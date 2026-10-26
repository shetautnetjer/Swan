package shapes;

import java.util.List;

public final class Shapes {
    private Shapes() {}

    public static double totalArea(List<Shape> shapes) {
        double total = 0;
        for (Shape s : shapes) {
            total += s.area();
        }
        return total;
    }

    public static void main(String[] args) {
        System.out.println(totalArea(List.of(new Square(2), new Circle(1))));
    }
}
