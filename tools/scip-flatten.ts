// Flattens a SCIP index (protobuf) into plain TSV so the Goose indexer never
// parses protobuf. No dependencies: a minimal wire-format reader for the few
// fields Swan needs (field numbers from github.com/sourcegraph/scip scip.proto).
//
//   bun tools/scip-flatten.ts [--root <repo>] <index.scip> <out-dir> [more.scip ...]
//
// With --root, Rust sources are read for one more pass: uses inside macro
// calls (vec![...], matches!(...), assert!(...)) that rust-analyzer left out
// are matched by name and written with role "name" instead of "ref". See
// rustMacroUses below.
//
// Several SCIP files (one per language, say) flatten into one set of rows;
// their symbols cannot collide, since each starts with its indexer's scheme.
//
// Writes <out-dir>/occurrences.tsv with the columns shared with the
// code-map bake-off (symbol, file, start_line, start_col, end_line, end_col,
// role def|ref|imp|name; 0-based lines and columns; imp marks the name in an
// import statement) and <out-dir>/symbols.tsv
// (symbol, display_name, kind, enclosing_symbol, first doc line, docs) and
// <out-dir>/extents.tsv (symbol, file, start_line, start_col, end_line,
// end_col): the whole span of each definition, from SCIP's enclosing_range,
// which is what lets Swan say which symbol a reference sits inside, and
// <out-dir>/relationships.tsv (symbol, file, related_symbol, flags): what a
// symbol implements, overrides or is the type of, from SCIP's relationships.
// flags is a comma list of impl, ref, type and def, as SCIP sets them.
// Document-local symbols ("local N") are dropped: agents query named symbols.

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, posix } from "node:path";

class Reader {
  pos = 0;
  constructor(public buf: Uint8Array, public end = buf.length) {}
  varint(): number {
    let result = 0, shift = 0, b: number;
    do {
      b = this.buf[this.pos++];
      result += (b & 0x7f) * 2 ** shift;
      shift += 7;
    } while (b & 0x80);
    return result;
  }
  // Calls f(field, wireType, reader) per field; length-delimited fields get a
  // sub-reader bounded to their bytes, others are skipped unless f reads them.
  fields(f: (field: number, wt: number, r: Reader) => void) {
    while (this.pos < this.end) {
      const key = this.varint();
      const field = Math.floor(key / 8), wt = key & 7;
      if (wt === 2) {
        const len = this.varint();
        const sub = new Reader(this.buf, this.pos + len);
        sub.pos = this.pos;
        f(field, wt, sub);
        this.pos += len;
      } else if (wt === 0) {
        const start = this.pos;
        f(field, wt, this);
        if (this.pos === start) this.varint();
      } else if (wt === 1) this.pos += 8;
      else if (wt === 5) this.pos += 4;
      else throw new Error(`unsupported wire type ${wt} at ${this.pos}`);
    }
  }
  at(pos: number): Reader {
    this.pos = pos;
    return this;
  }
  string(): string {
    return dec.decode(this.buf.subarray(this.pos, this.end));
  }
}
const dec = new TextDecoder();

// Tabs and newlines would break the rows. They do occur: scip-typescript names
// a destructured parameter by its source text, newlines and all.
// When scip-typescript runs from a tsconfig outside the repo (swan map's
// chunks) and the repo has no package.json, it names modules by their path
// from the filesystem root. That prefix is cut so names match a normal run.
let absPrefix = "";
function setRepoRoot(root: string) {
  const segs = posix.resolve(root).split("/").filter(Boolean);
  absPrefix = " " + segs.map((g) => (/^[\w$+\-]+$/.test(g) ? g : "`" + g.replace(/`/g, "``") + "`")).join("/") + "/";
}
const cleanText = (s: string) =>
  (absPrefix && s.includes(absPrefix) ? s.split(absPrefix).join(" ") : s).replace(/[\t\n\r]/g, " ");
// scip-typescript numbers anonymous type literals by a counter that depends
// on the order it walks files, so the same literal gets a different name in
// each run. Dropping the number keeps names stable across runs and across
// the parallel chunks swan map splits TS into. Only in a symbol's unquoted
// parts: a file name (always `quoted` in a symbol, since it holds a dot) and
// a document path keep theirs.
const clean = (s: string) =>
  cleanText(s)
    .split(/(`(?:[^`]|``)*`)/)
    .map((part, i) => (i % 2 === 1 ? part : part.replace(/typeLiteral\d+/g, "typeLiteral")))
    .join("");
const ROLE_DEFINITION = 1;
const ROLE_IMPORT = 2;   // the name in an import statement: a use, not a call

const argv = process.argv.slice(2);
let repoRoot = "";
if (argv[0] === "--root") { repoRoot = argv[1]; argv.splice(0, 2); setRepoRoot(repoRoot); }
const [indexPath, outDir, ...moreIndexes] = argv;
if (!indexPath || !outDir) {
  console.error("usage: bun tools/scip-flatten.ts [--root <repo>] <index.scip> <out-dir> [more.scip ...]");
  process.exit(2);
}

// Rows per document, in document order, so each file's rows stay together.
const occByDoc = new Map<string, string[]>();
const rustDocs: { path: string; taken: Set<string> }[] = [];
// C, C++ and CUDA definitions without an enclosing range (scip-clang writes
// none), whose spans cBodies() works out from the source.
const cDefs: { path: string; symbol: string; line: number; col: number; cs: boolean }[] = [];
const ext: string[] = [];
const rel: string[] = [];
const syms = new Map<string, string>();

function symbolInfo(r: Reader, path: string) {
  let symbol = "", display = "", kind = 0, enclosing = "", doc = "", prose = "";
  const related: string[][] = [];
  r.fields((f, wt, s) => {
    if (f === 1) symbol = clean(s.string());
    else if (f === 3) {
      const text = s.string();
      if (!doc) doc = text.split("\n").find((l) => l.trim() && !l.startsWith("```")) ?? "";
      // The prose: documentation with its code blocks taken out.
      const p = text.replace(/```[\s\S]*?```/g, "").replace(/^\s*---\s*$/gm, "").trim();
      if (p) prose = prose ? `${prose} ${p}` : p;
    }
    else if (f === 5 && wt === 0) kind = s.varint();
    else if (f === 6) display = s.string();
    else if (f === 8) enclosing = s.string();
    else if (f === 4) {
      let other = "";
      const flags: string[] = [];
      s.fields((rf, rwt, x) => {
        if (rf === 1) other = clean(x.string());
        else if (rwt === 0 && rf >= 2 && rf <= 5 && x.varint()) flags.push(["", "", "ref", "impl", "type", "def"][rf]);
      });
      if (other && flags.length) related.push([other, flags.join(",")]);
    }
  });
  if (symbol && !symbol.startsWith("local ")) {
    syms.set(symbol, [symbol, display, kind, enclosing, clean(doc).slice(0, 200), clean(prose).slice(0, 600)].join("\t"));
    // Rows need the defining file, so the refresh can replace them per file.
    if (path) for (const [other, flags] of related) rel.push([symbol, path, other, flags].join("\t"));
  }
}

// rust-analyzer leaves trait impls out of SCIP's relationships, but names
// what it can in the symbol itself: a method in `impl Area for
// Tile` is `.../impl#[Tile][Area]area().` From that, and
// the references on the impl header, this recovers two impl links: the type
// implements the trait, and the method implements the trait's method.
const RUST_TRAIT_IMPL = /^(.*\/)impl#\[(`[^`]*`|[^\]]*)\]\[(`[^`]*`|[^\]]*)\](.*)$/;
const bareName = (n: string) => n.replace(/^`|`$/g, "").replace(/<.*$/s, "").trim();

function rustImplLinks(path: string, pending: { range: number[]; symbol: string; roles: number }[]) {
  const refs = pending.filter((p) => !(p.roles & ROLE_DEFINITION) && p.symbol.endsWith("#"));
  const seen = new Set<string>();
  for (const p of pending) {
    if (!(p.roles & ROLE_DEFINITION) || !p.symbol.startsWith("rust-analyzer ")) continue;
    const m = RUST_TRAIT_IMPL.exec(p.symbol);
    if (!m) continue;
    const [, , selfRaw, traitRaw, member] = m;
    const self = bareName(selfRaw), trait = bareName(traitRaw), line = p.range[0];
    // The nearest reference above the member whose symbol is the named type.
    const nearest = (name: string) => {
      let best: { range: number[]; symbol: string } | undefined;
      for (const r of refs) {
        if (r.range[0] > line) continue;
        const tail = r.symbol.slice(r.symbol.lastIndexOf("/") + 1);
        if (bareName(tail.slice(0, -1)) !== name) continue;
        if (!best || r.range[0] >= best.range[0]) best = r;
      }
      return best?.symbol;
    };
    const traitSym = nearest(trait);
    if (!traitSym) continue;
    if (member) rel.push([p.symbol, path, traitSym + member, "ref,impl"].join("\t"));
    const selfSym = nearest(self);
    const key = `${selfSym}\t${traitSym}`;
    if (selfSym && !seen.has(key)) {
      seen.add(key);
      rel.push([selfSym, path, traitSym, "impl"].join("\t"));
    }
  }
}

const defined = new Set<string>();

// No indexer here sets SCIP's Import role, so import statements are found
// in the source: a reference inside one is marked "imp" (a use, not a call).
// The statement forms per language, matched over the whole file so that
// multi-line imports count.
const IMPORT_FORMS: [RegExp, RegExp][] = [
  [/\.(m|c)?[jt]sx?$/, /^[ \t]*(?:import\b[^;]*?(?:\bfrom\s*)?["'][^"']+["']|import\s+\w+\s*=\s*require\([^)]*\)|export\s+(?:type\s+)?(?:\*|\{[^}]*\})\s*(?:as\s+\w+\s*)?from\s*["'][^"']+["'])/gm],
  [/\.pyi?$/, /^[ \t]*(?:from\s+[\w.]+\s+import\s+(?:\([^)]*\)|[^\n]*)|import\s+[^\n]*)/gm],
  [/\.rs$/, /^[ \t]*(?:pub(?:\([^)]*\))?\s+)?use\s+[^;]*;/gm],
  [/\.(java|kt|scala)$/, /^[ \t]*import\s+[^;\n]*;?/gm],
];

function markImports() {
  for (const [path, rows] of occByDoc) {
    const form = IMPORT_FORMS.find(([ext]) => ext.test(path));
    if (!form || rows.length === 0) continue;
    let text: string;
    try { text = readFileSync(join(repoRoot, path), "utf8"); } catch { continue; }
    // Statement spans as [start line, start col, end line, end col].
    const starts = [0];
    for (let i = 0; i < text.length; i++) if (text[i] === "\n") starts.push(i + 1);
    const pos = (off: number) => {
      let lo = 0, hi = starts.length - 1;
      while (lo < hi) { const mid = (lo + hi + 1) >> 1; if (starts[mid] <= off) lo = mid; else hi = mid - 1; }
      return [lo, off - starts[lo]];
    };
    const spans: number[][] = [];
    for (const m of text.matchAll(form[1])) spans.push([...pos(m.index!), ...pos(m.index! + m[0].length)]);
    if (spans.length === 0) continue;
    const inside = (l: number, c: number) =>
      spans.some(([sl, sc, el, ec]) => (l > sl || (l === sl && c >= sc)) && (l < el || (l === el && c < ec)));
    for (let i = 0; i < rows.length; i++) {
      const f = rows[i].split("\t");
      if (f[6] === "ref" && inside(+f[2], +f[3])) { f[6] = "imp"; rows[i] = f.join("\t"); }
    }
  }
}

// scip-clang and scip-dotnet give no enclosing ranges, so Swan could not say which function
// a use sits in, nor edit a function by symbol. For each function or type
// definition, this finds its body in the source: from the name, the first
// '{' before any ';' (a ';' first means a declaration, which has no body),
// to its matching '}', skipping comments, strings and character literals.
// The span starts at the definition's line, where its return type or
// keyword sits. C# adds expression bodies (`int Round() => Strike();`,
// which end at their ';') and its own strings: verbatim @"..." (no escapes,
// "" for a quote, may span lines) and raw """...""" (N quotes, no escapes).
function cBodies() {
  const texts = new Map<string, string[]>();
  for (const d of cDefs) {
    let lines = texts.get(d.path);
    if (!lines) {
      try { lines = readFileSync(join(repoRoot, d.path), "utf8").split("\n"); } catch { continue; }
      texts.set(d.path, lines);
    }
    let l = d.line, c = d.col, depth = 0, started = false, done = false;
    let inStr = "", inBlock = false, verbatim = false, arrow = false, parens = 0;
    scan: while (l < lines.length) {
      const line = lines[l];
      while (c < line.length) {
        const ch = line[c], two = line.slice(c, c + 2);
        if (inBlock) { if (two === "*/") { inBlock = false; c += 2; continue; } c++; continue; }
        if (inStr) {
          if (inStr.length > 1) { if (line.startsWith(inStr, c)) { c += inStr.length; inStr = ""; } else c++; continue; }
          if (verbatim) { if (two === '""') { c += 2; continue; } if (ch === '"') inStr = ""; c++; continue; }
          if (ch === "\\") { c += 2; continue; } if (ch === inStr) inStr = ""; c++; continue;
        }
        if (two === "//") break;
        if (two === "/*") { inBlock = true; c += 2; continue; }
        const at = d.cs && ch === '"' && /@\$?$|\$@$/.test(line.slice(Math.max(0, c - 2), c));
        if (d.cs && ch === '"' && !at && line.startsWith('"""', c)) {
          let n = 3; while (line[c + n] === '"') n++;
          inStr = '"'.repeat(n); c += n; continue;
        }
        if (ch === '"' || ch === "'") { verbatim = at; inStr = ch; c++; continue; }
        // `=>` starts an expression body only outside brackets: a lambda in a
        // constructor initializer (`: base(() => Make())`) does not.
        if (d.cs && !started && !arrow && parens === 0 && two === "=>") { arrow = true; c += 2; continue; }
        if (d.cs && !started && !arrow) { if (ch === "(" || ch === "[") parens++; else if (ch === ")" || ch === "]") parens--; }
        if (arrow) {
          // An expression body: its ';' at bracket depth 0 ends it.
          if ("({[".includes(ch)) depth++;
          else if (")}]".includes(ch)) depth--;
          else if (ch === ";" && depth === 0) { done = true; break scan; }
          c++; continue;
        }
        if (!started && ch === ";") break scan;
        if (ch === "{") { depth++; started = true; }
        else if (ch === "}" && started && --depth === 0) { done = true; break scan; }
        c++;
      }
      l++; c = 0;
    }
    if (done) ext.push([d.symbol, d.path, d.line, 0, l, c + 1].join("\t"));
  }
}

// scip-java writes method implementation links both ways (Shape#area() ->
// Circle#area() as well as Circle#area() -> Shape#area()). The owners' own
// link says which way is real: Circle# implements Shape#, so the link from
// Shape's method is dropped.
function dropReverseImplLinks() {
  const owner = (sym: string) => sym.slice(0, sym.lastIndexOf("#") + 1);
  const edges = rel.map((r) => r.split("\t"));
  const has = new Set(edges.map(([a, , b, f]) => `${a}\t${b}\t${f.includes("impl")}`));
  const typeImpl = new Set(edges.filter(([a, , , f]) => a.endsWith("#") && f.includes("impl")).map(([a, , b]) => `${a}\t${b}`));
  const keep = edges.filter(([a, , b, f]) => {
    if (!f.includes("impl") || a.endsWith("#") || !has.has(`${b}\t${a}\ttrue`)) return true;
    return !typeImpl.has(`${owner(b)}\t${owner(a)}`);
  });
  rel.length = 0;
  for (const e of keep) rel.push(e.join("\t"));
}

// rust-analyzer resolves little inside macro calls, and nothing inside a
// macro nested in another (`assert!(matches!(s, Shape::Circle(_)))`,
// `vec![Tile::new(2)]`). This pass reads each Rust file, finds macro
// call arguments by their brackets, and matches the names in them against
// this repo's own definitions: `Type::member` goes to the member when it
// exists, else to the type; a lone capitalised name or a `name(` call goes
// to the one definition with that name. Ambiguous names are skipped. The
// rows carry role "name": found by name, not resolved by the compiler.
function rustMacroUses() {
  const lastName = (sym: string) => {
    const m = /([A-Za-z_][A-Za-z0-9_]*|`[^`]*`)(?:\(\)\.|[#.])$/.exec(sym);
    return m ? bareName(m[1]) : "";
  };
  const byName = new Map<string, string[]>();
  for (const sym of defined) {
    if (!sym.startsWith("rust-analyzer ") || sym.endsWith(")") || sym.endsWith("]")) continue;
    const n = lastName(sym);
    if (!n) continue;
    if (!byName.has(n)) byName.set(n, []);
    byName.get(n)!.push(sym);
  }
  const unique = (n: string) => { const c = byName.get(n); return c && c.length === 1 ? c[0] : undefined; };
  const memberOf = (typeSym: string, member: string) => {
    const module = typeSym.slice(0, typeSym.lastIndexOf("/") + 1);
    const typeName = bareName(typeSym.slice(module.length, -1));
    for (const cand of byName.get(member) ?? []) {
      if (cand.startsWith(typeSym)) return cand;
      if (cand.startsWith(`${module}impl#[${typeName}]`) || cand.startsWith(`${module}impl#[\`${typeName}<`)) return cand;
    }
    return undefined;
  };
  for (const { path, taken } of rustDocs) {
    let text: string;
    try { text = readFileSync(join(repoRoot, path), "utf8"); } catch { continue; }
    const rows = occByDoc.get(path)!;
    const lines = text.split("\n");
    for (let ln = 0; ln < lines.length; ln++) {
      const re = /\b[a-z_][a-z0-9_]*!\s*[(\[{]/g;
      let m: RegExpExecArray | null;
      while ((m = re.exec(lines[ln]))) {
        // The arguments: up to the matching bracket, across lines, skipping strings.
        let l = ln, c = m.index + m[0].length, depth = 1, inStr = false;
        const tokens: { l: number; c: number; text: string }[] = [];
        while (l < lines.length && depth > 0) {
          const line = lines[l];
          while (c < line.length && depth > 0) {
            const ch = line[c];
            if (inStr) { if (ch === "\\") c++; else if (ch === '"') inStr = false; c++; continue; }
            if (ch === '"') { inStr = true; c++; continue; }
            if ("([{".includes(ch)) depth++;
            else if (")]}".includes(ch)) depth--;
            const id = /^[A-Za-z_][A-Za-z0-9_]*/.exec(line.slice(c));
            if (id && (c === 0 || !/[A-Za-z0-9_]/.test(line[c - 1]))) {
              tokens.push({ l, c, text: id[0] });
              c += id[0].length;
              continue;
            }
            c++;
          }
          if (depth > 0) { l++; c = 0; }
        }
        for (let i = 0; i < tokens.length; i++) {
          const t = tokens[i];
          if (taken.has(`${t.l}:${t.c}`)) continue;
          const line = lines[t.l];
          const before = line.slice(0, t.c).trimEnd();
          if (before.endsWith(".") || before.endsWith("::")) continue;   // a field, method or path tail
          const after = line.slice(t.c + t.text.length);
          let sym: string | undefined;
          let at = t, len = t.text.length;
          const path2 = /^::([A-Za-z_][A-Za-z0-9_]*)/.exec(after);
          if (/^[A-Z]/.test(t.text)) {
            const typeSym = unique(t.text);
            if (typeSym && path2) {
              const member = memberOf(typeSym, path2[1]);
              if (member) { sym = member; at = { l: t.l, c: t.c + t.text.length + 2, text: path2[1] }; len = path2[1].length; }
              else sym = typeSym;
            } else sym = typeSym;
          } else if (/^\s*\(/.test(after)) {
            const f = unique(t.text);
            if (f && f.endsWith("().")) sym = f;
          }
          if (!sym || taken.has(`${at.l}:${at.c}`)) continue;
          taken.add(`${at.l}:${at.c}`);
          rows.push([sym, path, at.l, at.c, at.l, at.c + len, "name"].join("\t"));
        }
        re.lastIndex = l === ln ? c : lines[ln].length;   // nested macros were inside these args
      }
    }
  }
}

// SCIP ranges are [line, start_col, end_col] or [start_line, start_col, end_line, end_col].
function span(r: number[]): number[] {
  return r.length === 3 ? [r[0], r[1], r[0], r[2]] : r.slice(0, 4);
}

const t0 = performance.now();
let docs = 0, dupDocs = 0;
let docBase = "", docBaseExplicit = false;
const seenDocs = new Set<string>();
// "index.scip=dir" says its document paths are relative to dir rather than
// to the repo: scip-python --target-only writes them that way.
for (const spec of [indexPath, ...moreIndexes]) {
  const eq = spec.lastIndexOf("=");
  const [file, base] = eq > 0 ? [spec.slice(0, eq), spec.slice(eq + 1)] : [spec, ""];
  docBase = base;
  docBaseExplicit = base !== "";
  flattenIndex(new Reader(new Uint8Array(readFileSync(file))));
}

function flattenIndex(root: Reader) {
root.fields((f, _wt, r) => {
  // Metadata.project_root: where document paths start. With --root and no
  // explicit base, paths are re-rooted to the repo from it.
  if (f === 1 && !docBaseExplicit && repoRoot) {
    r.fields((mf, _mwt, m) => {
      if (mf !== 3) return;
      const uri = m.string();
      if (uri.startsWith("file://")) {
        const rel = posix.relative(posix.resolve(repoRoot), decodeURIComponent(uri.slice(7)));
        docBase = rel && !rel.startsWith("..") ? rel : "";
      }
    });
    return;
  }
  if (f === 3) return symbolInfo(r, "");
  if (f !== 2) return;
  let path = "";
  const infos: Reader[] = [];
  const pending: { range: number[]; enclosing: number[]; symbol: string; roles: number }[] = [];
  r.fields((df, _dwt, d) => {
    if (df === 1) path = cleanText(docBase ? posix.normalize(posix.join(docBase, d.string())) : d.string());
    else if (df === 3) infos.push(new Reader(d.buf, d.end).at(d.pos));
    else if (df === 2) {
      const range: number[] = [], enclosing: number[] = [];
      let symbol = "", roles = 0;
      d.fields((of, owt, o) => {
        if (of === 1 || of === 7) {
          // The original packed form: [line, start, end] or [start_line, start, end_line, end].
          const into = of === 1 ? range : enclosing;
          if (owt === 2) while (o.pos < o.end) into.push(o.varint());
          else into.push(o.varint());
        } else if (of >= 8 && of <= 11) {
          // The typed form newer producers (scip-java 0.13) write instead:
          // 8/10 SingleLineRange {line, start, end}, 9/11 MultiLineRange
          // {start_line, start, end_line, end}. Zero fields are left out.
          const into = of === 8 || of === 9 ? range : enclosing;
          const parts = of === 8 || of === 10 ? [0, 0, 0] : [0, 0, 0, 0];
          o.fields((rf, rwt, r) => { if (rwt === 0 && rf >= 1 && rf <= parts.length) parts[rf - 1] = r.varint(); });
          into.length = 0;
          into.push(...parts);
        } else if (of === 2) symbol = clean(o.string());
        else if (of === 3 && owt === 0) roles = o.varint();
      });
      pending.push({ range, enclosing, symbol, roles });
    }
  });
  // Several runs over one repo (scip-python split into pieces) can each
  // write a document for the same file; the first one stands.
  // A document for the run's target itself has an empty path (it is the root).
  if (!path && docBase) path = posix.normalize(docBase);
  if (seenDocs.has(path)) { dupDocs++; return; }
  // MSBuild's obj/ folders hold generated code (scip-dotnet indexes it after
  // its restore); Swan skips them when walking a repo, so the map does too.
  if (/(^|\/)obj\//.test(path)) return;
  seenDocs.add(path);
  docs++;
  for (const info of infos) symbolInfo(info, path);
  rustImplLinks(path, pending);
  const rows = occByDoc.get(path) ?? [];
  occByDoc.set(path, rows);
  if (pending.some((p) => p.symbol.startsWith("rust-analyzer "))) {
    // Every position rust-analyzer already resolved, locals included.
    rustDocs.push({ path, taken: new Set(pending.map((p) => `${p.range[0]}:${p.range[1]}`)) });
  }
  for (const { range, enclosing, symbol, roles } of pending) {
    if (!symbol || symbol.startsWith("local ")) continue;
    if (roles & ROLE_DEFINITION) defined.add(symbol);
    if ((roles & ROLE_DEFINITION) && enclosing.length < 3 && (symbol.startsWith("cxx ") || symbol.startsWith("scip-dotnet ")) &&
        /(\)\.|#)$/.test(symbol))
      cDefs.push({ path, symbol, line: range[0], col: range[1], cs: symbol.startsWith("scip-dotnet ") });
    const role = roles & ROLE_DEFINITION ? "def" : roles & ROLE_IMPORT ? "imp" : "ref";
    rows.push([symbol, path, ...span(range), role].join("\t"));
    if (enclosing.length >= 3) ext.push([symbol, path, ...span(enclosing)].join("\t"));
  }
});
}

if (repoRoot) rustMacroUses();
if (repoRoot) cBodies();
if (repoRoot) markImports();
dropReverseImplLinks();
const occ = [...occByDoc.values()].flat();

mkdirSync(outDir, { recursive: true });
writeFileSync(join(outDir, "occurrences.tsv"), occ.join("\n") + "\n");
writeFileSync(join(outDir, "symbols.tsv"), [...syms.values()].join("\n") + "\n");
writeFileSync(join(outDir, "extents.tsv"), ext.join("\n") + "\n");
writeFileSync(join(outDir, "relationships.tsv"), rel.join("\n") + "\n");
console.error(
  `scip-flatten: ${docs} documents${dupDocs ? ` (${dupDocs} repeats dropped)` : ""}, ${occ.length} occurrences, ${syms.size} symbols, ${ext.length} extents, ${rel.length} relationships in ${Math.round(performance.now() - t0)} ms`,
);
