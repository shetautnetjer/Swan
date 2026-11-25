<?php
namespace App;

interface Shape
{
    public function area(): float;
}

class Circle implements Shape
{
    public function __construct(private float $r)
    {
    }

    public function area(): float
    {
        return 3.14 * $this->r * $this->r;
    }

    public function describe(): string
    {
        return "circle";
    }
}

class Square implements Shape
{
    public function __construct(private float $s)
    {
    }

    public function area(): float
    {
        return $this->s * $this->s;
    }

    public function describe(): string
    {
        return "square";
    }
}
