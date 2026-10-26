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

if (run("python")) {
  // A copy with its own virtualenv holding `requests`, made with uv.
  const w = "data/py-check";
  sh(["rm", "-rf", w]);
  sh(["mkdir", "-p", w]);
  sh(["cp", "-r", "fixtures/tiny-py", `${w}/repo`]);
  sh(["uv", "venv", "-q", `${w}/repo/.venv`]);
  sh(["uv", "pip", "install", "-q", "--python", `${w}/repo/.venv/bin/python`, "requests==2.32.5"]);
  sh(["bin/swan", "map", `${w}/repo`, `${w}/map`]);
  sh(["bin/swan", "check", `${w}/repo`, `${w}/map`]);
  const q = (...a: string[]) => JSON.parse(sh(["bin/swan", "query", `${w}/map/swan.db`, ...a]));
  check("python: Square and Circle implement Shape",
    q("impls", "Shape").implementations.map((s: any) => s.name_path).sort().join(",") === "Circle,Square");
  check("python: both area() methods override Shape.area",
    q("hierarchy", "Shape/area").subtypes.map((s: any) => s.name_path).sort().join(",") === "Circle/area,Square/area");
  const callees = q("callees", "fetch_status").callees;
  check("python: requests.get resolves to the venv's requests 2.32.5",
    callees.some((c: any) => c.name_path === "get" && c.package === "requests 2.32.5"), callees);
  check("python: pyright finds no errors in the clean fixture (requests imports resolve)", q("diagfile", ".").map_total.errors === 0);
  check("python: top-level functions and methods are told apart",
    q("symbol", "total_area")[0]?.kind === "function" && q("symbol", "Square/area")[0]?.kind === "method");

  // Break Square's constructor; pyright should report it in Square's callers.
  const srv = Bun.spawnSync(["bin/swan", "serve", `${w}/map/swan.db`], {
    stdin: Buffer.from(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "replace_symbol_body",
      arguments: { name_path: "Square/__init__", relative_path: "shapes/__init__.py",
        body: "def __init__(self, side: float, unit: str) -> None:\n        self.side = side\n        self.unit = unit" } } }) + "\n"),
    stdout: "pipe" });
  check("python: replace_symbol_body on a method", !JSON.parse(srv.stdout.toString()).result.isError, srv.stdout.toString());
  sh(["bin/swan", "check", `${w}/repo`, `${w}/map`]);
  const diag = q("diag", "Square", "shapes/__init__.py").diagnostics;
  const inSyms = diag.filter((d: any) => d.severity === "error").map((d: any) => d.in_symbol).sort();
  check("python: pyright's errors land in Square's callers, report and ShapeTests.test_square",
    inSyms.includes("report") && inSyms.includes("ShapeTests/test_square"), diag);
}

if (run("java")) {
  // scip-java with no build tool: Swan writes its scip-java.json outside the repo.
  const w = "data/java-check";
  sh(["rm", "-rf", w]);
  sh(["mkdir", "-p", w]);
  sh(["cp", "-r", "fixtures/tiny-java", `${w}/repo`]);
  sh(["bin/swan", "map", `${w}/repo`, `${w}/map`]);
  sh(["bin/swan", "check", `${w}/repo`, `${w}/map`]);
  const q = (...a: string[]) => JSON.parse(sh(["bin/swan", "query", `${w}/map/swan.db`, ...a]));
  const mcp = (name: string, args: Record<string, unknown>) => {
    const r = Bun.spawnSync(["bin/swan", "serve", `${w}/map/swan.db`], {
      stdin: Buffer.from(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }) + "\n"),
      stdout: "pipe" });
    return JSON.parse(r.stdout.toString()).result;
  };
  check("java: Square and Circle implement Shape",
    q("impls", "Shape").implementations.map((s: any) => s.name_path).sort().join(",") === "Circle,Square");
  check("java: the area() overrides, without scip-java's reverse links",
    q("hierarchy", "Shape/area").subtypes.map((s: any) => s.name_path).sort().join(",") === "Circle/area,Square/area");
  const sq = q("refs", "Square")[0].references;
  check("java: `new Square(2)` counts as a use of Square (through its constructor)",
    sq.some((r: any) => r.in_symbol === "Shapes/main" && r.via === "Square/<init>"), sq);
  check("java: javac finds no errors in the clean fixture", q("diagfile", ".").map_total.errors === 0);

  const edit = mcp("replace_symbol_body", { name_path: "Square/<init>", relative_path: "src/main/java/shapes/Square.java",
    body: "public Square(double side, String unit) {\n        this.side = side;\n    }" });
  check("java: replace_symbol_body on a constructor", !edit.isError, edit);
  sh(["bin/swan", "check", `${w}/repo`, `${w}/map`]);
  const diag = q("diag", "Square", "src/main/java/shapes/Square.java").diagnostics;
  check("java: javac's error lands in the caller, Shapes.main, with its column",
    diag.some((d: any) => d.severity === "error" && d.in_symbol === "Shapes/main" && d.column > 1 && d.distance === 1), diag);

  const ren = mcp("rename_symbol", { name_path: "Shapes/totalArea", relative_path: "src/main/java/shapes/Shapes.java",
    new_name: "sumOfAreas", apply: true });
  const renamed = await Bun.file(`${w}/repo/src/main/java/shapes/Shapes.java`).text();
  check("java: rename_symbol rewrites the method and its call",
    !ren.isError && renamed.includes("static double sumOfAreas(") && renamed.includes("println(sumOfAreas("), ren);
}

if (run("cuda")) {
  // scip-clang in clang's CUDA mode, with NVIDIA's headers from pip wheels and
  // clang's builtin CUDA headers; no nvcc, no GPU.
  const w = "data/cuda-check";
  sh(["rm", "-rf", w]);
  sh(["mkdir", "-p", w]);
  sh(["cp", "-r", "fixtures/tiny-cuda", `${w}/repo`]);
  sh(["bin/swan", "map", `${w}/repo`, `${w}/map`]);
  sh(["bin/swan", "check", `${w}/repo`, `${w}/map`]);
  const q = (...a: string[]) => JSON.parse(sh(["bin/swan", "query", `${w}/map/swan.db`, ...a]));
  const chain = q("callers", "scale").callers.map((c: any) => `${c.name_path}@${c.distance}`);
  check("cuda: callers of the device function scale(): scaled_kernel, then launch_scaled (a <<<>>> launch), then main",
    chain.join(",") === "scaled_kernel@1,launch_scaled@2,main@3", chain);
  check("cuda: the kernel launch add_kernel<<<...>>> is a reference from launch_add",
    q("refs", "add_kernel")[0].references.some((r: any) => r.in_symbol === "launch_add"));
  check("cuda: clang finds no errors in the clean fixture", q("diagfile", ".").map_total.errors === 0);
  const r = Bun.spawnSync(["bin/swan", "serve", `${w}/map/swan.db`], {
    stdin: Buffer.from(JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "replace_symbol_body",
      arguments: { name_path: "scale", relative_path: "vec.cuh", body: "__device__ inline float scale(float x, float k, float bias) { return x * k + bias; }" } } }) + "\n"),
    stdout: "pipe" });
  check("cuda: replace_symbol_body on a __device__ function in a .cuh header", !JSON.parse(r.stdout.toString()).result.isError);
  sh(["bin/swan", "check", `${w}/repo`, `${w}/map`]);
  const diag = q("diag", "scale", "vec.cuh").diagnostics;
  check("cuda: clang's error for the old call lands in scaled_kernel",
    diag.some((d: any) => d.severity === "error" && d.in_symbol === "scaled_kernel" && d.distance === 1), diag);
}

console.log(failures ? `${failures} check(s) failed` : "all language checks passed");
process.exit(failures ? 1 : 0);
