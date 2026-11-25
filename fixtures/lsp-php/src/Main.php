<?php
namespace App;

function report(Shape $shape): float
{
    return $shape->area();
}

function onlyCircle(Circle $c): string
{
    return $c->describe();
}

function onlySquare(Square $s): string
{
    return $s->describe();
}

function main(): void
{
    $c = new Circle(1.0);
    $s = new Square(2.0);
    echo onlyCircle($c);
    echo onlySquare($s);
    echo report($c);
    echo report($s);
}
