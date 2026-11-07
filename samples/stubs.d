module stubs;

import lunarbind;
import std.stdio : writeln;

@LuaExport("Player", "A player-controlled character.")
class Player
{
    @LuaExport("hp", "Current hit points.")
    int health;

    @LuaExport(skip: true)
    int internalState;

    this(int health)
    {
        this.health = health;
    }

    @LuaExport("damage", "Reduces hit points.")
    void takeDamage(int amount)
    {
        health -= amount;
    }

    @LuaExport("create", "Creates a player at full health.")
    static Player create(int health)
    {
        return new Player(health);
    }
}

@LuaExport("Vec", "A two-dimensional vector.")
struct Vec
{
    @LuaExport("x", "Horizontal component.")
    double x;

    @LuaExport("y", "Vertical component.")
    double y;

    @LuaExport("length", "Sum of the components.")
    double length() const
    {
        return x + y;
    }

    @LuaExport("origin", "The zero vector.")
    static Vec origin()
    {
        return Vec(0, 0);
    }
}

@LuaExport("Status", "Player states.")
enum Status
{
    @LuaExport("ok", "Active.") success,
    @LuaExport("failed", "Inactive.") failure,
    @LuaExport(skip: true) legacy,
}

// A type with a custom registerCodec representation. In generated stubs it is
// declared as a plain table instead of a struct class (see main).
struct Packed
{
    int value;
}

// Player and Vec are not listed below; they are discovered from World's field
// and method signature.
@LuaExport("World", "Demo world.")
class World
{
    @LuaExport("player", "The active player.")
    Player player;

    @LuaExport("packed", "Encoded as a plain table.")
    Packed packed;

    @LuaExport("spawn", "Creates a vector at the given position.")
    Vec spawn(double x, double y)
    {
        return Vec(x, y);
    }
}

@LuaExport("add", "Adds two integers.")
int add(int a, int b = 1)
{
    return a + b;
}

void main()
{
    // No Lua state is needed: stub generation only inspects D symbols.
    writeln(luaStubs!(World, Status, add)());

    // A custom codec representation overrides the generated type; the default
    // struct declaration is then omitted.
    LuaStubBuilder builder;
    builder.setType!Packed("table");
    builder.addClass!World();
    writeln(builder.toString());
}
