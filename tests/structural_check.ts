// Structural search checked against ast-grep, the reference: for each case
// (language, pattern, where), Swan's matches and ast-grep's must be the same
// set of positions. Cases are an obligation ledger: each states what it
// covers. Runs on the fixtures; pass a map to run the same cases on a real
// repo (read-only):  bun tests/structural_check.ts [db]
//
// Also checks rewrite_pattern's plan, refusal and apply on a scratch copy.

import { cpSync, existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";

const sh = (cmd: string[], cwd?: string) => {
  const r = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe", cwd });
  return { code: r.exitCode, out: r.stdout.toString(), err: r.stderr.toString() };
};

// sg: ast-grep's name for the language; expect: the answer where ast-grep
// has no grammar (CUDA), checked by hand against the fixture.
type Case = { lang: string; sg: string; pattern: string; covers: string; expect?: string[] };
const CASES: Case[] = [
  { lang: "typescript", sg: "ts", pattern: "console.log($$$A)", covers: "a call with any arguments ($$$, none included)" },
  { lang: "typescript", sg: "ts", pattern: "$X.push($Y)", covers: "a method call on anything" },
  { lang: "typescript", sg: "ts", pattern: "await $X", covers: "a unary keyword expression" },
  { lang: "typescript", sg: "ts", pattern: "new $C($$$A)", covers: "constructor calls" },
  { lang: "typescript", sg: "ts", pattern: "if ($C) { $$$B }", covers: "a statement with a block body" },
  { lang: "typescript", sg: "ts", pattern: "$A === $A", covers: "a metavariable used twice must match the same text" },
  { lang: "typescript", sg: "ts", pattern: "return $X", covers: "a keyword statement is not stripped to its operand" },
  { lang: "python", sg: "python", pattern: "$X.append($Y)", covers: "Python method calls" },
  { lang: "python", sg: "python", pattern: "isinstance($X, $T)", covers: "fixed arity" },
  { lang: "python", sg: "python", pattern: "def $F($$$A): $$$B", covers: "a whole function definition" },
  { lang: "rust", sg: "rust", pattern: "$X.unwrap()", covers: "an expression only valid inside a function" },
  { lang: "rust", sg: "rust", pattern: "impl $T for $S { $$$B }", covers: "trait impl items" },
  { lang: "rust", sg: "rust", pattern: "Tile::new($X)", covers: "a path call" },
  { lang: "java", sg: "java", pattern: "System.out.println($X)", covers: "Java statement inside a method" },
  { lang: "java", sg: "java", pattern: "new $C($$$A)", covers: "Java object creation" },
  { lang: "c", sg: "c", pattern: "printf($$$A)", covers: "C calls" },
  { lang: "kotlin", sg: "kotlin", pattern: "$X.area()", covers: "Kotlin method calls" },
  { lang: "csharp", sg: "csharp", pattern: "Debug.Log($X)", covers: "C# (Unity) calls" },
  { lang: "csharp", sg: "csharp", pattern: "new Vector3($$$A)", covers: "C# object creation" },
  { lang: "lua", sg: "lua", pattern: "$O:hit($D)", covers: "Lua method calls" },
  { lang: "lua", sg: "lua", pattern: "function $F($$$A) $$$B end", covers: "a whole Lua function" },
  { lang: "php", sg: "php", pattern: "array_slice($$$A)", covers: "PHP calls" },
  { lang: "php", sg: "php", pattern: "echo $X;", covers: "PHP statements with PHP variables around" },
  { lang: "glsl", sg: "", pattern: "texture($S, $UV)", covers: "GLSL sampling", expect: ["lit.frag:7:17"] },
  { lang: "hlsl", sg: "", pattern: "$T.Sample($S, $UV)", covers: "HLSL sampling", expect: ["lit.hlsl:6:19"] },
  { lang: "wgsl", sg: "", pattern: "textureSample($T, $S, $UV)", covers: "WGSL sampling", expect: ["lit.wgsl:6:16"] },
  { lang: "gdscript", sg: "", pattern: "print($$$A)", covers: "GDScript calls", expect: ["player.gd:13:2"] },
  { lang: "kotlin", sg: "kotlin", pattern: "fun $F($$$P): $T = $E", covers: "expression-bodied functions" },
  { lang: "kotlin", sg: "kotlin", pattern: "$X!!", covers: "non-null assertions" },
  { lang: "kotlin", sg: "kotlin", pattern: "class $C($$$P) : $S { $$$B }", covers: "a class body the grammar parses as another kind" },
  { lang: "kotlin", sg: "kotlin", pattern: "override fun $F(): Double = $E", covers: "modifiers in the pattern" },
  { lang: "cuda", sg: "", pattern: "$K<<<$$$L>>>($$$A)", covers: "CUDA kernel launches", expect: ["vec.cu:14:5", "vec.cu:18:5"] },
];

let failures = 0;
const check = (what: string, ok: boolean, detail: unknown = "") => {
  console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok ? "" : `\n     ${JSON.stringify(detail).slice(0, 600)}`}`);
  if (!ok) failures++;
};

const EXT: Record<string, RegExp> = {
  typescript: /\.(ts|mts|cts)$/, kotlin: /\.kts?$/, csharp: /\.cs$/, lua: /\.lua$/, php: /\.php$/,
  glsl: /\.(glsl|vert|frag|comp)$/, hlsl: /\.(hlsl|hlsli|fx)$/, wgsl: /\.wgsl$/, gdscript: /\.gd$/, python: /\.pyi?$/, rust: /\.rs$/, java: /\.java$/, c: /\.[ch]$/, cuda: /\.(cu|cuh)$/,
};

function compare(db: string, root: string, rel: string, label: string) {
  for (const c of CASES) {
    const s = sh(["bin/swan", "query", db, "pattern", c.pattern, rel]);
    if (s.code !== 0) { check(`${label} ${c.lang} ${c.pattern}: swan ran`, false, s.err); continue; }
    const body = JSON.parse(s.out);
    const ours = new Set<string>(body.matches.filter((m: any) => EXT[c.lang].test(m.relative_path))
      .map((m: any) => `${m.relative_path}:${m.line}:${m.column}`));
    if (c.expect) {
      // Checked only where its files are (the fixture it was written for).
      if (!c.expect.every((e) => existsSync(`${root}/${e.split(":")[0]}`))) continue;
      check(`${label} ${c.lang} ${c.pattern} (${c.covers}): ${ours.size}, by hand`,
        [...ours].sort().join(",") === c.expect.join(","), [...ours]);
      continue;
    }
    const g = sh(["ast-grep", "run", "-p", c.pattern, "-l", c.sg, "--json=compact", rel || "."], root);
    const theirs = new Set<string>((JSON.parse(g.out || "[]") as any[])
      .filter((m) => EXT[c.lang].test(m.file))
      .map((m) => `${rel && !m.file.startsWith(rel) ? `${rel}/` : ""}${m.file.replace(/^\.\//, "")}:${m.range.start.line + 1}:${m.range.start.column + 1}`));
    if (theirs.size === 0 && ours.size === 0) continue;   // nothing in this language here
    // ast-grep's own walk skips what .gitignore names, tracked or not; Swan
    // reads those files too. Those are not matching differences.
    const ignored = (f: string) => sh(["git", "check-ignore", "-q", "--no-index", f], root).code === 0;
    const onlyUs = [...ours].filter((x) => !theirs.has(x) && !ignored(x.split(":")[0]));
    const onlyThem = [...theirs].filter((x) => !ours.has(x));
    check(`${label} ${c.lang} ${c.pattern} (${c.covers}): ${ours.size} = ast-grep ${theirs.size}`,
      onlyUs.length === 0 && onlyThem.length === 0, { onlyUs: onlyUs.slice(0, 5), onlyThem: onlyThem.slice(0, 5) });
  }
}

var external = process.argv[2];
if (external) {
  const info = JSON.parse(sh(["bin/swan", "query", external, "info", "x"]).out);
  compare(external, info.root, process.argv[3] ?? "", "repo");
} else {
  for (const [fx, map] of [["tiny-ts", "data/tiny-ts"], ["tiny-py", "data/struct/py"], ["tiny-rs", "data/struct/rs"],
                           ["tiny-java", "data/struct/java"], ["tiny-cuda", "data/struct/cuda"], ["tiny-kt", "data/struct/kt"],
                           ["tiny-lua", "data/struct/lua"], ["tiny-shaders", "data/struct/shaders"], ["tiny-game", "data/struct/game"]]) {
    if (fx !== "tiny-ts") {
      // Kotlin's map runs a Gradle build, which writes into the repo: map a copy.
      const src = fx === "tiny-kt" ? `${map}-repo` : `fixtures/${fx}`;
      if (fx === "tiny-kt") { rmSync(src, { recursive: true, force: true }); cpSync(`fixtures/${fx}`, src, { recursive: true }); }
      const m = sh(["bin/swan", "map", src, map]);
      if (m.code !== 0) { check(`map ${fx}`, false, m.err.slice(-400)); continue; }
    }
    compare(`${map}/swan.db`, fx === "tiny-kt" ? `${map}-repo` : `fixtures/${fx}`, "", fx);
  }

  // Rewrite on a scratch copy: plan, apply, and the stale refusal.
  rmSync("data/struct/rw", { recursive: true, force: true });
  cpSync("fixtures/tiny-rs", "data/struct/rw/repo", { recursive: true });
  sh(["bin/swan", "map", "data/struct/rw/repo", "data/struct/rw/out"]);
  const proc = Bun.spawn(["bin/swan", "serve", "data/struct/rw/out/swan.db"], { stdin: "pipe", stdout: "pipe" });
  const reader = proc.stdout.getReader();
  let buf = "";
  let id = 0;
  const call = async (name: string, args: any) => {
    proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: ++id, method: "tools/call", params: { name, arguments: args } }) + "\n");
    while (!buf.includes("\n")) { const { value } = await reader.read(); buf += new TextDecoder().decode(value); }
    const line = buf.slice(0, buf.indexOf("\n")); buf = buf.slice(buf.indexOf("\n") + 1);
    const r = JSON.parse(line).result;
    return { ok: !r.isError, body: JSON.parse(r.content[0].text) };
  };
  const lib = "data/struct/rw/repo/src/lib.rs";
  const before = readFileSync(lib, "utf8");
  const hit = await call("search_pattern", { pattern: "self.$F * self.$F" });
  check("search_pattern ties a match to its symbol: Tile/area",
    hit.body.matches.length === 1 && hit.body.matches[0].in_symbol === "Tile/area" && hit.body.matches[0].captures.F === "side", hit.body);
  const plan = await call("rewrite_pattern", { pattern: "self.$F * self.$F", rewrite: "self.$F.pow(2)" });
  check("rewrite_pattern plans without writing", plan.body.applied === false && plan.body.edits[0].after === "self.side.pow(2)" &&
    readFileSync(lib, "utf8") === before, plan.body);
  const done = await call("rewrite_pattern", { pattern: "self.$F * self.$F", rewrite: "self.$F.pow(2)", apply: true });
  check("apply writes it", done.ok && done.body.files_written === 1 && readFileSync(lib, "utf8").includes("self.side.pow(2)"), done.body);
  // A rewrite that adds lines moves the map with it: a symbol edit after it
  // still lands where the symbol is now, not three lines up.
  const grow = await call("rewrite_pattern", { pattern: "3 * self.$F * self.$F",
    rewrite: "{\n            let r = self.$F;\n            3 * r * r\n        }", apply: true });
  const marker = await call("insert_before_symbol", { name_path: "first_is_square", relative_path: "src/lib.rs",
    body: "pub fn marker() -> u32 {\n    7\n}" });
  check("after a rewrite that adds lines, an edit by symbol lands at the symbol",
    grow.ok && marker.ok && readFileSync(lib, "utf8").includes("pub fn marker() -> u32 {\n    7\n}\n\npub fn first_is_square()"),
    { grow: grow.body, marker: marker.body });
  writeFileSync(lib, before.replace("pub side: u32", "pub side:  u32"));
  const refused = await call("rewrite_pattern", { pattern: "3 * self.$F * self.$F", rewrite: "3 * self.$F.pow(2)", apply: true });
  check("a file changed outside Swan since the map is refused", !refused.ok && /refresh first/.test(refused.body.refused ?? ""), refused.body);
  const bad = await call("search_pattern", { pattern: "fn (((", language: "rust" });
  check("a pattern that does not parse says so", bad.body.pattern_does_not_parse_in?.length === 1, bad.body);
  proc.stdin.end();
  await proc.exited;
}

console.log(failures ? `${failures} check(s) failed` : "all structural checks passed");
process.exit(failures ? 1 : 0);
