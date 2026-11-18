// Checks that splitting an indexer's work changes nothing: a generated
// TypeScript project with references across files is mapped once in a
// single scip-typescript run (SWAN_JOBS=1) and once split into chunks
// (SWAN_JOBS=4), and the two maps must hold the same rows.
// (Was tests/split_check.ts.)

import std;
import os;
import sqlite;
import dictionary;
import .harness;

// Every occurrence of a map, one "|"-joined line each, in a fixed order.
fn split_rows(db_path: const u8[:], rows: u8[>..]&) -> i64 {
    var err: u8[>..] = [];
    let db = sqlite::open_existing(db_path, err);
    guard db != 0 else { return -1; }
    let st = sqlite::prepare_or_die(db, """
        SELECT s.scip, o.file, o.start_line, o.start_col, o.is_def, e.scip AS enc
        FROM occurrences o JOIN symbols s ON s.id = o.symbol_id LEFT JOIN symbols e ON e.id = o.enclosing_id
        ORDER BY 2, 3, 4, 1
        """);
    var n = 0;
    var cell: u8[>..] = [];
    while sqlite::step(st, err) == 1 {
        for c in 6 {
            if c > 0 { rows.push('|'); }
            cell.clear();
            sqlite::col_text(st, c as i32, cell);
            rows.append(cell);
        }
        rows.push('\n');
        n++;
    }
    sqlite::finalize(st);
    sqlite::close(db);
    return n;
}

// Lines of a that are not lines of b, at most `max`, and how many in all.
fn split_only(a: const u8[:], b: const u8[:], shown: u8[>..]&, max: i64) -> i64 {
    var in_b = dictionary<u64, bool> {};
    each_split(b, '\n') { l => if l.len > 0 { in_b.insert(hash(l), true); } };
    var n = 0;
    each_split(a, '\n') { l =>
        if l.len > 0 && !in_b.contains(hash(l)) {
            if n < max { format(shown, l, "\n     "); }
            n++;
        }
    };
    return n;
}

// Swan's stable names for scip-typescript (src/tspatch.goose), on a copy of
// the indexer's file: applied, it carries the mark; undone, it is the file
// it was, byte for byte.
fn split_names_patch(w: const u8[:]) {
    let src = "tools/node_modules/@sourcegraph/scip-typescript/dist/src/FileIndexer.js";
    if !file_exists(src) { print("skipped: no scip-typescript in tools/node_modules"); return; }
    let copy = str(w, "/FileIndexer.js");
    let plain = str(w, "/FileIndexer.plain.js");
    var o: u8[>..] = [];
    var e: u8[>..] = [];
    guard sh(argv(["cp", src, copy]), "", o) else { return; }
    run(argv(["bin/swan", "scip-typescript-patch", copy, "--revert"]), "", o, e);     // whichever state the installed one is in
    guard sh(argv(["cp", copy, plain]), "", o) else { return; }
    let applied = run(argv(["bin/swan", "scip-typescript-patch", copy]), "", o, e);
    var text: u8[>..] = [];
    read_file(copy, text);
    let marked = find(text, "function swanOrdinal(") >= 0 && find(text, "counter.next()") < 0;
    let again = run(argv(["bin/swan", "scip-typescript-patch", copy]), "", o, e);
    let again_said = trim(o) == "already";
    let undone = run(argv(["bin/swan", "scip-typescript-patch", copy, "--revert"]), "", o, e);
    let same = run(argv(["cmp", "-s", copy, plain]), "", o, e);
    check("the stable-names patch applies to scip-typescript once, and undone leaves the file it was",
          applied == 0 && marked && again == 0 && again_said && undone == 0 && same == 0,
          str("apply ", applied, ", marked ", marked, ", again ", again, " ", again_said, ", undo ", undone, ", cmp ", same));
}

// A repo with several tsconfig projects: a root config that takes in every
// file and has no `jsx`, a package with its own tsconfig, a package whose
// tsconfig.json only references a tsconfig.app.json (with `jsx` and a
// `paths` alias), and one whose tsconfig tsc cannot read. Each file must be
// indexed under the config that owns it, whatever the number of chunks, and
// an edit in two projects must be a layer for each.
fn split_projects() {
    let w = "data/split-projects";
    rm_rf(w);
    for d in ["repo/src", "repo/packages/lib/src", "repo/packages/dash/src", "repo/apps/broken/src"] { mkdir_p(str(w, "/", d)); }
    let r = str(w, "/repo");
    let opts = "\"strict\":true,\"noEmit\":true,\"module\":\"esnext\",\"moduleResolution\":\"bundler\"";
    write_file(str(r, "/package.json"), "{\"name\":\"projects\",\"private\":true,\"type\":\"module\"}\n");
    write_file(str(r, "/tsconfig.json"), str("{\"compilerOptions\":{", opts, "}}\n"));
    write_file(str(r, "/src/main.ts"), "import { shout } from \"../packages/lib/src/shout\";\nexport const loud = shout(\"x\");\n");
    write_file(str(r, "/packages/lib/tsconfig.json"), str("{\"compilerOptions\":{", opts, "},\"include\":[\"src\"]}\n"));
    write_file(str(r, "/packages/lib/src/shout.ts"), "export function shout(s: string): string {\n  return s.toUpperCase() + \"!\";\n}\n");
    write_file(str(r, "/packages/dash/tsconfig.json"), "{\n  // only points at the real one, as Vite's template does\n  \"files\": [],\n  \"references\": [{ \"path\": \"./tsconfig.app.json\" }]\n}\n");
    write_file(str(r, "/packages/dash/tsconfig.app.json"),
               str("{\"compilerOptions\":{\"jsx\":\"react-jsx\",", opts, ",\"paths\":{\"@lib/*\":[\"../lib/src/*\"]}},\"include\":[\"src\"]}\n"));
    for i in 12 {
        var t: u8[>..] = [];
        format(t, "import { shout } from \"@lib/shout\";\n");
        if i > 0 { format(t, "import { C", i - 1, " } from \"./C", i - 1, "\";\n"); }
        format(t, "export function C", i, "(props: { label: string }) {\n");
        if i > 0 { format(t, "  return <C", i - 1, " label={shout(props.label)} />;\n"); }
        else { format(t, "  return <span>{shout(props.label)}</span>;\n"); }
        format(t, "}\n");
        write_file(str(r, "/packages/dash/src/C", i, ".tsx"), t);
    }
    write_file(str(r, "/apps/broken/tsconfig.json"), "{\"extends\":\"@nope/tsconfig/base.json\",\"include\":[\"src\"]}\n");
    write_file(str(r, "/apps/broken/src/x.ts"), "export const x = 1;\n");

    var single: u8[>..] = [];
    guard sh(argv(["bin/swan", "map", r, str(w, "/single")]), envv("SWAN_JOBS", "1"), single) else { return; }
    var split: u8[>..] = [];
    guard sh(argv(["bin/swan", "map", r, str(w, "/split")]), envv("SWAN_JOBS", "4"), split) else { return; }
    check("the map says which configs own files, and that one could not be read",
          find(split, "more tsconfig projects own files") >= 0 && find(split, "1 could not be read by tsc") >= 0, split);

    // In the split map: every component's use of the one before it, and of
    // the alias-imported shout, resolved; the unread project's file mapped.
    var err: u8[>..] = [];
    var comp = 0;
    var alias = 0;
    var rel = 0;
    var broken = 0;
    let db = sqlite::open_existing(str(w, "/split/swan.db"), err);
    if db != 0 {
        let st = sqlite::prepare_or_die(db, """
            SELECT
              (SELECT COUNT(DISTINCT o.file) FROM occurrences o JOIN symbols s ON s.id = o.symbol_id
               WHERE o.is_def = 0 AND o.file LIKE 'packages/dash/src/C%.tsx' AND s.kind = 'function' AND s.def_file LIKE 'packages/dash/src/C%.tsx' AND s.def_file != o.file),
              (SELECT COUNT(DISTINCT o.file) FROM occurrences o JOIN symbols s ON s.id = o.symbol_id
               WHERE o.is_def = 0 AND o.file LIKE 'packages/dash/src/C%.tsx' AND s.name = 'shout' AND s.def_file = 'packages/lib/src/shout.ts'),
              (SELECT COUNT(*) FROM occurrences o JOIN symbols s ON s.id = o.symbol_id
               WHERE o.is_def = 0 AND o.file = 'src/main.ts' AND s.name = 'shout' AND s.def_file = 'packages/lib/src/shout.ts'),
              (SELECT COUNT(*) FROM files WHERE file = 'apps/broken/src/x.ts')
            """);
        if sqlite::step(st, err) == 1 {
            comp = sqlite::col_int(st, 0);
            alias = sqlite::col_int(st, 1);
            rel = sqlite::col_int(st, 2);
            broken = sqlite::col_int(st, 3);
        }
        sqlite::finalize(st);
        sqlite::close(db);
    }
    check("a .tsx file's import of another, in another chunk, resolves under the package's own config (jsx): 11 of 11 components",
          comp == 11, str(comp, " of 11\n", split));
    check("an import through the package's own `paths` alias resolves: shout from @lib/shout in all 12 components", alias == 12, str(alias, " of 12"));
    check("the root config still owns what no nearer config lists (src/main.ts), and the file of a config tsc cannot read",
          rel >= 2 && broken == 1, str(rel, " uses in src/main.ts, ", broken, " broken file"));

    var a: u8[>..] = [];
    var b: u8[>..] = [];
    let na = split_rows(str(w, "/single/swan.db"), a);
    split_rows(str(w, "/split/swan.db"), b);
    var shown_a: u8[>..] = [];
    var shown_b: u8[>..] = [];
    let only_a = split_only(a, b, shown_a, 3);
    let only_b = split_only(b, a, shown_b, 3);
    check(str("projects: one chunk for each project and several hold the same ", na, " rows"), only_a == 0 && only_b == 0,
          str(shown_a, "vs\n     ", shown_b));

    // An edit in two projects: a layer for each, and the map a fresh one would be.
    var t: u8[>..] = [];
    read_file(str(r, "/packages/dash/src/C11.tsx"), t);
    t.append("export function Extra() {\n  return <C10 label=\"again\" />;\n}\n");
    write_file(str(r, "/packages/dash/src/C11.tsx"), t);
    t.clear();
    read_file(str(r, "/src/main.ts"), t);
    t.append("export const louder = shout(\"y\");\n");
    write_file(str(r, "/src/main.ts"), t);
    var again: u8[>..] = [];
    guard sh(argv(["bin/swan", "map", r, str(w, "/split")]), envv("SWAN_JOBS", "4"), again) else { return; }
    var layers = 0;
    var at = find(again, "scip-typescript changed files (");
    while at >= 0 {
        layers++;
        let next = find(again[at + 1..], "scip-typescript changed files (");
        at = if next >= 0 { at + 1 + next } else { -1 };
    }
    var fresh: u8[>..] = [];
    guard sh(argv(["bin/swan", "map", r, str(w, "/fresh")]), envv("SWAN_JOBS", "4"), fresh) else { return; }
    a.clear();
    b.clear();
    let nf = split_rows(str(w, "/fresh/swan.db"), a);
    split_rows(str(w, "/split/swan.db"), b);
    shown_a.clear();
    shown_b.clear();
    let fresh_only = split_only(a, b, shown_a, 3);
    let layered_only = split_only(b, a, shown_b, 3);
    check(str("an edit in two projects is indexed as a layer for each, and the map holds the ", nf, " rows a fresh one does"),
          layers == 2 && fresh_only == 0 && layered_only == 0, str(layers, " layers\n     ", shown_a, "vs\n     ", shown_b, "\n", again));
}

fn split_suite() {
    let w = "data/split-check";
    rm_rf(w);
    mkdir_p(str(w, "/repo/src"));
    write_file(str(w, "/repo/tsconfig.json"), """{"compilerOptions":{"strict":true,"noEmit":true,"module":"esnext","moduleResolution":"bundler"},"include":["src/**/*"]}""");
    write_file(str(w, "/repo/src/types.d.ts"), "declare interface Shared { id: number }\n");
    for i in 24 {
        var t: u8[>..] = [];
        if i > 0 { format(t, "import { f", i - 1, " } from \"./m", i - 1, "\";\n"); }
        format(t, "export interface Box", i, " { value: number; inner: { depth: number } }\n");
        format(t, "export function f", i, "(n: number): number {\n  const s: Shared = { id: n };\n  return ");
        if i > 0 { format(t, "f", i - 1, "(n) + "); }
        format(t, "s.id;\n}\n");
        format(t, "export const box", i, ": Box", i, " = { value: f", i, "(", i, "), inner: { depth: ", i, " } };\n");
        write_file(str(w, "/repo/src/m", i, ".ts"), t);
    }
    // An object with two keys of one name and a type with two type literals,
    // used from eight other files, which the chunks spread out. Each use
    // reads only the second of the two: an indexer that numbers keys in the
    // order one process meets them calls it the first (six of the eight
    // uses of `steps` went to the wrong key before src/tspatch.goose).
    write_file(str(w, "/repo/src/table.ts"),
               "export const table = {\n  first: { steps: \"one\" },\n  second: { steps: [\"a\", \"b\"] },\n};\nexport type Shape = { kind: { tag: string }; size: { tag: number } };\n");
    for i in 8 {
        var t: u8[>..] = [];
        format(t, "import { table, Shape } from \"./table\";\n");
        format(t, "export function use", i, "(s: Shape): number {\n");
        for k in i { format(t, "  const pad", k, " = ", k, ";\n"); }
        format(t, "  return table.second.steps.length + s.size.tag", if i > 0 { str(" + pad", i - 1) } else { str("") }, ";\n}\n");
        write_file(str(w, "/repo/src/use", i, ".ts"), t);
    }
    var single: u8[>..] = [];
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/single")]), envv("SWAN_JOBS", "1"), single) else { return; }
    var split: u8[>..] = [];
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/split")]), envv("SWAN_JOBS", "4"), split) else { return; }

    // /scip-typescript \d+\/\d+/ in the report
    var chunked = false;
    var at = find(split, "scip-typescript ");
    while at >= 0 && !chunked {
        var k = at + 16;
        let d0 = k;
        while k < split.len && split[k] >= '0' && split[k] <= '9' { k++; }
        if k > d0 && k < split.len && split[k] == '/' {
            let d1 = k + 1;
            k = d1;
            while k < split.len && split[k] >= '0' && split[k] <= '9' { k++; }
            if k > d1 { chunked = true; }
        }
        let next = find(split[at + 1..], "scip-typescript ");
        at = if next >= 0 { at + 1 + next } else { -1 };
    }
    check("the split map ran more than one scip-typescript", chunked, split);

    var a: u8[>..] = [];
    var b: u8[>..] = [];
    let na = split_rows(str(w, "/single/swan.db"), a);
    split_rows(str(w, "/split/swan.db"), b);
    var shown_a: u8[>..] = [];
    var shown_b: u8[>..] = [];
    let only_a = split_only(a, b, shown_a, 3);
    let only_b = split_only(b, a, shown_b, 3);
    check(str("split and single maps hold the same ", na, " rows"), only_a == 0 && only_b == 0,
          str(shown_a, "vs\n     ", shown_b));
    // Where the eight uses of `steps` and of `tag` point, in the split map:
    // line 3 of table.ts (the second `steps`), and the `tag` of `size`.
    var err: u8[>..] = [];
    var right = 0;
    var wrong = 0;
    let db = sqlite::open_existing(str(w, "/split/swan.db"), err);
    if db != 0 {
        let st = sqlite::prepare_or_die(db, """
            SELECT s.name, s.def_line, s.def_col FROM occurrences o JOIN symbols s ON s.id = o.symbol_id
            WHERE o.file LIKE 'src/use%.ts' AND o.is_def = 0 AND s.def_file = 'src/table.ts' AND (s.name LIKE 'steps%' OR s.name = 'tag')
            """);
        var name: u8[>..] = [];
        while sqlite::step(st, err) == 1 {
            name.clear();
            sqlite::col_text(st, 0, name);
            let line = sqlite::col_int(st, 1);
            let col = sqlite::col_int(st, 2);
            if (starts_with(name, "steps") && line == 2) || (name == "tag" && line == 4 && col > 40) { right++; } else { wrong++; }
        }
        sqlite::finalize(st);
        sqlite::close(db);
    }
    check("each chunk names another file's object keys and type literals as that file's own chunk does: 16 uses, all at the second of the two",
          right == 16 && wrong == 0, str(right, " right, ", wrong, " wrong"));
    split_names_patch(w);
    split_projects();
    split_python();
}

// The same for Python's prefix pieces: 200 standalone scripts at a repo's
// root, mapped in one scip-python run (SWAN_JOBS=1) and split by filename
// prefix (SWAN_JOBS=4), must give the same rows.
fn split_python() {
    let w = "data/split-check-py";
    rm_rf(w);
    mkdir_p(str(w, "/repo"));
    var n = 0;
    for pre in ["args", "class", "dict", "float", "int", "list", "math", "set", "str", "tuple"] {
        for i in 20 {
            var t: u8[>..] = [];
            format(t, "import json\nimport math\n\n\nclass Case", n, ":\n    def value(self) -> int:\n        return math.floor(", i, ".5)\n\n\n");
            format(t, "def run_", pre, "_", i, "() -> str:\n    case = Case", n, "()\n    return json.dumps({'v': case.value()})\n\n\nassert run_", pre, "_", i, "()\n");
            write_file(str(w, "/repo/", pre, "__case_", i, ".py"), t);
            n++;
        }
    }
    // An object with two keys of one name and a type with two type literals,
    // used from eight other files, which the chunks spread out. Each use
    // reads only the second of the two: an indexer that numbers keys in the
    // order one process meets them calls it the first (six of the eight
    // uses of `steps` went to the wrong key before src/tspatch.goose).
    write_file(str(w, "/repo/src/table.ts"),
               "export const table = {\n  first: { steps: \"one\" },\n  second: { steps: [\"a\", \"b\"] },\n};\nexport type Shape = { kind: { tag: string }; size: { tag: number } };\n");
    for i in 8 {
        var t: u8[>..] = [];
        format(t, "import { table, Shape } from \"./table\";\n");
        format(t, "export function use", i, "(s: Shape): number {\n");
        for k in i { format(t, "  const pad", k, " = ", k, ";\n"); }
        format(t, "  return table.second.steps.length + s.size.tag", if i > 0 { str(" + pad", i - 1) } else { str("") }, ";\n}\n");
        write_file(str(w, "/repo/src/use", i, ".ts"), t);
    }
    var single: u8[>..] = [];
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/single")]), envv("SWAN_JOBS", "1"), single) else { return; }
    var split: u8[>..] = [];
    guard sh(argv(["bin/swan", "map", str(w, "/repo"), str(w, "/split")]), envv("SWAN_JOBS", "4"), split) else { return; }
    var pieces = 0;
    each_split(split, '\n') { l => if starts_with(l, "scip-python ") && find(l, "*:") > 0 { pieces++; } };
    check(str("python: the split map ran scip-python on prefix pieces (", pieces, ")"), pieces >= 4 && find(single, "*:") < 0, split);
    var a: u8[>..] = [];
    var b: u8[>..] = [];
    let na = split_rows(str(w, "/single/swan.db"), a);
    split_rows(str(w, "/split/swan.db"), b);
    var shown_a: u8[>..] = [];
    var shown_b: u8[>..] = [];
    let only_a = split_only(a, b, shown_a, 3);
    let only_b = split_only(b, a, shown_b, 3);
    check(str("python: split and single maps hold the same ", na, " rows"), na > 0 && only_a == 0 && only_b == 0,
          str(shown_a, "vs\n     ", shown_b));
}
