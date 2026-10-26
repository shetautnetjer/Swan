package demo

/** Something with an area: the cases for implementations. */
interface Shape {
    fun area(): Double
}

data class Square(val side: Double) : Shape {
    override fun area(): Double = side * side
}

class Circle(private val radius: Double) : Shape {
    override fun area(): Double {
        return 3.14159 * radius * radius
    }
}

fun totalArea(shapes: List<Shape>): Double = shapes.sumOf { it.area() }

fun Shape.describe(): String = "${this::class.simpleName} of area ${area()}"
