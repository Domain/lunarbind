# Changelog

All notable changes to lunarbind are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
semantic versioning while the public API is pre-1.0.

## [Unreleased]

### Added

- `LuaResults` return values expand a runtime-sized list of `LuaValue`s into
  multiple Lua results, complementing fixed-size `Tuple` returns. Class and
  struct methods, module functions and runtime delegates share the same path.
- `LuaFunction.callWith` calls a Lua function with a runtime-sized
  `LuaValue[]` argument list, pushing each entry as a separate argument.

## [0.3.0] - 2026-11-20

This is the first tagged release. It covers the initial binding core plus the
v0.2 and v0.3 API reviews.

### Added

- Transparent D ↔ Lua binding for Lua 5.1–5.5 and LuaJIT 2.1, with runtime
  smoke tests on Windows and Linux.
- `toLua` registration for functions, classes, struct types, enums, modules
  and values, alongside the lower-level registration helpers.
- `LuaClass!T` and `LuaStruct!S` userdata bindings with metatables, methods,
  fields, properties, constructors and D object identity.
- Per-state type codecs via `registerCodec`, including union support.
- `LuaModule` incremental table builder and non-global `moduleTable`,
  `enumTable` and `createTable` helpers.
- `LuaThread` coroutine create/adopt/resume/status handles.
- Weak-key and weak-value tables through `LuaTable.createWeak`.
- `@LuaExport` naming, descriptions and member filtering, plus `luaStubs` /
  `LuaStubBuilder` EmmyLua declaration generation and `tools/gen_stubs.d`.
- Selective standard-library loading with `LuaLib` and GC parameter controls.
- Checked and raw paths for globals, table entries, table length and value
  pushing, including `@nogc` primitive stack and table operations.
- `LuaStatus` names, `luaStatusFromInt`, and `LuaRef.registryId`.
- Coverage-guided libFuzzer target (`fuzz/fuzz_target.d`, `tools/fuzz.sh`)
  and an AddressSanitizer CI job.
- Benchmark suite (`bench/bench.d`) for binding overhead comparisons.

### Changed

- `LuaState.setGlobal` is now the checked write path; the raw fast path is
  `setGlobalUnchecked`, and `setGlobalChecked` remains an alias.
- Dispatch errors name the symbol and the supplied Lua argument types; arity
  errors use the name the function was registered under.
- `LuaTable.lengthOf` checks `__len` on Lua 5.2+, while `length` stays raw.
- Handle types expose `reference`, and `LuaRef` exposes `registryId`.

### Removed

- The deprecated `ref_` properties on `LuaRef`, `LuaTable`, `LuaFunction`,
  `LuaThread` and `LuaModule`; use `reference` instead.

### Fixed

- Lua `longjmp` errors no longer skip D destructors or leak state references.
- Cross-state reference use, dead handles and stack imbalance are rejected.
- Protected metamethod calls keep `__index`, `__newindex`, `__len` and
  `lua_next` failures inside `LuaException` instead of aborting the process.
