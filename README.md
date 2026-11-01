# lunarbind

**A transparent, layered D ↔ Lua binding.** Supports LuaJIT and Lua 5.1–5.4.

> Status: **early scaffold (v0.1)**. The core API, conversion layer, callbacks and
> a first userdata/object model are implemented and compile on DMD-frontend
> (LDC 1.43) against Lua 5.1–5.4 API profiles. The runtime smoke tests pass
> against LuaJIT 2.1.0-beta3 on Windows (Lua 5.2–5.4 runtime runs are left to CI,
> which installs the corresponding system libraries). The public API is not
> frozen yet.

## Why another binding?

The upstream [lumars](https://github.com/Domain/lumars) is a useful, lightweight
embedding wrapper, but its value-semantic `push`/`get` model cannot provide
transparent D-class ↔ Lua-object interoperation. lunarbind is a clean base for
that goal:

- explicit, shared `LuaState` lifetime; no `LuaState*` dangling from refs;
- registry references with deterministic release (`LuaRef`, `LuaTable`,
  `LuaFunction`);
- one `extern(C)` trampoline per signature for callbacks (never type-punning
  `void*`/delegate internals);
- `pushTo!T` / `popFrom!T` conversion policy instead of a closed `static if`;
- full-userdata based object binding (`LuaClass!T`) with D-GC rooting.

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
  table.d        LuaTable (registry-backed; get/set/opIndex/foreach)
  function_.d    LuaFunction call/bind, callback wrappers, delegate boxing, registration
  object.d       LuaClass!T: D class <-> Lua full userdata + metatable
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

    // D object -> Lua userdata
    auto player = new Player(100, "bob");
    LuaClass!Player.setGlobal(L, "player", player);
    L.doString("player:damage(5)");
    assert(player.hp == 95);
}
```

`samples/hello.d` is a runnable version.

## Build / test

DUB configurations (pick one):

| Config | API profile |
|---|---|
| `lua51` | Lua 5.1 / LuaJIT |
| `lua52` | Lua 5.2 |
| `lua53` | Lua 5.3 |
| `lua54` | Lua 5.4 |
| `luajit` | LuaJIT (`LUA_51` + `LUAJIT`) |

```bash
# library
dub build --config=lua54

# runtime tests (needs a Lua development library installed)
dub test --config=lua54
```

On Debian/Ubuntu:

```bash
sudo apt install liblua5.4-dev      # for lua54
sudo apt install libluajit-5.1-dev  # for luajit
```

On Windows, put `lua54.lib`/`lua54.dll` (or LuaJIT's `lua51.lib`) on the
compiler/library search path. On macOS: `brew install lua@5.4` or `luajit`.
The build does **not** vendor Lua binaries; you choose dynamic/static linking.

The module has **no D dependencies** beyond the D runtime, so `dub build` does
not need network access. `dub test` links against the selected Lua library.

## Design

```
user API      LuaState / LuaTable / LuaFunction / LuaClass!T / LuaValue
bind          extern(C) trampolines, registration, callbacks
object        full userdata + metatable, fields/methods, GC rooting
marshal       pushTo!T / popFrom!T, LuaRef, LuaString (zero-copy view)
raw           lua_State* + version compat helpers, StackGuard
bindings      hand-written, version-selected C API declarations
```

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
public single-overload methods (`obj:method(...)`); `__gc`; `__eq`; D → Lua and
Lua → D identity.

Not yet: constructors from Lua, properties, inheritance, overload resolution,
operator metamethods, struct reference semantics, `__tostring`, weak tables.
These are deliberately listed on the roadmap rather than half-implemented.

## Roadmap

1. **Stability** (next): CI runtime matrix (Lua 5.1–5.4 + LuaJIT; LDC/DMD),
   fix bugs exposed by real Lua runs, add `@nogc` fast paths where possible.
2. **Object model**: constructors, properties, inheritance, overloads,
   `__tostring`/`__len`, structs by reference, weak identity table.
3. **Functions**: default args, varargs, `LuaState` injection, tuple returns,
   user-defined codecs (`LuaCodec`), coroutine wrappers.
4. **Tooling**: `@LuaExport`/module builder as a single source for registration
   and EmmyLua output, benchmarks, docs.
5. **Lua 5.5** binding profile.

## License

MIT. See [LICENSE](LICENSE).

