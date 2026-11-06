/// Test fixture for module-level `@LuaExport` and automatic module binding.
///
/// This module is only imported from the unittest build, so it is not part of
/// the normal library.
@LuaExport("renamedFixture")
module lunarbind.exportfixture;

import lunarbind.export_ : LuaExport;

@LuaExport("fixtureAdd")
int fixtureSum(int a, int b)
{
    return a + b;
}

@LuaExport(skip: true)
int fixtureHidden()
{
    return 7;
}

@LuaExport("fixtureChoice")
string fixturePick(int value)
{
    return "int";
}

string fixturePick(string value)
{
    return "string:" ~ value;
}

int fixturePlain(int value)
{
    return value + 1;
}

struct FixturePoint
{
    int x;
    int y;
}

FixturePoint fixtureOrigin()
{
    return FixturePoint(0, 0);
}

FixturePoint fixtureShift(FixturePoint point, int dx, int dy)
{
    return FixturePoint(point.x + dx, point.y + dy);
}
