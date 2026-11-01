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
import core.sync.mutex : Mutex;
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

// The same D object can be exposed in several Lua states (and as several
// class views). The D GC root set is process-global and not reference-counted,
// so keep one count per object and only add/remove the actual GC root when the
// first/last userdata disappears.
private __gshared size_t[void*] objectRootCounts;
private shared Mutex objectRootLock;

shared static this()
{
    objectRootLock = new shared Mutex;
}

private void addObjectRoot(void* p) nothrow
{
    if (p is null)
        return;
    objectRootLock.lock_nothrow();
    scope(exit) objectRootLock.unlock_nothrow();

    auto count = p in objectRootCounts;
    if (count is null)
    {
        objectRootCounts[p] = 1;
        GC.addRoot(p);
    }
    else
        ++*count;
}

private void removeObjectRoot(void* p) nothrow
{
    if (p is null)
        return;
    objectRootLock.lock_nothrow();
    scope(exit) objectRootLock.unlock_nothrow();

    auto count = p in objectRootCounts;
    if (count is null)
        return;
    if (--*count == 0)
    {
        objectRootCounts.remove(p);
        GC.removeRoot(p);
    }
}

version (unittest)
{
    /// Test hook: number of live Lua userdata currently rooting `obj`.
    package size_t objectRootCountForTest(void* p) nothrow
    {
        if (p is null)
            return 0;
        objectRootLock.lock_nothrow();
        scope(exit) objectRootLock.unlock_nothrow();
        auto count = p in objectRootCounts;
        return count is null ? 0 : *count;
    }
}

private extern(C) int classGc(T)(lua_State* L) nothrow
{
    auto p = cast(T*) lua_touserdata(L, 1);
    if (p !is null && *p !is null)
    {
        removeObjectRoot(cast(void*) *p);
        *p = null;
    }
    return 0;
}

// Every class metatable owns a weak-valued table mapping the boxed D object
// pointer to its userdata. While the userdata is reachable from Lua, pushing
// the same D object reuses it; when Lua collects it, the weak entry disappears
// and the next push creates a fresh userdata.
private void ensureIdentityTable(lua_State* L, int metaIdx)
{
    metaIdx = raw.absIndex(L, metaIdx);
    lua_getfield(L, metaIdx, "__lunarbind_identity");
    if (lua_type(L, -1) == LUA_TTABLE)
        return;

    raw.pop(L, 1);
    lua_createtable(L, 0, 0);
    lua_createtable(L, 0, 1);
    lua_pushlstring(L, "__mode".ptr, "__mode".length);
    lua_pushlstring(L, "v".ptr, 1);
    lua_rawset(L, -3);
    lua_setmetatable(L, -2);
    lua_pushvalue(L, -1);
    lua_setfield(L, metaIdx, "__lunarbind_identity");
    // The identity table is left on top of the stack.
}

private extern(C) int classEq(T)(lua_State* L) nothrow
{
    // Compare the boxed D references, not the userdata addresses. Repeated
    // pushes normally reuse one userdata, but different class views (or a
    // fresh userdata created after the previous one was collected) must still
    // compare equal.
    auto a = cast(T**) lua_touserdata(L, 1);
    auto b = cast(T**) lua_touserdata(L, 2);
    lua_pushboolean(L, a !is null && b !is null && *a is *b ? 1 : 0);
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
    ///
    /// Pushing the same D object again reuses the existing userdata while it is
    /// still reachable from Lua, preserving object identity and avoiding
    /// duplicate GC roots.
    static void push(LuaState state, T obj)
    {
        if (obj is null)
        {
            lua_pushnil(state.handle);
            return;
        }

        auto L = state.handle;
        ensureMetatable(state);              // class metatable
        ensureIdentityTable(L, -1);          // class metatable, identity table
        auto metaIdx = raw.absIndex(L, -2);

        lua_pushlightuserdata(L, cast(void*) obj);
        lua_rawget(L, -2);                   // class metatable, identity, value
        if (lua_type(L, -1) == LUA_TUSERDATA)
        {
            // A userdata whose __gc already ran has a null boxed reference and
            // must not be handed out again (it may still be in the weak table
            // while its finalizer runs).
            auto existing = cast(T**) lua_touserdata(L, -1);
            if (existing !is null && *existing !is null)
            {
                raw.remove(L, -3);           // identity, userdata
                raw.remove(L, -2);           // userdata
                return;
            }
        }
        raw.pop(L, 1);                       // class metatable, identity

        auto p = cast(T*) raw.newUserdata(L, (void*).sizeof);
        *p = obj;
        addObjectRoot(cast(void*) obj);

        lua_pushvalue(L, metaIdx);           // class metatable, identity, userdata, metatable
        lua_setmetatable(L, -2);             // class metatable, identity, userdata

        lua_pushlightuserdata(L, cast(void*) obj);
        lua_pushvalue(L, -2);                // class metatable, identity, userdata, key, userdata
        lua_rawset(L, -4);                   // class metatable, identity, userdata
        raw.remove(L, -3);                   // identity, userdata
        raw.remove(L, -2);                   // userdata
    }

    /// Read a D object from a Lua userdata at `idx`.
    static T get(LuaState state, int idx)
    {
        if (lua_type(state.handle, idx) == LUA_TNIL)
            return null;
        if (!isInstance(state, idx))
            throw new LuaTypeException("expected userdata of type " ~ T.stringof);
        auto p = cast(T*) lua_touserdata(state.handle, idx);
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

            // Attach the identity table eagerly so normal pushes only pay for
            // one lookup. ensureIdentityTable leaves it on the stack.
            ensureIdentityTable(state.handle, -1);
            raw.pop(state.handle, 1);
        }
        // luaL_newmetatable leaves the metatable on the stack.
    }
}
