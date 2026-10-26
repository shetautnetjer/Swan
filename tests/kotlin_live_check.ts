// Kotlin end to end: maps a copy of fixtures/tiny-kt (scip-java through its
// Gradle build), checks the map, then asks JetBrains' Kotlin language server
// for diagnostics before and after an edit. The
// first run imports the Gradle build (Gradle fetches itself and the Kotlin
// plugin into .tools/gradle-home), which takes minutes; later runs reuse it.
//
//   bun tests/kotlin_live_check.ts

import { cpSync, existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";

if (!existsSync(".tools/kotlin-lsp")) { console.log("skipped: no .tools/kotlin-lsp (scripts/fetch-tools.sh)"); process.exit(0); }
rmSync("data/kt-live", { recursive: true, force: true });
cpSync("fixtures/tiny-kt", "data/kt-live/repo", { recursive: true });
const m = Bun.spawnSync(["bin/swan", "map", "data/kt-live/repo", "data/kt-live/out"], { stdout: "pipe", stderr: "pipe" });
if (m.exitCode !== 0) throw new Error(`swan map: ${m.stderr}`);

const proc = Bun.spawn(["bin/swan", "serve", "data/kt-live/out/swan.db"], { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
const reader = proc.stdout.getReader();
let buf = "";
let id = 0;
async function tool(name: string, args: any) {
  const t0 = performance.now();
  proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: ++id, method: "tools/call", params: { name, arguments: args } }) + "\n");
  while (!buf.includes("\n")) { const { value, done } = await reader.read(); if (done) throw new Error("serve closed"); buf += new TextDecoder().decode(value); }
  const line = buf.slice(0, buf.indexOf("\n")); buf = buf.slice(buf.indexOf("\n") + 1);
  const r = JSON.parse(line).result;
  const ms = performance.now() - t0;
  console.log(`  ${name} ${JSON.stringify(args)}: ${ms.toFixed(0)} ms`);
  return { ok: !r.isError, body: JSON.parse(r.content[0].text), ms };
}


let failures = 0;
const check = (what: string, ok: boolean, detail: unknown = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok ? "" : `\n     ${JSON.stringify(detail).slice(0, 600)}`}`);
  if (!ok) failures++;
};
// The map itself: scip-java through the repo's Gradle build.
const q = (...a: string[]) => JSON.parse(Bun.spawnSync(["bin/swan", "query", "data/kt-live/out/swan.db", ...a], { stdout: "pipe" }).stdout.toString());
check("kotlin map: Square and Circle implement Shape",
  q("impls", "Shape").implementations.map((s: any) => s.name_path).sort().join(",") === "Circle,Square");
check("kotlin map: main calls totalArea",
  q("callers", "totalArea").callers.some((c: any) => c.name_path === "main"));

const rel = "src/main/kotlin/demo/Main.kt";
const file = `data/kt-live/repo/${rel}`;
const orig = readFileSync(file, "utf8");
const clean = await tool("get_diagnostics", { relative_path: rel, live: true });
check("kotlin: the clean file has no errors (the first call imports the Gradle build)",
  clean.ok && !clean.body.import_failed && clean.body.diagnostics.every((d: any) => d.severity !== "error"), clean.body);
writeFileSync(file, orig.replace("println(totalArea(shapes))", "val x: Int = \"text\"\n    println(totalArea(shapes))"));
const broken = await tool("get_diagnostics", { relative_path: rel, live: true });
check("kotlin: a String assigned to an Int is an error on the new line",
  broken.ok && broken.body.diagnostics.some((d: any) => d.severity === "error" && d.line === 12), broken.body);
writeFileSync(file, orig);
const fixed = await tool("get_diagnostics", { relative_path: rel, live: true });
check("kotlin: gone again after the undo", fixed.ok && fixed.body.diagnostics.every((d: any) => d.severity !== "error"), fixed.body);
proc.stdin.end();
await proc.exited;
check("serve exits cleanly", proc.exitCode === 0);
console.log(failures ? `${failures} check(s) failed` : "all kotlin live checks passed");
process.exit(failures ? 1 : 0);
