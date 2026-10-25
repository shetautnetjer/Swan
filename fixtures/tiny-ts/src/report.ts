import type { Store } from "./store";

// A short call chain for the impact tools: summary -> report -> Store.total.
export function report(store: Store): string {
  return `total weight ${store.total()}`;
}

export function summary(store: Store): string {
  return `[${report(store)}]`;
}
