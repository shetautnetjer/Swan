#!/usr/bin/env bash
greet() {
  echo "hello $1"
}

loud_greet() {
  greet "$1" | tr a-z A-Z
}

loud_greet world
