/// Compile-time + runtime smoke test.  The runtime checks require a Lua
/// library; `dub test --config=lua54` runs them in CI.
module lunarbind.tests;

import lunarbind;
import lunarbind.exportfixture;
import lunarbind.rawfixture;

import std.algorithm.searching : canFind, startsWith;
import std.conv : to;
import std.file : remove, tempDir, write;
import std.functional : toDelegate;
import std.path : buildPath;
import std.string : indexOf;
import std.typecons : Nullable, Tuple, tuple;

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

@LuaExport("RenamedBox", "A box with a renamed field.")
class ExportedClass
{
    @LuaExport("v", "Stored value.")
    int value;

    @LuaExport(skip: true)
    int hiddenField;

    this(int value)
    {
        this.value = value;
    }

    @LuaExport("plus", "Adds an amount to the value.")
    int add(int amount)
    {
        value += amount;
        return value;
    }

    @LuaExport(skip: true)
    int internal()
    {
        return 99;
    }

    @LuaExport("double", "Doubles a value.")
    static int twice(int value)
    {
        return value * 2;
    }

    @LuaExport("_under")
    int normallyHidden()
    {
        return 5;
    }

    @property @LuaExport("total", "Current value.")
    int sum() const
    {
        return value;
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

@LuaExport("RenamedColor", "Traffic-light colors.")
enum ExportedColor
{
    @LuaExport("crimson", "Deep red.")
    red,
    green,
    @LuaExport(skip: true) blue,
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

    static int dimensions()
    {
        return 2;
    }

    static string describe(int value)
    {
        return "int";
    }

    static string describe(string value)
    {
        return "string:" ~ value;
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

@LuaExport("RenamedVec", "A two-dimensional vector.")
struct ExportedStruct
{
    int x;

    @LuaExport("yCoord", "Vertical coordinate.")
    int y;

    @LuaExport(skip: true)
    int hidden;

    @LuaExport("mag", "Sum of the coordinates.")
    int magnitude() const
    {
        return x + y;
    }

    @LuaExport("make", "Creates a vector.")
    static ExportedStruct create(int x, int y)
    {
        return ExportedStruct(x, y);
    }

    @LuaExport(skip: true)
    static int hiddenStatic()
    {
        return 1;
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

struct Seed
{
    int value;
}

class Seeded
{
    int value;

    this(Seed seed)
    {
        value = seed.value;
    }
}

class HoldsExported
{
    ExportedClass box;
}

class PointCollections
{
    Point[] points;
    Point[string] named;
    Nullable!Point maybe;

    Tuple!(int, Point) pair()
    {
        return tuple(1, Point(2, 3));
    }
}

struct Vec2
{
    double x;
    double y;
}

// Unions have no default representation; the codec below maps one member.
union CodecNumber
{
    int integer;
    float floating;
}

struct CodecNumberCodec
{
    static void push(LuaState L, ref const CodecNumber value)
    {
        pushTo(L, value.integer);
    }

    static CodecNumber pop(LuaState L, int idx)
    {
        CodecNumber result;
        result.integer = popFrom!int(L, idx);
        return result;
    }

    static bool check(LuaState L, int idx)
    {
        return lua_type(L.handle, idx) == LUA_TNUMBER;
    }
}

CodecNumber codecNumberRoundTrip(CodecNumber value)
{
    return value;
}

class HasUnionField
{
    CodecNumber number;
}

struct NamedValue
{
    string name;
    int value;
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

// Key type whose codec removes the current entry during AA conversion.
struct MutatingKey
{
    string name;
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

@LuaExport("renamedFree")
int exportFree(int value)
{
    return value * 2;
}

@LuaExport(skip: true)
int exportHiddenFree()
{
    return 7;
}

@LuaExport("renamedPick")
string exportPick(int value)
{
    return "int";
}

string exportPick(string value)
{
    return "string:" ~ value;
}

@LuaExport(skip: true)
int exportSkippedSet(int value)
{
    return 1;
}

int exportSkippedSet(string value)
{
    return 2;
}

@LuaExport
int exportBare(int value)
{
    return value + 1;
}

@LuaExport("exportBothName", skip: true)
int exportBoth()
{
    return 11;
}

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

// Used by the nested-resume test; reset after the coroutine finishes.
LuaThread nestedResumeThread;
int resumeNested(LuaState from)
{
    auto values = nestedResumeThread.resumeFrom(from, 41);
    return asInt(values[0]);
}

// Filled from a Lua callback; must stay valid after the callback returns.
LuaTable capturedTable;
void captureTable(LuaTable table) { capturedTable = table; }

// Used by the module-builder test.
int moduleAnswer = 42;

// Stand-in for a type with a custom registerCodec representation.
struct CodecVec
{
    int x;
    int y;
}

class HasCodecField
{
    CodecVec point;
    CodecVec[] points;
    Nullable!CodecVec maybe;
}

unittest
{
    auto L = LuaState.open();

    // scalars, strings, globals
    L.setGlobal("answer", 42);
    assert(L.getGlobal!int("answer") == 42);
    L.setGlobal("greeting", "hello");
    assert(L.getGlobal!string("greeting") == "hello");

    // Mutable char arrays round-trip through Lua strings as owned copies.
    auto mutableText = "mutable".dup;
    L.setGlobal("mutable_text", mutableText);
    auto copiedText = L.getGlobal!(char[])("mutable_text");
    assert(copiedText == "mutable");
    assert(copiedText.ptr !is mutableText.ptr);
    copiedText[0] = 'M';
    assert(L.getGlobal!string("mutable_text") == "mutable");

    // 64-bit integers must survive conversion without truncation to 32 bits
    // (regression: lua_tointegerx was declared as returning int).
    L.setGlobal("large", 500001500000L);
    assert(L.getGlobal!long("large") == 500001500000L);
    L.doString("function large_sum(n) return n * (n + 3) / 2 end");
    auto largeSum = L.getGlobal!LuaFunction("large_sum");
    assert(largeSum.call!long(1_000_000) == 500001500000L);
    assert(largeSum.call!double(1_000_000) == 500001500000.0);

    // Narrow integer conversions reject out-of-range values instead of
    // silently truncating.
    L.setGlobal("wide", 5_000_000_000L);
    bool wideThrew;
    try
        L.getGlobal!int("wide");
    catch (LuaArgumentException e)
        wideThrew = e.msg.canFind("out of range");
    assert(wideThrew);

    L.setGlobal("uint_value", 4_000_000_000L);
    assert(L.getGlobal!uint("uint_value") == 4_000_000_000u);

    L.setGlobal("negative", -1);
    bool unsignedThrew;
    try
        L.getGlobal!uint("negative");
    catch (LuaArgumentException e)
        unsignedThrew = e.msg.canFind("out of range");
    assert(unsignedThrew);

    // Numeric strings convert consistently on every supported version. Lua
    // 5.1 lacks the *x conversion functions, so the compat helpers must use
    // lua_isnumber rather than checking the raw type.
    L.setGlobal("numeric_string", "42");
    assert(L.getGlobal!int("numeric_string") == 42);
    assert(L.getGlobal!double("numeric_string") == 42.0);
    assert(L.getGlobal!string("numeric_string") == "42");
    L.setGlobal("not_numeric", "forty-two");
    bool stringIntThrew;
    try
        L.getGlobal!int("not_numeric");
    catch (LuaTypeException)
        stringIntThrew = true;
    assert(stringIntThrew);

    // Non-integral and out-of-range numbers are rejected on every version.
    // Lua 5.1/LuaJIT truncate in lua_tointeger and Lua 5.2 wraps
    // out-of-range floats, so the compat helper checks the value first.
    L.setGlobal("fractional", 3.75);
    bool fractionalThrew;
    try
        L.getGlobal!int("fractional");
    catch (LuaTypeException)
        fractionalThrew = true;
    assert(fractionalThrew);

    // An integral float is still a valid integer conversion.
    L.setGlobal("whole_number", 3.0);
    assert(L.getGlobal!int("whole_number") == 3);

    L.setGlobal("huge_number", 1e300);
    bool hugeThrew;
    try
        L.getGlobal!long("huge_number");
    catch (LuaTypeException)
        hugeThrew = true;
    assert(hugeThrew);

    bool pushThrew;
    try
        L.setGlobal("too_big", ulong.max);
    catch (LuaArgumentException e)
        pushThrew = e.msg.canFind("out of range");
    assert(pushThrew);
    assert(L.getGlobal!LuaValue("too_big").isNil());

    // Registry references must come from a live stack slot.
    bool invalidRefThrew;
    try
        LuaRef.make(L, L.top() + 1);
    catch (LuaArgumentException e)
        invalidRefThrew = e.msg.canFind("stack value");
    assert(invalidRefThrew);

    // An out-of-range index is "no value" on every runtime; Lua 5.1's
    // lua_typename handles LUA_TNONE explicitly instead of indexing the
    // type-name array.
    assert(L.typeName(L.top() + 1) == "no value");

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

    // Clearing weakness removes __mode instead of leaving the table weak.
    weakKeys.setWeakness(LuaWeakness.none);
    L.doString("
        assert(getmetatable(weakKeys).__mode == nil)
        assert(weakKeys[1] == 'kept')
    ");

    // `none` on a table without a metatable does not attach one.
    auto strongTable = LuaTable.create(L);
    strongTable.setWeakness(LuaWeakness.none);
    strongTable.push();
    assert(lua_getmetatable(L.handle, -1) == 0);
    L.pop(1);

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

    // setWeakness writes __mode with rawset, so a metatable's __newindex
    // cannot intercept the assignment or raise out of D.
    auto weakGuarded = LuaTable.create(L);
    L.setGlobal("weakGuarded", weakGuarded);
    L.doString("
        setmetatable(weakGuarded, {
            __newindex = function() error('no writes') end,
        })
    ");
    weakGuarded.setWeakness(LuaWeakness.keys);
    L.doString("assert(getmetatable(weakGuarded).__mode == 'k')");

    // Lua functions from D
    auto f = L.loadString("return 40 + 2");
    assert(f.call!int() == 42);

    auto mulValue = L.loadString("return function(a, b) return a * b end").call!LuaValue();
    L.setGlobal("mul", mulValue);
    auto mul = L.getGlobal!LuaFunction("mul");
    assert(mul.call!int(6, 7) == 42);

    auto bound = mul.bind!(int, int, int)();
    assert(bound(2, 3) == 6);

    // File loading mirrors loadString/eval and reports missing files with
    // LuaStatus.errFile.
    auto scriptPath = buildPath(tempDir(), "lunarbind-load-file-test.lua");
    write(scriptPath, "return 6 * 7, 'file'\n");
    scope(exit) remove(scriptPath);

    auto script = L.loadFile(scriptPath);
    auto fileResults = script.call!(Tuple!(int, string))();
    assert(fileResults[0] == 42);
    assert(fileResults[1] == "file");

    auto evalResults = L.evalFile(scriptPath);
    assert(asInt(evalResults[0]) == 42);
    assert(evalResults[1].stringValue == "file");

    L.doFile(scriptPath);

    bool missingThrew;
    LuaStatus missingStatus;
    string missingMessage;
    try
        L.loadFile(buildPath(tempDir(), "lunarbind-missing-file.lua"));
    catch (LuaException e)
    {
        missingThrew = e.status == LuaStatus.errFile;
        missingStatus = e.status;
        missingMessage = e.msg;
    }
    assert(missingThrew,
           "status=" ~ to!string(cast(int) missingStatus) ~ " msg=" ~ missingMessage);

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

    // Reference-valued LuaValue arguments are pushed onto the coroutine's
    // stack, not the main state's stack.
    auto argumentThread = LuaThread.create(
        L.loadString("return function(t) return t.value end")
         .call!LuaFunction());
    auto argumentTable = LuaTable.create(L);
    argumentTable["value"] = 99;
    auto tableValues = argumentThread.resume(argumentTable.ref_.asValue());
    assert(tableValues.length == 1);
    assert(asInt(tableValues[0]) == 99);

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

    // Resuming from inside a coroutine passes the calling thread to Lua, so
    // the inner coroutine inherits the outer thread's C-call depth.
    nestedResumeThread = LuaThread.create(
        L.loadString("return function(x) return x + 1 end")
         .call!LuaFunction());
    registerFunction!resumeNested(L, "resume_nested");
    auto outerThread = LuaThread.create(
        L.loadString("return function() return resume_nested() end")
         .call!LuaFunction());
    auto nestedValues = outerThread.resume();
    assert(nestedValues.length == 1);
    assert(asInt(nestedValues[0]) == 42);
    nestedResumeThread = LuaThread.init;

    // resumeFrom rejects closed and foreign states.
    auto closedThread = LuaThread.create(
        L.loadString("return function() end").call!LuaFunction());
    bool rejectedClosed;
    try
        closedThread.resumeFrom(LuaState.init);
    catch (LuaStateException)
        rejectedClosed = true;
    assert(rejectedClosed);

    auto foreignState = LuaState.open();
    bool rejectedForeign;
    try
        closedThread.resumeFrom(foreignState);
    catch (LuaStateException)
        rejectedForeign = true;
    assert(rejectedForeign);
    foreignState.close();

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

    // Unions require an explicit codec. Without one, push and pop report the
    // missing type instead of guessing an active member.
    CodecNumber numberUnion;
    numberUnion.integer = 21;
    bool unionPushRejected;
    try
        L.setGlobal("raw_union", numberUnion);
    catch (LuaArgumentException e)
        unionPushRejected = e.msg.canFind("no codec registered for union");
    assert(unionPushRejected);
    assert(L.getGlobal!LuaValue("raw_union").isNil());

    // A failed container conversion must not leave a partial table behind.
    auto topBefore = L.top();
    bool arrayPushRejected;
    try
        L.setGlobal("raw_union_array", [numberUnion]);
    catch (LuaArgumentException e)
        arrayPushRejected = e.msg.canFind("no codec registered for union");
    assert(arrayPushRejected);
    assert(L.top() == topBefore);

    bool pushRejected;
    try
        L.push([numberUnion]);
    catch (LuaArgumentException e)
        pushRejected = e.msg.canFind("no codec registered for union");
    assert(pushRejected);
    assert(L.top() == topBefore);

    auto pendingModule = LuaModule.create(L);
    bool moduleSetRejected;
    try
        pendingModule.set("bad", [numberUnion]);
    catch (LuaArgumentException e)
        moduleSetRejected = e.msg.canFind("no codec registered for union");
    assert(moduleSetRejected);
    assert(L.top() == topBefore);

    bool toLuaValueRejected;
    try
        toLua(L, [numberUnion], "bad_union_value");
    catch (LuaArgumentException e)
        toLuaValueRejected = e.msg.canFind("no codec registered for union");
    assert(toLuaValueRejected);
    assert(L.top() == topBefore);

    bool toLuaSymbolRejected;
    try
        toLua!numberUnion(L, "bad_union_symbol");
    catch (LuaArgumentException e)
        toLuaSymbolRejected = e.msg.canFind("no codec registered for union");
    assert(toLuaSymbolRejected);
    assert(L.top() == topBefore);

    registerCodec!CodecNumber(L, LuaCodec!CodecNumber(
        toDelegate(&CodecNumberCodec.push),
        toDelegate(&CodecNumberCodec.pop),
        toDelegate(&CodecNumberCodec.check)));
    L.setGlobal("number_union", numberUnion);
    assert(L.getGlobal!int("number_union") == 21);
    assert(L.getGlobal!CodecNumber("number_union").integer == 21);

    registerFunction!codecNumberRoundTrip(L, "codecNumberRoundTrip");
    assert(asInt(L.eval("return codecNumberRoundTrip(42)")[0]) == 42);

    // Class fields of union type use the same codec for reads and writes.
    auto unionHolder = new HasUnionField;
    unionHolder.number.integer = 5;
    LuaClass!HasUnionField.setGlobal(L, "unionHolder", unionHolder);
    auto unionFieldResult = L.eval("
        assert(unionHolder.number == 5)
        unionHolder.number = 8
        return unionHolder.number
    ");
    assert(asInt(unionFieldResult[0]) == 8);
    assert(unionHolder.number.integer == 8);

    unregisterCodec!CodecNumber(L);
    bool unionPopRejected;
    try
        L.getGlobal!CodecNumber("number_union");
    catch (LuaArgumentException e)
        unionPopRejected = e.msg.canFind("no codec registered for union");
    assert(unionPopRejected);

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
        assert(testlib.exportFree == nil)
        assert(testlib.exportHiddenFree == nil)
        assert(testlib.exportPick == nil)
        assert(testlib.exportSkippedSet == nil)
        assert(testlib.exportBoth == nil)
        assert(testlib.exportBothName == nil)
        assert(testlib.renamedFree(21) == 42)
        assert(testlib.renamedPick(7) == 'int')
        assert(testlib.renamedPick('x') == 'string:x')
        assert(testlib.exportBare(1) == 2)
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

    // @LuaExport renames symbols and members in automatic tables, and
    // skip: true removes them. Explicit toLua calls honor the name but ignore
    // skip, so a hidden member can still be bound on purpose.
    auto exportedClass = toLua!ExportedClass(L);
    assert(exportedClass.get!LuaFunction("double").call!int(21) == 42);
    auto exportedClassResult = L.eval("
        local obj = RenamedBox(3)
        obj.v = obj.v + 4
        obj:plus(2)
        assert(obj.value == nil)
        assert(obj.hiddenField == nil)
        assert(obj.internal == nil)
        assert(RenamedBox.internal == nil)
        assert(obj:_under() == 5)
        assert(obj.total == 9)
        assert(ExportedClass == nil)
        return obj.v, obj.total, RenamedBox.double(20), RenamedBox.plus(obj, 1)
    ");
    assert(asInt(exportedClassResult[0]) == 9);
    assert(asInt(exportedClassResult[1]) == 9);
    assert(asInt(exportedClassResult[2]) == 40);
    assert(asInt(exportedClassResult[3]) == 10);

    // bind() uses the @LuaExport type name by default.
    auto boundExportedClass = LuaClass!ExportedClass.bind(L);
    assert(boundExportedClass.get!LuaFunction("double").call!int(2) == 4);
    assert(asInt(L.eval("return RenamedBox(6).v")[0]) == 6);

    // Struct type tables use renamed static methods; struct values use the
    // renamed fields and methods on their instance metatable.
    auto exportedStructType = toLua!ExportedStruct(L);
    assert(exportedStructType.get!LuaFunction("make").ref_.type() == LuaType.function_);
    L.doString("
        local s = RenamedVec.make(3, 4)
        assert(s.x == 3)
        assert(s.yCoord == 4)
        assert(s.y == nil)
        assert(s.hidden == nil)
        assert(s:mag() == 7)
        assert(RenamedVec.hiddenStatic == nil)
    ");
    auto exportedStructValue = ExportedStruct(5, 6);
    LuaStruct!ExportedStruct.setGlobal(L, "exportedStructValue", exportedStructValue);
    L.doString("
        assert(exportedStructValue.x == 5)
        assert(exportedStructValue.yCoord == 6)
        assert(exportedStructValue.y == nil)
        assert(exportedStructValue.hidden == nil)
        assert(exportedStructValue:mag() == 11)
    ");
    auto boundExportedStruct = LuaStruct!ExportedStruct.bind(L);
    assert(boundExportedStruct.get!LuaFunction("make").ref_.type() == LuaType.function_);

    // Enum tables use the renamed type and members, and hide skipped members.
    auto exportedEnum = toLua!ExportedColor(L);
    assert(exportedEnum.get!int("crimson") == 0);
    assert(exportedEnum.get!int("green") == 1);
    L.doString("
        assert(RenamedColor.crimson == 0)
        assert(RenamedColor.green == 1)
        assert(RenamedColor.blue == nil)
        assert(RenamedColor.red == nil)
    ");

    // A skipped enum member is still available through explicit toLua.
    auto explicitBlue = toLua!(ExportedColor.blue)(L);
    auto explicitBlueKind = explicitBlue.type();
    assert(explicitBlueKind == LuaType.integer || explicitBlueKind == LuaType.number);
    assert(L.getGlobal!int("blue") == 2);

    // A skipped free function is hidden from registerModule but can be bound
    // explicitly.
    auto hiddenFreeFn = toLua!exportHiddenFree(L);
    assert(hiddenFreeFn.call!int() == 7);
    L.doString("assert(testlib.exportHiddenFree == nil)");

    // Renamed overload sets share one Lua function under the UDA name.
    auto renamedOverloads = toLua!exportPick(L);
    assert(renamedOverloads.call!string(7) == "int");
    assert(renamedOverloads.call!string("x") == "string:x");
    auto skippedOverloads = toLua!exportSkippedSet(L);
    assert(skippedOverloads.call!int(1) == 1);
    assert(skippedOverloads.call!int("x") == 2);

    // Module-level @LuaExport supplies the default table name, and function
    // UDAs apply inside that table.
    auto fixtureModule = toLua!(lunarbind.exportfixture)(L);
    assert(fixtureModule.get!LuaFunction("fixtureAdd").call!int(20, 22) == 42);
    assert(fixtureModule.get!LuaFunction("fixtureChoice").call!string(7) == "int");
    assert(fixtureModule.get!LuaFunction("fixtureChoice").call!string("x") == "string:x");
    assert(fixtureModule.get!LuaFunction("fixturePlain").call!int(1) == 2);
    L.doString("
        assert(renamedFixture.fixtureHidden == nil)
        assert(renamedFixture.fixtureSum == nil)
        assert(renamedFixture.fixturePick == nil)
        assert(renamedFixture.fixtureAdd(1, 2) == 3)
        assert(renamedFixture.fixtureChoice(1) == 'int')
    ");
    auto fixtureHiddenFn = toLua!fixtureHidden(L);
    assert(fixtureHiddenFn.call!int() == 7);

    // Direct registration APIs also use the UDA defaults.
    registerModule!(lunarbind.exportfixture)(L);
    L.doString("assert(renamedFixture.fixtureAdd(1, 2) == 3)");
    registerEnum!ExportedColor(L);
    L.doString("
        assert(RenamedColor.crimson == 0)
        assert(RenamedColor.blue == nil)
    ");

    // An explicit name and skip: true combine: automatic tables hide the
    // member, while an explicit toLua uses the requested name.
    auto combinedExport = toLua!exportBoth(L);
    assert(combinedExport.call!int() == 11);
    assert(L.getGlobal!LuaFunction("exportBothName").call!int() == 11);

    static assert(is(typeof(toLua!ExportedClass(L)) == LuaTable));
    static assert(is(typeof(toLua!ExportedStruct(L)) == LuaTable));
    static assert(is(typeof(toLua!ExportedColor(L)) == LuaTable));
    static assert(is(typeof(toLua!(lunarbind.exportfixture)(L)) == LuaTable));

    // The module builder composes symbols without creating globals.
    auto composed = LuaModule.create(L)
        .addFunction!add("sum")
        .addFunction!exportPick("pick")
        .addClass!ExportedClass("Box")
        .addStruct!ExportedStruct("Vec")
        .addEnum!ExportedColor("Palette")
        .addModule!(lunarbind.exportfixture)("fx")
        .addValue!moduleAnswer("answer")
        .set("version", 3);
    assert(composed.table().get!int("version") == 3);
    L.doString("assert(sum == nil and Box == nil and toolbox == nil)");
    composed.setGlobal("toolbox");
    L.doString("
        assert(toolbox.sum(2, 3) == 5)
        assert(toolbox.pick(1) == 'int')
        assert(toolbox.pick('x') == 'string:x')
        assert(toolbox.answer == 42)
        assert(toolbox.Palette.crimson == 0)
        assert(toolbox.Palette.blue == nil)
        assert(toolbox.fx.fixtureAdd(1, 2) == 3)
        local box = toolbox.Box(4)
        assert(box.v == 4)
        assert(box:plus(3) == 7)
        assert(toolbox.Box.double(5) == 10)
        local vec = toolbox.Vec.make(1, 2)
        assert(vec.x == 1 and vec.yCoord == 2)
        assert(vec:mag() == 3)
    ");

    // LuaModule.set/addFunction protect a __newindex metamethod on the module
    // table instead of letting it longjmp out of D.
    L.doString("
        setmetatable(toolbox, {
            __newindex = function(t, k, v)
                if k == 'blocked' then error('module blocked') end
                rawset(t, k, v)
            end,
        })
    ");
    bool blocked;
    try
        composed.set("blocked", 1);
    catch (LuaException e)
        blocked = e.msg.canFind("module blocked");
    assert(blocked);

    composed.set("allowed", 2);
    assert(composed.table().get!int("allowed") == 2);

    blocked = false;
    try
        composed.addFunction!add("blocked");
    catch (LuaException e)
        blocked = e.msg.canFind("module blocked");
    assert(blocked);

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

    // Struct type tables expose public static methods. Struct values stay
    // value-only and are bound separately.
    auto toLuaPointType = toLua!Point(L);
    assert(toLuaPointType.get!LuaFunction("dimensions").call!int() == 2);
    assert(toLuaPointType.get!LuaFunction("describe").call!string(7) == "int");
    assert(toLuaPointType.get!LuaFunction("describe").call!string("x") == "string:x");
    assert(asInt(L.eval("return Point.dimensions()")[0]) == 2);
    assert(L.eval("return Point.describe('y')")[0].stringValue == "string:y");

    static assert(is(typeof(toLua!add(L)) == LuaFunction));
    static assert(is(typeof(toLua!AutoBound(L)) == LuaTable));
    static assert(is(typeof(toLua!(lunarbind.tests)(L)) == LuaTable));
    static assert(is(typeof(toLua!Color(L)) == LuaTable));
    static assert(is(typeof(toLua!Point(L)) == LuaTable));
    static assert(is(typeof(toLua(L, 1, "toLuaTypeProbe")) == LuaRef));
    static assert(is(typeof(toLua(L, (int x) => x, "toLuaTypeProbe")) == LuaFunction));

    // a wrapper must share the owner's core
    auto wrapped = LuaState.wrap(L.handle);
    assert(wrapped.sharesState(L));
    assert(!LuaState.init.sharesState(LuaState.init));
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

    // Associative array keys that convert to nil or NaN are rejected before
    // lua_rawset can raise an unprotected Lua error.
    auto nanTop = L.top();
    int[double] nanKeys;
    nanKeys[double.nan] = 1;
    bool nanKeyRejected;
    try
        L.setGlobal("nan_keys", nanKeys);
    catch (LuaArgumentException e)
        nanKeyRejected = e.msg.canFind("NaN");
    assert(nanKeyRejected);
    assert(L.top() == nanTop);

    int[Player] nullKeys;
    nullKeys[null] = 2;
    bool nullKeyRejected;
    try
        L.setGlobal("null_keys", nullKeys);
    catch (LuaArgumentException e)
        nullKeyRejected = e.msg.canFind("nil");
    assert(nullKeyRejected);
    assert(L.top() == nanTop);

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

    // A userdata whose finalizer already ran can be resurrected and remain
    // reachable from Lua. Accessing it must raise instead of dereferencing a
    // null boxed reference.
    {
        auto dead = new Player(9, "dead");
        LuaClass!Player.setGlobal(L, "dead", dead);
        L.doString("dead_ref = dead");
        LuaClass!Player.push(L, dead);
        auto box = cast(Player*) lua_touserdata(L.handle, -1);
        auto saved = *box;
        *box = null;
        L.pop(1);

        bool getThrew;
        try
            L.getGlobal!Player("dead");
        catch (LuaStateException e)
            getThrew = e.msg.canFind("no longer alive");
        assert(getThrew);

        void expectDead(string code, string what)
        {
            bool threw;
            try
                L.doString(code);
            catch (LuaException e)
                threw = e.msg.canFind("no longer alive");
            assert(threw, what);
        }

        expectDead("dead:damage(1)", "method");
        expectDead("local hp = dead.hp", "field read");
        expectDead("dead.hp = 5", "field write");
        expectDead("return tostring(dead)", "tostring");

        // Restore the box so the state's root accounting stays consistent.
        *box = saved;
        L.doString("dead = nil; dead_ref = nil");
    }

    // Struct boxes carry an explicit liveness marker. A finalizer that
    // resurrects the userdata must not leave a value whose GC range was
    // already removed accessible through the binding.
    {
        LuaStruct!NamedValue.setGlobal(L, "doomed_struct",
                                       NamedValue("payload".idup, 3));
        L.doString(q{
            local s = doomed_struct
            doomed_struct = nil
            local mt = debug.getmetatable(s)
            local finalize = mt.__gc
            resurrected_meta = mt
            resurrected_finalize = finalize
            mt.__gc = function(u) finalize(u); resurrected_struct = u end
            s = nil
            collectgarbage()
            collectgarbage()
        });
        assert(L.getGlobal!LuaValue("resurrected_struct").kind
               == LuaType.userdata);

        bool structGetThrew;
        try
            L.getGlobal!NamedValue("resurrected_struct");
        catch (LuaStateException e)
            structGetThrew = e.msg.canFind("no longer alive");
        assert(structGetThrew);

        void expectStructDead(string code, string what)
        {
            bool threw;
            try
                L.doString(code);
            catch (LuaException e)
                threw = e.msg.canFind("no longer alive");
            assert(threw, what);
        }

        expectStructDead("local name = resurrected_struct.name",
                         "struct field read");
        expectStructDead("resurrected_struct.name = 'changed'",
                         "struct field write");
        expectStructDead("resurrected_struct.value = 9",
                         "struct integer field write");

        // Drop the wrapper and the resurrected userdata before other tests
        // reuse the shared NamedValue metatable.
        L.doString(q{
            resurrected_meta.__gc = resurrected_finalize
            resurrected_meta = nil
            resurrected_finalize = nil
            resurrected_struct = nil
        });
    }
}

unittest
{
    // EmmyLua type mapping.
    assert(luaStubType!int() == "integer");
    assert(luaStubType!long() == "integer");
    assert(luaStubType!double() == "number");
    assert(luaStubType!string() == "string");
    assert(luaStubType!bool() == "boolean");
    assert(luaStubType!(int[])() == "integer[]");
    assert(luaStubType!(int[string])() == "table<string, integer>");
    assert(luaStubType!(int*)() == "lightuserdata");
    assert(luaStubType!(Nullable!int)() == "integer|nil");
    assert(luaStubType!LuaValue() == "any");
    assert(luaStubType!LuaTable() == "table");
    assert(luaStubType!LuaFunction() == "function");
    assert(luaStubType!LuaThread() == "thread");
    assert(luaStubType!ExportedClass() == "RenamedBox");
    assert(luaStubType!ExportedColor() == "RenamedColor");
    assert(luaStubType!void() == "nil");

    // Classes expose fields, properties, constructors, instance methods and
    // static methods. Private and skipped members are omitted.
    auto classStub = luaStubs!AutoBound();
    assert(classStub.startsWith("---@meta\n"));
    assert(classStub.canFind("---@class AutoBound"));
    assert(classStub.canFind("\nAutoBound = {}"));
    assert(!classStub.canFind("local AutoBound"));
    assert(classStub.canFind("---@field public value integer"));
    assert(classStub.canFind("function AutoBound(value) end"));
    assert(classStub.canFind("function AutoBound.add(self, amount) end"));
    assert(classStub.canFind("function AutoBound.twice(value) end"));
    assert(classStub.canFind("function AutoBound.label() end"));
    assert(!classStub.canFind("hidden"));

    auto exportedClassStub = luaStubs!ExportedClass();
    assert(exportedClassStub.canFind("---@class RenamedBox"));
    assert(exportedClassStub.canFind("---@field public v integer"));
    assert(exportedClassStub.canFind("---@field public total integer"));
    assert(exportedClassStub.canFind("function RenamedBox.plus(self, amount) end"));
    assert(exportedClassStub.canFind("function RenamedBox.double(value) end"));
    assert(exportedClassStub.canFind("function RenamedBox._under(self) end"));
    assert(!exportedClassStub.canFind("hiddenField"));
    assert(!exportedClassStub.canFind("internal"));
    assert(!exportedClassStub.canFind("value ===")); // renamed field only
    assert(exportedClassStub.canFind("--- A box with a renamed field."));
    assert(exportedClassStub.canFind(
        "---@field public v integer # Stored value."));
    assert(exportedClassStub.canFind("--- Adds an amount to the value."));
    assert(exportedClassStub.canFind(
        "---@field public total integer # Current value."));

    // Struct type tables expose static methods without a constructor; struct
    // values expose fields and instance methods through the value class.
    auto structStub = luaStubs!ExportedStruct();
    assert(structStub.canFind("---@class RenamedVec"));
    assert(structStub.canFind("---@field public x integer"));
    assert(structStub.canFind("---@field public yCoord integer"));
    assert(structStub.canFind("---@field public mag fun(self: RenamedVec): integer"));
    assert(structStub.canFind("function RenamedVec.make(x, y) end"));
    assert(!structStub.canFind("hiddenStatic"));
    assert(!structStub.canFind("hidden "));
    assert(structStub.canFind("--- A two-dimensional vector."));
    assert(structStub.canFind(
        "---@field public yCoord integer # Vertical coordinate."));
    assert(structStub.canFind("# Sum of the coordinates."));

    // Enum tables use renamed members and hide skipped ones.
    auto enumStub = luaStubs!ExportedColor();
    assert(enumStub.canFind("---@enum RenamedColor"));
    assert(enumStub.canFind("crimson = 0, -- Deep red."));
    assert(enumStub.canFind("green = 1"));
    assert(!enumStub.canFind("blue"));
    assert(enumStub.canFind("--- Traffic-light colors."));

    // String-backed enums keep their string values.
    enum Named
    {
        first = "one",
        second = "two",
    }
    auto namedStub = luaStubs!Named();
    assert(namedStub.canFind(`first = "one"`));
    assert(namedStub.canFind(`second = "two"`));

    // Base classes are emitted before derived classes.
    auto derivedStub = luaStubs!Dog();
    assert(derivedStub.canFind("---@class Animal"));
    assert(derivedStub.canFind("---@class Dog : Animal"));
    assert(derivedStub.canFind("---@field public name string"));

    // Types referenced by public fields, properties, constructors and method
    // signatures are declared before the dependent type.
    auto geometryStub = luaStubs!Geometry();
    assert(geometryStub.indexOf("---@class Point")
           < geometryStub.indexOf("---@class Geometry"));
    assert(geometryStub.canFind("---@field public x integer"));
    assert(geometryStub.canFind("function Geometry.sum(self, p) end"));
    assert(geometryStub.canFind("function Geometry.make(self, x, y) end"));

    auto hasPointStub = luaStubs!HasPoint();
    assert(hasPointStub.indexOf("---@class Point")
           < hasPointStub.indexOf("---@class HasPoint"));
    assert(hasPointStub.canFind("---@field public point Point"));

    // Enum references work from fields and method signatures.
    auto paletteStub = luaStubs!Palette();
    assert(paletteStub.indexOf("---@enum Color")
           < paletteStub.indexOf("---@class Palette"));
    assert(paletteStub.canFind("---@field public current Color"));
    assert(paletteStub.canFind("---@param color Color"));
    assert(paletteStub.canFind("---@return Color"));

    // Referenced types keep their @LuaExport names.
    auto holdsExportedStub = luaStubs!HoldsExported();
    assert(holdsExportedStub.canFind("---@class RenamedBox"));
    assert(holdsExportedStub.canFind("---@field public box RenamedBox"));
    assert(!holdsExportedStub.canFind("---@class ExportedClass"));

    // Constructor parameter types are discovered too.
    auto seededStub = luaStubs!Seeded();
    assert(seededStub.indexOf("---@class Seed")
           < seededStub.indexOf("---@class Seeded"));
    assert(seededStub.canFind("---@param seed Seed"));

    // Discovery follows arrays, associative arrays, Nullable and Tuple.
    auto collectionsStub = luaStubs!PointCollections();
    assert(collectionsStub.indexOf("---@class Point")
           < collectionsStub.indexOf("---@class PointCollections"));
    assert(collectionsStub.canFind("---@field public points Point[]"));
    assert(collectionsStub.canFind(
        "---@field public named table<string, Point>"));
    assert(collectionsStub.canFind("---@field public maybe Point|nil"));
    assert(collectionsStub.canFind("---@return Point"));

    // A struct referring to itself is declared exactly once.
    auto selfStructStub = luaStubs!ExportedStruct();
    auto selfIndex = selfStructStub.indexOf("---@class RenamedVec");
    assert(selfIndex >= 0);
    assert(selfStructStub.indexOf("---@class RenamedVec", selfIndex + 1) < 0);

    // Lua handles are mapped to primitive types, not declared as classes.
    auto capturedStub = luaStubs!capturedTable();
    assert(capturedStub.canFind("---@type table"));
    assert(!capturedStub.canFind("---@class LuaTable"));

    // Overloaded constructors become ---@overload entries.
    auto overloadedCtorStub = luaStubs!Overloaded();
    assert(overloadedCtorStub.canFind("---@overload fun(value: integer): Overloaded"));
    assert(overloadedCtorStub.canFind("---@overload fun(value: string): Overloaded"));
    assert(overloadedCtorStub.canFind("---@overload fun(a: integer, b: integer): Overloaded"));
    assert(overloadedCtorStub.canFind("function Overloaded(...) end"));

    // Module tables follow registerModule's filtering and overload handling.
    auto moduleStub = luaStubs!(lunarbind.exportfixture)();
    assert(moduleStub.canFind("---@class renamedFixture"));
    assert(moduleStub.canFind("function renamedFixture.fixtureAdd(a, b) end"));
    assert(moduleStub.canFind("---@overload fun(value: integer): string"));
    assert(moduleStub.canFind("---@overload fun(value: string): string"));
    assert(moduleStub.canFind("function renamedFixture.fixtureChoice(...) end"));
    assert(moduleStub.canFind("function renamedFixture.fixturePlain(value) end"));
    assert(!moduleStub.canFind("fixtureHidden"));
    assert(!moduleStub.canFind("fixtureSum"));
    assert(!moduleStub.canFind("fixturePick"));
    assert(moduleStub.canFind("--- Fixture bindings."));
    assert(moduleStub.canFind("--- Adds two integers."));

    // Module signatures discover referenced types before the module table.
    assert(moduleStub.indexOf("---@class FixturePoint")
           < moduleStub.indexOf("---@class renamedFixture"));
    assert(moduleStub.canFind("---@param point FixturePoint"));
    assert(moduleStub.canFind("function renamedFixture.fixtureOrigin() end"));
    assert(moduleStub.canFind(
        "function renamedFixture.fixtureShift(point, dx, dy) end"));

    // Free functions, injected LuaState parameters, defaults and variadics.
    assert(luaStubs!add().canFind("function add(a, b) end"));
    auto tupleStub = luaStubs!describe();
    assert(tupleStub.canFind("---@return integer"));
    assert(tupleStub.canFind("---@return string"));
    assert(tupleStub.canFind("function describe(value) end"));
    auto variadicStub = luaStubs!stateSum();
    assert(variadicStub.canFind("---@param base? integer"));
    assert(variadicStub.canFind("---@vararg integer"));
    assert(variadicStub.canFind("function stateSum(base, ...) end"));

    // An explicit stub request ignores skip, mirroring explicit toLua.
    assert(luaStubs!exportHiddenFree().canFind("function exportHiddenFree() end"));

    // Runtime values are declared with ---@type.
    assert(luaStubs!capturedTable().canFind("---@type table\ncapturedTable = nil"));

    // Custom-codec types can override the generated Lua type, and the override
    // suppresses the default class declaration.
    LuaStubBuilder codecBuilder;
    codecBuilder.setType!CodecVec("table");
    codecBuilder.addClass!HasCodecField();
    auto codecStub = codecBuilder.toString();
    assert(codecStub.canFind("---@field public point table"));
    assert(codecStub.canFind("---@field public points table[]"));
    assert(codecStub.canFind("---@field public maybe table|nil"));
    assert(!codecStub.canFind("---@class CodecVec"));

    auto overrideStub = luaStubs!HasCodecField([typeid(CodecVec): "table"]);
    assert(overrideStub.canFind("---@field public point table"));
    assert(!overrideStub.canFind("---@class CodecVec"));

    // The builder can be used incrementally.
    LuaStubBuilder builder;
    builder.addFunction!add("sum");
    builder.addValue!int("answer");
    auto manual = builder.toString();
    assert(manual.canFind("function sum(a, b) end"));
    assert(manual.canFind("---@type integer\nanswer = nil"));
}

unittest
{
    // Selective standard library loading.
    auto minimal = LuaState.open(LuaLib.base | LuaLib.string | LuaLib.table);
    minimal.doString("
        assert(type(print) == 'function')
        assert(type(string.format) == 'function')
        assert(type(table.concat) == 'function')
        assert(io == nil)
        assert(os == nil)
        assert(math == nil)
        assert(debug == nil)
        assert(package == nil)
    ");

    // Libraries can be added after creation, and opening twice is harmless.
    minimal.openLibraries(LuaLib.math);
    minimal.openLibraries(LuaLib.math);
    minimal.doString("assert(math.floor(1.5) == 1)");

    // No libraries at all. The base library also defines `assert`, so check
    // globals from D instead of running Lua assertions.
    auto bare = LuaState.open(false);
    assert(bare.getGlobal!LuaValue("print").isNil());
    assert(bare.getGlobal!LuaValue("assert").isNil());
    assert(bare.getGlobal!LuaValue("string").isNil());
    assert(bare.getGlobal!LuaValue("table").isNil());
    assert(bare.getGlobal!LuaValue("math").isNil());
    bare.openLibraries(LuaLib.base);
    assert(!bare.getGlobal!LuaValue("print").isNil());
    bare.doString("assert(type(print) == 'function')");

    // LuaLib.all matches the default set for the active Lua version.
    auto all = LuaState.open(LuaLib.all);
    all.doString("assert(io and os and math and string and table and package)");
    version (LUAJIT)
        all.doString("assert(bit and jit)");
    else static if (LUA_VERSION_NUM == 502)
        all.doString("assert(bit32)");
    else static if (LUA_VERSION_NUM >= 503)
        all.doString("assert(utf8)");

    // GC controls.
    minimal.gcCollect();
    assert(minimal.gcBytes() > 0);
    assert(minimal.gcCount() >= 0);
    assert(minimal.gcIsRunning());

    minimal.gcStop();
    version (LUAJIT)
        assert(!minimal.gcIsRunning());
    else static if (LUA_VERSION_NUM >= 502)
        assert(!minimal.gcIsRunning());

    minimal.gcRestart();
    assert(minimal.gcIsRunning());

    minimal.gcSetPause(150);
    minimal.gcSetStepMul(150);
    minimal.gcStep(1);
    assert(minimal.gcBytes() > 0);
}

unittest
{
    // Raw lua_CFunction callbacks read the Lua stack directly, which is the
    // escape hatch for C-style variadic arguments.
    auto L = LuaState.open();

    auto rawSumFn = toLua!(lunarbind.rawfixture.rawSum)(L, "raw_sum");
    assert(rawSumFn.call!int(1, 2, 3) == 6);
    assert(L.getGlobal!LuaFunction("raw_sum").call!int() == 0);

    // registerFunction and registerLibrary accept raw callbacks too.
    registerFunction!(lunarbind.rawfixture.rawArgumentCount)(L, "raw_count");
    assert(L.getGlobal!LuaFunction("raw_count").call!int("a", "b") == 2);
    registerLibrary!("count", lunarbind.rawfixture.rawArgumentCount)(L, "rawlib");
    assert(L.getGlobal!LuaTable("rawlib")
            .get!LuaFunction("count").call!int(1, 2, 3, 4) == 4);

    // Runtime function pointers take the raw path as well.
    registerDelegate(L, "raw_ptr", &lunarbind.rawfixture.rawSum);
    assert(L.getGlobal!LuaFunction("raw_ptr").call!int(7, 8) == 15);

    // Module binding and LuaModule composition include raw callbacks.
    auto rawModule = registerModule!(lunarbind.rawfixture)(L, "raw_module");
    assert(rawModule.get!LuaFunction("rawSum").call!int(5, 6) == 11);

    // Typed overloads are preferred; the raw callback handles the rest.
    auto rawMixed = rawModule.get!LuaFunction("mixed");
    assert(rawMixed.call!int(4) == 8);
    assert(rawMixed.call!int("x") == -1);

    LuaModule.create(L)
        .addFunction!(lunarbind.rawfixture.rawSum)("sum")
        .addFunction!(lunarbind.rawfixture.rawArgumentCount)("count")
        .setGlobal("raw_tools");
    L.doString("
        assert(raw_tools.sum(1, 2, 3) == 6)
        assert(raw_tools.count('a', 'b') == 2)
    ");

    // Raw callbacks appear in stubs as Lua varargs.
    auto rawStub = luaStubs!(lunarbind.rawfixture.rawSum)();
    assert(rawStub.canFind("---@vararg any"));
    assert(rawStub.canFind("function rawSum(...) end"));
    auto rawModuleStub = luaStubs!(lunarbind.rawfixture)();
    assert(rawModuleStub.canFind("function rawfixture.rawSum(...) end"));
    assert(rawModuleStub.canFind(
        "function rawfixture.rawArgumentCount(...) end"));
    // A mixed set keeps the typed overload signature and the raw fallback.
    assert(rawModuleStub.canFind(
        "---@overload fun(value: integer): integer"));
    assert(rawModuleStub.canFind("function rawfixture.mixed(...) end"));
}

// Compile-time only: these bodies must stay @nogc so the primitive stack,
// table and state paths never allocate. They are intentionally not called.
private void nogcProbe(LuaState L, LuaTable t, LuaFunction f, LuaRef r,
                       LuaValue v, int i, double d, bool b, string s,
                       void* p, Nullable!int n, LuaString ls,
                       const(char)[] cs) @nogc
{
    L.push(i);
    L.push(d);
    L.push(b);
    L.push(s);
    L.push(p);
    L.push(n);
    L.push(ls);
    L.push(cs);
    L.pop(8);

    L.top();
    L.setTop(0);
    L.pushValue(-1);
    L.absIndex(-1);
    L.checkStack(1);
    L.typeOf(-1);
    L.protectedCall(0, 0, 0);
    L.gcCollect();
    L.gcBytes();
    L.setGlobal("answer", 42);

    t.setUnchecked("x", i);
    t.setUnchecked(1, s);
    t.push();
    t.length();

    f.push();
    f.ref_();

    r.push();
    r.ref_();
    r.isNull();

    v.pushUnchecked(L);

    auto copy = L;
    auto main = L.mainState();
    copy.isOpen();
    copy = main;
}

unittest
{
    // `pushUnchecked` is the allocation-free push path; `push` adds the
    // cross-state ownership check.
    auto L = LuaState.open();
    auto t = LuaTable.create(L);
    t.set("answer", 42);

    auto intValue = t.get!LuaValue("answer");
    intValue.pushUnchecked(L);
    assert(L.get!int(-1) == 42);
    L.pop();

    auto tableValue = LuaValue(LuaType.table, t.ref_());
    tableValue.pushUnchecked(L);
    assert(L.typeOf(-1) == LuaType.table);
    L.pop();

    auto stringValue = LuaValue.fromString("hi");
    stringValue.pushUnchecked(L);
    assert(L.get!string(-1) == "hi");
    L.pop();

    // The checked variant still rejects values from another state.
    auto other = LuaState.open();
    bool threw;
    try
        tableValue.push(other);
    catch (LuaStateException)
        threw = true;
    assert(threw);
}

unittest
{
    // Dispatch errors name the symbol and the supplied Lua argument types.
    auto L = LuaState.open();

    auto addFn = toLua!add(L, "add");
    bool sawArity;
    try
        addFn.call!int(1);
    catch (LuaException e)
        sawArity = e.msg.canFind(
            "add: expected between 2 and 2 arguments, got 1 argument");
    assert(sawArity);

    auto fx = registerModule!(lunarbind.exportfixture)(L, "fx");
    bool sawModule;
    try
        fx.get!LuaFunction("fixtureAdd").call!int("x", 1);
    catch (LuaException e)
    {
        // Lua 5.1/5.2/LuaJIT have no integer subtype, so the numeric
        // argument is reported as `number` there.
        sawModule = e.msg.canFind("no matching overload for fixtureAdd(string, ")
                 && (e.msg.canFind("integer)") || e.msg.canFind("number)"));
    }
    assert(sawModule);

    toLua!Player(L);
    auto player = new Player(10, "bob");
    toLua!player(L);

    bool sawCtor;
    try
        L.doString("return Player('x')");
    catch (LuaException e)
        sawCtor = e.msg.canFind(
            "no matching constructor for Player(string)");
    assert(sawCtor);

    bool sawMethod;
    try
        L.doString("player:damage('x')");
    catch (LuaException e)
        sawMethod = e.msg.canFind(
            "no matching overload for Player.damage(string)");
    assert(sawMethod);

    toLua!AutoBound(L);
    bool sawStatic;
    try
        L.doString("AutoBound.overloaded(true)");
    catch (LuaException e)
        sawStatic = e.msg.canFind(
            "no matching overload for AutoBound.overloaded(boolean)");
    assert(sawStatic);
}

unittest
{
    // Internal class metatable metadata is accessed raw. Lua code can reach
    // these tables through the debug library, and a metatable it attaches must
    // not run __index/__newindex while D frames are active.
    auto L = LuaState.open();

    auto player = new Player(10, "raw");
    LuaClass!Player.setGlobal(L, "player", player);

    L.doString(`
        local m = debug.getmetatable(player)
        assert(m.__lunarbind_identity ~= nil)
        m.__lunarbind_identity = nil
        setmetatable(m, {
            __index = function() error('tampered identity index') end,
            __newindex = function() error('tampered identity newindex') end,
        })
    `);

    // The identity table is recreated with raw access; no metamethod runs.
    LuaClass!Player.push(L, player);
    L.pop(1);

    // The base-metatable list is read raw for derived instances.
    auto dog = new Dog("rex");
    LuaClass!Dog.setGlobal(L, "dog", dog);
    LuaClass!Animal.registerClass(L);

    L.doString(`
        local m = debug.getmetatable(dog)
        assert(m.__lunarbind_bases ~= nil)
        m.__lunarbind_bases = nil
        setmetatable(m, {
            __index = function() error('tampered bases index') end,
            __newindex = function() error('tampered bases newindex') end,
        })
    `);

    LuaClass!Dog.push(L, dog);
    assert(!LuaClass!Animal.isInstance(L, -1));
    L.pop(1);
}

unittest
{
    // Lua errors longjmp out of callbacks, so every temporary LuaState must be
    // destroyed before lua_error runs; otherwise its reference leaks.
    auto L = LuaState.open();
    toLua!Player(L);
    toLua!AutoBound(L);
    toLua!Vec(L);
    auto player = new Player(10, "bob");
    toLua!player(L);
    auto fx = registerModule!(lunarbind.exportfixture)(L, "fx");

    auto before = L.referenceCount();

    void expectError(string code)
    {
        bool threw;
        try
            L.doString(code);
        catch (LuaException)
            threw = true;
        assert(threw, code);
        assert(L.referenceCount() == before, code);
    }

    expectError("return Player('x')");          // constructor
    expectError("player:damage('x')");          // instance method
    expectError("AutoBound.overloaded(true)");  // static method
    expectError("return fx.fixtureAdd('x', 1)"); // module function
    expectError("player.unknown = 1");          // unknown field
    expectError("return Vec(1) + 2");           // binary operator
    expectError("return Vec(1) < 2");           // comparison
}

unittest
{
    // Table operations validate the receiver before entering Lua's
    // unprotected error path.
    auto L = LuaState.open();
    auto fn = toLua!add(L, "add");
    auto bogus = fn.ref_().asTable();

    bool threw;
    try
        bogus.get!int("x");
    catch (LuaTypeException e)
        threw = e.msg.canFind("expected table, got function");
    assert(threw);

    threw = false;
    try
        bogus.set("x", 1);
    catch (LuaTypeException)
        threw = true;
    assert(threw);

    bool found;
    threw = false;
    try
        bogus.tryGet!int("x", found);
    catch (LuaTypeException)
        threw = true;
    assert(threw);

    threw = false;
    try
        bogus.opApply((LuaValue key, LuaValue value) => 0);
    catch (LuaTypeException)
        threw = true;
    assert(threw);
}

unittest
{
    // Closed and default-initialized handles fail with typed errors instead of
    // dereferencing a null or stale lua_State pointer.
    auto L = LuaState.open();
    L.close();
    assert(!L.isOpen());
    assert(L.handle is null);

    void expectClosed(void delegate() action, string what)
    {
        bool threw;
        try
            action();
        catch (LuaStateException)
            threw = true;
        assert(threw, what);
    }

    expectClosed({ L.loadString("return 1"); }, "loadString");
    expectClosed({ L.eval("return 1"); }, "eval");
    expectClosed({ L.globals(); }, "globals");
    expectClosed({ L.typeName(1); }, "typeName");
    expectClosed({ LuaTable.create(L); }, "table create");

    LuaTable table;
    assert(table.state().handle is null);
    expectClosed({ table.get!int("x"); }, "table get");
    expectClosed({ table.set("x", 1); }, "table set");
    expectClosed({ table.opApply((LuaValue key, LuaValue value) => 0); },
                 "table opApply");

    LuaFunction fn;
    expectClosed({ fn.call!int(); }, "function call");

    LuaRef ref_;
    assert(ref_.state().handle is null);
    assert(ref_.isNull());
    assert(ref_.ref_() == 0);
    expectClosed({ ref_.type(); }, "ref type");
    expectClosed({ ref_.asValue(); }, "ref value");
    expectClosed({ ref_.pushInto(L); }, "ref pushInto");
    expectClosed({ LuaRef.make(L, -1); }, "ref make");

    // LuaValue's checked paths reject a closed state; pushUnchecked stays raw.
    auto closedValue = LuaValue.fromInteger(1);
    expectClosed({ closedValue.push(L); }, "value push");
    expectClosed({ LuaValue.fromStack(L, 1); }, "value fromStack");

    // Registration and binding entry points check the state before touching
    // the raw lua_State pointer.
    expectClosed({ registerFunction!add(L, "closed_add"); },
                 "registerFunction");
    expectClosed({ registerLibrary!("add", add)(L, "closed_lib"); },
                 "registerLibrary");
    expectClosed({ toLua!Player(L); }, "toLua type");
    expectClosed({ toLua(L, 1, "closed_value"); }, "toLua value");
    expectClosed({ LuaClass!Player.setGlobal(L, "closed_player", null); },
                 "class setGlobal");
    expectClosed({ LuaStruct!Point.push(L, Point(1, 2)); },
                 "struct push");
    expectClosed({ LuaTable.createWeak(L, LuaWeakness.keys); },
                 "table createWeak");

    LuaModule closedModule;
    expectClosed({ closedModule.set("x", 1); }, "module set");
    expectClosed({ closedModule.setGlobal("closed_module"); },
                 "module setGlobal");
    expectClosed({ closedModule.push(); }, "module push");
}

unittest
{
    // Converting an error value must survive a failing __tostring metamethod:
    // the conversion itself runs under pcall instead of longjmping out of D.
    auto L = LuaState.open();
    bool threw;
    try
        L.doString(
            "error(setmetatable({}, " ~
            "{__tostring = function() error('boom') end}))");
    catch (LuaException e)
    {
        threw = true;
        assert(e.msg.length > 0);
    }
    assert(threw);
}

unittest
{
    // Metamethod errors in table get/set become D exceptions, and invalid
    // keys are rejected before lua_settable can raise.
    auto L = LuaState.open();
    L.doString(`
        t = setmetatable({}, {
            __index = function(_, k) return "default:" .. k end,
            __newindex = function(t, k, v) rawset(t, k, v) end,
        })
        bad = setmetatable({}, {
            __index = function() error("no index") end,
            __newindex = function() error("no newindex") end,
        })
    `);

    auto t = L.getGlobal!LuaTable("t");
    assert(t.get!string("missing") == "default:missing");
    t.set("x", 42);
    assert(t.get!int("x") == 42);

    auto bad = L.getGlobal!LuaTable("bad");
    bool threw;
    try
        bad.get!int("x");
    catch (LuaException e)
        threw = e.msg.canFind("no index");
    assert(threw);

    threw = false;
    try
        bad.set("x", 1);
    catch (LuaException e)
        threw = e.msg.canFind("no newindex");
    assert(threw);

    bool found;
    threw = false;
    try
        bad.tryGet!int("x", found);
    catch (LuaException e)
        threw = e.msg.canFind("no index");
    assert(threw);

    threw = false;
    try
        t.set(LuaValue(), 1);
    catch (LuaArgumentException e)
        threw = e.msg.canFind("nil");
    assert(threw);

    threw = false;
    try
        t.set(double.nan, 1);
    catch (LuaArgumentException e)
        threw = e.msg.canFind("NaN");
    assert(threw);
}

unittest
{
    // opApply copies keys through the registry between protected steps.
    auto L = LuaState.open();
    auto t = LuaTable.create(L);
    t.set("a", "1");
    t.set("b", "2");

    string keys;
    int count;
    assert(t.opApply((LuaValue key, LuaValue value) {
        keys ~= key.stringValue;
        ++count;
        return 0;
    }) == 0);
    assert(count == 2);
    assert(keys.canFind("a") && keys.canFind("b"));

    count = 0;
    assert(t.opApply((LuaValue key, LuaValue value) {
        ++count;
        return 1; // break
    }) == 1);
    assert(count == 1);
}

unittest
{
    // Globals access protects _G __index/__newindex metamethods.
    auto L = LuaState.open();
    L.doString(`
        setmetatable(_G, {
            __index = function(_, k)
                if k == "missing_global" then error("no global") end
                return nil
            end,
            __newindex = function(t, k, v)
                if k == "blocked_global" then error("blocked global") end
                rawset(t, k, v)
            end,
        })
    `);

    bool threw;
    try
        L.getGlobal!int("missing_global");
    catch (LuaException e)
        threw = e.msg.canFind("no global");
    assert(threw);

    threw = false;
    try
        L.setGlobalChecked("blocked_global", 1);
    catch (LuaException e)
        threw = e.msg.canFind("blocked global");
    assert(threw);

    L.setGlobalChecked("allowed_global", 7);
    assert(L.getGlobal!int("allowed_global") == 7);

    // Registration helpers use the checked path too.
    threw = false;
    try
        toLua!add(L, "blocked_global");
    catch (LuaException e)
        threw = e.msg.canFind("blocked global");
    assert(threw);

    // The raw fast path still bypasses the check.
    L.setGlobal("raw_global", 3);
    assert(L.getGlobal!int("raw_global") == 3);
}

unittest
{
    // Opening a library after tampering with _G must raise instead of aborting.
    auto L = LuaState.open(LuaLib.base);
    L.doString(`
        setmetatable(_G, {
            __newindex = function() error("library blocked") end,
        })
    `);

    bool threw;
    try
        L.openLibraries(LuaLib.string);
    catch (LuaException e)
        threw = e.msg.canFind("library blocked");
    assert(threw);
}

unittest
{
    // AA conversion protects lua_next: a codec that removes the current key
    // turns the next step into a LuaException instead of a longjmp out of D.
    auto L = LuaState.open();
    L.doString(`
        aaTable = { a = 1, b = 2, c = 3 }
        function remove_key(k)
            rawset(aaTable, k, nil)
            -- Force a rehash so the dead key node is discarded.
            for i = 1, 100 do aaTable['x' .. i] = i end
        end
    `);

    registerCodec!MutatingKey(L, LuaCodec!MutatingKey(
        (LuaState s, ref const MutatingKey v) { pushTo(s, v.name); },
        (LuaState s, int idx) {
            auto name = popFrom!string(s, idx);
            s.getGlobal!LuaFunction("remove_key").call(name);
            return MutatingKey(name);
        },
        (LuaState s, int idx) => lua_type(s.handle, idx) == LUA_TSTRING));
    scope(exit) unregisterCodec!MutatingKey(L);

    bool threw;
    try
        L.getGlobal!(int[MutatingKey])("aaTable");
    catch (LuaException e)
        threw = e.msg.canFind("invalid key to 'next'");
    assert(threw);
}

unittest
{
    // Structs with GC-managed fields register their Lua-owned box as a GC
    // range and remove it again from __gc. This exercises both the rooting
    // path and the druntime-compatible removeRange call.
    auto L = LuaState.open();
    auto original = NamedValue("lunarbind".idup, 42);
    LuaStruct!NamedValue.setGlobal(L, "named_value", original);

    auto back = LuaStruct!NamedValue.getGlobal(L, "named_value");
    assert(back.name == original.name);
    assert(back.value == original.value);

    // Replace the global and collect so the old box's __gc handler runs.
    LuaStruct!NamedValue.setGlobal(L, "named_value",
                                   NamedValue("replacement".idup, 7));
    L.gcCollect();
    L.gcCollect();

    auto latest = LuaStruct!NamedValue.getGlobal(L, "named_value");
    assert(latest.name == "replacement");
    assert(latest.value == 7);
}
