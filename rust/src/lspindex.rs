// swan lsp-index <repo> <out> <lang> <target.scip> [--within <folder>]: a
// map for a language that has a language server and no SCIP indexer (its
// "map_lsp" servers in tools/modules.json, or "map": "lsp"), made by asking
// the server. Its files are those its entry's "match" names. For every file
// of the language, its symbols (documentSymbol); then each definition's
// references; then what implements each interface or class, and each of
// their methods. What comes back is what the server's own compiler
// resolved, so these rows are exact, not matched by name. They are written
// as a SCIP index, which the flattener reads like any other.
//
// Symbols are named as src/lspindex.goose names them, since maps it wrote
// hold these names and the flattener and the store read the language from
// the scheme: "swan-lsp-go . <repo> 0 shapes/`shapes.go`/Square#Area()."
//
// within: a folder of the repo (a Go module); only its files are asked
// about and the server is started in it, the way an editor opens a module.
// The paths written stay relative to the repo.
//
// Limits: only what is defined in the repo is asked about, so uses of the
// standard library and of packages are not in the map; what is declared
// inside a function's body, and symbols nested more than four deep, are left
// out.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use lsp_types::request::{DocumentSymbolRequest, GotoImplementation, References, Request};
use lsp_types::{DocumentSymbol, DocumentSymbolResponse, GotoDefinitionResponse, Range, SymbolKind};
use scip::types::symbol_information::Kind;
use scip::types::{Document, Index, Metadata, Occurrence, ProtocolVersion, Relationship, SymbolInformation, TextEncoding, ToolInfo};
use serde_json::{json, Value};

use crate::lsp::{uri_path, Client, LspError};
use crate::modules::{map_entry, Entry};
use crate::syntax::{sx_basename, sx_cut, sx_dirname, sx_ident, sx_ns};
use crate::sys;
use crate::util::{hash, trim};
use crate::walk::Walk;

/// How long the server may take to start, and to answer each question.
const START: Duration = Duration::from_secs(120);
const ASK: Duration = Duration::from_secs(120);

/// A definition, from a documentSymbol answer.
struct Def {
    /// As the server names it, with a Go method's receiver taken off.
    name: String,
    /// Its descriptors: the part of its symbol after the package.
    desc: Vec<u8>,
    /// The line it is defined on, cut short.
    sig: Vec<u8>,
    file: usize,
    kind: SymbolKind,
    parent: Option<usize>,
    /// Its name.
    at: Range,
    /// All of it.
    extent: Range,
}

/// A use of a definition.
struct Ref {
    def: usize,
    line: u32,
    col: u32,
    end: u32,
}

/// What the server said, file by file.
#[derive(Default)]
struct Found {
    defs: Vec<Def>,
    /// Each file's first definition; one more at the end.
    first: Vec<usize>,
    /// A definition by where its name is: (file, line, column).
    def_at: HashMap<(usize, u32, u32), usize>,
    /// And by where it starts, its first there.
    starts_at: HashMap<(usize, u32, u32), usize>,
    /// How many callables have had each path so far (overloads).
    overloads: HashMap<Vec<u8>, usize>,
    /// The uses in each file.
    refs: Vec<Vec<Ref>>,
    /// For each definition, the ones it implements.
    implements: Vec<Vec<usize>>,
    /// Files the server gave no symbols for, though asked.
    no_symbols: usize,
    /// Other questions the server could not answer.
    unanswered: usize,
    /// Symbols listed inside a function's body, left out.
    in_bodies: usize,
}

pub fn lsp_index_main(repo: &[u8], out: &[u8], lang: &[u8], target: &[u8], within: &[u8]) -> bool {
    let t0 = Instant::now();
    let mut walk = Walk::default();
    walk.load(repo, out);
    let within: &[u8] = if within == b"." { b"" } else { within };
    let entry = match map_entry(lang) {
        Ok(e) => e,
        Err(why) => return fail(&why),
    };
    let spec = match entry.map_server(&walk, repo, out, lang) {
        Ok(s) => s,
        Err(why) => return fail(&why),
    };
    let (workspace, log) = if within.is_empty() {
        (repo.to_vec(), [out, b"/lsp-", lang, b".log"].concat())
    } else {
        ([repo, b"/", within].concat(), [out, b"/lsp-", lang, b"-", (hash(within) % 100000).to_string().as_bytes(), b".log"].concat())
    };
    let mut client = match Client::start(&spec, repo, &workspace, out, &log, START) {
        Ok(c) => c,
        Err(e) => return fail(format!("the {} language server did not start: {e}; see {}", String::from_utf8_lossy(lang), String::from_utf8_lossy(&log)).as_bytes()),
    };
    let files = files_of(&walk, repo, &entry, within);
    let cut = if within.is_empty() { 0 } else { within.len() + 1 };
    let asked = ask_all(&mut client, &spec.language_id, repo, &files, cut);
    client.shutdown();
    let found = match asked {
        Ok(f) => f,
        Err(e) => return fail(format!("the {} language server: {e}; see {}", String::from_utf8_lossy(lang), String::from_utf8_lossy(&log)).as_bytes()),
    };
    if !files.is_empty() && found.no_symbols == files.len() {
        return fail(b"the language server answered for no file");
    }
    let index = scip_index(repo, lang, &files, &found);
    let tmp = [target, b".tmp"].concat();
    let path = String::from_utf8_lossy(&tmp).into_owned();
    if scip::write_message_to_file(&path, index).is_err() || !sys::rename_file(&tmp, target) {
        sys::delete_file(&tmp);
        return fail(&[b"cannot write ", target].concat());
    }
    let refs: usize = found.refs.iter().map(Vec::len).sum();
    let impls: usize = found.implements.iter().map(Vec::len).sum();
    let unanswered = if found.unanswered > 0 { format!(", {} questions unanswered", found.unanswered) } else { String::new() };
    let in_bodies = if found.in_bodies > 0 { format!(", {} symbols inside functions (locals, parameters) not mapped", found.in_bodies) } else { String::new() };
    let line = format!(
        "lsp-index {}: {} files, {} definitions, {} references, {} implementations{unanswered}{in_bodies}, {} ms\n",
        String::from_utf8_lossy(lang),
        files.len(),
        found.defs.len(),
        refs,
        impls,
        t0.elapsed().as_millis()
    );
    sys::write_stderr(line.as_bytes());
    true
}

fn fail(why: &[u8]) -> bool {
    sys::write_stderr(&[b"lsp-index: ", why, b"\n"].concat());
    false
}

// The language's files under within, repo-relative, in the order the repo
// is walked.
fn files_of(walk: &Walk, repo: &[u8], entry: &Entry, within: &[u8]) -> Vec<Vec<u8>> {
    let mut files = Vec::new();
    walk.each_file(repo, |full, name| {
        if entry.holds(name) && full.len() > repo.len() + 1 {
            let rel = &full[repo.len() + 1..];
            if within.is_empty() || (rel.len() > within.len() + 1 && rel.starts_with(within) && rel[within.len()] == b'/') {
                files.push(rel.to_vec());
            }
        }
    });
    files
}

// One question. Err: the server is wedged or gone, and nothing more can be
// asked. Ok(Err(why)): this one went unanswered (the server said why, or
// its answer was not the shape asked for).
fn ask<R: Request>(client: &mut Client, params: Value) -> Result<Result<R::Result, String>, LspError> {
    match client.request(R::METHOD, params, ASK) {
        Ok(v) => Ok(serde_json::from_value(v).map_err(|e| format!("an answer not understood: {e}"))),
        Err(LspError::Server { code, message }) => Ok(Err(format!("{code}: {message}"))),
        Err(e) => Err(e),
    }
}

fn place(uri: &str, line: u32, col: u32) -> Value {
    json!({"textDocument": {"uri": uri}, "position": {"line": line, "character": col}})
}

fn ask_all(client: &mut Client, language_id: &str, repo: &[u8], files: &[Vec<u8>], cut: usize) -> Result<Found, LspError> {
    let by_path: HashMap<&[u8], usize> = files.iter().enumerate().map(|(i, f)| (&f[..], i)).collect();
    let mut found = Found { refs: files.iter().map(|_| Vec::new()).collect(), ..Default::default() };
    for (fi, rel) in files.iter().enumerate() {
        found.first.push(found.defs.len());
        let mut text = Vec::new();
        sys::read_file(&[repo, b"/", rel].concat(), &mut text);
        let uri = client.uri(&rel[cut..]);
        let open = json!({"textDocument": {"uri": uri, "languageId": language_id, "version": 1, "text": String::from_utf8_lossy(&text)}});
        client.notify("textDocument/didOpen", open)?;
        let why = match ask::<DocumentSymbolRequest>(client, json!({"textDocument": {"uri": uri}}))? {
            Ok(Some(DocumentSymbolResponse::Nested(symbols))) => {
                let mut ns = Vec::new();
                sx_ns(sx_dirname(rel), &mut ns);
                sx_ident(sx_basename(rel), &mut ns);
                ns.push(b'/');
                add_symbols(&mut found, fi, &ns, &text, &symbols, None, 1);
                continue;
            }
            Ok(Some(DocumentSymbolResponse::Flat(list))) if !list.is_empty() => "the server lists symbols without their nesting".to_string(),
            Ok(_) => continue,
            Err(why) => why,
        };
        found.no_symbols += 1;
        sys::write_stderr(format!("lsp-index: no symbols for {}: {}\n", String::from_utf8_lossy(rel), sx_cut_str(&why, 200)).as_bytes());
    }
    found.first.push(found.defs.len());
    found.implements = found.defs.iter().map(|_| Vec::new()).collect();

    // Each definition's references, as the server resolved them.
    for d in 0..found.defs.len() {
        let (fi, at) = (found.defs[d].file, found.defs[d].at.start);
        let mut q = place(&client.uri(&files[fi][cut..]), at.line, at.character);
        q["context"] = json!({"includeDeclaration": false});
        let Ok(locations) = ask::<References>(client, q)? else {
            found.unanswered += 1;
            continue;
        };
        for loc in locations.unwrap_or_default() {
            let Some(f2) = repo_path(loc.uri.as_str(), repo).and_then(|p| by_path.get(&p[..]).copied()) else { continue };
            let (s, e) = (loc.range.start, loc.range.end);
            if f2 == fi && s.line == at.line && s.character == at.character {
                continue; // the definition itself
            }
            let end = if e.character > s.character { e.character } else { s.character + found.defs[d].name.len() as u32 };
            found.refs[f2].push(Ref { def: d, line: s.line, col: s.character, end });
        }
    }

    // What implements each interface or class, and each of their methods:
    // SCIP keeps that on the implementing symbol, as a relationship.
    let typeish = |k: SymbolKind| k == SymbolKind::CLASS || k == SymbolKind::INTERFACE;
    for d in 0..found.defs.len() {
        let def = &found.defs[d];
        let member = def.parent.is_some_and(|p| typeish(found.defs[p].kind)) && (def.kind == SymbolKind::METHOD || def.kind == SymbolKind::FUNCTION);
        if !(typeish(def.kind) || member) {
            continue;
        }
        let (fi, at) = (def.file, def.at.start);
        let Ok(answer) = ask::<GotoImplementation>(client, place(&client.uri(&files[fi][cut..]), at.line, at.character))? else {
            found.unanswered += 1;
            continue;
        };
        let places: Vec<(String, u32, u32)> = match answer {
            None => Vec::new(),
            Some(GotoDefinitionResponse::Scalar(l)) => vec![(l.uri.as_str().to_string(), l.range.start.line, l.range.start.character)],
            Some(GotoDefinitionResponse::Array(ls)) => ls.into_iter().map(|l| (l.uri.as_str().to_string(), l.range.start.line, l.range.start.character)).collect(),
            Some(GotoDefinitionResponse::Link(ls)) => ls.into_iter().map(|l| (l.target_uri.as_str().to_string(), l.target_selection_range.start.line, l.target_selection_range.start.character)).collect(),
        };
        for (uri, line, col) in places {
            let Some(f2) = repo_path(&uri, repo).and_then(|p| by_path.get(&p[..]).copied()) else { continue };
            // A place is a definition's name, or where all of it starts
            // (PHPantom gives a class from its `class` keyword).
            if let Some(&d2) = found.def_at.get(&(f2, line, col)).or_else(|| found.starts_at.get(&(f2, line, col))) {
                if d2 != d {
                    found.implements[d2].push(d);
                }
            }
        }
    }
    Ok(found)
}

fn sx_cut_str(s: &str, n: usize) -> String {
    String::from_utf8_lossy(sx_cut(s.as_bytes(), n)).into_owned()
}

// A documentSymbol answer's symbols, nested at most four deep. What is
// declared inside a function's body (lua-language-server lists its locals,
// parameters and blocks) is left out and counted: Go's and PHP's servers do
// not list it.
fn add_symbols(found: &mut Found, file: usize, ns: &[u8], text: &[u8], symbols: &[DocumentSymbol], parent: Option<usize>, depth: usize) {
    for s in symbols {
        let Some(d) = add_def(found, file, ns, text, s, parent) else { continue };
        let Some(children) = &s.children else { continue };
        if suffix(s.kind) == b'm' {
            found.in_bodies += count(children);
        } else if depth < 4 {
            add_symbols(found, file, ns, text, children, Some(d), depth + 1);
        }
    }
}

fn count(symbols: &[DocumentSymbol]) -> usize {
    symbols.iter().map(|s| 1 + s.children.as_deref().map_or(0, count)).sum()
}

fn add_def(found: &mut Found, file: usize, ns: &[u8], text: &[u8], s: &DocumentSymbol, parent: Option<usize>) -> Option<usize> {
    let name = s.name.as_bytes();
    if name.is_empty() {
        return None;
    }
    // "(Greeter).Greet" at the top of a file (a Go method, named so by the
    // bridge) is Greet nested under the type Greeter.
    let close = name.windows(2).position(|w| w == b").");
    let receiver = match close {
        Some(c) if parent.is_none() && name.len() > 3 && name[0] == b'(' && c > 1 && c + 2 < name.len() => Some(c),
        _ => None,
    };
    let short = receiver.map_or(name, |c| &name[c + 2..]);
    let mut desc = parent.map_or_else(|| ns.to_vec(), |p| found.defs[p].desc.clone());
    if let Some(c) = receiver {
        sx_ident(&name[1..c], &mut desc);
        desc.push(b'#');
    }
    sx_ident(short, &mut desc);
    match suffix(s.kind) {
        b'm' => {
            // A second callable on the same path (an overload): SCIP's disambiguator.
            let n = found.overloads.entry(desc.clone()).or_insert(0);
            let seen = *n;
            *n += 1;
            if seen == 0 {
                desc.extend_from_slice(b"().");
            } else {
                desc.extend_from_slice(format!("(+{seen}).").as_bytes());
            }
        }
        c => desc.push(c),
    }
    let at = s.selection_range;
    let d = found.defs.len();
    found.def_at.insert((file, at.start.line, at.start.character), d);
    found.starts_at.entry((file, s.range.start.line, s.range.start.character)).or_insert(d);
    found.defs.push(Def {
        name: String::from_utf8_lossy(short).into_owned(),
        desc,
        sig: sx_cut(trim(line_of(text, at.start.line as usize)), 200).to_vec(),
        file,
        kind: s.kind,
        parent,
        at,
        extent: s.range,
    });
    Some(d)
}

// The SCIP descriptor suffix for a kind: 'm' for what is called (written
// "()."), '#' for a type, '.' for the rest.
fn suffix(k: SymbolKind) -> u8 {
    match k {
        SymbolKind::METHOD | SymbolKind::CONSTRUCTOR | SymbolKind::FUNCTION => b'm',
        SymbolKind::CLASS | SymbolKind::ENUM | SymbolKind::INTERFACE | SymbolKind::STRUCT => b'#',
        _ => b'.',
    }
}

fn scip_kind(k: SymbolKind) -> Kind {
    match k {
        SymbolKind::MODULE => Kind::Module,
        SymbolKind::NAMESPACE => Kind::Namespace,
        SymbolKind::CLASS => Kind::Class,
        SymbolKind::METHOD => Kind::Method,
        SymbolKind::FIELD => Kind::Field,
        SymbolKind::CONSTRUCTOR => Kind::Constructor,
        SymbolKind::ENUM => Kind::Enum,
        SymbolKind::INTERFACE => Kind::Interface,
        SymbolKind::FUNCTION => Kind::Function,
        SymbolKind::CONSTANT => Kind::Constant,
        SymbolKind::ENUM_MEMBER => Kind::EnumMember,
        SymbolKind::STRUCT => Kind::Struct,
        SymbolKind::TYPE_PARAMETER => Kind::TypeParameter,
        _ => Kind::Variable,
    }
}

// "swan-lsp . <repo's folder name> 0 ", the head of every symbol (the
// scheme gets the language in scip_index).
fn package(repo: &[u8]) -> Vec<u8> {
    let mut name = Vec::new();
    sx_ident(sx_basename(repo), &mut name);
    name.iter().map(|&c| if c == b' ' { b'_' } else { c }).collect()
}

// Line n (0-based) of text, without its newline.
fn line_of(text: &[u8], n: usize) -> &[u8] {
    text.split(|&c| c == b'\n').nth(n).unwrap_or_default()
}

// The repo-relative path a file:// URI names, percent-decoded; None when it
// is not inside the repo.
fn repo_path(uri: &str, repo: &[u8]) -> Option<Vec<u8>> {
    uri.strip_prefix("file://")?;
    let path = uri_path(uri);
    let inside = path.len() > repo.len() + 1 && path.starts_with(repo) && path[repo.len()] == b'/';
    inside.then(|| path[repo.len() + 1..].to_vec())
}

// SCIP's packed range: [line, start, end] on one line, else [line, start, end line, end].
fn span(l: u32, c: u32, el: u32, ec: u32) -> Vec<i32> {
    if el == l {
        vec![l as i32, c as i32, ec as i32]
    } else {
        vec![l as i32, c as i32, el as i32, ec as i32]
    }
}

fn scip_index(repo: &[u8], lang: &[u8], files: &[Vec<u8>], found: &Found) -> Index {
    let head = [b"swan-lsp-", lang, b" . ", &package(repo)[..], b" 0 "].concat();
    let symbol = |d: usize| String::from_utf8_lossy(&[&head[..], &found.defs[d].desc[..]].concat()).into_owned();
    let lang_name = String::from_utf8_lossy(lang).into_owned();
    let mut index = Index::new();
    index.metadata = Some(Metadata {
        version: ProtocolVersion::UnspecifiedProtocolVersion.into(),
        tool_info: Some(ToolInfo { name: "swan-lsp".to_string(), version: "1".to_string(), ..Default::default() }).into(),
        project_root: format!("file://{}", String::from_utf8_lossy(repo)),
        text_document_encoding: TextEncoding::UTF8.into(),
        ..Default::default()
    })
    .into();
    for (fi, rel) in files.iter().enumerate() {
        let defs = found.first[fi]..found.first[fi + 1];
        let mut doc = Document { relative_path: String::from_utf8_lossy(rel).into_owned(), language: lang_name.clone(), ..Default::default() };
        for d in defs.clone() {
            let (at, x) = (found.defs[d].at, found.defs[d].extent);
            doc.occurrences.push(Occurrence {
                range: span(at.start.line, at.start.character, at.start.line, at.end.character),
                symbol: symbol(d),
                symbol_roles: 1,
                enclosing_range: span(x.start.line, x.start.character, x.end.line, x.end.character),
                ..Default::default()
            });
        }
        for r in &found.refs[fi] {
            doc.occurrences.push(Occurrence { range: span(r.line, r.col, r.line, r.end), symbol: symbol(r.def), ..Default::default() });
        }
        for d in defs {
            let def = &found.defs[d];
            doc.symbols.push(SymbolInformation {
                symbol: symbol(d),
                documentation: vec![format!("```{lang_name}\n{}\n```", String::from_utf8_lossy(&def.sig))],
                relationships: found.implements[d].iter().map(|&t| Relationship { symbol: symbol(t), is_implementation: true, ..Default::default() }).collect(),
                kind: scip_kind(def.kind).into(),
                display_name: def.name.clone(),
                ..Default::default()
            });
        }
        index.documents.push(doc);
    }
    index
}

#[cfg(test)]
mod tests {
    use super::*;

    // The shape of gopls's answer for fixtures/tiny-go/shapes/shapes.go
    // through the bridge, with a second TotalArea for an overload, and the
    // names the Goose program's map of it holds.
    #[test]
    fn symbols_are_named_as_the_goose_program_named_them() {
        let r = |l: u32, c: u32, e: u32| json!({"start": {"line": l, "character": c}, "end": {"line": l, "character": e}});
        let sym = |name: &str, kind: u32, l: u32, children: Value| json!({"name": name, "kind": kind, "range": r(l, 0, 40), "selectionRange": r(l, 5, 9), "children": children});
        let answer = json!([
            sym("Shape", 11, 3, json!([sym("Area", 6, 4, json!([]))])),
            sym("Square", 23, 7, json!([sym("Side", 8, 7, json!([]))])),
            sym("(Square).Area", 6, 9, json!([])),
            sym("TotalArea", 12, 11, json!([])),
            sym("TotalArea", 12, 12, json!([])),
        ]);
        let symbols: Vec<DocumentSymbol> = serde_json::from_value(answer).unwrap();
        let mut found = Found::default();
        let mut ns = Vec::new();
        sx_ns(sx_dirname(b"shapes/shapes.go"), &mut ns);
        sx_ident(sx_basename(b"shapes/shapes.go"), &mut ns);
        ns.push(b'/');
        add_symbols(&mut found, 0, &ns, b"", &symbols, None, 1);
        found.first = vec![0, found.defs.len()];
        found.refs = vec![Vec::new()];
        found.implements = found.defs.iter().map(|_| Vec::new()).collect();
        let index = scip_index(b"/x/tiny-go", b"go", &[b"shapes/shapes.go".to_vec()], &found);
        let names: Vec<&str> = index.documents[0].symbols.iter().map(|s| s.symbol.as_str()).collect();
        assert_eq!(
            names,
            [
                "swan-lsp-go . tiny-go 0 shapes/`shapes.go`/Shape#",
                "swan-lsp-go . tiny-go 0 shapes/`shapes.go`/Shape#Area().",
                "swan-lsp-go . tiny-go 0 shapes/`shapes.go`/Square#",
                "swan-lsp-go . tiny-go 0 shapes/`shapes.go`/Square#Side.",
                "swan-lsp-go . tiny-go 0 shapes/`shapes.go`/Square#Area().",
                "swan-lsp-go . tiny-go 0 shapes/`shapes.go`/TotalArea().",
                "swan-lsp-go . tiny-go 0 shapes/`shapes.go`/TotalArea(+1).",
            ]
        );
        assert_eq!(index.documents[0].symbols[4].display_name, "Area");
    }

    #[test]
    fn only_uris_inside_the_repo_have_a_path() {
        assert_eq!(repo_path("file:///r/a%20b/c.go", b"/r"), Some(b"a b/c.go".to_vec()));
        assert_eq!(repo_path("file:///r2/c.go", b"/r"), None);
        assert_eq!(repo_path("file:///r", b"/r"), None);
    }
}
