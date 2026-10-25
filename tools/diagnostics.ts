// Runs each language's own checker over a repo and writes what it reports
// as rows Swan can load (`swan diagnostics`), since Goose cannot start
// processes.
//
//   bun tools/diagnostics.ts <repo> <out-dir>
//
// Writes <out-dir>/diagnostics.tsv: file, line, col, end_line, end_col,
// severity (error|warning|info), source (tsc|cargo), code, message.
// Lines and columns are 0-based, as in the SCIP rows. The repo is only
// read: Rust build output goes to <out-dir>/cargo-target.
// TypeScript: `tsc --noEmit` (needs tsconfig.json). Rust: `cargo check
// --message-format=json`. Python is not covered yet; there is no pyright here.

import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";

const [repoArg, outArg] = process.argv.slice(2);
if (!repoArg || !outArg) {
  console.error("usage: bun tools/diagnostics.ts <repo> <out-dir>");
  process.exit(2);
}
const repo = resolve(repoArg), out = resolve(outArg);
mkdirSync(out, { recursive: true });
const here = resolve(import.meta.dir, "..");
const clean = (s: string) => s.replace(/[\t\r\n]+/g, " ").trim().slice(0, 500);
const rows: string[] = [];
const ran: string[] = [];

if (existsSync(join(repo, "tsconfig.json"))) {
  const t0 = performance.now();
  const r = Bun.spawnSync([join(here, "tools/node_modules/.bin/tsc"), "--noEmit", "--pretty", "false", "-p", repo],
    { cwd: repo, stdout: "pipe", stderr: "pipe" });
  // file(line,col): error TS2345: message, then indented continuation lines
  const re = /^(.+?)\((\d+),(\d+)\): (error|warning|message) (TS\d+): (.*)$/;
  let last: string[] | null = null;
  for (const line of r.stdout.toString().split("\n")) {
    const m = re.exec(line);
    if (m) {
      const [, file, l, c, sev, code, msg] = m;
      last = [relative(repo, resolve(repo, file)), String(+l - 1), String(+c - 1), String(+l - 1), String(+c - 1),
              sev === "message" ? "info" : sev, "tsc", code, clean(msg)];
      rows.push(last.join("\t"));
    } else if (last && line.startsWith("  ")) {
      last[8] = clean(`${last[8]} ${line}`);
      rows[rows.length - 1] = last.join("\t");
    }
  }
  ran.push(`tsc ${Math.round(performance.now() - t0)} ms`);
}

if (existsSync(join(repo, "Cargo.toml"))) {
  const t0 = performance.now();
  const r = Bun.spawnSync(["cargo", "check", "--workspace", "--all-targets", "--message-format=json", "--quiet"],
    { cwd: repo, stdout: "pipe", stderr: "pipe", env: { ...process.env, CARGO_TARGET_DIR: join(out, "cargo-target") } });
  for (const line of r.stdout.toString().split("\n")) {
    if (!line.startsWith("{")) continue;
    const msg = JSON.parse(line);
    if (msg.reason !== "compiler-message") continue;
    const d = msg.message;
    const span = d.spans?.find((s: any) => s.is_primary);
    if (!span || !["error", "warning"].includes(d.level)) continue;
    const file = relative(repo, resolve(repo, span.file_name));
    if (file.startsWith("..")) continue;    // a dependency's file
    rows.push([file, span.line_start - 1, span.column_start - 1, span.line_end - 1, span.column_end - 1,
               d.level, "cargo", d.code?.code ?? "", clean(d.message)].join("\t"));
  }
  ran.push(`cargo check ${Math.round(performance.now() - t0)} ms`);
}

writeFileSync(join(out, "diagnostics.tsv"), rows.length ? rows.join("\n") + "\n" : "");
console.error(`diagnostics: ${rows.length} from ${ran.join(", ") || "no checker (no tsconfig.json or Cargo.toml)"}`);
