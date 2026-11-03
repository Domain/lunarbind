/// Lua state handle, registry references, stack guards and error handling.
module lunarbind.state;

import lunarbind.raw;
static import raw = lunarbind.raw;
import lunarbind.types;
import lunarbind.value : LuaValue;

import std.string : toStringz;
import std.typecons : RefCounted;

/// Registry key used to find the owner StateCore from a raw `lua_State*`.
/// The address of this variable is used as a light userdata key.
private __gshared ubyte stateCoreKey;

// ---------------------------------------------------------------------------
// State core: owns the lua_State* and is shared by LuaState/LuaRef.
// ---------------------------------------------------------------------------

final class StateCore
{
    lua_State* L;
    bool ownsClose;
    bool closed;
    size_t refs = 1;

    this(lua_State* L, bool ownsClose) nothrow
    {
        this.L = L;
        this.ownsClose = ownsClose;
    }

    void retain() nothrow
    {
        assert(refs > 0);
        refs++;
    }

    void release() nothrow
    {
        assert(refs > 0);
        if (--refs == 0)
            close();
    }

    void close() nothrow
    {
        if (closed)
            return;
        closed = true;
        if (ownsClose && L !is null)
            lua_close(L);
        L = null;
    }

    ~this() nothrow
    {
        close();
    }
}

/// Associate `core` with `L` so callbacks can recover the owning handle.
private void storeStateCore(lua_State* L, StateCore core) nothrow
{
    lua_pushlightuserdata(L, cast(void*) &stateCoreKey);
    lua_pushlightuserdata(L, cast(void*) core);
    lua_rawset(L, LUA_REGISTRYINDEX);
}

/// Recover the owner StateCore for `L`, or null for a foreign state.
private StateCore loadStateCore(lua_State* L) nothrow
{
    lua_pushlightuserdata(L, cast(void*) &stateCoreKey);
    lua_rawget(L, LUA_REGISTRYINDEX);
    auto p = lua_touserdata(L, -1);
    raw.pop(L, 1);
    return p is null ? null : cast(StateCore) p;
}

// ---------------------------------------------------------------------------
// LuaState: a cheap, copyable, shared handle.
// ---------------------------------------------------------------------------

struct LuaState
{
    private StateCore _core;
    // The state used for stack operations. It is the main state for ordinary
    // handles and the coroutine's state for handles wrapping a Lua thread.
    // Every thread shares the owning core's registry.
    private lua_State* _handle;

    private this(lua_State* L, bool ownsClose)
    {
        _core = new StateCore(L, ownsClose);
        _handle = L;
    }

    /// Adopt an existing core, retaining it. `handle` selects the thread whose
    /// stack this wrapper addresses; it defaults to the core's main state.
    private this(StateCore core, bool retain,
                 lua_State* handle = null) nothrow
    {
        _core = core;
        _handle = handle is null ? core.L : handle;
        if (retain)
            _core.retain();
    }

    this(this) nothrow
    {
        if (_core !is null)
            _core.retain();
    }

    ~this() nothrow
    {
        if (_core !is null)
            _core.release();
    }

    ref LuaState opAssign(LuaState rhs) return
    {
        if (_core is rhs._core && _handle is rhs._handle)
            return this;
        if (rhs._core !is null)
            rhs._core.retain();
        auto old = _core;
        _core = rhs._core;
        _handle = rhs._handle;
        if (old !is null)
            old.release();
        return this;
    }

    /// Create and own a new Lua state. Standard libraries are opened by default.
    static LuaState open(bool openLibs = true)
    {
        auto L = luaL_newstate();
        if (L is null)
            throw new LuaException("luaL_newstate() failed");

        auto state = LuaState(L, true);
        storeStateCore(L, state._core);
        if (openLibs)
            luaL_openlibs(L);
        return state;
    }

    /// Create an owning handle for an existing `lua_State*`.
    static LuaState adopt(lua_State* L)
    {
        if (L is null)
            throw new LuaStateException("cannot adopt a null lua_State");
        if (loadStateCore(L) !is null)
            throw new LuaStateException("this lua_State already has an owning LuaState");
        auto state = LuaState(L, true);
        storeStateCore(L, state._core);
        return state;
    }

    /// Wrap an existing state without taking ownership. Intended for callbacks.
    /// When the state was created by LuaState.open/adopt, this shares the
    /// owner's StateCore so references stay valid for the state's lifetime.
    /// For a Lua thread, the returned handle addresses that thread's stack.
    static LuaState wrap(lua_State* L)
    {
        if (L is null)
            throw new LuaStateException("cannot wrap a null lua_State");
        if (auto core = loadStateCore(L))
            return LuaState(core, true, L);
        return LuaState(L, false);
    }

    /// True when both handles share the same StateCore (same Lua universe).
    bool sharesState(LuaState other)
    {
        return _core is other._core;
    }

    /// Explicitly close an owned state. Throws if LuaRef copies still exist.
    void close()
    {
        if (_core is null)
            return;
        if (!_core.ownsClose)
            throw new LuaStateException("cannot close a non-owning LuaState wrapper");
        if (_core.refs != 1)
            throw new LuaStateException("cannot close a LuaState while references are still alive");
        _core.close();
    }

    bool isOpen() const @nogc nothrow
    {
        return _core !is null && !_core.closed && _handle !is null;
    }

    size_t referenceCount() const @nogc nothrow
    {
        return _core is null ? 0 : _core.refs;
    }

    /// Number of currently live LuaState handles sharing the same core.
    @property lua_State* handle() @nogc nothrow
    {
        return _handle;
    }

    /// A handle addressing the main state of this Lua universe. For a handle
    /// wrapping a coroutine this is the thread's owner state, whose registry is
    /// shared. State-wide operations and `LuaRef` stack pushes use it so they
    /// never disturb a suspended coroutine's stack.
    LuaState mainState()
    {
        if (_core is null)
            return LuaState.init;
        return LuaState(_core, true);
    }

    void ensureOpen() const
    {
        if (!isOpen())
            throw new LuaStateException("Lua state is closed or null");
    }

    // -- raw stack primitives ------------------------------------------------

    int top() @nogc nothrow { return lua_gettop(handle); }
    void setTop(int idx) @nogc nothrow { lua_settop(handle, idx); }
    void pop(int n = 1) @nogc nothrow { raw.pop(handle, n); }
    void pushValue(int idx) @nogc nothrow { lua_pushvalue(handle, idx); }
    int absIndex(int idx) @nogc nothrow { return raw.absIndex(handle, idx); }
    bool checkStack(int n) @nogc nothrow { return lua_checkstack(handle, n) != 0; }

    LuaType typeOf(int idx) @nogc nothrow
    {
        auto t = lua_type(handle, idx);
        if (t == LUA_TNUMBER && raw.isInteger(handle, idx))
            return LuaType.integer;
        switch (t)
        {
            case LUA_TNONE:          return LuaType.none;
            case LUA_TNIL:           return LuaType.nil;
            case LUA_TBOOLEAN:       return LuaType.boolean;
            case LUA_TLIGHTUSERDATA: return LuaType.lightUserdata;
            case LUA_TNUMBER:        return LuaType.number;
            case LUA_TSTRING:        return LuaType.string;
            case LUA_TTABLE:         return LuaType.table;
            case LUA_TFUNCTION:      return LuaType.function_;
            case LUA_TUSERDATA:      return LuaType.userdata;
            case LUA_TTHREAD:        return LuaType.thread;
            default:                 return LuaType.none;
        }
    }

    string typeName(int idx)
    {
        return lua_typename(handle, lua_type(handle, idx))[0 .. strlen(lua_typename(handle, lua_type(handle, idx)))].idup;
    }

    // -- generic conversion (implemented in lunarbind.conv) --------------------

    void push(T)(T value)
    {
        import lunarbind.conv : pushTo;
        pushTo(this, value);
    }

    T get(T)(int idx)
    {
        import lunarbind.conv : popFrom;
        return popFrom!T(this, idx);
    }

    void setGlobal(T)(string name, T value)
    {
        import lunarbind.conv : pushTo;
        pushTo(this, value);
        raw.setGlobal(handle, toStringz(name));
    }

    T getGlobal(T)(string name)
    {
        import lunarbind.conv : popFrom;
        StackGuard guard = StackGuard(this);
        raw.getGlobal(handle, toStringz(name));
        return popFrom!T(this, -1);
    }

    // -- globals / load / eval ----------------------------------------------

    auto globals()
    {
        import lunarbind.table : LuaTable;
        pushGlobalTable(handle);
        auto ref_ = LuaRef.make(this, -1);
        pop(1);
        return LuaTable(ref_);
    }

    /// Load a chunk without running it.
    auto loadString(string code, string name = "<string>")
    {
        import lunarbind.function_ : LuaFunction;
        StackGuard guard = StackGuard(this);
        auto status = raw.loadString(handle, code, toStringz(name));
        if (status != LUA_OK)
        {
            auto msg = errorText(-1);
            throw new LuaException(msg, cast(LuaStatus) status);
        }
        return LuaFunction(LuaRef.make(this, -1));
    }

    /// Evaluate a chunk and return all its results. Throws on Lua errors.
    LuaValue[] eval(string code, string name = "<string>")
    {
        import lunarbind.value : LuaValue;
        StackGuard guard = StackGuard(this);

        const base = top();
        auto status = raw.loadString(handle, code, toStringz(name));
        if (status != LUA_OK)
        {
            auto msg = errorText(-1);
            throw new LuaException(msg, cast(LuaStatus) status);
        }

        // Insert a traceback message handler below the chunk.
        pushCFunction(handle, &luaMessageHandler);
        insert(handle, base + 1);

        status = raw.pcall(handle, 0, LUA_MULTRET, base + 1);
        remove(handle, base + 1);

        if (status != LUA_OK)
        {
            auto msg = errorText(-1);
            throw new LuaException(msg, cast(LuaStatus) status, msg);
        }

        LuaValue[] result;
        foreach (i; base + 1 .. top() + 1)
            result ~= LuaValue.fromStack(this, i);
        return result;
    }

    /// Evaluate a chunk, discarding its results.
    void doString(string code, string name = "<string>")
    {
        eval(code, name);
    }

    // -- protected call ------------------------------------------------------
    //
    // The stack layout expected by this helper is:
    //     [ ... , messageHandler, function, arg1, ..., argN ]
    // with `errFunc` pointing at messageHandler.
    LuaStatus protectedCall(int nargs, int nresults, int errFunc) @nogc nothrow
    {
        return cast(LuaStatus) raw.pcall(handle, nargs, nresults, errFunc);
    }

    @nogc nothrow
    void pushErrorHandler()
    {
        pushCFunction(handle, &luaMessageHandler);
    }

    // -- error helpers -------------------------------------------------------

    string errorText(int idx)
    {
        ensureOpen();
        static if (LUA_VERSION_NUM >= 502)
        {
            size_t len;
            auto p = luaL_tolstring(handle, idx, &len);
            string s = p is null ? "unknown Lua error" : p[0 .. len].idup;
            pop(1);
            return s;
        }
        else
        {
            auto absIdx = raw.absIndex(handle, idx);
            size_t len;
            auto p = lua_tolstring(handle, absIdx, &len);
            if (p !is null)
                return p[0 .. len].idup;
            raw.getGlobal(handle, "tostring");
            if (lua_type(handle, -1) == LUA_TFUNCTION)
            {
                lua_pushvalue(handle, absIdx);
                raw.call(handle, 1, 1);
                auto p2 = lua_tolstring(handle, -1, &len);
                string s2 = p2 is null ? "unknown Lua error" : p2[0 .. len].idup;
                pop(1);
                return s2;
            }
            pop(1);
            return "unknown Lua error";
        }
    }
}

// ---------------------------------------------------------------------------
// StackGuard
// ---------------------------------------------------------------------------

/// Restores the Lua stack to its entry top when the guard is destroyed.
struct StackGuard
{
    private lua_State* L;
    private int savedTop;

    this(LuaState state)
    {
        L = state.handle;
        savedTop = L is null ? 0 : lua_gettop(L);
    }

    @disable this(this);

    ~this() @nogc nothrow
    {
        if (L !is null)
            lua_settop(L, savedTop);
    }
}

// ---------------------------------------------------------------------------
// LuaRef: an owning registry reference
// ---------------------------------------------------------------------------

private struct RefHolder
{
    LuaState state;
    int ref_;

    this(LuaState state, int ref_)
    {
        this.state = state;
        this.ref_ = ref_;
    }

    ~this() nothrow
    {
        auto L = state.handle;
        if (L !is null && ref_ != 0 && ref_ != LUA_REFNIL)
            luaL_unref(L, LUA_REGISTRYINDEX, ref_);
    }
}

struct LuaRef
{
    private RefCounted!RefHolder _holder;

    this(LuaState state, int ref_)
    {
        // Registry references are universe-wide. Store the main state so
        // pushing a reference never touches a suspended coroutine's stack.
        _holder = RefCounted!RefHolder(state.mainState(), ref_);
    }

    /// Copy the value at `idx` into the registry and return a reference.
    static LuaRef make(LuaState state, int idx)
    {
        state.pushValue(idx);
        auto ref_ = luaL_ref(state.handle, LUA_REGISTRYINDEX);
        return LuaRef(state, ref_);
    }

    /// Take ownership of an existing registry reference.
    static LuaRef fromRef(LuaState state, int ref_)
    {
        return LuaRef(state, ref_);
    }

    bool isNull() const @nogc nothrow
    {
        if (!_holder.refCountedStore.isInitialized)
            return true;
        return _holder.ref_ == 0 || _holder.ref_ == LUA_REFNIL;
    }

    LuaState state() { return _holder.state; }
    int ref_() const @nogc nothrow { return _holder.ref_; }

    void push() @nogc nothrow
    {
        lua_rawgeti(_holder.state.handle, LUA_REGISTRYINDEX, _holder.ref_);
    }

    /// True when this reference belongs to a live `target` Lua state. Threads
    /// of one state share a registry and therefore belong to each other.
    bool belongsTo(LuaState target)
    {
        return _holder.state.handle !is null && _holder.state.sharesState(target);
    }

    /// Push this reference onto `target`, refusing to leak it into a different
    /// Lua state.
    void pushInto(LuaState target)
    {
        if (!belongsTo(target))
            throw new LuaStateException("LuaRef belongs to a different Lua state");
        lua_rawgeti(target.handle, LUA_REGISTRYINDEX, _holder.ref_);
    }

    LuaType type()
    {
        StackGuard guard = StackGuard(_holder.state);
        push();
        return _holder.state.typeOf(-1);
    }

    auto asTable() { import lunarbind.table : LuaTable; return LuaTable(this); }
    auto asFunction() { import lunarbind.function_ : LuaFunction; return LuaFunction(this); }

    LuaValue asValue()
    {
        auto s = _holder.state;
        StackGuard guard = StackGuard(s);
        push();
        return LuaValue.fromStack(s, -1);
    }
}

// ---------------------------------------------------------------------------
// Traceback message handler
// ---------------------------------------------------------------------------

/// Message handler used by protected calls. It replaces the error object with
/// a traceback string (Lua 5.2+) or keeps the original error (Lua 5.1).
package extern(C) int luaMessageHandler(lua_State* L) nothrow
{
    static if (LUA_VERSION_NUM >= 502)
    {
        const(char)* msg = lua_tolstring(L, -1, null);
        luaL_traceback(L, L, msg, 1);
    }
    return 1;
}

// ---------------------------------------------------------------------------
// Misc helpers
// ---------------------------------------------------------------------------

// `std.string.strlen` is not @nogc? It is, but avoid the import.
private size_t strlen(const(char)* s) @nogc nothrow
{
    size_t n = 0;
    if (s !is null)
        while (s[n] != '\0')
            n++;
    return n;
}
