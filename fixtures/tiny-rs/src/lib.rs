//! A small crate with the Rust cases Swan's tests need: a trait with two
//! implementations, an enum whose variants are used through paths, and uses
//! hidden inside nested macro calls.

#[derive(Debug, PartialEq)]
pub enum Shape {
    Square(u32),
    Circle(u32),
}

pub trait Area {
    fn area(&self) -> u32;
}

pub struct Tile {
    pub side: u32,
}

pub struct Disc {
    pub radius: u32,
}

impl Area for Tile {
    fn area(&self) -> u32 {
        self.side * self.side
    }
}

impl Area for Disc {
    fn area(&self) -> u32 {
        3 * self.radius * self.radius
    }
}

impl Tile {
    pub fn new(side: u32) -> Tile {
        Tile { side }
    }
}

pub fn shapes() -> Vec<Shape> {
    vec![Shape::Square(2), Shape::Circle(1)]
}

pub fn first_is_square() -> bool {
    matches!(shapes().first(), Some(Shape::Square(_)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tiles() {
        assert!(matches!(shapes()[1], Shape::Circle(1)));
        assert_eq!(vec![Tile::new(2).area()], vec![4]);
    }
}
