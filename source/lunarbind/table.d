/// Registry-backed Lua table handle.
module lunarbind.table;

import lunarbind.raw;
static import raw = lunarbind.raw;
import lunarbind.state;
import lunarbind.types;
import lunarbind.value;
import lunarbind.conv;

/// Weak-reference behavior for a Lua table.
enum LuaWeakness
{
    /// Keys and values are strong.
    none,
    /// Keys are weak; unreachable key objects are removed from the table.
    keys,
    /// Values are weak; unreachable value objects are removed from the table.
    values,
    /// Both keys and values are weak.
    both,
}

struct LuaTable
{
    private LuaRef _ref;

    this(LuaRef ref_)
    {
        _ref = ref_;
    }

    // The value must be a table before lua_gettable/lua_settable/lua_next run:
    // those calls raise Lua errors, and an unprotected error would longjmp out
    // of D code and abort the process.
    private static void requireTable(LuaState state)
    {
        if (state.typeOf(-1) != LuaType.table)
            throw new LuaTypeException(
                "expected table, got " ~ state.typeName(-1));
    }

    // True when the table at `idx` has a non-nil metamethod field. A table
    // without `__index`/`__newindex` cannot raise from get/set, so the common
    // path stays a direct lua_gettable/lua_settable call.
    //
    // `hasMetamethod`, `tableError`, `getTableThunk`, `setTableThunk` and
    // `nextThunk` are shared with LuaState globals access and live in
    // lunarbind.state.

    // Nil and NaN keys make lua_settable raise; validate them before the call.
    private static void checkSettableKey(LuaState s, int idx)
    {
        auto t = lua_type(s.handle, idx);
        if (t == LUA_TNIL)
            throw new LuaArgumentException("table index is nil");
        if (t == LUA_TNUMBER)
        {
            auto n = raw.toNumberX(s.handle, idx, null);
            if (n != n)
                throw new LuaArgumentException("table index is NaN");
        }
    }

    /// Create a fresh, empty table.
    static LuaTable create(LuaState state, int arrayHint = 0, int recordHint = 0)
    {
        state.ensureOpen();
        lua_createtable(state.handle, arrayHint, recordHint);
        auto ref_ = LuaRef.make(state, -1);
        state.pop(1);
        return LuaTable(ref_);
    }

    /// Create a fresh table with weak keys and/or values.
    static LuaTable createWeak(LuaState state, LuaWeakness weakness,
                               int arrayHint = 0, int recordHint = 0)
    {
        auto table = create(state, arrayHint, recordHint);
        table.setWeakness(weakness);
        return table;
    }

    /// Set weak keys/values through the table's metatable.
    ///
    /// An existing metatable is reused; otherwise an empty one is attached.
    /// `LuaWeakness.none` removes an existing `__mode` field and does not
    /// attach a metatable when there is none. Set this once, before filling the
    /// table: Lua only reads `__mode` when it collects the table's entries.
    void setWeakness(LuaWeakness weakness)
    {
        auto s = state();
        s.ensureOpen();
        StackGuard guard = StackGuard(s);
        push();                                  // [table]
        if (lua_getmetatable(s.handle, -1) == 0)
        {
            // Nothing to clear, and `none` should not attach a metatable.
            if (weakness == LuaWeakness.none)
                return;
            lua_createtable(s.handle, 0, 1);      // [table, metatable]
            lua_pushvalue(s.handle, -1);          // [table, metatable, metatable]
            lua_setmetatable(s.handle, -3);       // [table, metatable]
        }

        // Use a raw set: assigning `__mode` must not run a metatable's
        // `__newindex` metamethod (which could raise).
        lua_pushlstring(s.handle, "__mode".ptr, 6);
        if (weakness == LuaWeakness.none)
        {
            // Remove the field so the table becomes strong again.
            lua_pushnil(s.handle);
        }
        else
        {
            auto mode = weaknessMode(weakness);
            lua_pushlstring(s.handle, mode.ptr, mode.length);
        }
        lua_rawset(s.handle, -3);                // [table, metatable]
    }

    LuaState state() @nogc nothrow { return _ref.state(); }
    LuaRef ref_() @nogc nothrow { return _ref; }
    /// Registry reference handle for this table.
    @property LuaRef reference() @nogc nothrow { return _ref; }
    void push() @nogc nothrow { _ref.push(); }
    void pushInto(LuaState target) { _ref.pushInto(target); }

    /// Get a field/entry. `key` may be a string, integer, or any pushable value.
    ///
    /// A table with an `__index` metamethod runs the lookup under `pcall`, so
    /// errors raised by the metamethod become `LuaException` instead of
    /// escaping as an unprotected Lua error.
    T get(T, K)(K key)
    {
        auto s = state();
        s.ensureOpen();
        StackGuard guard = StackGuard(s);
        push();
        requireTable(s);
        auto tableIndex = s.top();
        pushTo(s, key);
        getTableEntry(s, tableIndex);
        return popFrom!T(s, -1);
    }

    /// Get an entry; `found` is false when the value is nil.
    T tryGet(T, K)(K key, out bool found)
    {
        auto s = state();
        s.ensureOpen();
        StackGuard guard = StackGuard(s);
        push();
        requireTable(s);
        auto tableIndex = s.top();
        pushTo(s, key);
        getTableEntry(s, tableIndex);
        if (lua_type(s.handle, -1) == LUA_TNIL)
        {
            found = false;
            return T.init;
        }
        found = true;
        return popFrom!T(s, -1);
    }

    /// Set a field/entry. `key` must not be nil or NaN.
    ///
    /// A table with a `__newindex` metamethod runs the assignment under `pcall`,
    /// so errors raised by the metamethod become `LuaException` instead of
    /// escaping as an unprotected Lua error.
    void set(T, K)(K key, T value)
    {
        auto s = state();
        s.ensureOpen();
        StackGuard guard = StackGuard(s);
        push();
        requireTable(s);
        auto tableIndex = s.top();
        pushTo(s, key);
        checkSettableKey(s, -1);
        pushTo(s, value);
        setTableEntry(s, tableIndex);
    }

    /// Set a field/entry without checking that the receiver is a table.
    ///
    /// Use this on hot paths after confirming the handle refers to a table.
    /// It never allocates for primitive keys and values.
    void setUnchecked(T, K)(K key, T value)
    {
        auto s = state();
        StackGuard guard = StackGuard(s);
        push();
        pushTo(s, key);
        pushTo(s, value);
        lua_settable(s.handle, -3);
    }

    LuaValue opIndex(K)(K key)
    {
        return get!LuaValue(key);
    }

    void opIndexAssign(T, K)(T value, K key)
    {
        set(key, value);
    }

    size_t length() @nogc nothrow
    {
        StackGuard guard = StackGuard(state());
        push();
        return raw.rawLen(state().handle, -1);
    }

    /// Checked table length. Honors a `__len` metamethod on Lua 5.2+ and
    /// throws `LuaException` if it raises. A `__len` result that is not an
    /// integer throws `LuaTypeException`. Lua 5.1/LuaJIT ignore table
    /// `__len` and return the raw length.
    size_t lengthOf()
    {
        auto s = state();
        s.ensureOpen();
        StackGuard guard = StackGuard(s);
        push();                                     // [table]
        static if (LUA_VERSION_NUM == 501)
            return raw.rawLen(s.handle, -1);
        else
        {
            auto tableIndex = s.top();
            pushCFunction(s.handle, &lenThunk);     // [table, thunk]
            raw.insert(s.handle, tableIndex);       // [thunk, table]
            auto status = raw.pcall(s.handle, 1, 1, 0);
            if (status != LUA_OK)
                throw tableError(s, status);
            return popFrom!size_t(s, -1);
        }
    }

    /// Iterate the table. Supports `break`/`return` from the loop body.
    ///
    /// Each step runs under `pcall`, so `lua_next` raising
    /// `invalid key to 'next'` (for example because the loop body added a new
    /// key) becomes a `LuaException` instead of an unprotected error.
    int opApply(scope int delegate(LuaValue key, LuaValue value) dg)
    {
        auto s = state();
        s.ensureOpen();
        StackGuard guard = StackGuard(s);
        push();
        requireTable(s);
        auto tableIndex = s.top();

        LuaValue currentKey; // nil starts the traversal
        while (true)
        {
            pushCFunction(s.handle, &nextThunk);   // [table, thunk]
            lua_pushvalue(s.handle, tableIndex);   // [table, thunk, table]
            currentKey.push(s);                    // [table, thunk, table, key]
            auto status = raw.pcall(s.handle, 2, LUA_MULTRET, 0);
            if (status != LUA_OK)
                throw tableError(s, status);

            auto produced = s.top() - tableIndex;
            if (produced == 0)
                break;

            auto key = LuaValue.fromStack(s, tableIndex + 1);
            auto value = LuaValue.fromStack(s, tableIndex + 2);
            s.pop(2);
            currentKey = key;

            auto result = dg(key, value);
            if (result != 0)
                return result;
        }
        return 0;
    }
}

private string weaknessMode(LuaWeakness weakness)
{
    final switch (weakness)
    {
        case LuaWeakness.none:   return "";
        case LuaWeakness.keys:   return "k";
        case LuaWeakness.values: return "v";
        case LuaWeakness.both:   return "kv";
    }
}
