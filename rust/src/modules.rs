// What tools/modules.json says of a language, for the map.
//
// Carried over from src/modules.goose so far: whether a language's server
// is installed here, and which language a path is of. The rest of that
// file (linters, formatters, test runners, live errors) comes with the
// commands that use it.

use crate::json::Doc;
use crate::sys;
use crate::util::{ends_with, push_replaced};

// Whether the first server listed for a language (its "lsp" list) is
// installed: the first word of its command, with {tools} as Swan's .tools.
pub fn lsp_server_present(doc: &Doc, m: Option<usize>, home: &[u8]) -> bool {
    let mut found = false;
    if let Some(list) = doc.member(m, b"lsp") {
        if let Some(cand) = doc.each(list).next() {
            if let Some(cmd) = doc.member(Some(cand), b"cmd") {
                if let Some(part) = doc.each(cmd).next() {
                    if let Some(s) = doc.as_string(Some(part)) {
                        let mut p: Vec<u8> = Vec::new();
                        push_replaced(&mut p, s, b"{tools}", &[home, b"/.tools"].concat());
                        found = sys::file_exists(&p);
                    }
                }
            }
        }
    }
    found
}

pub fn lang_of_path(p: &[u8]) -> &'static [u8] {
    let ends = |list: &[&[u8]]| list.iter().any(|e| ends_with(p, e));
    if ends(&[b".py", b".pyi"]) {
        return b"python";
    }
    if ends(&[b".rs"]) {
        return b"rust";
    }
    if ends(&[b".kt", b".kts"]) {
        return b"kotlin";
    }
    if ends(&[b".java"]) {
        return b"java";
    }
    if ends(&[b".goose"]) {
        return b"goose";
    }
    if ends(&[b".go"]) {
        return b"go";
    }
    if ends(&[b".c", b".cc", b".cpp", b".cxx", b".h", b".hpp", b".hh", b".hxx", b".cu", b".cuh"]) {
        return b"cpp";
    }
    if ends(&[b".cs"]) {
        return b"csharp";
    }
    if ends(&[b".lua"]) {
        return b"lua";
    }
    if ends(&[b".glsl", b".vert", b".frag", b".comp", b".geom", b".tesc", b".tese"]) {
        return b"glsl";
    }
    if ends(&[b".hlsl", b".hlsli", b".fx"]) {
        return b"hlsl";
    }
    if ends(&[b".wgsl"]) {
        return b"wgsl";
    }
    if ends(&[b".ts", b".tsx", b".mts", b".cts", b".js", b".jsx", b".mjs", b".cjs"]) {
        return b"typescript";
    }
    b""
}
