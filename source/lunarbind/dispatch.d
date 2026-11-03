/// Internal call-shape helpers shared by class, struct and function bindings.
///
/// D default arguments and typesafe variadics are resolved here so every
/// binding path accepts the same Lua calls.
module lunarbind.dispatch;

import lunarbind.state;
import lunarbind.conv;

import std.traits : Parameters, ParameterDefaults, variadicFunctionStyle,
                    Variadic, Unqual, isInstanceOf;
import std.typecons : Tuple;

/// Number of parameters matched one-to-one with Lua arguments. A typesafe
/// variadic's final array parameter is filled from the argument tail instead.
package template fixedParamCount(alias F)
{
    static if (variadicFunctionStyle!F == Variadic.typesafe)
        enum fixedParamCount = Parameters!F.length - 1;
    else
        enum fixedParamCount = Parameters!F.length;
}

/// Smallest acceptable Lua argument count, derived from D default arguments.
/// Parameters before the last non-default parameter are required.
package template requiredParamCount(alias F, size_t i = 0, size_t required = 0)
{
    static if (i == fixedParamCount!F)
        enum requiredParamCount = required;
    else
    {
        static if (is(ParameterDefaults!F[i] == void))
            enum requiredParamCount = requiredParamCount!(F, i + 1, i + 1);
        else
            enum requiredParamCount = requiredParamCount!(F, i + 1, required);
    }
}

/// True when the function's variadic style can be marshalled from Lua.
package template bindableVariadic(alias F)
{
    static if (__traits(compiles, variadicFunctionStyle!F))
        enum bindableVariadic = variadicFunctionStyle!F == Variadic.no
                             || variadicFunctionStyle!F == Variadic.typesafe;
    else
        enum bindableVariadic = false;
}

/// Element type of a D typesafe variadic parameter.
package template typesafeVariadicElement(alias F)
{
    alias P = Parameters!F[$ - 1];
    alias typesafeVariadicElement = Unqual!(typeof(P.init[0]));
}

/// Push a D call result onto the Lua stack. A `std.typecons.Tuple` becomes
/// multiple Lua return values; any other value becomes one.
package int pushCallResult(R)(LuaState state, auto ref R value)
{
    static if (isInstanceOf!(Tuple, Unqual!R))
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
        static if (i < fixed)
        {
            static if (i < requiredParamCount!F)
                args[i] = popFrom!(Unqual!P)(state, startIdx + cast(int) i);
            else
            {
                if (i < nargs)
                    args[i] = popFrom!(Unqual!P)(state, startIdx + cast(int) i);
                else
                    args[i] = ParameterDefaults!F[i];
            }
        }
        else
        {
            alias E = typesafeVariadicElement!F;
            auto count = nargs - i;
            E[] values;
            values.length = count;
            foreach (k; 0 .. count)
                values[k] = popFrom!E(state, startIdx + cast(int)(i + k));
            args[i] = values;
        }
    }}
}
