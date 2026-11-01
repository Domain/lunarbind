/// Registry-backed Lua table handle.
module lunarbind.table;

import lunarbind.raw;
static import raw = lunarbind.raw;
import lunarbind.state;
import lunarbind.types;
import lunarbind.value;
import lunarbind.conv;

struct LuaTable
{
    private LuaRef _ref;

    this(LuaRef ref_)
    {
        _ref = ref_;
    }

    LuaState state() { return _ref.state(); }
    LuaRef ref_() @nogc nothrow { return _ref; }
    void push() @nogc nothrow { _ref.push(); }
    void pushInto(LuaState target) { _ref.pushInto(target); }

    /// Get a field/entry. `key` may be a string, integer, or any pushable value.
    T get(T, K)(K key)
    {
        StackGuard guard = StackGuard(state());
        push();
        pushTo(state(), key);
        lua_gettable(state().handle, -2);
        return popFrom!T(state(), -1);
    }

    /// Get an entry; `found` is false when the value is nil.
    T tryGet(T, K)(K key, out bool found)
    {
        StackGuard guard = StackGuard(state());
        push();
        pushTo(state(), key);
        lua_gettable(state().handle, -2);
        if (lua_type(state().handle, -1) == LUA_TNIL)
        {
            found = false;
            return T.init;
        }
        found = true;
        return popFrom!T(state(), -1);
    }

    void set(T, K)(K key, T value)
    {
        StackGuard guard = StackGuard(state());
        push();
        pushTo(state(), key);
        pushTo(state(), value);
        lua_settable(state().handle, -3);
    }

    LuaValue opIndex(K)(K key)
    {
        return get!LuaValue(key);
    }

    void opIndexAssign(T, K)(T value, K key)
    {
        set(key, value);
    }

    size_t length()
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
