//! What the server tests share: a Swan home for the binary under test.

use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

/// The binary under test inside a Swan home: swan finds its tools (bin/swan-flatten, bin/spread-wings,
/// bin/eggshell, tools/, .tools/) beside itself, two folders up from its own path, and cargo builds it where none
/// are. The home is the repository's root with `bin/swan` the binary under test and every other entry a link, but
/// for `data/`, which is the home's own and empty: the repository's holds the maps and trust list of whatever ran
/// there before. Made once per test process, in cargo's folder for test files.
static SWAN: LazyLock<PathBuf> = LazyLock::new(|| {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap().canonicalize().unwrap();
    let home = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("swan-home-{}", std::process::id()));
    let _ = fs::remove_dir_all(&home);
    fs::create_dir_all(home.join("bin")).unwrap();
    fs::create_dir_all(home.join("data")).unwrap();
    for entry in fs::read_dir(&root).unwrap() {
        let name = entry.unwrap().file_name();
        if name != "bin" && name != "data" {
            symlink(root.join(&name), home.join(&name)).unwrap();
        }
    }
    if let Ok(bins) = fs::read_dir(root.join("bin")) {
        for entry in bins {
            let name = entry.unwrap().file_name();
            if name != "swan" {
                symlink(root.join("bin").join(&name), home.join("bin").join(&name)).unwrap();
            }
        }
    }
    // A hard link, not a copy: a file being written cannot be run ("Text file busy"), and the other tests of this
    // process fork while it would be.
    fs::hard_link(env!("CARGO_BIN_EXE_swan"), home.join("bin/swan")).unwrap();
    home.join("bin/swan")
});

pub fn swan_beside_tools() -> &'static Path {
    &SWAN
}
