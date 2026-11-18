module stubs;

import lunarbind;
import samples.stub_fixture;
import std.stdio : writeln;

void main()
{
    // No Lua state is needed: stub generation only inspects D symbols.
    writeln(luaStubs!(World, Status, add)());

    // A custom codec representation overrides the generated type; the default
    // struct declaration is then omitted.
    LuaStubBuilder builder;
    builder.setType!Packed("table");
    builder.addClass!World();
    writeln(builder.toString());
}
