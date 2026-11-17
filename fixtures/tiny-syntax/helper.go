package main

// helper is called from main in another file of the same package.
func helper(n int) int {
	return n * 2
}

// scaled has a parameter list over several lines, as gofmt writes long ones.
func scaled(
	n int,
	factor int,
) int {
	return n * factor
}
