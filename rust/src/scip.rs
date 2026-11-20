// What a SCIP symbol string says about itself. The grammar (scip.proto):
//   <scheme> ' ' <manager> ' ' <package-name> ' ' <version> ' ' <descriptors>
// where a space inside a field is written as two, and each descriptor ends
// in a suffix: '/' namespace, '#' type, '.' term, '(disambiguator).' method,
// '(name)' parameter, '[name]' type parameter, ':' meta, '!' macro.
// Swan names the suffixes with one byte: the grammar's own for '/', '#',
// '.', ':' and '!', and 'm' method, 'p' parameter, 'g' type parameter.
// Carried over from src/scip.goose.

use crate::util::{find, starts_with};

pub fn is_ident(c: u8) -> bool {
    c.is_ascii_alphanumeric() || c == b'_' || c == b'+' || c == b'-' || c == b'$'
}

// The descriptors: everything after the four header fields.
fn descriptors_of(sym: &[u8]) -> &[u8] {
    let mut i = 0;
    let mut fields = 0;
    while i < sym.len() && fields < 4 {
        if sym[i] == b' ' {
            if i + 1 < sym.len() && sym[i + 1] == b' ' {
                i += 2;
                continue;
            }
            fields += 1;
        }
        i += 1;
    }
    &sym[i..]
}

// A name at d[at..]: an identifier, or text between backticks (`` is a
// literal backtick, kept doubled in the slice). Returns it and where it ends.
fn read_name(d: &[u8], at: usize) -> (&[u8], usize) {
    let mut i = at;
    if i < d.len() && d[i] == b'`' {
        i += 1;
        let start = i;
        while i < d.len() {
            if d[i] == b'`' {
                if i + 1 < d.len() && d[i + 1] == b'`' {
                    i += 2;
                    continue;
                }
                break;
            }
            i += 1;
        }
        let name = &d[start..i];
        return (name, if i < d.len() { i + 1 } else { i });
    }
    let start = i;
    while i < d.len() && is_ident(d[i]) {
        i += 1;
    }
    (&d[start..i], i)
}

// Calls f(name, suffix) for each descriptor, outermost first.
fn each_descriptor<'a>(d: &'a [u8], mut f: impl FnMut(&'a [u8], u8)) {
    let mut i = 0;
    while i < d.len() {
        let open = d[i];
        if open == b'(' || open == b'[' {
            let (name, end) = read_name(d, i + 1);
            i = end;
            if i < d.len() && (d[i] == b')' || d[i] == b']') {
                i += 1;
            }
            f(name, if open == b'(' { b'p' } else { b'g' });
            continue;
        }
        let (name, end) = read_name(d, i);
        i = end;
        if i >= d.len() {
            f(name, b'?');
            break;
        }
        let c = d[i];
        if c == b'(' {
            while i < d.len() && d[i] != b')' {
                i += 1;
            }
            i += 1;
            if i < d.len() && d[i] == b'.' {
                i += 1;
            }
            f(name, b'm');
        } else {
            i += 1;
            f(name, c);
        }
    }
}

// The innermost descriptor's name, its suffix and its parent's suffix ('?'
// at the top), and the Serena-style name path: the non-namespace names
// joined by '/' (Store/add), or for a module the file name itself.
pub fn describe<'a>(sym: &'a [u8], path: &mut Vec<u8>) -> (&'a [u8], u8, u8) {
    let d = descriptors_of(sym);
    let mut last: &[u8] = &d[0..0];
    let mut suffix: u8 = b'?';
    let mut parent: u8 = b'?';
    // rust-analyzer writes an impl block as `impl#[SelfType][Trait]`; the
    // name path uses the self type, as Rust code reads (Tile/new).
    let mut in_impl = 0; // 1 after impl#, 2 after its self type
    each_descriptor(d, |name, s| {
        if s == b'#' && name == b"impl" {
            in_impl = 1;
        } else if in_impl > 0 && s == b'g' {
            if in_impl == 1 {
                let lt = find(name, b"<");
                if !path.is_empty() {
                    path.push(b'/');
                }
                path.extend_from_slice(if lt > 0 { &name[..lt as usize] } else { name });
                parent = b'#';
                suffix = b'#';
                in_impl = 2;
            }
        } else {
            in_impl = 0;
            last = name;
            parent = suffix;
            suffix = s;
            if s != b'/' {
                if !path.is_empty() {
                    path.push(b'/');
                }
                path.extend_from_slice(name);
            }
        }
    });
    if path.is_empty() {
        path.extend_from_slice(last);
    }
    (last, suffix, parent)
}

// SCIP's own kind (SymbolInformation.Kind), for the indexers that set it:
// scip-typescript and rust-analyzer do, scip-python does not.
fn scip_kind_word(k: i64) -> &'static [u8] {
    match k {
        7 | 75 => b"class",
        8 => b"constant",
        9 => b"constructor",
        11 => b"enum",
        12 => b"enum_member",
        15 | 77 | 79 => b"field",
        16 | 29 => b"module",
        17 => b"function",
        18 => b"getter",
        21 | 42 => b"interface",
        25 => b"macro",
        26 | 66 | 67 | 68 | 69 | 70 | 71 | 76 | 80 => b"method",
        30 | 35 => b"namespace",
        37 | 44 | 52 => b"parameter",
        41 | 81 => b"property",
        45 => b"setter",
        49 => b"struct",
        53 => b"trait",
        54 | 55 | 57 => b"type",
        58 => b"type_parameter",
        59 => b"union",
        61 | 82 => b"variable",
        _ => b"",
    }
}

// A kind word for an agent, the same across languages. In order: the
// signature's own word (scip-typescript writes "class Store", "(method)
// add(...)"; scip-python "def add(" and "class Store"), SCIP's kind, and last
// the descriptor suffix and its parent's.
pub fn kind_word(sig: &[u8], suffix: u8, parent: u8, scip_kind: i64) -> &[u8] {
    if sig.len() > 1 && sig[0] == b'(' {
        let close = find(sig, b")");
        if close > 1 {
            return &sig[1..close as usize];
        }
    }
    let sp = find(sig, b" ");
    let first = if sp > 0 { &sig[..sp as usize] } else { sig };
    if first == b"class"
        || first == b"interface"
        || first == b"function"
        || first == b"enum"
        || first == b"module"
        || first == b"namespace"
        || first == b"type"
    {
        return first;
    }
    if first == b"var" || first == b"let" {
        return b"variable";
    }
    if first == b"const" {
        return b"constant";
    }
    if first == b"def" || first == b"async" {
        return if parent == b'#' { b"method" } else { b"function" };
    }
    let sk = scip_kind_word(scip_kind);
    if !sk.is_empty() {
        return sk;
    }
    match suffix {
        b'/' => b"namespace",
        b'#' => b"type",
        b'.' => {
            if parent == b'#' {
                b"property"
            } else {
                b"variable"
            }
        }
        b'm' => {
            if parent == b'#' {
                b"method"
            } else {
                b"function"
            }
        }
        b'p' => b"parameter",
        b'g' => b"type_parameter",
        b':' => b"meta",
        b'!' => b"macro",
        _ => b"unknown",
    }
}

// The package a symbol belongs to, "<name> <version>" from the header
// ("scip-typescript npm bun-types 1.3.7 ..." gives "bun-types 1.3.7").
pub fn package_of(sym: &[u8]) -> &[u8] {
    let mut i = 0;
    let mut field = 0;
    let mut start = 0;
    while i < sym.len() {
        if sym[i] == b' ' {
            if i + 1 < sym.len() && sym[i + 1] == b' ' {
                i += 2;
                continue;
            }
            field += 1;
            if field == 2 {
                start = i + 1;
            }
            if field == 4 {
                return &sym[start..i];
            }
        }
        i += 1;
    }
    &sym[0..0]
}

// The language, from the indexer named at the head of the symbol.
pub fn language_of(sym: &[u8]) -> &[u8] {
    let sp = find(sym, b" ");
    let scheme = if sp > 0 { &sym[..sp as usize] } else { sym };
    if scheme == b"rust-analyzer" {
        return b"rust";
    }
    if scheme == b"scip-clang" || scheme == b"cxx" {
        return b"c++"; // scip-clang writes "cxx"
    }
    if scheme == b"scip-dotnet" {
        return b"csharp";
    }
    if starts_with(scheme, b"swan-lsp-") {
        return &scheme[9..]; // `swan lsp-index`: the language is in the scheme
    }
    if starts_with(scheme, b"scip-") {
        return &scheme[5..];
    }
    scheme
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(sym: &[u8]) -> (Vec<u8>, Vec<u8>, u8, u8) {
        let mut path = Vec::new();
        let (name, s, p) = describe(sym, &mut path);
        (name.to_vec(), path, s, p)
    }

    // Symbols with the name and name path the Goose program gave them, read
    // from maps it wrote (relate, Understand-Anything and Agent-Reach,
    // 2026-11-19): a method, a backticked name, a module, impl blocks with
    // and without a trait and type arguments, a namespace, a parameter, a
    // type parameter, and a symbol from `swan lsp-index`.
    #[test]
    fn names_and_paths_are_the_goose_programs() {
        let cases: [(&[u8], &[u8], &[u8], u8, u8); 10] = [
            (
                b"scip-typescript npm @understand-anything/core 0.1.0 src/languages/`language-registry.ts`/LanguageRegistry#register().",
                b"register",
                b"LanguageRegistry/register",
                b'm',
                b'#',
            ),
            (
                b"scip-typescript npm @relate/relate 1.1.1 `index.d.ts`/CypherFloat#`<constructor>`().",
                b"<constructor>",
                b"CypherFloat/<constructor>",
                b'm',
                b'#',
            ),
            (b"scip-python python Agent-Reach 0 agent_reach/__init__:", b"__init__", b"__init__", b':', b'/'),
            (b"rust-analyzer cargo xtask 1.1.1 bin/xtask/impl#[Outcome]exit_code().", b"exit_code", b"Outcome/exit_code", b'm', b'#'),
            (b"rust-analyzer cargo xtask 1.1.1 bin/xtask/workspace/impl#[DepKind][Display]fmt().", b"fmt", b"DepKind/fmt", b'm', b'#'),
            (
                b"rust-analyzer cargo relate-graph-examples 1.1.1 lib/timebox/impl#[`RunError<E>`][Display]fmt().",
                b"fmt",
                b"RunError/fmt",
                b'm',
                b'#',
            ),
            (b"scip-typescript npm typescript 6.0.3 lib/`lib.dom.d.ts`/WebAssembly/", b"WebAssembly", b"WebAssembly", b'/', b'/'),
            (b"scip-typescript npm @relate/relate 1.1.1 `entity.js`/decodedEntity().(kind)", b"kind", b"decodedEntity/kind", b'p', b'm'),
            (b"scip-java maven . . ai/relatedb/WireEnum#fromWire().[E]", b"E", b"WireEnum/fromWire/E", b'g', b'm'),
            (
                b"swan-lsp-go . relate 0 clients/go/`abi_v2_test.go`/TestWalkerScalarsAndContainers().",
                b"TestWalkerScalarsAndContainers",
                b"TestWalkerScalarsAndContainers",
                b'm',
                b'/',
            ),
        ];
        for (sym, name, path, suffix, parent) in cases {
            assert_eq!(d(sym), (name.to_vec(), path.to_vec(), suffix, parent), "{}", String::from_utf8_lossy(sym));
        }
        assert_eq!(language_of(cases[3].0), b"rust");
        assert_eq!(language_of(cases[8].0), b"java");
        assert_eq!(package_of(b"scip-typescript npm bun-types 1.3.7 a/b#"), b"bun-types 1.3.7");
        assert_eq!(language_of(b"swan-lsp-go . . . x/"), b"go");
        assert_eq!(language_of(b"cxx . . $ f(1)."), b"c++");
        assert_eq!(kind_word(b"(method) add(a: number): void", b'm', b'#', 0), b"method");
        assert_eq!(kind_word(b"def add(self)", b'm', b'#', 0), b"method");
        assert_eq!(kind_word(b"", b'.', b'/', 0), b"variable");
        assert_eq!(kind_word(b"fn new() -> Tile", b'm', b'#', 26), b"method");
    }
}
