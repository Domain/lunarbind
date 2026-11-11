/// Conversion policy: `pushTo!T` and `popFrom!T`.
///
/// The design deliberately uses free-function templates instead of baking a
/// giant `static if` chain into `LuaState`. Runtime-registered codecs
/// (`registerCodec`) override the default representation for classes and
/// structs, and are required for unions; object binding lives in
/// `lunarbind.object`.
module lunarbind.conv;

import lunarbind.raw;
static import raw = lunarbind.raw;
import lunarbind.state;
import lunarbind.types;
import lunarbind.value;

import lunarbind.table : LuaTable;
import lunarbind.function_ : LuaFunction;

import std.traits : isIntegral, isFloatingPoint, isDynamicArray,
                    isAssociativeArray, isSomeString, KeyType, ValueType, isPointer,
                    isInstanceOf, Unqual, OriginalType, isUnsigned;
import std.typecons : Nullable;
import std.meta : AliasSeq;

/// A zero-copy view of a Lua string. Valid only while the underlying Lua value
/// stays alive on the stack; use `string` when you need an owning copy.
struct LuaString
{
    const(char)[] value;
    alias value this;
}

/// A user-defined conversion between a D type and a Lua value.
///
/// Codecs are registered per `LuaState` and take precedence over the default
/// `LuaClass!T`/`LuaStruct!T` representation for classes and structs. Unions
/// have no default representation and can only cross the boundary through a
/// registered codec. `push` writes a value onto the Lua stack, `pop` reads a
/// value from `idx`, and the optional `check` predicate is used by overload
/// resolution. Without `check`, any non-nil Lua value is accepted.
struct LuaCodec(T)
{
    alias Push = void delegate(LuaState, ref const T);
    alias Pop = T delegate(LuaState, int);
    alias Check = bool delegate(LuaState, int);

    Push push;
    Pop pop;
    Check check;

    this(Push push, Pop pop, Check check = null)
    {
        this.push = push;
        this.pop = pop;
        this.check = check;
    }
}

private final class CodecHolder(T)
{
    LuaCodec!T codec;

    this(LuaCodec!T codec)
    {
        this.codec = codec;
    }
}

/// Register or replace the codec for `T` in this state.
void registerCodec(T)(LuaState L, LuaCodec!T codec)
{
    static assert(is(T == Unqual!T),
                  "register a codec for the unqualified type");
    if (codec.push is null || codec.pop is null)
        throw new LuaArgumentException("LuaCodec requires push and pop functions");
    L.setExtension(typeid(T), new CodecHolder!T(codec));
}

/// Remove a previously registered codec for `T`.
void unregisterCodec(T)(LuaState L)
{
    static assert(is(T == Unqual!T),
                  "unregister a codec for the unqualified type");
    L.setExtension(typeid(T), null);
}

private CodecHolder!T codecFor(T)(LuaState L)
{
    auto extension = L.getExtension(typeid(Unqual!T));
    return extension is null ? null : cast(CodecHolder!(Unqual!T)) extension;
}

package bool hasCodec(T)(LuaState L)
{
    return codecFor!(Unqual!T)(L) !is null;
}

package bool codecMatches(T)(LuaState L, int idx)
{
    auto holder = codecFor!(Unqual!T)(L);
    if (holder is null)
        return false;
    if (holder.codec.check !is null)
        return holder.codec.check(L, idx);
    auto t = lua_type(L.handle, idx);
    return t != LUA_TNIL && t != LUA_TNONE;
}

/// Push a D value onto the Lua stack.
void pushTo(T)(LuaState L, auto ref T value)
{
    static if (is(T == typeof(null)))
    {
        lua_pushnil(L.handle);
    }
    else static if (is(T == LuaValue))
    {
        value.push(L);
    }
    else static if (is(T == LuaRef))
    {
        if (value.isNull())
            lua_pushnil(L.handle);
        else
            value.pushInto(L);
    }
    else static if (is(T == LuaTable) || is(T == LuaFunction))
    {
        value.pushInto(L);
    }
    else static if (__traits(compiles, value.pushInto(L)))
    {
        // Typed handles such as LuaThread expose `pushInto`.
        value.pushInto(L);
    }
    else static if (is(T == class))
    {
        if (auto holder = codecFor!T(L))
        {
            auto copy = value;
            holder.codec.push(L, copy);
        }
        else
        {
            import lunarbind.object : LuaClass;
            LuaClass!T.push(L, value);
        }
    }
    else static if (is(T == LuaString))
    {
        lua_pushlstring(L.handle, value.value.ptr, value.value.length);
    }
    else static if (is(T == string) || is(T : const(char)[]))
    {
        lua_pushlstring(L.handle, value.ptr, value.length);
    }
    else static if (is(T == bool))
    {
        lua_pushboolean(L.handle, value ? 1 : 0);
    }
    else static if (is(T == enum))
    {
        pushTo(L, cast(OriginalType!T) value);
    }
    else static if (isIntegral!T)
    {
        // Values wider than lua_Integer (or unsigned values of the same
        // width) can wrap when cast. Reject them before pushing so Lua never
        // observes a truncated integer.
        static if (isUnsigned!T && T.sizeof >= lua_Integer.sizeof)
        {
            if (value > cast(T) lua_Integer.max)
                throw new LuaArgumentException(
                    T.stringof ~ " value is out of range for a Lua integer");
        }
        else static if (!isUnsigned!T && T.sizeof > lua_Integer.sizeof)
        {
            if (value < lua_Integer.min || value > lua_Integer.max)
                throw new LuaArgumentException(
                    T.stringof ~ " value is out of range for a Lua integer");
        }
        lua_pushinteger(L.handle, cast(lua_Integer) value);
    }
    else static if (isFloatingPoint!T)
    {
        lua_pushnumber(L.handle, cast(lua_Number) value);
    }
    else static if (is(T == void*))
    {
        lua_pushlightuserdata(L.handle, value);
    }
    else static if (isInstanceOf!(Nullable, T))
    {
        if (value.isNull)
            lua_pushnil(L.handle);
        else
            pushTo(L, value.get());
    }
    else static if (isDynamicArray!T)
    {
        lua_createtable(L.handle, cast(int) value.length, 0);
        foreach (i, e; value)
        {
            pushTo(L, e);
            lua_rawseti(L.handle, -2, cast(lua_Integer)(i + 1));
        }
    }
    else static if (isAssociativeArray!T)
    {
        lua_createtable(L.handle, 0, cast(int) value.length);
        foreach (k, v; value)
        {
            pushTo(L, k);
            // lua_rawset raises on nil and NaN keys. Reject them here so a
            // failed conversion becomes a D exception instead of an
            // unprotected longjmp out of D code.
            auto keyType = lua_type(L.handle, -1);
            if (keyType == LUA_TNIL)
                throw new LuaArgumentException(
                    "associative array key converts to nil");
            if (keyType == LUA_TNUMBER)
            {
                auto n = raw.toNumberX(L.handle, -1, null);
                if (n != n)
                    throw new LuaArgumentException(
                        "associative array key converts to NaN");
            }
            pushTo(L, v);
            lua_rawset(L.handle, -3);
        }
    }
    else static if (is(Unqual!T == struct))
    {
        alias S = Unqual!T;
        if (auto holder = codecFor!S(L))
        {
            auto copy = cast(S) value;
            holder.codec.push(L, copy);
        }
        else
        {
            import lunarbind.object : LuaStruct;
            LuaStruct!S.push(L, cast(S) value);
        }
    }
    else static if (is(Unqual!T == union))
    {
        // Unions have no default Lua representation: their active member is
        // not known to the binder, so a codec must define the mapping.
        alias U = Unqual!T;
        if (auto holder = codecFor!U(L))
        {
            auto copy = cast(U) value;
            holder.codec.push(L, copy);
        }
        else
            throw new LuaArgumentException(
                "no codec registered for union " ~ U.stringof
                ~ "; call registerCodec!" ~ U.stringof);
    }
    else
    {
        static assert(0, "lunarbind: no pushTo implementation for type " ~ T.stringof);
    }
}

/// Pop a D value from the Lua stack at `idx`.
T popFrom(T)(LuaState L, int idx)
{
    auto h = L.handle;
    static if (is(T == LuaValue))
    {
        return LuaValue.fromStack(L, idx);
    }
    else static if (is(T == LuaRef))
    {
        return LuaRef.make(L, idx);
    }
    else static if (is(T == LuaTable))
    {
        return LuaTable(LuaRef.make(L, idx));
    }
    else static if (is(T == LuaFunction))
    {
        return LuaFunction(LuaRef.make(L, idx));
    }
    else static if (is(T == LuaString))
    {
        auto t = lua_type(h, idx);
        if (t != LUA_TSTRING && t != LUA_TNUMBER)
            throw new LuaTypeException("expected string, got " ~ L.typeName(idx));
        size_t len;
        auto p = lua_tolstring(h, idx, &len);
        return LuaString(p[0 .. len]);
    }
    else static if (is(T == string))
    {
        auto t = lua_type(h, idx);
        if (t == LUA_TNIL || t == LUA_TNONE)
            return null;
        if (t != LUA_TSTRING && t != LUA_TNUMBER)
            throw new LuaTypeException("expected string, got " ~ L.typeName(idx));
        size_t len;
        auto p = lua_tolstring(h, idx, &len);
        return p[0 .. len].idup;
    }
    else static if (is(T == char[]))
    {
        // Mutable slices cannot alias Lua's immutable, GC-managed string
        // storage, so return an owned copy.
        auto t = lua_type(h, idx);
        if (t == LUA_TNIL || t == LUA_TNONE)
            return null;
        if (t != LUA_TSTRING && t != LUA_TNUMBER)
            throw new LuaTypeException("expected string, got " ~ L.typeName(idx));
        size_t len;
        auto p = lua_tolstring(h, idx, &len);
        return p[0 .. len].dup;
    }
    else static if (is(T : const(char)[]))
    {
        auto t = lua_type(h, idx);
        if (t == LUA_TNIL || t == LUA_TNONE)
            return null;
        if (t != LUA_TSTRING && t != LUA_TNUMBER)
            throw new LuaTypeException("expected string, got " ~ L.typeName(idx));
        size_t len;
        auto p = lua_tolstring(h, idx, &len);
        return p[0 .. len];
    }
    else static if (is(T == bool))
    {
        return lua_toboolean(h, idx) != 0;
    }
    else static if (is(T == enum))
    {
        return cast(T) popFrom!(OriginalType!T)(L, idx);
    }
    else static if (isIntegral!T)
    {
        import std.conv : to;

        int isnum = 0;
        auto v = raw.toIntegerX(h, idx, &isnum);
        if (!isnum)
            throw new LuaTypeException("expected integer, got " ~ L.typeName(idx));

        static if (is(T == lua_Integer))
            return v;
        else static if (isUnsigned!T)
        {
            static if (T.sizeof >= lua_Integer.sizeof)
            {
                if (v < 0)
                    throw new LuaArgumentException(
                        "integer " ~ to!string(v) ~ " is out of range for "
                        ~ T.stringof);
            }
            else
            {
                if (v < 0 || cast(ulong) v > T.max)
                    throw new LuaArgumentException(
                        "integer " ~ to!string(v) ~ " is out of range for "
                        ~ T.stringof);
            }
            return cast(T) v;
        }
        else
        {
            static if (T.sizeof >= lua_Integer.sizeof)
                return cast(T) v;
            else
            {
                if (v < T.min || v > T.max)
                    throw new LuaArgumentException(
                        "integer " ~ to!string(v) ~ " is out of range for "
                        ~ T.stringof);
                return cast(T) v;
            }
        }
    }
    else static if (isFloatingPoint!T)
    {
        int isnum = 0;
        auto v = raw.toNumberX(h, idx, &isnum);
        if (!isnum)
            throw new LuaTypeException("expected number, got " ~ L.typeName(idx));
        return cast(T) v;
    }
    else static if (is(T == void*))
    {
        if (lua_type(h, idx) == LUA_TNIL)
            return null;
        if (lua_type(h, idx) != LUA_TLIGHTUSERDATA)
            throw new LuaTypeException("expected light userdata, got " ~ L.typeName(idx));
        return lua_touserdata(h, idx);
    }
    else static if (isInstanceOf!(Nullable, T))
    {
        alias U = typeof(T.init.get());
        if (lua_type(h, idx) == LUA_TNIL)
            return T.init;
        return T(popFrom!U(L, idx));
    }
    else static if (isDynamicArray!T)
    {
        if (lua_type(h, idx) == LUA_TNIL)
            return null;
        if (lua_type(h, idx) != LUA_TTABLE)
            throw new LuaTypeException("expected table, got " ~ L.typeName(idx));

        alias E = typeof(T.init[0]);
        auto tableIdx = L.absIndex(idx);
        auto len = raw.rawLen(h, tableIdx);
        auto result = new E[len];
        foreach (i; 0 .. len)
        {
            lua_rawgeti(h, tableIdx, cast(lua_Integer)(i + 1));
            scope(exit) L.pop(1);
            result[i] = popFrom!E(L, -1);
        }
        return result;
    }
    else static if (isAssociativeArray!T)
    {
        if (lua_type(h, idx) == LUA_TNIL)
            return null;
        if (lua_type(h, idx) != LUA_TTABLE)
            throw new LuaTypeException("expected table, got " ~ L.typeName(idx));

        alias K = KeyType!T;
        alias V = ValueType!T;
        T result;
        auto tableIdx = L.absIndex(idx);
        auto baseTop = L.top();
        LuaValue currentKey; // nil starts the traversal
        while (true)
        {
            // Restore the stack after each step, including when the key or
            // value conversion throws.
            scope(exit) L.setTop(baseTop);

            pushCFunction(h, &nextThunk);       // [.., thunk]
            lua_pushvalue(h, tableIdx);         // [.., thunk, table]
            currentKey.push(L);                 // [.., thunk, table, key]
            auto status = raw.pcall(h, 2, LUA_MULTRET, 0);
            if (status != LUA_OK)
                throw tableError(L, status);
            if (L.top() == baseTop)
                break;

            auto key = LuaValue.fromStack(L, baseTop + 1);
            result[popFrom!K(L, baseTop + 1)] = popFrom!V(L, baseTop + 2);
            currentKey = key;
        }
        return result;
    }
    else static if (is(T == class))
    {
        if (auto holder = codecFor!T(L))
            return holder.codec.pop(L, idx);
        if (lua_type(h, idx) == LUA_TNIL)
            return null;
        import lunarbind.object : LuaClass;
        return LuaClass!T.get(L, idx);
    }
    else static if (is(Unqual!T == struct))
    {
        alias S = Unqual!T;
        if (auto holder = codecFor!S(L))
            return cast(T) holder.codec.pop(L, idx);
        import lunarbind.object : LuaStruct;
        return cast(T) LuaStruct!S.get(L, idx);
    }
    else static if (is(Unqual!T == union))
    {
        alias U = Unqual!T;
        if (auto holder = codecFor!U(L))
            return cast(T) holder.codec.pop(L, idx);
        throw new LuaArgumentException(
            "no codec registered for union " ~ U.stringof
            ~ "; call registerCodec!" ~ U.stringof);
    }
    else
    {
        static assert(0, "lunarbind: no popFrom implementation for type " ~ T.stringof);
    }
}
