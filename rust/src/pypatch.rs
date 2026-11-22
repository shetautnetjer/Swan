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
//
// Carried over from src/pypatch.goose: the sites and the two files they
// patch. Making sure of the patches before a map runs scip-python
// (ensure_scip_python_patch, ensure_scip_python_site_patch) comes with the
// map itself.

use crate::sys;
use crate::util::{find, trim};

const PYPATCH_MARK: &[u8] = b"__swanReach";

// old, new, old, new, ... in the minified bundle's own names: n is
// isReachableRecursionMap, m callIsNoReturnCache, f noReturnAnalysisDepth,
// T contextManagerAnalysisDepth, v isFlowNodeReachable, I isCallNoReturn.
#[rustfmt::skip]
const PYPATCH_SITES: [&[u8]; 12] = [
    // 1. Look an answer up on entry.
    b"function v(t,i,r=!1){const o=new Set;if(n.has(t.id))return!0;n.set(t.id,!0);try{return function t(",
    b"const __swanReach=new Map,__swanProv=new Set;let __swanGate=0,__swanTaint=0,__swanLo=1/0,__swanHi=-1;function v(t,i,r=!1){const o=new Set;if(n.has(t.id))return!0;const __m=!r&&0===__swanGate&&0===T,__k=__m?t.id+\":\"+(i?i.id:0):void 0;if(__m){const e=__swanReach.get(__k);if(void 0!==e){let t=!0;if(0!==f)for(const n of __swanProv)if(n>=e[1]&&n<=e[2]){t=!1;break}if(t)return e[1]<__swanLo&&(__swanLo=e[1]),e[2]>__swanHi&&(__swanHi=e[2]),e[0]}}const __t=__swanTaint,__l=__swanLo,__h=__swanHi;__swanLo=1/0,__swanHi=-1;n.set(t.id,!0);try{const __r=function t(",
    // 2. Store it on exit, and hand the calls it depended on to the walk around it.
    b"}(t,i)}finally{n.delete(t.id)}}function _(e,t){let n=!0;",
    b"}(t,i);return __m&&__swanTaint===__t&&__swanReach.set(__k,[__r,__swanLo,__swanHi]),__r}finally{n.delete(t.id),__l<__swanLo&&(__swanLo=__l),__h>__swanHi&&(__swanHi=__h)}}function _(e,t){let n=!0;",
    // 3. isCallNoReturn: note the call consulted; a provisional or depth-limited answer taints.
    b"function I(e,t){const n=t.node;if(m.has(n.id)){return m.get(n.id)}if(f>d.maxTypeRecursionCount)return!1;m.set(n.id,!1),f++;try{",
    b"function I(e,t){const n=t.node;if(n.id<__swanLo&&(__swanLo=n.id),n.id>__swanHi&&(__swanHi=n.id),m.has(n.id)){return __swanProv.has(n.id)&&__swanTaint++,m.get(n.id)}if(f>d.maxTypeRecursionCount)return __swanTaint++,!1;m.set(n.id,!1),__swanProv.add(n.id),f++;try{",
    // 4. ... and is no longer provisional when it ends.
    b"return m.set(n.id,a),a}finally{f--}}function b(e,t){",
    b"return m.set(n.id,a),a}finally{f--,__swanProv.delete(n.id)}}function b(e,t){",
    // 5, 6. Count temporarily closed finally gates, in the reachability walk and in the type walk.
    b"try{return e.preFinallyGate.isGateClosed=!0,t(e.antecedent,i,l)}finally{e.preFinallyGate.isGateClosed=n}",
    b"try{return e.preFinallyGate.isGateClosed=!0,__swanGate++,t(e.antecedent,i,l)}finally{e.preFinallyGate.isGateClosed=n,__swanGate--}",
    b"try{let s;return t.preFinallyGate.isGateClosed=!0,e.useSpeculativeMode(t.finallyNode,(()=>{s=E(t.antecedent)})),s.isIncomplete?s:b(t,s.type,!1)}finally{t.preFinallyGate.isGateClosed=n}",
    b"try{let s;return t.preFinallyGate.isGateClosed=!0,__swanGate++,e.useSpeculativeMode(t.finallyNode,(()=>{s=E(t.antecedent)})),s.isIncomplete?s:b(t,s.type,!1)}finally{t.preFinallyGate.isGateClosed=n,__swanGate--}",
];

pub fn pypatch_count(text: &[u8], what: &[u8]) -> i64 {
    let mut n = 0;
    let mut at = 0;
    while at < text.len() {
        let i = find(&text[at..], what);
        if i < 0 {
            break;
        }
        n += 1;
        at = at + i as usize + what.len();
    }
    n
}

// The text with a patch's sites applied (or, with revert, undone) in out.
// `sites` is old, new, old, new, ... False, with nothing in out, unless
// every site is there exactly once.
fn sites_apply(text: &[u8], sites: &[&[u8]], revert: bool, out: &mut Vec<u8>) -> bool {
    out.clear();
    let pairs = sites.len() / 2;
    let from_of = |k: usize| if revert { sites[2 * k + 1] } else { sites[2 * k] };
    let to_of = |k: usize| if revert { sites[2 * k] } else { sites[2 * k + 1] };
    for k in 0..pairs {
        if pypatch_count(text, from_of(k)) != 1 {
            return false;
        }
    }
    // The sites do not overlap, so one pass in file order rebuilds the text.
    let mut at = 0;
    while at < text.len() {
        let mut best: i64 = -1;
        let mut best_k = 0;
        for k in 0..pairs {
            let i = find(&text[at..], from_of(k));
            if i >= 0 && (best < 0 || i < best) {
                best = i;
                best_k = k;
            }
        }
        if best < 0 {
            out.extend_from_slice(&text[at..]);
            break;
        }
        out.extend_from_slice(&text[at..at + best as usize]);
        out.extend_from_slice(to_of(best_k));
        at = at + best as usize + from_of(best_k).len();
    }
    true
}

// Rewrites one file of an indexer in place (whole, by rename) with a
// patch's sites; `mark` is text only the patched file holds. Returns
// "patched", "reverted", "already" (nothing to do) or "no match".
pub fn sites_patch_file(path: &[u8], sites: &[&[u8]], mark: &[u8], revert: bool) -> &'static [u8] {
    let mut text: Vec<u8> = Vec::new();
    if !sys::read_file(path, &mut text) {
        return b"no match";
    }
    let has = find(&text, mark) >= 0;
    if has != revert {
        return b"already";
    }
    let mut out: Vec<u8> = Vec::new();
    if !sites_apply(&text, sites, revert, &mut out) {
        return b"no match";
    }
    // write_file_atomic: a temporary file of its own name, synced, then
    // renamed. Two maps starting at once used to share one temporary name:
    // a reader could see a half-written bundle, and the loser reported
    // "does not fit" for a file that was being patched correctly.
    if !sys::write_file_atomic(path, &out) {
        return b"no match";
    }
    if revert {
        b"reverted"
    } else {
        b"patched"
    }
}

// scip-python's pyright-internal.js, with the memo or (revert) without.
pub fn pypatch_file(path: &[u8], revert: bool) -> &'static [u8] {
    sites_patch_file(path, &PYPATCH_SITES, PYPATCH_MARK, revert)
}

// A second fix, to dist/scip-python.js: a package installed inside the repo
// is still a package from outside.
//
// What was wrong. To name the package a definition belongs to, scip-python
// asks in three places whether the file is under the folder it runs in, and
// if so answers "this project" without looking at the environment. A
// virtualenv usually sits inside the project (.venv), so what a file took
// from an installed package with `import x` or `from x import y` was named
// as the repo itself, at the repo's version (`repo 0 fakepkg.tools/
// shout().`), while `x.y(...)` reached through the module was named right
// (`requests 2.32.5 requests.api/get().`). Seen 2026-11-18 on a project
// with a hand-made virtualenv; with the same folder copied outside the
// project every name was the package's.
//
// The fix. A file under a site-packages folder is not the project's own:
// the three shortcuts skip it, and the environment names its package.
//
// A fourth place had the same effect whatever folder a package was in. A
// class reached through a module (`requests.Response`, `unittest.TestCase`,
// `nx.Graph`) was named by the file it was used in, so always as the repo:
// `repo 0 unittest.case/TestCase#`. It is now named by its own file first,
// the way its methods already were.
//
// And the Python version. scip-python never asks its interpreter which
// Python it is: every project was read as 3.11, the newest it calls
// stable, so `if sys.version_info >= (3, 10):` took the same branch in a
// project on 3.9, and the standard library was named `python-stdlib 3.11`
// everywhere. Swan passes the version of the project's virtualenv in
// $SWAN_PY_VERSION (src/pipeline.goose) and the fifth site makes it the
// default. A version the project sets for pyright itself still wins.
const PYSITE_MARK: &[u8] = b"__swanSite";
#[rustfmt::skip]
const PYSITE_SITES: [&[u8]; 10] = [
    // 1. A definition's own package (getPackageInfo): functions, variables.
    b"return(0,R.assertNeverNormalized)(s),s.startsWith(this.cwd)?this.projectPackage:this.config.pythonEnvironment.getPackageForModule(t)}",
    b"return(0,R.assertNeverNormalized)(s),s.startsWith(this.cwd)&&s.indexOf(\"/site-packages/\")<0?this.projectPackage:this.config.pythonEnvironment.getPackageForModule(t)}",
    // 2. `import x` (visitImportAs): the module's symbol.
    b"\"visitImportAs.resolvedPath\"),e.startsWith(this.cwd)||e.startsWith(",
    b"\"visitImportAs.resolvedPath\"),e.indexOf(\"/site-packages/\")>=0?!1:e.startsWith(this.cwd)||e.startsWith(",
    // 3. A module named in an import (guessPackage).
    b"if(e.startsWith(\".\"))return this.projectPackage;if(t&&0!==t.length){const e=a.resolve(t);",
    b"if(e.startsWith(\".\"))return this.projectPackage;if(t&&0!==t.length&&t.indexOf(\"/site-packages/\")<0/*__swanSite*/){const e=a.resolve(t);",
    // 4. A class reached through a module (typeToSymbol): by the class's
    //    own file, as its methods already are, and only then by the file
    //    it is used in.
    b"if(_.isClass(i)){const t=this.getPackageInfo(e,i.details.moduleName);return p.makeClass(t,i.details.moduleName,e.value)}",
    b"if(_.isClass(i)){const t=this.guessPackage(i.details.moduleName,i.details.filePath)||this.getPackageInfo(e,i.details.moduleName);return p.makeClass(t,i.details.moduleName,e.value)}",
    // 5. Which Python the code is read as: $SWAN_PY_VERSION ("3.9.18"),
    //    3.0 to 3.12, the newest this pyright knows; a later one counts as
    //    3.12. Only when the project's own pyright settings name none.
    b"a.defaultPythonPlatform=t.pythonPlatform,a.defaultPythonVersion=t.pythonVersion,",
    b"a.defaultPythonPlatform=t.pythonPlatform,a.defaultPythonVersion=t.pythonVersion||(e=>{const t=(e||\"\").split(\".\"),n=256*+t[0]+ +t[1];if(n>=768)return n>780?780:n})(process.env.SWAN_PY_VERSION),",
];

// scip-python's scip-python.js, with that fix or (revert) without.
pub fn pysite_file(path: &[u8], revert: bool) -> &'static [u8] {
    sites_patch_file(path, &PYSITE_SITES, PYSITE_MARK, revert)
}

// Before a map runs scip-python: make sure Swan's copy has the second fix.
// `size` is the size of dist/scip-python.js now (0 if it is not there).
pub fn ensure_scip_python_site_patch(home: &[u8], size: i64, report: &mut Vec<u8>) {
    if size <= 0 {
        return;
    }
    if sys::env(b"SWAN_SCIP_PYTHON_PATCH") == b"0" {
        return;
    }
    let dist = [home, b"/tools/node_modules/@sourcegraph/scip-python/dist"].concat();
    let marker = [&dist[..], b"/.swan-site-patch"].concat();
    let mut seen: Vec<u8> = Vec::new();
    if sys::read_file(&marker, &mut seen) && trim(&seen) == size.to_string().as_bytes() {
        return;
    }
    let path = [&dist[..], b"/scip-python.js"].concat();
    let r = pysite_file(&path, false);
    // The words are the Goose program's, its file's name included.
    if r == b"patched" {
        report.extend_from_slice(b"scip-python: a package in a virtualenv inside the repo is now named as that package, not as the repo (src/pypatch.goose)\n");
    } else if r == b"no match" {
        report.extend_from_slice(b"scip-python: Swan's fix for packages in a virtualenv inside the repo does not fit this scip-python; their classes are named as the repo\n");
    }
    let mut now: Vec<u8> = Vec::new();
    if sys::read_file(&path, &mut now) {
        sys::write_file(&marker, now.len().to_string().as_bytes());
    }
}

// Before a map runs scip-python: make sure Swan's copy has the memo. `size`
// is the bundle's size now (0 if it is not there). A line goes in the
// report only when something was done or could not be.
pub fn ensure_scip_python_patch(home: &[u8], size: i64, report: &mut Vec<u8>) {
    if size <= 0 {
        return;
    }
    if sys::env(b"SWAN_SCIP_PYTHON_PATCH") == b"0" {
        return;
    }
    let dist = [home, b"/tools/node_modules/@sourcegraph/scip-python/dist"].concat();
    let marker = [&dist[..], b"/.swan-reach-patch"].concat();
    let mut seen: Vec<u8> = Vec::new();
    if sys::read_file(&marker, &mut seen) && trim(&seen) == size.to_string().as_bytes() {
        return;
    }
    let path = [&dist[..], b"/pyright-internal.js"].concat();
    let r = pypatch_file(&path, false);
    if r == b"patched" {
        report.extend_from_slice(b"scip-python: applied Swan's reachability memo to its bundled pyright (src/pypatch.goose)\n");
    } else if r == b"no match" {
        report.extend_from_slice(b"scip-python: Swan's reachability memo does not fit this scip-python; indexing unpatched (a long script of try/except blocks can be very slow)\n");
    }
    // Whatever the outcome, this exact file needs no second look.
    let mut now: Vec<u8> = Vec::new();
    if sys::read_file(&path, &mut now) {
        sys::write_file(&marker, now.len().to_string().as_bytes());
    }
}
