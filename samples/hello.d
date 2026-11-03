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
}

int greeter(string name)
{
    writeln("hello, ", name);
    return 1;
}

void main()
{
    auto L = LuaState.open();

    registerFunction!greeter(L, "greet");
    L.doString(`greet("world")`);

    auto counter = new Counter(10);
    LuaClass!Counter.registerClass(L);
    LuaClass!Counter.setGlobal(L, "counter", counter);
    L.doString(`
        counter:add(5)
        assert(counter:get() == 15)
    `);
    assert(counter.value == 15);

    LuaClass!Counter.registerConstructor(L, "Counter");
    L.doString(`
        local made = Counter(2)
        made:add(3)
        assert(made:get() == 5)
    `);

    auto vec = Vec2(1.5, 2.5);
    LuaStruct!Vec2.setGlobal(L, "vec", vec);
    L.doString(`
        vec.x = 2.5
        vec:scale(2)
        assert(vec.x == 5 and vec.y == 5)
    `);
    assert(vec.x == 1.5); // Lua mutated only the boxed copy
}

