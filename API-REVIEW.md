# v0.2 API review

This document collects API changes proposed for v0.2. Each item lists the
current behavior, the proposed change and the migration path. Items that have
already landed are marked as such.

The guiding rule is additive-first: v0.2 adds aliases and new entry points,
marks old spellings deprecated, and only removes them in a later release. No
existing binding, codec, registration helper or raw C API name is removed in
v0.2.

## 1. Checked globals by default (deprecation applied)

**Previous.** `LuaState.setGlobal(name, value)` was the raw fast path. It did
not call `ensureOpen` and did not protect a `_G.__newindex` metamethod. The safe
variant was the longer `setGlobalChecked`.

Most callers want the safe variant, so the short name was the unsafe one.

**Change.**

- `setGlobalUnchecked` is now the explicit raw fast path.
- `setGlobal` is deprecated and forwards to `setGlobalUnchecked`.
- In v0.3, `setGlobalChecked` becomes `setGlobal`; `setGlobalChecked` stays as
  an alias so no call site breaks.

`LuaState.getGlobal` is already the checked read path; no change is needed.

## 2. Deprecate `ref_` (implemented)

**Previous.** `LuaRef.ref_`, `LuaTable.ref_`, `LuaFunction.ref_`,
`LuaThread.ref_` and `LuaModule.ref_` exposed the registry handle.

**Change.** `ref_` is deprecated on all five types in favor of the `reference`
property. The trailing underscore was a workaround for the `ref` keyword, and
`reference` reads better in chained expressions such as `table.reference`.

`LuaRef.reference` returns the registry id (`int`), while the handle types
return the underlying `LuaRef`. That two-level meaning is intentional but worth
documenting; if it causes confusion, v0.3 can rename the `int` accessor to
`registryId`.

## 3. Name-aware arity errors (implemented)

**Previous.** Arity errors used the D identifier of the bound function, for
example `addDefault: expected between 1 and 2 arguments, got 0 arguments`, even
when the function was registered as `add_default`.

**Change.** `pushFunction` and `pushDelegate` now take an optional name, stored
as a Lua string upvalue. `registerFunction`, `registerDelegate`,
`registerLibrary`, `toLua`, `LuaModule.addFunction` and the runtime-delegate
`toLua` overload pass the registration name, so arity errors report the name Lua
callers actually see. The cost is one interned string per registration.

Overload sets keep their existing `no matching overload for <name>(...)`
messages, which already use the Lua member name.

## 4. `raw.getMetatable` / `raw.setMetatable` (resolved: keep)

**Current.** `lunarbind.raw` declares both helpers, but nothing in lunarbind
uses them.

**Proposal.** Keep them. `raw` is a public mirror of the C API, the helpers are
small inline wrappers, and removing them would break users who call the raw
layer directly. If the maintenance cost ever matters, deprecate them for one
release before removal.

## 5. `LuaTable.length` and `__len` (implemented)

**Previous.** `LuaTable.length` was a raw `@nogc nothrow` path that ignored
`__len` and assumed a live state.

**Change.** `LuaTable.lengthOf` is the checked counterpart: it honors `__len`
on Lua 5.2+, throws `LuaException` when the metamethod raises, and
`LuaTypeException` when it does not return an integer. Lua 5.1/LuaJIT have no
table `__len`, so both paths return the raw length there. `length` remains the
documented fast path.

## 6. Status and type helpers (resolved)

**Current.** `LuaStatus` values follow the selected Lua version, and
`LuaType.function_` carries a trailing underscore because `function` is a D
keyword.

**Change.** `LuaStatus.toString` returns a version-independent name and
`luaStatusFromInt` maps a raw C API status code back to the enum, throwing
`LuaArgumentException` for unknown values. `LuaType.function_` is unchanged;
the underscore is the standard D workaround and renaming it would touch every
dispatch site for little gain.

## 7. Documentation and stubs (implemented)

Not API changes, but part of the same review:

- The README now has a "Checked and raw paths" table that lists both entry
  points side by side instead of scattering the split across sections.
- The stub generator's custom-codec overrides stay keyed by `typeid(T)`; that
  has proven sufficient for unions and other non-default representations.
- EmmyLua has no deprecation marker that maps cleanly to `@LuaExport(skip: true)`
  because skipped members are hidden entirely. A `deprecated` flag on
  `@LuaExport` is out of scope for v0.2.
