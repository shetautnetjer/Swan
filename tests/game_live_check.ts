// Live errors from the language servers added for game and 3D code: Lua
// (lua-language-server), the GLSL, HLSL and WGSL shaders (shader-validator's
// server), C++ (clangd) and Blender Python (pyright with Blender's stubs).
// Each fixture is mapped from a copy, checked clean, given a deliberate
// error, checked again, and put back.
//
//   bun tests/game_live_check.ts

import { cpSync, existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";

let failures = 0;
const check = (what: string, ok: boolean, detail: unknown = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok ? "" : `\n     ${JSON.stringify(detail).slice(0, 700)}`}`);
  if (!ok) failures++;
};

async function session(fixture: string, cases: { file: string; label: string; edit: (s: string) => string; want: (d: any[]) => boolean }[]) {
  const dir = `data/game-live/${fixture}`;
  rmSync(dir, { recursive: true, force: true });
  cpSync(`fixtures/${fixture}`, `${dir}/repo`, { recursive: true });
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
} else console.log("skipped C++: no .tools/clangd");
if (have("blender-stubs")) {
  await session("tiny-blender", [{ file: "addon.py", label: "Blender Python", edit: (s) => s.replace("obj.name = prefix + obj.name", "obj.name = 3"),
    want: (d) => d.some((x: any) => x.line === 16) }]);
} else console.log("skipped Blender: no .tools/blender-stubs");

console.log(failures ? `${failures} check(s) failed` : "all game live checks passed");
process.exit(failures ? 1 : 0);
