// Spread-Wings beside Swan: where its program is.
//
// Carried over from src/wings.goose so far: wings_bin, which the map's
// survey needs. The broad map and its answers (the rest of that file) are
// asked for by the server and come with it, at stage 7.

use crate::run::swan_home;
use crate::sys;

// The spread-wings program: $SWAN_SPREAD_WINGS when set, else the one that
// ships with this Swan (<swan home>/bin/spread-wings, built from the wings/
// submodule at the commit Swan pins), else `spread-wings` on PATH. "" when
// none; `why` says what was tried.
pub fn wings_bin(why: &mut Vec<u8>) -> Vec<u8> {
    let v = sys::env(b"SWAN_SPREAD_WINGS");
    if !v.is_empty() {
        if sys::file_exists(&v) {
            return v;
        }
        why.extend_from_slice(&[b"SWAN_SPREAD_WINGS is ", &v[..], b", which is not there"].concat());
        return Vec::new();
    }
    let own = [&swan_home()[..], b"/bin/spread-wings"].concat();
    if sys::file_exists(&own) {
        return own;
    }
    let mut found: Vec<u8> = Vec::new();
    for d in sys::env(b"PATH").split(|&c| c == b':') {
        if found.is_empty() && !d.is_empty() && sys::file_exists(&[d, b"/spread-wings"].concat()) {
            found = [d, b"/spread-wings"].concat();
        }
    }
    if found.is_empty() {
        why.extend_from_slice(&[b"spread-wings is not beside this swan (", &own[..], b") nor on PATH: rebuild or reinstall Swan, or set SWAN_SPREAD_WINGS to its path"].concat());
    }
    found
}
