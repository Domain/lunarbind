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
        assert(counter.get() == 15)
    `);
    assert(counter.value == 15);
}

