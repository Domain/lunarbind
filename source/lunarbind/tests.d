/// Compile-time + runtime smoke test.  The runtime checks require a Lua
/// library; `dub test --config=lua54` runs them in CI.
module lunarbind.tests;

import lunarbind;

import std.conv : to;
import std.typecons : Tuple, tuple;

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

    override string toString()
    {
        return "Player:" ~ name;
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

class DefaultConstructed
{
    int value = 7;
}

class Overloaded
{
    string kind;

    this(int value)
    {
        kind = "int";
    }

    this(string value)
    {
        kind = "string";
    }

    this(int a, int b)
    {
        kind = "pair";
    }

    string pick(int value)
    {
        return "int";
    }

    string pick(string value)
    {
        return "string";
    }

    string pick(int a, int b)
    {
        return "pair";
    }
}

class Bag
{
    int[] items;

    @property size_t length() const
    {
        return items.length;
    }
}

class Vec
{
    int x;

    this(int x)
    {
        this.x = x;
    }

    Vec opBinary(string op)(Vec other) const
        if (op == "+" || op == "-")
    {
        return new Vec(op == "+" ? x + other.x : x - other.x);
    }

    string opBinary(string op)(Vec other) const
        if (op == "~")
    {
        return "vec";
    }

    Vec opUnary(string op)() const
        if (op == "-")
    {
        return new Vec(-x);
    }

    int opCmp(Vec other) const
    {
        return x < other.x ? -1 : x > other.x ? 1 : 0;
    }
}

class Callable
{
    int base;

    this(int base)
    {
        this.base = base;
    }

    int opCall(int value)
    {
        return base + value;
    }
}

class Dict
{
    long[string] named;
    long[int] indexed;

    long opIndex(string key) const
    {
        auto p = key in named;
        return p is null ? -1 : *p;
    }

    void opIndexAssign(long value, string key)
    {
        named[key] = value;
    }

    long opIndex(int index) const
    {
        auto p = index in indexed;
        return p is null ? -1 : *p;
    }

    void opIndexAssign(long value, int index)
    {
        indexed[index] = value;
    }
}

struct Point
{
    int x;
    int y;

    int sum() const
    {
        return x + y;
    }

    int scaled(int factor = 1) const
    {
        return (x + y) * factor;
    }

    int plus(int[] extra...) const
    {
        int result = x + y;
        foreach (value; extra)
            result += value;
        return result;
    }

    void move(int dx, int dy)
    {
        x += dx;
        y += dy;
    }

    Point opBinary(string op)(Point other) const
        if (op == "+" || op == "-")
    {
        static if (op == "+")
            return Point(x + other.x, y + other.y);
        else
            return Point(x - other.x, y - other.y);
    }

    Point opUnary(string op)() const
        if (op == "-")
    {
        return Point(-x, -y);
    }

    int opCmp(Point other) const
    {
        return x < other.x ? -1 : x > other.x ? 1 : 0;
    }

    string toString() const
    {
        return "Point(" ~ to!string(x) ~ "," ~ to!string(y) ~ ")";
    }
}

class Geometry
{
    int sum(Point p) const
    {
        return p.x + p.y;
    }

    Point make(int x, int y)
    {
        return Point(x, y);
    }
}

class HasPoint
{
    Point point;
}

class Defaults
{
    int base;

    this(int base = 5)
    {
        this.base = base;
    }

    int total(int a, int b = 2, int c = 3) const
    {
        return base + a + b + c;
    }

    string tag(string prefix = "v", int n = 1) const
    {
        return prefix ~ to!string(n);
    }
}

class Splitter
{
    Tuple!(int, int) digits(int value) const
    {
        return tuple(value / 10, value % 10);
    }
}

class Variadic
{
    int total(int[] values...) const
    {
        int result;
        foreach (v; values)
            result += v;
        return result;
    }

    string join(string separator, string[] parts...) const
    {
        string result;
        foreach (i, part; parts)
        {
            if (i > 0)
                result ~= separator;
            result ~= part;
        }
        return result;
    }

    int offset(int base, int[] values...) const
    {
        int result = base;
        foreach (v; values)
            result += v;
        return result;
    }
}

int asInt(LuaValue v)
{
    return v.kind == LuaType.integer ? cast(int) v.integerValue : cast(int) v.numberValue;
}

int add(int a, int b) { return a + b; }
int sub(int a, int b) { return a - b; }

int addDefault(int a, int b = 10) { return a + b; }

int sumVariadic(int[] values...)
{
    int result;
    foreach (value; values)
        result += value;
    return result;
}

string joinVariadic(string separator, string[] parts...)
{
    string result;
    foreach (i, part; parts)
    {
        if (i > 0)
            result ~= separator;
        result ~= part;
    }
    return result;
}

Tuple!(int, string) describe(int value)
{
    return tuple(value * 2, "v" ~ to!string(value));
}

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

    // Weak tables drop entries when keys or values become unreachable.
    auto weakValues = LuaTable.createWeak(L, LuaWeakness.values);
    L.setGlobal("weakValues", weakValues);
    L.doString("
        local key = {}
        local function setValue()
            weakValues[key] = {}
        end
        setValue()
        weakValues[1] = 'kept'
        assert(getmetatable(weakValues).__mode == 'v')
        collectgarbage()
        collectgarbage()
        local count = 0
        for _ in pairs(weakValues) do count = count + 1 end
        assert(count == 1)
        assert(weakValues[1] == 'kept')
    ");

    auto weakKeys = LuaTable.createWeak(L, LuaWeakness.keys);
    L.setGlobal("weakKeys", weakKeys);
    L.doString("
        local function setKey()
            local key = {}
            weakKeys[key] = 'gone'
        end
        setKey()
        weakKeys[1] = 'kept'
        assert(getmetatable(weakKeys).__mode == 'k')
        collectgarbage()
        collectgarbage()
        local count = 0
        for _ in pairs(weakKeys) do count = count + 1 end
        assert(count == 1)
        assert(weakKeys[1] == 'kept')
    ");

    // Existing tables can be made weak in place.
    auto weakBoth = LuaTable.create(L);
    weakBoth.setWeakness(LuaWeakness.both);
    L.setGlobal("weakBoth", weakBoth);
    L.doString("
        local function setEntry()
            local key = {}
            weakBoth[key] = {}
        end
        setEntry()
        weakBoth[1] = 'kept'
        assert(getmetatable(weakBoth).__mode == 'kv')
        collectgarbage()
        collectgarbage()
        local count = 0
        for _ in pairs(weakBoth) do count = count + 1 end
        assert(count == 1)
        assert(weakBoth[1] == 'kept')
    ");

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

    // Free functions accept omitted defaults and typesafe variadic tails.
    registerFunction!addDefault(L, "add_default");
    registerFunction!sumVariadic(L, "sum_variadic");
    registerFunction!joinVariadic(L, "join_variadic");
    auto functionShape = L.eval("
        return add_default(1), add_default(1, 2),
               sum_variadic(), sum_variadic(1, 2, 3),
               join_variadic('-', 'a', 'b', 'c')
    ");
    assert(asInt(functionShape[0]) == 11);
    assert(asInt(functionShape[1]) == 3);
    assert(asInt(functionShape[2]) == 0);
    assert(asInt(functionShape[3]) == 6);
    assert(functionShape[4].stringValue == "a-b-c");

    // Extra arguments beyond the declared fixed parameters are rejected.
    bool extraArgFailed;
    try
        L.eval("add(1, 2, 3)");
    catch (LuaException e)
        extraArgFailed = true;
    assert(extraArgFailed);

    // D Tuple results become multiple Lua return values.
    registerFunction!describe(L, "describe");
    auto described = L.eval("return describe(21)");
    assert(asInt(described[0]) == 42);
    assert(described[1].stringValue == "v21");

    // Lua multiple returns can be collected into a D Tuple.
    auto multiReturn = L.loadString("return 7, 'x', true");
    auto tupleResult = multiReturn.call!(Tuple!(int, string, bool))();
    assert(tupleResult[0] == 7);
    assert(tupleResult[1] == "x");
    assert(tupleResult[2]);

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

    // Lua can construct D classes through a registered global class table.
    LuaClass!Player.registerConstructor(L, "Player");
    auto constructed = L.eval("
        local p = Player(5, 'made')
        assert(p:health() == 5)
        return p.hp, p.name
    ");
    assert(asInt(constructed[0]) == 5);
    assert(constructed[1].stringValue == "made");

    // Classes without explicit constructors get the implicit default one.
    LuaClass!DefaultConstructed.registerConstructor(L, "DefaultConstructed");
    auto defaultConstructed = L.eval("return DefaultConstructed().value");
    assert(asInt(defaultConstructed[0]) == 7);

    // Overloads are selected by arity and Lua argument types. Both
    // constructors and methods share the same dispatch path.
    LuaClass!Overloaded.registerConstructor(L, "Overloaded");
    auto overloaded = L.eval("
        local a = Overloaded(1)
        local b = Overloaded('x')
        local c = Overloaded(1, 2)
        return a.kind, b.kind, c.kind,
               a:pick(1), b:pick('x'), c:pick(1, 2)
    ");
    assert(overloaded[0].stringValue == "int");
    assert(overloaded[1].stringValue == "string");
    assert(overloaded[2].stringValue == "pair");
    assert(overloaded[3].stringValue == "int");
    assert(overloaded[4].stringValue == "string");
    assert(overloaded[5].stringValue == "pair");

    // Omitted trailing arguments take their D default values, for
    // constructors and methods alike.
    auto defaults = new Defaults;
    LuaClass!Defaults.registerConstructor(L, "Defaults");
    LuaClass!Defaults.setGlobal(L, "defaults", defaults);
    auto defaultResult = L.eval("
        local made = Defaults()
        local custom = Defaults(10)
        assert(defaults:total(1) == 11)
        assert(defaults:total(1, 10) == 19)
        assert(defaults:total(1, 10, 20) == 36)
        assert(defaults:tag() == 'v1')
        assert(custom:tag('x', 3) == 'x3')
        return made.base, custom.base, defaults:total(2)
    ");
    assert(asInt(defaultResult[0]) == 5);
    assert(asInt(defaultResult[1]) == 10);
    assert(asInt(defaultResult[2]) == 12);

    // D typesafe variadics collect the remaining Lua arguments.
    auto variadic = new Variadic;
    LuaClass!Variadic.setGlobal(L, "variadic", variadic);
    auto variadicResult = L.eval("
        assert(variadic:total() == 0)
        assert(variadic:total(1, 2, 3) == 6)
        assert(variadic:join('-', 'a', 'b', 'c') == 'a-b-c')
        assert(variadic:offset(10, 1, 2) == 13)
        return variadic:total(4, 5), variadic:join(',', 'x')
    ");
    assert(asInt(variadicResult[0]) == 9);
    assert(variadicResult[1].stringValue == "x");

    // Methods can return tuples as well.
    auto splitter = new Splitter;
    LuaClass!Splitter.setGlobal(L, "splitter", splitter);
    auto splitResult = L.eval("return splitter:digits(42)");
    assert(asInt(splitResult[0]) == 4);
    assert(asInt(splitResult[1]) == 2);

    // D toString and length integrate with Lua's tostring and # operators.
    auto stringResult = L.eval("return tostring(player)");
    assert(stringResult[0].stringValue == "Player:bob");

    auto bag = new Bag;
    bag.items = [1, 2, 3];
    LuaClass!Bag.setGlobal(L, "bag", bag);
    auto lenResult = L.eval("return #bag, bag.length");
    assert(asInt(lenResult[0]) == 3);
    assert(asInt(lenResult[1]) == 3);

    // D operator overloads map to Lua metamethods.
    auto vecA = new Vec(1);
    auto vecB = new Vec(3);
    LuaClass!Vec.setGlobal(L, "vecA", vecA);
    LuaClass!Vec.setGlobal(L, "vecB", vecB);
    auto opResult = L.eval("
        local sum = vecA + vecB
        local diff = vecB - vecA
        local neg = -vecA
        local joined = vecA .. vecB
        return sum.x, diff.x, neg.x, joined,
               vecA < vecB, vecA <= vecB, vecB < vecA, vecB <= vecA
    ");
    assert(asInt(opResult[0]) == 4);
    assert(asInt(opResult[1]) == 2);
    assert(asInt(opResult[2]) == -1);
    assert(opResult[3].stringValue == "vec");
    assert(opResult[4].booleanValue);
    assert(opResult[5].booleanValue);
    assert(!opResult[6].booleanValue);
    assert(!opResult[7].booleanValue);

    // A D opCall makes the userdata callable from Lua.
    auto callable = new Callable(10);
    LuaClass!Callable.setGlobal(L, "callable", callable);
    auto callResult = L.eval("return callable(5)");
    assert(asInt(callResult[0]) == 15);

    // D opIndex/opIndexAssign handle keys that are not field names. Numeric
    // keys must stay numeric instead of being coerced to strings.
    auto dict = new Dict;
    LuaClass!Dict.setGlobal(L, "dict", dict);
    auto indexResult = L.eval("
        dict['seed'] = 5
        assert(dict['seed'] == 5)
        dict[7] = 9
        assert(dict[7] == 9)
        assert(dict['missing'] == -1)
        return dict['seed'], dict[7]
    ");
    assert(asInt(indexResult[0]) == 5);
    assert(asInt(indexResult[1]) == 9);
    assert(dict.named.length == 1 && "seed" in dict.named);
    assert(dict.indexed.length == 1 && 7 in dict.indexed);

    // Structs are boxed as mutable userdata. Lua field writes and mutating
    // methods persist in the box, while the D value passed to push is copied.
    auto point = Point(1, 2);
    auto point2 = Point(1, 2);
    auto point3 = Point(9, 9);
    auto point4 = Point(11, 4);
    LuaStruct!Point.setGlobal(L, "point", point);
    LuaStruct!Point.setGlobal(L, "point2", point2);
    LuaStruct!Point.setGlobal(L, "point3", point3);
    LuaStruct!Point.setGlobal(L, "point4", point4);
    auto structResult = L.eval("
        assert(point.x == 1 and point.y == 2)
        point.x = 10
        point:move(1, 2)
        assert(point.x == 11 and point.y == 4)
        assert(point:sum() == 15)
        assert(point:scaled() == 15)
        assert(point:scaled(2) == 30)
        assert(point:plus(1, 2) == 18)
        assert(tostring(point) == 'Point(11,4)')
        assert(point == point4)
        assert(point ~= point2)
        local sum = point + point2
        local diff = point - point2
        local neg = -point
        assert(sum.x == 12 and sum.y == 6)
        assert(diff.x == 10 and diff.y == 2)
        assert(neg.x == -11 and neg.y == -4)
        assert(point2 < point3)
        assert(point2 <= point)
        return point.x, point.y, sum.x, sum.y
    ");
    assert(asInt(structResult[0]) == 11);
    assert(asInt(structResult[1]) == 4);
    assert(asInt(structResult[2]) == 12);
    assert(asInt(structResult[3]) == 6);
    assert(point.x == 1 && point.y == 2); // pushing copied the D value

    auto readBack = LuaStruct!Point.getGlobal(L, "point");
    assert(readBack.x == 11 && readBack.y == 4);

    // Const/immutable structs are copied into a mutable box.
    immutable Point frozen = Point(5, 6);
    LuaStruct!Point.setGlobal(L, "frozen", frozen);
    auto frozenResult = L.eval("return frozen.x, frozen.y");
    assert(asInt(frozenResult[0]) == 5);
    assert(asInt(frozenResult[1]) == 6);

    // Structs cross the boundary as method parameters and results.
    auto geometry = new Geometry;
    LuaClass!Geometry.setGlobal(L, "geometry", geometry);
    auto geometryResult = L.eval("
        assert(geometry:sum(point) == 15)
        local made = geometry:make(7, 8)
        assert(made.x == 7 and made.y == 8)
        return made.x, made.y
    ");
    assert(asInt(geometryResult[0]) == 7);
    assert(asInt(geometryResult[1]) == 8);

    // Struct-valued class fields can be read and assigned as boxes.
    auto holder = new HasPoint;
    holder.point = Point(3, 4);
    LuaClass!HasPoint.setGlobal(L, "holder", holder);
    L.doString("assert(holder.point.x == 3); holder.point = point2");
    assert(holder.point.x == 1 && holder.point.y == 2);

    // Constructor arity errors surface as Lua errors.
    bool ctorFailed;
    try
        L.eval("Player()");
    catch (LuaException e)
        ctorFailed = true;
    assert(ctorFailed);

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
