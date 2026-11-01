/// Experimental D-object binding: expose D classes as Lua userdata with a
/// metatable, public fields and methods.
///
/// This is deliberately a *first* implementation:
/// - D -> Lua and Lua -> D object identity is preserved (full userdata stores
///   the class reference, and the D GC is rooted while Lua owns the userdata).
/// - Public fields are readable/writable from Lua.
/// - Public single-overload methods are callable as `obj:method(...)`.
/// - Inheritance, properties, operator overloads, constructors and overload
///   resolution are future work.
module lunarbind.object;

import lunarbind.raw;
static import raw = lunarbind.raw;
import lunarbind.state;
import lunarbind.types;
import lunarbind.value;
import lunarbind.conv;
import lunarbind.function_;

import core.memory : GC;
import std.string : toStringz;
import std.traits : fullyQualifiedName, Parameters, ReturnType, isIntegral,
                    isFloatingPoint, isSomeString, Unqual;
import std.typecons : Tuple;

// ---------------------------------------------------------------------------
// Compile-time member filtering
// ---------------------------------------------------------------------------

private template memberCount(T, string member)
{
    static if (__traits(compiles, __traits(getOverloads, T, member)))
        enum memberCount = __traits(getOverloads, T, member).length;
    else
        enum memberCount = 0;
}

private template isPublicMember(T, string member)
{
    static if (__traits(compiles, __traits(getProtection, __traits(getMember, T, member))))
        enum isPublicMember = __traits(getProtection, __traits(getMember, T, member)) == "public";
    else
        enum isPublicMember = false;
}

private template isExposedName(string member)
{
    enum isExposedName =
        member.length > 0
        && member[0] != '_'
        && member != "toString"
        && member != "toHash"
        && member != "opEquals"
        && member != "opCmp"
        && member != "classinfo"
        && member != "mangleof"
        && member != "sizeof"
        && member != "alignof"
        && member != "init"
        && member != "factory";
}

private template isBindableType(T)
{
    enum isBindableType =
        is(T == bool)
        || isIntegral!T
        || isFloatingPoint!T
        || isSomeString!T
        || is(T : const(char)[])
        || is(T == LuaValue)
        || is(T == LuaRef)
        || is(T == LuaTable)
        || is(T == LuaFunction)
        || is(T == void*);
}

private template isBindableReturn(T)
{
    static if (is(T == void))
        enum isBindableReturn = true;
    else
        enum isBindableReturn = isBindableType!T;
}

private template methodBindable(T, string member)
{
    static if (memberCount!(T, member) == 1)
    {
        alias Method = __traits(getOverloads, T, member)[0];
        static if (__traits(compiles, Parameters!Method))
        {
            enum paramsOk = allBindable!(Parameters!Method);
            enum methodBindable = paramsOk && isBindableReturn!(ReturnType!Method);
        }
        else
            enum methodBindable = false;
    }
    else
        enum methodBindable = false;
}

private template allBindable(Params...)
{
    static if (Params.length == 0)
        enum allBindable = true;
    else
        enum allBindable = isBindableType!(Params[0]) && allBindable!(Params[1 .. $]);
}

private template fieldType(T, string member)
{
    alias fieldType = typeof(__traits(getMember, T.init, member));
}

private template isField(T, string member)
{
    static if (memberCount!(T, member) == 0
               && __traits(compiles, typeof(__traits(getMember, T.init, member))))
        enum isField = true;
    else
        enum isField = false;
}

private template fieldBindable(T, string member)
{
    static if (isField!(T, member))
        enum fieldBindable = isBindableType!(Unqual!(fieldType!(T, member)));
    else
        enum fieldBindable = false;
}

// ---------------------------------------------------------------------------
// Userdata helpers
// ---------------------------------------------------------------------------

private template metaName(T)
{
    enum string metaName = "lunarbind.class." ~ fullyQualifiedName!T;
}

private extern(C) int classGc(T)(lua_State* L) nothrow
{
    auto p = cast(T*) lua_touserdata(L, 1);
    if (p !is null && *p !is null)
    {
        GC.removeRoot(cast(void*) *p);
        *p = null;
    }
    return 0;
}

private extern(C) int classEq(T)(lua_State* L) nothrow
{
    auto a = lua_touserdata(L, 1);
    auto b = lua_touserdata(L, 2);
    lua_pushboolean(L, a is b ? 1 : 0);
    return 1;
}

private extern(C) int classIndex(T)(lua_State* L) nothrow
{
    try
    {
        auto state = LuaState.wrap(L);
        size_t len;
        auto keyPtr = lua_tolstring(L, 2, &len);
        if (keyPtr is null)
        {
            lua_pushnil(L);
            return 1;
        }
        const(char)[] key = keyPtr[0 .. len];
        T self = *cast(T*) lua_touserdata(L, 1);

        static foreach (member; __traits(allMembers, T))
        {{
            static if (isPublicMember!(T, member) && isExposedName!member)
            {
                static if (fieldBindable!(T, member))
                {
                    if (key == member)
                    {
                        pushTo(state, __traits(getMember, self, member));
                        return 1;
                    }
                }
                else static if (methodBindable!(T, member))
                {
                    if (key == member)
                    {
                        pushCFunction(L, &methodThunk!(T, member));
                        return 1;
                    }
                }
            }
        }}

        lua_pushnil(L);
        return 1;
    }
    catch (Throwable e)
    {
        lua_pushlstring(L, e.msg.ptr, e.msg.length);
        return lua_error(L);
    }
}

private extern(C) int classNewIndex(T)(lua_State* L) nothrow
{
    try
    {
        auto state = LuaState.wrap(L);
        size_t len;
        auto keyPtr = lua_tolstring(L, 2, &len);
        if (keyPtr is null)
        {
            luaL_argerror(L, 2, "field name must be a string");
            return 0;
        }
        const(char)[] key = keyPtr[0 .. len];
        T self = *cast(T*) lua_touserdata(L, 1);

        static foreach (member; __traits(allMembers, T))
        {{
            static if (isPublicMember!(T, member) && isExposedName!member
                       && fieldBindable!(T, member))
            {
                if (key == member)
                {
                    alias FT = Unqual!(fieldType!(T, member));
                    __traits(getMember, self, member) = popFrom!FT(state, 3);
                    return 0;
                }
            }
        }}

        luaL_argerror(L, 2, "unknown field");
        return 0;
    }
    catch (Throwable e)
    {
        lua_pushlstring(L, e.msg.ptr, e.msg.length);
        return lua_error(L);
    }
}

private extern(C) int methodThunk(T, string member)(lua_State* L) nothrow
{
    try
    {
        auto state = LuaState.wrap(L);
        T self = *cast(T*) lua_touserdata(L, 1);
        alias Method = __traits(getOverloads, T, member)[0];
        alias Params = Parameters!Method;

        auto nargs = lua_gettop(L) - 1;
        if (nargs < Params.length)
        {
            lua_pushlstring(L, "not enough arguments".ptr, "not enough arguments".length);
            return lua_error(L);
        }

        Tuple!Params args;
        static foreach (i, P; Params)
            args[i] = popFrom!(Unqual!P)(state, cast(int)(i + 2));

        static if (is(ReturnType!Method == void))
        {
            __traits(getMember, self, member)(args.expand);
            return 0;
        }
        else
        {
            pushTo(state, __traits(getMember, self, member)(args.expand));
            return 1;
        }
    }
    catch (Throwable e)
    {
        lua_pushlstring(L, e.msg.ptr, e.msg.length);
        return lua_error(L);
    }
}

// ---------------------------------------------------------------------------
// Public class binding
// ---------------------------------------------------------------------------

struct LuaClass(T)
    if (is(T == class))
{
    /// Push `obj` as a full userdata. Null becomes Lua nil.
    static void push(LuaState state, T obj)
    {
        if (obj is null)
        {
            lua_pushnil(state.handle);
            return;
        }

        auto p = cast(T*) raw.newUserdata(state.handle, (void*).sizeof);
        *p = obj;
        GC.addRoot(cast(void*) obj);

        ensureMetatable(state);
        lua_setmetatable(state.handle, -2);
    }

    /// Read a D object from a Lua userdata at `idx`.
    static T get(LuaState state, int idx)
    {
        auto p = cast(T*) luaL_checkudata(state.handle, idx, toStringz(metaName!T));
        return *p;
    }

    /// Push a global variable and register it under `name`.
    static void setGlobal(LuaState state, string name, T obj)
    {
        push(state, obj);
        raw.setGlobal(state.handle, toStringz(name));
    }

    /// Read a global variable as a D object (null if nil).
    static T getGlobal(LuaState state, string name)
    {
        raw.getGlobal(state.handle, toStringz(name));
        scope(exit) raw.pop(state.handle, 1);
        if (lua_type(state.handle, -1) == LUA_TNIL)
            return null;
        return get(state, -1);
    }

    /// Check whether the value at `idx` is an instance of this class.
    static bool isInstance(LuaState state, int idx)
    {
        if (lua_type(state.handle, idx) != LUA_TUSERDATA)
            return false;
        auto p = lua_touserdata(state.handle, idx);
        if (p is null)
            return false;
        if (lua_getmetatable(state.handle, idx) == 0)
            return false;
        raw.getMetatable(state.handle, toStringz(metaName!T)); // allocates in @nogc -- see below
        auto eq = lua_rawequal(state.handle, -1, -2) != 0;
        raw.pop(state.handle, 2);
        return eq;
    }

    /// Ensure the class metatable exists in the registry.
    static void registerClass(LuaState state)
    {
        ensureMetatable(state);
        raw.pop(state.handle, 1);
    }

    private static void ensureMetatable(LuaState state)
    {
        auto name = toStringz(metaName!T);
        if (luaL_newmetatable(state.handle, name) != 0)
        {
            pushCFunction(state.handle, &classGc!T);
            lua_setfield(state.handle, -2, "__gc");
            pushCFunction(state.handle, &classIndex!T);
            lua_setfield(state.handle, -2, "__index");
            pushCFunction(state.handle, &classNewIndex!T);
            lua_setfield(state.handle, -2, "__newindex");
            pushCFunction(state.handle, &classEq!T);
            lua_setfield(state.handle, -2, "__eq");
        }
        // luaL_newmetatable leaves the metatable on the stack.
    }
}





