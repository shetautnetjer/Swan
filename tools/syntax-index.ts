// A syntax-level index for the languages no SCIP indexer covers here: Go,
// shell (bash, zsh, sh, and scripts named only by their #! line), Makefiles,
// Ruby and Lua. It writes a real SCIP file, so the flattener and `swan index`
// take it like any other, and a repo in these languages gets a map instead of
// "no language found".
//
// It reads source text only and runs nothing from the repo. Definitions come
// from line patterns, bodies from brace matching (Go, shell) or `end` at the
// same indentation (Ruby, Lua) or tab-indented recipe lines (Make).
// References are found by name: an identifier equal to a defined name, the
// nearest definition winning (same file, then same folder, then the only one
// in the repo). The flattener marks them "name" (found by name, not resolved
// by a compiler), and answers show them as by_name.
//
//   bun tools/syntax-index.ts <repo> <out.scip>
import { readdirSync, readFileSync, statSync, writeFileSync, lstatSync } from "node:fs";
import { basename, dirname, join, posix, relative } from "node:path";

const [repo, outPath] = process.argv.slice(2);
if (!repo || !outPath) { console.error("usage: bun tools/syntax-index.ts <repo> <out.scip>"); process.exit(2); }

const SKIP = new Set(["node_modules", ".git", "target", ".venv", "venv", "__pycache__", ".tox", ".mypy_cache",
  ".pytest_cache", ".swan", "build", ".gradle", "obj", "vendor", "dist"]);
type Lang = "go" | "shell" | "make" | "ruby" | "lua";
const KIND = { function: 17, method: 26, class: 7, module: 29, struct: 49, interface: 21, type: 54, variable: 61, constant: 8 };

function langOf(path: string, name: string): Lang | null {
  if (name.endsWith(".go")) return "go";
  if (/\.(sh|bash|zsh|ksh)$/.test(name)) return "shell";
  if (/^(GNUmakefile|makefile|Makefile)$/.test(name) || name.endsWith(".mk")) return "make";
  if (name.endsWith(".rb") || name === "Rakefile") return "ruby";
  if (name.endsWith(".lua")) return "lua";
  if (name.includes(".")) return null;
  try {
    const head = readFileSync(path, { encoding: "latin1" }).slice(0, 128);
    if (/^#!.*\b(ba|z|k|da)?sh\b/.test(head)) return "shell";
    if (/^#!.*\bruby\b/.test(head)) return "ruby";
  } catch {}
  return null;
}

const files: { rel: string; lang: Lang; lines: string[] }[] = [];
(function walk(dir: string) {
  let names: string[] = [];
  try { names = readdirSync(dir).sort(); } catch { return; }
  for (const n of names) {
    const full = join(dir, n);
    let st;
    try { st = lstatSync(full); } catch { continue; }
    if (st.isSymbolicLink()) continue;
    if (st.isDirectory()) { if (!SKIP.has(n)) walk(full); continue; }
    if (!st.isFile() || st.size > 1_000_000) continue;
    const lang = langOf(full, n);
    if (lang) files.push({ rel: relative(repo, full).split("\\").join("/"), lang, lines: readFileSync(full, "utf8").split(/\r?\n/) });
  }
})(repo);

type Def = { name: string; sym: string; kind: number; line: number; col: number; end: number; endCol: number;
  sig: string; file: string; dir: string; lang: Lang; method: boolean };
const ident = (s: string) => (/^[\w$+\-]+$/.test(s) ? s : "`" + s.replace(/`/g, "``") + "`");
const pkg = `swan-syntax . ${ident(basename(repo)).replace(/ /g, "_")} 0 `;
const nsOf = (dir: string) => (dir && dir !== "." ? dir.split("/").map((s) => ident(s) + "/").join("") : "");

// Code with comments and string contents blanked (same length, so columns hold).
function codeOnly(line: string, lang: Lang): string {
  let out = "", q = "";
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) { out += c === q ? c : " "; if (c === "\\" && q !== "`") { out += " "; i++; } if (c === q) q = ""; continue; }
    if (lang === "go" && c === "/" && line[i + 1] === "/") break;
    if (lang === "lua" && c === "-" && line[i + 1] === "-") break;
    if ((lang === "shell" || lang === "make" || lang === "ruby") && c === "#" && (i === 0 || /\s/.test(line[i - 1]))) break;
    if (lang === "go" && (c === '"' || c === "`" || c === "'")) { q = c; out += c; continue; }
    out += c;
  }
  return out;
}

// The line where a body opened by a brace on (or just after) `from` closes.
function braceEnd(lines: string[], from: number, lang: Lang): [number, number] {
  let depth = 0, opened = false;
  for (let l = from; l < lines.length && l < from + 20000; l++) {
    const code = codeOnly(lines[l], lang);
    for (let c = 0; c < code.length; c++) {
      if (code[c] === "{") { depth++; opened = true; }
      else if (code[c] === "}" && opened) { depth--; if (depth === 0) return [l, c + 1]; }
    }
    if (!opened && l > from + 1) break;
  }
  return [from, lines[from].length];
}
function endEnd(lines: string[], from: number): [number, number] {
  const indent = lines[from].match(/^\s*/)![0].length;
  for (let l = from + 1; l < lines.length; l++) {
    const m = lines[l].match(/^(\s*)end\b/);
    if (m && m[1].length === indent) return [l, m[0].length];
  }
  return [from, lines[from].length];
}

const defs: Def[] = [];
const modules: Def[] = [];
for (const f of files) {
  const dir = posix.dirname(f.rel);
  const fileNs = nsOf(dir) + ident(basename(f.rel)) + "/";
  let goTypeBlock = false;
  const add = (name: string, desc: string, kind: number, line: number, col: number, end: [number, number], method = false) =>
    defs.push({ name, sym: pkg + desc, kind, line, col, end: end[0], endCol: end[1], sig: f.lines[line].trim().slice(0, 200),
      file: f.rel, dir, lang: f.lang, method });
  // The file itself, as scip-typescript names a module: top-level code (a
  // script's main part, a Makefile's variables) sits inside it.
  const last = f.lines.length - 1;
  modules.push({ name: basename(f.rel), sym: pkg + fileNs, kind: 29, line: 0, col: 0, end: last, endCol: f.lines[last].length,
    sig: basename(f.rel), file: f.rel, dir, lang: f.lang, method: false });
  f.lines.forEach((raw, i) => {
    const line = codeOnly(raw, f.lang);
    let m: RegExpMatchArray | null;
    if (f.lang === "go") {
      const ns = nsOf(dir);
      if (/^\)/.test(line)) goTypeBlock = false;
      if ((m = line.match(/^func\s+\(\s*\w*\s*\*?\s*(\w+)(?:\[[^\]]*\])?\s*\)\s*(\w+)\s*[\[(]/)))
        add(m[2], `${ns}${ident(m[1])}#${ident(m[2])}().`, KIND.method, i, line.indexOf(m[2], line.indexOf(")")), braceEnd(f.lines, i, "go"), true);
      else if ((m = line.match(/^func\s+(\w+)\s*[\[(]/)))
        add(m[1], `${ns}${ident(m[1])}().`, KIND.function, i, line.indexOf(m[1], 4), braceEnd(f.lines, i, "go"));
      else if ((m = line.match(/^type\s+\($/))) goTypeBlock = true;
      else if ((m = line.match(/^(?:type\s+|\t)(\w+)(?:\[[^\]]*\])?\s+(struct|interface)?/)) && (line.startsWith("type") || goTypeBlock)) {
        const k = m[2] === "struct" ? KIND.struct : m[2] === "interface" ? KIND.interface : KIND.type;
        add(m[1], `${ns}${ident(m[1])}#`, k, i, line.indexOf(m[1]), m[2] ? braceEnd(f.lines, i, "go") : [i, raw.length]);
      } else if ((m = line.match(/^(var|const)\s+(\w+)/)))
        add(m[2], `${ns}${ident(m[2])}.`, m[1] === "const" ? KIND.constant : KIND.variable, i, line.indexOf(m[2], 4), [i, raw.length]);
    } else if (f.lang === "shell") {
      if ((m = line.match(/^\s*(?:function\s+)?([A-Za-z_][\w:.\-]*)\s*\(\s*\)/)) || (m = line.match(/^\s*function\s+([A-Za-z_][\w:.\-]*)/)))
        add(m[1], `${fileNs}${ident(m[1])}().`, KIND.function, i, line.indexOf(m[1]), braceEnd(f.lines, i, "shell"));
    } else if (f.lang === "make") {
      if ((m = line.match(/^([A-Za-z0-9_][\w.\-\/]*)\s*:(?![=:])/)) && !m[1].startsWith(".")) {
        let e = i;
        while (e + 1 < f.lines.length && f.lines[e + 1].startsWith("\t")) e++;
        add(m[1], `${fileNs}${ident(m[1])}().`, KIND.function, i, 0, [e, f.lines[e].length]);
      }
    } else if (f.lang === "ruby") {
      if ((m = line.match(/^\s*(class|module)\s+([A-Z]\w*(?:::\w+)*)/)))
        add(m[2].split("::").pop()!, `${fileNs}${ident(m[2])}#`, m[1] === "class" ? KIND.class : KIND.module, i, line.indexOf(m[2]), endEnd(f.lines, i));
      else if ((m = line.match(/^\s*def\s+(?:self\.)?([A-Za-z_][\w]*[?!=]?)/)))
        add(m[1], `${fileNs}${ident(m[1])}().`, KIND.method, i, line.indexOf(m[1], line.indexOf("def") + 3), endEnd(f.lines, i), true);
    } else if (f.lang === "lua") {
      if ((m = line.match(/^\s*(?:local\s+)?function\s+([\w.:]+)\s*\(/))) {
        const name = m[1].split(/[.:]/).pop()!;
        add(name, `${fileNs}${ident(m[1])}().`, KIND.function, i, line.indexOf(m[1]) + m[1].length - name.length, endEnd(f.lines, i), /[.:]/.test(m[1]));
      }
    }
  });
}

// Definitions by name, per language family (Make targets only answer Make).
const byName = new Map<string, Def[]>();
for (const d of defs) {
  const k = `${d.lang === "make" ? "make" : d.lang}\t${d.name}`;
  (byName.get(k) ?? byName.set(k, []).get(k)!).push(d);
}
function resolve(name: string, lang: Lang, file: string, dir: string, afterDot: boolean): Def[] {
  const all = byName.get(`${lang}\t${name}`) ?? [];
  if (!all.length) return [];
  const pool = lang === "go" && afterDot && all.some((d) => d.method) ? all.filter((d) => d.method) : all;
  for (const tier of [pool.filter((d) => d.file === file), pool.filter((d) => d.dir === dir), pool]) {
    if (tier.length && tier.length <= 3) return tier;
    if (tier.length) return [];
  }
  return [];
}

// --- SCIP protobuf writer ---
const enc = new TextEncoder();
class W {
  b: number[] = [];
  varint(n: number) { while (n > 127) { this.b.push((n & 127) | 128); n = Math.floor(n / 128); } this.b.push(n); return this; }
  key(f: number, wt: number) { return this.varint(f * 8 + wt); }
  bytes(f: number, v: Uint8Array | number[]) { this.key(f, 2).varint(v.length); for (const x of v) this.b.push(x); return this; }
  str(f: number, s: string) { return this.bytes(f, enc.encode(s)); }
  int(f: number, n: number) { return this.key(f, 0).varint(n); }
  packed(f: number, ns: number[]) { const w = new W(); for (const n of ns) w.varint(n); return this.bytes(f, w.b); }
  msg(f: number, m: W) { return this.bytes(f, m.b); }
}
const span = (l: number, c: number, el: number, ec: number) => (l === el ? [l, c, ec] : [l, c, el, ec]);
const top = new W();
top.msg(1, new W().int(1, 0).msg(2, new W().str(1, "swan-syntax").str(2, "1")).str(3, "file://" + repo).int(4, 1));
let nOcc = 0;
const tok: Record<Lang, RegExp> = {
  go: /[A-Za-z_]\w*/g, shell: /[A-Za-z_][\w:\-]*/g, make: /[A-Za-z0-9_][\w.\-\/]*/g, ruby: /[A-Za-z_]\w*[?!]?/g, lua: /[A-Za-z_]\w*/g,
};
for (const f of files) {
  const doc = new W().str(1, f.rel).str(4, f.lang === "make" ? "Makefile" : f.lang);
  const own = defs.filter((d) => d.file === f.rel);
  const defAt = new Set(own.map((d) => `${d.line}:${d.col}`));
  const mine = [...modules.filter((d) => d.file === f.rel), ...own];
  for (const d of mine) {
    const len = d.kind === 29 ? 0 : d.name.length;
    doc.msg(2, new W().packed(1, [d.line, d.col, d.col + len]).str(2, d.sym).int(3, 1)
      .packed(7, span(d.line, 0, d.end, d.endCol)));
    nOcc++;
  }
  const dir = posix.dirname(f.rel);
  f.lines.forEach((raw, i) => {
    const code = f.lang === "shell" ? raw.replace(/(^|\s)#.*$/, "$1") : codeOnly(raw, f.lang);
    for (const m of code.matchAll(tok[f.lang])) {
      const col = m.index!;
      if (defAt.has(`${i}:${col}`)) continue;
      for (const d of resolve(m[0], f.lang, f.rel, dir, code[col - 1] === ".")) {
        doc.msg(2, new W().packed(1, [i, col, col + m[0].length]).str(2, d.sym));
        nOcc++;
      }
    }
  });
  for (const d of mine)
    doc.msg(3, new W().str(1, d.sym).str(3, "```" + f.lang + "\n" + d.sig + "\n```").int(5, d.kind).str(6, d.name));
  top.msg(2, doc);
}
writeFileSync(outPath, Uint8Array.from(top.b));
console.error(`syntax-index: ${files.length} files, ${defs.length} definitions, ${nOcc} occurrences`);
