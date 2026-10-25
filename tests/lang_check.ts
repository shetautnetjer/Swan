// One check per language fixture beyond the TypeScript and Rust ones that
// have their own tests: each is mapped with scripts/index-repo.sh and asked
// the questions an engineer would ask first.
//
//   bun tests/lang_check.ts [js|python|java|cuda ...]   (default: all)

const sh = (cmd: string[], env: Record<string, string> = {}) => {
  const r = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe", env: { ...process.env, ...env } });
  if (r.exitCode !== 0) throw new Error(`${cmd.join(" ")}: ${r.stderr}`);
  return r.stdout.toString();
};
let failures = 0;
const check = (what: string, ok: boolean, detail: unknown = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok ? "" : `\n     ${JSON.stringify(detail).slice(0, 600)}`}`);
  if (!ok) failures++;
};
const mapOf = (fixture: string) => {
  sh(["scripts/index-repo.sh", `fixtures/${fixture}`, `data/${fixture}`]);
  return (...a: string[]) => JSON.parse(sh(["bin/swan", "query", `data/${fixture}/swan.db`, ...a]));
};
const sites = (d: any[]) => d.flatMap((s: any) => s.references.map((r: any) => `${r.relative_path}:${r.line}`));
const want = new Set(process.argv.slice(2));
const run = (lang: string) => want.size === 0 || want.has(lang);

if (run("js")) {
  // No tsconfig: Swan generates one outside the repo, with allowJs.
  const q = mapOf("tiny-js");
  check("js: add() from math.mjs is used in main.js and in math.mjs itself",
    sites(q("refs", "add")).sort().join(",") === "main.js:2,main.js:9,math.mjs:11", sites(q("refs", "add")));
  check("js: double() from legacy.cjs reaches main.js through require()", sites(q("refs", "double")).includes("main.js:9"));
  check("js: Counter.bump is a method", q("symbol", "Counter/bump")[0]?.kind === "method");
  check("js: the repo was not written to (no tsconfig.json appeared)", !(await Bun.file("fixtures/tiny-js/tsconfig.json").exists()));
}

console.log(failures ? `${failures} check(s) failed` : "all language checks passed");
process.exit(failures ? 1 : 0);
