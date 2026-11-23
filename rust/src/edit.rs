// Editing through the map. Carried over from src/edit.goose so far: where a
// line and column sit in a text (offset_of, col_of), and the mark a file is
// given when Swan has changed it or moved its rows (mark_edited). The end of
// `swan map` uses them. The edit commands themselves come later.

use crate::db::Db;
use crate::fresh::edit_mark;
use crate::sys;

// The byte where `line` and `col` (UTF-16 units) are in `text`, whose lines
// start at `starts`.
pub fn offset_of(text: &[u8], starts: &[i64], line: i64, col: i64) -> i64 {
    if !(line >= 0 && (line as usize) < starts.len()) {
        return text.len() as i64;
    }
    let mut i = starts[line as usize] as usize;
    let mut units = 0;
    while i < text.len() && units < col && text[i] != b'\n' {
        let c = text[i];
        let n = if c < 0x80 { 1 } else if c < 0xE0 { 2 } else if c < 0xF0 { 3 } else { 4 };
        units += if n == 4 { 2 } else { 1 };
        i += n;
    }
    i as i64
}

// UTF-16 units from the start of the line holding `to` up to `to`.
pub fn col_of(text: &[u8], to: i64) -> i64 {
    let to = to as usize;
    let mut i = to;
    while i > 0 && text[i - 1] != b'\n' {
        i -= 1;
    }
    let mut units = 0;
    while i < to {
        let c = text[i];
        let n = if c < 0x80 { 1 } else if c < 0xE0 { 2 } else if c < 0xF0 { 3 } else { 4 };
        units += if n == 4 { 2 } else { 1 };
        i += n;
    }
    units
}

// Swan has changed `file` (at `path`), or moved its rows to match it. Its
// rows no longer come from a SCIP run, so the next refresh must rebuild
// them whatever SCIP says (no SCIP fingerprint starts with "e").
// The new fingerprint is "e" and the hash of the text Swan left. The mtime
// alone does not prove the file is still Swan's: file times move in clock
// ticks (4 ms on Linux before 6.13), and a write by someone else in the
// same tick has the same mtime. is_stale compares the text too.
// A file with no rows (a language Swan only searches, Lua say) gets a files
// row here, so its next edit is not mistaken for an outside change.
pub fn mark_edited(db: &Db, file: &[u8], path: &[u8]) {
    let st = db.prepare_or_die(
        b"
        INSERT INTO files (file, hash, rows, edited_mtime) VALUES (?1, ?3, 0, ?2)
        ON CONFLICT(file) DO UPDATE SET edited_mtime = excluded.edited_mtime, hash = excluded.hash
        ",
    );
    let mut text: Vec<u8> = Vec::new();
    sys::read_file(path, &mut text);
    st.bind_text(1, file);
    st.bind_int(2, sys::mtime_ns(path));
    st.bind_text(3, &edit_mark(&text));
    st.step_done();
}
