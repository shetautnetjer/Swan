"""Shapes with a small class hierarchy: the cases for find_implementations."""

from abc import ABC, abstractmethod


class Shape(ABC):
    @abstractmethod
    def area(self) -> float:
        ...


class Square(Shape):
    def __init__(self, side: float) -> None:
        self.side = side

    def area(self) -> float:
        return self.side * self.side


class Circle(Shape):
    def __init__(self, radius: float) -> None:
        self.radius = radius

    def area(self) -> float:
        return 3.14159 * self.radius * self.radius


def total_area(shapes: list[Shape]) -> float:
    return sum(s.area() for s in shapes)
