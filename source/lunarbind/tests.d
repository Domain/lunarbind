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

class Stats
{
    private int _hp;

    this(int hp)
    {
        _hp = hp;
    }

    @property int hp() const
    {
        return _hp;
    }

    @property void hp(int value)
    {
        _hp = value;
    }

    @property int doubled() const
    {
        return _hp * 2;
    }
}

class Node
{
    int value;
    Node next;

    this(int value)
    {
        this.value = value;
    }

    Node child()
    {
        return next;
    }

    void link(Node other)
    {
        next = other;
    }
}

class Animal
{
    string name;

    this(string name)
    {
        this.name = name;
    }

    string speak()
    {
        return "...";
    }
}

class Dog : Animal
{
    this(string name)
    {
        super(name);
    }

    override string speak()
    {
        return "woof";
    }
}

int asInt(LuaValue v)
{
    return v.kind == LuaType.integer ? cast(int) v.integerValue : cast(int) v.numberValue;
}

int add(int a, int b) { return a + b; }
int sub(int a, int b) { return a - b; }

// Filled from a Lua callback; must stay valid after the callback returns.
LuaTable capturedTable;
void captureTable(LuaTable table) { capturedTable = table; }

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
    assert(same is player);

    // class values now flow through pushTo/popFrom
    g["otherPlayer"] = player;
    auto other = g.get!Player("otherPlayer");
    assert(other is player);

    // Pushing the same D object again reuses the existing userdata, so the two
    // globals are rawequal (not merely __eq-equal).
    L.setGlobal("player2", player);
    auto sameUserdata = L.eval("return rawequal(player, player2)")[0];
    assert(sameUserdata.kind == LuaType.boolean && sameUserdata.booleanValue);
    auto equal = L.eval("return player == player2")[0];
    assert(equal.kind == LuaType.boolean && equal.booleanValue);

    auto playerValue = L.getGlobal!LuaValue("player");
    playerValue.push(L);
    assert(LuaClass!Player.isInstance(L, -1));
    L.pop(1);

    // @property getters and setters
    auto stats = new Stats(10);
    LuaClass!Stats.setGlobal(L, "stats", stats);
    auto statsResult = L.eval("
        stats.hp = stats.hp + 5
        return stats.hp, stats.doubled
    ");
    assert(asInt(statsResult[0]) == 15);
    assert(asInt(statsResult[1]) == 30);
    assert(stats.hp == 15);

    // Class-typed fields and method parameters/results flow through LuaClass.
    auto nodeA = new Node(1);
    auto nodeB = new Node(2);
    nodeA.next = nodeB;
    LuaClass!Node.setGlobal(L, "nodeA", nodeA);
    LuaClass!Node.setGlobal(L, "nodeB", nodeB);
    auto nodeResult = L.eval("
        assert(nodeA.next.value == 2)
        nodeA:link(nodeB)
        return nodeA:child().value
    ");
    assert(asInt(nodeResult[0]) == 2);
    L.doString("nodeA.next = nil");
    assert(nodeA.next is null);

    // Derived userdata can be viewed as a base class, but a base userdata is
    // not accepted as a derived class.
    auto dog = new Dog("rex");
    LuaClass!Dog.setGlobal(L, "dog", dog);
    auto animal = LuaClass!Animal.getGlobal(L, "dog");
    assert(animal is dog);

    auto dogValue = L.getGlobal!LuaValue("dog");
    dogValue.push(L);
    assert(LuaClass!Animal.isInstance(L, -1));
    assert(LuaClass!Dog.isInstance(L, -1));
    L.pop(1);

    L.setGlobal("animal", animal); // static type Animal: base metatable
    auto animalValue = L.getGlobal!LuaValue("animal");
    animalValue.push(L);
    assert(LuaClass!Animal.isInstance(L, -1));
    assert(!LuaClass!Dog.isInstance(L, -1));
    L.pop(1);

    auto sameView = L.eval("return dog == animal")[0];
    assert(sameView.kind == LuaType.boolean && sameView.booleanValue);
    auto speak = L.eval("return dog:speak(), animal:speak()");
    assert(speak[0].stringValue == "woof");
    assert(speak[1].stringValue == "woof");

    // a wrapper must share the owner's core
    auto wrapped = LuaState.wrap(L.handle);
    assert(wrapped.sharesState(L));
    assert(wrapped.getGlobal!int("answer") == 42);

    // a reference created inside a callback must outlive the callback
    registerFunction!captureTable(L, "captureTable");
    L.doString("captureTable({ value = 7 })");
    assert(capturedTable.get!int("value") == 7);
    capturedTable = LuaTable.init;

    auto multi = L.loadString("return 1, 2, 3").call!(LuaValue[])();
    assert(multi.length == 3);

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

    // refs must not leak into another state
    auto otherState = LuaState.open();
    bool crossStateRejected;
    try
        otherState.push(g);
    catch (LuaStateException)
        crossStateRejected = true;
    assert(crossStateRejected);

    // Roots are reference-counted across states: closing/dropping one state's
    // userdata must not unroot an object still visible in another state.
    {
        auto rooted = new Player(7, "rooted");
        auto s1 = LuaState.open();
        auto s2 = LuaState.open();

        LuaClass!Player.setGlobal(s1, "rooted", rooted);
        LuaClass!Player.setGlobal(s2, "rooted", rooted);
        assert(objectRootCountForTest(cast(void*) rooted) == 2);

        // Re-pushing in the same state reuses the userdata and adds no root.
        LuaClass!Player.push(s1, rooted);
        LuaClass!Player.push(s1, rooted);
        assert(lua_rawequal(s1.handle, -1, -2) != 0);
        s1.pop(2);
        assert(objectRootCountForTest(cast(void*) rooted) == 2);

        // Two full collections also cover versions that run finalizers in a
        // separate cycle.
        s1.doString("rooted = nil; collectgarbage('collect'); collectgarbage('collect')");
        assert(objectRootCountForTest(cast(void*) rooted) == 1);
        s2.doString("rooted = nil; collectgarbage('collect'); collectgarbage('collect')");
        assert(objectRootCountForTest(cast(void*) rooted) == 0);

        s1.close();
        s2.close();
    }

    // Closing a state finalizes its userdata and releases their roots.
    {
        auto closedObj = new Player(8, "closed");
        {
            auto s = LuaState.open();
            LuaClass!Player.setGlobal(s, "obj", closedObj);
            assert(objectRootCountForTest(cast(void*) closedObj) == 1);
        }
        assert(objectRootCountForTest(cast(void*) closedObj) == 0);
    }
}
