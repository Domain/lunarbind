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
  coroutine.d    LuaThread: create/fromValue/resume/resumeFrom/status coroutine handles
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

## State setup, libraries and GC

`LuaState.open()` loads every standard library for the active Lua version.
`LuaState.open(false)` creates a bare state, and `LuaState.open(LuaLib...)`
loads only the selected libraries:

```d
auto L = LuaState.open(LuaLib.base | LuaLib.string | LuaLib.table);
assert(L.getGlobal!LuaValue("io").isNil());

// Add more libraries later; opening an already-open library is harmless.
L.openLibraries(LuaLib.math | LuaLib.os);
```

Available members are `base`, `package_`, `coroutine`, `table`, `io`, `os`,
`string`, `math`, `utf8` (5.3+), `debug_`, `bit32` (5.2), `bit` and `jit`
(LuaJIT), plus `all` and `none`. Libraries that do not exist in the active Lua
version are ignored, so `LuaLib.all` matches `luaL_openlibs`. On Lua 5.1 and
LuaJIT the `coroutine` functions are opened together with `base`.

GC controls are thin wrappers over `lua_gc`:

```d
L.gcCollect();                 // full collection
size_t bytes = L.gcBytes();    // current Lua memory use
int kb = L.gcCount();          // kilobytes (remainder in gcCountBytes)
L.gcStep(1);                   // incremental step
L.gcStop();                    // pause the collector
L.gcRestart();
bool running = L.gcIsRunning();
L.gcSetPause(200);             // percentage
L.gcSetStepMul(200);           // step multiplier
```

`gcIsRunning` reports `true` on plain Lua 5.1, which has no query. The pause
and step-multiplier setters return the previous value. On Lua 5.5 the same
operations map to `LUA_GCPARAM`; on earlier versions they map to
`LUA_GCSETPAUSE` / `LUA_GCSETSTEPMUL`.

Chunks can be loaded from strings or files:

```d
auto chunk = L.loadFile("scripts/init.lua");   // LuaFunction, not run
auto results = L.evalFile("scripts/init.lua"); // run and collect results
L.doFile("scripts/init.lua");                  // run and discard results
```

`loadString`, `eval` and `doString` are the string equivalents. A missing or
unreadable file raises `LuaException` with `LuaStatus.errFile`; syntax errors
use `LuaStatus.errSyntax`. `LuaStatus.toString` gives a version-independent
name, and `luaStatusFromInt` maps a raw C API status code back to the enum.

## Allocation-free fast paths

Primitive stack, table and state operations are `@nogc`, so they can be used
from real-time or `@nogc` code:

- `LuaState` stack primitives (`top`, `setTop`, `pop`, `pushValue`,
  `absIndex`, `checkStack`, `typeOf`, `protectedCall`) and GC controls
- `LuaState.push` for `bool`, integers, floating-point values, strings,
  `LuaString`, `const(char)[]`, `void*` and `Nullable` scalars (unsigned values
  wider than `lua_Integer` are range-checked and may throw)
- `LuaState.setGlobal` (keys are pushed as length-delimited strings; this is
  the raw path and does not protect a `_G` `__newindex` metamethod)
- `LuaTable.setUnchecked` with primitive keys and values, `LuaTable.push` and
  `LuaTable.length` (`LuaTable.set` validates the receiver and key and may
  throw; `LuaTable.lengthOf` is the checked length that honors `__len` on
  Lua 5.2+ and throws on a raising or non-integer metamethod)
- `LuaRef.push` / `reference` / `isNull`, `LuaFunction.push`, `LuaTable.state`
- `LuaValue.pushUnchecked`, the allocation-free counterpart of `push`
- copying a `LuaState` handle, `mainState` and `sharesState`

Checked conversions (`LuaTable.get`, `LuaState.getGlobal`, `LuaFunction.call`)
throw typed D exceptions on conversion errors, which requires allocation; they
are intentionally not `@nogc`. Integer conversions are range-checked: popping a
Lua integer into a narrower or unsigned D type throws `LuaArgumentException`
instead of truncating, and pushing an unsigned value above `lua_Integer.max` is
rejected. Non-integral numbers and values outside `lua_Integer`'s range are
rejected on every runtime, including Lua 5.1/LuaJIT where `lua_tointeger`
would truncate. When you need a no-allocation path, validate with `typeOf` and
read through the stack primitives, or use `LuaValue.pushUnchecked` after
confirming state ownership yourself.

## Error handling

Errors raised by bound D callbacks become ordinary Lua errors, so they can be
caught with `pcall` or `LuaFunction.call`. Dispatch failures name the symbol and
the supplied argument types, for example
`no matching overload for add(string, integer)`. Arity failures use the name
the function was registered under, for example
`add_default: expected between 1 and 2 arguments, got 0 arguments`.

Lua raises errors with `longjmp`, which skips D destructors. lunarbind builds
the message inside the `try` body, lets normal D unwinding destroy temporary
`LuaState` handles and argument tuples, and only then calls `lua_error`. State
reference counts therefore stay balanced after a failed call, and closing the
state still succeeds.

`LuaTable.get`, `tryGet` and `set` run `__index`/`__newindex` under `pcall`, so a
metamethod that raises becomes a `LuaException` instead of an unprotected Lua
error. Tables without those metamethods take the direct `lua_gettable`/
`lua_settable` path. `set` rejects nil and NaN keys before calling Lua;
`setUnchecked` skips all of these checks. `LuaModule.set` and its `add*`
methods use the same protected assignment, and `LuaTable.setWeakness` writes
`__mode` with a raw set so a metatable's `__newindex` cannot intercept it.

`LuaTable.opApply` also runs each `lua_next` step under `pcall`. If the loop
body mutates the table in a way that invalidates the current key, Lua's
`invalid key to 'next'` error becomes a `LuaException` instead of aborting the
process. Keys are copied into `LuaValue` between steps, so the traversal holds
no Lua stack reference to them; modifying existing entries is safe, while
adding new keys may raise that exception. Associative-array conversion
(`popFrom!(V[K])`) uses the same protected iteration, so a codec that removes
the current key produces a `LuaException` too.

Global access follows the same rule. `LuaState.getGlobal` runs a `_G` `__index`
metamethod under `pcall`, and `LuaState.setGlobalChecked` does the same for
`__newindex`; registration helpers such as `toLua`, `LuaClass!T.setGlobal`,
`LuaStruct!S.setGlobal`, `registerModule` and `LuaModule.setGlobal` use the
checked path. `LuaState.setGlobal` remains the raw allocation-free fast path
and deliberately skips those checks. Opening a standard library through
`openLibraries` also runs the opener and its global registration under `pcall`,
so a tampered `_G` or `package.loaded` raises `LuaException`.

## Unified registration with `toLua`

`toLua` is the recommended facade. It detects the symbol kind at compile time,
uses the symbol's `@LuaExport("name")` or `__traits(identifier, Symbol)` as the
default global name, and returns a handle that matches the category:

| D symbol | Lua value | returned handle |
|---|---|---|
| function / overload set | function | `LuaFunction` |
| raw `lua_CFunction` | function | `LuaFunction` |
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

D `...` declarations cannot be marshalled automatically because Lua values
carry no C type information. For arbitrary or C-style variadic arguments, bind
a raw `lua_CFunction` instead; it receives the Lua stack directly and returns
the number of Lua results:

```d
extern(C) int sumAll(lua_State* L) nothrow
{
    lua_Integer total;
    foreach (i; 1 .. lua_gettop(L) + 1)
        total += luaL_checkinteger(L, i);
    lua_pushinteger(L, total);
    return 1;
}

toLua!sumAll(L);                 // global `sumAll`
L.doString("assert(sumAll(1, 2, 3) == 6)");
```

Raw callbacks also work with `registerFunction`, `registerLibrary`,
`registerModule`, `LuaModule.addFunction` and runtime function pointers. They
are not bound as class or struct members; generated stubs declare them with a
Lua vararg (`function sumAll(...) end`).

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

Unions have no default representation because the binder cannot know which
member is active. Register a codec for the union before pushing, popping or
binding it:

```d
union Number { int integer; float floating; }

registerCodec!Number(L, LuaCodec!Number(
    (LuaState L, ref const Number v) { pushTo(L, v.integer); },
    (LuaState L, int idx) {
        Number n;
        n.integer = popFrom!int(L, idx);
        return n;
    },
    (LuaState L, int idx) => lua_type(L.handle, idx) == LUA_TNUMBER
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
(`--compiler` / `-Compiler`). No Lua binaries are committed. After the profile
loop both scripts also compile and run `samples/hello.d` and `samples/stubs.d`
against the first selected profile, so the samples are checked against the
public API on every run.

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
created inside a callback stay valid after the callback returns. A state not
created by lunarbind gets a non-owning wrapper; references made from it must not
outlive the owner's `lua_State`. The underlying `lua_State` is closed when the
last handle and reference are released. Pushing a reference into a different Lua
state throws `LuaStateException` instead of silently reading the wrong registry.

After the state is closed, `LuaState.handle` returns null and checked operations
(`loadString`, `loadFile`, `eval`, `evalFile`, `doFile`, `globals`, `typeName`, `LuaTable.get`/`set`/`opApply`,
`LuaFunction.call`, `LuaRef.type`, `LuaRef.make`, `LuaThread.resume`/`resumeFrom`,
`LuaValue.push`/`fromStack`, `toLua`, `registerFunction`, `registerLibrary`, `LuaClass!T.setGlobal`,
`LuaStruct!S.push` and the `LuaModule` mutators) throw `LuaStateException`.
Default-initialized handles behave the same way instead of tripping a
`RefCounted` assertion or dereferencing a null state. The `@nogc nothrow` stack
primitives, `LuaRef.push`, `LuaFunction.push`, `LuaTable.setUnchecked` and
`LuaValue.pushUnchecked` stay raw: they assume a live state and valid handle.
`LuaTable.setUnchecked` also assumes a valid key; use `set` when the key may be
nil or NaN.

`popFrom!(const(char)[])` returns a slice into Lua's interned string storage, so
it is only valid while that Lua value stays alive. Pop into `string` or `char[]`
for an owned copy; `LuaString` is the explicit zero-copy view.

A `LuaThread` handle addresses one coroutine's stack while sharing the owner's
`StateCore` and registry. `LuaThread.resume` pushes arguments on the coroutine
stack, resumes it, and copies yielded or final values into D. It assumes the
caller runs on the main thread; when a bound callback running inside a
coroutine resumes another one, pass the callback's injected state as the first
argument to `LuaThread.resumeFrom` so Lua inherits the caller's C-call depth.
`LuaState.wrap` preserves the thread when called from a Lua callback, while
`mainState()` returns a handle to the owner state; registry references always
push through the main state so they cannot disturb a suspended coroutine.

`LuaState` and every handle derived from it are single-threaded. Lua states are
not internally synchronized, and `StateCore` tracks reference counts with a
plain `size_t`, so sharing a state or a handle between threads without external
locking is a data race. Use one state per thread, or guard all access with your
own lock.

D class userdata are rooted in the D GC. Because the GC root set is process-wide
and not reference-counted, `lunarbind` keeps its own per-object count: an object
exposed in two Lua states (or through two class views) is unrooted only when the
last userdata is finalized. Each class metatable also owns a weak-valued
identity table, so pushing the same D object again reuses the existing userdata
while Lua still has it. A finalized userdata can be resurrected by Lua (for
example by storing it in a global from `__gc`); its boxed D reference is
cleared, so field access, method calls, `tostring`, `#` and `LuaClass!T.get`
raise instead of dereferencing a null reference. Struct boxes carry an explicit
liveness marker: finalization clears the value and removes its GC range, and
any later field access, method call or `LuaStruct!S.get` on a resurrected
userdata raises instead of exposing stale pointers. Struct boxes live in
Lua-allocated memory, which the D GC does not scan; when the struct contains
GC-managed fields (strings, arrays, class references, delegates), the box is
registered as a GC range while Lua owns it and unregistered from `__gc`.

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
states and class views; selective standard-library loading through `LuaLib` /
`openLibraries` and GC controls (`gcCollect`, `gcBytes`, `gcStep`, `gcStop`,
`gcRestart`, `gcIsRunning`, `gcSetPause`, `gcSetStepMul`); raw
`lua_CFunction` callbacks for arbitrary/C-style variadic arguments. Custom
per-state codecs (`registerCodec!T`) override the default class/struct
representation and participate in overload selection through their `check`
predicate.

Not yet: automatic marshalling of D `...` declarations. C-style variadic
arguments are handled through raw `lua_CFunction` callbacks (see above). D
`union` types have no default representation; register a `LuaCodec` for the
union before pushing, popping or binding it. A binding whose union parameter
has no registered codec reports no matching overload.

## Roadmap

1. **Stability** (ongoing): CI runtime matrix (Lua 5.1–5.5 + LuaJIT; LDC/DMD),
   seeded randomized stress tests, and coverage-guided fuzzing. Primitive
   stack, table and state paths are already `@nogc`; checked conversions stay
   allocating because they throw typed errors. Callback errors unwind safely
   across the Lua `longjmp` boundary without leaking state references.
2. **Tooling** (ongoing): richer documentation generation and editor
   integration.
3. **API polish**: v0.2 review of names, attributes and error messages; see
   [`API-REVIEW.md`](API-REVIEW.md) for the current proposal list.

## License

MIT. See [LICENSE](LICENSE).

