/// Automatic Lua library binding for D modules.
///
/// `registerModule!someModule(L, "name")` creates a global table containing
/// every public function in `someModule`. Overloads with the same name share
/// one Lua function and are selected by arity and Lua argument types.
module lunarbind.module_;

import lunarbind.raw;
import lunarbind.state;
import lunarbind.conv : pushTo;
import lunarbind.dispatch : fillCallArgs, isRawLuaFunction, luaArgumentTypes,
                            pushCallResult, raiseLuaError;
import lunarbind.function_ : pushDelegate, pushFunction;
import lunarbind.object : LuaClass, LuaStruct, callMatches, callableBindable,
                          overloadBindable;
import lunarbind.export_ : isLuaExportedMember, luaMemberName, luaNameOf,
                         luaTypeName;
import lunarbind.table : LuaTable;

import std.string : toStringz;
import std.traits : Parameters, ReturnType, isSomeFunction;
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
            callableBindable!(__traits(getOverloads, Module, member)[i])
            || anyModuleOverloadBindable!(Module, member, i + 1);
    else
        enum anyModuleOverloadBindable = false;
}

package extern(C) int functionSetThunk(alias Parent, string member)(lua_State* L) nothrow
{
    string errorMessage;
    try
    {
        {
            auto state = LuaState.wrap(L);
            auto nargs = cast(size_t) lua_gettop(L);

            static foreach (i, F; __traits(getOverloads, Parent, member))
            {{
                static if (overloadBindable!F && !isRawLuaFunction!F)
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

            // Raw Lua callbacks consume the stack themselves and have no fixed
            // arity, so they are the last resort after typed overloads.
            static foreach (i, F; __traits(getOverloads, Parent, member))
            {{
                static if (callableBindable!F && isRawLuaFunction!F)
                    return F(L);
            }}

            errorMessage = "no matching overload for "
                         ~ luaMemberName!(Parent, member)
                         ~ "(" ~ luaArgumentTypes(L, 1, nargs) ~ ")";
        }
    }
    catch (Throwable e)
    {
        errorMessage = e.msg.length ? e.msg : "D exception";
    }
    // `state` is gone here; lua_error may longjmp safely.
    return raiseLuaError(L, errorMessage);
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

/// Create a table containing every exported function in `Module`.
///
/// This is the table-building half of `registerModule`: the result is not
/// registered as a global, so it can be nested in another table or kept in D.
/// Filtering and overload rules are identical to `registerModule`.
LuaTable moduleTable(alias Module)(LuaState state)
{
    state.ensureOpen();
    StackGuard guard = StackGuard(state);
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
    state.pop(1);
    return LuaTable(ref_);
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
    auto table = moduleTable!Module(state);
    table.push();
    state.setGlobalChecked(name);
    return table;
}

/// Create an enum table without registering a global.
///
/// The table maps member names to their base values. No reverse mapping is
/// created. Members can be renamed with `@LuaExport("name")` or hidden with
/// `@LuaExport(skip: true)`.
LuaTable enumTable(E)(LuaState state)
{
    static assert(is(E == enum), "lunarbind: enumTable requires an enum type");

    auto table = LuaTable.create(state, 0,
                                 cast(int) __traits(allMembers, E).length);
    static foreach (member; __traits(allMembers, E))
    {{
        static if (isLuaExportedMember!(E, member))
            table.set(luaMemberName!(E, member), __traits(getMember, E, member));
    }}
    return table;
}

private template globalOverloadCount(alias Symbol)
{
    static if (__traits(compiles, __traits(parent, Symbol))
               && __traits(compiles, __traits(identifier, Symbol))
               && __traits(compiles,
                           __traits(getOverloads,
                                    __traits(parent, Symbol),
                                    __traits(identifier, Symbol))))
        enum globalOverloadCount =
            __traits(getOverloads,
                     __traits(parent, Symbol),
                     __traits(identifier, Symbol)).length;
    else
        enum globalOverloadCount = 0;
}

/// Compose a Lua table from D symbols without creating a global.
///
/// `LuaModule` is the incremental counterpart to `registerModule` and `toLua`:
/// it can mix functions, overload sets, classes, structs, enums and values
/// from different D modules in one table. Methods return `this`, so calls can
/// be chained. Use `setGlobal` to expose the finished table:
///
/// ```d
/// auto module = LuaModule.create(L)
///     .addFunction!add("add")
///     .addClass!Player("Player")
///     .set("version", 2)
///     .setGlobal("game");
/// ```
struct LuaModule
{
    private LuaTable _table;
    private LuaState _state;

    private this(LuaTable table, LuaState state)
    {
        _table = table;
        _state = state;
    }

    /// Create an empty module table.
    static LuaModule create(LuaState state, int arrayHint = 0,
                            int recordHint = 0)
    {
        return LuaModule(LuaTable.create(state, arrayHint, recordHint), state);
    }

    /// The underlying table handle.
    LuaTable table() { return _table; }
    LuaRef ref_() { return _table.ref_(); }
    /// Registry reference handle for the module table.
    @property LuaRef reference() { return _table.ref_(); }
    LuaState state() { return _state; }

    /// Push the module table onto the Lua stack.
    void push()
    {
        _state.ensureOpen();
        _table.push();
    }

    /// Expose the module as a global table.
    LuaTable setGlobal(string name)
    {
        _state.ensureOpen();
        _table.push();
        _state.setGlobalChecked(name);
        return _table;
    }

    /// Set a field to a runtime value.
    LuaModule set(T)(string name, auto ref T value)
    {
        _state.ensureOpen();
        auto savedTop = _state.top();
        scope(failure) _state.setTop(savedTop);
        pushTo(_state, value);
        setTop(name);
        return this;
    }

    /// Add a function or overload set.
    LuaModule addFunction(alias Symbol)(string name = luaNameOf!Symbol)
    {
        _state.ensureOpen();
        static if (globalOverloadCount!Symbol > 1)
            pushFunctionSet!(__traits(parent, Symbol),
                             __traits(identifier, Symbol))(_state);
        else static if (__traits(compiles, typeof(Symbol))
                        && isSomeFunction!(typeof(Symbol)))
        {
            static if (is(typeof(Symbol) == function))
                pushFunction!Symbol(_state, name);
            else
                pushDelegate(_state, Symbol, name);
        }
        else
            pushDelegate(_state, Symbol, name);
        setTop(name);
        return this;
    }

    /// Add a class type table (constructor and static/instance methods).
    LuaModule addClass(alias T)(string name = luaTypeName!T)
    {
        static assert(is(T == class),
                      "lunarbind: addClass requires a class type");
        _state.ensureOpen();
        auto table = LuaClass!T.createTable(_state);
        table.push();
        setTop(name);
        return this;
    }

    /// Add a struct type table (static methods; no constructor).
    LuaModule addStruct(alias S)(string name = luaTypeName!S)
    {
        static assert(is(S == struct),
                      "lunarbind: addStruct requires a struct type");
        _state.ensureOpen();
        auto table = LuaStruct!S.createTable(_state);
        table.push();
        setTop(name);
        return this;
    }

    /// Add an enum table.
    LuaModule addEnum(alias E)(string name = luaTypeName!E)
    {
        static assert(is(E == enum),
                      "lunarbind: addEnum requires an enum type");
        _state.ensureOpen();
        auto table = enumTable!E(_state);
        table.push();
        setTop(name);
        return this;
    }

    /// Add every exported function of `Module` as a nested table.
    LuaModule addModule(alias Module)(string name = luaNameOf!Module)
    {
        _state.ensureOpen();
        auto table = moduleTable!Module(_state);
        table.push();
        setTop(name);
        return this;
    }

    /// Add a compile-time value.
    LuaModule addValue(alias Symbol)(string name = luaNameOf!Symbol)
    {
        _state.ensureOpen();
        auto savedTop = _state.top();
        scope(failure) _state.setTop(savedTop);
        pushTo(_state, Symbol);
        setTop(name);
        return this;
    }

    private void setTop(string name)
    {
        // The value to store is on top of the stack.
        auto valueIndex = _state.top();
        scope(exit) _state.setTop(valueIndex - 1);
        _table.push();                                          // [value, table]
        auto tableIndex = valueIndex + 1;
        lua_pushlstring(_state.handle, name.ptr, name.length);  // [value, table, key]
        lua_pushvalue(_state.handle, valueIndex);               // [value, table, key, value]
        setTableEntry(_state, tableIndex);
    }
}
