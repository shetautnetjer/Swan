// A fix Swan applies to its own copy of scip-typescript (0.5.2), in
// tools/node_modules: names for the properties of object literals that do
// not depend on which file is being indexed.
//
// What was wrong. scip-typescript names a property of an object literal
// `steps0`, `steps1`, ..., taking the number from a counter that belongs to
// the file it is indexing, the first time that file meets the declaration;
// a cache then keeps one name for each declaration for the rest of the
// run. So the number is "how many properties of this name this run had
// named before it first came across this one", not anything about the
// property. Swan runs the indexer as several processes (parallel chunks,
// and a layer for changed files), each over part of the project. The chunk
// holding `en.ts` named its three `steps` keys steps0, steps1, steps2 in
// source order; the chunk holding a test that read only `onboarding.steps`
// called that one steps0. In the map the test's use was linked to another
// key, 224 lines up. Found by comparing with WebStorm on
// Egonex-AI/Understand-Anything, 2026-11-17. Within one run the same can
// happen when a file that uses a property is indexed before the file that
// declares it.
//
// (Type literals have the same kind of number, `typeLiteral3`. Those need
// no fix here: a type literal is named under its owner, so the flattener
// drops the number and the owner tells them apart. A property of an object
// literal is named under its file alone, so dropping the number would make
// every `steps` of a file one symbol.)
//
// The fix. The number is the property's place among the properties of that
// name in its own file, in source order. One walk of the declaring file,
// kept for the run. Whichever process asks, and in whatever order, the
// answer is the same, and for a file indexed from top to bottom it is the
// number upstream gave.
//
// How it is applied. As for scip-python (src/pypatch.goose): `swan map`
// calls ensure_scip_typescript_patch before it plans TypeScript; each site
// must occur exactly once in dist/src/FileIndexer.js or nothing is changed.
// If the indexer cannot be patched (another version, a read-only install,
// SWAN_SCIP_TYPESCRIPT_PATCH=0) the map says so and runs TypeScript as one
// process with no layers, where the cache at least keeps one name for each
// declaration. `swan scip-typescript-patch <file> [--revert]` applies or
// undoes it by hand.

import std;
import os;

let TSPATCH_MARK = "function swanOrdinal(";

// old, new, old, new, ...
let TSPATCH_SITES = [
    // 1. The helper, after the requires.
    "const ts_inline = __importStar(require(\"./TypeScriptInternal\"));\n",
    "const ts_inline = __importStar(require(\"./TypeScriptInternal\"));\n// Swan (src/tspatch.goose): the number in the name of an object literal's\n// property (`steps2:`) is its place among the properties of that name in\n// its own file, in source order.\nconst swanOrdinals = new WeakMap();\nfunction swanOrdinal(node) {\n    const file = node.getSourceFile();\n    let table = swanOrdinals.get(file);\n    if (!table) {\n        table = new Map();\n        const counts = new Map();\n        const visit = (n) => {\n            if (ts.isPropertyAssignment(n) || ts.isShorthandPropertyAssignment(n)) {\n                const name = n.name.getText();\n                const k = counts.get(name) ?? 0;\n                counts.set(name, k + 1);\n                table.set(n, k);\n            }\n            ts.forEachChild(n, visit);\n        };\n        visit(file);\n        swanOrdinals.set(file, table);\n    }\n    return table.get(node) ?? 0;\n}\n",
    // 2. A property of an object literal: its place in its file, not a counter of the file being indexed.
    "            const name = node.name.getText();\n            let counter = this.propertyCounters.get(name);\n            if (!counter) {\n                counter = new Counter_1.Counter();\n                this.propertyCounters.set(name, counter);\n            }\n            return this.cached(node, ScipSymbol_1.ScipSymbol.global(this.scipSymbol(node.getSourceFile()), (0, Descriptor_1.metaDescriptor)(`${node.name.getText()}${counter.next()}`)));",
    "            return this.cached(node, ScipSymbol_1.ScipSymbol.global(this.scipSymbol(node.getSourceFile()), (0, Descriptor_1.metaDescriptor)(`${node.name.getText()}${swanOrdinal(node)}`)));",
];

fn tspatch_file(path: const u8[:], revert: bool) -> const u8[:] {
    return sites_patch_file(path, TSPATCH_SITES, TSPATCH_MARK, revert);
}

// Before a map plans TypeScript: make sure Swan's copy of scip-typescript
// names the properties of object literals by their place. True when it does (several
// processes may then index parts of one project); false when it could not
// be patched, with a line in the report. The answer is kept in a marker
// beside the file, with the size it was left at, so later maps read
// neither again.
fn ensure_scip_typescript_patch(home: const u8[:], report: u8[>..]&) -> bool {
    let dist = str(home, "/tools/node_modules/@sourcegraph/scip-typescript/dist/src");
    let path = str(dist, "/FileIndexer.js");
    let size = swan_file_size(path);
    guard size > 0 else { return false; }
    let marker = str(dist, "/.swan-stable-names");
    var off: u8[>..] = [];
    let wanted = !(env("SWAN_SCIP_TYPESCRIPT_PATCH", off) && off == "0");
    var seen: u8[>..] = [];
    if wanted && read_file(marker, seen) && trim(seen) == str(size, " stable") { return true; }
    var text: u8[>..] = [];
    read_file(path, text);
    var stable = find(text, TSPATCH_MARK) >= 0;
    if !stable && wanted {
        let r = tspatch_file(path, false);
        if r == "patched" {
            report.append("scip-typescript: applied Swan's stable names for the properties of object literals (src/tspatch.goose)\n");
            stable = true;
        }
    }
    if stable {
        var now: u8[>..] = [];
        if read_file(path, now) { write_file(marker, str(now.len, " stable")); }
    } else {
        report.append("scip-typescript: Swan's stable names are not applied to this indexer; TypeScript runs as one process, without layers, so that each declaration keeps one name\n");
    }
    return stable;
}
