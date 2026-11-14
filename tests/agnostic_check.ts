// Repos shaped the way strangers' repos are: Swan has to map them from cold,
// with nothing installed into them. Found by a cold test on public repos
// (2026-11-14), where these shapes gave no map or no cross-file answers.
//
//   tiny-syntax     Go, shell (one script known only by its #! line) and a
//                   Makefile: no SCIP indexer here, so the syntax map answers.
//   tiny-srcpy      a Python "src layout": tests import the package that
//                   lives under src/, which is never installed.
//   tiny-ts-badcfg  a tsconfig that extends a shared config from an npm
//                   package that is not installed.
//
//   bun tests/agnostic_check.ts

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const sh = (cmd: string[]) => {
  const r = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe" });
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
};
let failures = 0;
const check = (what: string, ok: boolean, detail: unknown = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok ? "" : `\n     ${JSON.stringify(detail).slice(0, 800)}`}`);
  if (!ok) failures++;
};
const work = mkdtempSync(join(tmpdir(), "swan-agnostic-"));
const mapOf = (fixture: string) => {
  const out = join(work, fixture);
  const m = sh(["bin/swan", "map", resolve(`fixtures/${fixture}`), out]);
  const q = (...a: string[]) => JSON.parse(sh(["bin/swan", "query", join(out, "swan.db"), ...a]).out);
  return { report: m.out + m.err, code: m.code, q };
};
const lines = (xs: any[]) => xs.map((s: any) => `${s.relative_path}:${s.line}`).sort().join(",");
const sitesOf = (d: any) => d.callers.filter((c: any) => c.distance === 1).flatMap((c: any) => c.call_sites ?? []);

try {
  const syn = mapOf("tiny-syntax");
  check("tiny-syntax: Go, shell and Make map (no 'no language found')", syn.code === 0 && syn.report.includes("syntax-index"), syn.report);
  check("Go: helper() is defined in helper.go", lines(syn.q("symbol", "helper")) === "helper.go:4", syn.q("symbol", "helper"));
  check("Go: helper() is called from main in main.go, at line 15",
    lines(sitesOf(syn.q("callers", "helper"))) === "main.go:15", syn.q("callers", "helper"));
  check("Go: Greeter/Greet is a method of Greeter", syn.q("symbol", "Greeter/Greet")[0]?.kind === "method", syn.q("symbol", "Greeter/Greet"));
  check("shell: greet is called inside loud_greet, by name",
    syn.q("callers", "greet").callers.some((c: any) => c.name_path.endsWith("loud_greet") &&
      lines(c.call_sites) === "util/run.sh:7"), syn.q("callers", "greet"));
  check("shell: a script with no extension (bin/tool) is read by its #! line",
    lines(syn.q("symbol", "usage")) === "bin/tool:3", syn.q("symbol", "usage"));
  check("shell: top-level code calling usage counts, at bin/tool:6",
    lines(sitesOf(syn.q("callers", "usage"))) === "bin/tool:6", syn.q("callers", "usage"));
  check("Make: the build target needs deps", lines(sitesOf(syn.q("callers", "deps"))) === "Makefile:1", syn.q("callers", "deps"));
  const refs = syn.q("refs", "helper");
  check("syntax references say they were found by name",
    refs[0]?.references?.length > 0 && refs[0].references.every((r: any) => r.by_name === true), refs);

  const py = mapOf("tiny-srcpy");
  check("src layout: tests' `tinypkg.add(...)` reaches src/tinypkg/core.py's add",
    lines(sitesOf(py.q("callers", "add"))).includes("tests/test_core.py:5"), py.q("callers", "add"));

  const sub = py.q("impls", "IOError");
  check("subclasses of IOError (an alias of OSError) are found", lines(sub.implementations) === "src/tinypkg/core.py:5", sub);

  const ts = mapOf("tiny-ts-badcfg");
  check("unreadable tsconfig: the map is built with Swan's own config and says so",
    ts.code === 0 && ts.report.includes("tsconfig.json cannot be read"), ts.report);
  check("unreadable tsconfig: shout() is used in b.ts at line 3",
    lines(sitesOf(ts.q("callers", "shout"))) === "src/b.ts:3", ts.q("callers", "shout"));
} finally {
  rmSync(work, { recursive: true, force: true });
}
if (failures) { console.log(`${failures} check(s) failed`); process.exit(1); }
console.log("all checks passed");
