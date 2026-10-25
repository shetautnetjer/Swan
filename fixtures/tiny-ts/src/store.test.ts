import { makeStore } from "./store";
import { summary } from "./report";

// Not run by anything; it is here so Swan can tell test code from the rest.
export function testSummary(): boolean {
  const store = makeStore();
  store.add("x", 3);
  return summary(store) === "[total weight 3]";
}
