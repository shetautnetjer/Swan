import unittest

from shapes import Square, total_area


class ShapeTests(unittest.TestCase):
    def test_square(self) -> None:
        self.assertEqual(total_area([Square(3)]), 9)


if __name__ == "__main__":
    unittest.main()
