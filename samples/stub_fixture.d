/// Annotated API shared by the stub sample and the stub generator tool.
module samples.stub_fixture;

import lunarbind;

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

// A type with a custom registerCodec representation. The generator declares it
// as a plain table instead of a struct class; the sample also demonstrates the
// default declaration without an override.
struct Packed
{
    int value;
}

// Player and Vec are not listed explicitly; they are discovered from World's
// field and method signatures.
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
