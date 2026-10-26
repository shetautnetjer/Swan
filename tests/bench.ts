// Times `swan serve` on a real index: cold start (spawn to first answer) and
// warm latency per tool over repeated calls.
//
//   bun tests/bench.ts <db> <name_path>...

const [db, ...names] = process.argv.slice(2);
const bin = "bin/swan";

function client() {
  const proc = Bun.spawn([bin, "serve", db], { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
  const reader = proc.stdout.getReader();
  const dec = new TextDecoder();
  let buf = "", id = 0;
  async function call(method: string, params?: unknown) {
    proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }) + "\n");
    while (!buf.includes("\n")) {
      const { value, done } = await reader.read();
      if (done) throw new Error("closed");
      buf += dec.decode(value);
    }
    const i = buf.indexOf("\n");
    const msg = JSON.parse(buf.slice(0, i));
    buf = buf.slice(i + 1);
    return msg;
  }
  return { proc, call };
}

const pct = (xs: number[], p: number) => [...xs].sort((a, b) => a - b)[Math.min(xs.length - 1, Math.floor(xs.length * p))];

const t0 = performance.now();
const c = client();
await c.call("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "bench", version: "0" } });
const first = await c.call("tools/call", { name: "find_referencing_symbols", arguments: { name_path: names[0] } });
console.log(`cold: spawn + initialize + first find_referencing_symbols(${names[0]}) = ${(performance.now() - t0).toFixed(1)} ms`);
if (first.result.isError) throw new Error(first.result.content[0].text);

for (const name of names) {
  for (const [tool, args] of [
    ["find_symbol", { name_path_pattern: name }],
    ["find_referencing_symbols", { name_path: name }],
  ] as const) {
    const times: number[] = [];
    let count = 0;
    for (let i = 0; i < 50; i++) {
      const s = performance.now();
      const r = await c.call("tools/call", { name: tool, arguments: args });
      times.push(performance.now() - s);
      const v = JSON.parse(r.result.content[0].text);
      count = tool === "find_symbol" ? v.length : v.reduce((n: number, s: any) => n + s.references.length, 0);
    }
    console.log(`${tool}(${name}): ${count} results, median ${pct(times, 0.5).toFixed(2)} ms, p95 ${pct(times, 0.95).toFixed(2)} ms`);
  }
}
c.proc.stdin.end();
await c.proc.exited;
