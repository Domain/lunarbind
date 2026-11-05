# lunarbind

**A transparent, layered D ↔ Lua binding.** Supports LuaJIT and Lua 5.1–5.4.

> Status: **early scaffold (v0.1)**. The core API, conversion layer, callbacks and
> a first userdata/object model are implemented and compile on DMD-frontend
> (LDC 1.43) against Lua 5.1–5.4 API profiles. The runtime smoke tests pass
> against Lua 5.1–5.4 and LuaJIT 2.1 on Windows and Linux using the bundled test
> scripts. References created inside callbacks share the owner state core, and
> cross-state use is rejected. The public API is not frozen yet.

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

It is a **new codebase**, not a patch on lumars; tests, UDA/field filtering ideas
and the EmmyLua generator can be migrated over time. lumars remains MIT-licensed
and is credited in [LICENSE](LICENSE).

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
    registerFunction!add(L, "add");
    auto values = L.eval("return add(20, 22)");

    // Lua function -> D
    auto mul = L.loadString("return function(a, b) return a * b end").call!LuaValue();
    // or: auto f = L.getGlobal!LuaFunction("mul"); f.call!int(6, 7);

    // D object -> Lua userdata; one call binds the constructor and all public
    // static/instance methods.
    auto player = new Player(100, "bob");
    LuaClass!Player.registerClass(L, "Player");
    LuaClass!Player.setGlobal(L, "player", player);
    L.doString("player:damage(5)");
    assert(player.hp == 95);

    // Lua -> new D object
    L.doString("local p = Player(10, 'new'); assert(p.hp == 10)");
}
```

`registerModule!(some.module)(L, "name")` binds every public function in a D
module as one Lua table, including overloads. Both helpers share the same
default-argument, typesafe-variadic and `LuaState` injection rules as
`registerFunction`.

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

Both scripts default to all five profiles, cache runtimes under `.lua/`
(git-ignored), and use `ldc2`/`dub` from `PATH` unless told otherwise
(`--compiler` / `-Compiler`). No Lua binaries are committed.

If you already have Lua development libraries installed, plain `dub test` still
works:

```bash
sudo apt install liblua5.4-dev      # for lua54
sudo apt install libluajit-5.1-dev  # for luajit
dub test --config=lua54
```

On macOS: `brew install lua@5.4` or `luajit`. The build does **not** vendor Lua
binaries; you choose dynamic/static linking.

The module has **no D dependencies** beyond the D runtime, so `dub build` does
not need network access. `dub test` links against the selected Lua library.

## Design

```
user API      LuaState / LuaTable / LuaFunction / LuaThread / LuaClass!T / LuaStruct!S / LuaValue
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
- **Lua 5.5:** not yet. Lua 5.5 changed `LUA_REGISTRYINDEX`, `luaL_openlibs`,
  the GC constants, `lua_Debug` and `lua_newstate`; add a dedicated profile
  when the bindings are extended.

### Current object-model scope

Implemented: D class → full userdata; `__index`/`__newindex` for public fields;
public methods (`obj:method(...)`) including overloads selected by arity and Lua
argument types; one-call class binding (`LuaClass!T.registerClass(L, "Name")`)
that registers the constructor and all public static methods, with instance
methods also callable as `Name.method(obj, ...)`; one-call module binding
(`registerModule!(some.module)(L, "name")`) for all public free functions
including overloads; `@property` getters/setters; class-typed fields and method
parameters/results; inheritance-aware upcasts (a derived userdata is accepted as
a base class, not vice versa); constructors from Lua through a registered class
table (`Class(args...)`); `__tostring` from D `toString`; `__len` from a `length`
field, property or zero-argument method; arithmetic, unary and comparison
metamethods from `opBinary`, `opUnary` and `opCmp` (same-class operands);
`__call` from `opCall`; `__index`/`__newindex` falling back to
`opIndex`/`opIndexAssign`; D structs boxed as mutable userdata (`LuaStruct!S`)
with field access, methods and operators; omitted trailing parameters filled
from D default arguments; D typesafe variadics collected into an array; D
`Tuple` results expanded into multiple Lua returns; `LuaState` parameters
injected into callbacks; weak-key/weak-value tables (`LuaWeakness`); coroutine
creation and resumption through `LuaThread`; `__gc`; `__eq`; D → Lua and Lua → D
identity; weak-value identity tables so repeated pushes reuse the same userdata;
reference-counted GC roots across states and class views.

Not yet: C-style/D-style variadics. These are deliberately listed on the roadmap
rather than half-implemented.

## Roadmap

1. **Stability** (next): CI runtime matrix (Lua 5.1–5.4 + LuaJIT; LDC/DMD),
   fix bugs exposed by real Lua runs, add `@nogc` fast paths where possible.
2. **Functions**: user-defined codecs (`LuaCodec`).
3. **Tooling**: `@LuaExport`/module builder as a single source for registration
   and EmmyLua output, benchmarks, docs.
4. **Lua 5.5** binding profile.

## License

MIT. See [LICENSE](LICENSE).

