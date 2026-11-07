# lunarbind

**A transparent, layered D ↔ Lua binding.** Supports LuaJIT and Lua 5.1–5.5.

> Status: **early scaffold (v0.1)**. The core API, conversion layer, callbacks and
> a first userdata/object model are implemented and compile with LDC 1.43 and
> DMD 2.111 against Lua 5.1–5.5 API profiles. The runtime smoke tests pass
> against Lua 5.1–5.5 and LuaJIT 2.1 on Windows (LDC) and Linux (LDC and DMD)
> using the bundled test scripts. References created inside callbacks share the
> owner state core, and cross-state use is rejected. The public API is not frozen
> yet.

## Why another binding?

The upstream [lumars](https://github.com/Domain/lumars) is a useful, lightweight
embedding wrapper, but its value-semantic `push`/`get` model cannot provide
transparent D-class ↔ Lua-object interoperation. lunarbind is a clean base for
that goal:

- explicit, shared `LuaState` lifetime; refs created inside callbacks share the
  owner's `StateCore`, and cross-state use is rejected;
- registry references with deterministic release (`LuaRef`, `LuaTable`,
  `LuaFunction`);
- one `extern(C)` trampoline per signature for callbacks (never type-punning
  `void*`/delegate internals);
- `pushTo!T` / `popFrom!T` conversion policy instead of a closed `static if`;
- full-userdata based object binding (`LuaClass!T`, `LuaStruct!S`) with D-GC
  rooting;
- weak-key/weak-value tables for caches and identity maps (`LuaWeakness`).

It is a **new codebase**, not a patch on lumars; tests and the EmmyLua
generator can be migrated over time. lumars remains MIT-licensed and is
credited in [LICENSE](LICENSE).

## Layout

```
source/lunarbind/
  raw.d          version-aware Lua C API declarations + compat helpers
  types.d        LuaStatus, LuaType, exceptions
  state.d        StateCore, LuaState, StackGuard, LuaRef, traceback/error helpers
  value.d        LuaValue (dynamic value for untyped edges)
  conv.d         pushTo!T / popFrom!T (primitives, strings, arrays, AAs, Nullable, LuaRef)
  table.d        LuaTable (registry-backed; get/set/opIndex/foreach, weak tables)
  function_.d    LuaFunction call/bind, callback wrappers, delegate boxing, registration
  module_.d      registerModule: bind all public functions in a D module
  bind.d         toLua: unified registration for functions, classes, struct type tables, modules, enums, values
  export_.d      @LuaExport: Lua names and member filtering
  stub.d         luaStubs / LuaStubBuilder: EmmyLua declaration generation
  coroutine.d    LuaThread: create/resume/yield/status coroutine handles
  object.d       LuaClass!T / LuaStruct!S: D objects <-> Lua userdata + metatable
  tests.d        runtime smoke tests (compiled under -unittest)
```

## Quick start

```d
import lunarbind;

class Player
{
    int hp;
    string name;
    this(int hp, string name) { this.hp = hp; this.name = name; }
    void damage(int n) { hp -= n; }
    int health() const { return hp; }
}

void main()
{
    auto L = LuaState.open();

    L.setGlobal("answer", 42);
    assert(L.getGlobal!int("answer") == 42);

    // D function -> Lua
    int add(int a, int b) { return a + b; }
    toLua!add(L);                    // global `add`, default name
    auto values = L.eval("return add(20, 22)");

    // Lua function -> D
    auto mul = L.loadString("return function(a, b) return a * b end").call!LuaValue();
    // or: auto f = L.getGlobal!LuaFunction("mul"); f.call!int(6, 7);

    // D object -> Lua userdata; one call binds the class table (constructor
    // and every public static/instance method), another exports the instance.
    auto player = new Player(100, "bob");
    toLua!Player(L);
    toLua!player(L);
    L.doString("player:damage(5)");
    assert(player.hp == 95);

    // Lua -> new D object
    L.doString("local p = Player(10, 'new'); assert(p.hp == 10)");
}
```

## Unified registration with `toLua`

`toLua` is the recommended facade. It detects the symbol kind at compile time,
uses the symbol's `@LuaExport("name")` or `__traits(identifier, Symbol)` as the
default global name, and returns a handle that matches the category:

| D symbol | Lua value | returned handle |
|---|---|---|
| function / overload set | function | `LuaFunction` |
| delegate / function pointer | function | `LuaFunction` |
| class | class table | `LuaTable` |
| struct | static-method table | `LuaTable` |
| module | function table | `LuaTable` |
| enum type | `{ member = value }` | `LuaTable` |
| instance / plain value | value | `LuaRef` |

```d
toLua!add(L);                     // global add
toLua!add(L, "add2");             // rename
toLua!freePick(L);                // overload set, dispatched by Lua args
toLua!Player(L);                  // class table: Player(...) and methods
toLua!MyStruct(L);                // type table: public static methods only
toLua!player(L);                  // instance global
toLua!(some.module)(L);           // module table, default name = last segment
toLua!Color(L);                   // Color = { red = 0, green = 1, ... }

auto fn = toLua!add(L);           // LuaFunction
auto cls = toLua!Player(L);       // LuaTable
auto ref_ = toLua!player(L);      // LuaRef

// Runtime expressions have no identifier, so the name is required:
toLua(L, 42, "answer");
toLua(L, new Player(10, "bob"), "p");

// UFCS works for both forms:
L.toLua!add("add2");
L.toLua(42, "answer");
```

The low-level APIs (`registerFunction`, `LuaClass!T.registerClass`,
`LuaClass!T.setGlobal`, `registerModule`, `LuaStruct!S.setGlobal`) remain
available. `toLua` is a facade over them:

| Low-level | `toLua` |
|---|---|
| `registerFunction!f(L, "f")` | `toLua!f(L)` |
| `LuaClass!T.registerClass(L, "T")` | `toLua!T(L)` |
| `LuaClass!T.setGlobal(L, "obj", obj)` | `toLua!obj(L)` |
| `registerModule!(m)(L, "m")` | `toLua!m(L)` |
| `registerDelegate(L, "f", dg)` | `toLua(L, dg, "f")` |
| `LuaStruct!S.bind(L, "S")` | `toLua!S(L)` |
| `LuaStruct!S.setGlobal(L, "s", s)` | `toLua!s(L)` |

Instance binding does not implicitly register the class table; call
`toLua!Class(L)` when Lua needs the constructor or static methods. Struct type
tables expose public static methods only; bind struct values separately with
`toLua!value(L)` or `LuaStruct!S.setGlobal`.

`toLua` uses the same default-argument, typesafe-variadic and `LuaState`
injection rules as `registerFunction`. `registerModule!(some.module)(L, "name")`
binds every public function in a D module as one Lua table, including
overloads.

For programmatic composition across modules, `LuaModule` builds a table without
creating globals:

```d
auto game = LuaModule.create(L)
    .addFunction!add("add")
    .addClass!Player("Player")
    .addEnum!Status("Status")
    .addModule!mathlib("math")
    .addValue!buildVersion("buildVersion")
    .set("author", "lunarbind")
    .setGlobal("game");
```

`addFunction`, `addClass`, `addStruct`, `addEnum`, `addModule` and `addValue`
use the same `@LuaExport` defaults as `toLua`; `set` stores a runtime value and
`setGlobal` exposes the finished table. The non-global building blocks
`moduleTable!M(L)`, `enumTable!E(L)`, `LuaClass!T.createTable(L)` and
`LuaStruct!S.createTable(L)` return tables directly for nesting or storage in D.

## Naming and filtering with `@LuaExport`

`@LuaExport` controls the Lua names used by automatic tables: `registerModule`,
`toLua` (including class/struct type tables and enum tables), `LuaClass!T.bind`
and `LuaStruct!S.bind`.

```d
import lunarbind;

@LuaExport("vec")                       // type name
struct Vec
{
    @LuaExport("x") int x;              // field name
    @LuaExport(skip: true) int cache;   // hidden from automatic tables

    @LuaExport("length") int len() const { return x; }
    @LuaExport("origin") static Vec origin() { return Vec(0); }
}

@LuaExport("Renamed")
class Player
{
    @LuaExport("hp") int health;
    @LuaExport(skip: true) int internalState;

    @LuaExport("damage", "Reduces health.") void takeDamage(int amount) { health -= amount; }
    @LuaExport("heal") void restore(int amount) { health += amount; }
}

@LuaExport("Status")
enum Status
{
    @LuaExport("ok") success,
    @LuaExport(skip: true) legacy,
}

@LuaExport("mymodule")                  // module-level table name
module my.module;

@LuaExport("add") int addNumbers(int a, int b);  // table field name
@LuaExport(skip: true) int debugOnly();
```

Rules:

- `@LuaExport("name")` replaces the D identifier in automatic tables. It also
  exposes names that are hidden by default (leading `_`, `toString`, ...).
- `@LuaExport("name", "text")` also attaches `text` as documentation in
  generated EmmyLua stubs. Descriptions do not affect runtime behavior.
- `@LuaExport(skip: true)` removes a member from automatic tables.
- `@LuaExport` with no arguments is accepted and behaves like the default.
- An explicit `toLua!symbol(L)` call ignores `skip` but honors `name`, so a
  hidden member can still be exported deliberately.
- Overload sets share one Lua function; a UDA on any overload supplies the
  name/skip for the whole set.
- The default type/table name is the D identifier unless the symbol carries
  `@LuaExport("name")`.

Low-level APIs accept the resolved name explicitly, e.g.
`LuaClass!T.bind(L, "Renamed")`; the UDA only supplies defaults.

## EmmyLua stubs

`luaStubs!Symbols()` generates a `.lua` declaration file for editors that
understand EmmyLua/LuaLS annotations. It uses the same `@LuaExport` names and
filters as automatic tables, so the stubs match what Lua sees at runtime:

```d
import std.file : write;
import lunarbind;

write("mymodule.lua", luaStubs!(
    Player,          // ---@class with fields, properties and methods
    Vec,             // struct value class + static-method type table
    Status,          // ---@enum table
    my.module,       // function table
    addNumbers,      // global function / overload set
    player           // ---@type value
)());
```

The result starts with `---@meta` and declares the bound globals (not locals),
so it can be written directly to a LuaLS meta/stub file. The builder emits
`---@class`, `---@field`, `---@param`, `---@return`, `---@overload`,
`---@vararg`, `---@enum` and `---@type` annotations. Classes
include constructor overloads, instance methods (`function Name.method(self, ...)`)
and static methods; struct type tables contain public static methods only,
while struct values expose fields and instance methods; enum members use their
integer or string values; modules contain every exported function with
overloads listed as `---@overload`.

`@LuaExport("name", "text")` adds documentation: classes and modules get a
leading `--- text` line, fields and enum members get a trailing comment, and
functions get a `--- text` line above their signature.

Types referenced by public fields, properties, constructors and method
signatures (and by module function signatures) are declared automatically and
emitted before the type that uses them. Discovery follows arrays, associative
arrays, `Nullable` and `Tuple`, honors `@LuaExport` names, and emits each type
once even when references form a cycle. Lua handle types, `Object` and
`Throwable` subclasses are never auto-declared.

Auto-declared types assume the default class/struct representation. If a
referenced type has a custom `registerCodec` representation, override its
EmmyLua type; an overridden type is no longer auto-declared:

```d
LuaStubBuilder builder;
builder.setType!Vec2("table");  // applies to Vec2, Vec2[] and Nullable!Vec2
builder.addClass!World();
write("world.lua", builder.toString());

// Or in one call:
write("world.lua", luaStubs!World([typeid(Vec2): "table"]));
```

`LuaStubBuilder` supports incremental output:

```d
LuaStubBuilder builder;
builder.addClass!Player();
builder.addFunction!addNumbers("add");
builder.addValue!int("answer");
write("mymodule.lua", builder.toString());
```

As with explicit `toLua!symbol(L)`, listing a symbol explicitly includes it
even when it carries `@LuaExport(skip: true)`; `skip` only filters automatic
tables (module members, class/struct members and enum members).
`samples/stubs.d` prints a complete stub file for a small annotated API.

Custom representations are registered per state and override the default
`LuaStruct!S`/`LuaClass!T` conversion:

```d
struct Vec2 { double x, y; }

registerCodec!Vec2(L, LuaCodec!Vec2(
    (LuaState L, ref const Vec2 v) {
        auto t = LuaTable.create(L);
        t["x"] = v.x;
        t["y"] = v.y;
        t.pushInto(L);
    },
    (LuaState L, int idx) {
        auto t = popFrom!LuaTable(L, idx);
        return Vec2(t.get!double("x"), t.get!double("y"));
    },
    (LuaState L, int idx) => lua_type(L.handle, idx) == LUA_TTABLE
));
```

The optional `check` predicate is also used when selecting between overloads.
`samples/hello.d` is a runnable version.

Coroutines use the same state and registry:

```d
auto fn = L.loadString("
    return function(a)
        local b = coroutine.yield(a + 1)
        return b * 2
    end
").call!LuaFunction();

auto co = LuaThread.create(fn);
auto yielded = co.resume(10);  // 11, suspended at the yield
auto finished = co.resume(4);  // 8, coroutine finished
assert(!co.isSuspended());
```

## Build / test

DUB configurations (pick one):

| Config | API profile |
|---|---|
| `lua51` | Lua 5.1 |
| `lua52` | Lua 5.2 |
| `lua53` | Lua 5.3 |
| `lua54` | Lua 5.4 |
| `lua55` | Lua 5.5 |
| `luajit` | LuaJIT (`LUA_51` + `LUAJIT`) |

```bash
# library
dub build --config=lua54

# runtime tests (downloads/builds the selected Lua runtime)
./tools/test-lua.sh --profiles lua54
```

On Windows use the PowerShell script instead; it downloads LuaBinaries and
builds LuaJIT with MSVC:

```powershell
.\tools\test-lua.ps1 -Profiles lua54
```

Both scripts default to all six profiles, cache runtimes under `.lua/`
(git-ignored), and use `ldc2`/`dub` from `PATH` unless told otherwise
(`--compiler` / `-Compiler`). No Lua binaries are committed.

CI runs the distro-package matrix on Linux, the source-built runtime matrix on
Linux and Windows (LDC and DMD), and Homebrew-based builds on macOS (LDC).
The unittest build also runs a seeded randomized stress test
(`source/lunarbind/fuzz.d`) over conversions, tables, functions, classes and
structs on every profile.

If you already have Lua development libraries installed, plain `dub test` still
works:

```bash
sudo apt install liblua5.4-dev      # for lua54
sudo apt install liblua5.5-dev      # for lua55, if your distro packages it
sudo apt install libluajit-5.1-dev  # for luajit
dub test --config=lua54
```

On macOS: install a Lua development package (for example `brew install lua`
or `brew install lua@5.4`) or `luajit`. The build does **not** vendor Lua
binaries; you choose dynamic/static linking.

### Benchmarks

`bench/bench.d` compares pure-Lua code against bound D functions, field reads
and writes, method calls, class construction and struct field writes, plus
D-side push/get and table access. Run it after the tests for each selected
profile:

```bash
./tools/test-lua.sh --profiles lua54 --bench
```

```powershell
.\tools\test-lua.ps1 -Profiles lua54 -Bench
```

The results are useful for relative comparisons (such as the cost a binding
call adds over a pure-Lua call) and for spotting regressions between lunarbind
versions, not as absolute performance guarantees. CI runs the benchmark on the
LDC leg of the Linux and Windows runtime matrices.

The module has **no D dependencies** beyond the D runtime, so `dub build` does
not need network access. `dub test` links against the selected Lua library.

## Design

```
user API      LuaState / LuaTable / LuaFunction / LuaThread / LuaClass!T / LuaStruct!S / LuaValue / toLua
bind          extern(C) trampolines, registration, callbacks
object        full userdata + metatable, fields/methods, GC rooting
marshal       pushTo!T / popFrom!T, LuaRef, LuaString (zero-copy view)
raw           lua_State* + version compat helpers, StackGuard
bindings      hand-written, version-selected C API declarations
```

### Lifetime model

`LuaState.open()` creates a reference-counted `StateCore` and records it in the
Lua registry. `LuaState.wrap(L)` — used by every callback — looks that core up
instead of creating a fresh handle, so `LuaRef`/`LuaTable`/`LuaFunction` values
created inside a callback stay valid after the callback returns. The underlying
`lua_State` is closed when the last handle and reference are released. Pushing a
reference into a different Lua state throws `LuaStateException` instead of
silently reading the wrong registry.

A `LuaThread` handle addresses one coroutine's stack while sharing the owner's
`StateCore` and registry. `LuaThread.resume` pushes arguments on the coroutine
stack, resumes it, and copies yielded or final values into D. `LuaState.wrap`
preserves the thread when called from a Lua callback, while `mainState()` returns
a handle to the owner state; registry references always push through the main
state so they cannot disturb a suspended coroutine.

D class userdata are rooted in the D GC. Because the GC root set is process-wide
and not reference-counted, `lunarbind` keeps its own per-object count: an object
exposed in two Lua states (or through two class views) is unrooted only when the
last userdata is finalized. Each class metatable also owns a weak-valued
identity table, so pushing the same D object again reuses the existing userdata
while Lua still has it.

Goals and non-goals:

- **Goal:** D calling Lua looks like D; Lua calling D looks like Lua; D objects
  keep identity and GC safety across the boundary; predictable performance.
- **Non-goal (for v0.1):** source compatibility with lumars. A compatibility
  shim may be added later.

### Current object-model scope

Implemented: D class → full userdata; `__index`/`__newindex` for public fields;
public methods (`obj:method(...)`) including overloads selected by arity and Lua
argument types; unified registration through `toLua` (functions, overload sets,
classes, struct type tables, instances, modules, enum tables and plain values)
with one-call class binding that registers the constructor and all public static
methods, struct type tables that expose public static methods without a
constructor, instance methods also callable as `Name.method(obj, ...)`, and
one-call module binding for all public free functions including overloads;
incremental `LuaModule` composition plus non-global table builders
(`moduleTable`, `enumTable`, `LuaClass!T.createTable`,
`LuaStruct!S.createTable`);
`@LuaExport` naming and member filtering across classes, structs, enums,
modules and free functions; EmmyLua stub generation (`luaStubs`,
`LuaStubBuilder`) from the same metadata, including descriptions and
custom-codec type overrides; `@property` getters/setters;
class-typed fields and method parameters/results; inheritance-aware upcasts (a
derived userdata is accepted as a base class, not vice versa); constructors from
Lua through a registered class table (`Class(args...)`); `__tostring` from D
`toString`; `__len` from a `length` field, property or zero-argument method;
arithmetic, unary and comparison metamethods from `opBinary`, `opUnary` and
`opCmp` (same-class operands); `__call` from `opCall`; `__index`/`__newindex`
falling back to `opIndex`/`opIndexAssign`; D structs boxed as mutable userdata
(`LuaStruct!S`) with field access, methods and operators; omitted trailing
parameters filled from D default arguments; D typesafe variadics collected into
an array; D enums converted through their base integer type (and optionally
exported as `{ name = value }` tables); D `Tuple` results expanded into multiple
Lua returns; `LuaState` parameters injected into callbacks; weak-key/weak-value
tables (`LuaWeakness`); coroutine creation and resumption through `LuaThread`;
`__gc`; `__eq`; D → Lua and Lua → D identity; weak-value identity tables so
repeated pushes reuse the same userdata; reference-counted GC roots across
states and class views. Custom per-state codecs (`registerCodec!T`) override the
default class/struct representation and participate in overload selection
through their `check` predicate.

Not yet: C-style/D-style variadics. These are deliberately listed on the roadmap
rather than half-implemented.

## Roadmap

1. **Stability** (ongoing): CI runtime matrix (Lua 5.1–5.5 + LuaJIT; LDC/DMD),
   seeded randomized stress tests, coverage-guided fuzzing, and `@nogc` fast
   paths where possible.
2. **Tooling** (ongoing): richer documentation generation and editor
   integration.
3. **Language coverage**: selective stdlib opening, GC parameters, and
   C-style/D-style variadics.

## License

MIT. See [LICENSE](LICENSE).

