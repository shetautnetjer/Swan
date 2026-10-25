from shapes import Circle, Square, total_area


def report() -> str:
    return f"total {total_area([Square(2), Circle(1)]):.2f}"


if __name__ == "__main__":
    print(report())
