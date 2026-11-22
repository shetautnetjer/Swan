// Builds tree-sitter and its grammars from the same C sources the Goose
// program builds them from: goose-treesitter at the commit src/swan.goose
// imports, as the Goose build fetched it (scripts/build.sh), with the file
// and include lists of that package's own treesitter.build. The trees are
// then the Goose program's by construction: one shim (ts_shim.c), one
// runtime, the same grammars (docs/rust-port.md, stage 3).
//
// SWAN_TREESITTER_SRC: the package's folder, when it is not in
// .tools/goose-home (or $GOOSE_HOME) where the Goose build puts it.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn quoted(list: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = list;
    while let Some(a) = rest.find('"') {
        let after = &rest[a + 1..];
        let Some(b) = after.find('"') else { break };
        out.push(after[..b].to_string());
        rest = &after[b + 1..];
    }
    out
}

// The text of `key = [ ... ]` in a .build file.
fn list_of(build: &str, key: &str) -> Vec<String> {
    let at = build.find(&format!("{key} = [")).unwrap_or_else(|| panic!("treesitter.build has no {key}"));
    let body = &build[at..];
    let end = body.find(']').expect("an unclosed list in treesitter.build");
    quoted(&body[..end])
}

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let repo = manifest.parent().unwrap().to_path_buf();
    let swan_goose = repo.join("src/swan.goose");
    println!("cargo:rerun-if-changed={}", swan_goose.display());
    println!("cargo:rerun-if-env-changed=SWAN_TREESITTER_SRC");
    println!("cargo:rerun-if-env-changed=GOOSE_HOME");
    let pkg: PathBuf = match env::var_os("SWAN_TREESITTER_SRC") {
        Some(p) => PathBuf::from(p),
        None => {
            let text = fs::read_to_string(&swan_goose).expect("src/swan.goose");
            let tag = "shetautnetjer/goose-treesitter@";
            let at = text.find(tag).expect("src/swan.goose imports no goose-treesitter") + tag.len();
            let sha: String = text[at..].chars().take_while(|c| c.is_ascii_hexdigit()).collect();
            assert!(sha.len() >= 12, "goose-treesitter is not imported by commit in src/swan.goose");
            let home = env::var_os("GOOSE_HOME").map(PathBuf::from).unwrap_or_else(|| repo.join(".tools/goose-home"));
            home.join("pkg/github.com/shetautnetjer/goose-treesitter").join(&sha[..12])
        }
    };
    let build_file = pkg.join("treesitter.build");
    let build = fs::read_to_string(&build_file).unwrap_or_else(|_| {
        panic!(
            "goose-treesitter is not at {}: run scripts/build.sh first (the Goose build fetches it), or set SWAN_TREESITTER_SRC",
            pkg.display()
        )
    });
    println!("cargo:rerun-if-changed={}", build_file.display());
    let mut cc = cc::Build::new();
    for inc in list_of(&build, "c_include") {
        cc.include(pkg.join(inc));
    }
    for src in list_of(&build, "c_sources") {
        let p: &Path = &pkg.join(&src);
        println!("cargo:rerun-if-changed={}", p.display());
        cc.file(p);
    }
    cc.opt_level(2).warnings(false).compile("swan_treesitter");
    for lib in list_of(&build, "c_libs") {
        println!("cargo:rustc-link-lib={lib}");
    }
}
