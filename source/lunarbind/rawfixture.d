/// Raw Lua C callback fixtures used by the unittest build.
module lunarbind.rawfixture;

import lunarbind.raw : lua_Integer, lua_State, lua_gettop, lua_pushinteger,
                       luaL_checkinteger;

/// Return the number of Lua arguments it received.
extern(C) int rawArgumentCount(lua_State* L) nothrow
{
    lua_pushinteger(L, lua_gettop(L));
    return 1;
}

/// Add every integer argument and return the total.
extern(C) int rawSum(lua_State* L) nothrow
{
    lua_Integer total;
    auto count = lua_gettop(L);
    foreach (i; 1 .. count + 1)
        total += luaL_checkinteger(L, i);
    lua_pushinteger(L, total);
    return 1;
}

/// Typed half of a mixed overload set.
int mixed(int value)
{
    return value * 2;
}

/// Raw half of a mixed overload set. Typed overloads are tried first; this one
/// handles calls whose arguments do not match them.
extern(C) int mixed(lua_State* L) nothrow
{
    lua_pushinteger(L, -1);
    return 1;
}
