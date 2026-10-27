// Breaks a fixture copy on purpose and checks that get_diagnostics finds the
// damage where an engineer would look: in the callers of what changed.
//
//   bun tests/diag_check.ts

import { cpSync, rmSync } from "node:fs";

const work = "data/diag-check";
rmSync(work, { recursive: true, force: true });
cpSync("fixtures/tiny-ts", `${work}/repo`, { recursive: true });
const sh = (cmd: string[]) => {
  const r = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe" });
  if (r.exitCode !== 0) throw new Error(`${cmd.join(" ")}: ${r.stderr}`);
  return r.stdout.toString();
};
const db = `${work}/map/swan.db`;
sh(["scripts/index-repo.sh", `${work}/repo`, `${work}/map`]);
sh(["scripts/diagnose-repo.sh", `${work}/repo`, `${work}/map`]);
const q = (...a: string[]) => JSON.parse(sh(["bin/swan", "query", db, ...a]));

let failures = 0;
const check = (what: string, ok: boolean, detail: unknown = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok ? "" : `\n     ${JSON.stringify(detail).slice(0, 600)}`}`);
  if (!ok) failures++;
};

const clean = q("diagfile", "src");
check("the untouched fixture has no errors", clean.map_total.errors === 0, clean);

// The change: Store.total now needs an argument, so its callers break.
const edit = Bun.spawnSync(["bin/swan", "serve", db], {
  stdin: Buffer.from(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "replace_symbol_body",
    arguments: { name_path: "Store/total", relative_path: "src/store.ts",
      body: "total(cap: number): number {\n    let sum = 0;\n    for (const item of this.items.values()) sum += item.weight;\n    return Math.min(sum, cap);\n  }" } } }) + "\n"),
  stdout: "pipe",
});
check("the edit went in", !JSON.parse(edit.stdout.toString()).result.isError);

const before = q("diag", "Store/total", "src/store.ts");
check("before rechecking, get_diagnostics shows nothing new and marks store.ts entries stale if any",
  before.diagnostics.every((d: any) => d.relative_path !== "src/store.ts" || d.stale));

sh(["scripts/diagnose-repo.sh", `${work}/repo`, `${work}/map`]);
const after = q("diag", "Store/total", "src/store.ts");
const where = after.diagnostics.map((d: any) => `${d.in_symbol}@${d.distance}`);
check("after the check, the errors show up in the callers, at distance 1: report, CappedStore.total (super.total()) and main.ts's top level",
  ["report", "CappedStore/total", "main.ts"].every((s) =>
    after.diagnostics.some((d: any) => d.in_symbol === s && d.distance === 1 && d.code === "TS2554")), where);
check("summary, two steps out, has no errors of its own, so it is not listed",
  !after.diagnostics.some((d: any) => d.in_symbol === "summary"), where);
const all = q("diagfile", "src");
check("the whole-map view lists every error, with the symbol it is in",
  all.map_total.errors >= 2 && all.diagnostics.every((d: any) => d.severity && d.message), all.map_total);

// Rust, through cargo check: Tile::new gains a parameter, so the test that
// calls it breaks.
const rs = `${work}/rs`;
cpSync("fixtures/tiny-rs", `${rs}/repo`, { recursive: true });
sh(["scripts/index-repo.sh", `${rs}/repo`, `${rs}/map`]);
const lib = `${rs}/repo/src/lib.rs`;
await Bun.write(lib, (await Bun.file(lib).text()).replace("pub fn new(side: u32) -> Tile", "pub fn new(side: u32, _scale: u32) -> Tile"));
sh(["scripts/diagnose-repo.sh", `${rs}/repo`, `${rs}/map`]);
const rsDiag = JSON.parse(sh(["bin/swan", "query", `${rs}/map/swan.db`, "diag", "Tile/new", "src/lib.rs"]));
check("cargo check's error lands in the caller of Tile::new (the test fn tiles, found through the vec! macro), marked stale-free after the check",
  rsDiag.diagnostics.some((d: any) => d.severity === "error" && d.in_symbol === "tiles" && d.distance === 1 && !d.stale),
  rsDiag.diagnostics);

// A checker that fails without checking (cargo exits 101 when a dependency
// will not resolve) leaves the saved errors as they were.
const toml = `${rs}/repo/Cargo.toml`;
const tomlText = await Bun.file(toml).text();
await Bun.write(toml, tomlText + (tomlText.includes("[dependencies]") ? "" : "\n[dependencies]\n") +
  "missing-dep = { path = \"../does-not-exist\" }\n");
const broken = Bun.spawnSync(["bin/swan", "check", `${rs}/repo`, `${rs}/map`], { stdout: "pipe", stderr: "pipe" });
await Bun.write(toml, tomlText);
const kept = JSON.parse(sh(["bin/swan", "query", `${rs}/map/swan.db`, "diag", "Tile/new", "src/lib.rs"]));
check("a cargo that fails without checking keeps the saved errors and says so",
  broken.stdout.toString().includes("could not check") &&
  kept.diagnostics.some((d: any) => d.severity === "error" && d.in_symbol === "tiles"),
  broken.stdout.toString() + broken.stderr.toString().slice(-300));

console.log(failures ? `${failures} check(s) failed` : "all diagnostics checks passed");
process.exit(failures ? 1 : 0);
