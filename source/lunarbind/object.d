/// Experimental D-object binding: expose D classes and structs as Lua userdata
/// with metatables, public fields and methods.
///
/// This is deliberately a *first* implementation:
/// - D -> Lua and Lua -> D object identity is preserved (full userdata stores
///   the class reference, and the D GC is rooted while Lua owns the userdata).
/// - Public fields and `@property` accessors are readable/writable from Lua.
/// - `@LuaExport("name")` renames a class, struct, field, method or property;
///   `@LuaExport(skip: true)` hides members from automatic tables.
/// - Public methods are callable as `obj:method(...)`; overloads are selected
///   by arity and Lua argument types.
/// - Registered classes can be constructed from Lua with `Class(args...)`.
/// - `tostring(obj)` uses D `toString`; `#obj` uses a `length` field, property
///   or zero-argument method.
/// - Arithmetic, unary, comparison and call operators map to D `opBinary`,
///   `opUnary`, `opCmp` and `opCall` for same-class operands.
/// - `obj[key]` and `obj[key] = value` map to D `opIndex`/`opIndexAssign`;
///   string keys still resolve fields, properties and methods first.
/// - D structs are boxed as mutable userdata (`LuaStruct!S`); field writes and
///   mutating methods persist while Lua holds the box.
/// - Omitted trailing arguments take their D default values; D typesafe
///   variadics collect the argument tail into an array; a `std.typecons.Tuple`
///   result expands into multiple Lua return values; a `LuaState` parameter is
///   injected by the wrapper and consumes no Lua argument.
/// - D `...` declarations cannot be marshalled automatically because Lua
///   values carry no C type information. Free functions with the raw
///   `extern(C) int f(lua_State*)` signature are bound directly and can read
///   any number of arguments from the Lua stack.
module lunarbind.object;

import lunarbind.raw;
static import raw = lunarbind.raw;
import lunarbind.state;
import lunarbind.types;
import lunarbind.value;
import lunarbind.conv;
import lunarbind.dispatch;
import lunarbind.table : LuaTable;
import lunarbind.function_;
import lunarbind.export_ : isLuaExportedMember, luaMemberName, luaTypeName;

import core.memory : GC;
import core.sync.mutex : Mutex;
import std.string : toStringz;
import std.traits : fullyQualifiedName, Parameters, ReturnType, isIntegral,
                    isFloatingPoint, isSomeString, isDynamicArray,
                    isAssociativeArray, isInstanceOf, functionAttributes,
                    FunctionAttribute, BaseClassesTuple, Unqual, FieldTypeTuple,
                    isStaticArray, isPointer, variadicFunctionStyle, Variadic,
                    OriginalType;
import std.typecons : Tuple, Nullable;

// ---------------------------------------------------------------------------
// Compile-time member filtering
// ---------------------------------------------------------------------------

private template memberCount(T, string member)
{
    static if (__traits(compiles, __traits(getOverloads, T, member)))
        enum memberCount = __traits(getOverloads, T, member).length;
    else
        enum memberCount = 0;
}

package template isPublicMember(T, string member)
{
    static if (__traits(compiles, __traits(getProtection, __traits(getMember, T, member))))
        enum isPublicMember = __traits(getProtection, __traits(getMember, T, member)) == "public";
    else
        enum isPublicMember = false;
}

private template isPublicOverload(alias F)
{
    static if (__traits(compiles, __traits(getProtection, F)))
        enum isPublicOverload = __traits(getProtection, F) == "public";
    else
        enum isPublicOverload = false;
}

private template isBindableType(T)
{
    enum isBindableType =
        is(T == bool)
        || (is(T == enum) && isBindableType!(OriginalType!T))
        || isIntegral!T
        || isFloatingPoint!T
        || isSomeString!T
        || is(T : const(char)[])
        || is(T == LuaValue)
        || is(T == LuaRef)
        || is(T == LuaTable)
        || is(T == LuaFunction)
        || is(T == LuaString)
        || is(T == void*)
        || is(T == class)
        || isDynamicArray!T
        || isAssociativeArray!T
        || isInstanceOf!(Nullable, T)
        || is(Unqual!T == struct)
        || is(Unqual!T == union);
}

private template isBindableReturn(T)
{
    static if (is(T == void))
        enum isBindableReturn = true;
    else
        enum isBindableReturn = isBindableType!T;
}

package template overloadBindable(alias Method)
{
    static if (__traits(compiles, Parameters!Method)
               && __traits(compiles, ReturnType!Method)
               && isPublicOverload!Method)
        enum overloadBindable =
            allBindable!(Parameters!Method)
            && isBindableReturn!(ReturnType!Method)
            && bindableVariadic!Method;
    else
        enum overloadBindable = false;
}

/// Like `overloadBindable`, but also accepts raw `lua_CFunction` callbacks.
/// Free functions and module tables can expose them; class and struct members
/// cannot, because their arguments are handled by the normal method wrapper.
package template callableBindable(alias F)
{
    static if (isRawLuaFunction!F)
        enum callableBindable = isPublicOverload!F;
    else
        enum callableBindable = overloadBindable!F;
}

package template methodBindable(T, string member, size_t i = 0)
{
    static if (__traits(compiles, __traits(getOverloads, T, member)))
    {
        alias overloads = __traits(getOverloads, T, member);
        static if (i < overloads.length)
            enum methodBindable =
                overloadBindable!(overloads[i]) || methodBindable!(T, member, i + 1);
        else
            enum methodBindable = false;
    }
    else
        enum methodBindable = false;
}

package template staticMethodBindable(T, string member, size_t i = 0)
{
    static if (__traits(compiles, __traits(getOverloads, T, member)))
    {
        alias overloads = __traits(getOverloads, T, member);
        static if (i < overloads.length)
            enum staticMethodBindable =
                (__traits(isStaticFunction, overloads[i])
                 && overloadBindable!(overloads[i]))
                || staticMethodBindable!(T, member, i + 1);
        else
            enum staticMethodBindable = false;
    }
    else
        enum staticMethodBindable = false;
}

private template allBindable(Params...)
{
    static if (Params.length == 0)
        enum allBindable = true;
    else
        enum allBindable = isBindableType!(Params[0]) && allBindable!(Params[1 .. $]);
}

// `Object.toString` exists on every class, but a class can hide it or provide
// overloads. Find the first zero-argument char-string overload.
private template toStringBindable(T, size_t i = 0)
{
    static if (__traits(compiles, __traits(getOverloads, T, "toString")))
    {
        alias overloads = __traits(getOverloads, T, "toString");
        static if (i < overloads.length)
        {
            alias F = overloads[i];
            static if (isPublicOverload!F
                       && __traits(compiles, Parameters!F)
                       && __traits(compiles, ReturnType!F)
                       && Parameters!F.length == 0
                       && is(ReturnType!F : const(char)[]))
                enum toStringBindable = true;
            else
                enum toStringBindable = toStringBindable!(T, i + 1);
        }
        else
            enum toStringBindable = false;
    }
    else
        enum toStringBindable = false;
}

// Runtime type screen used to choose between overloads. It deliberately
// mirrors `popFrom` only closely enough to avoid picking an obviously wrong
// candidate; e.g. both `int` and `string` accept a Lua number, and the first
// matching overload wins.
package bool luaArgMatches(T)(LuaState state, int idx)
{
    auto t = lua_type(state.handle, idx);
    static if (is(T == LuaValue))
        return true;
    else static if (is(T == LuaRef))
        return t != LUA_TNONE;
    else static if (is(T == LuaTable))
        return t == LUA_TTABLE;
    else static if (is(T == LuaFunction))
        return t == LUA_TFUNCTION;
    else static if (is(T == LuaString))
        return t == LUA_TSTRING || t == LUA_TNUMBER;
    else static if (isSomeString!T)
        return t == LUA_TSTRING || t == LUA_TNUMBER || t == LUA_TNIL;
    else static if (is(T == bool))
        return true;
    else static if (is(T == enum))
        return luaArgMatches!(OriginalType!T)(state, idx);
    else static if (isIntegral!T || isFloatingPoint!T)
        return t == LUA_TNUMBER;
    else static if (is(T == void*))
        return t == LUA_TLIGHTUSERDATA || t == LUA_TNIL;
    else static if (isInstanceOf!(Nullable, T))
    {
        if (t == LUA_TNIL)
            return true;
        alias U = typeof(T.init.get());
        return luaArgMatches!U(state, idx);
    }
    else static if (isDynamicArray!T || isAssociativeArray!T)
        return t == LUA_TTABLE || t == LUA_TNIL;
    else static if (is(T == class))
    {
        if (hasCodec!T(state))
            return codecMatches!T(state, idx);
        if (t == LUA_TNIL)
            return true;
        if (t != LUA_TUSERDATA)
            return false;
        return LuaClass!T.isInstance(state, idx);
    }
    else static if (is(Unqual!T == struct))
    {
        alias S = Unqual!T;
        if (hasCodec!S(state))
            return codecMatches!S(state, idx);
        if (t != LUA_TUSERDATA)
            return false;
        return LuaStruct!S.isInstance(state, idx);
    }
    else static if (is(Unqual!T == union))
    {
        // Without a codec there is no way to interpret the Lua value.
        alias U = Unqual!T;
        return hasCodec!U(state) && codecMatches!U(state, idx);
    }
    else
        return false;
}

// Match a Lua call against a D function's declared parameters, including
// omitted trailing defaults and a typesafe variadic tail.
package bool callMatches(alias F)(LuaState state, int startIdx, size_t nargs)
{
    static if (!bindableVariadic!F)
        return false;
    else
    {
        enum fixed = fixedParamCount!F;
        static if (variadicFunctionStyle!F == Variadic.typesafe)
        {
            if (nargs < requiredParamCount!F)
                return false;
        }
        else
        {
            if (nargs < requiredParamCount!F || nargs > luaFixedCount!F)
                return false;
        }

        static foreach (i, P; Parameters!F)
        {{
            static if (isInjectedParameter!P)
            {
                // Supplied by the wrapper; consumes no Lua argument.
            }
            else static if (i < fixed)
            {
                enum p = luaParamOrdinal!(F, i);
                if (p < nargs
                    && !luaArgMatches!(Unqual!P)(state, startIdx + cast(int) p))
                    return false;
            }
            else
            {
                alias E = typesafeVariadicElement!F;
                enum p = luaParamOrdinal!(F, i);
                foreach (k; p .. nargs)
                {
                    if (!luaArgMatches!E(state, startIdx + cast(int) k))
                        return false;
                }
            }
        }}
        return true;
    }
}

// Stricter key screen for `opIndex`/`opIndexAssign`. Strings only match Lua
// strings and booleans only match Lua booleans, so an integer key prefers an
// integer overload instead of being converted by a string overload.
private bool luaKeyMatches(T)(LuaState state, int idx)
{
    auto t = lua_type(state.handle, idx);
    static if (is(T == LuaString) || isSomeString!T)
        return t == LUA_TSTRING;
    else static if (is(T == bool))
        return t == LUA_TBOOLEAN;
    else
        return luaArgMatches!T(state, idx);
}

// Constructors are introspected through "__ctor" rather than allMembers.  A
// class with no explicit constructors has the implicit default `new T()`.
private template hasExplicitConstructors(T)
{
    enum hasExplicitConstructors =
        __traits(compiles, __traits(getOverloads, T, "__ctor"));
}

private template canNew(T, Params...)
{
    enum canNew = __traits(compiles, new T(Params.init));
}

private template anyBindableConstructor(T, size_t i = 0)
{
    static if (!hasExplicitConstructors!T)
        enum anyBindableConstructor = canNew!T;
    else static if (i < __traits(getOverloads, T, "__ctor").length)
    {
        alias Ctor = __traits(getOverloads, T, "__ctor")[i];
        static if (__traits(compiles, Parameters!Ctor))
            enum bindable =
                allBindable!(Parameters!Ctor)
                && bindableVariadic!Ctor
                && canNew!(T, Parameters!Ctor);
        else
            enum bindable = false;
        enum anyBindableConstructor =
            bindable || anyBindableConstructor!(T, i + 1);
    }
    else
        enum anyBindableConstructor = false;
}

private template hasBindableConstructor(T)
{
    enum hasBindableConstructor = anyBindableConstructor!T;
}

// `@property` getters/setters share a member name, so they cannot go through
// the method overload dispatch. Find the first callable getter (zero args,
// non-void result) and setter (one bindable arg) in the overload set.
private template isPropertyFunction(alias F)
{
    static if (__traits(compiles, functionAttributes!F))
        enum isPropertyFunction =
            (functionAttributes!F & FunctionAttribute.property) != 0;
    else
        enum isPropertyFunction = false;
}

package template propertyGetter(T, string member, size_t i = 0)
{
    static if (__traits(compiles, __traits(getOverloads, T, member)))
    {
        alias overloads = __traits(getOverloads, T, member);
        static if (i < overloads.length)
        {
            alias F = overloads[i];
            static if (isPropertyFunction!F
                       && __traits(compiles, Parameters!F)
                       && __traits(compiles, ReturnType!F)
                       && Parameters!F.length == 0
                       && !is(ReturnType!F == void)
                       && isBindableReturn!(ReturnType!F))
                alias propertyGetter = F;
            else
                alias propertyGetter = propertyGetter!(T, member, i + 1);
        }
        else
            alias propertyGetter = void;
    }
    else
        alias propertyGetter = void;
}

package template propertySetter(T, string member, size_t i = 0)
{
    static if (__traits(compiles, __traits(getOverloads, T, member)))
    {
        alias overloads = __traits(getOverloads, T, member);
        static if (i < overloads.length)
        {
            alias F = overloads[i];
            static if (isPropertyFunction!F
                       && __traits(compiles, Parameters!F)
                       && __traits(compiles, ReturnType!F)
                       && Parameters!F.length == 1
                       && is(ReturnType!F == void)
                       && allBindable!(Parameters!F))
                alias propertySetter = F;
            else
                alias propertySetter = propertySetter!(T, member, i + 1);
        }
        else
            alias propertySetter = void;
    }
    else
        alias propertySetter = void;
}

package template hasPropertyGetter(T, string member)
{
    enum hasPropertyGetter = !is(propertyGetter!(T, member) == void);
}

package template hasPropertySetter(T, string member)
{
    enum hasPropertySetter = !is(propertySetter!(T, member) == void);
}

private template fieldType(T, string member)
{
    alias fieldType = typeof(__traits(getMember, T.init, member));
}

private template isField(T, string member)
{
    static if (memberCount!(T, member) == 0
               && __traits(compiles, typeof(__traits(getMember, T.init, member))))
        enum isField = true;
    else
        enum isField = false;
}

package template fieldBindable(T, string member)
{
    static if (isField!(T, member))
        enum fieldBindable = isBindableType!(Unqual!(fieldType!(T, member)));
    else
        enum fieldBindable = false;
}

private template lengthMethodBindable(T, size_t i = 0)
{
    static if (__traits(compiles, __traits(getOverloads, T, "length")))
    {
        alias overloads = __traits(getOverloads, T, "length");
        static if (i < overloads.length)
        {
            alias F = overloads[i];
            static if (isPublicOverload!F
                       && __traits(compiles, Parameters!F)
                       && __traits(compiles, ReturnType!F)
                       && Parameters!F.length == 0
                       && isIntegral!(Unqual!(ReturnType!F)))
                enum lengthMethodBindable = true;
            else
                enum lengthMethodBindable = lengthMethodBindable!(T, i + 1);
        }
        else
            enum lengthMethodBindable = false;
    }
    else
        enum lengthMethodBindable = false;
}

private template lengthBindable(T)
{
    static if (isField!(T, "length")
               && isIntegral!(Unqual!(fieldType!(T, "length"))))
        enum lengthBindable = true;
    else static if (hasPropertyGetter!(T, "length")
                    && isIntegral!(Unqual!(ReturnType!(propertyGetter!(T, "length")))))
        enum lengthBindable = true;
    else
        enum lengthBindable = lengthMethodBindable!T;
}

private template binaryOperatorBindable(T, string op)
{
    static if (__traits(compiles, T.init.opBinary!op(T.init)))
        enum binaryOperatorBindable =
            isBindableType!(Unqual!(typeof(T.init.opBinary!op(T.init))));
    else
        enum binaryOperatorBindable = false;
}

private template unaryOperatorBindable(T, string op)
{
    static if (__traits(compiles, T.init.opUnary!op()))
        enum unaryOperatorBindable =
            isBindableType!(Unqual!(typeof(T.init.opUnary!op())));
    else
        enum unaryOperatorBindable = false;
}

private template indexGetOverloadBindable(alias F)
{
    static if (isPublicOverload!F
               && __traits(compiles, Parameters!F)
               && __traits(compiles, ReturnType!F)
               && Parameters!F.length == 1
               && allBindable!(Parameters!F)
               && !is(ReturnType!F == void)
               && isBindableReturn!(ReturnType!F))
        enum indexGetOverloadBindable = true;
    else
        enum indexGetOverloadBindable = false;
}

private template indexSetOverloadBindable(alias F)
{
    static if (isPublicOverload!F
               && __traits(compiles, Parameters!F)
               && Parameters!F.length == 2
               && allBindable!(Parameters!F))
        enum indexSetOverloadBindable = true;
    else
        enum indexSetOverloadBindable = false;
}

private template indexGetBindable(T, size_t i = 0)
{
    static if (__traits(compiles, __traits(getOverloads, T, "opIndex")))
    {
        alias overloads = __traits(getOverloads, T, "opIndex");
        static if (i < overloads.length)
            enum indexGetBindable =
                indexGetOverloadBindable!(overloads[i])
                || indexGetBindable!(T, i + 1);
        else
            enum indexGetBindable = false;
    }
    else
        enum indexGetBindable = false;
}

private template indexSetBindable(T, size_t i = 0)
{
    static if (__traits(compiles, __traits(getOverloads, T, "opIndexAssign")))
    {
        alias overloads = __traits(getOverloads, T, "opIndexAssign");
        static if (i < overloads.length)
            enum indexSetBindable =
                indexSetOverloadBindable!(overloads[i])
                || indexSetBindable!(T, i + 1);
        else
            enum indexSetBindable = false;
    }
    else
        enum indexSetBindable = false;
}

// Object itself provides opCmp; only expose ordering when a class (or one of
// its bases) actually overrides it.
private template compareOperatorBindable(T, size_t i = 0)
{
    static if (__traits(compiles, __traits(getOverloads, T, "opCmp")))
    {
        alias overloads = __traits(getOverloads, T, "opCmp");
        static if (i < overloads.length)
        {
            alias F = overloads[i];
            static if (isPublicOverload!F
                       && __traits(compiles, Parameters!F)
                       && __traits(compiles, ReturnType!F)
                       && __traits(compiles, __traits(parent, F))
                       && Parameters!F.length == 1
                       && !is(__traits(parent, F) == Object)
                       && isIntegral!(Unqual!(ReturnType!F))
                       && __traits(compiles, T.init.opCmp(T.init)))
                enum compareOperatorBindable = true;
            else
                enum compareOperatorBindable = compareOperatorBindable!(T, i + 1);
        }
        else
            enum compareOperatorBindable = false;
    }
    else
        enum compareOperatorBindable = false;
}

// ---------------------------------------------------------------------------
// Userdata helpers
// ---------------------------------------------------------------------------

private template metaName(T)
{
    enum string metaName = "lunarbind.class." ~ fullyQualifiedName!T;
}

// The same D object can be exposed in several Lua states (and as several
// class views). The D GC root set is process-global and not reference-counted,
// so keep one count per object and only add/remove the actual GC root when the
// first/last userdata disappears.
private __gshared size_t[void*] objectRootCounts;
private shared Mutex objectRootLock;

shared static this()
{
    objectRootLock = new shared Mutex;
}

private void addObjectRoot(void* p) nothrow
{
    if (p is null)
        return;
    objectRootLock.lock_nothrow();
    scope(exit) objectRootLock.unlock_nothrow();

    auto count = p in objectRootCounts;
    if (count is null)
    {
        objectRootCounts[p] = 1;
        GC.addRoot(p);
    }
    else
        ++*count;
}

private void removeObjectRoot(void* p) nothrow
{
    if (p is null)
        return;
    objectRootLock.lock_nothrow();
    scope(exit) objectRootLock.unlock_nothrow();

    auto count = p in objectRootCounts;
    if (count is null)
        return;
    if (--*count == 0)
    {
        objectRootCounts.remove(p);
        GC.removeRoot(p);
    }
}

version (unittest)
{
    /// Test hook: number of live Lua userdata currently rooting `obj`.
    package size_t objectRootCountForTest(void* p) nothrow
    {
        if (p is null)
            return 0;
        objectRootLock.lock_nothrow();
        scope(exit) objectRootLock.unlock_nothrow();
        auto count = p in objectRootCounts;
        return count is null ? 0 : *count;
    }
}

private extern(C) int classGc(T)(lua_State* L) nothrow
{
    auto p = cast(T*) lua_touserdata(L, 1);
    if (p !is null && *p !is null)
    {
        removeObjectRoot(cast(void*) *p);
        *p = null;
    }
    return 0;
}

// Struct boxes store the value inline, so liveness needs an explicit marker.
// The extra byte after the value is 1 while the box is alive and 0 after
// `__gc`. A resurrected userdata must not expose its cleared value or accept
// writes, because its GC range has already been removed.
private bool structBoxAlive(S)(S* self) @nogc nothrow
{
    return self !is null && (cast(const(ubyte)*) self)[S.sizeof] != 0;
}

private void setStructBoxAlive(S)(S* self, bool alive) @nogc nothrow
{
    (cast(ubyte*) self)[S.sizeof] = alive ? 1 : 0;
}

// A userdata can outlive its finalizer when `__gc` resurrects it. A class box
// holds a null D reference then; a struct box carries a cleared value and a
// dead marker. Every field, method, length and tostring path must reject the
// dead box instead of dereferencing null or reading memory whose GC range was
// already removed.
private void requireLiveBox(T)(T* self)
{
    static if (is(T == class))
    {
        if (self is null || *self is null)
            throw new LuaStateException(T.stringof ~ " instance is no longer alive");
    }
    else static if (is(T == struct))
    {
        if (!structBoxAlive!T(self))
            throw new LuaStateException(T.stringof ~ " value is no longer alive");
    }
}

// Every class metatable owns a weak-valued table mapping the boxed D object
// pointer to its userdata. While the userdata is reachable from Lua, pushing
// the same D object reuses it; when Lua collects it, the weak entry disappears
// and the next push creates a fresh userdata.
private void ensureIdentityTable(lua_State* L, int metaIdx)
{
    metaIdx = raw.absIndex(L, metaIdx);
    // Internal metadata: raw access, so a metatable attached to the class
    // metatable cannot run `__index` and longjmp out of D.
    lua_pushlstring(L, "__lunarbind_identity".ptr,
                    "__lunarbind_identity".length);
    lua_rawget(L, metaIdx);
    if (lua_type(L, -1) == LUA_TTABLE)
        return;

    raw.pop(L, 1);
    lua_createtable(L, 0, 0);
    lua_createtable(L, 0, 1);
    lua_pushlstring(L, "__mode".ptr, "__mode".length);
    lua_pushlstring(L, "v".ptr, 1);
    lua_rawset(L, -3);
    lua_setmetatable(L, -2);
    lua_pushlstring(L, "__lunarbind_identity".ptr,
                    "__lunarbind_identity".length);
    lua_pushvalue(L, -2);
    lua_rawset(L, metaIdx);
    // The identity table is left on top of the stack.
}

private extern(C) int classEq(lua_State* L) nothrow
{
    // Compare the boxed D references, not the userdata addresses. All class
    // metatables share this function, so a base-class view and a derived-class
    // view of the same object also compare equal. D class subobjects start at
    // offset zero (D has single class inheritance), so the stored reference
    // pointers are directly comparable.
    auto a = cast(void**) lua_touserdata(L, 1);
    auto b = cast(void**) lua_touserdata(L, 2);
    lua_pushboolean(L, a !is null && b !is null && *a is *b ? 1 : 0);
    return 1;
}

private extern(C) int classToString(T)(lua_State* L) nothrow
{
    try
    {
        auto self = cast(T*) lua_touserdata(L, 1);
        requireLiveBox!T(self);
        auto s = self.toString();
        if (s is null)
            s = "";
        lua_pushlstring(L, s.ptr, s.length);
        return 1;
    }
    catch (Throwable e)
        return pushError(L, e);
}

private extern(C) int classLen(T)(lua_State* L) nothrow
{
    try
    {
        auto self = cast(T*) lua_touserdata(L, 1);
        requireLiveBox!T(self);
        static if (isField!(T, "length"))
            auto len = __traits(getMember, *self, "length");
        else
            auto len = __traits(getMember, *self, "length")();
        lua_pushinteger(L, cast(lua_Integer) len);
        return 1;
    }
    catch (Throwable e)
        return pushError(L, e);
}

private bool bindableIsInstance(T)(LuaState state, int idx)
{
    static if (is(T == class))
        return LuaClass!T.isInstance(state, idx);
    else
        return LuaStruct!T.isInstance(state, idx);
}

private T bindableGet(T)(LuaState state, int idx)
{
    static if (is(T == class))
        return LuaClass!T.get(state, idx);
    else
        return LuaStruct!T.get(state, idx);
}

private extern(C) int classBinary(T, string op)(lua_State* L) nothrow
{
    try
    {
        auto state = LuaState.wrap(L);
        if (!bindableIsInstance!T(state, 1) || !bindableIsInstance!T(state, 2))
            throw new LuaTypeException(
                "operator " ~ op ~ " expects two " ~ T.stringof ~ " operands");

        T self = bindableGet!T(state, 1);
        T other = bindableGet!T(state, 2);
        pushTo(state, self.opBinary!op(other));
        return 1;
    }
    catch (Throwable e)
        return pushError(L, e);
}

private extern(C) int classUnary(T, string op)(lua_State* L) nothrow
{
    try
    {
        auto state = LuaState.wrap(L);
        if (!bindableIsInstance!T(state, 1))
            throw new LuaTypeException(
                "operator " ~ op ~ " expects a " ~ T.stringof ~ " operand");

        T self = bindableGet!T(state, 1);
        pushTo(state, self.opUnary!op());
        return 1;
    }
    catch (Throwable e)
        return pushError(L, e);
}

private extern(C) int classCompare(T, bool inclusive)(lua_State* L) nothrow
{
    try
    {
        auto state = LuaState.wrap(L);
        if (!bindableIsInstance!T(state, 1) || !bindableIsInstance!T(state, 2))
            throw new LuaTypeException(
                "comparison expects two " ~ T.stringof ~ " operands");

        T self = bindableGet!T(state, 1);
        T other = bindableGet!T(state, 2);
        auto cmp = self.opCmp(other);
        static if (inclusive)
            lua_pushboolean(L, cmp <= 0 ? 1 : 0);
        else
            lua_pushboolean(L, cmp < 0 ? 1 : 0);
        return 1;
    }
    catch (Throwable e)
        return pushError(L, e);
}

private void setBinaryOperator(T, string op, string meta)(lua_State* L)
{
    static if (binaryOperatorBindable!(T, op))
    {
        pushCFunction(L, &classBinary!(T, op));
        lua_setfield(L, -2, meta.ptr);
    }
}

private void setUnaryOperator(T, string op, string meta)(lua_State* L)
{
    static if (unaryOperatorBindable!(T, op))
    {
        pushCFunction(L, &classUnary!(T, op));
        lua_setfield(L, -2, meta.ptr);
    }
}

private void setCompareOperator(T, bool inclusive)(lua_State* L)
{
    static if (compareOperatorBindable!T)
    {
        pushCFunction(L, &classCompare!(T, inclusive));
        static if (inclusive)
            lua_setfield(L, -2, "__le");
        else
            lua_setfield(L, -2, "__lt");
    }
}

// Lua's __eq is only consulted when both operands carry the *same* metamethod
// object. Reuse one closure per Lua state so base and derived class views can
// compare equal.
private void pushClassEq(lua_State* L)
{
    // Raw registry access: user code can obtain the registry through the debug
    // library, and a metatable there must not run while D is on the stack.
    lua_pushlstring(L, "__lunarbind_class_eq".ptr,
                    "__lunarbind_class_eq".length);
    lua_rawget(L, LUA_REGISTRYINDEX);
    if (lua_type(L, -1) == LUA_TFUNCTION)
        return;

    raw.pop(L, 1);
    pushCFunction(L, &classEq);
    lua_pushlstring(L, "__lunarbind_class_eq".ptr,
                    "__lunarbind_class_eq".length);
    lua_pushvalue(L, -2);
    lua_rawset(L, LUA_REGISTRYINDEX);
}

// ---------------------------------------------------------------------------
// Struct boxes
// ---------------------------------------------------------------------------

private template structMetaName(S)
{
    enum string structMetaName = "lunarbind.struct." ~ fullyQualifiedName!S;
}

private template structEqualityBindable(S)
{
    static if (__traits(compiles, S.init == S.init))
        enum structEqualityBindable = true;
    else
        enum structEqualityBindable = false;
}

// Conservative compile-time scan used to decide whether a struct box must be
// registered as a GC root range.
private template hasDPointers(T)
{
    static if (is(Unqual!T == class) || is(Unqual!T == interface)
               || isDynamicArray!(Unqual!T) || isAssociativeArray!(Unqual!T)
               || isPointer!(Unqual!T) || is(Unqual!T == delegate)
               || is(Unqual!T == function))
        enum hasDPointers = true;
    else static if (isStaticArray!(Unqual!T))
        enum hasDPointers = hasDPointers!(typeof(T.init[0]));
    else static if (is(Unqual!T == struct))
        enum hasDPointers = anyPointerField!(FieldTypeTuple!(Unqual!T));
    else
        enum hasDPointers = false;
}

private template anyPointerField(Fields...)
{
    static if (Fields.length == 0)
        enum anyPointerField = false;
    else
        enum anyPointerField =
            hasDPointers!(Fields[0]) || anyPointerField!(Fields[1 .. $]);
}

// Struct boxes live in Lua-allocated memory, which the D GC does not scan.
// Register the box as a root range while Lua owns it so contained class
// references, arrays and delegates stay alive.
private extern(C) int structGc(S)(lua_State* L) nothrow
{
    auto p = cast(S*) lua_touserdata(L, 1);
    // A resurrected userdata may be finalized again by a custom Lua __gc.
    // Only the first finalization owns the GC range and the live value.
    if (p is null || !structBoxAlive!S(p))
        return 0;

    setStructBoxAlive!S(p, false);
    static if (hasDPointers!S)
    {
        // Newer druntime tracks range sizes internally and removed the
        // size argument from removeRange.
        static if (__traits(compiles, GC.removeRange(p, S.sizeof)))
            GC.removeRange(p, S.sizeof);
        else
            GC.removeRange(p);
    }

    // Drop contained references before the memory can be observed through a
    // resurrected userdata. Binding access raises on the dead marker, but a
    // raw lua_touserdata user should never see stale pointers either. Zeroed
    // bits are valid for every D scalar, pointer and dynamic-array field and
    // avoid requiring a copy or default construction of `S`.
    import core.stdc.string : memset;
    memset(p, 0, S.sizeof);
    return 0;
}

private extern(C) int structEq(S)(lua_State* L) nothrow
{
    try
    {
        auto a = cast(S*) lua_touserdata(L, 1);
        auto b = cast(S*) lua_touserdata(L, 2);
        requireLiveBox!S(a);
        requireLiveBox!S(b);
        lua_pushboolean(L, *a == *b ? 1 : 0);
        return 1;
    }
    catch (Throwable e)
        return pushError(L, e);
}

private void ensureStructMetatable(S)(LuaState state)
{
    auto name = toStringz(structMetaName!S);
    if (luaL_newmetatable(state.handle, name) != 0)
    {
        pushCFunction(state.handle, &structGc!S);
        lua_setfield(state.handle, -2, "__gc");
        pushCFunction(state.handle, &classIndex!S);
        lua_setfield(state.handle, -2, "__index");
        pushCFunction(state.handle, &classNewIndex!S);
        lua_setfield(state.handle, -2, "__newindex");
        static if (structEqualityBindable!S)
        {
            pushCFunction(state.handle, &structEq!S);
            lua_setfield(state.handle, -2, "__eq");
        }

        static if (toStringBindable!S)
        {
            pushCFunction(state.handle, &classToString!S);
            lua_setfield(state.handle, -2, "__tostring");
        }
        static if (lengthBindable!S)
        {
            pushCFunction(state.handle, &classLen!S);
            lua_setfield(state.handle, -2, "__len");
        }

        setBinaryOperator!(S, "+", "__add")(state.handle);
        setBinaryOperator!(S, "-", "__sub")(state.handle);
        setBinaryOperator!(S, "*", "__mul")(state.handle);
        setBinaryOperator!(S, "/", "__div")(state.handle);
        setBinaryOperator!(S, "%", "__mod")(state.handle);
        setBinaryOperator!(S, "^^", "__pow")(state.handle);
        setBinaryOperator!(S, "~", "__concat")(state.handle);
        setBinaryOperator!(S, "&", "__band")(state.handle);
        setBinaryOperator!(S, "|", "__bor")(state.handle);
        setBinaryOperator!(S, "^", "__bxor")(state.handle);
        setBinaryOperator!(S, "<<", "__shl")(state.handle);
        setBinaryOperator!(S, ">>", "__shr")(state.handle);
        setUnaryOperator!(S, "-", "__unm")(state.handle);
        setUnaryOperator!(S, "~", "__bnot")(state.handle);
        setCompareOperator!(S, false)(state.handle);
        setCompareOperator!(S, true)(state.handle);
        static if (methodBindable!(S, "opCall"))
        {
            pushCFunction(state.handle, &methodThunk!(S, "opCall"));
            lua_setfield(state.handle, -2, "__call");
        }
    }
}

private bool tryIndexGet(T, alias F)(LuaState state, T* self, bool strictKey)
{
    alias Params = Parameters!F;
    alias K = Unqual!(Params[0]);
    bool matches = strictKey
        ? luaKeyMatches!K(state, 2)
        : luaArgMatches!K(state, 2);
    if (!matches)
        return false;

    auto key = popFrom!K(state, 2);
    pushTo(state, self.opIndex(key));
    return true;
}

private bool tryIndexSet(T, alias F)(LuaState state, T* self, bool strictKey)
{
    alias Params = Parameters!F;
    alias V = Unqual!(Params[0]);
    alias K = Unqual!(Params[1]);
    bool keyMatches = strictKey
        ? luaKeyMatches!K(state, 2)
        : luaArgMatches!K(state, 2);
    if (!keyMatches || !luaArgMatches!V(state, 3))
        return false;

    auto value = popFrom!V(state, 3);
    auto key = popFrom!K(state, 2);
    self.opIndexAssign(value, key);
    return true;
}

private extern(C) int classIndex(T)(lua_State* L) nothrow
{
    try
    {
        auto state = LuaState.wrap(L);
        auto self = cast(T*) lua_touserdata(L, 1);
        requireLiveBox!T(self);

        // Only string keys can name fields/methods. Check the type first so
        // numeric and other keys stay intact instead of being coerced by
        // lua_tolstring.
        if (lua_type(L, 2) == LUA_TSTRING)
        {
            size_t len;
            auto keyPtr = lua_tolstring(L, 2, &len);
            const(char)[] key = keyPtr[0 .. len];

            static foreach (member; __traits(allMembers, T))
            {{
                static if (isPublicMember!(T, member) && isLuaExportedMember!(T, member))
                {
                    static if (hasPropertyGetter!(T, member))
                    {
                        if (key == luaMemberName!(T, member))
                        {
                            pushTo(state, __traits(getMember, *self, member)());
                            return 1;
                        }
                    }
                    else static if (fieldBindable!(T, member))
                    {
                        if (key == luaMemberName!(T, member))
                        {
                            pushTo(state, __traits(getMember, *self, member));
                            return 1;
                        }
                    }
                    else static if (methodBindable!(T, member))
                    {
                        if (key == luaMemberName!(T, member))
                        {
                            pushCFunction(L, &methodThunk!(T, member));
                            return 1;
                        }
                    }
                }
            }}
        }

        // Fall back to D's opIndex for keys that are not field/method names.
        // Prefer exact key-type matches, then the looser conversion screen.
        static if (indexGetBindable!T)
        {
            foreach (pass; 0 .. 2)
            {
                bool strictKey = pass == 0;
                static foreach (i, F; __traits(getOverloads, T, "opIndex"))
                {{
                    static if (indexGetOverloadBindable!F)
                    {
                        if (tryIndexGet!(T, F)(state, self, strictKey))
                            return 1;
                    }
                }}
            }
        }

        lua_pushnil(L);
        return 1;
    }
    catch (Throwable e)
        return pushError(L, e);
}

private extern(C) int classNewIndex(T)(lua_State* L) nothrow
{
    try
    {
        auto state = LuaState.wrap(L);
        auto self = cast(T*) lua_touserdata(L, 1);
        requireLiveBox!T(self);

        if (lua_type(L, 2) == LUA_TSTRING)
        {
            size_t len;
            auto keyPtr = lua_tolstring(L, 2, &len);
            const(char)[] key = keyPtr[0 .. len];

            static foreach (member; __traits(allMembers, T))
            {{
                static if (isPublicMember!(T, member) && isLuaExportedMember!(T, member))
                {
                    static if (hasPropertySetter!(T, member))
                    {
                        if (key == luaMemberName!(T, member))
                        {
                            alias Setter = propertySetter!(T, member);
                            alias SetterParams = Parameters!Setter;
                            alias PT = Unqual!(SetterParams[0]);
                            auto value = popFrom!PT(state, 3);
                            __traits(getMember, *self, member)(value);
                            return 0;
                        }
                    }
                    else static if (fieldBindable!(T, member))
                    {
                        if (key == luaMemberName!(T, member))
                        {
                            alias FT = Unqual!(fieldType!(T, member));
                            __traits(getMember, *self, member) = popFrom!FT(state, 3);
                            return 0;
                        }
                    }
                }
            }}
        }

        // D's opIndexAssign takes the value first and the key second. Prefer
        // exact key-type matches, then the looser conversion screen.
        static if (indexSetBindable!T)
        {
            foreach (pass; 0 .. 2)
            {
                bool strictKey = pass == 0;
                static foreach (i, F; __traits(getOverloads, T, "opIndexAssign"))
                {{
                    static if (indexSetOverloadBindable!F)
                    {
                        if (tryIndexSet!(T, F)(state, self, strictKey))
                            return 0;
                    }
                }}
            }
        }

        if (lua_type(L, 2) == LUA_TSTRING)
        {
            size_t len;
            auto keyPtr = lua_tolstring(L, 2, &len);
            throw new LuaArgumentException(
                T.stringof ~ " has no field '" ~ keyPtr[0 .. len].idup ~ "'");
        }

        throw new LuaArgumentException(
            T.stringof ~ " does not support indexed assignment");
    }
    catch (Throwable e)
        return pushError(L, e);
}

private extern(C) int constructorThunk(T)(lua_State* L) nothrow
{
    try
    {
        auto state = LuaState.wrap(L);
        auto nargs = lua_gettop(L) - 1;

        static if (hasExplicitConstructors!T)
        {
            static foreach (i, Ctor; __traits(getOverloads, T, "__ctor"))
            {{
                static if (__traits(compiles, Parameters!Ctor)
                           && allBindable!(Parameters!Ctor)
                           && bindableVariadic!Ctor
                           && canNew!(T, Parameters!Ctor))
                {
                    if (callMatches!Ctor(state, 2, cast(size_t) nargs))
                    {
                        Tuple!(Parameters!Ctor) args;
                        fillCallArgs!Ctor(state, args, cast(size_t) nargs, 2);

                        pushTo(state, new T(args.expand));
                        return 1;
                    }
                }
            }}
        }
        else static if (canNew!T)
        {
            if (nargs == 0)
            {
                pushTo(state, new T());
                return 1;
            }
        }

        throw new LuaArgumentException(
            "no matching constructor for " ~ T.stringof
            ~ "(" ~ luaArgumentTypes(L, 2, nargs) ~ ")");
    }
    catch (Throwable e)
        return pushError(L, e);
}

private extern(C) int methodThunk(T, string member)(lua_State* L) nothrow
{
    try
    {
        auto state = LuaState.wrap(L);
        auto self = cast(T*) lua_touserdata(L, 1);
        requireLiveBox!T(self);
        auto nargs = cast(size_t)(lua_gettop(L) - 1);

        static foreach (i, Method; __traits(getOverloads, T, member))
        {{
            static if (overloadBindable!Method)
            {
                alias Params = Parameters!Method;
                if (callMatches!Method(state, 2, nargs))
                {
                    Tuple!Params args;
                    fillCallArgs!Method(state, args, nargs, 2);

                    static if (is(ReturnType!Method == void))
                    {
                        __traits(getMember, *self, member)(args.expand);
                        return 0;
                    }
                    else
                    {
                        return pushCallResult(
                            state, __traits(getMember, *self, member)(args.expand));
                    }
                }
            }
        }}

        throw new LuaArgumentException(
            "no matching overload for " ~ T.stringof ~ "." ~ member
            ~ "(" ~ luaArgumentTypes(L, 2, nargs) ~ ")");
    }
    catch (Throwable e)
        return pushError(L, e);
}

// Class-table entry for an instance method: `Class.method(obj, ...)`. The
// metatable path calls `methodThunk` directly, but a table lookup can be
// invoked with any first argument, so validate the receiver first.
private extern(C) int classTableMethodThunk(T, string member)(lua_State* L) nothrow
{
    try
    {
        auto state = LuaState.wrap(L);
        if (!LuaClass!T.isInstance(state, 1))
            throw new LuaTypeException(
                "expected " ~ T.stringof ~ " userdata as self");
        return methodThunk!(T, member)(L);
    }
    catch (Throwable e)
        return pushError(L, e);
}

// Class-table entry for a static method: no receiver is consumed.
private extern(C) int staticMethodThunk(T, string member)(lua_State* L) nothrow
{
    try
    {
        auto state = LuaState.wrap(L);
        auto nargs = cast(size_t) lua_gettop(L);

        static foreach (i, Method; __traits(getOverloads, T, member))
        {{
            static if (__traits(isStaticFunction, Method) && overloadBindable!Method)
            {
                alias Params = Parameters!Method;
                if (callMatches!Method(state, 1, nargs))
                {
                    Tuple!Params args;
                    fillCallArgs!Method(state, args, nargs, 1);

                    static if (is(ReturnType!Method == void))
                    {
                        Method(args.expand);
                        return 0;
                    }
                    else
                    {
                        return pushCallResult(state, Method(args.expand));
                    }
                }
            }
        }}

        throw new LuaArgumentException(
            "no matching overload for " ~ T.stringof ~ "." ~ member
            ~ "(" ~ luaArgumentTypes(L, 1, nargs) ~ ")");
    }
    catch (Throwable e)
        return pushError(L, e);
}

// ---------------------------------------------------------------------------
// Public class binding
// ---------------------------------------------------------------------------

struct LuaClass(T)
    if (is(T == class))
{
    /// Push `obj` as a full userdata. Null becomes Lua nil.
    ///
    /// Pushing the same D object again reuses the existing userdata while it is
    /// still reachable from Lua, preserving object identity and avoiding
    /// duplicate GC roots.
    static void push(LuaState state, T obj)
    {
        state.ensureOpen();
        if (obj is null)
        {
            lua_pushnil(state.handle);
            return;
        }

        auto L = state.handle;
        auto savedTop = state.top();
        scope(failure) state.setTop(savedTop);
        ensureMetatable(state);              // class metatable
        ensureIdentityTable(L, -1);          // class metatable, identity table
        auto metaIdx = raw.absIndex(L, -2);

        lua_pushlightuserdata(L, cast(void*) obj);
        lua_rawget(L, -2);                   // class metatable, identity, value
        if (lua_type(L, -1) == LUA_TUSERDATA)
        {
            // A userdata whose __gc already ran has a null boxed reference and
            // must not be handed out again (it may still be in the weak table
            // while its finalizer runs).
            auto existing = cast(T**) lua_touserdata(L, -1);
            if (existing !is null && *existing !is null)
            {
                raw.remove(L, -3);           // identity, userdata
                raw.remove(L, -2);           // userdata
                return;
            }
        }
        raw.pop(L, 1);                       // class metatable, identity

        auto p = cast(T*) raw.newUserdata(L, (void*).sizeof);
        *p = obj;
        addObjectRoot(cast(void*) obj);

        lua_pushvalue(L, metaIdx);           // class metatable, identity, userdata, metatable
        lua_setmetatable(L, -2);             // class metatable, identity, userdata

        lua_pushlightuserdata(L, cast(void*) obj);
        lua_pushvalue(L, -2);                // class metatable, identity, userdata, key, userdata
        lua_rawset(L, -4);                   // class metatable, identity, userdata
        raw.remove(L, -3);                   // identity, userdata
        raw.remove(L, -2);                   // userdata
    }

    /// Read a D object from a Lua userdata at `idx`.
    static T get(LuaState state, int idx)
    {
        state.ensureOpen();
        if (lua_type(state.handle, idx) == LUA_TNIL)
            return null;
        if (!isInstance(state, idx))
            throw new LuaTypeException("expected userdata of type " ~ T.stringof);
        auto p = cast(T*) lua_touserdata(state.handle, idx);
        requireLiveBox!T(p);
        return *p;
    }

    /// Push a global variable and register it under `name`.
    static void setGlobal(LuaState state, string name, T obj)
    {
        push(state, obj);
        state.setGlobal(name);
    }

    /// Read a global variable as a D object (null if nil).
    static T getGlobal(LuaState state, string name)
    {
        auto value = state.getGlobal!LuaValue(name);
        if (value.isNil())
            return null;
        StackGuard guard = StackGuard(state);
        value.push(state);
        return get(state, -1);
    }

    /// Check whether the value at `idx` is an instance of this class.
    static bool isInstance(LuaState state, int idx)
    {
        state.ensureOpen();
        idx = raw.absIndex(state.handle, idx); // stack pushes below shift idx
        if (lua_type(state.handle, idx) != LUA_TUSERDATA)
            return false;
        auto p = lua_touserdata(state.handle, idx);
        if (p is null)
            return false;

        StackGuard guard = StackGuard(state);
        ensureMetatable(state); // [T meta]

        if (lua_getmetatable(state.handle, idx) == 0)
            return false;
        // [T meta, userdata meta]
        if (lua_rawequal(state.handle, -1, -2) != 0)
            return true;

        // A derived class metatable lists its base metatables. Accept those,
        // but never a base userdata as an instance of a derived class. Use raw
        // access: the metatable is reachable from Lua, so a metatable attached
        // to it must not run `__index` here.
        lua_pushlstring(state.handle, "__lunarbind_bases".ptr,
                        "__lunarbind_bases".length);
        lua_rawget(state.handle, -2); // [T meta, ud meta, bases]
        if (lua_type(state.handle, -1) != LUA_TTABLE)
            return false;
        lua_pushvalue(state.handle, -3); // [T meta, ud meta, bases, T meta]
        lua_rawget(state.handle, -2);    // [T meta, ud meta, bases, value]
        return lua_type(state.handle, -1) != LUA_TNIL;
    }

    /// Create the class table without registering a global.
    ///
    /// The table is callable as `name(args...)` when the class has a bindable
    /// constructor. Every public static method becomes a field of the table;
    /// public instance methods are available both as `obj:method(...)` and as
    /// `name.method(obj, ...)`. Fields and properties are reached through the
    /// instance metatable. Use `bind` to also register the table as a global.
    static LuaTable createTable(LuaState state)
    {
        state.ensureOpen();
        auto L = state.handle;
        auto savedTop = state.top();
        scope(failure) state.setTop(savedTop);
        ensureMetatable(state);
        raw.pop(L, 1);

        lua_createtable(L, 0, 0);
        static if (hasBindableConstructor!T)
        {
            lua_createtable(L, 0, 1);
            pushCFunction(L, &constructorThunk!T);
            lua_setfield(L, -2, "__call");
            lua_setmetatable(L, -2);
        }

        static foreach (member; __traits(allMembers, T))
        {{
            static if (isPublicMember!(T, member) && isLuaExportedMember!(T, member))
            {
                static if (staticMethodBindable!(T, member))
                {
                    pushCFunction(L, &staticMethodThunk!(T, member));
                    lua_setfield(L, -2, toStringz(luaMemberName!(T, member)));
                }
                else static if (methodBindable!(T, member))
                {
                    pushCFunction(L, &classTableMethodThunk!(T, member));
                    lua_setfield(L, -2, toStringz(luaMemberName!(T, member)));
                }
            }
        }}

        auto ref_ = LuaRef.make(state, -1);
        state.pop(1);
        return LuaTable(ref_);
    }

    /// Bind this class as a global class table in one call.
    ///
    /// The table is callable as `name(args...)` when the class has a bindable
    /// constructor. Every public static method becomes a field of the table;
    /// public instance methods are available both as `obj:method(...)` and as
    /// `name.method(obj, ...)`. Fields and properties are reached through the
    /// instance metatable. `name` defaults to the D class name or its
    /// `@LuaExport("name")`. Returns a handle to the new table.
    static LuaTable bind(LuaState state, string name = luaTypeName!T)
    {
        auto table = createTable(state);
        table.push();
        state.setGlobal(name);
        return table;
    }

    /// Register a global callable class table so Lua can construct instances
    /// with `name(args...)`. This also exposes all public methods; see `bind`.
    static void registerConstructor(LuaState state, string name)
    {
        static assert(hasBindableConstructor!T,
                      "lunarbind: " ~ T.stringof ~
                      " has no constructor with bindable parameters");
        bind(state, name);
    }

    /// Ensure the class metatable exists in the registry.
    static void registerClass(LuaState state)
    {
        state.ensureOpen();
        ensureMetatable(state);
        raw.pop(state.handle, 1);
    }

    /// Bind the class as a global table (see `bind`).
    static void registerClass(LuaState state, string name)
    {
        bind(state, name);
    }

    private static void ensureMetatable(LuaState state)
    {
        auto name = toStringz(metaName!T);
        if (luaL_newmetatable(state.handle, name) != 0)
        {
            pushCFunction(state.handle, &classGc!T);
            lua_setfield(state.handle, -2, "__gc");
            pushCFunction(state.handle, &classIndex!T);
            lua_setfield(state.handle, -2, "__index");
            pushCFunction(state.handle, &classNewIndex!T);
            lua_setfield(state.handle, -2, "__newindex");
            pushClassEq(state.handle);
            lua_setfield(state.handle, -2, "__eq");
            static if (toStringBindable!T)
            {
                pushCFunction(state.handle, &classToString!T);
                lua_setfield(state.handle, -2, "__tostring");
            }
            static if (lengthBindable!T)
            {
                pushCFunction(state.handle, &classLen!T);
                lua_setfield(state.handle, -2, "__len");
            }

            setBinaryOperator!(T, "+", "__add")(state.handle);
            setBinaryOperator!(T, "-", "__sub")(state.handle);
            setBinaryOperator!(T, "*", "__mul")(state.handle);
            setBinaryOperator!(T, "/", "__div")(state.handle);
            setBinaryOperator!(T, "%", "__mod")(state.handle);
            setBinaryOperator!(T, "^^", "__pow")(state.handle);
            setBinaryOperator!(T, "~", "__concat")(state.handle);
            setBinaryOperator!(T, "&", "__band")(state.handle);
            setBinaryOperator!(T, "|", "__bor")(state.handle);
            setBinaryOperator!(T, "^", "__bxor")(state.handle);
            setBinaryOperator!(T, "<<", "__shl")(state.handle);
            setBinaryOperator!(T, ">>", "__shr")(state.handle);
            setUnaryOperator!(T, "-", "__unm")(state.handle);
            setUnaryOperator!(T, "~", "__bnot")(state.handle);
            setCompareOperator!(T, false)(state.handle);
            setCompareOperator!(T, true)(state.handle);
            static if (methodBindable!(T, "opCall"))
            {
                pushCFunction(state.handle, &methodThunk!(T, "opCall"));
                lua_setfield(state.handle, -2, "__call");
            }

            // Record every base-class metatable so LuaClass!Base can accept a
            // derived userdata (upcasts) without accepting downcasts.
            lua_createtable(state.handle, 0, 0);
            static foreach (B; BaseClassesTuple!T)
            {{
                static if (!is(B == Object))
                {
                    LuaClass!B.ensureMetatable(state); // [meta, bases, base meta]
                    lua_pushboolean(state.handle, 1);
                    lua_rawset(state.handle, -3);      // [meta, bases]
                }
            }}
            lua_setfield(state.handle, -2, "__lunarbind_bases");

            // Attach the identity table eagerly so normal pushes only pay for
            // one lookup. ensureIdentityTable leaves it on the stack.
            ensureIdentityTable(state.handle, -1);
            raw.pop(state.handle, 1);
        }
        // luaL_newmetatable leaves the metatable on the stack.
    }
}

/// Bind a D struct to Lua as a mutable box.
///
/// Lua holds an independent copy of the struct in userdata. While that box is
/// reachable, field writes and mutating methods from Lua persist and are
/// visible to subsequent reads. Pushing the same D value again creates a new
/// box; there is no struct identity. Reading a struct-valued field of a class
/// pushes a copy, so mutating that copy does not write back to the class field.
/// A finalized box is marked dead; if Lua resurrects it from `__gc`, field
/// access, method calls and `get` raise instead of reading the cleared value.
struct LuaStruct(S)
    if (is(S == struct))
{
    /// Push `value` as a full userdata box.
    static void push(T)(LuaState state, T value)
        if (is(Unqual!T == S))
    {
        state.ensureOpen();
        auto savedTop = state.top();
        scope(failure) state.setTop(savedTop);
        auto L = state.handle;
        ensureStructMetatable!S(state);      // [meta]
        auto p = cast(S*) raw.newUserdata(L, S.sizeof + 1);
        *p = cast(S) value;
        setStructBoxAlive!S(p, true);
        static if (hasDPointers!S)
            GC.addRange(p, S.sizeof);

        lua_pushvalue(L, -2);                // [meta, userdata, meta]
        lua_setmetatable(L, -2);             // [meta, userdata]
        raw.remove(L, -2);                   // [userdata]
    }

    /// Read a struct value from a boxed userdata at `idx` (by copy).
    static S get(LuaState state, int idx)
    {
        if (!isInstance(state, idx))
            throw new LuaTypeException("expected userdata of type " ~ S.stringof);
        auto p = cast(S*) lua_touserdata(state.handle, idx);
        requireLiveBox!S(p);
        return *p;
    }

    /// Push a global variable and register it under `name`.
    static void setGlobal(T)(LuaState state, string name, T value)
        if (is(Unqual!T == S))
    {
        push(state, value);
        state.setGlobal(name);
    }

    /// Read a global variable as a struct value (S.init if nil).
    static S getGlobal(LuaState state, string name)
    {
        auto value = state.getGlobal!LuaValue(name);
        if (value.isNil())
            return S.init;
        StackGuard guard = StackGuard(state);
        value.push(state);
        return get(state, -1);
    }

    /// Check whether the value at `idx` is a box of this struct type.
    static bool isInstance(LuaState state, int idx)
    {
        state.ensureOpen();
        idx = raw.absIndex(state.handle, idx);
        if (lua_type(state.handle, idx) != LUA_TUSERDATA)
            return false;

        StackGuard guard = StackGuard(state);
        ensureStructMetatable!S(state); // [meta]
        if (lua_getmetatable(state.handle, idx) == 0)
            return false;
        return lua_rawequal(state.handle, -1, -2) != 0;
    }

    /// Create the struct type table without registering a global.
    ///
    /// Every public static method becomes a field of the table. Struct values
    /// remain value-only and are bound with `push`, `setGlobal` or
    /// `toLua(L, value, name)`. The type table has no constructor because a
    /// struct has no object identity; create boxes from D or through a codec.
    static LuaTable createTable(LuaState state)
    {
        state.ensureOpen();
        auto savedTop = state.top();
        scope(failure) state.setTop(savedTop);
        lua_createtable(state.handle, 0, 0);
        static foreach (member; __traits(allMembers, S))
        {{
            static if (isPublicMember!(S, member) && isLuaExportedMember!(S, member))
            {
                static if (staticMethodBindable!(S, member))
                {
                    pushCFunction(state.handle, &staticMethodThunk!(S, member));
                    lua_setfield(state.handle, -2, toStringz(luaMemberName!(S, member)));
                }
            }
        }}

        auto ref_ = LuaRef.make(state, -1);
        state.pop(1);
        return LuaTable(ref_);
    }

    /// Bind this struct type as a global type table in one call.
    ///
    /// Every public static method becomes a field of the table. Struct values
    /// remain value-only and are bound with `push`, `setGlobal` or
    /// `toLua(L, value, name)`. The type table has no constructor because a
    /// struct has no object identity; create boxes from D or through a codec.
    /// `name` defaults to the D struct name or its `@LuaExport("name")`.
    /// Returns a handle to the new table.
    static LuaTable bind(LuaState state, string name = luaTypeName!S)
    {
        auto table = createTable(state);
        table.push();
        state.setGlobal(name);
        return table;
    }
}
