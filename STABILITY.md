# API stability

**Status: the public API is frozen as of 1.0.0.**

`lunarbind` follows [Semantic Versioning 2.0.0](https://semver.org/). The
public surface described here shipped with 1.0.0. A source-breaking change after
1.0.0 requires a new major version.

## Public modules

The following modules and their public declarations are part of the API:

| Module | Public contents |
| --- | --- |
| `lunarbind` | Package module; re-exports the stable modules below |
| `lunarbind.types` | `LuaStatus`, `LuaType`, status helpers and the exception hierarchy |
| `lunarbind.raw` | Lua C API declarations and version-compatibility helpers |
| `lunarbind.state` | `LuaState`, `LuaLib`, `StackGuard`, `LuaRef` |
| `lunarbind.value` | `LuaValue`, `LuaResults` |
| `lunarbind.conv` | `LuaString`, `LuaCodec`, `registerCodec`, `unregisterCodec`, `pushTo`, `popFrom` |
| `lunarbind.table` | `LuaTable`, `LuaWeakness` |
| `lunarbind.function_` | `LuaFunction` and the callback/registration helpers |
| `lunarbind.module_` | `LuaModule`, `moduleTable`, `registerModule`, `enumTable` |
| `lunarbind.object` | `LuaClass!T`, `LuaStruct!S` |
| `lunarbind.export_` | `@LuaExport` |
| `lunarbind.coroutine` | `LuaThread` |
| `lunarbind.bind` | `toLua`, `registerEnum` |
| `lunarbind.stub` | `luaStubs`, `LuaStubBuilder` |

`import lunarbind;` is the recommended import. Importing a module directly is
also supported; its public declarations carry the same guarantee.

`toLua` is the recommended registration facade. The lower-level helpers
(`registerFunction`, `registerLibrary`, `registerModule`, `LuaClass!T.registerClass`,
`LuaStruct!S.setGlobal`, `LuaModule` and so on) remain supported API, so code
that needs finer control does not have to move to `toLua`.

## The `raw` layer

`lunarbind.raw` is a public, thin mirror of the Lua C API:

- `lua_*` and `luaL_*` declarations track the selected Lua profile
  (`LUA_51` through `LUA_55`, or `LUAJIT`). A name and signature present in a
  profile is stable for that profile.
- The set of names can differ between profiles. Version-specific constants such
  as `LUA_ERRGCMM`, and functions such as `lua_closeslot`, exist only where the
  corresponding Lua version defines them.
- The compatibility helpers (`pcall`, `getGlobal`, `setGlobalString`,
  `pushCFunction`, `newLib`, `loadString`, `setFuncs`, `equal`, `gcParam` and
  the rest) are covered by the same stability guarantee as the rest of the
  public API.

The raw declarations are not an ABI contract. Lua builds differ in calling
conventions and `lua_Number`/`lua_Integer` configuration; DUB builds from
source, so only source compatibility is promised.

## Version-dependent values

`LuaStatus` numeric values intentionally follow the selected Lua version. Use
`LuaStatus.toString` for a version-independent name and `luaStatusFromInt` when
converting a raw status code. Do not persist the numeric values if they must be
read by another Lua profile.

Adding a new enum member (for example for a future Lua version) is treated as
an additive change and may happen in a minor release. Code that must tolerate
new members should use a regular `switch` with a `default` arm; a
`final switch` over a public enum can stop compiling when a member is added.

## Versioning rules

- **Major** releases may remove or rename public symbols and may change
  documented behavior incompatibly.
- **Minor** releases add API and may deprecate existing API. They do not remove
  public symbols or intentionally break source compatibility.
- **Patch** releases contain bug and security fixes only. They do not add
  public API and do not change documented behavior.
- Deprecated symbols are marked with D's `deprecated` attribute and a
  replacement, and remain available for at least one subsequent minor release.
  Removal happens in a major release.
- Release tags use `vMAJOR.MINOR.PATCH`; DUB derives the package version from
  the tag.
- Attributes are part of the contract. A public declaration that is `@nogc`,
  `nothrow`, `pure` or `@safe` today will not lose that attribute in a minor
  release. Checked conversions are documented as allocating because they throw
  typed errors; they are not required to be `@nogc`.
- Exact exception message text, Lua traceback formatting and generated EmmyLua
  output are not frozen. Exception types, the conditions under which they are
  thrown, and the information they carry are stable.

The project is developed and tested against Lua 5.1–5.5 and LuaJIT 2.1 with LDC
and DMD. The supported runtime and compiler matrix may evolve; changes that
affect source compatibility follow the rules above, while new test coverage or
new compatible compiler versions are ordinary minor/patch work.

## Behavioral contracts

These behaviors are part of the frozen API:

- A `LuaState` is a shared handle to a reference-counted state core; handles and
  references created inside a callback keep working after the callback returns.
  Using a reference with a different Lua state throws `LuaStateException`.
- The checked/raw split stays explicit: checked operations validate handles and
  metamethod results, while the documented raw paths (`setGlobalUnchecked`,
  `LuaTable.length`, `LuaTable.setUnchecked`, `LuaValue.pushUnchecked` and the
  `@nogc` stack primitives) keep their fast-path behavior.
- `toLua` returns category-specific handles: `LuaFunction` for functions,
  `LuaTable` for class/struct/module/enum tables, and `LuaRef` for values.
- Binding a class instance does not automatically register the class table.
  Register the class separately with `toLua!T(L)` when Lua needs the type name.
- Struct values are value-only. A struct type table exposes public static
  methods and has no constructor entry point.
- Enum tables map names to values; no reverse value-to-name mapping is
  generated.
- Raw `lua_CFunction` callbacks are bindable as free or module functions, not
  as class or struct members.

## Not public API

The following are implementation details. D may make some of them nameable, but
they are excluded from the stability guarantee and may change at any time:

- `lunarbind.dispatch`, the internal overload-dispatch layer.
- `lunarbind.fuzz`, `lunarbind.tests`, `lunarbind.exportfixture` and
  `lunarbind.rawfixture`.
- Private and package declarations, including `StateCore`, `LuaBoundFunction`,
  `luaCFunctionWrapper`, the reference holder, module constructors generated by
  the compiler, and private fields such as `LuaValue._ref`.
- Source file layout, module-private helpers, internal template names and
  implementation aliases.
- `fuzz/`, `bench/`, `samples/`, `tools/`, test fixtures and generated files
  under `.lua/`.
- The exact text and formatting of generated EmmyLua stubs.

If a piece of the implementation needs to become public API, it will be added
deliberately in a minor release and documented here rather than being relied
on through an internal name.
