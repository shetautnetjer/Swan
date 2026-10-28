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
