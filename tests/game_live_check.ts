// Live errors from the language servers added for game and 3D code: Lua
// (lua-language-server), the GLSL, HLSL and WGSL shaders (shader-validator's
// server), C++ (clangd), C# (csharp-ls) and Blender Python (pyright with
// Blender's stubs). Each fixture is mapped from a copy, checked clean, given
// a deliberate error, checked again, and put back. For C#, the full map from
// scip-dotnet is checked too.
//
//   SWAN_TRUST_BUILD=1 bun tests/game_live_check.ts   (scripts/test.sh sets it)

import { cpSync, existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";

let failures = 0;
const check = (what: string, ok: boolean, detail: unknown = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok ? "" : `\n     ${JSON.stringify(detail).slice(0, 700)}`}`);
  if (!ok) failures++;
};

async function session(fixture: string, cases: { file: string; label: string; edit: (s: string) => string; want: (d: any[]) => boolean }[],
                       from = `fixtures/${fixture}`, prepare?: (repo: string) => void) {
  const dir = `data/game-live/${fixture}`;
  rmSync(dir, { recursive: true, force: true });
  cpSync(from, `${dir}/repo`, { recursive: true });
  if (prepare) prepare(`${dir}/repo`);
  const m = Bun.spawnSync(["bin/swan", "map", `${dir}/repo`, `${dir}/out`], { stdout: "pipe", stderr: "pipe" });
  if (m.exitCode !== 0) { check(`${fixture}: swan map`, false, m.stdout.toString() + m.stderr.toString()); return; }
  const proc = Bun.spawn(["bin/swan", "serve", `${dir}/out/swan.db`], { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
  const reader = proc.stdout.getReader();
  let buf = "";
  let id = 0;
  const diags = async (rel: string) => {
    const t0 = performance.now();
    proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: ++id, method: "tools/call", params: { name: "get_diagnostics", arguments: { relative_path: rel, live: true } } }) + "\n");
    while (!buf.includes("\n")) { const { value, done } = await reader.read(); if (done) throw new Error("serve closed"); buf += new TextDecoder().decode(value); }
    const line = buf.slice(0, buf.indexOf("\n")); buf = buf.slice(buf.indexOf("\n") + 1);
    const r = JSON.parse(line).result;
    let body: any = r.content[0].text;
    try { body = JSON.parse(body); } catch {}
    return { ok: !r.isError, body, ms: performance.now() - t0 };
  };
  for (const c of cases) {
    const path = `${dir}/repo/${c.file}`;
    const orig = readFileSync(path, "utf8");
    const clean = await diags(c.file);
    const errs = (b: any) => (b.diagnostics ?? []).filter((d: any) => d.severity === "error");
    check(`${c.label}: the clean file has no errors (${clean.ms.toFixed(0)} ms)`, clean.ok && errs(clean.body).length === 0, clean.body);
    writeFileSync(path, c.edit(orig));
    const broken = await diags(c.file);
    check(`${c.label}: the deliberate error is reported (${broken.ms.toFixed(0)} ms)`, broken.ok && c.want(errs(broken.body)), broken.body);
    writeFileSync(path, orig);
    const fixed = await diags(c.file);
    check(`${c.label}: gone after the undo`, fixed.ok && errs(fixed.body).length === 0, fixed.body);
  }
  proc.stdin.end();
  await proc.exited;
  check(`${fixture}: serve exits cleanly`, proc.exitCode === 0);
}

const have = (p: string) => existsSync(`.tools/${p}`);
if (have("lua-ls")) {
  await session("tiny-lua", [{ file: "game.lua", label: "Lua", edit: (s) => s.replace("hero:hit(10)", "hero:hit(10"),
    want: (d) => d.length > 0 }]);
} else console.log("skipped Lua: no .tools/lua-ls");
if (have("shader-ls")) {
  await session("tiny-shaders", [
    { file: "lit.frag", label: "GLSL", edit: (s) => s.replace("color = vec4(", "color = vec3("), want: (d) => d.length > 0 },
    { file: "lit.hlsl", label: "HLSL", edit: (s) => s.replace("return float4(", "return undefinedThing("), want: (d) => d.length > 0 },
    { file: "lit.wgsl", label: "WGSL", edit: (s) => s.replace("let base =", "let base: i32 ="), want: (d) => d.length > 0 },
  ]);
} else console.log("skipped shaders: no .tools/shader-ls");
if (have("clangd")) {
  await session("tiny-cpp", [{ file: "src/main.cpp", label: "C++", edit: (s) => s.replace("add_points(score, 10)", "add_points(score)"),
    want: (d) => d.some((x: any) => x.line === 5) }]);
  // A repo with its own compile_commands.json: clangd must use it (here it
  // defines SCORE_BONUS, which the code needs).
  rmSync("data/game-live/cpp-own-db-src", { recursive: true, force: true });
  cpSync("fixtures/tiny-cpp", "data/game-live/cpp-own-db-src", { recursive: true });
  writeFileSync("data/game-live/cpp-own-db-src/src/bonus.cpp", "int bonus() { return SCORE_BONUS; }\n");
  await session("cpp-own-db", [{ file: "src/bonus.cpp", label: "C++ with the repo's own compile_commands.json",
    edit: (s) => s.replace("SCORE_BONUS", "SCORE_BONUS + missing_name"), want: (d) => d.some((x: any) => x.line === 1) }],
    "data/game-live/cpp-own-db-src", (repo) => writeFileSync(`${repo}/compile_commands.json`, JSON.stringify(
      ["main.cpp", "score.cpp", "bonus.cpp"].map((f) => ({ directory: `${process.cwd()}/${repo}/src`, file: f,
        arguments: ["clang++", "-DSCORE_BONUS=5", "-c", f] })))));
} else console.log("skipped C++: no .tools/clangd");
if (have("dotnet-tools/csharp-ls") && have("dotnet-tools/scip-dotnet")) {
  await session("tiny-cs", [{ file: "src/Program.cs", label: "C#", edit: (s) => s.replace("Combat.Strike(hero, 10)", "Combat.Strike(hero)"),
    want: (d) => d.some((x: any) => x.line === 4) }]);
  // The full map from scip-dotnet: implementations of an interface and
  // callers of a method, with no obj/ files in it.
  const db = "data/game-live/tiny-cs/out/swan.db";
  const q = (...a: string[]) => JSON.parse(Bun.spawnSync(["bin/swan", "query", db, ...a]).stdout.toString());
  const impls = q("impls", "IDamageable").implementations.map((s: any) => s.name_path).sort();
  check("C# map: Player and Crate implement IDamageable", JSON.stringify(impls) === '["Crate","Player"]', impls);
  const callers = q("callers", "Strike").callers.map((s: any) => s.name_path).sort();
  check("C# map: Arena/Round and the expression-bodied Tricks/Finish call Combat/Strike",
    JSON.stringify(callers) === '["Arena/Round","Tricks/Finish"]', callers);
  const save = q("overview", "src/Shapes.cs").find((s: any) => s.name_path === "Tricks/SavePath");
  check("C# map: a verbatim string ending in \\ and strings holding braces leave the body whole",
    JSON.stringify(save?.body_lines) === "[46,50]", save);
  const refs = q("refs", "Strike")[0].references.map((r: any) => r.relative_path).sort();
  check("C# map: the top-level call in Program.cs is a reference", refs.includes("src/Program.cs"), refs);
  const files = readFileSync("data/game-live/tiny-cs/out/occurrences.tsv", "utf8").split("\n").map((l) => l.split("\t")[1]);
  check("C# map: no generated obj/ files", !files.some((f) => f?.startsWith("obj/")), [...new Set(files)]);
} else console.log("skipped C#: no .tools/dotnet-tools (csharp-ls, scip-dotnet)");
if (have("dotnet-tools/csharp-ls") && have("dotnet-tools/scip-dotnet")) {
  // Untrusted, nothing runs the repo's build files: the map says how to trust
  // it, the live server waits, dotnet restore writes no obj/; then
  // `swan trust` lets both run.
  const dir = "data/game-live/untrusted-cs";
  rmSync(dir, { recursive: true, force: true });
  cpSync("fixtures/tiny-cs", `${dir}/repo`, { recursive: true });
  const env = { ...process.env };
  delete env.SWAN_TRUST_BUILD;
  const run = (...a: string[]) => Bun.spawnSync(["bin/swan", ...a], { env, stdout: "pipe", stderr: "pipe" });
  const m = run("map", `${dir}/repo`, `${dir}/out`).stdout.toString();
  check("untrusted C#: the map skips scip-dotnet and says how to trust the repo",
    m.includes("not run: scip-dotnet") && m.includes("swan trust "), m);
  check("untrusted C#: dotnet restore did not run (no obj/)", !existsSync(`${dir}/repo/obj`));
  const serve = (input: string) => Bun.spawnSync(["bin/swan", "serve", `${dir}/out/swan.db`], { env, stdin: new TextEncoder().encode(input), stdout: "pipe" }).stdout.toString();
  const ask = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "get_diagnostics", arguments: { relative_path: "src/Program.cs", live: true } } }) + "\n";
  const live = serve(ask);
  check("untrusted C#: the live server waits for swan trust", live.includes("swan trust "), live.slice(0, 600));
  run("trust", `${dir}/repo`, `${dir}/out`);
  const m2 = run("map", `${dir}/repo`, `${dir}/out`).stdout.toString();
  const callers = JSON.parse(run("query", `${dir}/out/swan.db`, "callers", "Strike").stdout.toString()).callers.length;
  check("trusted C#: after swan trust the map runs scip-dotnet", !m2.includes("not run:") && callers === 2, m2);
}
if (have("blender-stubs")) {
  await session("tiny-blender", [{ file: "addon.py", label: "Blender Python", edit: (s) => s.replace("obj.name = prefix + obj.name", "obj.name = 3"),
    want: (d) => d.some((x: any) => x.line === 16) }]);
} else console.log("skipped Blender: no .tools/blender-stubs");

console.log(failures ? `${failures} check(s) failed` : "all game live checks passed");
process.exit(failures ? 1 : 0);
