/// Unified one-call registration facade.
///
/// `toLua!Symbol(L)` exports a D symbol as a Lua global. The symbol's kind is
/// detected at compile time:
///
/// | D symbol                 | Lua value            | returned handle |
/// |--------------------------|----------------------|-----------------|
/// | function / overload set  | function             | `LuaFunction`   |
/// | raw `lua_CFunction`      | function             | `LuaFunction`   |
/// | delegate / function ptr  | function             | `LuaFunction`   |
/// | class                    | class table          | `LuaTable`      |
/// | struct                   | static-method table  | `LuaTable`      |
/// | module                   | function table       | `LuaTable`      |
/// | enum type                | `{ member = value }` | `LuaTable`      |
/// | instance / plain value   | value                | `LuaRef`        |
///
/// The default name comes from `__traits(identifier, Symbol)` unless the
/// symbol carries `@LuaExport("name")`. Runtime values have no symbol name, so
/// they require an explicit name: `toLua(L, value, "name")`.
///
/// Struct type tables expose public static methods only; struct values are
/// bound separately and remain value-only. Members marked
/// `@LuaExport(skip: true)` are omitted from automatic tables, while an
/// explicit `toLua!Symbol` call still binds them.
module lunarbind.bind;

static import raw = lunarbind.raw;
import lunarbind.state;
import lunarbind.conv;
import lunarbind.table : LuaTable;
import lunarbind.function_ : LuaFunction, pushFunction, pushDelegate;
import lunarbind.module_ : enumTable, pushFunctionSet, registerModule;
import lunarbind.object : LuaClass, LuaStruct;
import lunarbind.export_ : isLuaExportedMember, luaMemberName, luaNameOf,
                         luaTypeName;

import std.string : toStringz;
import std.traits : isSomeFunction;

// ---------------------------------------------------------------------------
// Compile-time symbol classification
// ---------------------------------------------------------------------------

/// True when `Symbol` names a type (class, struct, enum, ...).
package template isTypeSymbol(alias Symbol)
{
    enum isTypeSymbol = __traits(compiles, { void probe(Symbol __value); });
}

/// True when `Symbol` names a module.
package template isModuleSymbol(alias Symbol)
{
    enum isModuleSymbol =
        __traits(compiles, __traits(allMembers, Symbol)) && !isTypeSymbol!Symbol;
}

/// Number of overloads when `Symbol` is a module-level function set, else 0.
package template overloadSetLength(alias Symbol)
{
    static if (__traits(compiles, __traits(parent, Symbol))
               && isModuleSymbol!(__traits(parent, Symbol))
               && __traits(compiles,
                           __traits(getOverloads,
                                    __traits(parent, Symbol),
                                    __traits(identifier, Symbol))))
        enum overloadSetLength =
            __traits(getOverloads,
                     __traits(parent, Symbol),
                     __traits(identifier, Symbol)).length;
    else
        enum overloadSetLength = 0;
}

// ---------------------------------------------------------------------------
// Registration helpers
// ---------------------------------------------------------------------------

private LuaRef makeGlobalRef(LuaState state, string name)
{
    // The value to register is on top; restore the caller's stack if making
    // the reference or setting the global throws.
    auto savedTop = state.top() - 1;
    scope(failure) state.setTop(savedTop);
    auto ref_ = LuaRef.make(state, -1);
    state.pop(1);
    ref_.pushInto(state);
    state.setGlobalChecked(name);
    return ref_;
}

private LuaFunction makeGlobalFunction(LuaState state, string name)
{
    return LuaFunction(makeGlobalRef(state, name));
}

private LuaFunction bindFunction(alias Symbol)(LuaState state, string name)
{
    static if (is(typeof(Symbol) == function))
        pushFunction!Symbol(state);
    else
        pushDelegate(state, Symbol);
    return makeGlobalFunction(state, name);
}

private LuaFunction bindOverloadSet(alias Parent, string member)(LuaState state, string name)
{
    pushFunctionSet!(Parent, member)(state);
    return makeGlobalFunction(state, name);
}

private LuaTable bindClass(alias T)(LuaState state, string name)
{
    return LuaClass!T.bind(state, name);
}

private LuaTable bindStruct(alias S)(LuaState state, string name)
{
    return LuaStruct!S.bind(state, name);
}

private LuaTable bindModule(alias Module)(LuaState state, string name)
{
    return registerModule!Module(state, name);
}

private LuaRef bindValue(alias Symbol)(LuaState state, string name)
{
    auto savedTop = state.top();
    scope(failure) state.setTop(savedTop);
    pushTo(state, Symbol);
    return makeGlobalRef(state, name);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Export a compile-time symbol as a Lua global.
///
/// The overload is selected by symbol kind; see the module documentation.
/// The default name is the symbol's identifier or its `@LuaExport("name")`,
/// so `toLua!add(L)` creates the global `add`, while `toLua!add(L, "add2")`
/// renames it.
auto toLua(alias Symbol)(LuaState state, string name = luaNameOf!Symbol)
{
    state.ensureOpen();
    static if (isTypeSymbol!Symbol)
    {
        static if (is(Symbol == class))
            return bindClass!Symbol(state, name);
        else static if (is(Symbol == struct))
            return bindStruct!Symbol(state, name);
        else static if (is(Symbol == enum))
            return registerEnum!Symbol(state, name);
        else static if (is(Symbol == union))
            static assert(0,
                          "lunarbind: toLua cannot bind the union type " ~ Symbol.stringof
                          ~ "; register a codec and bind a value with toLua(L, value, name)");
        else
            static assert(0, "lunarbind: toLua does not support type " ~ Symbol.stringof);
    }
    else static if (isModuleSymbol!Symbol)
    {
        return bindModule!Symbol(state, name);
    }
    else static if (overloadSetLength!Symbol > 1)
    {
        return bindOverloadSet!(__traits(parent, Symbol),
                                __traits(identifier, Symbol))(state, name);
    }
    else static if (__traits(compiles, typeof(Symbol))
                    && isSomeFunction!(typeof(Symbol)))
    {
        return bindFunction!Symbol(state, name);
    }
    else static if (__traits(compiles, typeof(Symbol)))
    {
        return bindValue!Symbol(state, name);
    }
    else
    {
        static assert(0, "lunarbind: toLua cannot bind " ~ Symbol.stringof);
    }
}

/// Export a runtime value as a Lua global. `name` is required because an
/// expression has no compile-time identifier.
auto toLua(T)(LuaState state, auto ref T value, string name)
{
    state.ensureOpen();
    static if (isSomeFunction!T)
    {
        pushDelegate(state, value);
        return makeGlobalFunction(state, name);
    }
    else
    {
        auto savedTop = state.top();
        scope(failure) state.setTop(savedTop);
        pushTo(state, value);
        return makeGlobalRef(state, name);
    }
}

/// Bind an enum type as a global table mapping member names to their base
/// integer values. No reverse mapping is created. The table name defaults to
/// the enum identifier or its `@LuaExport("name")`; members can be renamed
/// with `@LuaExport("name")` or hidden with `@LuaExport(skip: true)`.
LuaTable registerEnum(E)(LuaState state, string name = luaTypeName!E)
{
    auto table = enumTable!E(state);
    table.push();
    state.setGlobalChecked(name);
    return table;
}
