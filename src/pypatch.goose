// A fix Swan applies to its own copy of scip-python (0.6.8, the newest
// release), in tools/node_modules: a memo for pyright's reachability walk.
//
// What was wrong. scip-python bundles an old pyright. To narrow a variable
// at a condition (`assert threw`), that pyright asks, for every assignment
// to the variable, "is there a path from this assignment to here?"
// (getDeclsForLocalVar -> isNodeReachable -> isFlowNodeReachable), and each
// question walks the file's flow graph again from scratch. A test script
// with 123 `threw = False / try / except: threw = True / assert threw`
// blocks (pydantic/monty's math__module.py, 39 KB) took 282 s to index,
// alone; current pyright checks it in 0.5 s. One such file held a whole map
// for five minutes.
//
// The fix. isFlowNodeReachable remembers its answers, keyed by the two flow
// nodes, under conditions where a fresh walk must give the same answer:
//   - not while a `finally` gate is temporarily closed (both places that
//     close one are counted), nor during a context-manager analysis, nor
//     with ignoreNoReturn;
//   - an answer is stored only if the walk never read a provisional or
//     depth-limited "does this call return?" value (isCallNoReturn's own
//     cache makes every other value final);
//   - an answer is reused during a NoReturn analysis only if none of the
//     calls being analysed lies in the range of calls the answer depended
//     on.
//
// Proof it changes no answers: the patched and unpatched indexers write
// byte-identical SCIP on Graphify (29 MB), monty's slow slice, Understand-
// Anything, the-full-monty and Swan's fixtures; tests/check/pypatch_suite
// keeps checking that on fixtures. Times: math__module.py 282 s -> 8.7 s;
// Graphify's whole-repo index 36.9 s -> 30.9 s.
//
// How it is applied. `swan map` calls ensure_scip_python_patch before it
// runs scip-python: each of the six sites must occur exactly once in
// dist/pyright-internal.js, or nothing is changed and the map says so (a
// newer scip-python will simply not match). The file is replaced whole by
// rename (from a temporary file no other process shares); a marker beside it records the size it was left at, so later
// maps do not read it again. SWAN_SCIP_PYTHON_PATCH=0 leaves the indexer
// alone. `swan scip-python-patch <file> [--revert]` applies or undoes it by
// hand (the tests use it).

import std;
import os;

let PYPATCH_MARK = "__swanReach";

// old, new, old, new, ... in the minified bundle's own names: n is
// isReachableRecursionMap, m callIsNoReturnCache, f noReturnAnalysisDepth,
// T contextManagerAnalysisDepth, v isFlowNodeReachable, I isCallNoReturn.
let PYPATCH_SITES = [
    // 1. Look an answer up on entry.
    "function v(t,i,r=!1){const o=new Set;if(n.has(t.id))return!0;n.set(t.id,!0);try{return function t(",
    "const __swanReach=new Map,__swanProv=new Set;let __swanGate=0,__swanTaint=0,__swanLo=1/0,__swanHi=-1;function v(t,i,r=!1){const o=new Set;if(n.has(t.id))return!0;const __m=!r&&0===__swanGate&&0===T,__k=__m?t.id+\":\"+(i?i.id:0):void 0;if(__m){const e=__swanReach.get(__k);if(void 0!==e){let t=!0;if(0!==f)for(const n of __swanProv)if(n>=e[1]&&n<=e[2]){t=!1;break}if(t)return e[1]<__swanLo&&(__swanLo=e[1]),e[2]>__swanHi&&(__swanHi=e[2]),e[0]}}const __t=__swanTaint,__l=__swanLo,__h=__swanHi;__swanLo=1/0,__swanHi=-1;n.set(t.id,!0);try{const __r=function t(",
    // 2. Store it on exit, and hand the calls it depended on to the walk around it.
    "}(t,i)}finally{n.delete(t.id)}}function _(e,t){let n=!0;",
    "}(t,i);return __m&&__swanTaint===__t&&__swanReach.set(__k,[__r,__swanLo,__swanHi]),__r}finally{n.delete(t.id),__l<__swanLo&&(__swanLo=__l),__h>__swanHi&&(__swanHi=__h)}}function _(e,t){let n=!0;",
    // 3. isCallNoReturn: note the call consulted; a provisional or depth-limited answer taints.
    "function I(e,t){const n=t.node;if(m.has(n.id)){return m.get(n.id)}if(f>d.maxTypeRecursionCount)return!1;m.set(n.id,!1),f++;try{",
    "function I(e,t){const n=t.node;if(n.id<__swanLo&&(__swanLo=n.id),n.id>__swanHi&&(__swanHi=n.id),m.has(n.id)){return __swanProv.has(n.id)&&__swanTaint++,m.get(n.id)}if(f>d.maxTypeRecursionCount)return __swanTaint++,!1;m.set(n.id,!1),__swanProv.add(n.id),f++;try{",
    // 4. ... and is no longer provisional when it ends.
    "return m.set(n.id,a),a}finally{f--}}function b(e,t){",
    "return m.set(n.id,a),a}finally{f--,__swanProv.delete(n.id)}}function b(e,t){",
    // 5, 6. Count temporarily closed finally gates, in the reachability walk and in the type walk.
    "try{return e.preFinallyGate.isGateClosed=!0,t(e.antecedent,i,l)}finally{e.preFinallyGate.isGateClosed=n}",
    "try{return e.preFinallyGate.isGateClosed=!0,__swanGate++,t(e.antecedent,i,l)}finally{e.preFinallyGate.isGateClosed=n,__swanGate--}",
    "try{let s;return t.preFinallyGate.isGateClosed=!0,e.useSpeculativeMode(t.finallyNode,(()=>{s=E(t.antecedent)})),s.isIncomplete?s:b(t,s.type,!1)}finally{t.preFinallyGate.isGateClosed=n}",
    "try{let s;return t.preFinallyGate.isGateClosed=!0,__swanGate++,e.useSpeculativeMode(t.finallyNode,(()=>{s=E(t.antecedent)})),s.isIncomplete?s:b(t,s.type,!1)}finally{t.preFinallyGate.isGateClosed=n,__swanGate--}",
];

fn pypatch_count(text: const u8[:], what: const u8[:]) -> i64 {
    var n = 0;
    var at = 0;
    while at < text.len {
        let i = find(text[at..], what);
        if i < 0 { break; }
        n++;
        at = at + i + what.len;
    }
    return n;
}

// The text with a patch's sites applied (or, with revert, undone) in out.
// `sites` is old, new, old, new, ... False, with nothing in out, unless
// every site is there exactly once.
fn sites_apply(text: const u8[:], sites: const u8[:][:], revert: bool, out: u8[>..]&) -> bool {
    out.clear();
    let pairs = sites.len / 2;
    for k in pairs {
        let from = if revert { sites[2 * k + 1] } else { sites[2 * k] };
        if pypatch_count(text, from) != 1 { return false; }
    }
    // The sites do not overlap, so one pass in file order rebuilds the text.
    var at = 0;
    while at < text.len {
        var best = -1;
        var best_k = -1;
        for k in pairs {
            let from = if revert { sites[2 * k + 1] } else { sites[2 * k] };
            let i = find(text[at..], from);
            if i >= 0 && (best < 0 || i < best) { best = i; best_k = k; }
        }
        if best < 0 { out.append(text[at..]); break; }
        let from = if revert { sites[2 * best_k + 1] } else { sites[2 * best_k] };
        let to = if revert { sites[2 * best_k] } else { sites[2 * best_k + 1] };
        out.append(text[at..at + best]);
        out.append(to);
        at = at + best + from.len;
    }
    return true;
}

// Rewrites one file of an indexer in place (whole, by rename) with a
// patch's sites; `mark` is text only the patched file holds. Returns
// "patched", "reverted", "already" (nothing to do) or "no match".
fn sites_patch_file(path: const u8[:], sites: const u8[:][:], mark: const u8[:], revert: bool) -> const u8[:] {
    var text: u8[>..] = [];
    guard read_file(path, text) else { return "no match"; }
    let has = find(text, mark) >= 0;
    if has != revert { return "already"; }
    var out: u8[>..] = [];
    guard sites_apply(text, sites, revert, out) else { return "no match"; }
    // write_file_atomic: a temporary file of its own name, synced, then
    // renamed. Two maps starting at once used to share one temporary name:
    // a reader could see a half-written bundle, and the loser reported
    // "does not fit" for a file that was being patched correctly.
    guard write_file_atomic(path, out) else { return "no match"; }
    return if revert { "reverted" } else { "patched" };
}

// scip-python's pyright-internal.js, with the memo or (revert) without.
fn pypatch_file(path: const u8[:], revert: bool) -> const u8[:] {
    return sites_patch_file(path, PYPATCH_SITES, PYPATCH_MARK, revert);
}

// Before a map runs scip-python: make sure Swan's copy has the memo. `size`
// is the bundle's size now (0 if it is not there). A line goes in the
// report only when something was done or could not be.
fn ensure_scip_python_patch(home: const u8[:], size: i64, report: u8[>..]&) {
    guard size > 0;
    var off: u8[>..] = [];
    if env("SWAN_SCIP_PYTHON_PATCH", off) && off == "0" { return; }
    let dist = str(home, "/tools/node_modules/@sourcegraph/scip-python/dist");
    let marker = str(dist, "/.swan-reach-patch");
    var seen: u8[>..] = [];
    if read_file(marker, seen) && trim(seen) == str(size) { return; }
    let path = str(dist, "/pyright-internal.js");
    let r = pypatch_file(path, false);
    if r == "patched" {
        report.append("scip-python: applied Swan's reachability memo to its bundled pyright (src/pypatch.goose)\n");
    } else if r == "no match" {
        report.append("scip-python: Swan's reachability memo does not fit this scip-python; indexing unpatched (a long script of try/except blocks can be very slow)\n");
    }
    // Whatever the outcome, this exact file needs no second look.
    var now: u8[>..] = [];
    if read_file(path, now) { write_file(marker, str(now.len)); }
}
