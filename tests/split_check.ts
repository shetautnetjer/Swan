// Checks that splitting an indexer's work changes nothing: a generated
// TypeScript project with references across files is mapped once in a
// single scip-typescript run (SWAN_JOBS=1) and once split into chunks
// (SWAN_JOBS=4), and the two maps must hold the same rows.
//
//   bun tests/split_check.ts

import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { Database } from "bun:sqlite";

const w = "data/split-check";
rmSync(w, { recursive: true, force: true });
mkdirSync(`${w}/repo/src`, { recursive: true });
writeFileSync(`${w}/repo/tsconfig.json`, JSON.stringify({ compilerOptions: { strict: true, noEmit: true, module: "esnext", moduleResolution: "bundler" }, include: ["src/**/*"] }));
writeFileSync(`${w}/repo/src/types.d.ts`, "declare interface Shared { id: number }\n");
for (let i = 0; i < 24; i++) {
  const prev = i > 0 ? `import { f${i - 1} } from "./m${i - 1}";\n` : "";
  const call = i > 0 ? `f${i - 1}(n) + ` : "";
  writeFileSync(`${w}/repo/src/m${i}.ts`,
    `${prev}export interface Box${i} { value: number; inner: { depth: number } }\n` +
    `export function f${i}(n: number): number {\n  const s: Shared = { id: n };\n  return ${call}s.id;\n}\n` +
    `export const box${i}: Box${i} = { value: f${i}(${i}), inner: { depth: ${i} } };\n`);
}
const sh = (cmd: string[], env: Record<string, string>) => {
  const r = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe", env: { ...process.env, ...env } });
  if (r.exitCode !== 0) throw new Error(`${cmd.join(" ")}: ${r.stderr}`);
  return r.stdout.toString();
};
const single = sh(["bin/swan", "map", `${w}/repo`, `${w}/single`], { SWAN_JOBS: "1" });
const split = sh(["bin/swan", "map", `${w}/repo`, `${w}/split`], { SWAN_JOBS: "4" });
const rows = (db: string) => {
  const d = new Database(db, { readonly: true });
  const r = d.query(`SELECT s.scip, o.file, o.start_line, o.start_col, o.is_def, e.scip AS enc
                     FROM occurrences o JOIN symbols s ON s.id = o.symbol_id LEFT JOIN symbols e ON e.id = o.enclosing_id
                     ORDER BY 2, 3, 4, 1`).all().map((x: any) => Object.values(x).join("|"));
  d.close();
  return r;
};
const a = rows(`${w}/single/swan.db`), b = rows(`${w}/split/swan.db`);
let failures = 0;
const check = (what: string, ok: boolean, detail = "") => { console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok ? "" : `\n     ${detail}`}`); if (!ok) failures++; };
check("the split map ran more than one scip-typescript", /scip-typescript \d+\/\d+/.test(split), split);
const onlyA = a.filter((x) => !b.includes(x)), onlyB = b.filter((x) => !a.includes(x));
check(`split and single maps hold the same ${a.length} rows`, onlyA.length === 0 && onlyB.length === 0,
  `${onlyA.slice(0, 3).join("\n     ")}\n     vs\n     ${onlyB.slice(0, 3).join("\n     ")}`);
console.log(failures ? `${failures} check(s) failed` : "all split checks passed");
process.exit(failures ? 1 : 0);
