import { makeStore } from "./store";

// A test runner takes each test body as a callback, as vitest, jest and
// node:test do. The body is anonymous, so a use inside it sits at top level.
function it(title: string, body: () => void): string { body(); return title; }

it("adds an item", () => {
  const store = makeStore();
  store.add("y");
});
