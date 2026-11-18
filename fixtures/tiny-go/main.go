package main

import (
	"fmt"

	"example.com/tiny/shapes"
)

func main() {
	fmt.Println(shapes.TotalArea([]shapes.Shape{shapes.Square{Side: 2}}))
}
