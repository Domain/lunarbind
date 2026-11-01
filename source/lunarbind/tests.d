/// Compile-time + runtime smoke test.  The runtime checks require a Lua
/// library; `dub test --config=lua54` runs them in CI.
module lunarbind.tests;

import lunarbind;

class Player
{
    int hp;
    string name;

    this(int hp, string name)
    {
        this.hp = hp;
        this.name = name;
    }

    void damage(int amount)
    {
        hp -= amount;
    }

    int health() const
    {
        return hp;
    }
}

int asInt(LuaValue v)
{
    return v.kind == LuaType.integer ? cast(int) v.integerValue : cast(int) v.numberValue;
}

int add(int a, int b) { return a + b; }
int sub(int a, int b) { return a - b; }

unittest
{
    auto L = LuaState.open();

    // scalars, strings, globals
    L.setGlobal("answer", 42);
    assert(L.getGlobal!int("answer") == 42);
    L.setGlobal("greeting", "hello");
    assert(L.getGlobal!string("greeting") == "hello");

    // tables
    auto g = L.globals();
    g["name"] = "lunarbind";
    assert(g.get!string("name") == "lunarbind");
    bool found;
    assert(g.tryGet!int("missing", found) == 0 && !found);

    auto values = L.eval("return { 1, 2, 3 }");
    assert(values.length == 1);
    auto tableValue = values[0];
    auto table = tableValue.ref_.asTable();
    assert(table.length() == 3);
    assert(table.get!int(2) == 2);

    int sum;
    foreach (i, v; table)
        sum += asInt(v);
    assert(sum == 6);

    // Lua functions from D
    auto f = L.loadString("return 40 + 2");
    assert(f.call!int() == 42);

    auto mulValue = L.loadString("return function(a, b) return a * b end").call!LuaValue();
    L.setGlobal("mul", mulValue);
    auto mul = L.getGlobal!LuaFunction("mul");
    assert(mul.call!int(6, 7) == 42);

    auto bound = mul.bind!(int, int, int)();
    assert(bound(2, 3) == 6);

    // D functions from Lua: plain function
    registerFunction!add(L, "add");
    assert(asInt(L.eval("return add(20, 22)")[0]) == 42);

    // compile-time lambda
    registerFunction!((int x) { return x + 1; })(L, "inc");
    assert(asInt(L.eval("return inc(41)")[0]) == 42);

    // library
    registerLibrary!("add", add, "sub", sub)(L, "mathx");
    assert(asInt(L.eval("return mathx.add(10, 32)")[0]) == 42);
    assert(asInt(L.eval("return mathx.sub(50, 8)")[0]) == 42);

    // runtime delegate with boxed closure
    alias BinOp = int delegate(int, int);
    BinOp mulDelegate = (int a, int b) => a * b;
    registerDelegate(L, "mul2", mulDelegate);
    assert(asInt(L.eval("return mul2(6, 7)")[0]) == 42);

    // D class <-> Lua userdata
    auto player = new Player(100, "bob");
    LuaClass!Player.registerClass(L);
    LuaClass!Player.setGlobal(L, "player", player);

    auto result = L.eval("
        player.hp = player.hp - 10
        player:damage(5)
        return player:health(), player.name
    ");
    assert(asInt(result[0]) == 85);
    assert(result[1].stringValue == "bob");
    assert(player.hp == 85);

    auto same = LuaClass!Player.getGlobal(L, "player");
    auto playerValue = L.getGlobal!LuaValue("player");
    playerValue.push(L);
    assert(LuaClass!Player.isInstance(L, -1));
    L.pop(1);

    auto multi = L.loadString("return 1, 2, 3").call!(LuaValue[])();
    assert(multi.length == 3);
    assert(same is player);

    // errors carry a LuaException
    bool caught;
    try
        L.eval("error('boom')");
    catch (LuaException e)
        caught = true;
    assert(caught);

    // typed conversions
    L.setGlobal("ints", [1, 2, 3]);
    assert(L.getGlobal!(int[])("ints") == [1, 2, 3]);
    int[string] aa = ["a": 1, "b": 2];
    L.setGlobal("aa", aa);
    auto roundTrip = L.getGlobal!(int[string])("aa");
    assert(roundTrip["a"] == 1 && roundTrip["b"] == 2);
}






