/// Lua function handles and D callback binding.
module lunarbind.function_;

import lunarbind.raw;
static import raw = lunarbind.raw;
import lunarbind.state;
import lunarbind.types;
import lunarbind.value;
import lunarbind.conv;
import lunarbind.dispatch;

import core.memory : GC;
import std.meta : AliasSeq;
import std.string : toStringz;
import std.traits : Parameters, ReturnType, isSomeFunction,
                    variadicFunctionStyle, Variadic, isInstanceOf, Unqual;
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

    LuaState state() @nogc nothrow { return _ref.state(); }
    /// Registry reference handle for this function.
    @property LuaRef reference() @nogc nothrow { return _ref; }
    void push() @nogc nothrow { _ref.push(); }
    void pushInto(LuaState target) { _ref.pushInto(target); }

    /// Call the function. `T` defaults to `LuaValue`; use `call!int` etc. for
    /// a typed result, `call!void` to discard results, `call!(LuaValue[])` to
    /// collect all results, or a `Tuple` to collect several typed results.
    T call(T = LuaValue, Args...)(Args args)
    {
        auto s = state();
        s.ensureOpen();
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
        else static if (isInstanceOf!(Tuple, Unqual!T))
            enum int nresults = cast(int) Unqual!T.length;
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
        else static if (isInstanceOf!(Tuple, Unqual!T))
        {
            alias R = Unqual!T;
            R result;
            static foreach (i, E; R.Types)
                result.expand[i] = popFrom!(Unqual!E)(s, base + 1 + cast(int) i);
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

private string argumentCount(size_t n)
{
    import std.conv : to;
    return n == 1 ? "1 argument" : to!string(n) ~ " arguments";
}

// Resolve the name used in arity errors. Called only on the failure path so
// successful calls do not pay for reading the upvalue.
private string arityName(alias F)(lua_State* L, int nameIndex)
{
    auto runtimeName = upvalueString(L, nameIndex);
    static if (__traits(compiles, __traits(identifier, F)))
        enum fallbackName = __traits(identifier, F);
    else
        enum fallbackName = F.stringof;
    return runtimeName.length ? runtimeName : fallbackName;
}

// Throws a D exception instead of raising a Lua error: the caller's
// `LuaState` and argument tuple must unwind normally before `lua_error` runs.
//
// The name lives in a Lua upvalue (`nameIndex`) and is read only when the
// arity check fails.
private void checkArity(alias F)(int given, lua_State* L, int nameIndex)
{
    import std.conv : to;
    enum required = requiredParamCount!F;
    static if (variadicFunctionStyle!F == Variadic.typesafe)
    {
        if (given < required)
            throw new LuaArgumentException(
                arityName!F(L, nameIndex) ~ ": expected at least "
                ~ argumentCount(required)
                ~ ", got " ~ argumentCount(given));
    }
    else
    {
        enum fixed = luaFixedCount!F;
        if (given < required || given > fixed)
        {
            static if (required == fixed)
                throw new LuaArgumentException(
                    arityName!F(L, nameIndex) ~ ": expected "
                    ~ argumentCount(fixed)
                    ~ ", got " ~ argumentCount(given));
            else
                throw new LuaArgumentException(
                    arityName!F(L, nameIndex) ~ ": expected between "
                    ~ to!string(required)
                    ~ " and " ~ argumentCount(fixed)
                    ~ ", got " ~ argumentCount(given));
        }
    }
}

private int invokeAlias(alias F)(LuaState state, int nameIndex)
{
    alias P = Parameters!F;
    auto nargs = cast(size_t) lua_gettop(state.handle);
    checkArity!F(cast(int) nargs, state.handle, nameIndex);
    Tuple!P args;
    fillCallArgs!F(state, args, nargs, 1);
    static if (is(ReturnType!F == void))
    {
        F(args.expand);
        return 0;
    }
    else
    {
        return pushCallResult(state, F(args.expand));
    }
}

private int invokeValue(Dg)(LuaState state, Dg callable, int nameIndex)
{
    alias P = Parameters!Dg;
    auto nargs = cast(size_t) lua_gettop(state.handle);
    checkArity!Dg(cast(int) nargs, state.handle, nameIndex);
    Tuple!P args;
    fillCallArgs!Dg(state, args, nargs, 1);
    static if (is(ReturnType!Dg == void))
    {
        callable(args.expand);
        return 0;
    }
    else
    {
        return pushCallResult(state, callable(args.expand));
    }
}

// The registration name lives in a Lua string upvalue so arity errors can use
// the Lua name instead of the D identifier.
private string upvalueString(lua_State* L, int index) nothrow @nogc
{
    size_t len;
    auto p = lua_tolstring(L, raw.upvalueIndex(index), &len);
    // Lua strings are immutable, so exposing them as `string` is safe.
    return p is null ? "" : cast(string) p[0 .. len];
}

/// Wrap a compile-time D function/lambda as a Lua C function.
extern(C) int luaCFunctionWrapper(alias Func)(lua_State* L) nothrow
{
    try
    {
        auto state = LuaState.wrap(L);
        return invokeAlias!Func(state, 1);
    }
    catch (Throwable e)
    {
        return pushError(L, e);
    }
}

/// Wrap a raw Lua C callback so D-linkage callbacks and exceptions are safe.
private extern(C) int luaRawFunctionWrapper(alias Func)(lua_State* L) nothrow
{
    try
    {
        return Func(L);
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
    if (luaL_newmetatable(state.handle, "__lunarbind_callback") != 0)
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
        return invokeValue(state, box.dg, 2);
    }
    catch (Throwable e)
    {
        return pushError(L, e);
    }
}

private extern(C) int luaRawDelegateWrapper(Dg)(lua_State* L) nothrow
{
    try
    {
        auto ud = lua_touserdata(L, raw.upvalueIndex(1));
        auto fp = *cast(Dg*) ud;
        return fp(L);
    }
    catch (Throwable e)
    {
        return pushError(L, e);
    }
}

/// Push a runtime D delegate as a Lua function.
///
/// `name` is used in arity error messages. When empty, the wrapper falls back
/// to the D identifier for compile-time functions and to the anonymous
/// function text for runtime delegates.
void pushDelegate(Dg)(LuaState state, Dg dg, string name = "")
{
    state.ensureOpen();
    static if (isRawLuaFunctionType!Dg)
    {
        // A raw Lua callback reads the Lua stack directly. Store the pointer in
        // an upvalue so the call goes through D linkage and exceptions are
        // converted; function pointers need no GC root.
        auto ud = cast(Dg*) raw.newUserdata(state.handle, Dg.sizeof);
        *ud = dg;
        lua_pushcclosure(state.handle, &luaRawDelegateWrapper!Dg, 1);
    }
    else
    {
        static assert(bindableVariadic!Dg,
                      "lunarbind: only D typesafe variadics can be bound; " ~
                      "use a raw lua_CFunction for C-style variadics");
        auto box = new CallbackBox!Dg(dg);
        GC.addRoot(cast(void*) box);

        auto ud = cast(void**) raw.newUserdata(state.handle, (void*).sizeof);
        *ud = cast(void*) box;
        ensureCallbackMetatable(state);
        lua_setmetatable(state.handle, -2);
        lua_pushlstring(state.handle, name.ptr, name.length);
        lua_pushcclosure(state.handle, &luaDelegateWrapper!Dg, 2);
    }
}

// ---------------------------------------------------------------------------
// Registration helpers
// ---------------------------------------------------------------------------

/// Push a compile-time D function as a Lua function.
///
/// `name` is used in arity error messages. When empty, the wrapper falls back
/// to the D identifier.
void pushFunction(alias Func)(LuaState state, string name = "")
{
    state.ensureOpen();
    static if (isRawLuaFunction!Func)
    {
        pushCFunction(state.handle, &luaRawFunctionWrapper!Func);
    }
    else
    {
        static assert(bindableVariadic!Func,
                      "lunarbind: only D typesafe variadics can be bound; " ~
                      "use a raw lua_CFunction for C-style variadics");
        lua_pushlstring(state.handle, name.ptr, name.length);
        lua_pushcclosure(state.handle, &luaCFunctionWrapper!Func, 1);
    }
}

/// Register a compile-time D function as a global.
void registerFunction(alias Func)(LuaState state, string name)
{
    pushFunction!Func(state, name);
    state.setGlobal(name);
}

/// Register a runtime delegate as a global.
void registerDelegate(Dg)(LuaState state, string name, Dg dg)
{
    pushDelegate(state, dg, name);
    state.setGlobal(name);
}

/// Create a library table and register functions from (name, function) pairs.
void registerLibrary(Args...)(LuaState state, string libName)
    if (Args.length % 2 == 0)
{
    state.ensureOpen();
    StackGuard guard = StackGuard(state);
    lua_createtable(state.handle, 0, cast(int)(Args.length / 2));
    static foreach (i; 0 .. Args.length / 2)
    {{
        pushFunction!(Args[i * 2 + 1])(state, Args[i * 2]);
        lua_setfield(state.handle, -2, toStringz(Args[i * 2]));
    }}
    state.setGlobal(libName);
}
