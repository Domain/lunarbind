/// Deterministic randomized stress tests for the marshalling and binding
/// layers.
///
/// The seed is fixed so failures reproduce exactly, and the iteration count is
/// small enough to keep the normal unittest matrix fast. Every supported Lua
/// version runs the same sequence.
module lunarbind.fuzz;

import lunarbind;

import std.random : Xorshift, uniform;

private class FuzzBox
{
    int value;

    this(int value)
    {
        this.value = value;
    }

    int add(int delta)
    {
        value += delta;
        return value;
    }
}

private struct FuzzPoint
{
    int x;
    int y;
}

unittest
{
    enum iterations = 500;

    auto rng = Xorshift(0x5EED_2026);
    auto L = LuaState.open();

    LuaClass!FuzzBox.registerClass(L, "FuzzBox");
    auto box = new FuzzBox(0);
    LuaClass!FuzzBox.setGlobal(L, "fuzz_box", box);

    auto add = L.loadString("return function(a, b) return a + b end")
        .call!LuaFunction();

    foreach (i; 0 .. iterations)
    {
        switch (uniform(0, 9, rng))
        {
            case 0:
            {
                auto value = uniform(-1_000_000, 1_000_000, rng);
                L.setGlobal("fuzz_value", value);
                assert(L.getGlobal!int("fuzz_value") == value);
                break;
            }
            case 1:
            {
                auto value = uniform(0.0, 1.0, rng);
                L.setGlobal("fuzz_value", value);
                assert(L.getGlobal!double("fuzz_value") == value);
                break;
            }
            case 2:
            {
                auto value = uniform(0, 2, rng) == 0;
                L.setGlobal("fuzz_value", value);
                assert(L.getGlobal!bool("fuzz_value") == value);
                break;
            }
            case 3:
            {
                auto length = uniform(0, 32, rng);
                char[] value;
                foreach (_; 0 .. length)
                    value ~= cast(char) uniform('a', 'z' + 1, rng);
                L.setGlobal("fuzz_value", value.idup);
                assert(L.getGlobal!string("fuzz_value") == value);
                break;
            }
            case 4:
            {
                auto length = uniform(0, 16, rng);
                auto value = new int[length];
                foreach (ref item; value)
                    item = uniform(-1_000, 1_000, rng);
                L.setGlobal("fuzz_value", value);
                assert(L.getGlobal!(int[])("fuzz_value") == value);
                break;
            }
            case 5:
            {
                auto table = LuaTable.create(L);
                auto count = uniform(0, 8, rng);
                int[int] expected;
                foreach (j; 0 .. count)
                {
                    auto value = uniform(-1_000, 1_000, rng);
                    table.set(j + 1, value);
                    expected[j + 1] = value;
                }
                L.setGlobal("fuzz_table", table);
                auto back = L.getGlobal!LuaTable("fuzz_table");
                assert(back.length == count);
                foreach (key, value; expected)
                    assert(back.get!int(key) == value);
                break;
            }
            case 6:
            {
                auto a = uniform(-1_000, 1_000, rng);
                auto b = uniform(-1_000, 1_000, rng);
                assert(add.call!int(a, b) == a + b);
                break;
            }
            case 7:
            {
                auto delta = uniform(-100, 100, rng);
                auto before = box.value;
                L.setGlobal("fuzz_delta", delta);
                L.doString("fuzz_box:add(fuzz_delta)");
                assert(box.value == before + delta);
                break;
            }
            case 8:
            {
                auto point = FuzzPoint(uniform(-100, 100, rng),
                                       uniform(-100, 100, rng));
                LuaStruct!FuzzPoint.setGlobal(L, "fuzz_point", point);
                L.doString("fuzz_point.x = fuzz_point.x + 1");
                auto back = LuaStruct!FuzzPoint.getGlobal(L, "fuzz_point");
                assert(back.x == point.x + 1);
                assert(back.y == point.y);
                break;
            }
            default:
                assert(0, "unreachable fuzz case");
        }

        // Every operation must leave the Lua stack balanced.
        assert(L.top() == 0);

        if (i % 64 == 0)
            L.doString("collectgarbage('collect'); collectgarbage('collect')");
    }
}
