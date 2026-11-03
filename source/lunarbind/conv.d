/// Conversion policy: `pushTo!T` and `popFrom!T`.
///
/// The design deliberately uses free-function templates instead of baking a
/// giant `static if` chain into `LuaState`.  Future versions will also allow
/// runtime-registered codecs for user types; object binding lives in
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
                    isAssociativeArray, isSomeString, KeyType, ValueType, isPointer, isInstanceOf, Unqual;
import std.typecons : Nullable;
import std.meta : AliasSeq;

/// A zero-copy view of a Lua string. Valid only while the underlying Lua value
/// stays alive on the stack; use `string` when you need an owning copy.
struct LuaString
{
    const(char)[] value;
    alias value this;
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
    else static if (is(T == class))
    {
        import lunarbind.object : LuaClass;
        LuaClass!T.push(L, value);
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
    else static if (isIntegral!T)
    {
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
            pushTo(L, v);
            lua_rawset(L.handle, -3);
        }
    }
    else static if (is(Unqual!T == struct))
    {
        import lunarbind.object : LuaStruct;
        alias S = Unqual!T;
        LuaStruct!S.push(L, cast(S) value);
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
    else static if (isIntegral!T)
    {
        int isnum = 0;
        auto v = raw.toIntegerX(h, idx, &isnum);
        if (!isnum)
            throw new LuaTypeException("expected integer, got " ~ L.typeName(idx));
        return cast(T) v;
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
        lua_pushnil(h);
        while (lua_next(h, tableIdx) != 0)
        {
            scope(exit) L.pop(1);
            result[popFrom!K(L, -2)] = popFrom!V(L, -1);
        }
        return result;
    }
    else static if (is(T == class))
    {
        if (lua_type(h, idx) == LUA_TNIL)
            return null;
        import lunarbind.object : LuaClass;
        return LuaClass!T.get(L, idx);
    }
    else static if (is(Unqual!T == struct))
    {
        import lunarbind.object : LuaStruct;
        return cast(T) LuaStruct!(Unqual!T).get(L, idx);
    }
    else
    {
        static assert(0, "lunarbind: no popFrom implementation for type " ~ T.stringof);
    }
}
