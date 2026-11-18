package main

import "fmt"

// Emit writes one generated line.
func Emit(name string) string {
	return "// generated: " + name
}

func main() {
	fmt.Println(Emit("shapes"))
}
