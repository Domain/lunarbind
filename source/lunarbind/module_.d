/// Automatic Lua library binding for D modules.
///
/// `registerModule!someModule(L, "name")` creates a global table containing
/// every public function in `someModule`. Overloads with the same name share
/// one Lua function and are selected by arity and Lua argument types.
module lunarbind.module_;

import lunarbind.raw;
static import raw = lunarbind.raw;
import lunarbind.state;
import lunarbind.dispatch : fillCallArgs, pushCallResult;
import lunarbind.object : callMatches, overloadBindable;
import lunarbind.export_ : isLuaExportedMember, luaMemberName, luaNameOf;
import lunarbind.table : LuaTable;

import std.string : toStringz;
import std.traits : Parameters, ReturnType;
import std.typecons : Tuple;

// A member is exposed when at least one of its overloads is a public function
// whose parameters and result can be marshalled. Non-function members (and
// function templates that cannot be instantiated without explicit arguments)
// are ignored by the `Parameters!F` screen inside `overloadBindable`.
private template moduleMemberBindable(alias Module, string member)
{
    static if (member == "main" || !isLuaExportedMember!(Module, member))
        enum moduleMemberBindable = false;
    else static if (__traits(compiles, __traits(getOverloads, Module, member)))
        enum moduleMemberBindable = anyModuleOverloadBindable!(Module, member);
    else
        enum moduleMemberBindable = false;
}

private template anyModuleOverloadBindable(alias Module, string member, size_t i = 0)
{
    static if (i < __traits(getOverloads, Module, member).length)
        enum anyModuleOverloadBindable =
            overloadBindable!(__traits(getOverloads, Module, member)[i])
            || anyModuleOverloadBindable!(Module, member, i + 1);
    else
        enum anyModuleOverloadBindable = false;
}

package extern(C) int functionSetThunk(alias Parent, string member)(lua_State* L) nothrow
{
    try
    {
        auto state = LuaState.wrap(L);
        auto nargs = cast(size_t) lua_gettop(L);

        static foreach (i, F; __traits(getOverloads, Parent, member))
        {{
            static if (overloadBindable!F)
            {
                if (callMatches!F(state, 1, nargs))
                {
                    Tuple!(Parameters!F) args;
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
            }
        }}

        auto msg = "no matching overload for " ~ luaMemberName!(Parent, member);
        lua_pushlstring(L, msg.ptr, msg.length);
        return lua_error(L);
    }
    catch (Throwable e)
    {
        lua_pushlstring(L, e.msg.ptr, e.msg.length);
        return lua_error(L);
    }
}

/// Push a set of same-named functions as one Lua function.
///
/// The wrapper selects an overload by arity and Lua argument types, using the
/// same rules as `registerFunction`. `Parent` is normally a module, but any
/// symbol whose `__traits(getOverloads, Parent, member)` yields callable
/// functions works.
package void pushFunctionSet(alias Parent, string member)(LuaState state)
{
    pushCFunction(state.handle, &functionSetThunk!(Parent, member));
}

/// Bind every public function in `Module` as a field of a new global table.
///
/// Private members, `main`, non-functions and function templates that cannot
/// be instantiated from Lua are ignored. Public overloads with the same name
/// are dispatched by arity and Lua argument types, with the same default
/// argument, typesafe variadic and `LuaState` injection rules as
/// `registerFunction`. `@LuaExport("name")` renames a function and
/// `@LuaExport(skip: true)` hides it. The table name defaults to the module
/// identifier or its `@LuaExport("name")`. Returns a handle to the new table.
LuaTable registerModule(alias Module)(LuaState state,
                                      string name = luaNameOf!Module)
{
    lua_createtable(state.handle, 0, 0);
    static foreach (member; __traits(allMembers, Module))
    {{
        static if (moduleMemberBindable!(Module, member))
        {
            pushFunctionSet!(Module, member)(state);
            lua_setfield(state.handle, -2,
                         toStringz(luaMemberName!(Module, member)));
        }
    }}
    auto ref_ = LuaRef.make(state, -1);
    raw.setGlobal(state.handle, toStringz(name));
    return LuaTable(ref_);
}
