export interface Item {
  id: string;
  weight: number;
}

export const DEFAULT_WEIGHT = 1;

export class Store {
  private items = new Map<string, Item>();

  add(id: string, weight = DEFAULT_WEIGHT): Item {
    const item: Item = { id, weight };
    this.items.set(id, item);
    return item;
  }

  get(id: string): Item | undefined {
    return this.items.get(id);
  }

  total(): number {
    let sum = 0;
    for (const item of this.items.values()) sum += item.weight;
    return sum;
  }
}

export function makeStore(): Store {
  return new Store();
}
