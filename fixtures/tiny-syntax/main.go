package main

import "fmt"

type Greeter struct {
	name string
}

func (g *Greeter) Greet() string {
	return "hi " + g.name
}

func main() {
	g := &Greeter{name: "swan"}
	fmt.Println(g.Greet(), helper(2))
}
