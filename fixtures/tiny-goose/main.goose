// A two-file Goose program: main imports a module that only compiles as part of it.
import std;
import os;
import .shapes;

let UNIT = 2;

fn main() {
    print(str(area(3)));
}
