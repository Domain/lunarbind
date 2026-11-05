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
///   - `toLua` unified registration for functions, classes, modules, enums and values
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
public import lunarbind.bind;

version (unittest)
    public import lunarbind.tests;


