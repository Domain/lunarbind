/// lunarbind: a transparent, layer-based D <-> Lua binding.
///
/// Public API:
///   - `LuaState` shared state handle and stack primitives
///   - `LuaTable` / `LuaFunction` typed handles
///   - `LuaThread` coroutine create/resume/status handle
///   - `LuaValue` dynamic value
///   - `pushTo` / `popFrom` conversion functions
///   - D `Tuple` results expand into multiple Lua return values
///   - `LuaState` parameters are injected into bound D callbacks
///   - `LuaClass!T` D-class <-> Lua userdata binding
///   - `LuaStruct!S` D-struct <-> mutable Lua userdata box binding
///   - `toLua` unified registration for functions, classes, struct type tables,
///     modules, enums and values
///   - `@LuaExport` naming and member filtering for automatic tables
///   - `luaStubs` / `LuaStubBuilder` EmmyLua declaration generation
///   - `registerFunction` / `registerLibrary` callback registration
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


