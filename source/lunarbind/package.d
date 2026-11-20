/// lunarbind: a transparent, layer-based D <-> Lua binding.
///
/// Public API:
///   - `LuaState` shared state handle, selective `LuaLib` loading, GC controls
///     and stack primitives
///   - `@nogc` primitive push/stack/table paths and `LuaValue.pushUnchecked`
///   - `LuaTable` / `LuaFunction` typed handles
///   - `LuaThread` coroutine create/adopt/resume/resumeFrom/status handle
///   - `LuaValue` dynamic value
///   - `pushTo` / `popFrom` conversion functions
///   - D `Tuple` and `LuaResults` results expand into multiple Lua return
///     values
///   - `LuaState` parameters are injected into bound D callbacks
///   - `LuaClass!T` D-class <-> Lua userdata binding
///   - `LuaStruct!S` D-struct <-> mutable Lua userdata box binding
///   - `toLua` unified registration for functions, classes, struct type tables,
///     modules, enums and values
///   - `LuaModule` incremental table builder and non-global `moduleTable` /
///     `enumTable` / `createTable` helpers
///   - `@LuaExport` naming, member filtering and stub descriptions
///   - `luaStubs` / `LuaStubBuilder` EmmyLua declaration generation with
///     custom-codec type overrides
///   - `registerFunction` / `registerLibrary` callback registration, including
///     raw `lua_CFunction` callbacks for arbitrary/C-style variadic arguments
module lunarbind;

public import lunarbind.types;
public import lunarbind.raw;
public import lunarbind.state;
public import lunarbind.value;
public import lunarbind.conv;
public import lunarbind.table;
public import lunarbind.function_;
public import lunarbind.module_;
public import lunarbind.coroutine;
public import lunarbind.object;
public import lunarbind.export_;
public import lunarbind.bind;
public import lunarbind.stub;

version (unittest)
    public import lunarbind.tests;


