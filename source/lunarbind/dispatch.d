/// Internal call-shape helpers shared by class, struct and function bindings.
///
/// D default arguments and typesafe variadics are resolved here so every
/// binding path accepts the same Lua calls.
module lunarbind.dispatch;

import lunarbind.state;
import lunarbind.conv;
import lunarbind.value : LuaResults;
import lunarbind.raw : LUA_TNUMBER, isInteger, lua_State, lua_error,
                      lua_pushlstring, lua_type, lua_typename;

import std.traits : Parameters, ParameterDefaults, ReturnType,
                    variadicFunctionStyle, Variadic, Unqual, isInstanceOf;
import std.typecons : Tuple;

/// Raise `msg` as a Lua error.
///
/// `lua_error` uses `longjmp`, so no D object with a destructor may be live at
/// the call site: its cleanup would be skipped. Compute the message in an
/// inner scope, leave it, and only then raise.
package int raiseLuaError(lua_State* L, string msg) nothrow
{
    lua_pushlstring(L, msg.ptr, msg.length);
    return lua_error(L);
}

/// Convert a caught D exception into a Lua error. Safe to call from a catch
/// block, after D unwinding has destroyed the live locals of the `try` body.
package int pushError(lua_State* L, Throwable e) nothrow
{
    auto msg = e.msg;
    if (msg.length == 0)
        msg = "D exception";
    return raiseLuaError(L, msg);
}

/// Comma-separated Lua type names for `count` arguments starting at `start`.
///
/// Used in dispatch error messages so a failed call reports the shapes that
/// were actually supplied, for example `no matching overload for add(string)`.
package string luaArgumentTypes(lua_State* L, int start, size_t count)
{
    import std.array : appender;
    import std.string : fromStringz;

    auto result = appender!string();
    foreach (i; 0 .. count)
    {
        if (i != 0)
            result.put(", ");
        auto idx = start + cast(int) i;
        // Lua 5.3+ reports integers as LUA_TNUMBER; refine the name so the
        // message distinguishes integer arguments from floating-point ones.
        if (lua_type(L, idx) == LUA_TNUMBER && isInteger(L, idx))
            result.put("integer");
        else
            result.put(fromStringz(lua_typename(L, lua_type(L, idx))));
    }
    return result.data;
}

/// Number of parameters matched one-to-one with Lua arguments. A typesafe
/// variadic's final array parameter is filled from the argument tail instead.
package template fixedParamCount(alias F)
{
    static if (variadicFunctionStyle!F == Variadic.typesafe)
        enum fixedParamCount = Parameters!F.length - 1;
    else
        enum fixedParamCount = Parameters!F.length;
}

/// A `LuaState` parameter is supplied by the wrapper, not by Lua.
package template isInjectedParameter(T)
{
    enum isInjectedParameter = is(Unqual!T == LuaState);
}

/// Ordinal of parameter `i` among Lua-supplied (non-injected) parameters.
package template luaParamOrdinal(alias F, size_t i)
{
    static if (i == 0)
        enum luaParamOrdinal = 0;
    else static if (isInjectedParameter!(Parameters!F[i - 1]))
        enum luaParamOrdinal = luaParamOrdinal!(F, i - 1);
    else
        enum luaParamOrdinal = luaParamOrdinal!(F, i - 1) + 1;
}

private template countLuaParams(alias F, size_t n, size_t i = 0, size_t count = 0)
{
    static if (i == n)
        enum countLuaParams = count;
    else static if (isInjectedParameter!(Parameters!F[i]))
        enum countLuaParams = countLuaParams!(F, n, i + 1, count);
    else
        enum countLuaParams = countLuaParams!(F, n, i + 1, count + 1);
}

/// Number of Lua-supplied parameters in the fixed (non-variadic) part.
package template luaFixedCount(alias F)
{
    enum luaFixedCount = countLuaParams!(F, fixedParamCount!F);
}

/// Smallest acceptable Lua argument count, derived from D default arguments.
/// Parameters before the last non-default parameter are required.
package template requiredParamCount(alias F, size_t i = 0, size_t required = 0)
{
    static if (i == fixedParamCount!F)
        enum requiredParamCount = required;
    else static if (isInjectedParameter!(Parameters!F[i]))
        enum requiredParamCount = requiredParamCount!(F, i + 1, required);
    else
    {
        static if (is(ParameterDefaults!F[i] == void))
            enum requiredParamCount =
                requiredParamCount!(F, i + 1, luaParamOrdinal!(F, i) + 1);
        else
            enum requiredParamCount = requiredParamCount!(F, i + 1, required);
    }
}

/// True when the function's variadic style can be marshalled from Lua.
package template bindableVariadic(alias F)
{
    static if (isRawLuaFunction!F)
        enum bindableVariadic = true;
    else static if (__traits(compiles, variadicFunctionStyle!F))
        enum bindableVariadic = variadicFunctionStyle!F == Variadic.no
                             || variadicFunctionStyle!F == Variadic.typesafe;
    else
        enum bindableVariadic = false;
}

/// True when `T` is a raw Lua C callback type: `int(lua_State*)`.
///
/// Such callbacks receive the Lua stack directly, so they can accept any
/// number of Lua arguments (the C-style variadic escape hatch). Both function
/// types (`typeof(someFunction)`) and function pointer types match.
package template isRawLuaFunctionType(T)
{
    static if (!is(T == delegate)
               && __traits(compiles, Parameters!T)
               && __traits(compiles, ReturnType!T))
        enum isRawLuaFunctionType =
            Parameters!T.length == 1
            && is(Unqual!(Parameters!T[0]) == lua_State*)
            && is(ReturnType!T == int);
    else
        enum isRawLuaFunctionType = false;
}

/// True when `F` names a raw Lua C callback.
package template isRawLuaFunction(alias F)
{
    static if (__traits(compiles, typeof(F)))
        enum isRawLuaFunction = isRawLuaFunctionType!(typeof(F));
    else
        enum isRawLuaFunction = false;
}

/// Element type of a D typesafe variadic parameter.
package template typesafeVariadicElement(alias F)
{
    alias P = Parameters!F[$ - 1];
    alias typesafeVariadicElement = Unqual!(typeof(P.init[0]));
}

/// Push a D call result onto the Lua stack. A `std.typecons.Tuple` or
/// `LuaResults` becomes multiple Lua return values; any other value becomes one.
package int pushCallResult(R)(LuaState state, auto ref R value)
{
    static if (is(Unqual!R == LuaResults))
    {
        foreach (result; value.values)
            pushTo(state, result);
        return cast(int) value.values.length;
    }
    else static if (isInstanceOf!(Tuple, Unqual!R))
    {
        static foreach (i; 0 .. Unqual!R.length)
            pushTo(state, value[i]);
        return cast(int) Unqual!R.length;
    }
    else
    {
        pushTo(state, value);
        return 1;
    }
}

/// Fill a tuple of D arguments from Lua stack slots starting at `startIdx`.
/// Missing trailing arguments take their D default values; a typesafe
/// variadic tail is collected into an array.
package void fillCallArgs(alias F)(LuaState state, ref Tuple!(Parameters!F) args,
                                   size_t nargs, int startIdx)
{
    enum fixed = fixedParamCount!F;
    static foreach (i, P; Parameters!F)
    {{
        static if (isInjectedParameter!P)
            args[i] = state;
        else static if (i < fixed)
        {
            enum p = luaParamOrdinal!(F, i);
            static if (p < requiredParamCount!F)
                args[i] = popFrom!(Unqual!P)(state, startIdx + cast(int) p);
            else
            {
                if (p < nargs)
                    args[i] = popFrom!(Unqual!P)(state, startIdx + cast(int) p);
                else
                    args[i] = ParameterDefaults!F[i];
            }
        }
        else
        {
            alias E = typesafeVariadicElement!F;
            enum p = luaParamOrdinal!(F, i);
            auto count = nargs > p ? nargs - p : 0;
            E[] values;
            values.length = count;
            foreach (k; 0 .. count)
                values[k] = popFrom!E(state, startIdx + cast(int)(p + k));
            args[i] = values;
        }
    }}
}
