/// Coverage-guided fuzz target for lunarbind.
///
/// The target turns an arbitrary byte slice into a short sequence of
/// conversion, table, function, object and coroutine operations. Every input
/// runs against a fresh `LuaState`, so a crash cannot depend on state left by
/// an earlier input.
///
/// Build and run it with `tools/fuzz.sh`. The `ldc.libfuzzer` mixin supplies
/// the `LLVMFuzzerTestOneInput` entry point and the D runtime bootstrap; the
/// script links LDC's coverage instrumentation against the matching LLVM
/// compiler-rt fuzzer runtime.
module fuzz_target;

import ldc.libfuzzer;
import lunarbind;

import std.conv : to;

mixin DefineTestOneInput!fuzzOneInput;

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

private struct FuzzNamed
{
    string name;
    int value;
}

private enum FuzzColor
{
    red,
    green,
    blue,
}

private struct Reader
{
    const(ubyte)[] data;
    size_t pos;

    bool empty() const @nogc nothrow
    {
        return pos >= data.length;
    }

    ubyte nextByte() @nogc nothrow
    {
        return empty ? ubyte(0) : data[pos++];
    }

    ulong u64() @nogc nothrow
    {
        ulong value;
        foreach (_; 0 .. 8)
            value = (value << 8) | nextByte();
        return value;
    }

    int range(int lo, int hi) @nogc nothrow
    {
        return lo + cast(int)(u64() % cast(ulong)(hi - lo));
    }

    string text(size_t maxLength = 24)
    {
        auto length = nextByte() % (maxLength + 1);
        auto value = new char[length];
        foreach (ref c; value)
            c = cast(char)(' ' + nextByte() % 95);
        return value.idup;
    }
}

private int fuzzOneInput(in ubyte[] data)
{
    auto reader = Reader(data);

    auto L = LuaState.open();
    scope(exit)
    {
        // `L.eval`, `L.doString` and `LuaFunction.call` return GC-managed
        // values. A value that wraps a table, function or thread owns a
        // registry reference that is released only when the collector reclaims
        // it, and an inert stack slot can keep the last one alive past a
        // collection. The reference count is therefore not a reliable leak
        // signal here: collect first, and when a value is still alive let the
        // state's own destructor close it once that last reference is gone.
        import core.memory : GC;
        if (L.referenceCount() > 1)
        {
            GC.collect();
            GC.collect();
        }
        if (L.referenceCount() == 1)
            L.close();
    }

    runOperations(L, reader);
    return 0;
}

/// Drive one input through the binding. Every handle-owning local lives here so
/// that its destructor releases its registry reference when this function
/// returns, before the caller closes the state.
private void runOperations(LuaState L, ref Reader reader)
{
    LuaClass!FuzzBox.registerClass(L, "FuzzBox");
    auto box = new FuzzBox(reader.range(-1000, 1000));
    LuaClass!FuzzBox.setGlobal(L, "fuzz_box", box);

    LuaStruct!FuzzPoint.setGlobal(L, "fuzz_point",
        FuzzPoint(reader.range(-100, 100), reader.range(-100, 100)));
    LuaStruct!FuzzNamed.setGlobal(L, "fuzz_named",
        FuzzNamed(reader.text(12), reader.range(-100, 100)));

    auto add = L.loadString("return function(a, b) return a + b end")
        .call!LuaFunction();
    auto builder = LuaModule.create(L);

    foreach (_; 0 .. 64)
    {
        if (reader.empty)
            break;

        try
        {
            switch (reader.nextByte() % 14)
            {
                case 0:
                {
                    switch (reader.nextByte() % 5)
                    {
                        case 0:
                        {
                            auto value = reader.range(-1_000_000, 1_000_000);
                            L.setGlobal("fuzz_value", value);
                            assert(L.getGlobal!int("fuzz_value") == value);
                            break;
                        }
                        case 1:
                        {
                            // Stay below 2^53 so double-based runtimes
                            // (Lua 5.1/5.2, LuaJIT) round-trip exactly.
                            auto value = reader.u64() & ((1UL << 53) - 1);
                            L.setGlobal("fuzz_value", value);
                            assert(L.getGlobal!ulong("fuzz_value") == value);
                            break;
                        }
                        case 2:
                        {
                            auto value = cast(double) cast(long) reader.u64() /
                                1000.0;
                            L.setGlobal("fuzz_value", value);
                            assert(L.getGlobal!double("fuzz_value") == value);
                            break;
                        }
                        case 3:
                        {
                            auto value = reader.text();
                            L.setGlobal("fuzz_value", value);
                            assert(L.getGlobal!string("fuzz_value") == value);
                            break;
                        }
                        default:
                        {
                            auto value = (reader.nextByte() & 1) != 0;
                            L.setGlobal("fuzz_value", value);
                            assert(L.getGlobal!bool("fuzz_value") == value);
                            break;
                        }
                    }
                    break;
                }
                case 1:
                {
                    auto values = new int[reader.nextByte() % 8];
                    foreach (ref value; values)
                        value = reader.range(-1000, 1000);
                    L.setGlobal("fuzz_array", values);
                    assert(L.getGlobal!(int[])("fuzz_array") == values);
                    break;
                }
                case 2:
                {
                    int[string] expected;
                    foreach (j; 0 .. reader.nextByte() % 6)
                        expected[reader.text(8)] = reader.range(-1000, 1000);
                    L.setGlobal("fuzz_aa", expected);
                    assert(L.getGlobal!(int[string])("fuzz_aa") == expected);
                    break;
                }
                case 3:
                {
                    auto table = LuaTable.create(L, reader.nextByte() % 8);
                    auto count = reader.nextByte() % 8;
                    foreach (i; 0 .. count)
                    {
                        if (reader.nextByte() & 1)
                            table.set(reader.range(-4, 4),
                                      reader.range(-1000, 1000));
                        else
                            table.set(reader.text(6),
                                      reader.range(-1000, 1000));
                    }

                    int visited;
                    table.opApply((LuaValue key, LuaValue value) {
                        ++visited;
                        return 0;
                    });
                    assert(visited <= count);
                    break;
                }
                case 4:
                {
                    auto name = "g_" ~ reader.text(8);
                    auto value = reader.range(-1000, 1000);
                    L.setGlobal(name, value);
                    assert(L.getGlobal!int(name) == value);

                    bool threw;
                    try
                        L.getGlobal!(int[])(name);
                    catch (LuaException e)
                        threw = true;
                    assert(threw);
                    break;
                }
                case 5:
                {
                    auto left = reader.range(-1000, 1000);
                    auto right = reader.range(-1000, 1000);
                    switch (reader.nextByte() % 4)
                    {
                        case 0:
                            L.eval("return " ~ to!string(left));
                            break;
                        case 1:
                            L.eval("return " ~ to!string(left) ~ " + " ~
                                   to!string(right));
                            break;
                        case 2:
                            L.doString("error('fuzz error')");
                            break;
                        default:
                            L.eval("local t = {}; for i = 1, " ~
                                   to!string(reader.nextByte() % 16) ~
                                   " do t[i] = i end; return t");
                            break;
                    }
                    break;
                }
                case 6:
                {
                    auto left = reader.range(-1000, 1000);
                    auto right = reader.range(-1000, 1000);
                    assert(add.call!int(left, right) == left + right);

                    bool threw;
                    try
                        add.call!int(left);
                    catch (LuaException e)
                        threw = true;
                    assert(threw);
                    break;
                }
                case 7:
                {
                    auto delta = reader.range(-100, 100);
                    auto before = box.value;
                    L.setGlobal("fuzz_delta", delta);
                    L.doString("fuzz_box:add(fuzz_delta)");
                    assert(box.value == before + delta);
                    break;
                }
                case 8:
                {
                    auto point = FuzzPoint(reader.range(-100, 100),
                                           reader.range(-100, 100));
                    LuaStruct!FuzzPoint.setGlobal(L, "fuzz_point", point);
                    L.doString("fuzz_point.x = fuzz_point.x + 1");
                    auto back = LuaStruct!FuzzPoint.getGlobal(L,
                                                              "fuzz_point");
                    assert(back.x == point.x + 1);
                    assert(back.y == point.y);
                    break;
                }
                case 9:
                {
                    auto named = FuzzNamed(reader.text(12),
                                           reader.range(-100, 100));
                    LuaStruct!FuzzNamed.setGlobal(L, "fuzz_named", named);
                    auto back = LuaStruct!FuzzNamed.getGlobal(L, "fuzz_named");
                    assert(back.name == named.name);
                    assert(back.value == named.value);
                    break;
                }
                case 10:
                {
                    auto value = reader.range(-1000, 1000);
                    builder.set("value", value);
                    assert(builder.table().get!int("value") == value);

                    auto colors = enumTable!FuzzColor(L);
                    assert(colors.get!int("green") == FuzzColor.green);
                    break;
                }
                case 11:
                {
                    auto weak = LuaTable.createWeak(L,
                        cast(LuaWeakness) (reader.nextByte() % 4));
                    weak.set("key", reader.range(-1000, 1000));
                    weak.set(1, reader.text(8));
                    assert(weak.lengthOf() <= 1);
                    break;
                }
                case 12:
                {
                    auto thread = LuaThread.create(L.loadString(
                        "return function(x) coroutine.yield(x + 1); " ~
                        "return x + 2 end").call!LuaFunction());
                    auto first = thread.resume(reader.range(-100, 100));
                    assert(first.length == 1);
                    assert(thread.isSuspended());
                    auto last = thread.resume();
                    assert(last.length == 1);
                    assert(!thread.isSuspended());
                    break;
                }
                default:
                {
                    auto value = LuaValue.fromInteger(reader.range(-1000, 1000));
                    L.setGlobal("fuzz_dynamic", value);
                    auto back = L.getGlobal!LuaValue("fuzz_dynamic");
                    assert(back.kind == LuaType.integer ||
                           back.kind == LuaType.number);
                    break;
                }
            }
        }
        catch (LuaException e)
        {
            // Arbitrary input regularly produces conversion and Lua errors.
            // They must leave the stack balanced; the check below proves it.
        }

        assert(L.top() == 0, "operation left the Lua stack unbalanced");
    }
}
