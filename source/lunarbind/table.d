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

    /// Create a fresh, empty table.
    static LuaTable create(LuaState state, int arrayHint = 0, int recordHint = 0)
    {
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
    /// Set this once, before filling the table: Lua only reads `__mode` when
    /// it collects the table's entries.
    void setWeakness(LuaWeakness weakness)
    {
        if (weakness == LuaWeakness.none)
            return;

        auto s = state();
        StackGuard guard = StackGuard(s);
        push();                                  // [table]
        if (lua_getmetatable(s.handle, -1) == 0)
        {
            lua_createtable(s.handle, 0, 1);      // [table, metatable]
            lua_pushvalue(s.handle, -1);          // [table, metatable, metatable]
            lua_setmetatable(s.handle, -3);       // [table, metatable]
        }

        auto mode = weaknessMode(weakness);
        lua_pushlstring(s.handle, mode.ptr, mode.length);
        lua_setfield(s.handle, -2, "__mode");    // [table, metatable]
    }

    LuaState state() @nogc nothrow { return _ref.state(); }
    LuaRef ref_() @nogc nothrow { return _ref; }
    void push() @nogc nothrow { _ref.push(); }
    void pushInto(LuaState target) { _ref.pushInto(target); }

    /// Get a field/entry. `key` may be a string, integer, or any pushable value.
    T get(T, K)(K key)
    {
        auto s = state();
        StackGuard guard = StackGuard(s);
        push();
        requireTable(s);
        pushTo(s, key);
        lua_gettable(s.handle, -2);
        return popFrom!T(s, -1);
    }

    /// Get an entry; `found` is false when the value is nil.
    T tryGet(T, K)(K key, out bool found)
    {
        auto s = state();
        StackGuard guard = StackGuard(s);
        push();
        requireTable(s);
        pushTo(s, key);
        lua_gettable(s.handle, -2);
        if (lua_type(s.handle, -1) == LUA_TNIL)
        {
            found = false;
            return T.init;
        }
        found = true;
        return popFrom!T(s, -1);
    }

    void set(T, K)(K key, T value)
    {
        auto s = state();
        StackGuard guard = StackGuard(s);
        push();
        requireTable(s);
        pushTo(s, key);
        pushTo(s, value);
        lua_settable(s.handle, -3);
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

    /// Iterate the table. Supports `break`/`return` from the loop body.
    int opApply(scope int delegate(LuaValue key, LuaValue value) dg)
    {
        auto s = state();
        StackGuard guard = StackGuard(s);
        push();
        requireTable(s);
        auto tableIndex = s.top();
        lua_pushnil(s.handle);
        while (lua_next(s.handle, tableIndex) != 0)
        {
            auto key = LuaValue.fromStack(s, -2);
            auto value = LuaValue.fromStack(s, -1);
            s.pop(1); // pop value, keep key for lua_next
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
