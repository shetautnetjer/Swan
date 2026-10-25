// Flattens a SCIP index (protobuf) into plain TSV so the Goose indexer never
// parses protobuf. No dependencies: a minimal wire-format reader for the few
// fields Swan needs (field numbers from github.com/sourcegraph/scip scip.proto).
//
//   bun tools/scip-flatten.ts <index.scip> <out-dir>
//
// Writes <out-dir>/occurrences.tsv with the columns shared with the
// code-map bake-off (symbol, file, start_line, start_col, end_line, end_col,
// role def|ref; 0-based lines and columns) and <out-dir>/symbols.tsv
// (symbol, display_name, kind, enclosing_symbol, first doc line) and
// <out-dir>/extents.tsv (symbol, file, start_line, start_col, end_line,
// end_col): the whole span of each definition, from SCIP's enclosing_range,
// which is what lets Swan say which symbol a reference sits inside, and
// <out-dir>/relationships.tsv (symbol, file, related_symbol, flags): what a
// symbol implements, overrides or is the type of, from SCIP's relationships.
// flags is a comma list of impl, ref, type and def, as SCIP sets them.
// Document-local symbols ("local N") are dropped: agents query named symbols.

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

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
  string(): string {
    return dec.decode(this.buf.subarray(this.pos, this.end));
  }
}
const dec = new TextDecoder();

// Tabs and newlines would break the rows. They do occur: scip-typescript names
// a destructured parameter by its source text, newlines and all.
const clean = (s: string) => s.replace(/[\t\n\r]/g, " ");
const ROLE_DEFINITION = 1;

const [indexPath, outDir] = process.argv.slice(2);
if (!indexPath || !outDir) {
  console.error("usage: bun tools/scip-flatten.ts <index.scip> <out-dir>");
  process.exit(2);
}

const occ: string[] = [];
const ext: string[] = [];
const rel: string[] = [];
const syms = new Map<string, string>();

function symbolInfo(r: Reader, path: string) {
  let symbol = "", display = "", kind = 0, enclosing = "", doc = "";
  const related: string[][] = [];
  r.fields((f, wt, s) => {
    if (f === 1) symbol = clean(s.string());
    else if (f === 3 && !doc) doc = s.string().split("\n").find((l) => l.trim() && !l.startsWith("```")) ?? "";
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
    syms.set(symbol, [symbol, display, kind, enclosing, clean(doc).slice(0, 200)].join("\t"));
    // Rows need the defining file, so the refresh can replace them per file.
    if (path) for (const [other, flags] of related) rel.push([symbol, path, other, flags].join("\t"));
  }
}

// SCIP ranges are [line, start_col, end_col] or [start_line, start_col, end_line, end_col].
function span(r: number[]): number[] {
  return r.length === 3 ? [r[0], r[1], r[0], r[2]] : r.slice(0, 4);
}

const t0 = performance.now();
const root = new Reader(new Uint8Array(readFileSync(indexPath)));
let docs = 0;
root.fields((f, _wt, r) => {
  if (f === 3) return symbolInfo(r, "");
  if (f !== 2) return;
  docs++;
  let path = "";
  const pending: { range: number[]; enclosing: number[]; symbol: string; roles: number }[] = [];
  r.fields((df, _dwt, d) => {
    if (df === 1) path = clean(d.string());
    else if (df === 3) symbolInfo(d, path);
    else if (df === 2) {
      const range: number[] = [], enclosing: number[] = [];
      let symbol = "", roles = 0;
      d.fields((of, owt, o) => {
        if (of === 1 || of === 7) {
          const into = of === 1 ? range : enclosing;
          if (owt === 2) while (o.pos < o.end) into.push(o.varint());
          else into.push(o.varint());
        } else if (of === 2) symbol = clean(o.string());
        else if (of === 3 && owt === 0) roles = o.varint();
      });
      pending.push({ range, enclosing, symbol, roles });
    }
  });
  for (const { range, enclosing, symbol, roles } of pending) {
    if (!symbol || symbol.startsWith("local ")) continue;
    occ.push([symbol, path, ...span(range), roles & ROLE_DEFINITION ? "def" : "ref"].join("\t"));
    if (enclosing.length >= 3) ext.push([symbol, path, ...span(enclosing)].join("\t"));
  }
});

mkdirSync(outDir, { recursive: true });
writeFileSync(join(outDir, "occurrences.tsv"), occ.join("\n") + "\n");
writeFileSync(join(outDir, "symbols.tsv"), [...syms.values()].join("\n") + "\n");
writeFileSync(join(outDir, "extents.tsv"), ext.join("\n") + "\n");
writeFileSync(join(outDir, "relationships.tsv"), rel.join("\n") + "\n");
console.error(
  `scip-flatten: ${docs} documents, ${occ.length} occurrences, ${syms.size} symbols, ${ext.length} extents, ${rel.length} relationships in ${Math.round(performance.now() - t0)} ms`,
);
