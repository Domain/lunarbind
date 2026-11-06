/// Micro-benchmarks for the marshalling and binding layers.
///
/// Build against one Lua profile with `tools/test-lua.ps1 -Bench` or
/// `tools/test-lua.sh --bench`. The numbers are intended for comparing
/// lunarbind versions and Lua runtimes, not as absolute performance claims.
module bench;

import lunarbind;

import std.datetime.stopwatch : AutoStart, StopWatch;
import std.stdio : writefln, writeln;

private class BenchBox
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

private struct BenchPoint
{
    int x;
    int y;
}

private int benchAdd(int a, int b)
{
    return a + b;
}

private long luaSum(long n)
{
    return n * (n + 3) / 2;
}

private double timePerOp(string name, long ops, void delegate() work)
{
    work(); // warm up

    long best = long.max;
    foreach (_; 0 .. 3)
    {
        auto watch = StopWatch(AutoStart.yes);
        work();
        watch.stop();
        auto elapsed = watch.peek.total!"nsecs";
        if (elapsed < best)
            best = elapsed;
    }

    auto ns = cast(double) best / ops;
    writefln("%-38s %12.1f", name, ns);
    return ns;
}

int main()
{
    enum luaOps = 1_000_000;
    enum constructOps = 100_000;
    enum dOps = 1_000_000;
    enum tableOps = 200_000;

    auto L = LuaState.open();
    writeln("lunarbind benchmark");
    writeln("runtime: ", L.getGlobal!string("_VERSION"));
    writeln();

    toLua!benchAdd(L, "bench_add");

    LuaClass!BenchBox.registerClass(L, "BenchBox");
    auto box = new BenchBox(0);
    LuaClass!BenchBox.setGlobal(L, "bench_box", box);

    auto point = BenchPoint(0, 0);
    LuaStruct!BenchPoint.setGlobal(L, "bench_point", point);

    L.doString(`
        local function add(a, b) return a + b end

        function bench_baseline(n)
            local s = 0
            for i = 1, n do s = s + add(i, 1) end
            return s
        end

        function bench_bound(n)
            local s = 0
            for i = 1, n do s = s + bench_add(i, 1) end
            return s
        end

        function bench_field_read(n)
            local s = 0
            for i = 1, n do s = s + bench_box.value end
            return s
        end

        function bench_field_write(n)
            for i = 1, n do bench_box.value = i end
        end

        function bench_method(n)
            for i = 1, n do bench_box:add(1) end
        end

        function bench_construct(n)
            local s = 0
            for i = 1, n do
                local o = BenchBox(i)
                s = s + o.value
            end
            return s
        end

        function bench_struct(n)
            for i = 1, n do bench_point.x = bench_point.x + 1 end
        end
    `);

    auto baseline = L.getGlobal!LuaFunction("bench_baseline");
    auto bound = L.getGlobal!LuaFunction("bench_bound");

    auto baselineNs = timePerOp("lua -> lua function (baseline)", luaOps, {
        assert(baseline.call!long(luaOps) == luaSum(luaOps));
    });
    auto boundNs = timePerOp("lua -> d function", luaOps, {
        assert(bound.call!long(luaOps) == luaSum(luaOps));
    });
    writefln("%-38s %12.1f", "  binding delta", boundNs - baselineNs);

    box.value = 1;
    auto fieldRead = L.getGlobal!LuaFunction("bench_field_read");
    timePerOp("lua -> d field read", luaOps, {
        assert(fieldRead.call!long(luaOps) == luaOps);
    });

    box.value = 0;
    auto fieldWrite = L.getGlobal!LuaFunction("bench_field_write");
    timePerOp("lua -> d field write", luaOps, {
        fieldWrite.call!void(luaOps);
        assert(box.value == luaOps);
    });

    box.value = 0;
    auto method = L.getGlobal!LuaFunction("bench_method");
    timePerOp("lua -> d method call", luaOps, {
        box.value = 0;
        method.call!void(luaOps);
        assert(box.value == luaOps);
    });

    auto construct = L.getGlobal!LuaFunction("bench_construct");
    timePerOp("lua -> d class construction", constructOps, {
        assert(construct.call!long(constructOps)
               == cast(long) constructOps * (constructOps + 1) / 2);
    });

    auto structWrite = L.getGlobal!LuaFunction("bench_struct");
    timePerOp("lua -> d struct field write", luaOps, {
        structWrite.call!void(luaOps);
        auto back = LuaStruct!BenchPoint.getGlobal(L, "bench_point");
        assert(back.x == luaOps && back.y == 0);
        back.x = 0;
        LuaStruct!BenchPoint.setGlobal(L, "bench_point", back);
    });

    long intSum;
    timePerOp("d push/get int", dOps, {
        long sum;
        foreach (i; 0 .. dOps)
        {
            L.push(i);
            sum += L.get!int(-1);
            L.pop();
        }
        intSum = sum;
    });
    assert(intSum == cast(long) dOps * (dOps - 1) / 2);

    auto text = "lunarbind benchmark";
    long textSum;
    timePerOp("d push/get string", dOps, {
        long sum;
        foreach (_; 0 .. dOps)
        {
            L.push(text);
            sum += L.get!string(-1).length;
            L.pop();
        }
        textSum = sum;
    });
    assert(textSum == cast(long) text.length * dOps);

    auto table = LuaTable.create(L);
    timePerOp("d table set int", tableOps, {
        foreach (i; 0 .. tableOps)
            table.set(i, i);
    });

    long tableSum;
    timePerOp("d table get int", tableOps, {
        long sum;
        foreach (i; 0 .. tableOps)
            sum += table.get!int(i);
        tableSum = sum;
    });
    assert(tableSum == cast(long) tableOps * (tableOps - 1) / 2);

    return 0;
}
