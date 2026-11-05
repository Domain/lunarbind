/// UDA-driven Lua export names and member filtering.
///
/// `@LuaExport` controls how a symbol or aggregate member is exposed:
///
/// ```d
/// @LuaExport("add") int addNumbers(int a, int b);
///
/// class Player
/// {
///     @LuaExport("hp") int health;
///     @LuaExport(skip: true) int internalState;
///     @LuaExport("damage") void takeDamage(int amount);
/// }
/// ```
///
/// An explicit name overrides the default identifier, and also exposes names
/// that the default filter hides (leading underscore, `toString`, ...).
/// `skip: true` removes a member from automatic tables; an explicit `toLua`
/// call still binds it.
module lunarbind.export_;

/// Attribute for overriding a Lua name or hiding a member from automatic
/// binding.
///
/// - `@LuaExport("name")` sets the Lua name.
/// - `@LuaExport(skip: true)` hides the member from `registerModule`,
///   `LuaClass!T.bind` and `LuaStruct!S.bind`.
/// - `@LuaExport` without arguments is accepted and behaves like the default.
struct LuaExport
{
    /// Lua name. Empty means "use the D identifier".
    string name;
    /// Hide this member from automatic tables.
    bool skip;
}

// ---------------------------------------------------------------------------
// Attribute lookup
// ---------------------------------------------------------------------------

private template findLuaExport(Attrs...)
{
    static if (Attrs.length == 0)
        enum LuaExport findLuaExport = LuaExport.init;
    else static if (__traits(compiles, { void probe(Attrs[0] __value); }))
        enum LuaExport findLuaExport = LuaExport.init; // bare UDA type
    else static if (is(typeof(Attrs[0]) == LuaExport))
        enum LuaExport findLuaExport = Attrs[0];
    else
        enum LuaExport findLuaExport = findLuaExport!(Attrs[1 .. $]);
}

private template directLuaExport(alias Symbol)
{
    static if (__traits(compiles, __traits(getAttributes, Symbol)))
        enum LuaExport directLuaExport =
            findLuaExport!(__traits(getAttributes, Symbol));
    else
        enum LuaExport directLuaExport = LuaExport.init;
}

private template isTemplateMember(alias Parent, string member)
{
    static if (__traits(compiles,
                        __traits(isTemplate,
                                 __traits(getMember, Parent, member))))
        enum isTemplateMember =
            __traits(isTemplate, __traits(getMember, Parent, member));
    else
        enum isTemplateMember = false;
}

private template directLuaExportMember(alias Parent, string member)
{
    static if (memberOverloadCount!(Parent, member) > 0)
        enum LuaExport directLuaExportMember = LuaExport.init;
    else static if (isTemplateMember!(Parent, member))
        enum LuaExport directLuaExportMember = LuaExport.init;
    else static if (__traits(compiles,
                             __traits(getAttributes,
                                      __traits(getMember, Parent, member))))
        enum LuaExport directLuaExportMember =
            findLuaExport!(__traits(getAttributes,
                                    __traits(getMember, Parent, member)));
    else
        enum LuaExport directLuaExportMember = LuaExport.init;
}

private template overloadCount(alias Symbol)
{
    static if (__traits(compiles, __traits(parent, Symbol))
               && __traits(compiles,
                           __traits(getOverloads,
                                    __traits(parent, Symbol),
                                    __traits(identifier, Symbol))))
        enum overloadCount =
            __traits(getOverloads,
                     __traits(parent, Symbol),
                     __traits(identifier, Symbol)).length;
    else
        enum overloadCount = 0;
}

private template memberOverloadCount(alias Parent, string member)
{
    static if (__traits(compiles, __traits(getOverloads, Parent, member)))
        enum memberOverloadCount = __traits(getOverloads, Parent, member).length;
    else
        enum memberOverloadCount = 0;
}

private template findLuaExportInOverloads(alias Symbol, size_t i = 0)
{
    static if (overloadCount!Symbol > 0)
    {
        alias Parent = __traits(parent, Symbol);
        enum name = __traits(identifier, Symbol);
        alias overloads = __traits(getOverloads, Parent, name);
        static if (i < overloads.length)
        {
            static if (__traits(compiles, __traits(getAttributes, overloads[i])))
                enum LuaExport found =
                    findLuaExport!(__traits(getAttributes, overloads[i]));
            else
                enum LuaExport found = LuaExport.init;

            static if (found.name.length || found.skip)
                enum LuaExport findLuaExportInOverloads = found;
            else
                enum LuaExport findLuaExportInOverloads =
                    findLuaExportInOverloads!(Symbol, i + 1);
        }
        else
            enum LuaExport findLuaExportInOverloads = LuaExport.init;
    }
    else
        enum LuaExport findLuaExportInOverloads = LuaExport.init;
}

private template findLuaExportInMemberOverloads(alias Parent, string member,
                                                 size_t i = 0)
{
    static if (memberOverloadCount!(Parent, member) > 0)
    {
        alias overloads = __traits(getOverloads, Parent, member);
        static if (i < overloads.length)
        {
            static if (__traits(compiles, __traits(getAttributes, overloads[i])))
                enum LuaExport found =
                    findLuaExport!(__traits(getAttributes, overloads[i]));
            else
                enum LuaExport found = LuaExport.init;

            static if (found.name.length || found.skip)
                enum LuaExport findLuaExportInMemberOverloads = found;
            else
                enum LuaExport findLuaExportInMemberOverloads =
                    findLuaExportInMemberOverloads!(Parent, member, i + 1);
        }
        else
            enum LuaExport findLuaExportInMemberOverloads = LuaExport.init;
    }
    else
        enum LuaExport findLuaExportInMemberOverloads = LuaExport.init;
}

private template luaExportOfType(T)
{
    static if (__traits(compiles, __traits(getAttributes, T)))
        enum LuaExport luaExportOfType =
            findLuaExport!(__traits(getAttributes, T));
    else
        enum LuaExport luaExportOfType = LuaExport.init;
}

/// The `LuaExport` attribute attached to `Symbol`, or a default value.
package template luaExportOf(alias Symbol)
{
    static if (overloadCount!Symbol > 1)
        enum LuaExport luaExportOf = findLuaExportInOverloads!Symbol;
    else
        enum LuaExport luaExportOf = directLuaExport!Symbol;
}

/// The `LuaExport` attribute attached to `Parent.member`, or a default value.
package template luaExportOfMember(alias Parent, string member)
{
    static if (memberOverloadCount!(Parent, member) > 0)
        enum LuaExport luaExportOfMember =
            findLuaExportInMemberOverloads!(Parent, member);
    else
        enum LuaExport luaExportOfMember = directLuaExportMember!(Parent, member);
}

/// Lua name for a symbol, honoring `@LuaExport("name")`.
package template luaNameOf(alias Symbol)
{
    enum string luaNameOf = luaExportOf!Symbol.name.length
        ? luaExportOf!Symbol.name
        : __traits(identifier, Symbol);
}

/// Lua name for a type parameter, honoring `@LuaExport("name")`.
package template luaTypeName(T)
{
    enum string luaTypeName = luaExportOfType!T.name.length
        ? luaExportOfType!T.name
        : T.stringof;
}

/// Lua name for `Parent.member`, honoring `@LuaExport("name")`.
package template luaMemberName(alias Parent, string member)
{
    enum string luaMemberName = luaExportOfMember!(Parent, member).name.length
        ? luaExportOfMember!(Parent, member).name
        : member;
}

/// Default filter for names that are automatically exposed to Lua.
///
/// Names starting with `_` and D/runtime implementation members are hidden
/// unless `@LuaExport("name")` gives them an explicit name.
package template isExposedName(string member)
{
    enum isExposedName =
        member.length > 0
        && member[0] != '_'
        && member != "toString"
        && member != "toHash"
        && member != "opEquals"
        && member != "opCmp"
        && member != "classinfo"
        && member != "mangleof"
        && member != "sizeof"
        && member != "alignof"
        && member != "init"
        && member != "factory";
}

/// Whether automatic binding should expose `Parent.member`.
package template isLuaExportedMember(alias Parent, string member)
{
    enum bool isLuaExportedMember =
        !luaExportOfMember!(Parent, member).skip
        && (luaExportOfMember!(Parent, member).name.length > 0
            || isExposedName!member);
}
