/// Compile-time + runtime smoke test.  The runtime checks require a Lua
/// library; `dub test --config=lua54` runs them in CI.
module lunarbind.tests;

import lunarbind;

import std.conv : to;
import std.functional : toDelegate;
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

class AutoBound
{
    int value;

    this(int value)
    {
        this.value = value;
    }

    int add(int amount)
    {
        value += amount;
        return value;
    }

    static int twice(int value)
    {
        return value * 2;
    }

    static string label()
    {
        return "auto";
    }

    static string overloaded(int value)
    {
        return "int";
    }

    static string overloaded(string value)
    {
        return "string:" ~ value;
    }

    private static int hidden()
    {
        return 1;
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

enum Color
{
    red,
    green,
    blue,
}

Color nextColor(Color color)
{
    return cast(Color) ((cast(int) color + 1) % 3);
}

string colorName(Color color)
{
    switch (color)
    {
        case Color.red:
            return "red";
        case Color.green:
            return "green";
        case Color.blue:
            return "blue";
        default:
            return "unknown";
    }
}

class Palette
{
    Color current;

    this(Color current)
    {
        this.current = current;
    }

    Color next()
    {
        current = nextColor(current);
        return current;
    }

    string name(Color color) const
    {
        return colorName(color);
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

struct Vec2
{
    double x;
    double y;
}

struct Vec2Codec
{
    static void push(LuaState L, ref const Vec2 value)
    {
        auto table = LuaTable.create(L);
        table["x"] = value.x;
        table["y"] = value.y;
        table.pushInto(L);
    }

    static Vec2 pop(LuaState L, int idx)
    {
        auto table = popFrom!LuaTable(L, idx);
        return Vec2(table.get!double("x"), table.get!double("y"));
    }

    static bool check(LuaState L, int idx)
    {
        return lua_type(L.handle, idx) == LUA_TTABLE;
    }
}

class CodecMath
{
    Vec2 add(Vec2 a, Vec2 b) const
    {
        return Vec2(a.x + b.x, a.y + b.y);
    }

    double length(Vec2 value) const
    {
        return value.x + value.y;
    }

    string describe(Vec2 value) const
    {
        return "vec";
    }

    string describe(int value) const
    {
        return "int";
    }
}

class Tagged
{
    string text;

    this(string text)
    {
        this.text = text;
    }
}

struct TaggedCodec
{
    static void push(LuaState L, ref const Tagged value)
    {
        pushTo(L, value.text);
    }

    static Tagged pop(LuaState L, int idx)
    {
        return new Tagged(popFrom!string(L, idx));
    }

    static bool check(LuaState L, int idx)
    {
        return lua_type(L.handle, idx) == LUA_TSTRING;
    }
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

class StateAware
{
    int total;

    int accumulate(LuaState L, int value, int factor = 1)
    {
        total += value * factor;
        L.setGlobal("state_aware_total", total);
        return total;
    }
}

class StateConstructed
{
    int value;

    this(LuaState L, int value = 4)
    {
        this.value = value;
        L.setGlobal("state_constructed", value);
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

string freePick(int value) { return "int"; }
string freePick(string value) { return "string:" ~ value; }
private int hiddenFree() { return 1; }

Tuple!(int, string) describe(int value)
{
    return tuple(value * 2, "v" ~ to!string(value));
}

int stateSum(LuaState L, int base = 1, int[] values...)
{
    int result = base;
    foreach (value; values)
        result += value;
    L.setGlobal("state_sum_result", result);
    return result;
}

int coroutineCallback(LuaState L, int value)
{
    L.setGlobal("coroutine_callback_seen", value);
    return value + 1;
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

    // Coroutines resume across yields and expose yielded/final values.
    auto threadFunction = L.eval("
        return function(a)
            local b, c = coroutine.yield(a + 1, a + 2)
            return b * c
        end
    ")[0].ref_.asFunction();
    auto thread = LuaThread.create(threadFunction);
    auto firstYield = thread.resume(10);
    assert(firstYield.length == 2);
    assert(asInt(firstYield[0]) == 11);
    assert(asInt(firstYield[1]) == 12);
    assert(thread.isSuspended());
    auto finalValues = thread.resume(2, 3);
    assert(finalValues.length == 1);
    assert(asInt(finalValues[0]) == 6);
    assert(!thread.isSuspended());

    // Coroutine errors surface as LuaException, not as yielded values.
    auto errorThread = LuaThread.create(L.loadString("error('boom')"));
    bool coroutineFailed;
    try
        errorThread.resume();
    catch (LuaException e)
    {
        coroutineFailed = true;
        assert(e.msg.length > 0);
    }
    assert(coroutineFailed);

    // A D callback invoked from a coroutine pushes results onto the coroutine's
    // stack, not the main stack.
    registerFunction!coroutineCallback(L, "coroutine_callback");
    auto callbackThread = LuaThread.create(
        L.loadString("return function() return coroutine_callback(41) end")
         .call!LuaFunction());
    auto callbackValues = callbackThread.resume();
    assert(callbackValues.length == 1);
    assert(asInt(callbackValues[0]) == 42);
    assert(L.getGlobal!int("coroutine_callback_seen") == 41);

    // Lua tables can be passed to a coroutine and returned from a yield.
    auto tableThread = LuaThread.create(
        L.loadString("
            return function(t)
                coroutine.yield({answer = t.x + 1})
                return t.x + 2
            end
        ").call!LuaFunction());
    auto input = LuaTable.create(L);
    input.set("x", 7);
    auto yieldedTable = tableThread.resume(input);
    assert(yieldedTable.length == 1);
    auto yielded = yieldedTable[0].ref_.asTable();
    assert(yielded.get!int("answer") == 8);
    auto finishedTable = tableThread.resume();
    assert(finishedTable.length == 1);
    assert(asInt(finishedTable[0]) == 9);

    // Existing Lua threads can be adopted from a thread value.
    auto adoptedValue = L.eval("return coroutine.create(function(a) return a + 5 end)")[0];
    auto adopted = LuaThread.fromValue(adoptedValue);
    auto adoptedValues = adopted.resume(37);
    assert(adoptedValues.length == 1);
    assert(asInt(adoptedValues[0]) == 42);

    // LuaThread handles push back into Lua as thread values.
    L.setGlobal("adopted_thread", adopted);
    auto adoptedRoundTrip = L.getGlobal!LuaValue("adopted_thread");
    assert(adoptedRoundTrip.kind == LuaType.thread);
    assert(LuaThread.fromValue(adoptedRoundTrip).status() == LuaStatus.ok);

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

    // A LuaState parameter is injected by the wrapper, not consumed from Lua.
    registerFunction!stateSum(L, "state_sum");
    auto stateSumResult = L.eval("return state_sum(), state_sum(10), state_sum(10, 1, 2)");
    assert(asInt(stateSumResult[0]) == 1);
    assert(asInt(stateSumResult[1]) == 10);
    assert(asInt(stateSumResult[2]) == 13);
    assert(L.getGlobal!int("state_sum_result") == 13);

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

    // Injected state works for methods and constructors, with defaults.
    auto stateAware = new StateAware;
    LuaClass!StateAware.setGlobal(L, "stateAware", stateAware);
    auto stateAwareResult = L.eval("
        assert(stateAware:accumulate(2) == 2)
        assert(stateAware:accumulate(3, 2) == 8)
        return stateAware.total
    ");
    assert(asInt(stateAwareResult[0]) == 8);
    assert(L.getGlobal!int("state_aware_total") == 8);

    LuaClass!StateConstructed.registerConstructor(L, "StateConstructed");
    auto stateConstructedResult = L.eval("
        local made = StateConstructed()
        local custom = StateConstructed(9)
        return made.value, custom.value
    ");
    assert(asInt(stateConstructedResult[0]) == 4);
    assert(asInt(stateConstructedResult[1]) == 9);
    assert(L.getGlobal!int("state_constructed") == 9);

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

    // Per-state codecs override the default struct/class representation and
    // participate in overload selection through their check predicate.
    registerCodec!Vec2(L,
        LuaCodec!Vec2(toDelegate(&Vec2Codec.push),
                      toDelegate(&Vec2Codec.pop),
                      toDelegate(&Vec2Codec.check)));
    auto codecMath = new CodecMath;
    LuaClass!CodecMath.setGlobal(L, "codecMath", codecMath);
    auto codecResult = L.eval("
        local v = {x = 1, y = 2}
        assert(codecMath:describe(v) == 'vec')
        assert(codecMath:describe(7) == 'int')
        local made = codecMath:add(v, {x = 2, y = 3})
        return made.x, made.y, codecMath:length(v)
    ");
    assert(asInt(codecResult[0]) == 3);
    assert(asInt(codecResult[1]) == 5);
    assert(asInt(codecResult[2]) == 3);

    registerCodec!Tagged(L,
        LuaCodec!Tagged(toDelegate(&TaggedCodec.push),
                        toDelegate(&TaggedCodec.pop),
                        toDelegate(&TaggedCodec.check)));
    auto tagged = new Tagged("hello");
    L.setGlobal("tagged", tagged);
    auto taggedResult = L.eval("return tagged");
    assert(taggedResult[0].stringValue == "hello");
    auto taggedBack = L.getGlobal!Tagged("tagged");
    assert(taggedBack !is tagged);
    assert(taggedBack.text == "hello");

    // Removing the codec restores the normal LuaClass representation.
    unregisterCodec!Tagged(L);
    L.setGlobal("taggedDefault", tagged);
    auto taggedKind = L.eval("return type(taggedDefault)");
    assert(taggedKind[0].stringValue == "userdata");
    assert(L.getGlobal!Tagged("taggedDefault") is tagged);

    bool codecRejected;
    try
    {
        registerCodec!Vec2(L, LuaCodec!Vec2.init);
    }
    catch (LuaArgumentException)
    {
        codecRejected = true;
    }
    assert(codecRejected);

    // Enums cross the boundary as their base integer values.
    L.setGlobal("color", Color.green);
    assert(L.getGlobal!Color("color") == Color.green);
    registerFunction!nextColor(L, "nextColor");
    registerFunction!colorName(L, "colorName");
    LuaClass!Palette.registerClass(L, "Palette");
    auto enumResult = L.eval("
        assert(nextColor(0) == 1)
        assert(colorName(2) == 'blue')
        local p = Palette(0)
        assert(p.current == 0)
        assert(p:name(2) == 'blue')
        assert(p:next() == 1)
        return p.current, nextColor(1), colorName(1)
    ");
    assert(asInt(enumResult[0]) == 1);
    assert(asInt(enumResult[1]) == 2);
    assert(enumResult[2].stringValue == "green");

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

    // One-call class binding exposes the constructor and every public method.
    LuaClass!AutoBound.registerClass(L, "AutoBound");
    auto autoBound = L.eval("
        local obj = AutoBound(10)
        obj:add(5)
        assert(AutoBound.hidden == nil)
        return obj.value,
               AutoBound.twice(21),
               AutoBound.label(),
               AutoBound.overloaded(7),
               AutoBound.overloaded('x'),
               AutoBound.add(obj, 1)
    ");
    assert(asInt(autoBound[0]) == 15);
    assert(asInt(autoBound[1]) == 42);
    assert(autoBound[2].stringValue == "auto");
    assert(autoBound[3].stringValue == "int");
    assert(autoBound[4].stringValue == "string:x");
    assert(asInt(autoBound[5]) == 16);

    // All public functions in a module can be bound in one call, including
    // overloads; private functions stay hidden.
    registerModule!(lunarbind.tests)(L, "testlib");
    auto moduleResult = L.eval("
        assert(testlib.hiddenFree == nil)
        assert(testlib.nextColor(0) == 1)
        assert(testlib.colorName(2) == 'blue')
        return testlib.add(20, 22),
               testlib.addDefault(1),
               testlib.sumVariadic(1, 2, 3),
               testlib.freePick(7),
               testlib.freePick('x')
    ");
    assert(asInt(moduleResult[0]) == 42);
    assert(asInt(moduleResult[1]) == 11);
    assert(asInt(moduleResult[2]) == 6);
    assert(moduleResult[3].stringValue == "int");
    assert(moduleResult[4].stringValue == "string:x");

    // Unified toLua facade: symbol kind is detected at compile time and the
    // returned handle matches the category.
    auto toLuaFn = toLua!add(L);
    assert(toLuaFn.call!int(20, 22) == 42);

    auto toLuaAliasFn = toLua!add(L, "toLuaAliasAdd");
    assert(toLuaAliasFn.call!int(1, 2) == 3);

    auto toLuaPickFn = toLua!freePick(L);
    assert(toLuaPickFn.call!string(7) == "int");
    assert(toLuaPickFn.call!string("x") == "string:x");

    auto toLuaClass = toLua!AutoBound(L);
    assert(toLuaClass.get!LuaFunction("twice").call!int(21) == 42);
    L.doString("
        local obj = AutoBound(3)
        obj:add(4)
        assert(obj.value == 7)
    ");

    auto toLuaInstance = new AutoBound(5);
    auto toLuaInstanceRef = toLua!toLuaInstance(L);
    assert(toLuaInstanceRef.type() == LuaType.userdata);
    L.doString("toLuaInstance:add(2)");
    assert(toLuaInstance.value == 7);

    auto toLuaRuntimeInstance = new AutoBound(9);
    auto toLuaRuntimeInstanceRef = toLua(L, toLuaRuntimeInstance, "toLuaRuntimeInstance");
    assert(toLuaRuntimeInstanceRef.type() == LuaType.userdata);
    L.doString("toLuaRuntimeInstance:add(1)");
    assert(toLuaRuntimeInstance.value == 10);

    auto toLuaModule = toLua!(lunarbind.tests)(L, "toLuaModule");
    assert(toLuaModule.get!LuaFunction("add").call!int(20, 22) == 42);
    assert(toLuaModule.get!LuaFunction("freePick").call!string(7) == "int");

    auto toLuaDefaultModule = toLua!(lunarbind.tests)(L);
    assert(toLuaDefaultModule.get!LuaFunction("add").call!int(1, 2) == 3);
    assert(L.getGlobal!LuaTable("tests").get!LuaFunction("add").call!int(2, 3) == 5);

    auto toLuaEnum = toLua!Color(L);
    assert(toLuaEnum.get!int("red") == 0);
    assert(toLuaEnum.get!int("green") == 1);
    assert(toLuaEnum.get!int("blue") == 2);

    auto toLuaValueRef = toLua(L, 42, "toLuaRuntimeAnswer");
    auto toLuaValueKind = toLuaValueRef.type();
    assert(toLuaValueKind == LuaType.integer || toLuaValueKind == LuaType.number);
    assert(L.getGlobal!int("toLuaRuntimeAnswer") == 42);

    L.toLua!add("toLuaUfcsAdd");
    assert(asInt(L.eval("return toLuaUfcsAdd(2, 3)")[0]) == 5);
    L.toLua("ufcs", "toLuaUfcsValue");
    assert(L.getGlobal!string("toLuaUfcsValue") == "ufcs");

    auto toLuaDelegate = (int x) => x * 2;
    auto toLuaDelegateFn = toLua(L, toLuaDelegate, "toLuaDouble");
    assert(toLuaDelegateFn.call!int(21) == 42);
    auto toLuaNamedDelegateFn = toLua!toLuaDelegate(L, "toLuaDouble2");
    assert(toLuaNamedDelegateFn.call!int(21) == 42);

    auto toLuaEnumValueRef = toLua!(Color.green)(L);
    auto toLuaEnumValueKind = toLuaEnumValueRef.type();
    assert(toLuaEnumValueKind == LuaType.integer || toLuaEnumValueKind == LuaType.number);
    assert(L.getGlobal!int("green") == 1);

    auto bindPoint = Point(1, 2);
    auto toLuaPointRef = toLua!bindPoint(L);
    assert(toLuaPointRef.type() == LuaType.userdata);
    L.doString("assert(bindPoint.x == 1); bindPoint.x = 9");
    assert(bindPoint.x == 1); // Lua mutated only the boxed copy

    static assert(is(typeof(toLua!add(L)) == LuaFunction));
    static assert(is(typeof(toLua!AutoBound(L)) == LuaTable));
    static assert(is(typeof(toLua!(lunarbind.tests)(L)) == LuaTable));
    static assert(is(typeof(toLua!Color(L)) == LuaTable));
    static assert(is(typeof(toLua(L, 1, "toLuaTypeProbe")) == LuaRef));
    static assert(is(typeof(toLua(L, (int x) => x, "toLuaTypeProbe")) == LuaFunction));

    static assert(!__traits(compiles, toLua!Point(L)),
                  "struct type binding is a documented future extension");

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
