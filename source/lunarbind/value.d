/// Dynamic Lua value used at the untyped edges of the API.
module lunarbind.value;

import lunarbind.raw;
import lunarbind.state;
import lunarbind.types;

struct LuaValue
{
    LuaType kind = LuaType.nil;
    bool booleanValue;
    lua_Integer integerValue;
    lua_Number numberValue;
    string stringValue;
    void* userdataValue;
    lua_State* threadValue;
    LuaRef ref_; // table / function / full userdata / thread

    this(lua_Integer v) { kind = LuaType.integer; integerValue = v; }
    this(lua_Number v) { kind = LuaType.number; numberValue = v; }
    this(bool v) { kind = LuaType.boolean; booleanValue = v; }
    this(string v) { kind = LuaType.string; stringValue = v; }
    this(LuaType kind, LuaRef ref__) { this.kind = kind; this.ref_ = ref__; }

    static LuaValue nil() { return LuaValue(); }
    static LuaValue fromBool(bool v) { return LuaValue(v); }
    static LuaValue fromInteger(lua_Integer v) { return LuaValue(v); }
    static LuaValue fromNumber(lua_Number v) { return LuaValue(v); }
    static LuaValue fromString(string v) { return LuaValue(v); }
    static LuaValue fromRef(LuaType kind, LuaRef r) { return LuaValue(kind, r); }

    bool isNil() const @nogc nothrow { return kind == LuaType.nil; }

    /// Copy the value at `idx` into a dynamic LuaValue.
    ///
    /// Throws `LuaStateException` when `state` is closed.
    static LuaValue fromStack(LuaState state, int idx)
    {
        state.ensureOpen();
        auto t = lua_type(state.handle, idx);
        final switch (t)
        {
            case LUA_TNONE:
            case LUA_TNIL:
                return LuaValue();
            case LUA_TBOOLEAN:
                return LuaValue(lua_toboolean(state.handle, idx) != 0);
            case LUA_TNUMBER:
                static if (LUA_VERSION_NUM >= 503)
                {
                    if (lua_isinteger(state.handle, idx))
                        return LuaValue(cast(lua_Integer) toIntegerX(state.handle, idx, null));
                }
                return LuaValue(cast(lua_Number) toNumberX(state.handle, idx, null));
            case LUA_TSTRING:
            {
                size_t len;
                auto p = lua_tolstring(state.handle, idx, &len);
                return LuaValue(p[0 .. len].idup);
            }
            case LUA_TTABLE:
                return LuaValue(LuaType.table, LuaRef.make(state, idx));
            case LUA_TFUNCTION:
                return LuaValue(LuaType.function_, LuaRef.make(state, idx));
            case LUA_TUSERDATA:
            {
                auto value = LuaValue(LuaType.userdata, LuaRef.make(state, idx));
                value.userdataValue = lua_touserdata(state.handle, idx);
                return value;
            }
            case LUA_TLIGHTUSERDATA:
            {
                LuaValue value;
                value.kind = LuaType.lightUserdata;
                value.userdataValue = lua_touserdata(state.handle, idx);
                return value;
            }
            case LUA_TTHREAD:
            {
                auto value = LuaValue(LuaType.thread, LuaRef.make(state, idx));
                value.threadValue = lua_tothread(state.handle, idx);
                return value;
            }
        }
    }

    /// Push this value onto the stack.
    ///
    /// Throws `LuaStateException` when `state` is closed or when a referenced
    /// value belongs to a different Lua state. Use `pushUnchecked` on hot paths.
    void push(LuaState state)
    {
        state.ensureOpen();
        switch (kind)
        {
            case LuaType.table:
            case LuaType.function_:
            case LuaType.thread:
            case LuaType.userdata:
                if (!ref_.isNull() && !ref_.belongsTo(state))
                    throw new LuaStateException("LuaValue belongs to a different Lua state");
                break;
            default:
                break;
        }

        pushUnchecked(state);
    }

    /// Push without checking that a referenced value belongs to `state`.
    ///
    /// Use this on hot paths after verifying state ownership yourself. It never
    /// allocates and never throws.
    void pushUnchecked(LuaState state) @nogc nothrow
    {
        final switch (kind)
        {
            case LuaType.none:
            case LuaType.nil:
                lua_pushnil(state.handle);
                break;
            case LuaType.boolean:
                lua_pushboolean(state.handle, booleanValue ? 1 : 0);
                break;
            case LuaType.integer:
                lua_pushinteger(state.handle, integerValue);
                break;
            case LuaType.number:
                lua_pushnumber(state.handle, numberValue);
                break;
            case LuaType.string:
                lua_pushlstring(state.handle, stringValue.ptr, stringValue.length);
                break;
            case LuaType.table:
            case LuaType.function_:
            case LuaType.thread:
            case LuaType.userdata:
                if (ref_.isNull())
                    lua_pushnil(state.handle);
                else
                    lua_rawgeti(state.handle, LUA_REGISTRYINDEX, ref_.ref_());
                break;
            case LuaType.lightUserdata:
                lua_pushlightuserdata(state.handle, userdataValue);
                break;
        }
    }
}
