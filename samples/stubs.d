module stubs;

import lunarbind;
import std.stdio : writeln;

@LuaExport("Player")
class Player
{
    @LuaExport("hp")
    int health;

    @LuaExport(skip: true)
    int internalState;

    this(int health)
    {
        this.health = health;
    }

    @LuaExport("damage")
    void takeDamage(int amount)
    {
        health -= amount;
    }

    @LuaExport("create")
    static Player create(int health)
    {
        return new Player(health);
    }
}

@LuaExport("Vec")
struct Vec
{
    @LuaExport("x") double x;
    @LuaExport("y") double y;

    @LuaExport("length")
    double length() const
    {
        return x + y;
    }

    @LuaExport("origin")
    static Vec origin()
    {
        return Vec(0, 0);
    }
}

@LuaExport("Status")
enum Status
{
    @LuaExport("ok") success,
    @LuaExport("failed") failure,
    @LuaExport(skip: true) legacy,
}

// Player and Vec are not listed below; they are discovered from World's field
// and method signature.
@LuaExport("World")
class World
{
    @LuaExport("player") Player player;

    @LuaExport("spawn") Vec spawn(double x, double y)
    {
        return Vec(x, y);
    }
}

int add(int a, int b = 1)
{
    return a + b;
}

void main()
{
    // No Lua state is needed: stub generation only inspects D symbols.
    writeln(luaStubs!(World, Status, add)());
}
