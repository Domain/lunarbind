/// EmmyLua stub generation from lunarbind's `@LuaExport` metadata.
///
/// `LuaStubBuilder` emits `.lua` declaration files for editors that understand
/// EmmyLua/LuaLS annotations. `luaStubs!Symbols()` is the one-call facade:
///
/// ```d
/// import std.file : write;
/// write("mymodule.lua", luaStubs!(Player, Vec, Status, some.module, add)());
/// ```
///
/// The generated declarations mirror the automatic tables: `@LuaExport` names
/// are used, skipped members are omitted, classes expose fields, properties,
/// constructors, instance methods and static methods, structs expose fields,
/// instance methods and static methods (no constructor), enums become
/// `---@enum` tables, and modules become function tables. Types referenced by
/// exported members and signatures are declared automatically, so the output
/// is self-contained.
module lunarbind.stub;

import lunarbind.bind : isModuleSymbol, isTypeSymbol, overloadSetLength;
import lunarbind.conv : LuaCodec, LuaString;
import lunarbind.coroutine : LuaThread;
import lunarbind.dispatch : fixedParamCount, isInjectedParameter,
                            typesafeVariadicElement;
import lunarbind.export_ : isLuaExportedMember, luaDescriptionOf,
                           luaMemberDescription, luaMemberName, luaNameOf,
                           luaTypeDescription, luaTypeName;
import lunarbind.function_ : LuaFunction;
import lunarbind.object : LuaClass, LuaStruct, fieldBindable, hasPropertyGetter,
                         hasPropertySetter, isPublicMember, methodBindable,
                         overloadBindable, propertyGetter, propertySetter,
                         staticMethodBindable;
import lunarbind.state : LuaRef, LuaState;
import lunarbind.table : LuaTable;
import lunarbind.value : LuaValue;

import std.algorithm : canFind;
import std.array : Appender, join;
import std.conv : to;
import std.traits : BaseClassesTuple, FieldTypeTuple, isAssociativeArray,
                    isDynamicArray, isFloatingPoint, isInstanceOf, isIntegral,
                    isPointer, isSomeFunction, isSomeString, OriginalType,
                    ParameterDefaults, ParameterIdentifierTuple, Parameters,
                    ReturnType, Unqual, Variadic, variadicFunctionStyle;
import std.typecons : Nullable, Tuple;

// ---------------------------------------------------------------------------
// Type mapping
// ---------------------------------------------------------------------------

/// Map a D type to an EmmyLua type annotation.
package string luaStubType(T)()
{
    alias U = Unqual!T;

    static if (is(U == void) || is(U == typeof(null)))
        return "nil";
    else static if (is(U == bool))
        return "boolean";
    else static if (is(U == LuaValue))
        return "any";
    else static if (is(U == LuaRef))
        return "any";
    else static if (is(U == LuaTable))
        return "table";
    else static if (is(U == LuaFunction))
        return "function";
    else static if (is(U == LuaThread))
        return "thread";
    else static if (is(U == LuaString))
        return "string";
    else static if (is(U == LuaState))
        return "any";
    else static if (is(U == enum))
        return luaTypeName!U;
    else static if (is(U == class))
        return luaTypeName!U;
    else static if (isInstanceOf!(Nullable, U))
        return luaStubType!(typeof(U.init.get)) ~ "|nil";
    else static if (isSomeString!U)
        return "string";
    else static if (isDynamicArray!U)
        return luaStubType!(typeof(U.init[0])) ~ "[]";
    else static if (isAssociativeArray!U)
        return "table<" ~ luaStubType!(typeof(U.init.keys[0])) ~ ", "
            ~ luaStubType!(typeof(U.init.values[0])) ~ ">";
    else static if (isSomeFunction!U)
        return "function";
    else static if (isInstanceOf!(Tuple, U))
        return "any";
    else static if (is(U == struct))
        return luaTypeName!U;
    else static if (isPointer!U)
        return "lightuserdata";
    else static if (isIntegral!U)
        return "integer";
    else static if (isFloatingPoint!U)
        return "number";
    else
        return "any";
}

// ---------------------------------------------------------------------------
// Compile-time helpers
// ---------------------------------------------------------------------------

private template isVariadicTail(alias Func, size_t i)
{
    enum isVariadicTail =
        variadicFunctionStyle!Func == Variadic.typesafe
        && i == fixedParamCount!Func;
}

private template paramOptional(alias Func, size_t i)
{
    static if (is(ParameterDefaults!Func[i] == void))
        enum paramOptional = false;
    else
        enum paramOptional = true;
}

private string paramName(alias Func, size_t i)()
{
    alias names = ParameterIdentifierTuple!Func;
    enum name = names[i];
    return name.length ? name : "arg" ~ to!string(i);
}

private string enumValueLiteral(E, string member)()
{
    alias Base = OriginalType!E;
    static if (isSomeString!Base)
        return `"` ~ to!string(cast(Base) __traits(getMember, E, member)) ~ `"`;
    else
        return to!string(cast(Base) __traits(getMember, E, member));
}

private template symbolValueType(alias Symbol)
{
    static if (isTypeSymbol!Symbol)
        alias symbolValueType = Symbol;
    else
        alias symbolValueType = typeof(Symbol);
}

// Types that are worth declaring automatically when they appear in a public
// field or signature. Lua handles are mapped to primitive Lua types, and the
// D root/exception hierarchy is never part of a binding.
private template isDiscoverableType(T)
{
    alias U = Unqual!T;
    static if (is(U == class))
        enum isDiscoverableType = !is(U == Object) && !is(U : Throwable);
    else static if (is(U == struct))
        enum isDiscoverableType =
            !is(U == LuaValue)
            && !is(U == LuaRef)
            && !is(U == LuaTable)
            && !is(U == LuaFunction)
            && !is(U == LuaThread)
            && !is(U == LuaString)
            && !is(U == LuaState)
            && !isInstanceOf!(Nullable, U)
            && !isInstanceOf!(Tuple, U)
            && !isInstanceOf!(LuaClass, U)
            && !isInstanceOf!(LuaStruct, U)
            && !isInstanceOf!(LuaCodec, U);
    else static if (is(U == enum))
        enum isDiscoverableType = true;
    else
        enum isDiscoverableType = false;
}

private template isStaticOverload(alias F)
{
    static if (__traits(compiles, __traits(isStaticFunction, F)))
        enum isStaticOverload = __traits(isStaticFunction, F);
    else
        enum isStaticOverload = false;
}

private template isInstanceProperty(T, string member)
{
    static if (hasPropertyGetter!(T, member))
        enum isInstanceProperty = !isStaticOverload!(propertyGetter!(T, member));
    else static if (hasPropertySetter!(T, member))
        enum isInstanceProperty = !isStaticOverload!(propertySetter!(T, member));
    else
        enum isInstanceProperty = false;
}

private template countBindableOverloads(alias Parent, string member,
                                        bool staticOnly, bool instanceOnly,
                                        size_t i = 0)
{
    static if (__traits(compiles, __traits(getOverloads, Parent, member)))
    {
        alias overloads = __traits(getOverloads, Parent, member);
        static if (i < overloads.length)
        {
            alias F = overloads[i];
            enum ok = overloadBindable!F
                && (!staticOnly || isStaticOverload!F)
                && (!instanceOnly || !isStaticOverload!F);
            enum countBindableOverloads =
                (ok ? 1 : 0)
                + countBindableOverloads!(Parent, member, staticOnly,
                                          instanceOnly, i + 1);
        }
        else
            enum countBindableOverloads = 0;
    }
    else
        enum countBindableOverloads = 0;
}

private template countBindableConstructors(T, size_t i = 0)
{
    static if (__traits(compiles, __traits(getOverloads, T, "__ctor")))
    {
        alias ctors = __traits(getOverloads, T, "__ctor");
        static if (i < ctors.length)
        {
            alias Ctor = ctors[i];
            enum ok = overloadBindable!Ctor
                && __traits(compiles, new T(Parameters!Ctor.init));
            enum countBindableConstructors =
                (ok ? 1 : 0) + countBindableConstructors!(T, i + 1);
        }
        else
            enum countBindableConstructors = 0;
    }
    else
        enum countBindableConstructors = 0;
}

private template moduleMemberPublic(alias Module, string member)
{
    static if (__traits(compiles,
                        __traits(getProtection,
                                 __traits(getMember, Module, member))))
        enum moduleMemberPublic =
            __traits(getProtection,
                     __traits(getMember, Module, member)) == "public";
    else
        enum moduleMemberPublic = false;
}

private template anyBindableOverload(alias Parent, string member, size_t i = 0)
{
    static if (i < __traits(getOverloads, Parent, member).length)
        enum anyBindableOverload =
            overloadBindable!(__traits(getOverloads, Parent, member)[i])
            || anyBindableOverload!(Parent, member, i + 1);
    else
        enum anyBindableOverload = false;
}

private template moduleMemberBindable(alias Module, string member)
{
    static if (member == "main" || !isLuaExportedMember!(Module, member))
        enum moduleMemberBindable = false;
    else static if (__traits(compiles, __traits(getOverloads, Module, member))
                    && __traits(getOverloads, Module, member).length > 0)
        enum moduleMemberBindable = anyBindableOverload!(Module, member);
    else
        enum moduleMemberBindable = false;
}

// ---------------------------------------------------------------------------
// Builder
// ---------------------------------------------------------------------------

/// Collect EmmyLua declarations and return them as one string.
struct LuaStubBuilder
{
    private Appender!(char[]) _output;
    private string[] _declared;
    private string[TypeInfo] _typeOverrides;

    /// Override the EmmyLua type used for `T` in this builder.
    ///
    /// Use this when `T` has a custom `registerCodec` representation (for
    /// example a struct encoded as a plain `table` or `string`). Overrides also
    /// suppress automatic declaration of the type and are applied recursively
    /// to arrays, associative arrays and `Nullable`.
    void setType(T)(string luaType)
    {
        _typeOverrides[typeid(Unqual!T)] = luaType;
    }

    /// Set a type override from runtime type information.
    void setTypeOverride(TypeInfo info, string luaType)
    {
        _typeOverrides[info] = luaType;
    }

    /// Remove a previously set type override.
    void clearType(T)()
    {
        _typeOverrides.remove(typeid(Unqual!T));
    }

    private bool hasTypeOverride(T)()
    {
        static if (__traits(compiles, typeid(Unqual!T)))
            return (typeid(Unqual!T) in _typeOverrides) !is null;
        else
            return false;
    }

    private string typeText(T)()
    {
        alias U = Unqual!T;
        static if (isSomeString!U)
            return "string";
        else static if (isInstanceOf!(Nullable, U))
            return typeText!(typeof(U.init.get))() ~ "|nil";
        else static if (isDynamicArray!U)
            return typeText!(typeof(U.init[0]))() ~ "[]";
        else static if (isAssociativeArray!U)
            return "table<" ~ typeText!(typeof(U.init.keys[0]))() ~ ", "
                ~ typeText!(typeof(U.init.values[0]))() ~ ">";
        else
        {
            static if (__traits(compiles, typeid(U)))
            {
                auto found = typeid(U) in _typeOverrides;
                if (found !is null)
                    return *found;
            }
            return luaStubType!T();
        }
    }

    private void putDescription(string description)
    {
        if (description.length)
            putLine("--- " ~ description);
    }

    private void putLine(string line)
    {
        _output.put(line);
        _output.put('\n');
    }

    private void putBlank()
    {
        _output.put('\n');
    }

    private bool isDeclared(string name) const
    {
        return _declared.canFind(name);
    }

    private void markDeclared(string name)
    {
        if (!isDeclared(name))
            _declared ~= name;
    }

    private string overloadParams(alias Func)(string selfType = null)
    {
        string[] parts;
        if (selfType.length)
            parts ~= "self: " ~ selfType;

        static foreach (i, P; Parameters!Func)
        {{
            static if (!isInjectedParameter!P)
            {
                static if (isVariadicTail!(Func, i))
                    parts ~= "...: " ~ typeText!(typesafeVariadicElement!Func)();
                else
                    parts ~= paramName!(Func, i)
                        ~ (paramOptional!(Func, i) ? "?: " : ": ")
                        ~ typeText!P();
            }
        }}
        return parts.join(", ");
    }

    private string signatureParams(alias Func)(string selfName = null)
    {
        string[] parts;
        if (selfName.length)
            parts ~= selfName;

        static foreach (i, P; Parameters!Func)
        {{
            static if (!isInjectedParameter!P)
            {
                static if (isVariadicTail!(Func, i))
                    parts ~= "...";
                else
                    parts ~= paramName!(Func, i);
            }
        }}
        return parts.join(", ");
    }

    private string returnTypeText(R)()
    {
        static if (is(R == void))
            return "";
        else static if (isInstanceOf!(Tuple, Unqual!R))
        {
            string[] types;
            static foreach (T; FieldTypeTuple!(Unqual!R))
                types ~= typeText!T();
            return types.join(", ");
        }
        else
            return typeText!R();
    }

    private void putParamAnnotations(alias Func)(string selfType = null)
    {
        if (selfType.length)
            putLine("---@param self " ~ selfType);

        static foreach (i, P; Parameters!Func)
        {{
            static if (!isInjectedParameter!P)
            {
                static if (isVariadicTail!(Func, i))
                    putLine("---@vararg "
                            ~ typeText!(typesafeVariadicElement!Func)());
                else
                    putLine("---@param " ~ paramName!(Func, i)
                            ~ (paramOptional!(Func, i) ? "? " : " ")
                            ~ typeText!P());
            }
        }}

        alias R = ReturnType!Func;
        static if (!is(R == void))
        {
            static if (isInstanceOf!(Tuple, Unqual!R))
            {
                static foreach (T; FieldTypeTuple!(Unqual!R))
                    putLine("---@return " ~ typeText!T());
            }
            else
                putLine("---@return " ~ typeText!R());
        }
    }

    private void putConstructorAnnotations(alias Ctor)(string className)
    {
        static foreach (i, P; Parameters!Ctor)
        {{
            static if (!isInjectedParameter!P)
            {
                static if (isVariadicTail!(Ctor, i))
                    putLine("---@vararg "
                            ~ typeText!(typesafeVariadicElement!Ctor)());
                else
                    putLine("---@param " ~ paramName!(Ctor, i)
                            ~ (paramOptional!(Ctor, i) ? "? " : " ")
                            ~ typeText!P());
            }
        }}
        putLine("---@return " ~ className);
    }

    private void putSingleFunction(alias Func)(string table, string name,
                                               string selfType = null)
    {
        putParamAnnotations!Func(selfType);
        auto prefix = table.length ? table ~ "." : "";
        auto selfName = selfType.length ? "self" : "";
        putLine("function " ~ prefix ~ name ~ "("
                ~ signatureParams!Func(selfName) ~ ") end");
        putBlank();
    }

    private void putFunctionSet(alias Parent, string member,
                                bool staticOnly = false,
                                bool instanceOnly = false)(string table,
                                                           string name,
                                                           string selfType = null,
                                                           string description = null)
    {
        enum count = countBindableOverloads!(Parent, member, staticOnly,
                                             instanceOnly);
        static if (count == 0)
        {
            // Nothing bindable; emit no declaration.
        }
        else
        {
            putDescription(description);
            static if (count == 1)
            {
                static foreach (F; __traits(getOverloads, Parent, member))
                {{
                    static if (overloadBindable!F
                               && (!staticOnly || isStaticOverload!F)
                               && (!instanceOnly || !isStaticOverload!F))
                        putSingleFunction!F(table, name, selfType);
                }}
            }
            else
            {
                static foreach (F; __traits(getOverloads, Parent, member))
                {{
                    static if (overloadBindable!F
                               && (!staticOnly || isStaticOverload!F)
                               && (!instanceOnly || !isStaticOverload!F))
                    {
                        auto ret = returnTypeText!(ReturnType!F)();
                        putLine("---@overload fun("
                                ~ overloadParams!F(selfType) ~ ")"
                                ~ (ret.length ? ": " ~ ret : ""));
                    }
                }}

                auto prefix = table.length ? table ~ "." : "";
                auto self = selfType.length ? "self, " : "";
                putLine("function " ~ prefix ~ name ~ "(" ~ self ~ "...) end");
                putBlank();
            }
        }
    }

    private void putConstructors(T)(string name)
    {
        static if (__traits(compiles, __traits(getOverloads, T, "__ctor")))
        {
            enum count = countBindableConstructors!T;
            static if (count == 1)
            {
                static foreach (Ctor; __traits(getOverloads, T, "__ctor"))
                {{
                    static if (overloadBindable!Ctor
                               && __traits(compiles,
                                           new T(Parameters!Ctor.init)))
                    {
                        putConstructorAnnotations!Ctor(name);
                        putLine("function " ~ name ~ "("
                                ~ signatureParams!Ctor() ~ ") end");
                        putBlank();
                    }
                }}
            }
            else static if (count > 1)
            {
                static foreach (Ctor; __traits(getOverloads, T, "__ctor"))
                {{
                    static if (overloadBindable!Ctor
                               && __traits(compiles,
                                           new T(Parameters!Ctor.init)))
                        putLine("---@overload fun("
                                ~ overloadParams!Ctor() ~ "): " ~ name);
                }}
                putLine("function " ~ name ~ "(...) end");
                putBlank();
            }
        }
        else static if (__traits(compiles, new T()))
        {
            putLine("---@return " ~ name);
            putLine("function " ~ name ~ "() end");
            putBlank();
        }
    }

    private void putFields(T)()
    {
        string[] emitted;
        static foreach (member; __traits(allMembers, T))
        {{
            static if (isPublicMember!(T, member)
                       && isLuaExportedMember!(T, member))
            {
                static if (isInstanceProperty!(T, member))
                {
                    enum fieldName = luaMemberName!(T, member);
                    if (!emitted.canFind(fieldName))
                    {
                        auto desc = luaMemberDescription!(T, member);
                        static if (hasPropertyGetter!(T, member))
                            putLine("---@field public " ~ fieldName ~ " "
                                    ~ typeText!(
                                        ReturnType!(propertyGetter!(T, member)))()
                                    ~ (desc.length ? " # " ~ desc : ""));
                        else
                            putLine("---@field public " ~ fieldName ~ " "
                                    ~ typeText!(
                                        Parameters!(propertySetter!(T, member))[0])()
                                    ~ (desc.length ? " # " ~ desc : ""));
                        emitted ~= fieldName;
                    }
                }
                else static if (fieldBindable!(T, member))
                {
                    enum fieldName = luaMemberName!(T, member);
                    if (!emitted.canFind(fieldName))
                    {
                        alias FT = typeof(__traits(getMember, T.init, member));
                        auto desc = luaMemberDescription!(T, member);
                        putLine("---@field public " ~ fieldName ~ " "
                                ~ typeText!(Unqual!FT)()
                                ~ (desc.length ? " # " ~ desc : ""));
                        emitted ~= fieldName;
                    }
                }
            }
        }}
    }

    private void putMethods(T)(string name)
    {
        static foreach (member; __traits(allMembers, T))
        {{
            static if (isPublicMember!(T, member)
                       && isLuaExportedMember!(T, member)
                       && !isInstanceProperty!(T, member)
                       && !fieldBindable!(T, member))
            {
                static if (staticMethodBindable!(T, member))
                    putFunctionSet!(T, member, true)(
                        name, luaMemberName!(T, member), null,
                        luaMemberDescription!(T, member));
                else static if (methodBindable!(T, member))
                    putFunctionSet!(T, member, false, true)(
                        name, luaMemberName!(T, member), name,
                        luaMemberDescription!(T, member));
            }
        }}
    }

    // Struct values have no table of their own, so instance methods are
    // declared as function-typed fields of the value class.
    private void putInstanceMethodFields(T)(string name)
    {
        static foreach (member; __traits(allMembers, T))
        {{
            static if (isPublicMember!(T, member)
                       && isLuaExportedMember!(T, member)
                       && !isInstanceProperty!(T, member)
                       && !fieldBindable!(T, member)
                       && methodBindable!(T, member))
            {
                enum fieldName = luaMemberName!(T, member);
                enum count = countBindableOverloads!(T, member, false, true);
                auto desc = luaMemberDescription!(T, member);
                static if (count == 1)
                {
                    static foreach (F; __traits(getOverloads, T, member))
                    {{
                        static if (overloadBindable!F && !isStaticOverload!F)
                        {
                            auto ret = returnTypeText!(ReturnType!F)();
                            putLine("---@field public " ~ fieldName ~ " fun("
                                    ~ overloadParams!F(name) ~ ")"
                                    ~ (ret.length ? ": " ~ ret : "")
                                    ~ (desc.length ? " # " ~ desc : ""));
                        }
                    }}
                }
                else static if (count > 1)
                    putLine("---@field public " ~ fieldName ~ " fun(self: "
                            ~ name ~ ", ...): any"
                            ~ (desc.length ? " # " ~ desc : ""));
            }
        }}
    }

    private void addReferenced(T)()
    {
        alias U = Unqual!T;
        static if (isDynamicArray!U)
            addReferenced!(typeof(U.init[0]))();
        else static if (isAssociativeArray!U)
        {
            addReferenced!(typeof(U.init.keys[0]))();
            addReferenced!(typeof(U.init.values[0]))();
        }
        else static if (isInstanceOf!(Nullable, U))
            addReferenced!(typeof(U.init.get))();
        else static if (isInstanceOf!(Tuple, U))
        {
            static foreach (E; FieldTypeTuple!U)
                addReferenced!E();
        }
        else static if (isDiscoverableType!U)
        {
            // A custom codec representation replaces the default class/struct
            // declaration, so do not auto-declare overridden types.
            if (!hasTypeOverride!U)
            {
                static if (is(U == class))
                    addClass!U();
                else static if (is(U == struct))
                    addStruct!U();
                else static if (is(U == enum))
                    addEnum!U();
            }
        }
    }

    private void addReferencedFromFunction(alias F)()
    {
        static foreach (i, P; Parameters!F)
        {{
            static if (!isInjectedParameter!P)
                addReferenced!P();
        }}

        alias R = ReturnType!F;
        static if (!is(R == void))
            addReferenced!R();
    }

    private void addReferencedMembers(T, bool includeConstructors = false)()
    {
        static foreach (member; __traits(allMembers, T))
        {{
            static if (isPublicMember!(T, member)
                       && isLuaExportedMember!(T, member))
            {
                static if (isInstanceProperty!(T, member))
                {
                    static if (hasPropertyGetter!(T, member))
                        addReferenced!(ReturnType!(propertyGetter!(T, member)))();
                    else static if (hasPropertySetter!(T, member))
                        addReferenced!(Parameters!(propertySetter!(T, member))[0])();
                }
                else static if (fieldBindable!(T, member))
                    addReferenced!(typeof(__traits(getMember, T.init, member)))();
                else static if (staticMethodBindable!(T, member)
                                || methodBindable!(T, member))
                {
                    static foreach (F; __traits(getOverloads, T, member))
                    {{
                        static if (overloadBindable!F)
                            addReferencedFromFunction!F();
                    }}
                }
            }
        }}

        static if (includeConstructors
                   && __traits(compiles, __traits(getOverloads, T, "__ctor")))
            static foreach (Ctor; __traits(getOverloads, T, "__ctor"))
            {{
                static if (overloadBindable!Ctor
                           && __traits(compiles, new T(Parameters!Ctor.init)))
                    addReferencedFromFunction!Ctor();
            }}
    }

    /// Add a global function or overload set.
    void addFunction(alias Symbol)(string name = luaNameOf!Symbol,
                                   string description = luaDescriptionOf!Symbol)
    {
        putDescription(description);
        static if (overloadSetLength!Symbol > 1)
        {
            static foreach (F; __traits(getOverloads, __traits(parent, Symbol),
                                        __traits(identifier, Symbol)))
            {{
                static if (overloadBindable!F)
                    addReferencedFromFunction!F();
            }}
            putFunctionSet!(__traits(parent, Symbol),
                            __traits(identifier, Symbol))("", name);
        }
        else
        {
            static if (__traits(compiles, Parameters!Symbol)
                       && __traits(compiles, ReturnType!Symbol))
                addReferencedFromFunction!Symbol();
            putSingleFunction!Symbol("", name);
        }
    }

    /// Add a class type table.
    void addClass(T)(string name = luaTypeName!T,
                     string description = luaTypeDescription!T)
    {
        static assert(is(T == class),
                      "lunarbind: addClass requires a class type");

        if (isDeclared(name))
            return;

        // Mark the type before traversing so self-references and cycles do not
        // recurse, then emit referenced types and the base class first.
        markDeclared(name);

        // Emit bindable base classes first so `---@class Derived : Base`
        // refers to a declared type. Object is the implicit D root and has no
        // Lua binding.
        static if (BaseClassesTuple!T.length
                   && !is(BaseClassesTuple!T[0] == Object))
            addClass!(BaseClassesTuple!T[0])();

        addReferencedMembers!(T, true)();

        putDescription(description);
        string header = "---@class " ~ name;
        static if (BaseClassesTuple!T.length
                   && !is(BaseClassesTuple!T[0] == Object))
            header ~= " : " ~ luaTypeName!(BaseClassesTuple!T[0]);
        putLine(header);
        putFields!T();
        putLine(name ~ " = {}");
        putBlank();
        putConstructors!T(name);
        putMethods!T(name);
    }

    /// Add a struct type table and value declaration.
    void addStruct(S)(string name = luaTypeName!S,
                      string description = luaTypeDescription!S)
    {
        static assert(is(Unqual!S == struct),
                      "lunarbind: addStruct requires a struct type");

        if (isDeclared(name))
            return;
        markDeclared(name);

        // Struct values are value-only, so there is no constructor to inspect.
        addReferencedMembers!(S, false)();

        putDescription(description);
        putLine("---@class " ~ name);
        putFields!S();
        putInstanceMethodFields!S(name);
        putLine(name ~ " = {}");
        putBlank();

        // Struct type tables expose static methods only; values are boxed
        // separately and have no constructor.
        static foreach (member; __traits(allMembers, S))
        {{
            static if (isPublicMember!(S, member)
                       && isLuaExportedMember!(S, member)
                       && staticMethodBindable!(S, member))
                putFunctionSet!(S, member, true)(
                    name, luaMemberName!(S, member), null,
                    luaMemberDescription!(S, member));
        }}
    }

    /// Add an enum table.
    void addEnum(E)(string name = luaTypeName!E,
                    string description = luaTypeDescription!E)
    {
        static assert(is(E == enum),
                      "lunarbind: addEnum requires an enum type");

        if (isDeclared(name))
            return;
        markDeclared(name);

        putDescription(description);
        putLine("---@enum " ~ name);
        putLine(name ~ " = {");
        static foreach (member; __traits(allMembers, E))
        {{
            static if (isLuaExportedMember!(E, member))
            {
                auto desc = luaMemberDescription!(E, member);
                putLine("    " ~ luaMemberName!(E, member) ~ " = "
                        ~ enumValueLiteral!(E, member)() ~ ","
                        ~ (desc.length ? " -- " ~ desc : ""));
            }
        }}
        putLine("}");
        putBlank();
    }

    /// Add a module function table.
    void addModule(alias Module)(string name = luaNameOf!Module,
                                 string description = luaDescriptionOf!Module)
    {
        if (isDeclared(name))
            return;
        markDeclared(name);

        // Declare types used by exported function signatures before the
        // module table itself.
        static foreach (member; __traits(allMembers, Module))
        {{
            static if (moduleMemberPublic!(Module, member)
                       && moduleMemberBindable!(Module, member))
                static foreach (F; __traits(getOverloads, Module, member))
                {{
                    static if (overloadBindable!F)
                        addReferencedFromFunction!F();
                }}
        }}

        putDescription(description);
        putLine("---@class " ~ name);
        putLine(name ~ " = {}");
        putBlank();

        static foreach (member; __traits(allMembers, Module))
        {{
            static if (moduleMemberPublic!(Module, member)
                       && moduleMemberBindable!(Module, member))
                putFunctionSet!(Module, member)(
                    name, luaMemberName!(Module, member), null,
                    luaMemberDescription!(Module, member));
        }}
    }

    /// Add a global value with an explicit type annotation. `Symbol` may be a
    /// type or a variable.
    void addValue(alias Symbol)(string name, string luaType)
    {
        addReferenced!(symbolValueType!Symbol)();
        putDescription(luaDescriptionOf!Symbol);
        putLine("---@type " ~ luaType);
        putLine(name ~ " = nil");
        putBlank();
    }

    /// Add a global value using the default EmmyLua type for `Symbol`.
    void addValue(alias Symbol)(string name)
    {
        addValue!Symbol(name, typeText!(symbolValueType!Symbol)());
    }

    /// Add any supported compile-time symbol.
    void addSymbol(alias Symbol)()
    {
        static if (isTypeSymbol!Symbol)
        {
            static if (is(Symbol == class))
                addClass!Symbol();
            else static if (is(Unqual!Symbol == struct))
                addStruct!Symbol();
            else static if (is(Symbol == enum))
                addEnum!Symbol();
            else
                static assert(0, "lunarbind: luaStubs does not support type "
                              ~ Symbol.stringof);
        }
        else static if (isModuleSymbol!Symbol)
            addModule!Symbol();
        else static if (overloadSetLength!Symbol > 1)
            addFunction!Symbol();
        else static if (is(typeof(Symbol) == function)
                        || is(typeof(Symbol) == delegate))
            addFunction!Symbol();
        else static if (__traits(compiles, typeof(Symbol)))
            addValue!Symbol(luaNameOf!Symbol);
        else
            static assert(0, "lunarbind: luaStubs cannot describe "
                          ~ Symbol.stringof);
    }

    /// The generated EmmyLua declarations.
    string toString() const
    {
        return _output.data.idup;
    }
}

/// Generate EmmyLua declarations for a list of compile-time symbols.
///
/// The result starts with `---@meta` and declares the bound globals, so it can
/// be written directly to a LuaLS meta/stub file.
string luaStubs(Symbols...)()
{
    LuaStubBuilder builder;
    static foreach (Symbol; Symbols)
        builder.addSymbol!Symbol();
    return "---@meta\n\n" ~ builder.toString();
}

/// Generate EmmyLua declarations with explicit Lua type overrides.
///
/// The associative array maps `typeid(T)` to the EmmyLua type that should be
/// used for `T`, which is useful for types with a custom `registerCodec`
/// representation:
///
/// ```d
/// auto stubs = luaStubs!(Player, Vec2)([typeid(Vec2): "table"]);
/// ```
string luaStubs(Symbols...)(string[TypeInfo] typeOverrides)
{
    LuaStubBuilder builder;
    foreach (info, luaType; typeOverrides)
        builder.setTypeOverride(info, luaType);
    static foreach (Symbol; Symbols)
        builder.addSymbol!Symbol();
    return "---@meta\n\n" ~ builder.toString();
}
