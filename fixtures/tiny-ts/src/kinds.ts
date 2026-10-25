import { Store } from "./store";

// Two implementations of one interface, and a subclass that overrides a
// method: the cases for find_implementations and get_type_hierarchy.
export interface Weighed {
  weigh(): number;
}

export class Box implements Weighed {
  weigh(): number {
    return 2;
  }
}

export class Crate implements Weighed {
  weigh(): number {
    return 5;
  }
}

export class CappedStore extends Store {
  total(): number {
    return Math.min(super.total(), 10);
  }
}
