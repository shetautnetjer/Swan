// Tools that run a repo's own build files wait for `swan trust`. Checked
// here without SWAN_TRUST_BUILD: an untrusted C# repo maps without
// scip-dotnet and writes no obj/, its live server waits, a trust record
// shipped inside the map folder is ignored, an index from before is not
// reused once the repo is trusted, and an unchecked Rust repo keeps its
// saved diagnostics.
//
//   bun tests/trust_check.ts

import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

let failures = 0;
const check = (what: string, ok: boolean, detail: unknown = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok ? "" : `\n     ${JSON.stringify(detail).slice(0, 700)}`}`);
  if (!ok) failures++;
};

const untrusted = { ...process.env };
delete untrusted.SWAN_TRUST_BUILD;
const trustedEnv = { ...untrusted, SWAN_TRUST_BUILD: "1" };
const run = (env: Record<string, string | undefined>, ...a: string[]) =>
  Bun.spawnSync(["bin/swan", ...a], { env, stdout: "pipe", stderr: "pipe" });
const trustFile = "data/trusted-repos";
const before = existsSync(trustFile) ? readFileSync(trustFile, "utf8") : null;

if (existsSync(".tools/dotnet-tools/scip-dotnet") && existsSync(".tools/dotnet-tools/csharp-ls")) {
  const dir = "data/trust-check/cs";
  rmSync(dir, { recursive: true, force: true });
  cpSync("fixtures/tiny-cs", `${dir}/repo`, { recursive: true });
  const repo = resolve(`${dir}/repo`), out = `${dir}/out`;
  const callers = () => JSON.parse(run(untrusted, "query", `${out}/swan.db`, "callers", "Strike").stdout.toString()).callers.length;

  // A full map first (trusted for this one run), so a stale index exists.
  run(trustedEnv, "map", repo, out);
  check("trusted C#: the full map has callers", callers() === 3, callers());
  rmSync(`${dir}/repo/obj`, { recursive: true, force: true });
  rmSync(`${dir}/repo/bin`, { recursive: true, force: true });

  // A trust record the map folder ships (it could sit inside the checkout).
  writeFileSync(`${out}/trusted`, `${repo}\n`);
  const m = run(untrusted, "map", repo, out).stdout.toString();
  check("untrusted C#: the map skips scip-dotnet and says how to trust the repo",
    m.includes("not run: scip-dotnet") && m.includes(`swan trust ${repo}`), m);
  check("untrusted C#: a trust record in the map folder is ignored", m.includes("not run:"), m);
  check("untrusted C#: dotnet restore did not run (no obj/)", !existsSync(`${dir}/repo/obj`));
  check("untrusted C#: the map has no callers", callers() === 0, callers());

  const ask = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call",
    params: { name: "get_diagnostics", arguments: { relative_path: "src/Program.cs", live: true } } }) + "\n";
  const live = Bun.spawnSync(["bin/swan", "serve", `${out}/swan.db`], { env: untrusted, stdin: new TextEncoder().encode(ask), stdout: "pipe" }).stdout.toString();
  check("untrusted C#: the live server waits for swan trust", live.includes("swan trust "), live.slice(0, 600));

  const t = run(untrusted, "trust", repo).stdout.toString();
  check("swan trust records the repo in Swan's own data", readFileSync(trustFile, "utf8").split("\n").includes(repo), t);
  const m2 = run(untrusted, "map", repo, out).stdout.toString();
  check("after swan trust the map runs scip-dotnet again rather than reusing the old index",
    !m2.includes("not run:") && !m2.includes("scip-dotnet: reused") && callers() === 3, m2);
} else console.log("skipped C#: no .tools/dotnet-tools (csharp-ls, scip-dotnet)");

// Rust unchecked: its saved diagnostics stay while the Python check runs.
{
  const dir = "data/trust-check/rs";
  rmSync(dir, { recursive: true, force: true });
  cpSync("fixtures/tiny-rs", `${dir}/repo`, { recursive: true });
  writeFileSync(`${dir}/repo/helper.py`, "def helper() -> int:\n    return 1\n");
  const repo = resolve(`${dir}/repo`), out = `${dir}/out`;
  run(untrusted, "map", repo, out);
  const saved = "src/lib.rs\t0\t0\t0\t1\terror\tcargo\tE0061\ta saved cargo error\n";
  mkdirSync(out, { recursive: true });
  writeFileSync(`${out}/diagnostics.tsv`, saved);
  const c = run(untrusted, "check", repo, out);
  const after = existsSync(`${out}/diagnostics.tsv`) ? readFileSync(`${out}/diagnostics.tsv`, "utf8") : "";
  const report = c.stdout.toString() + c.stderr.toString();
  check("untrusted Rust: cargo check is skipped and says so", report.includes("not run: cargo check"), report.slice(0, 600));
  check("untrusted Rust: the saved cargo diagnostics are kept", after.includes("a saved cargo error"), after.slice(0, 600));
}

// A virtualenv inside an untrusted repo is the repo's own code: its python must not run, and it
// must not be put on PATH for indexers. The planted interpreter leaves a marker if anything runs it.
{
  const dir = "data/trust-check/venv";
  rmSync(dir, { recursive: true, force: true });
  cpSync("fixtures/tiny-py", `${dir}/repo`, { recursive: true });
  const repo = resolve(`${dir}/repo`), out = `${dir}/out`;
  const marker = resolve(`${dir}/venv-python-ran`);
  mkdirSync(`${dir}/repo/.venv/bin`, { recursive: true });
  writeFileSync(`${dir}/repo/.venv/pyvenv.cfg`, "home = /usr/bin\n");
  const fake = `#!/bin/sh\necho ran >> ${marker}\nexec python3 "$@"\n`;
  for (const n of ["python", "python3", "pip"]) writeFileSync(`${dir}/repo/.venv/bin/${n}`, fake, { mode: 0o755 });
  const m = run(untrusted, "map", repo, out);
  check("untrusted repo: mapping never runs its virtualenv's python, pip or PATH entries",
    !existsSync(marker), (m.stdout.toString() + m.stderr.toString()).slice(0, 600));
  check("untrusted repo: the map is still built (python indexed with the system interpreter)",
    existsSync(`${out}/swan.db`), m.stdout.toString().slice(0, 400));
  run(untrusted, "check", repo, out);
  check("untrusted repo: swan check never runs its virtualenv either", !existsSync(marker));
  const t = run(trustedEnv, "map", repo, out);
  check("trusted repo: its virtualenv is used", existsSync(marker), t.stdout.toString().slice(0, 400));
}

// Leave Swan's trust list as it was.
if (before === null) rmSync(trustFile, { force: true }); else writeFileSync(trustFile, before);
console.log(failures ? `${failures} check(s) failed` : "all trust checks passed");
process.exit(failures ? 1 : 0);
