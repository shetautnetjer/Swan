// An ES module (.mjs).
export function add(a, b) {
  return a + b;
}

export class Counter {
  constructor() {
    this.n = 0;
  }
  bump() {
    this.n = add(this.n, 1);
    return this.n;
  }
}
