namespace Game;

/// <summary>Something that can take damage: the cases for implementations.</summary>
public interface IDamageable
{
    int Health { get; }
    void Hit(int damage);
}

public class Player : IDamageable
{
    public int Health { get; private set; } = 100;
    public void Hit(int damage) { Health -= damage; }
}

public class Crate : IDamageable
{
    public int Health { get; private set; } = 10;
    public void Hit(int damage) { Health = 0; }
}

public static class Combat
{
    public static int Strike(IDamageable target, int damage)
    {
        target.Hit(damage);
        return target.Health;
    }
}

public class Arena
{
    public int Round(Player hero, Crate box)
    {
        Combat.Strike(box, 5);
        return Combat.Strike(hero, 1);
    }
}

public static class Tricks
{
    // An expression body: its call to Strike belongs to Finish.
    public static int Finish(Crate box) => Combat.Strike(box, 99);

    // A verbatim string ending in a backslash, then a string holding a brace.
    public static string SavePath()
    {
        var dir = @"C:\saves\";
        return dir + "}" + """raw " } """;
    }
}

public class Spawner
{
    public Spawner(System.Func<int> make) { }
}

public class Boss : Spawner
{
    // A lambda in the constructor initializer is not an expression body.
    public Boss() : base(() => 1)
    {
        Combat.Strike(new Crate(), 2);
        Combat.Strike(new Player(), 3);
    }
}
