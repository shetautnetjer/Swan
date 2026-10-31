// One `swan serve --maps <data-root>` answering about any repo: use_repo
// finds or builds the map and switches to it, every tool's `repo` argument
// does the same for a call, and a path inside a mapped repo resolves to the
// repo's map. `swan serve <db>` still answers as before.
//
//   bun tests/maps_check.ts [swan-binary] [data-root]
//
// Needs SWAN_TRUST_BUILD=1 (scripts/test.sh sets it): the tiny-rs map's
// indexer runs the repo's build files.

import { mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const bin = process.argv[2] ?? "bin/swan";
const dataRoot = realpathSync(process.argv[3] ?? mkdtempSync(join(tmpdir(), "swan-maps-")));
const tinyTs = realpathSync("fixtures/tiny-ts");
const tinyRs = realpathSync("fixtures/tiny-rs");

// The fixtures are ours: let their indexers run build files (rust needs it), as scripts/test.sh does.
// Without this a bare run holds tiny-rs's indexer and the switch check has nothing to find.
const proc = Bun.spawn([bin, "serve", "--maps", dataRoot], { stdin: "pipe", stdout: "pipe", stderr: "inherit", env: { ...process.env, SWAN_TRUST_BUILD: "1" } });
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
async function rpc(method: string, params?: unknown): Promise<any> {
  const id = nextId++;
  proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
  const raw = await nextLine();
  let msg: any;
  try { msg = JSON.parse(raw); } catch (e) { console.log(`non-JSON line from server: ${raw.slice(0, 300)}`); throw e; }
  if (msg.id !== id) throw new Error(`id mismatch: sent ${id}, got ${msg.id}`);
  return msg;
}

// The raw call: { isError, text } — the text is JSON for the tools that answer it.
async function call(name: string, args: Record<string, unknown>): Promise<any> {
  const msg = await rpc("tools/call", { name, arguments: args });
  return { isError: msg.result.isError, text: msg.result.content[0].text };
}
async function tool(name: string, args: Record<string, unknown>): Promise<any> {
  const r = await call(name, args);
  if (r.isError) throw new Error(`${name} failed: ${r.text}`);
  return JSON.parse(r.text);
}

let failures = 0;
function check(what: string, ok: boolean, detail: unknown = "") {
  console.log(`${ok ? "ok  " : "FAIL"} ${what}${ok ? "" : `\n     ${JSON.stringify(detail).slice(0, 600)}`}`);
  if (!ok) failures++;
}

const init = await rpc("initialize", {
  protocolVersion: "2025-06-18",
  capabilities: {},
  clientInfo: { name: "swan-maps-check", version: "0" },
});
check("initialize names the server", init.result.serverInfo.name === "swan");
proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");

const tools = (await rpc("tools/list")).result.tools.map((t: any) => t.name);
check("tools/list includes use_repo", tools.includes("use_repo"));

// No repo selected yet: every tool says what to do, index_info lists the maps.
const none = await call("find_symbol", { name_path_pattern: "Store/add" });
check("no repo selected: find_symbol says to call use_repo or pass repo",
  none.isError === true && none.text.includes("no repo selected: call use_repo with a path, or pass repo"), none);
const info0 = await tool("index_info", {});
check("no repo selected: index_info lists the known maps", Array.isArray(info0.maps), info0);

// use_repo builds tiny-ts's map the first time, then answers about it.
const useTs = await tool("use_repo", { path: "fixtures/tiny-ts" });
check("use_repo fixtures/tiny-ts: built the map under the data root",
  useTs.built === true && useTs.root === tinyTs && useTs.map === join(dataRoot, "tiny-ts", "swan.db"), useTs);
check("use_repo reports counts and a timed report",
  useTs.symbols > 0 && useTs.files > 0 && useTs.stale_file_count === 0 && /ms in all/.test(useTs.report), useTs);
const add = await tool("find_symbol", { name_path_pattern: "Store/add" });
check("after use_repo, find_symbol answers about tiny-ts",
  add.length === 1 && add[0].kind === "method" && add[0].relative_path === "src/store.ts", add);

// use_repo switches to tiny-rs: its symbols answer, tiny-ts's do not.
const useRs = await tool("use_repo", { path: "fixtures/tiny-rs" });
check("use_repo fixtures/tiny-rs: built its map too", useRs.built === true && useRs.root === tinyRs, useRs);
const tile = await tool("find_symbol", { name_path_pattern: "Tile/new" });
check("after the switch, find_symbol answers about tiny-rs (Tile/new in src/lib.rs)",
  tile.length === 1 && tile[0].relative_path === "src/lib.rs", tile);
const gone = await tool("find_symbol", { name_path_pattern: "Store/add" });
check("tiny-ts's symbols are gone after the switch", gone.length === 0, gone);

// A per-call repo switches back and answers.
const back = await tool("find_symbol", { name_path_pattern: "Store/add", repo: "fixtures/tiny-ts" });
check("a call's repo argument switches to that repo and answers",
  back.length === 1 && back[0].relative_path === "src/store.ts", back);
const stays = await tool("find_symbol", { name_path_pattern: "Tile/new" });
check("the switch persists after the call", stays.length === 0, stays);

// A path inside a mapped repo resolves to the repo's map.
const inner = await tool("use_repo", { path: "fixtures/tiny-ts/src" });
check("use_repo of a path inside a mapped repo finds the repo's map",
  inner.root === tinyTs && inner.built === false && inner.map === join(dataRoot, "tiny-ts", "swan.db"), inner);

// Reselecting the map that is already open is a no-op (no reopen, no live-server restart),
// even after several switches.
const againTs = await tool("use_repo", { path: "fixtures/tiny-ts" });
check("use_repo of the already-selected repo does not reopen the map", againTs.switched === false, againTs);
await tool("use_repo", { path: "fixtures/tiny-rs" });
const toTs = await tool("use_repo", { path: "fixtures/tiny-ts" });
check("a real switch reports switched", toTs.switched === true, toTs);
const sameTs = await tool("use_repo", { path: "fixtures/tiny-ts/src" });
check("after several switches, reselecting the current repo is still a no-op", sameTs.switched === false, sameTs);

// use_repo refuses what is not there, and a file is not a repo.
const missing = await call("use_repo", { path: "fixtures/no-such-dir" });
check("use_repo on a missing path errors", missing.isError === true && missing.text.includes("no such path"), missing);
const aFile = await call("use_repo", { path: "fixtures/tiny-ts/src/store.ts" });
check("use_repo on a file errors", aFile.isError === true && aFile.text.includes("not a directory"), aFile);

// The build:false hint names a collision-safe dir: a second repo with an already-mapped basename
// must not be pointed at that repo's map dir.
const twinRoot = mkdtempSync(join(tmpdir(), "swan-twin-"));
const twin = join(twinRoot, "tiny-ts");
mkdirSync(twin);
writeFileSync(join(twin, "x.ts"), "export const x = 1;\n");
const twinHint = await call("use_repo", { path: twin, build: false });
check("build:false for a same-basename repo suggests a dir other than the existing map's",
  twinHint.isError === true && twinHint.text.includes("swan map ") &&
  !twinHint.text.includes(` ${join(dataRoot, "tiny-ts")}'`), twinHint);

// Without build, an unmapped repo is an error naming the command to run.
const noBuild = await call("use_repo", { path: "fixtures/tiny-py", build: false });
check("use_repo with build:false names the swan map command",
  noBuild.isError === true && noBuild.text.includes("swan map "), noBuild);

// index_info now answers about the selected map.
const info1 = await tool("index_info", {});
check("index_info answers about the selected repo",
  info1.root === tinyTs && Number(info1.symbols) > 0, info1);

proc.stdin.end();
await proc.exited;

// Old mode is unchanged: `swan serve <db>` still answers about its map.
const one = Bun.spawn([bin, "serve", "data/tiny-ts/swan.db"], { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
const ask = JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/call",
  params: { name: "find_symbol", arguments: { name_path_pattern: "Store/add" } } }) + "\n";
one.stdin.write(ask);
one.stdin.end();
const reply = JSON.parse(await new Response(one.stdout).text().then((t) => t.trim().split("\n").pop()!));
const syms = JSON.parse(reply.result.content[0].text);
check("swan serve <db> still answers about its map",
  reply.result.isError === false && syms.length === 1 && syms[0].relative_path === "src/store.ts", reply);
await one.exited;

console.log(failures ? `${failures} check(s) failed` : "all checks passed");
process.exit(failures ? 1 : 0);
