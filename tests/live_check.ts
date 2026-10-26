// The live adapter end to end: maps a copy of fixtures/tiny-rs, starts
// `swan serve`, and asks rust-analyzer (through the swan-lsp library) for
// diagnostics and implementations before and after edits the map has not
// seen.
//
//   bun tests/live_check.ts

import { cpSync, readFileSync, rmSync, writeFileSync } from "node:fs";

const repo = "data/live-rs/repo";
const out = "data/live-rs/out";
rmSync("data/live-rs", { recursive: true, force: true });
cpSync("fixtures/tiny-rs", repo, { recursive: true });
const m = Bun.spawnSync(["bin/swan", "map", repo, out], { stdout: "pipe", stderr: "pipe" });
if (m.exitCode !== 0) throw new Error(`swan map: ${m.stderr}`);

const proc = Bun.spawn(["bin/swan", "serve", `${out}/swan.db`], { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
const reader = proc.stdout.getReader();
const dec = new TextDecoder();
let buffered = "";
async function nextLine(): Promise<string> {
  while (!buffered.includes("\n")) {
    const { value, done } = await reader.read();
    if (done) throw new Error("server closed stdout");
    buffered += dec.decode(value);
  }
  const i = buffered.indexOf("\n");
  const line = buffered.slice(0, i);
  buffered = buffered.slice(i + 1);
  return line;
}
let nextId = 1;
async function tool(name: string, args: Record<string, unknown>): Promise<{ ok: boolean; body: any; ms: number }> {
  const id = nextId++;
  const t0 = performance.now();
  proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } }) + "\n");
  const msg = JSON.parse(await nextLine());
  const ms = performance.now() - t0;
  const text = msg.result.content[0].text;
  let body: any = text;
  try { body = JSON.parse(text); } catch {}
  console.log(`  ${name} ${JSON.stringify(args)}: ${ms.toFixed(0)} ms`);
  return { ok: !msg.result.isError, body, ms };
}

let failures = 0;
const check = (what: string, ok: boolean, detail: unknown = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok ? "" : `\n     ${JSON.stringify(detail)}`}`);
  if (!ok) failures++;
};

const lib = `${repo}/src/lib.rs`;
const original = readFileSync(lib, "utf8");

const clean = await tool("get_diagnostics", { relative_path: "src/lib.rs", live: true });
check("live diagnostics on the clean crate: no errors (first call starts rust-analyzer)",
  clean.ok && clean.body.diagnostics.every((d: any) => d.severity !== "error"), clean.body);

const impls = await tool("find_implementations", { name_path: "Area", live: true });
const at = (b: any) => (b.implementations ?? []).map((i: any) => `${i.relative_path}:${i.line}`).sort();
check("live implementations of Area: the two impl blocks, lines 23 and 29",
  impls.ok && at(impls.body).join(",") === "src/lib.rs:23,src/lib.rs:29", impls.body);

// An edit the map has not seen: a wrong argument count.
writeFileSync(lib, original.replace("Tile::new(2).area()", "Tile::new(2, 3).area()"));
const broken = await tool("get_diagnostics", { relative_path: "src/lib.rs", live: true });
const errs = broken.ok ? broken.body.diagnostics.filter((d: any) => d.severity === "error") : [];
check("after the edit: E0061 on line 56, without a map or check run",
  errs.some((d: any) => d.code === "E0061" && d.line === 56), broken.body);
console.log(`     error seen ${broken.ms.toFixed(0)} ms after asking`);

writeFileSync(lib, original);
const fixed = await tool("get_diagnostics", { relative_path: "src/lib.rs", live: true });
check("after undoing it: the error is gone",
  fixed.ok && fixed.body.diagnostics.every((d: any) => d.severity !== "error"), fixed.body);

// A new implementation the map does not know.
writeFileSync(lib, original + "\npub struct Ring;\n\nimpl Area for Ring {\n    fn area(&self) -> u32 {\n        0\n    }\n}\n");
const more = await tool("find_implementations", { name_path: "Area", live: true });
check("a new impl Area for Ring shows up live", at(more.body).includes("src/lib.rs:62"), more.body);
const mapped = await tool("find_implementations", { name_path: "Area" });
check("while the map still has the two it was built with",
  mapped.body.implementations.map((s: any) => s.name_path).sort().join(",") === "Disc,Tile", mapped.body);
writeFileSync(lib, original);

const java = await tool("get_diagnostics", { relative_path: "src/Missing.java", live: true });
check("a language without a live server says so instead of failing hard", !java.ok && /no live server/.test(java.body), java.body);

// Switching language: pyright replaces rust-analyzer in the same serve.
cpSync("fixtures/tiny-py", `${repo}/py`, { recursive: true });
const pyFile = `${repo}/py/shapes/__init__.py`;
const pyOrig = readFileSync(pyFile, "utf8");
const pyClean = await tool("get_diagnostics", { relative_path: "py/shapes/__init__.py", live: true });
check("pyright: the clean module has no errors",
  pyClean.ok && pyClean.body.diagnostics.every((d: any) => d.severity !== "error"), pyClean.body);
writeFileSync(pyFile, pyOrig + "\n\ndef broken() -> int:\n    return \"text\"\n");
const pyBroken = await tool("get_diagnostics", { relative_path: "py/shapes/__init__.py", live: true });
check("pyright: a str returned as int is an error on the new line",
  pyBroken.ok && pyBroken.body.diagnostics.some((d: any) => d.severity === "error" && d.line === 33), pyBroken.body);
console.log(`     error seen ${pyBroken.ms.toFixed(0)} ms after asking`);
writeFileSync(pyFile, pyOrig);
const pyFixed = await tool("get_diagnostics", { relative_path: "py/shapes/__init__.py", live: true });
check("pyright: gone again after the undo",
  pyFixed.ok && pyFixed.body.diagnostics.every((d: any) => d.severity !== "error"), pyFixed.body);

// And the TypeScript server after pyright.
cpSync("fixtures/tiny-ts", `${repo}/ts`, { recursive: true });
const tsFile = `${repo}/ts/src/store.ts`;
const tsOrig = readFileSync(tsFile, "utf8");
const tsClean = await tool("get_diagnostics", { relative_path: "ts/src/store.ts", live: true });
check("typescript: the clean file has no errors",
  tsClean.ok && tsClean.body.diagnostics.every((d: any) => d.severity !== "error"), tsClean.body);
const tsLines = tsOrig.split("\n").length;
writeFileSync(tsFile, tsOrig + "\nexport const broken: number = \"text\";\n");
const tsBroken = await tool("get_diagnostics", { relative_path: "ts/src/store.ts", live: true });
check("typescript: a string assigned to a number is TS2322 on the new line",
  tsBroken.ok && tsBroken.body.diagnostics.some((d: any) => d.code === "2322" && d.line === tsLines + 1), tsBroken.body);
console.log(`     error seen ${tsBroken.ms.toFixed(0)} ms after asking`);
writeFileSync(tsFile, tsOrig);

proc.stdin.end();
await proc.exited;
check("serve exits cleanly and stops rust-analyzer", proc.exitCode === 0);
console.log(failures ? `${failures} check(s) failed` : "all live checks passed");
process.exit(failures ? 1 : 0);
