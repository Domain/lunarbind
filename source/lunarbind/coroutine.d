/// Lua coroutine handles.
module lunarbind.coroutine;

import lunarbind.raw;
static import raw = lunarbind.raw;
import lunarbind.state;
import lunarbind.types;
import lunarbind.value;
import lunarbind.conv;
import lunarbind.function_ : LuaFunction;

/// A Lua coroutine (thread) owned through a registry reference.
///
/// A thread starts with a function on its stack. `resume` pushes arguments,
/// runs until the next yield or return, and collects the produced values;
/// `resumeFrom` is the variant for resuming from inside another coroutine.
struct LuaThread
{
    private LuaRef _ref;
    private lua_State* _thread;

    private this(LuaRef ref_, lua_State* thread)
    {
        _ref = ref_;
        _thread = thread;
    }

    /// Create a coroutine from a Lua function.
    static LuaThread create(LuaFunction function_)
    {
        if (function_.reference.isNull())
            throw new LuaStateException("cannot create a coroutine from a null function");
        if (function_.reference.type() != LuaType.function_)
            throw new LuaTypeException("cannot create a coroutine from a non-function value");

        auto s = function_.state();
        StackGuard guard = StackGuard(s);
        auto thread = lua_newthread(s.handle);      // [thread]
        auto ref_ = LuaRef.make(s, -1);
        s.pop(1);

        // The new thread starts with the function on its stack.
        function_.reference.pushInto(LuaState.wrap(thread));
        return LuaThread(ref_, thread);
    }

    /// Adopt a thread value returned by Lua (for example from
    /// `coroutine.create` or `coroutine.running`).
    static LuaThread fromValue(LuaValue value)
    {
        if (value.kind != LuaType.thread || value.ref_.isNull())
            throw new LuaTypeException("expected a Lua coroutine thread");

        auto s = value.ref_.state();
        if (!s.isOpen())
            throw new LuaStateException(
                "cannot adopt a coroutine from a closed Lua state");
        StackGuard guard = StackGuard(s);
        value.push(s);
        auto thread = lua_tothread(s.handle, -1);
        if (thread is null)
            throw new LuaTypeException("expected a Lua coroutine thread");
        return LuaThread(value.ref_, thread);
    }

    LuaState state() { return _ref.state(); }
    /// Deprecated; use `reference`.
    deprecated("Use reference instead.")
    LuaRef ref_() @nogc nothrow { return _ref; }
    /// Registry reference handle for this coroutine.
    @property LuaRef reference() @nogc nothrow { return _ref; }
    void push() @nogc nothrow { _ref.push(); }
    void pushInto(LuaState target) { _ref.pushInto(target); }

    /// Lua status of the thread (fresh/complete, suspended, or an error).
    LuaStatus status() @nogc nothrow
    {
        if (_thread is null || !_ref.state().isOpen())
            return LuaStatus.ok;
        return cast(LuaStatus) lua_status(_thread);
    }

    /// True when the coroutine is suspended at a `yield`.
    bool isSuspended() @nogc nothrow
    {
        return status() == LuaStatus.yield;
    }

    /// Resume with `args`, returning all yielded or final values.
    ///
    /// Lua errors are thrown as `LuaException`; a normal yield is not an error.
    /// The caller is assumed to run on the main thread; use `resumeFrom` when
    /// resuming from inside a coroutine.
    LuaValue[] resume(Args...)(Args args)
    {
        return resumeImpl(state(), args);
    }

    /// Resume with `args` as if called from `from`.
    ///
    /// Pass the state wrapping the currently executing thread when resuming
    /// from inside a bound callback that Lua invoked from a coroutine, for
    /// example `thread.resumeFrom(state, arg)` with the callback's injected
    /// `LuaState`. Lua 5.2+ uses `from` to inherit the caller's C-call depth;
    /// Lua 5.1 and LuaJIT ignore it.
    LuaValue[] resumeFrom(Args...)(LuaState from, Args args)
    {
        if (_thread is null)
            throw new LuaStateException("coroutine is not initialized");
        if (!from.isOpen())
            throw new LuaStateException(
                "cannot resume a coroutine from a closed Lua state");
        if (!from.sharesState(state()))
            throw new LuaStateException(
                "cannot resume a coroutine from a different Lua state");
        return resumeImpl(from, args);
    }

    private LuaValue[] resumeImpl(Args...)(LuaState from, Args args)
    {
        if (_thread is null)
            throw new LuaStateException("coroutine is not initialized");
        if (!state().isOpen())
            throw new LuaStateException(
                "cannot resume a coroutine from a closed Lua state");

        auto threadState = LuaState.wrap(_thread);
        auto base = lua_gettop(_thread);
        try
        {
            foreach (arg; args)
                pushTo(threadState, arg);
        }
        catch (Throwable e)
        {
            lua_settop(_thread, base);
            throw e;
        }

        // Yielded/final values are consumed by this call. Clearing the stack
        // after a yield leaves the coroutine's suspended frame intact.
        scope(exit) lua_settop(_thread, 0);

        auto status = raw.resume(_thread, from.handle,
                                 cast(int) args.length);
        if (status != LUA_OK && status != LUA_YIELD)
        {
            auto msg = threadState.errorText(-1);
            throw new LuaException(msg, cast(LuaStatus) status, msg);
        }

        LuaValue[] results;
        foreach (i; 1 .. lua_gettop(_thread) + 1)
            results ~= LuaValue.fromStack(threadState, i);
        return results;
    }
}
