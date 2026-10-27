// Edits a copy of the fixture through the MCP tools, then checks:
// the files say what the edits asked for, tsc still compiles the copy, a
// rename skipped the alias and refused a conflict, a stale file was refused,
// and the positions Swan shifted itself match a fresh SCIP run afterwards.
//
//   bun tests/edit_check.ts

import { cpSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { Database } from "bun:sqlite";

const work = "data/edit-check";
rmSync(work, { recursive: true, force: true });
cpSync("fixtures/tiny-ts", `${work}/repo`, { recursive: true });
// Two definitions on one line, and a class whose replacement drops a method.
writeFileSync(`${work}/repo/src/oneline.ts`, `export function one() { return 1; } export function two() { return 2; }

export class Pair {
  left(): number { return 1; }
  right(): number { return 2; }
}
`);
const sh = (cmd: string[]) => {
  const r = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`${cmd.join(" ")}: ${r.stderr}`);
  return r.stdout.toString();
};
sh(["scripts/index-repo.sh", `${work}/repo`, `${work}/map`]);

const proc = Bun.spawn(["bin/swan", "serve", `${work}/map/swan.db`], { stdin: "pipe", stdout: "pipe" });
const reader = proc.stdout.getReader();
let buf = "", id = 0;
async function call(name: string, args: Record<string, unknown>) {
  proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: ++id, method: "tools/call", params: { name, arguments: args } }) + "\n");
  while (!buf.includes("\n")) buf += new TextDecoder().decode((await reader.read()).value);
  const i = buf.indexOf("\n");
  const msg = JSON.parse(buf.slice(0, i));
  buf = buf.slice(i + 1);
  const text = msg.result.content[0].text;
  return { error: msg.result.isError as boolean, text, json: (() => { try { return JSON.parse(text); } catch { return null; } })() };
}

let failures = 0;
const check = (what: string, ok: boolean, detail = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok || !detail ? "" : `\n     ${detail}`}`);
  if (!ok) failures++;
};
const file = (p: string) => readFileSync(`${work}/repo/${p}`, "utf8");

// 1. Replace a method body: two lines longer than before.
const total = await call("replace_symbol_body", {
  name_path: "Store/total", relative_path: "src/store.ts",
  body: `total(): number {
    let sum = 0;
    for (const item of this.items.values()) {
      sum += item.weight;
    }
    return sum;
  }`,
});
check("replace_symbol_body Store/total", !total.error && file("src/store.ts").includes("sum += item.weight;\n    }"), total.text);

// 2. Insert a method after Store/get, inside the class.
const has = await call("insert_after_symbol", {
  name_path: "Store/get", relative_path: "src/store.ts",
  body: `  has(id: string): boolean {
    return this.items.has(id);
  }`,
});
check("insert_after_symbol Store/get adds Store.has inside the class",
  !has.error && /get\(id: string\)[\s\S]*\n  }\n\n  has\(id: string\): boolean/.test(file("src/store.ts")), has.text);

// run_tests opens the map on its own; edits afterwards must still see files as fresh.
await call("run_tests", { relative_path: "src/store.ts" });

// 3. Insert a function before makeStore. Its position must have followed edits 1 and 2.
const empty = await call("insert_before_symbol", {
  name_path: "makeStore", relative_path: "src/store.ts",
  body: `export function emptyStore(): Store {\n  return new Store();\n}`,
});
check("insert_before_symbol makeStore lands right above it, after the earlier edits moved it",
  !empty.error && file("src/store.ts").includes("export function emptyStore(): Store {\n  return new Store();\n}\n\nexport function makeStore()"), empty.text);
check("an edit reports who uses the symbol", empty.json?.used_by?.references > 0, empty.text);

// 4. Rename: plan, conflict, apply.
const plan = await call("rename_symbol", { name_path: "format", relative_path: "src/format.ts", new_name: "formatEntry" });
check("rename plan lists the definition and the re-export, and skips the formatItem alias uses",
  !plan.error && plan.json.sites.length === 2 && plan.json.skipped.length >= 2 && plan.json.applied === false &&
  readFileSync(`${work}/repo/src/format.ts`, "utf8").includes("function format("), plan.text);
const clash = await call("rename_symbol", { name_path: "Store/add", relative_path: "src/store.ts", new_name: "get", apply: true });
check("rename onto an existing sibling is refused as a conflict",
  clash.error && clash.json?.conflicts?.[0]?.name_path === "Store/get" && !file("src/store.ts").includes("get(\"a\")"), clash.text);
const done = await call("rename_symbol", { name_path: "format", relative_path: "src/format.ts", new_name: "formatEntry", apply: true });
check("rename applied: definition and re-export renamed, alias kept",
  !done.error && file("src/format.ts").includes("function formatEntry(") &&
  file("src/index.ts").includes("export { formatEntry as formatItem }") && file("src/main.ts").includes("formatItem(a)"), done.text);
const after = await call("find_symbol", { name_path_pattern: "formatEntry" });
check("the map follows the rename", after.json?.[0]?.name_path === "formatEntry", after.text);

// 4b. Names a language would not accept are refused before anything is written.
for (const bad of ["123abc", "foo-bar"]) {
  const r = await call("rename_symbol", { name_path: "makeStore", relative_path: "src/store.ts", new_name: bad, apply: true });
  check(`rename to '${bad}' is refused`, r.error && r.text.includes("must be an identifier") && file("src/store.ts").includes("makeStore"), r.text);
}

// 4c. Two definitions on one line: lengthening the first moves the second's columns.
const one = await call("replace_symbol_body", { name_path: "one", relative_path: "src/oneline.ts",
  body: "export function one() { const x = 1; return x; }" });
const two = await call("replace_symbol_body", { name_path: "two", relative_path: "src/oneline.ts",
  body: "export function two() { return 22; }" });
check("an edit after a same-line edit lands on its own symbol",
  !one.error && !two.error && file("src/oneline.ts").startsWith("export function one() { const x = 1; return x; } export function two() { return 22; }\n"),
  `${one.text}\n     ${two.text}\n     ${file("src/oneline.ts").split("\n")[0]}`);

// 4d. Replacing a class with fewer methods: the dropped one is gone from the map.
const pair = await call("replace_symbol_body", { name_path: "Pair", relative_path: "src/oneline.ts",
  body: "export class Pair {\n  left(): number { return 1; }\n}" });
const gone = await call("replace_symbol_body", { name_path: "Pair/right", relative_path: "src/oneline.ts",
  body: "right(): number { return 3; }" });
check("a method dropped by replacing its class can no longer be edited",
  !pair.error && gone.error && gone.text.includes("no symbol matches") && !file("src/oneline.ts").includes("return 3"), gone.text);

// 5. A file changed behind Swan's back is refused.
const kinds = `${work}/repo/src/kinds.ts`;
const st = statSync(kinds);
utimesSync(kinds, st.atime, new Date(Date.now() + 60_000));
const stale = await call("replace_symbol_body", { name_path: "Box/weigh", relative_path: "src/kinds.ts", body: "weigh(): number { return 3; }" });
check("an edit to a file changed outside Swan is refused", stale.error && stale.text.includes("changed since the map was built"), stale.text);
utimesSync(kinds, st.atime, st.mtime);

// Swan's own positions, before a fresh SCIP run checks them.
proc.stdin.end();
await proc.exited;
const positions = (db: string) => {
  const d = new Database(db, { readonly: true });
  const rows = d.query(`SELECT name_path, def_file, def_line, def_col, body_start, body_end FROM symbols
                        WHERE in_repo = 1 AND kind NOT IN ('parameter','module') ORDER BY 1, 2`).all() as any[];
  d.close();
  return new Map(rows.map((r) => [`${r.def_file} ${r.name_path}`, r]));
};
const shifted = positions(`${work}/map/swan.db`);

// 6. The edited copy still compiles.
const tsc = Bun.spawnSync(["tools/node_modules/.bin/tsc", "--noEmit", "-p", `${work}/repo`], { stdout: "pipe" });
check("tsc --noEmit passes on the edited copy", tsc.exitCode === 0, tsc.stdout.toString());

// 7. A fresh SCIP run agrees with every position Swan shifted itself.
sh(["scripts/refresh-repo.sh", `${work}/repo`, `${work}/map`]);
const fresh = positions(`${work}/map/swan.db`);
const wrong: string[] = [];
for (const [k, v] of shifted) {
  const f = fresh.get(k);
  if (!f) continue;     // renamed or replaced: compared below by name
  for (const c of ["def_line", "def_col", "body_start", "body_end"])
    if (v[c] !== f[c]) wrong.push(`${k} ${c} swan ${v[c]} scip ${f[c]}`);
}
check(`shifted positions match a fresh SCIP run (${shifted.size} symbols compared)`, wrong.length === 0, wrong.slice(0, 5).join("\n     "));
check("after the refresh the new code is mapped: Store/has and emptyStore",
  fresh.has("src/store.ts Store/has") && fresh.has("src/store.ts emptyStore"));

console.log(failures ? `${failures} check(s) failed` : "all edit checks passed");
process.exit(failures ? 1 : 0);
