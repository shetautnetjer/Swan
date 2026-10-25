// End-to-end check of `swan serve` as an MCP client would drive it: spawn the
// server, initialize, list tools, call each tool, and assert on the answers
// for the tiny-ts fixture.
//
//   bun tests/mcp_smoke.ts [swan-binary] [db]

const bin = process.argv[2] ?? "bin/swan";
const db = process.argv[3] ?? "data/tiny-ts/swan.db";

const proc = Bun.spawn([bin, "serve", db], { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
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
  const msg = JSON.parse(await nextLine());
  if (msg.id !== id) throw new Error(`id mismatch: sent ${id}, got ${msg.id}`);
  return msg;
}

async function tool(name: string, args: Record<string, unknown>): Promise<any> {
  const t0 = performance.now();
  const msg = await rpc("tools/call", { name, arguments: args });
  const ms = performance.now() - t0;
  if (msg.result.isError) throw new Error(`${name} failed: ${msg.result.content[0].text}`);
  console.log(`  ${name} ${JSON.stringify(args)}: ${ms.toFixed(2)} ms`);
  return JSON.parse(msg.result.content[0].text);
}

let failures = 0;
function check(what: string, ok: boolean) {
  console.log(`${ok ? "ok  " : "FAIL"} ${what}`);
  if (!ok) failures++;
}

const init = await rpc("initialize", {
  protocolVersion: "2025-06-18",
  capabilities: {},
  clientInfo: { name: "swan-smoke", version: "0" },
});
check("initialize names the server", init.result.serverInfo.name === "swan");
proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");

const tools = (await rpc("tools/list")).result.tools.map((t: any) => t.name);
check(`tools/list: ${tools.join(", ")}`, tools.includes("find_symbol") && tools.includes("find_referencing_symbols") &&
  tools.includes("get_callers") && tools.includes("get_callees"));

const add = await tool("find_symbol", { name_path_pattern: "Store/add", include_body: true });
check("find_symbol Store/add: one method at src/store.ts:11", add.length === 1 && add[0].kind === "method" &&
  add[0].relative_path === "src/store.ts" && add[0].line === 11 && add[0].body.includes("this.items.set"));

const totals = await tool("find_symbol", { name_path_pattern: "total" });
check("find_symbol total: the function and the method stay apart",
  totals.map((s: any) => s.name_path).sort().join(",") === "Store/total,total");

const fmt = await tool("find_referencing_symbols", { name_path: "format" });
const fmtRefs = fmt[0].references.map((r: any) => `${r.relative_path}:${r.line}`);
check("refs to format() follow the re-export to formatItem in main.ts",
  fmtRefs.includes("src/main.ts:8") && fmtRefs.includes("src/index.ts:2"));

const dw = await tool("find_referencing_symbols", { name_path: "DEFAULT_WEIGHT" });
const inAdd = dw[0].references.find((r: any) => r.in_symbol === "Store/add");
check("a reference inside a method names that method (DEFAULT_WEIGHT in Store/add)", !!inAdd);

const ov = await tool("get_symbols_overview", { relative_path: "src/store.ts" });
check("overview of src/store.ts lists Store and makeStore",
  ov.some((s: any) => s.name_path === "Store") && ov.some((s: any) => s.name_path === "makeStore"));

const impact = await tool("get_callers", { name_path: "Store/total", depth: 3 });
const dist = Object.fromEntries(impact.callers.map((c: any) => [c.name_path, c.distance]));
check("get_callers walks the chain: report at 1, summary at 2, testSummary at 3",
  dist["report"] === 1 && dist["summary"] === 2 && dist["testSummary"] === 3);
check("get_callers lists the test file to run",
  impact.summary.test_files.includes("src/store.test.ts") &&
  impact.callers.find((c: any) => c.name_path === "testSummary").is_test === true);

const near = await tool("get_callers", { name_path: "Store/total" });
check("get_callers defaults to direct callers only", near.callers.every((c: any) => c.distance === 1));

const callees = await tool("get_callees", { name_path: "Store/add" });
const names = callees.callees.map((c: any) => c.name_path);
check("get_callees of Store/add: DEFAULT_WEIGHT, and Map/set from the typescript package",
  names.includes("DEFAULT_WEIGHT") &&
  callees.callees.some((c: any) => c.name_path === "Map/set" && c.package.startsWith("typescript ")));

const info = await tool("index_info", {});
check("index_info reports counts", Number(info.symbols) > 0 && Number(info.occurrences) > 0);

const unknown = await rpc("no/such/method");
check("unknown method is a JSON-RPC error", unknown.error?.code === -32601);

proc.stdin.end();
await proc.exited;
console.log(failures ? `${failures} check(s) failed` : "all checks passed");
process.exit(failures ? 1 : 0);
