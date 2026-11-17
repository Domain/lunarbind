# v0.2 API review

This document collects API changes proposed for v0.2. Each item lists the
current behavior, the proposed change and the migration path. Items that have
already landed are marked as such.

The guiding rule is additive-first: v0.2 adds aliases and new entry points,
marks old spellings deprecated, and only removes them in a later release. No
existing binding, codec, registration helper or raw C API name is removed in
v0.2.

## 1. Checked globals by default

**Current.** `LuaState.setGlobal(name, value)` is the raw fast path. It does
not call `ensureOpen` and does not protect a `_G.__newindex` metamethod. The
safe variant is the longer `setGlobalChecked`.

Most callers want the safe variant, so the short name is the unsafe one.

**Proposal.**

- Add `setGlobalUnchecked` as an alias for today's raw `setGlobal`.
- Deprecate the raw `setGlobal` spelling in v0.2.
- In v0.3, rename `setGlobalChecked` to `setGlobal` and remove the deprecated
  raw spelling.

`LuaState.getGlobal` is already the checked read path; no change is needed.

## 2. Deprecate `ref_`

**Current.** `LuaRef.ref_`, `LuaTable.ref_`, `LuaFunction.ref_`,
`LuaThread.ref_` and `LuaModule.ref_` expose the registry handle.

**Proposal.** The `reference` property now exists on all handle types; v0.2
marks `ref_` deprecated. The trailing underscore is a workaround for the `ref`
keyword, and `reference` reads better in chained expressions such as
`table.reference`.

`LuaRef.reference` currently returns the registry id (`int`), while the handle
types return the underlying `LuaRef`. That two-level meaning is intentional but
worth documenting; if it causes confusion, v0.3 can rename the `int` accessor
to `registryId`.

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

## 4. `raw.getMetatable` / `raw.setMetatable`

**Current.** `lunarbind.raw` declares both helpers, but nothing in lunarbind
uses them.

**Proposal.** Keep them. `raw` is a public mirror of the C API, the helpers are
small inline wrappers, and removing them would break users who call the raw
layer directly. If the maintenance cost ever matters, deprecate them for one
release before removal.

## 5. `LuaTable.length` and `__len`

**Current.** `LuaTable.length` is a raw `@nogc nothrow` path that ignores
`__len` and assumes a live state.

**Proposal.** Add `lengthOf()` as the checked variant that honors `__len` and
throws on a closed state or raising metamethod. Keep `length` as the documented
fast path. A later release can rename `length` to `rawLength` if the fast path
proves to be the rarer choice.

## 6. Status and type helpers

**Current.** `LuaStatus` values follow the selected Lua version, and
`LuaType.function_` carries a trailing underscore because `function` is a D
keyword.

**Proposal.** Add `LuaStatus.toString` and `LuaStatus.fromInt` so version
differences stay visible at the edges instead of leaking into user code. Leave
`LuaType.function_` alone; the underscore is the standard D workaround and
renaming it would touch every dispatch site for little gain.

## 7. Documentation and stubs

Not API changes, but part of the same review:

- Document the checked/raw split in one table in the README instead of
  scattering it across sections.
- Keep the stub generator's custom-codec overrides keyed by `typeid(T)`; that
  has proven sufficient for unions and other non-default representations.
- EmmyLua has no deprecation marker that maps cleanly to `@LuaExport(skip: true)`
  because skipped members are hidden entirely. A `deprecated` flag on
  `@LuaExport` is out of scope for v0.2.
