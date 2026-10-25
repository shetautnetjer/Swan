import { makeStore, formatItem } from "./index";
import { total } from "./format";
import { DEFAULT_WEIGHT, type Item } from "./store";

const store = makeStore();
const a = store.add("a");
const b = store.add("b", DEFAULT_WEIGHT * 2);
console.log(formatItem(a), formatItem(b), store.total());
const list: Item[] = [a, b];
console.log(total(list), store.get("a"));
