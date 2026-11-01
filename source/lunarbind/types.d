/// Public status/type/error types, independent of the C bindings.
module lunarbind.types;

/// Lua status codes (LUA_OK / LUA_YIELD / LUA_ERR*).
enum LuaStatus : int
{
    ok        = 0,
    yield     = 1,
    errRun    = 2,
    errSyntax = 3,
    errMem    = 4,
    errErr    = 5,
}

/// Lua value kinds. `integer` is only reported on Lua 5.3+.
enum LuaType : int
{
    none          = -1,
    nil           = 0,
    boolean       = 1,
    lightUserdata = 2,
    number        = 3,
    string        = 4,
    table         = 5,
    function_     = 6,
    userdata      = 7,
    thread        = 8,
    integer       = 9, // synthetic: a Lua 5.3+ integer stored as LUA_TNUMBER
}

/// Base class for all errors raised by lunarbind.
class LuaException : Exception
{
    LuaStatus status;
    string traceback;

    this(string msg, LuaStatus status = LuaStatus.errRun, string traceback = null,
         string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
        this.status = status;
        this.traceback = traceback;
    }
}

/// A value on the Lua stack had an unexpected type.
class LuaTypeException : LuaException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, LuaStatus.errRun, null, file, line, next);
    }
}

/// A function was called with the wrong number of arguments.
class LuaArgumentException : LuaException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, LuaStatus.errRun, null, file, line, next);
    }
}

/// The Lua stack could not be restored / was used incorrectly.
class LuaStackException : LuaException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, LuaStatus.errRun, null, file, line, next);
    }
}

/// The state handle was used after close, or a reference outlived its state.
class LuaStateException : LuaException
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, LuaStatus.errRun, null, file, line, next);
    }
}


