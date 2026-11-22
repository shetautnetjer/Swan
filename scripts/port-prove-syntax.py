#!/usr/bin/env python3
"""Proves stage 3's judge for the syntax-level index can fail (AGENTS.md rule
4: a check never seen failing may be testing nothing).

Builds copies of the Rust program, each broken in one place on purpose, and
runs scripts/port-syntax.sh against each, after the unbroken program passes
it. Every copy must be caught.

    scripts/port-prove-syntax.py            every break
    scripts/port-prove-syntax.py 18 36      only these (as numbered in a run)
    scripts/port-prove-syntax.py --fit      whether each break still fits the source; builds nothing

The tree is not touched: the copies are made and built in a temporary
folder.

Exit 0: every break was caught. 1: one was not (the judge has a hole), or a
break no longer fits the source (mend BREAKS below, then run again). 2: the
judge does not pass the unbroken program, so no break proves anything.

Not among the breaks, because no index can show them:
- whether a Ruby or Lua definition is marked a method: only Go asks
  (a name after a dot goes to the methods of that name);
- "too many" ending the search at the first tier: each tier holds the one
  before it, so a later tier has too many as well;
- a type whose `[` is never closed: with or without its special case, the
  `[` is not the space a type's name must be followed by;
- a file that cannot be read being left out: as root it can be read.
"""
import os
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

HASH = "        if (lang == SX_SHELL || lang == SX_MAKE || lang == SX_RUBY) && c == b'#' && (i == 0 || sx_sp(line[i - 1])) {"
MAKEFILE = '    if name == b"GNUmakefile" || name == b"makefile" || name == b"Makefile" || ends_with(name, b".mk") {'
INTO = "            if !n.is_empty() && n[0] != b'.' && !SX_SKIP.contains(&n) && !walk.skips(&full) {"
END = '            if k == indent && starts_with(&s[k..], b"end") && (k + 3 == s.len() || !sx_w(s[k + 3])) {'
TARGET = "                    if j < s.len() && s[j] == b':' && (j + 1 == s.len() || (s[j + 1] != b'=' && s[j + 1] != b':')) {"
SHELL_REF = "        if c == b'#' && (i == 0 || sx_sp(line[i - 1])) {"
SIG = "            sig: sx_cut(trim(lines.at(line)), 200).to_vec(),"

# (file in rust/src, what is broken, the text as it is, the text broken)
BREAKS = [
    # Which files are read.
    ('syntax.rs', 'a script whose #! line names dash is not shell',
     '    for w in [&b"sh"[..], b"bash", b"zsh", b"ksh", b"dash"] {',
     '    for w in [&b"sh"[..], b"bash", b"zsh", b"ksh", b"ksh"] {'),
    ('syntax.rs', 'a #! word that only starts with "sh" is shell',
     '            if &head[i..e] == w {',
     '            if head[i..e].starts_with(w) {'),
    ('syntax.rs', 'the #! word may be on a later line',
     "    while i < head.len() && head[i] != b'\\n' {",
     '    while i < head.len() {'),
    ('syntax.rs', 'more than 128 bytes of the #! line are read',
     '    let head = &text[..text.len().min(128)];',
     '    let head = &text[..text.len().min(4096)];'),
    ('syntax.rs', 'a name with a dot is read for its #! line',
     '    if find(name, b".") >= 0 {\n        return -1;',
     '    if false && find(name, b".") >= 0 {\n        return -1;'),
    ('syntax.rs', 'a #! line naming ruby is shell',
     '    if sx_shebang_word(head, b"ruby") {\n        return SX_RUBY;',
     '    if sx_shebang_word(head, b"ruby") {\n        return SX_SHELL;'),
    ('syntax.rs', '.zsh is not shell',
     '    for e in [&b".sh"[..], b".bash", b".zsh", b".ksh"] {',
     '    for e in [&b".sh"[..], b".bash", b".ksh"] {'),
    ('syntax.rs', 'a Rakefile is not Ruby',
     '    if ends_with(name, b".rb") || name == b"Rakefile" {',
     '    if ends_with(name, b".rb") {'),
    ('syntax.rs', 'a GNUmakefile is not Make', MAKEFILE,
     '    if name == b"makefile" || name == b"Makefile" || ends_with(name, b".mk") {'),
    ('syntax.rs', 'a .mk file is not Make', MAKEFILE,
     '    if name == b"GNUmakefile" || name == b"makefile" || name == b"Makefile" {'),
    ('syntax.rs', '--skip go skips nothing',
     '        return if skip_go { -1 } else { SX_GO };',
     '        return if skip_go && false { -1 } else { SX_GO };'),
    ('main.rs', '--skip with any word skips Go',
     '        let skip_go = n == 6 && is(5, "go");',
     '        let skip_go = n == 6;'),
    # The walk.
    ('syntax.rs', 'a folder is walked last name first',
     '                for name in names.iter().rev() {',
     '                for name in names.iter() {'),
    ('syntax.rs', 'hidden folders are walked', INTO,
     '            if !n.is_empty() && !SX_SKIP.contains(&n) && !walk.skips(&full) {'),
    ('syntax.rs', 'vendor is walked',
     '    b"vendor",\n',
     '    b"vendor-",\n'),
    ('syntax.rs', 'folders git ignores are walked', INTO,
     "            if !n.is_empty() && n[0] != b'.' && !SX_SKIP.contains(&n) {"),
    ('syntax.rs', 'links are followed',
     '        if sys::is_symlink(&full) {\n            continue;',
     '        if false && sys::is_symlink(&full) {\n            continue;'),
    ('syntax.rs', 'a file of exactly the largest size is left out',
     '            if size >= 0 && size <= 1000000 {',
     '            if size >= 0 && size < 1000000 {'),
    ('syntax.rs', 'slashes after the repo are kept',
     "    while rend > 1 && repo_arg[rend - 1] == b'/' {",
     "    while false && repo_arg[rend - 1] == b'/' {"),
    # Names in a symbol.
    ('syntax.rs', "a name with '+' is quoted",
     "        if !(sx_w(c) || c == b'$' || c == b'+' || c == b'-') {",
     "        if !(sx_w(c) || c == b'$' || c == b'-') {"),
    ('syntax.rs', 'a backtick in a name is not doubled',
     "        if c == b'`' {\n            out.push(b'`');\n        }\n        out.push(c);",
     '        out.push(c);'),
    ('syntax.rs', "a space in the repo's name is kept",
     "        pkg.push(if c == b' ' { b'_' } else { c });",
     '        pkg.push(c);'),
    ('syntax.rs', "a file's own symbol leaves out its folder",
     '        sx_ns(sx_dirname(rel), &mut msym);',
     '        let _ = rel;'),
    ('syntax.rs', "a file at the repo's top is given a folder",
     '    if !(!dir.is_empty() && dir != b".") {',
     '    if dir.is_empty() {'),
    ('syntax.rs', "a Go method's symbol has no '#' after its type",
     "                                desc.push(b'#');\n                                sx_ident(&s[n0..n1], &mut desc);",
     "                                desc.push(b'.');\n                                sx_ident(&s[n0..n1], &mut desc);"),
    # Code, strings and comments.
    ('syntax.rs', "a Go string's contents are read as code",
     "            out.push(if c == q { c } else { b' ' });",
     '            out.push(c);'),
    ('syntax.rs', 'a backslash in a Go string escapes nothing',
     "            if c == b'\\\\' && q != b'`' {",
     '            if false {'),
    ('syntax.rs', 'a backslash in a Go raw string escapes',
     "            if c == b'\\\\' && q != b'`' {",
     "            if c == b'\\\\' {"),
    ('syntax.rs', 'a Go // comment is read as code',
     "        if lang == SX_GO && c == b'/' && i + 1 < line.len() && line[i + 1] == b'/' {",
     "        if false && lang == SX_GO && c == b'/' && i + 1 < line.len() && line[i + 1] == b'/' {"),
    ('syntax.rs', 'a Lua -- comment is read as code',
     "        if lang == SX_LUA && c == b'-' && i + 1 < line.len() && line[i + 1] == b'-' {",
     "        if false && lang == SX_LUA && c == b'-' && i + 1 < line.len() && line[i + 1] == b'-' {"),
    ('syntax.rs', "a '#' inside a word starts a comment", HASH,
     "        if (lang == SX_SHELL || lang == SX_MAKE || lang == SX_RUBY) && c == b'#' {"),
    ('syntax.rs', 'a Ruby comment is read as code', HASH,
     "        if (lang == SX_SHELL || lang == SX_MAKE) && c == b'#' && (i == 0 || sx_sp(line[i - 1])) {"),
    ('syntax.rs', 'a Make comment is read as code', HASH,
     "        if (lang == SX_SHELL || lang == SX_RUBY) && c == b'#' && (i == 0 || sx_sp(line[i - 1])) {"),
    ('syntax.rs', "in shell uses, a '#' inside a word starts a comment", SHELL_REF,
     "        if c == b'#' {"),
    ('syntax.rs', 'in shell uses, a comment is read as code', SHELL_REF,
     '        if false {'),
    ('syntax.rs', 'a line keeps its carriage return',
     "        if e > s && self.text[e - 1] == b'\\r' {",
     "        if false && e > s && self.text[e - 1] == b'\\r' {"),
    # Where a body ends.
    ('syntax.rs', 'a brace inside a parameter list opens the body',
     "                } else if ch == b'{' && (opened || paren == 0) {",
     "                } else if ch == b'{' {"),
    ('syntax.rs', 'a brace two lines below is not looked for',
     '            if !opened && paren == 0 && l > from + 1 {',
     '            if !opened && paren == 0 && l > from {'),
    ('syntax.rs', 'a body ends before its closing brace',
     '                        return (l, c + 1);',
     '                        return (l, c);'),
    ('syntax.rs', 'a body with no brace ends where its line starts',
     '        (from, self.at(from).len())\n    }\n\n    // Where a body closed by',
     '        (from, 0)\n    }\n\n    // Where a body closed by'),
    ('syntax.rs', 'an `end` at any indentation closes a body', END,
     '            if starts_with(&s[k..], b"end") && (k + 3 == s.len() || !sx_w(s[k + 3])) {'),
    ('syntax.rs', 'a word that starts with "end" closes a body', END,
     '            if k == indent && starts_with(&s[k..], b"end") {'),
    # Go.
    ('syntax.rs', 'a word that starts with "func" is a function',
     '                if starts_with(s, b"func") && s.len() > 4 && sx_sp(s[4]) {',
     '                if starts_with(s, b"func") && s.len() > 4 {'),
    ('syntax.rs', 'a receiver without a name is no method',
     '                        if b1 == b0 && !star {',
     '                        if false {'),
    ('syntax.rs', 'a receiver with type parameters is no method',
     "                        if r1 > r0 && k < s.len() && s[k] == b'[' {",
     '                        if false {'),
    ('syntax.rs', 'a function with type parameters is no function',
     "                        if n1 > k && after < s.len() && (s[after] == b'(' || s[after] == b'[') {",
     "                        if n1 > k && after < s.len() && s[after] == b'(' {"),
    ('syntax.rs', 'a Go method is not marked a method',
     '&s[n0..n1], SX_METHOD, i, n0, e, ec, true);',
     '&s[n0..n1], SX_METHOD, i, n0, e, ec, false);'),
    ('syntax.rs', 'a `type (` block is not opened',
     '                    go_type_block = true;\n                    done = true;',
     '                    done = true;'),
    ('syntax.rs', 'a `type (` block is never closed',
     '                if starts_with(s, b")") {\n                    go_type_block = false;',
     '                if false {\n                    go_type_block = false;'),
    ('syntax.rs', 'a word that starts with "type" is a type',
     '                    if starts_with(s, b"type") && s.len() > 4 && sx_sp(s[4]) {\n                        at = Some(sx_skip_sp(s, 4));',
     '                    if starts_with(s, b"type") && s.len() > 4 {\n                        at = Some(sx_skip_sp(s, 4));'),
    ('syntax.rs', 'an interface is a plain type',
     '                                let is_iface = starts_with(&s[w..], b"interface");',
     '                                let is_iface = false;'),
    ('syntax.rs', 'a type with type parameters is no type',
     "                        if n1 > k && n1 < s.len() && s[n1] == b'[' {",
     '                        if false {'),
    ('syntax.rs', "a plain type's body ends where its line starts",
     '                                    defs.add(&pkg, &desc, &lines, fi, lang, &s[k..n1], kind, i, k, i, lines.at(i).len(), false);',
     '                                    defs.add(&pkg, &desc, &lines, fi, lang, &s[k..n1], kind, i, k, i, 0, false);'),
    ('syntax.rs', 'a constant is a variable',
     '                        at = Some(sx_skip_sp(s, 5));\n                        kind = SX_CONSTANT;',
     '                        at = Some(sx_skip_sp(s, 5));'),
    ('syntax.rs', 'a word that starts with "var" is a variable',
     '                    if starts_with(s, b"var") && s.len() > 3 && sx_sp(s[3]) {',
     '                    if starts_with(s, b"var") && s.len() > 3 {'),
    # Shell.
    ('syntax.rs', 'a word that starts with "function" is one, in shell',
     '                if starts_with(&s[k..], b"function") && k + 8 < s.len() && sx_sp(s[k + 8]) {\n                    let a = sx_skip_sp(s, k + 8);\n                    if a < s.len() && sx_alpha(s[a]) {',
     '                if starts_with(&s[k..], b"function") && k + 8 < s.len() {\n                    let a = sx_skip_sp(s, k + 8);\n                    if a < s.len() && sx_alpha(s[a]) {'),
    ('syntax.rs', "a shell `function` name may start with a digit",
     '                    if a < s.len() && sx_alpha(s[a]) {\n                        let mut e = a + 1;',
     '                    if a < s.len() && sx_w(s[a]) {\n                        let mut e = a + 1;'),
    ('syntax.rs', "a shell `function` name ends at a ':'",
     "                        let mut e = a + 1;\n                        while e < s.len() && (sx_w(s[e]) || s[e] == b':' || s[e] == b'.' || s[e] == b'-') {",
     "                        let mut e = a + 1;\n                        while e < s.len() && (sx_w(s[e]) || s[e] == b'.' || s[e] == b'-') {"),
    ('syntax.rs', 'a shell name may start with a digit',
     '                } else if k < s.len() && sx_alpha(s[k]) {',
     '                } else if k < s.len() && sx_w(s[k]) {'),
    ('syntax.rs', "a shell name ends at a '.'",
     "                    let mut e = k + 1;\n                    while e < s.len() && (sx_w(s[e]) || s[e] == b':' || s[e] == b'.' || s[e] == b'-') {",
     "                    let mut e = k + 1;\n                    while e < s.len() && (sx_w(s[e]) || s[e] == b':' || s[e] == b'-') {"),
    ('syntax.rs', '`name ( )` with a space inside is no function',
     "                        j = sx_skip_sp(s, j + 1);\n                        if j < s.len() && s[j] == b')' {",
     "                        j += 1;\n                        if j < s.len() && s[j] == b')' {"),
    ('syntax.rs', '`name( arg )` is a function',
     "                        if j < s.len() && s[j] == b')' {\n                            name = Some((k, e));",
     '                        if j < s.len() {\n                            name = Some((k, e));'),
    # Make.
    ('syntax.rs', 'a Make line that starts with anything is a target',
     '                if !s.is_empty() && sx_w(s[0]) {',
     '                if !s.is_empty() {'),
    ('syntax.rs', "a Make target's name ends at a '/'",
     "                    while e < s.len() && (sx_w(s[e]) || s[e] == b'.' || s[e] == b'-' || s[e] == b'/') {\n                        e += 1;\n                    }\n                    let j = sx_skip_sp(s, e);",
     "                    while e < s.len() && (sx_w(s[e]) || s[e] == b'.' || s[e] == b'-') {\n                        e += 1;\n                    }\n                    let j = sx_skip_sp(s, e);"),
    ('syntax.rs', '`name::` is a target', TARGET,
     "                    if j < s.len() && s[j] == b':' && (j + 1 == s.len() || s[j + 1] != b'=') {"),
    ('syntax.rs', '`name :=` is a target', TARGET,
     "                    if j < s.len() && s[j] == b':' && (j + 1 == s.len() || s[j + 1] != b':') {"),
    ('syntax.rs', "a target's recipe is not part of it",
     'starts_with(lines.at(last + 1), b"\\t") {',
     'starts_with(lines.at(last + 1), b" ") {'),
    # Ruby.
    ('syntax.rs', 'a word that starts with "class" is one',
     '                if kw > 0 && k + kw < s.len() && sx_sp(s[k + kw]) {',
     '                if kw > 0 && k + kw < s.len() {'),
    ('syntax.rs', 'a Ruby class may start with a small letter',
     "                    if a < s.len() && s[a] >= b'A' && s[a] <= b'Z' {",
     '                    if a < s.len() && sx_alpha(s[a]) {'),
    ('syntax.rs', 'a Ruby class named A::B stops at A',
     "                        while e + 2 < s.len() && s[e] == b':' && s[e + 1] == b':' && sx_w(s[e + 2]) {",
     '                        while false {'),
    ('syntax.rs', 'a Ruby class named A::B is called A::B',
     '                            last0 = e + 2;\n',
     ''),
    ('syntax.rs', 'a Ruby class is a module, and a module a class',
     'if kw == 5 { SX_CLASS } else { SX_MODULE }',
     'if kw == 5 { SX_MODULE } else { SX_CLASS }'),
    ('syntax.rs', 'a word that starts with "def" is a method',
     '                if !done && starts_with(&s[k..], b"def") && k + 3 < s.len() && sx_sp(s[k + 3]) {',
     '                if !done && starts_with(&s[k..], b"def") && k + 3 < s.len() {'),
    ('syntax.rs', '`def self.name` is called self',
     '                    if starts_with(&s[a..], b"self.") {\n                        a += 5;\n                    }\n',
     ''),
    ('syntax.rs', "a Ruby method's name leaves out its '='",
     "                        if e < s.len() && (s[e] == b'?' || s[e] == b'!' || s[e] == b'=') {",
     "                        if e < s.len() && (s[e] == b'?' || s[e] == b'!') {"),
    # Lua.
    ('syntax.rs', '`local function` is no function',
     '                if starts_with(&s[k..], b"local") && k + 5 < s.len() && sx_sp(s[k + 5]) {',
     '                if false {'),
    ('syntax.rs', "a Lua function's name ends at a ':'",
     "                    while e < s.len() && (sx_w(s[e]) || s[e] == b'.' || s[e] == b':') {",
     "                    while e < s.len() && (sx_w(s[e]) || s[e] == b'.') {"),
    ('syntax.rs', 'a Lua function named M.f is called M.f',
     '                                n0 = x + 1;\n',
     ''),
    ('syntax.rs', 'a Lua function needs no parenthesis',
     "                    if e > a && j < s.len() && s[j] == b'(' {",
     '                    if e > a {'),
    ('syntax.rs', 'a Lua function needs no name',
     "                    if e > a && j < s.len() && s[j] == b'(' {",
     "                    if j < s.len() && s[j] == b'(' {"),
    # Uses, by name.
    ('syntax.rs', 'a Go name after a dot goes to functions too',
     '                        let only_methods = lang == SX_GO && after_dot && any_method;',
     '                        let only_methods = false && lang == SX_GO && after_dot && any_method;'),
    ('syntax.rs', 'every Go name counts as after a dot',
     "                        let after_dot = c > 0 && s[c - 1] == b'.';",
     '                        let after_dot = true;'),
    ('syntax.rs', 'a name after a dot goes to methods only in every language',
     '                        let only_methods = lang == SX_GO && after_dot && any_method;',
     '                        let only_methods = after_dot && any_method;'),
    ('syntax.rs', 'four definitions are not too many',
     '                                if n > 3 {',
     '                                if n > 4 {'),
    ('syntax.rs', 'the same folder means anywhere',
     '                                        f_dir[f2] == my_dir',
     '                                        true || f_dir[f2] == my_dir'),
    ('syntax.rs', 'the same file is not looked in first',
     '                                        f2 == fi',
     '                                        false && f2 == fi'),
    ('syntax.rs', 'a definition is also a use of itself',
     '                if !def_at.contains(&place(i, c)) {',
     '                if true || !def_at.contains(&place(i, c)) {'),
    ('syntax.rs', 'each file is a folder of its own',
     'hash(sx_dirname(rel))).or_insert(n_dirs)',
     'hash(rel)).or_insert(n_dirs)'),
    ('syntax.rs', "a Ruby use leaves out its '?'",
     "                    if lang == SX_RUBY && e < s.len() && (s[e] == b'?' || s[e] == b'!') {",
     '                    if false {'),
    ('syntax.rs', "a shell use ends at a '-'",
     "                    while e < s.len() && (sx_w(s[e]) || s[e] == b':' || s[e] == b'-') {",
     "                    while e < s.len() && (sx_w(s[e]) || s[e] == b':') {"),
    ('syntax.rs', 'a Make use cannot start with a digit',
     '                let start_ok = if lang == SX_MAKE { sx_w(ch) } else { sx_alpha(ch) };',
     '                let start_ok = sx_alpha(ch);'),
    # What is written.
    ('syntax.rs', 'a signature is not cut at 200 bytes', SIG,
     '            sig: sx_cut(trim(lines.at(line)), 2000).to_vec(),'),
    ('syntax.rs', 'a signature keeps the space before it', SIG,
     '            sig: sx_cut(lines.at(line), 200).to_vec(),'),
    ('syntax.rs', 'a signature is cut inside a character',
     '    while e > 0 && (s[e] & 192) == 128 {',
     '    while false && (s[e] & 192) == 128 {'),
    ('syntax.rs', "a Makefile's language is make",
     'if lang == SX_MAKE { b"Makefile" } else { lname }',
     'if false { b"Makefile" } else { lname }'),
    ('syntax.rs', "a file's range ends where its last line starts",
     '        pb_range(&mut occ, 7, 0, 0, last, lines.at(last).len());',
     '        pb_range(&mut occ, 7, 0, 0, last, 0);'),
    ('syntax.rs', 'a range on one line has four numbers',
     '    if el != l {',
     '    if true {'),
    ('syntax.rs', "a definition's name has no length",
     '            pb_range(&mut occ, 1, d.line, d.col, d.line, d.col + d.name.len());',
     '            pb_range(&mut occ, 1, d.line, d.col, d.line, d.col);'),
    ('syntax.rs', 'a definition is not marked one',
     '            pb_int(&mut occ, 3, 1);\n            pb_range(&mut occ, 7, d.line, 0, d.end, d.endcol);',
     '            pb_range(&mut occ, 7, d.line, 0, d.end, d.endcol);'),
    ('syntax.rs', "a definition's body starts at its name",
     '            pb_range(&mut occ, 7, d.line, 0, d.end, d.endcol);',
     '            pb_range(&mut occ, 7, d.line, d.col, d.end, d.endcol);'),
    ('syntax.rs', "the tool's version is 2",
     '    pb_bytes(&mut tool, 2, b"1");',
     '    pb_bytes(&mut tool, 2, b"2");'),
    ('syntax.rs', 'columns are declared UTF-16',
     '    pb_int(&mut meta, 4, 1);',
     '    pb_int(&mut meta, 4, 2);'),
    ('syntax.rs', "the repo's address has one slash",
     '&[b"file://", repo].concat()',
     '&[b"file:/", repo].concat()'),
    ('syntax.rs', 'a file is a class',
     '        pb_int(&mut info, 5, SX_MODULE);',
     '        pb_int(&mut info, 5, SX_CLASS);'),
    ('syntax.rs', "a file's own occurrence is not counted",
     '        pb_bytes(&mut doc, 2, &occ);\n        n_occ += 1;\n        let mut def_at',
     '        pb_bytes(&mut doc, 2, &occ);\n        let mut def_at'),
    ('syntax.rs', 'other words when the index cannot be written',
     'b"syntax-index: cannot write "',
     'b"syntax-index: could not write "'),
    ('main.rs', 'another exit code when the index cannot be written',
     '        if !syntax::syntax_index_main(&a[2], &a[3], skip_go) {\n            exit(1);',
     '        if !syntax::syntax_index_main(&a[2], &a[3], skip_go) {\n            exit(3);'),
]

JUDGE = "port-syntax.sh"


def main():
    if sys.argv[1:] != ["--fit"] and not all(a.isdigit() and 1 <= int(a) <= len(BREAKS) for a in sys.argv[1:]):
        sys.exit(__doc__)
    only = {int(a) for a in sys.argv[1:] if a.isdigit()}
    here = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    if sys.argv[1:] == ["--fit"]:
        # Only whether each break still fits the source: nothing is built.
        unfit = 0
        for n, (name, what, good, _) in enumerate(BREAKS, 1):
            count = open(os.path.join(here, "rust", "src", name), encoding="utf-8").read().count(good)
            if count != 1:
                unfit += 1
                print(f"break {n} does not fit rust/src/{name} ({what}): its text is there {count} times")
        print(f"{len(BREAKS) - unfit} of {len(BREAKS)} breaks fit")
        sys.exit(1 if unfit else 0)
    cargo = shutil.which("cargo") or os.path.expanduser("~/.cargo/bin/cargo")
    work = tempfile.mkdtemp(prefix="port-prove-")
    try:
        sys.exit(prove(here, cargo, work, only))
    finally:
        shutil.rmtree(work, ignore_errors=True)


def prove(here, cargo, work, only):
    # One copy of rust/ is edited, built and put back as it was for each
    # break, so only the one crate is compiled each time.
    copy = os.path.join(work, "rust")
    shutil.copytree(os.path.join(here, "rust"), copy, ignore=shutil.ignore_patterns("target"))
    # rust/build.rs finds goose-treesitter's C through the import line of
    # src/swan.goose beside rust/, in the Goose build's cache.
    os.makedirs(os.path.join(work, "src"), exist_ok=True)
    shutil.copy(os.path.join(here, "src", "swan.goose"), os.path.join(work, "src", "swan.goose"))
    os.environ.setdefault("GOOSE_HOME", os.path.join(here, ".tools", "goose-home"))
    judge_script = os.path.join(here, "scripts", JUDGE)

    def build():
        return subprocess.run([cargo, "build", "--release", "--manifest-path", os.path.join(copy, "Cargo.toml")],
                              env=dict(os.environ, CARGO_TARGET_DIR=os.path.join(work, "target")),
                              capture_output=True, text=True)

    # The unbroken program first: a judge that does not pass it would "catch"
    # every break by failing for some other reason (review on #75).
    made = build()
    if made.returncode != 0:
        print(f"the unbroken program does not build:\n{made.stderr[-600:]}")
        return 2
    base = os.path.join(work, "swan-0")
    shutil.copy(os.path.join(work, "target", "release", "swan"), base)
    ran = subprocess.run([judge_script], env=dict(os.environ, SWAN_NEW=base),
                         capture_output=True, encoding="utf-8", errors="replace")
    last = (ran.stdout.strip().splitlines() or [""])[-1]
    if ran.returncode != 0 or not last.startswith("the same:"):
        print(f"the judge does not pass the unbroken program ({JUDGE} exit {ran.returncode}), so it proves nothing:")
        print("    " + "\n    ".join((ran.stdout + ran.stderr).strip().splitlines()[-8:]))
        return 2
    print(f"the unbroken program: {last}", flush=True)
    built = []
    unfit = 0
    for n, (name, what, good, broken) in enumerate(BREAKS, 1):
        if only and n not in only:
            continue
        path = os.path.join(copy, "src", name)
        text = open(path, encoding="utf-8").read()
        if text.count(good) != 1:
            print(f"break {n} no longer fits rust/src/{name} ({what}): its text is there {text.count(good)} times")
            unfit += 1
            continue
        open(path, "w", encoding="utf-8").write(text.replace(good, broken))
        made = build()
        open(path, "w", encoding="utf-8").write(text)
        if made.returncode != 0:
            print(f"break {n} does not build ({what}):\n{made.stderr[-600:]}")
            unfit += 1
            continue
        program = os.path.join(work, f"swan-{n}")
        shutil.copy(os.path.join(work, "target", "release", "swan"), program)
        built.append((n, what, program))

    def judge(item):
        n, what, program = item
        ran = subprocess.run([judge_script], env=dict(os.environ, SWAN_NEW=program),
                             capture_output=True, encoding="utf-8", errors="replace")
        return n, what, ran.returncode, ran.stdout

    missed = 0
    # One judge a core: each runs dozens of comparisons.
    with ThreadPoolExecutor(max(1, min(len(built), os.cpu_count() or 4))) as pool:
        for n, what, code, said in pool.map(judge, built):
            caught = [line for line in said.splitlines() if line.startswith("DIFFERENT (")]
            steps = list(dict.fromkeys(line[len("DIFFERENT ("):].rstrip(")") for line in caught))
            if code == 2:
                missed += 1
                print(f"break {n} NOT JUDGED ({what}): the judge could not compare ({JUDGE} exit 2)")
                print("    " + "\n    ".join(said.splitlines()[-4:]))
            elif code == 1 and caught:
                print(f"break {n} caught ({what}) by {len(steps)} of the cases: {'; '.join(steps)[:120]}")
            else:
                missed += 1
                print(f"break {n} NOT CAUGHT ({what}): {JUDGE} exit {code}")
                print("    " + "\n    ".join(said.splitlines()[-6:]))
    print(f"{len(built) - missed} of {len(only) or len(BREAKS)} breaks caught" + (f", {unfit} did not fit or build" if unfit else ""))
    return 0 if missed == 0 and unfit == 0 else 1


if __name__ == "__main__":
    main()
