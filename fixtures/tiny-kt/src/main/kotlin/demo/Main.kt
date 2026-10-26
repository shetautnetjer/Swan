package demo

fun report(shapes: List<Shape>): String {
    val names = shapes.map { it.describe() }
    println("shapes: ${names.size}")
    return names.joinToString("\n")
}

fun main() {
    val shapes = listOf(Square(2.0), Circle(1.0))
    println(report(shapes))
    println(totalArea(shapes))
    val first = shapes.firstOrNull()!!
    println(first.area())
}
