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
/// `---@enum` tables, and modules become function tables.
module lunarbind.stub;

import lunarbind.bind : isModuleSymbol, isTypeSymbol, overloadSetLength;
import lunarbind.conv : LuaString;
import lunarbind.dispatch : fixedParamCount, isInjectedParameter,
                            typesafeVariadicElement;
import lunarbind.export_ : isLuaExportedMember, luaMemberName, luaNameOf,
                           luaTypeName;
import lunarbind.function_ : LuaFunction;
import lunarbind.object : fieldBindable, hasPropertyGetter, hasPropertySetter,
                         isPublicMember, methodBindable, overloadBindable,
                         propertyGetter, propertySetter, staticMethodBindable;
import lunarbind.state : LuaRef, LuaState;
import lunarbind.table : LuaTable;
import lunarbind.value : LuaValue;

import std.algorithm : canFind;
import std.array : Appender, join;
import std.conv : to;
import std.traits : BaseClassesTuple, FieldTypeTuple, FunctionAttribute,
                    functionAttributes, isAssociativeArray, isDynamicArray,
                    isFloatingPoint, isInstanceOf, isIntegral, isPointer,
                    isSomeFunction, isSomeString, OriginalType, ParameterDefaults,
                    ParameterIdentifierTuple, Parameters, ReturnType, Unqual,
                    Variadic, variadicFunctionStyle;
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
                    parts ~= "...: " ~ luaStubType!(typesafeVariadicElement!Func);
                else
                    parts ~= paramName!(Func, i)
                        ~ (paramOptional!(Func, i) ? "?: " : ": ")
                        ~ luaStubType!P;
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
                types ~= luaStubType!T;
            return types.join(", ");
        }
        else
            return luaStubType!R;
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
                            ~ luaStubType!(typesafeVariadicElement!Func));
                else
                    putLine("---@param " ~ paramName!(Func, i)
                            ~ (paramOptional!(Func, i) ? "? " : " ")
                            ~ luaStubType!P);
            }
        }}

        alias R = ReturnType!Func;
        static if (!is(R == void))
        {
            static if (isInstanceOf!(Tuple, Unqual!R))
            {
                static foreach (T; FieldTypeTuple!(Unqual!R))
                    putLine("---@return " ~ luaStubType!T);
            }
            else
                putLine("---@return " ~ luaStubType!R);
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
                            ~ luaStubType!(typesafeVariadicElement!Ctor));
                else
                    putLine("---@param " ~ paramName!(Ctor, i)
                            ~ (paramOptional!(Ctor, i) ? "? " : " ")
                            ~ luaStubType!P);
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
                                                           string selfType = null)
    {
        enum count = countBindableOverloads!(Parent, member, staticOnly,
                                             instanceOnly);
        static if (count == 0)
        {
            // Nothing bindable; emit no declaration.
        }
        else static if (count == 1)
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

    private void putFields(T)(string name)
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
                        static if (hasPropertyGetter!(T, member))
                            putLine("---@field public " ~ fieldName ~ " "
                                    ~ luaStubType!(
                                        ReturnType!(propertyGetter!(T, member))));
                        else
                            putLine("---@field public " ~ fieldName ~ " "
                                    ~ luaStubType!(
                                        Parameters!(propertySetter!(T, member))[0]));
                        emitted ~= fieldName;
                    }
                }
                else static if (fieldBindable!(T, member))
                {
                    enum fieldName = luaMemberName!(T, member);
                    if (!emitted.canFind(fieldName))
                    {
                        alias FT = typeof(__traits(getMember, T.init, member));
                        putLine("---@field public " ~ fieldName ~ " "
                                ~ luaStubType!(Unqual!FT));
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
                    putFunctionSet!(T, member, true)(name,
                                                     luaMemberName!(T, member));
                else static if (methodBindable!(T, member))
                    putFunctionSet!(T, member, false, true)(
                        name, luaMemberName!(T, member), name);
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
                static if (count == 1)
                {
                    static foreach (F; __traits(getOverloads, T, member))
                    {{
                        static if (overloadBindable!F && !isStaticOverload!F)
                        {
                            auto ret = returnTypeText!(ReturnType!F)();
                            putLine("---@field public " ~ fieldName ~ " fun("
                                    ~ overloadParams!F(name) ~ ")"
                                    ~ (ret.length ? ": " ~ ret : ""));
                        }
                    }}
                }
                else static if (count > 1)
                    putLine("---@field public " ~ fieldName ~ " fun(self: "
                            ~ name ~ ", ...): any");
            }
        }}
    }

    /// Add a global function or overload set.
    void addFunction(alias Symbol)(string name = luaNameOf!Symbol)
    {
        static if (overloadSetLength!Symbol > 1)
            putFunctionSet!(__traits(parent, Symbol),
                            __traits(identifier, Symbol))("", name);
        else
            putSingleFunction!Symbol("", name);
    }

    /// Add a class type table.
    void addClass(T)(string name = luaTypeName!T)
    {
        static assert(is(T == class),
                      "lunarbind: addClass requires a class type");

        if (isDeclared(name))
            return;
        markDeclared(name);

        string header = "---@class " ~ name;
        static if (BaseClassesTuple!T.length
                   && !is(BaseClassesTuple!T[0] == Object))
            header ~= " : " ~ luaTypeName!(BaseClassesTuple!T[0]);
        putLine(header);
        putFields!T(name);
        putLine("local " ~ name ~ " = {}");
        putBlank();
        putConstructors!T(name);
        putMethods!T(name);
    }

    /// Add a struct type table and value declaration.
    void addStruct(S)(string name = luaTypeName!S)
    {
        static assert(is(Unqual!S == struct),
                      "lunarbind: addStruct requires a struct type");

        if (isDeclared(name))
            return;
        markDeclared(name);

        putLine("---@class " ~ name);
        putFields!S(name);
        putInstanceMethodFields!S(name);
        putLine("local " ~ name ~ " = {}");
        putBlank();

        // Struct type tables expose static methods only; values are boxed
        // separately and have no constructor.
        static foreach (member; __traits(allMembers, S))
        {{
            static if (isPublicMember!(S, member)
                       && isLuaExportedMember!(S, member)
                       && staticMethodBindable!(S, member))
                putFunctionSet!(S, member, true)(name,
                                                 luaMemberName!(S, member));
        }}
    }

    /// Add an enum table.
    void addEnum(E)(string name = luaTypeName!E)
    {
        static assert(is(E == enum),
                      "lunarbind: addEnum requires an enum type");

        if (isDeclared(name))
            return;
        markDeclared(name);

        putLine("---@enum " ~ name);
        putLine(name ~ " = {");
        static foreach (member; __traits(allMembers, E))
        {{
            static if (isLuaExportedMember!(E, member))
                putLine("    " ~ luaMemberName!(E, member) ~ " = "
                        ~ enumValueLiteral!(E, member)() ~ ",");
        }}
        putLine("}");
        putBlank();
    }

    /// Add a module function table.
    void addModule(alias Module)(string name = luaNameOf!Module)
    {
        if (isDeclared(name))
            return;
        markDeclared(name);

        putLine("---@class " ~ name);
        putLine("local " ~ name ~ " = {}");
        putBlank();

        static foreach (member; __traits(allMembers, Module))
        {{
            static if (moduleMemberPublic!(Module, member)
                       && moduleMemberBindable!(Module, member))
                putFunctionSet!(Module, member)(name,
                                                luaMemberName!(Module, member));
        }}
    }

    /// Add a global value with a type annotation. `Symbol` may be a type or a
    /// variable.
    void addValue(alias Symbol)(string name,
                                string luaType = luaStubType!(symbolValueType!Symbol))
    {
        putLine("---@type " ~ luaType);
        putLine(name ~ " = nil");
        putBlank();
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
string luaStubs(Symbols...)()
{
    LuaStubBuilder builder;
    static foreach (Symbol; Symbols)
        builder.addSymbol!Symbol();
    return builder.toString();
}
