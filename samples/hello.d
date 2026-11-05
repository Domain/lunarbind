module hello;

import lunarbind;
import std.stdio : writeln;

class Counter
{
    int value;

    this(int value)
    {
        this.value = value;
    }

    void add(int n)
    {
        value += n;
    }

    int get() const
    {
        return value;
    }

    static int schemaVersion()
    {
        return 2;
    }
}

struct Vec2
{
    double x;
    double y;

    void scale(double factor)
    {
        x *= factor;
        y *= factor;
    }

    static Vec2 origin()
    {
        return Vec2(0, 0);
    }
}

int greeter(string name = "world")
{
    writeln("hello, ", name);
    return 1;
}

int sum(int[] values...)
{
    int total;
    foreach (value; values)
        total += value;
    return total;
}

void main()
{
    auto L = LuaState.open();

    toLua!greeter(L, "greet");
    toLua!sum(L);
    L.doString(`
        greet("world")
        greet()
        assert(sum(1, 2, 3) == 6)
    `);

    auto counter = new Counter(10);
    // One call each: class table (constructor + static/instance methods) and
    // the instance global. Default names come from the D identifiers.
    toLua!Counter(L);
    toLua!counter(L);
    L.doString(`
        counter:add(5)
        assert(counter:get() == 15)
        assert(Counter.schemaVersion() == 2)
        assert(Counter.get(counter) == 15)
    `);
    assert(counter.value == 15);

    L.doString(`
        local made = Counter(2)
        made:add(3)
        assert(made:get() == 5)
    `);

    auto vec = Vec2(1.5, 2.5);
    toLua!Vec2(L); // struct type table: public static methods only
    toLua!vec(L);
    L.doString(`
        local origin = Vec2.origin()
        assert(origin.x == 0 and origin.y == 0)

        vec.x = 2.5
        vec:scale(2)
        assert(vec.x == 5 and vec.y == 5)
    `);
    assert(vec.x == 1.5); // Lua mutated only the boxed copy
}

