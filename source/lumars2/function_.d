/// Lua function handles and D callback binding.
module lumars2.function_;

import lumars2.raw;
static import raw = lumars2.raw;
import lumars2.state;
import lumars2.types;
import lumars2.value;
import lumars2.conv;

import core.memory : GC;
import std.meta : AliasSeq;
import std.string : toStringz;
import std.traits : Parameters, ReturnType, isSomeFunction;
import std.typecons : Tuple;

// ---------------------------------------------------------------------------
// LuaFunction
// ---------------------------------------------------------------------------

struct LuaFunction
{
    private LuaRef _ref;

    this(LuaRef ref_)
    {
        _ref = ref_;
    }

    LuaState state() { return _ref.state(); }
    LuaRef ref_() @nogc nothrow { return _ref; }
    void push() @nogc nothrow { _ref.push(); }

    /// Call the function. `T` defaults to `LuaValue`; use `call!int` etc. for
    /// a typed result, `call!void` to discard results, or `call!(LuaValue[])`
    /// to collect all results.
    T call(T = LuaValue, Args...)(Args args)
    {
        auto s = state();
        StackGuard guard = StackGuard(s);

        const base = s.top();
        pushCFunction(s.handle, &luaMessageHandler); // errfunc at base + 1
        push();                                     // function at base + 2
        static foreach (arg; args)
            pushTo(s, arg);

        static if (is(T == void))
            enum int nresults = 0;
        else static if (is(T == LuaValue[]))
            enum int nresults = LUA_MULTRET;
        else
            enum int nresults = 1;

        auto status = raw.pcall(s.handle, cast(int) args.length, nresults, base + 1);
        remove(s.handle, base + 1);

        if (status != LUA_OK)
        {
            auto msg = s.errorText(-1);
            throw new LuaException(msg, cast(LuaStatus) status, msg);
        }

        static if (is(T == void))
        {
            return;
        }
        else static if (is(T == LuaValue[]))
        {
            LuaValue[] result;
            foreach (i; base + 1 .. s.top() + 1)
                result ~= LuaValue.fromStack(s, i);
            return result;
        }
        else
        {
            return popFrom!T(s, -1);
        }
    }

    LuaValue[] callMulti(Args...)(Args args)
    {
        return call!(LuaValue[])(args);
    }

    /// Create a typed D delegate that calls this Lua function.
    auto bind(Ret, Args...)()
    {
        return new LuaBoundFunction!(Ret, Args)(this);
    }
}

final class LuaBoundFunction(Ret, Args...)
{
    private LuaFunction _function;

    this(LuaFunction function_)
    {
        _function = function_;
    }

    Ret opCall(Args args)
    {
        static if (is(Ret == void))
        {
            _function.call!void(args);
            return;
        }
        else
        {
            return _function.call!Ret(args);
        }
    }
}

// ---------------------------------------------------------------------------
// D -> Lua callback wrappers
// ---------------------------------------------------------------------------

private void checkArity(size_t expected, int given, LuaState state)
{
    if (given < expected)
    {
        import std.conv : to;
        auto msg = "expected at least " ~ to!string(expected) ~ " arguments, got " ~ to!string(given);
        lua_pushlstring(state.handle, msg.ptr, msg.length);
        lua_error(state.handle);
    }
}

private void fillArgs(alias Fn)(LuaState state, ref Tuple!(Parameters!Fn) args)
{
    static foreach (i, PT; Parameters!Fn)
        args[i] = popFrom!PT(state, cast(int)(i + 1));
}

private int invokeAlias(alias F)(LuaState state)
{
    alias P = Parameters!F;
    checkArity(P.length, lua_gettop(state.handle), state);
    Tuple!P args;
    fillArgs!F(state, args);
    static if (is(ReturnType!F == void))
    {
        F(args.expand);
        return 0;
    }
    else
    {
        pushTo(state, F(args.expand));
        return 1;
    }
}

private int invokeValue(Dg)(LuaState state, Dg callable)
{
    alias P = Parameters!Dg;
    checkArity(P.length, lua_gettop(state.handle), state);
    Tuple!P args;
    fillArgs!Dg(state, args);
    static if (is(ReturnType!Dg == void))
    {
        callable(args.expand);
        return 0;
    }
    else
    {
        pushTo(state, callable(args.expand));
        return 1;
    }
}

private int pushError(lua_State* L, Throwable e) nothrow
{
    auto msg = e.msg;
    if (msg.length == 0)
        msg = "D exception";
    lua_pushlstring(L, msg.ptr, msg.length);
    return lua_error(L);
}

/// Wrap a compile-time D function/lambda as a Lua C function.
extern(C) int luaCFunctionWrapper(alias Func)(lua_State* L) nothrow
{
    try
    {
        auto state = LuaState.wrap(L);
        return invokeAlias!Func(state);
    }
    catch (Throwable e)
    {
        return pushError(L, e);
    }
}

// -- runtime delegates ------------------------------------------------------

private final class CallbackBox(Dg)
{
    Dg dg;
    this(Dg dg) nothrow { this.dg = dg; }
}

private void ensureCallbackMetatable(LuaState state)
{
    if (luaL_newmetatable(state.handle, "__lumars2_callback") != 0)
    {
        pushCFunction(state.handle, &callbackGc);
        lua_setfield(state.handle, -2, "__gc");
    }
    // luaL_newmetatable leaves the metatable on the stack in both cases.
}

private extern(C) int callbackGc(lua_State* L) nothrow
{
    auto p = cast(void**) lua_touserdata(L, 1);
    if (p !is null && *p !is null)
    {
        GC.removeRoot(*p);
        *p = null;
    }
    return 0;
}

private extern(C) int luaDelegateWrapper(Dg)(lua_State* L) nothrow
{
    try
    {
        auto ud = lua_touserdata(L, raw.upvalueIndex(1));
        auto box = cast(CallbackBox!Dg)(*cast(void**) ud);
        auto state = LuaState.wrap(L);
        return invokeValue(state, box.dg);
    }
    catch (Throwable e)
    {
        return pushError(L, e);
    }
}

/// Push a runtime D delegate as a Lua function.
void pushDelegate(Dg)(LuaState state, Dg dg)
{
    auto box = new CallbackBox!Dg(dg);
    GC.addRoot(cast(void*) box);

    auto ud = cast(void**) raw.newUserdata(state.handle, (void*).sizeof);
    *ud = cast(void*) box;
    ensureCallbackMetatable(state);
    lua_setmetatable(state.handle, -2);
    lua_pushcclosure(state.handle, &luaDelegateWrapper!Dg, 1);
}

// ---------------------------------------------------------------------------
// Registration helpers
// ---------------------------------------------------------------------------

/// Push a compile-time D function as a Lua function.
void pushFunction(alias Func)(LuaState state)
{
    pushCFunction(state.handle, &luaCFunctionWrapper!Func);
}

/// Register a compile-time D function as a global.
void registerFunction(alias Func)(LuaState state, string name)
{
    pushFunction!Func(state);
    lua_setglobal(state.handle, toStringz(name));
}

/// Register a runtime delegate as a global.
void registerDelegate(Dg)(LuaState state, string name, Dg dg)
{
    pushDelegate(state, dg);
    lua_setglobal(state.handle, toStringz(name));
}

/// Create a library table and register functions from (name, function) pairs.
void registerLibrary(Args...)(LuaState state, string libName)
    if (Args.length % 2 == 0)
{
    lua_createtable(state.handle, 0, cast(int)(Args.length / 2));
    static foreach (i; 0 .. Args.length / 2)
    {{
        pushFunction!(Args[i * 2 + 1])(state);
        lua_setfield(state.handle, -2, toStringz(Args[i * 2]));
    }}
    lua_setglobal(state.handle, toStringz(libName));
}






