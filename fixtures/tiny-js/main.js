// Plain JavaScript using both.
import { add, Counter } from "./math.mjs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { double } = require("./legacy.cjs");

const c = new Counter();
c.bump();
console.log(add(1, 2), double(c.bump()));
