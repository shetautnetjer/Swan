import type { Item } from "./store";

export function format(item: Item): string {
  return `${item.id}:${item.weight}`;
}

// Same name as the method on Store, to check that they stay apart.
export function total(items: Item[]): number {
  return items.reduce((n, i) => n + i.weight, 0);
}
