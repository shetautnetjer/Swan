// Tree-sitter for Swan: the grammars and the runtime are C (goose-
// treesitter's ts_shim.c, built by build.rs from the same sources the Goose
// program builds), reached through an opaque handle and plain slices.
// Carried over from goose-treesitter's treesitter.goose; the structural
// search (compile, search, bindings) follows with `query pattern`.
//
// Kept free of the rest of the crate, so the port's tree dumper
// (src/bin/port-trees.rs) can include it alone.

#[repr(C)]
struct TsSlice {
    data: *const u8,
    len: i64,
}

#[repr(C)]
struct TsInts {
    data: *mut i32,
    len: i64,
}

extern "C" {
    fn swan_ts_parse(lang: TsSlice, src: TsSlice) -> i64;
    fn swan_ts_free(h: i64);
    fn swan_ts_count(h: i64) -> i64;
    fn swan_ts_fill(h: i64, out: TsInts) -> i64;
}

fn slice(s: &[u8]) -> TsSlice {
    TsSlice { data: s.as_ptr(), len: s.len() as i64 }
}

// Each node is R ints: symbol, flags, start and end byte, start row and
// column (0-based), first child, next sibling (-1 for none).
pub const R: usize = 8;
#[allow(dead_code)]
pub const F_NAMED: i32 = 1;
#[allow(dead_code)]
pub const F_EXTRA: i32 = 2;
#[allow(dead_code)]
pub const F_ERROR: i32 = 4;

// Parses src into `nodes` (pre-order, the root first). False when the
// language has no grammar here.
pub fn parse(lang: &[u8], src: &[u8], nodes: &mut Vec<i32>) -> bool {
    let h = unsafe { swan_ts_parse(slice(lang), slice(src)) };
    if h == 0 {
        return false;
    }
    let n = unsafe { swan_ts_count(h) } as usize;
    nodes.clear();
    nodes.resize(n * R, 0);
    unsafe {
        swan_ts_fill(h, TsInts { data: nodes.as_mut_ptr(), len: nodes.len() as i64 });
        swan_ts_free(h);
    }
    true
}

// The grammar for a file, by its name; "" when there is none.
pub fn language_of_path(p: &[u8]) -> &'static [u8] {
    let e = |x: &[u8]| p.ends_with(x);
    if e(b".ts") || e(b".mts") || e(b".cts") {
        return b"typescript";
    }
    if e(b".tsx") {
        return b"tsx";
    }
    if e(b".js") || e(b".jsx") || e(b".mjs") || e(b".cjs") {
        return b"javascript";
    }
    if e(b".py") || e(b".pyi") {
        return b"python";
    }
    if e(b".rs") {
        return b"rust";
    }
    if e(b".java") {
        return b"java";
    }
    if e(b".c") || e(b".h") {
        return b"c";
    }
    if e(b".cc") || e(b".cpp") || e(b".cxx") || e(b".hpp") || e(b".hh") || e(b".hxx") {
        return b"cpp";
    }
    if e(b".cu") || e(b".cuh") {
        return b"cuda";
    }
    if e(b".kt") || e(b".kts") {
        return b"kotlin";
    }
    if e(b".lua") {
        return b"lua";
    }
    if e(b".glsl") || e(b".vert") || e(b".frag") || e(b".comp") || e(b".geom") || e(b".tesc") || e(b".tese") {
        return b"glsl";
    }
    if e(b".hlsl") || e(b".hlsli") || e(b".fx") {
        return b"hlsl";
    }
    if e(b".wgsl") {
        return b"wgsl";
    }
    if e(b".gd") {
        return b"gdscript";
    }
    if e(b".cs") {
        return b"csharp";
    }
    if e(b".php") {
        return b"php";
    }
    b""
}
