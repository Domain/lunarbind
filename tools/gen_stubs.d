/// Example EmmyLua stub generator for the annotated fixture in
/// `samples/stub_fixture.d`.
///
/// Copy this file into your project and replace the fixture import and symbol
/// list with the modules, classes and functions that your bindings register.
/// Run it from the same build that registers the bindings, then point LuaLS at
/// the generated file via `workspace.library` (see README, "Editor setup").
///
/// The test scripts build this tool against the first Lua profile, write
/// `.lua/stubs/lunarbind.lua`, and validate the result so the generator cannot
/// drift from the public stub API.
module gen_stubs;

import lunarbind;
import samples.stub_fixture;

import std.algorithm.searching : startsWith;
import std.file : exists, mkdirRecurse, write;
import std.path : dirName;
import std.stdio : stderr, writeln;

int main(string[] args)
{
    string output = "types/lunarbind.lua";

    for (size_t i = 1; i < args.length; ++i)
    {
        auto arg = args[i];
        if (arg == "-h" || arg == "--help")
        {
            writeln("usage: gen_stubs [--out FILE]");
            writeln();
            writeln("Writes EmmyLua declarations for samples/stub_fixture.d.");
            return 0;
        }
        else if (arg == "-o" || arg == "--out")
        {
            if (i + 1 >= args.length)
            {
                stderr.writeln("gen_stubs: missing value for ", arg);
                return 2;
            }
            output = args[++i];
        }
        else if (arg.startsWith("--out="))
            output = arg["--out=".length .. $];
        else if (arg.startsWith("-o="))
            output = arg["-o=".length .. $];
        else
        {
            stderr.writeln("gen_stubs: unknown argument: ", arg);
            stderr.writeln("usage: gen_stubs [--out FILE]");
            return 2;
        }
    }

    // Packed has a custom registerCodec representation in the sample, so its
    // stub type is a plain table and no struct class is declared for it.
    auto text = luaStubs!(World, Status, add)([typeid(Packed): "table"]);

    auto dir = dirName(output);
    if (dir.length && dir != "." && !exists(dir))
        mkdirRecurse(dir);

    try
        write(output, text);
    catch (Exception e)
    {
        stderr.writeln("gen_stubs: cannot write ", output, ": ", e.msg);
        return 1;
    }

    writeln("wrote ", output);
    return 0;
}
