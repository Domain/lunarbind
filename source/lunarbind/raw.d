/// Minimal, version-aware Lua C API bindings.
///
/// This module deliberately has **no external D dependencies**.  It only
/// declares the C entry points the high-level layers use, plus small D
/// helpers that paper over the differences between Lua 5.1 (and LuaJIT),
/// 5.2, 5.3, 5.4 and 5.5.
///
/// Select exactly one version via a DUB configuration (or `-version=`):
/// `LUA_51`, `LUA_52`, `LUA_53`, `LUA_54`, `LUA_55`; add `LUAJIT` for LuaJIT.
module lunarbind.raw;

version (LUA_55)
    enum LUA_VERSION_NUM = 505;
else version (LUA_54)
    enum LUA_VERSION_NUM = 504;
else version (LUA_53)
    enum LUA_VERSION_NUM = 503;
else version (LUA_52)
    enum LUA_VERSION_NUM = 502;
else version (LUA_51)
    enum LUA_VERSION_NUM = 501;
else
    static assert(0, "lunarbind: select a Lua version (LUA_51, LUA_52, LUA_53, LUA_54 or LUA_55)");

version (LUAJIT)
    enum isLuaJIT = true;
else
    enum isLuaJIT = false;

// ---------------------------------------------------------------------------
// Basic types
// ---------------------------------------------------------------------------

struct lua_State;

alias lua_Number  = double;
alias lua_Integer = ptrdiff_t;
alias lua_Unsigned = ulong;
alias lua_KContext = ptrdiff_t;

alias lua_CFunction = extern(C) int function(lua_State*);
alias lua_KFunction = extern(C) int function(lua_State*, int, lua_KContext);
alias lua_Alloc     = extern(C) void* function(void* ud, void* ptr, size_t osize, size_t nsize);

struct luaL_Reg
{
    const(char)* name;
    lua_CFunction func;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

enum int LUA_MULTRET = -1;

enum int LUA_REGISTRYINDEX = (LUA_VERSION_NUM == 501) ? -10000
    : (LUA_VERSION_NUM >= 505) ? -(int.max / 2 + 1000)
    : -1001000;
enum int LUA_GLOBALSINDEX = -10002;
enum int LUA_RIDX_GLOBALS = 2;
enum int LUA_NOREF = -2;
enum int LUA_REFNIL = -1;

enum int LUA_TNONE = -1;
enum int LUA_TNIL = 0;
enum int LUA_TBOOLEAN = 1;
enum int LUA_TLIGHTUSERDATA = 2;
enum int LUA_TNUMBER = 3;
enum int LUA_TSTRING = 4;
enum int LUA_TTABLE = 5;
enum int LUA_TFUNCTION = 6;
enum int LUA_TUSERDATA = 7;
enum int LUA_TTHREAD = 8;

enum int LUA_OK = 0;
enum int LUA_YIELD = 1;
enum int LUA_ERRRUN = 2;
enum int LUA_ERRSYNTAX = 3;
enum int LUA_ERRMEM = 4;

// Lua 5.2/5.3 insert LUA_ERRGCMM, shifting LUA_ERRERR and LUA_ERRFILE.
static if (LUA_VERSION_NUM == 502 || LUA_VERSION_NUM == 503)
{
    enum int LUA_ERRGCMM = 5;
    enum int LUA_ERRERR = 6;
    enum int LUA_ERRFILE = 7;
}
else
{
    enum int LUA_ERRGCMM = 5; // not produced by these versions
    enum int LUA_ERRERR = 5;
    enum int LUA_ERRFILE = 6;
}

enum int LUA_OPEQ = 0;
enum int LUA_OPLT = 1;
enum int LUA_OPLE = 2;

// GC operations (the subset we expose; names differ across versions, values
// 0..5 are stable for the operations used by lunarbind).
enum int LUA_GCSTOP = 0;
enum int LUA_GCRESTART = 1;
enum int LUA_GCCOLLECT = 2;
enum int LUA_GCCOUNT = 3;
enum int LUA_GCCOUNTB = 4;
enum int LUA_GCSTEP = 5;

// GC parameter operations. Lua 5.5 replaced the individual setter operations
// with LUA_GCPARAM and moved/renumbered the mode operations.
static if (LUA_VERSION_NUM >= 505)
{
    enum int LUA_GCISRUNNING = 6;
    enum int LUA_GCGEN = 7;
    enum int LUA_GCINC = 8;
    enum int LUA_GCPARAM = 9;

    enum int LUA_GCPMINORMUL = 0;
    enum int LUA_GCPMAJORMINOR = 1;
    enum int LUA_GCPMINORMAJOR = 2;
    enum int LUA_GCPPAUSE = 3;
    enum int LUA_GCPSTEPMUL = 4;
    enum int LUA_GCPSTEPSIZE = 5;
}
else static if (LUA_VERSION_NUM >= 504)
{
    enum int LUA_GCSETPAUSE = 6;
    enum int LUA_GCSETSTEPMUL = 7;
    enum int LUA_GCISRUNNING = 9;
    enum int LUA_GCGEN = 10;
    enum int LUA_GCINC = 11;
}
else static if (LUA_VERSION_NUM >= 502)
{
    enum int LUA_GCSETPAUSE = 6;
    enum int LUA_GCSETSTEPMUL = 7;
    enum int LUA_GCISRUNNING = 9;
}
else
{
    enum int LUA_GCSETPAUSE = 6;
    enum int LUA_GCSETSTEPMUL = 7;

    version (LUAJIT)
        enum int LUA_GCISRUNNING = 9;
}

// ---------------------------------------------------------------------------
// C API: functions present in every supported version
// ---------------------------------------------------------------------------

extern(C) nothrow @nogc
{
    lua_State* luaL_newstate();
    void       lua_close(lua_State* L);
    lua_State* lua_newthread(lua_State* L);
    int        lua_pushthread(lua_State* L);
    lua_CFunction lua_atpanic(lua_State* L, lua_CFunction panicf);
    lua_Number lua_version(lua_State* L);

    int  lua_gettop(lua_State* L);
    void lua_settop(lua_State* L, int idx);
    void lua_pushvalue(lua_State* L, int idx);
    int  lua_checkstack(lua_State* L, int n);
    void lua_xmove(lua_State* from, lua_State* to, int n);

    int         lua_type(lua_State* L, int idx);
    const(char)* lua_typename(lua_State* L, int tp);
    lua_Number  lua_tonumber(lua_State* L, int idx);
    lua_Integer lua_tointeger(lua_State* L, int idx);
    int         lua_toboolean(lua_State* L, int idx);
    const(char)* lua_tolstring(lua_State* L, int idx, size_t* len);
    lua_CFunction lua_tocfunction(lua_State* L, int idx);
    void*       lua_touserdata(lua_State* L, int idx);
    lua_State*  lua_tothread(lua_State* L, int idx);
    int         lua_rawequal(lua_State* L, int idx1, int idx2);

    void lua_pushnil(lua_State* L);
    void lua_pushnumber(lua_State* L, lua_Number n);
    void lua_pushinteger(lua_State* L, lua_Integer n);
    void lua_pushlstring(lua_State* L, const(char)* s, size_t len);
    void lua_pushcclosure(lua_State* L, lua_CFunction fn, int n);
    void lua_pushboolean(lua_State* L, int b);
    void lua_pushlightuserdata(lua_State* L, void* p);

    int  lua_getglobal(lua_State* L, const(char)* name);
    void lua_setglobal(lua_State* L, const(char)* name);
    int  lua_gettable(lua_State* L, int idx);
    void lua_settable(lua_State* L, int idx);
    int  lua_getfield(lua_State* L, int idx, const(char)* k);
    void lua_setfield(lua_State* L, int idx, const(char)* k);
    int  lua_rawget(lua_State* L, int idx);
    void lua_rawset(lua_State* L, int idx);
    int  lua_rawgeti(lua_State* L, int idx, lua_Integer n);
    void lua_rawseti(lua_State* L, int idx, lua_Integer n);
    void lua_createtable(lua_State* L, int narr, int nrec);
    int  lua_getmetatable(lua_State* L, int objindex);
    int  lua_setmetatable(lua_State* L, int objindex);
    void lua_call(lua_State* L, int nargs, int nresults); // macro pre-5.2; real for 5.1
    int  lua_error(lua_State* L);
    int  lua_next(lua_State* L, int idx);
    void lua_concat(lua_State* L, int n);
    int  lua_status(lua_State* L);

    int  luaL_loadstring(lua_State* L, const(char)* s);
    int  luaL_newmetatable(lua_State* L, const(char)* tname);
    void* luaL_checkudata(lua_State* L, int ud, const(char)* tname);
    int  luaL_ref(lua_State* L, int t);
    void luaL_unref(lua_State* L, int t, int ref_);
    void luaL_argerror(lua_State* L, int arg, const(char)* extramsg);
    const(char)* luaL_checklstring(lua_State* L, int arg, size_t* len);
    lua_Integer luaL_checkinteger(lua_State* L, int arg);
    lua_Number  luaL_checknumber(lua_State* L, int arg);
    void luaL_checktype(lua_State* L, int arg, int t);
    void luaL_checkany(lua_State* L, int arg);
}

// ---------------------------------------------------------------------------
// Standard library openers and selective loading
// ---------------------------------------------------------------------------

extern(C) nothrow @nogc
{
    int luaopen_base(lua_State* L);
    int luaopen_package(lua_State* L);
    int luaopen_coroutine(lua_State* L); // Lua 5.2+
    int luaopen_table(lua_State* L);
    int luaopen_io(lua_State* L);
    int luaopen_os(lua_State* L);
    int luaopen_string(lua_State* L);
    int luaopen_math(lua_State* L);
    int luaopen_debug(lua_State* L);
    int luaopen_utf8(lua_State* L);    // Lua 5.3+
    int luaopen_bit32(lua_State* L);   // Lua 5.2
    int luaopen_bit(lua_State* L);     // LuaJIT
    int luaopen_jit(lua_State* L);     // LuaJIT
}

static if (LUA_VERSION_NUM >= 502)
{
    extern(C) nothrow @nogc
    {
        void luaL_requiref(lua_State* L, const(char)* modname,
                           lua_CFunction openf, int glb);
    }
}

static if (LUA_VERSION_NUM >= 505)
{
    extern(C) nothrow @nogc
    {
        lua_State* lua_newstate(lua_Alloc f, void* ud, uint seed);
        void luaL_openselectedlibs(lua_State* L, int load, int preload);
    }

    // Lua 5.5 turns luaL_openlibs into a macro over luaL_openselectedlibs.
    void luaL_openlibs(lua_State* L) nothrow @nogc
    {
        luaL_openselectedlibs(L, -1, 0);
    }
}
else
{
    extern(C) nothrow @nogc
    {
        lua_State* lua_newstate(lua_Alloc f, void* ud);
        void luaL_openlibs(lua_State* L);
    }
}

static if (LUA_VERSION_NUM == 501)
{
    extern(C) nothrow @nogc
    {
        int luaL_loadfile(lua_State* L, const(char)* filename);
    }
}
else
{
    extern(C) nothrow @nogc
    {
        int luaL_loadfilex(lua_State* L, const(char)* filename,
                           const(char)* mode);
    }

    // luaL_loadfile is a macro over luaL_loadfilex in Lua 5.2+.
    int luaL_loadfile(lua_State* L, const(char)* filename) nothrow @nogc
    {
        return luaL_loadfilex(L, filename, null);
    }
}

// ---------------------------------------------------------------------------
// Lua 5.1 / LuaJIT API
// ---------------------------------------------------------------------------

static if (LUA_VERSION_NUM == 501)
{
    extern(C) nothrow @nogc
    {
        int  lua_pcall(lua_State* L, int nargs, int nresults, int errfunc);
        void lua_insert(lua_State* L, int idx);
        void lua_remove(lua_State* L, int idx);
        void lua_replace(lua_State* L, int idx);
        size_t lua_objlen(lua_State* L, int idx);
        void* lua_newuserdata(lua_State* L, size_t size);
        int  lua_yield(lua_State* L, int nresults);
        int  lua_resume(lua_State* L, int nargs);
        int  lua_gc(lua_State* L, int what, int data);
        int  lua_equal(lua_State* L, int idx1, int idx2);
        int  lua_lessthan(lua_State* L, int idx1, int idx2);
        int  luaL_loadbuffer(lua_State* L, const(char)* buff, size_t sz, const(char)* name);
        void luaL_register(lua_State* L, const(char)* libname, const(luaL_Reg)* l);
    }
}
else
{
    extern(C) nothrow @nogc
    {
        int  lua_absindex(lua_State* L, int idx);
        void lua_copy(lua_State* L, int fromidx, int toidx);
        int  lua_pcallk(lua_State* L, int nargs, int nresults, int errfunc,
                        lua_KContext ctx, lua_KFunction k);
        void lua_callk(lua_State* L, int nargs, int nresults,
                       lua_KContext ctx, lua_KFunction k);
        int  lua_yieldk(lua_State* L, int nresults, lua_KContext ctx, lua_KFunction k);
        lua_Integer lua_tointegerx(lua_State* L, int idx, int* isnum);
        lua_Number lua_tonumberx(lua_State* L, int idx, int* isnum);
        size_t lua_rawlen(lua_State* L, int idx);
        void lua_len(lua_State* L, int idx);
        int  lua_compare(lua_State* L, int idx1, int idx2, int op);
        int  lua_rawgetp(lua_State* L, int idx, const(void)* p);
        void lua_rawsetp(lua_State* L, int idx, const(void)* p);
        const(char)* luaL_tolstring(lua_State* L, int idx, size_t* len);
        void luaL_setfuncs(lua_State* L, const(luaL_Reg)* l, int nup);
        int  luaL_loadbufferx(lua_State* L, const(char)* buff, size_t sz,
                              const(char)* name, const(char)* mode);
        void luaL_traceback(lua_State* L, lua_State* L1, const(char)* msg, int level);
    }

    static if (LUA_VERSION_NUM == 502)
    {
        extern(C) nothrow @nogc
        {
            void lua_insert(lua_State* L, int idx);
            void lua_remove(lua_State* L, int idx);
            void lua_replace(lua_State* L, int idx);
        }
    }

    static if (LUA_VERSION_NUM >= 503)
    {
        extern(C) nothrow @nogc
        {
            void lua_rotate(lua_State* L, int idx, int n);
            int  lua_isinteger(lua_State* L, int idx);
            int  lua_geti(lua_State* L, int idx, lua_Integer n);
            void lua_seti(lua_State* L, int idx, lua_Integer n);
        }
    }

    static if (LUA_VERSION_NUM >= 504)
    {
        extern(C) nothrow @nogc
        {
            void* lua_newuserdatauv(lua_State* L, size_t size, int nuvalue);
            int   lua_resume(lua_State* L, lua_State* from, int nargs, int* nresults);
            int   lua_gc(lua_State* L, int what, ...);
            void  lua_toclose(lua_State* L, int idx);
            void  lua_closeslot(lua_State* L, int idx);
        }
    }
    else
    {
        extern(C) nothrow @nogc
        {
            void* lua_newuserdata(lua_State* L, size_t size);
            int   lua_resume(lua_State* L, lua_State* from, int nargs);
            int   lua_gc(lua_State* L, int what, int data);
        }
    }
}

// ---------------------------------------------------------------------------
// Small compatibility helpers
// ---------------------------------------------------------------------------

@nogc nothrow
{
    int absIndex(lua_State* L, int idx)
    {
        static if (LUA_VERSION_NUM == 501)
        {
            if (idx > 0 || idx <= LUA_REGISTRYINDEX)
                return idx;
            return lua_gettop(L) + idx + 1;
        }
        else
            return lua_absindex(L, idx);
    }

    void pop(lua_State* L, int n) { lua_settop(L, -n - 1); }

    // In Lua 5.1 these are macros, not exported symbols.
    int getGlobal(lua_State* L, const(char)* name)
    {
        static if (LUA_VERSION_NUM == 501)
            return lua_getfield(L, LUA_GLOBALSINDEX, name);
        else
            return lua_getglobal(L, name);
    }

    void setGlobal(lua_State* L, const(char)* name)
    {
        static if (LUA_VERSION_NUM == 501)
            lua_setfield(L, LUA_GLOBALSINDEX, name);
        else
            lua_setglobal(L, name);
    }

    // Allocation-free variants that take a Lua string slice instead of a
    // NUL-terminated C string.
    int getGlobalString(lua_State* L, const(char)[] name)
    {
        pushGlobalTable(L);
        lua_pushlstring(L, name.ptr, name.length);
        lua_gettable(L, -2);
        remove(L, -2);
        return lua_type(L, -1);
    }

    void setGlobalString(lua_State* L, const(char)[] name)
    {
        // The value is on top; keep it while building globals[key].
        pushGlobalTable(L);
        lua_pushlstring(L, name.ptr, name.length);
        lua_pushvalue(L, -3);
        lua_settable(L, -3);
        pop(L, 2);
    }

    void pushCFunction(lua_State* L, lua_CFunction fn) { lua_pushcclosure(L, fn, 0); }

    void pushGlobalTable(lua_State* L)
    {
        static if (LUA_VERSION_NUM == 501)
            lua_pushvalue(L, LUA_GLOBALSINDEX);
        else
            lua_rawgeti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
    }

    int upvalueIndex(int i)
    {
        static if (LUA_VERSION_NUM == 501)
            return LUA_GLOBALSINDEX - i;
        else
            return LUA_REGISTRYINDEX - i;
    }

    void newTable(lua_State* L) { lua_createtable(L, 0, 0); }

    void* newUserdata(lua_State* L, size_t size)
    {
        static if (LUA_VERSION_NUM >= 504)
            return lua_newuserdatauv(L, size, 0);
        else
            return lua_newuserdata(L, size);
    }

    size_t rawLen(lua_State* L, int idx)
    {
        static if (LUA_VERSION_NUM == 501)
            return lua_objlen(L, idx);
        else
            return lua_rawlen(L, idx);
    }

    int isInteger(lua_State* L, int idx)
    {
        static if (LUA_VERSION_NUM >= 503)
            return lua_isinteger(L, idx);
        else
            return 0;
    }

    lua_Integer toIntegerX(lua_State* L, int idx, int* isnum)
    {
        static if (LUA_VERSION_NUM == 501)
        {
            if (isnum)
                *isnum = lua_type(L, idx) == LUA_TNUMBER;
            return lua_tointeger(L, idx);
        }
        else
            return lua_tointegerx(L, idx, isnum);
    }

    lua_Number toNumberX(lua_State* L, int idx, int* isnum)
    {
        static if (LUA_VERSION_NUM == 501)
        {
            if (isnum)
                *isnum = lua_type(L, idx) == LUA_TNUMBER;
            return lua_tonumber(L, idx);
        }
        else
            return lua_tonumberx(L, idx, isnum);
    }

    int pcall(lua_State* L, int nargs, int nresults, int errfunc)
    {
        static if (LUA_VERSION_NUM == 501)
            return lua_pcall(L, nargs, nresults, errfunc);
        else
            return lua_pcallk(L, nargs, nresults, errfunc, 0, null);
    }

    void call(lua_State* L, int nargs, int nresults)
    {
        static if (LUA_VERSION_NUM == 501)
            lua_call(L, nargs, nresults);
        else
            lua_callk(L, nargs, nresults, 0, null);
    }

    int yield(lua_State* L, int nresults)
    {
        static if (LUA_VERSION_NUM == 501)
            return lua_yield(L, nresults);
        else
            return lua_yieldk(L, nresults, 0, null);
    }

    int resume(lua_State* L, lua_State* from, int nargs, int* nresults = null)
    {
        static if (LUA_VERSION_NUM == 501)
            return lua_resume(L, nargs);
        else static if (LUA_VERSION_NUM >= 504)
        {
            // Lua 5.4 dereferences nresults unconditionally.
            int localResults;
            return lua_resume(L, from, nargs,
                              nresults is null ? &localResults : nresults);
        }
        else
            return lua_resume(L, from, nargs);
    }

    int gc(lua_State* L, int what, int data)
    {
        static if (LUA_VERSION_NUM >= 505)
            return lua_gc(L, what, cast(size_t) data); // 5.5 reads size_t for STEP
        else
            return lua_gc(L, what, data);
    }

    int gcParam(lua_State* L, int param, int data)
    {
        static if (LUA_VERSION_NUM >= 505)
            return lua_gc(L, LUA_GCPARAM, param, data);
        else
            return -1; // callers guard on the Lua version
    }

    int equal(lua_State* L, int idx1, int idx2)
    {
        static if (LUA_VERSION_NUM == 501)
            return lua_equal(L, idx1, idx2);
        else
            return lua_compare(L, idx1, idx2, LUA_OPEQ);
    }

    int lessThan(lua_State* L, int idx1, int idx2)
    {
        static if (LUA_VERSION_NUM == 501)
            return lua_lessthan(L, idx1, idx2);
        else
            return lua_compare(L, idx1, idx2, LUA_OPLT);
    }

    void insert(lua_State* L, int idx)
    {
        static if (LUA_VERSION_NUM <= 502)
            lua_insert(L, idx);
        else
            lua_rotate(L, idx, 1);
    }

    void remove(lua_State* L, int idx)
    {
        static if (LUA_VERSION_NUM <= 502)
            lua_remove(L, idx);
        else
        {
            lua_rotate(L, idx, -1);
            pop(L, 1);
        }
    }

    void replace(lua_State* L, int idx)
    {
        static if (LUA_VERSION_NUM <= 502)
            lua_replace(L, idx);
        else
        {
            lua_copy(L, -1, idx);
            pop(L, 1);
        }
    }

    void getMetatable(lua_State* L, const(char)* tname)
    {
        lua_getfield(L, LUA_REGISTRYINDEX, tname);
    }

    void setMetatable(lua_State* L, const(char)* tname)
    {
        getMetatable(L, tname);
        lua_setmetatable(L, -2);
    }

    void pushString(lua_State* L, const(char)[] s)
    {
        lua_pushlstring(L, s.ptr, s.length);
    }

    int loadString(lua_State* L, const(char)[] code, const(char)* name = "<string>")
    {
        static if (LUA_VERSION_NUM == 501)
            return luaL_loadbuffer(L, code.ptr, code.length, name);
        else
            return luaL_loadbufferx(L, code.ptr, code.length, name, null);
    }

    void setFuncs(lua_State* L, const(luaL_Reg)[] regs)
    {
        static if (LUA_VERSION_NUM == 501)
        {
            // No luaL_setfuncs in 5.1; do it ourselves.
            foreach (r; regs)
            {
                if (r.name is null)
                    break;
                pushCFunction(L, r.func);
                lua_setfield(L, -2, r.name);
            }
        }
        else
            luaL_setfuncs(L, regs.ptr, 0);
    }

    void newLib(lua_State* L, const(luaL_Reg)[] regs)
    {
        lua_createtable(L, 0, cast(int)regs.length);
        setFuncs(L, regs);
    }
}


