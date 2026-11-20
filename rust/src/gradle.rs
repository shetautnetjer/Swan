// Reading a Gradle build without running it: which modules there are, which
// are Android ones, and so which tasks scip-java should be given. Text only:
// comments, strings and reactions (withId, hasPlugin) are taken out first.
// Carried over from src/gradle.goose.

use crate::scip::is_ident;
use crate::sys;
use crate::util::{contains_line, ends_with, find, parse_int, push_int, rfind, split, starts_with, trim};
use crate::walk::Walk;

// Gradle plugins that make a module an Android one.
const ANDROID_PLUGINS: [&[u8]; 4] =
    [b"com.android.application", b"com.android.library", b"com.android.test", b"com.android.dynamic-feature"];

fn is_blank(c: u8) -> bool {
    c == b' ' || c == b'\t' || c == b'\n' || c == b'\r'
}

// Which Android plugin id s names in quotes ("id" or 'id', or "id:version"
// in a version catalog): its index in ANDROID_PLUGINS, or -1.
fn android_plugin_in(s: &[u8]) -> i64 {
    for (k, p) in ANDROID_PLUGINS.iter().enumerate() {
        for q in [&b"\""[..], b"'"] {
            if find(s, &[q, p, q].concat()) >= 0 || find(s, &[q, p, b":"].concat()) >= 0 {
                return k as i64;
            }
        }
    }
    -1
}

// The plugin aliases in gradle/libs.versions.toml that name an Android
// plugin, as build files write them ("libs.plugins.android.application"),
// each with its ANDROID_PLUGINS index: "alias\tindex" lines. Gradle's
// accessors turn '-' and '_' in a key into '.'. Other catalogs are not read.
fn android_catalog_aliases(repo: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    let mut toml: Vec<u8> = Vec::new();
    if !sys::read_file(&[repo, b"/gradle/libs.versions.toml"].concat(), &mut toml) {
        return out;
    }
    let mut plugins = false;
    for raw in toml.split(|&c| c == b'\n') {
        let line = trim(raw);
        if starts_with(line, b"[") {
            plugins = starts_with(line, b"[plugins]");
        } else if plugins && !starts_with(line, b"#") {
            let eq = find(line, b"=");
            let k = if eq > 0 { android_plugin_in(&line[eq as usize + 1..]) } else { -1 };
            if k >= 0 {
                let mut name: Vec<u8> = [&b"libs.plugins."[..], trim(&line[..eq as usize])].concat();
                for c in name.iter_mut() {
                    if *c == b'-' || *c == b'_' {
                        *c = b'.';
                    }
                }
                out.extend_from_slice(&name);
                out.push(b'\t');
                push_int(&mut out, k);
                out.push(b'\n');
            }
        }
    }
    out
}

// Every plugin in gradle/libs.versions.toml, as build files write its alias
// ("libs.plugins.demo.android.library"), with its id: "alias\tid" lines. The
// id is the quoted text after `id =` in a table, or a plain entry's string
// up to its ':' ("id:version"). Read for the repo's own convention plugins,
// whose ids name no Android plugin.
fn catalog_plugin_ids(repo: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    let mut toml: Vec<u8> = Vec::new();
    if !sys::read_file(&[repo, b"/gradle/libs.versions.toml"].concat(), &mut toml) {
        return out;
    }
    let mut plugins = false;
    for raw in toml.split(|&c| c == b'\n') {
        let line = trim(raw);
        if starts_with(line, b"[") {
            plugins = starts_with(line, b"[plugins]");
        } else if plugins && !starts_with(line, b"#") {
            let eq = find(line, b"=");
            if eq <= 0 {
                continue;
            }
            let eq = eq as usize;
            let value = trim(&line[eq + 1..]);
            let mut id: Vec<u8> = Vec::new();
            if !value.is_empty() && (value[0] == b'"' || value[0] == b'\'') {
                let end = gradle_quote_end(value, 0);
                if end > 0 {
                    let end = end as usize;
                    let colon = find(&value[1..end], b":");
                    id.extend_from_slice(if colon >= 0 { &value[1..1 + colon as usize] } else { &value[1..end] });
                }
            } else {
                let mut p = 0;
                while id.is_empty() && p < value.len() {
                    let a = find(&value[p..], b"id");
                    if a < 0 {
                        break;
                    }
                    let mut i = p + a as usize + 2;
                    p = i;
                    if !(p - 2 == 0 || !is_ident(value[p - 3])) {
                        continue;
                    }
                    while i < value.len() && value[i] == b' ' {
                        i += 1;
                    }
                    if !(i < value.len() && value[i] == b'=') {
                        continue;
                    }
                    i += 1;
                    while i < value.len() && value[i] == b' ' {
                        i += 1;
                    }
                    if !(i < value.len() && (value[i] == b'"' || value[i] == b'\'')) {
                        continue;
                    }
                    let end = gradle_quote_end(value, i);
                    if end > i as i64 {
                        id.extend_from_slice(&value[i + 1..end as usize]);
                    }
                }
            }
            if !id.is_empty() {
                let mut name: Vec<u8> = [&b"libs.plugins."[..], trim(&line[..eq])].concat();
                for c in name.iter_mut() {
                    if *c == b'-' || *c == b'_' {
                        *c = b'.';
                    }
                }
                out.extend_from_slice(&name);
                out.push(b'\t');
                out.extend_from_slice(&id);
                out.push(b'\n');
            }
        }
    }
    out
}

// The end of the quoted string that starts at s[i] (a " or '), on the same
// line, or -1.
fn gradle_quote_end(s: &[u8], i: usize) -> i64 {
    let mut j = i + 1;
    while j < s.len() && s[j] != s[i] && s[j] != b'\n' {
        j += 1;
    }
    if j < s.len() && s[j] == s[i] {
        j as i64
    } else {
        -1
    }
}

// The second field of the "key\tvalue" line whose key is `key`, else "".
fn gradle_field(lines: &[u8], key: &[u8]) -> Vec<u8> {
    for l in lines.split(|&c| c == b'\n') {
        let tab = find(l, b"\t");
        if tab > 0 && &l[..tab as usize] == key {
            return l[tab as usize + 1..].to_vec();
        }
    }
    Vec::new()
}

// The folders of the repo's own build logic, as paths from the repo, one
// per line: buildSrc, and each build settings.gradle(.kts) includes with
// includeBuild("..."), in pluginManagement or not. A path with ".." or a
// leading "/" is skipped, as include names are.
fn gradle_logic_dirs(repo: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    if sys::is_dir(&[repo, b"/buildSrc"].concat()) {
        out.extend_from_slice(b"buildSrc\n");
    }
    let mut s: Vec<u8> = Vec::new();
    let kotlin = sys::read_file(&[repo, b"/settings.gradle.kts"].concat(), &mut s);
    if !(kotlin || sys::read_file(&[repo, b"/settings.gradle"].concat(), &mut s)) {
        return out;
    }
    let text = strip_gradle_comments(&s, kotlin);
    let mut p = 0;
    while p < text.len() {
        let a = find(&text[p..], b"includeBuild");
        if a < 0 {
            break;
        }
        let a = a as usize;
        let mut i = p + a + 12;
        let word = p + a == 0 || !is_ident(text[p + a - 1]);
        p = i;
        while i < text.len() && (text[i] == b' ' || text[i] == b'\t' || text[i] == b'(') {
            i += 1;
        }
        if !(word && i < text.len() && (text[i] == b'"' || text[i] == b'\'')) {
            continue;
        }
        let end = gradle_quote_end(&text, i);
        if end <= i as i64 {
            continue;
        }
        let end = end as usize;
        let mut name = &text[i + 1..end];
        if starts_with(name, b"./") {
            name = &name[2..];
        }
        while !name.is_empty() && name[name.len() - 1] == b'/' {
            name = &name[..name.len() - 1];
        }
        let bad = name.is_empty() || name == b"." || find(name, b"..") >= 0 || name[0] == b'/';
        if !bad && !contains_line(&out, name) {
            out.extend_from_slice(name);
            out.push(b'\n');
        }
        p = end + 1;
    }
    out
}

fn push_pair(out: &mut Vec<u8>, a: &[u8], b: &[u8]) {
    out.extend_from_slice(a);
    out.push(b'\t');
    out.extend_from_slice(b);
    out.push(b'\n');
}

// The convention plugins one folder of build logic defines: "id\tfile"
// lines, the file being the source that says what the plugin does.
//   - A precompiled script plugin, a .gradle.kts or .gradle file under
//     src/main/kotlin or src/main/groovy: its id is its file name without
//     the extension, after the package a Kotlin one declares.
//   - A plugin a build file registers in its gradlePlugin block
//     (`register("x") { id = ...; implementationClass = "..." }`): its id
//     written out, or taken from the catalog (`id = libs.plugins.x.get()
//     .pluginId`); its file the .kt, .groovy or .java one named for the
//     class.
fn gradle_logic_plugins(walk: &Walk, dir: &[u8], catalog: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    let mut sources: Vec<u8> = Vec::new(); // "file name\tpath" of each .kt, .groovy and .java
    let mut builds: Vec<u8> = Vec::new(); // build files, one path per line
    walk.each_file(dir, |full, name| {
        let script = ends_with(name, b".gradle.kts") || ends_with(name, b".gradle");
        if name == b"build.gradle.kts" || name == b"build.gradle" {
            builds.extend_from_slice(full);
            builds.push(b'\n');
        } else if script
            && name != b"settings.gradle.kts"
            && name != b"settings.gradle"
            && (find(full, b"/src/main/kotlin/") >= 0 || find(full, b"/src/main/groovy/") >= 0)
        {
            let mut id: Vec<u8> = Vec::new();
            if ends_with(name, b".gradle.kts") {
                let mut text: Vec<u8> = Vec::new();
                sys::read_file(full, &mut text);
                for l in strip_gradle_comments(&text, true).split(|&c| c == b'\n') {
                    let t = trim(l);
                    if id.is_empty() && starts_with(t, b"package ") {
                        id.extend_from_slice(trim(&t[8..]));
                        id.push(b'.');
                    }
                }
                id.extend_from_slice(&name[..name.len() - 11]);
            } else {
                id.extend_from_slice(&name[..name.len() - 7]);
            }
            push_pair(&mut out, &id, full);
        } else if ends_with(name, b".kt") || ends_with(name, b".groovy") || ends_with(name, b".java") {
            push_pair(&mut sources, name, full);
        }
    });
    for b in builds.split(|&c| c == b'\n') {
        if b.is_empty() {
            continue;
        }
        let mut raw: Vec<u8> = Vec::new();
        if !sys::read_file(b, &mut raw) {
            continue;
        }
        let text = strip_gradle_comments(&raw, ends_with(b, b".kts"));
        let mut p = 0;
        while p < text.len() {
            let a = find(&text[p..], b"implementationClass");
            if a < 0 {
                break;
            }
            let at = p + a as usize;
            p = at + 19;
            // The class: the quoted text after it, without its package.
            let mut i = p;
            while i < text.len() && (text[i] == b' ' || text[i] == b'\t' || text[i] == b'=') {
                i += 1;
            }
            if !(i < text.len() && (text[i] == b'"' || text[i] == b'\'')) {
                continue;
            }
            let end = gradle_quote_end(&text, i);
            if end <= i as i64 {
                continue;
            }
            let qualified = &text[i + 1..end as usize];
            let dot = rfind(qualified, b".");
            let cls = if dot >= 0 { &qualified[dot as usize + 1..] } else { qualified };
            // The block it is in: from the unmatched { before it to the
            // unmatched } after it.
            let mut from = at;
            let mut depth = 0;
            while from > 0 {
                from -= 1;
                if text[from] == b'}' {
                    depth += 1;
                } else if text[from] == b'{' {
                    if depth == 0 {
                        break;
                    }
                    depth -= 1;
                }
            }
            let mut to = at;
            depth = 0;
            while to < text.len() {
                if text[to] == b'{' {
                    depth += 1;
                } else if text[to] == b'}' {
                    if depth == 0 {
                        break;
                    }
                    depth -= 1;
                }
                to += 1;
            }
            // Its id: `id = "..."`, `id '...'`, or `id = libs.plugins....`.
            let mut id: Vec<u8> = Vec::new();
            let mut j = from;
            while id.is_empty() && j < to {
                let c = find(&text[j..to], b"id");
                if c < 0 {
                    break;
                }
                let c = c as usize;
                let mut k = j + c + 2;
                let word = (j + c == 0 || !(is_ident(text[j + c - 1]) || text[j + c - 1] == b'.'))
                    && (k >= text.len() || !is_ident(text[k]));
                j = k;
                if !word {
                    continue;
                }
                while k < to && (text[k] == b' ' || text[k] == b'\t') {
                    k += 1;
                }
                if k < to && text[k] == b'=' {
                    k += 1;
                }
                while k < to && (text[k] == b' ' || text[k] == b'\t') {
                    k += 1;
                }
                if k < to && (text[k] == b'"' || text[k] == b'\'') {
                    let e = gradle_quote_end(&text, k);
                    if e > k as i64 {
                        id.extend_from_slice(&text[k + 1..e as usize]);
                    }
                } else if starts_with(&text[k..to], b"libs.plugins.") {
                    let mut e = k;
                    while e < to && (is_ident(text[e]) || text[e] == b'.') {
                        e += 1;
                    }
                    let mut alias = &text[k..e];
                    // libs.plugins.x.get().pluginId, or .asProvider().get() when
                    // x is also the start of a longer alias.
                    let mut cut = true;
                    while cut {
                        cut = false;
                        for tail in [&b".get"[..], b".asProvider"] {
                            if ends_with(alias, tail) {
                                alias = &alias[..alias.len() - tail.len()];
                                cut = true;
                            }
                        }
                    }
                    id.extend_from_slice(&gradle_field(catalog, alias));
                }
            }
            if id.is_empty() {
                continue;
            }
            let mut file: Vec<u8> = Vec::new();
            for ext in [&b".kt"[..], b".groovy", b".java"] {
                if file.is_empty() {
                    file.extend_from_slice(&gradle_field(&sources, &[cls, ext].concat()));
                }
            }
            if !file.is_empty() {
                push_pair(&mut out, &id, &file);
            }
        }
    }
    out
}

// The repo's own plugins that apply an Android plugin, each with that
// plugin's ANDROID_PLUGINS index: "id\tindex" lines. Convention plugins
// hide Android from the build files that use them: Now in Android's
// modules apply `alias(libs.plugins.nowinandroid.android.application)`,
// and only the Kotlin of its build-logic applies com.android.application;
// read without them it was taken for a JVM build (found 2026-11-20). A
// plugin counts when its file applies an Android plugin, or one of the
// repo's own plugins that does, read as a build file is (android_plugin_of:
// a comment or a reaction such as hasPlugin does not count). Nothing runs.
fn android_conventions(walk: &Walk, repo: &[u8], catalog: &[u8], aliases: &[u8]) -> Vec<u8> {
    let mut plugins: Vec<u8> = Vec::new();
    for d in gradle_logic_dirs(repo).split(|&c| c == b'\n') {
        if !d.is_empty() {
            plugins.extend_from_slice(&gradle_logic_plugins(walk, &[repo, b"/", d].concat(), catalog));
        }
    }
    let mut known: Vec<u8> = Vec::new();
    // Each pass adds the plugins that apply one found before: a chain of n
    // takes n passes.
    let mut more = !plugins.is_empty();
    while more {
        more = false;
        for entry in plugins.split(|&c| c == b'\n') {
            let tab = find(entry, b"\t");
            if !(tab > 0 && gradle_field(&known, &entry[..tab as usize]).is_empty()) {
                continue;
            }
            let tab = tab as usize;
            let mut text: Vec<u8> = Vec::new();
            if !sys::read_file(&entry[tab + 1..], &mut text) {
                continue;
            }
            let k = android_plugin_of(&text, aliases, &known, ends_with(entry, b".kt") || ends_with(entry, b".kts"));
            if k >= 0 {
                known.extend_from_slice(&entry[..tab]);
                known.push(b'\t');
                push_int(&mut known, k);
                known.push(b'\n');
                more = true;
            }
        }
    }
    known
}

// Whether the quoted string at s[q] is a plugin being applied: `id("x")`,
// `id 'x'`, `apply(plugin = "x")`, `apply plugin: 'x'` or
// `pluginManager.apply("x")`. A convention plugin's id anywhere else (a
// string a build file keeps) applies nothing; an Android plugin's own id is
// read wherever it is in quotes (android_plugin_in), as before.
fn gradle_applies_at(s: &[u8], q: usize) -> bool {
    let blank = |c: u8| c == b' ' || c == b'\t';
    let mut i = q;
    while i > 0 && blank(s[i - 1]) {
        i -= 1;
    }
    if i > 0 && (s[i - 1] == b'=' || s[i - 1] == b':') {
        i -= 1;
        while i > 0 && blank(s[i - 1]) {
            i -= 1;
        }
        return gradle_word_before(s, i) == b"plugin";
    }
    let paren = i > 0 && s[i - 1] == b'(';
    if paren {
        i -= 1;
        while i > 0 && blank(s[i - 1]) {
            i -= 1;
        }
    }
    let w = gradle_word_before(s, i);
    w == b"id" || (paren && w == b"apply")
}

// The word that ends at s[end].
fn gradle_word_before(s: &[u8], end: usize) -> &[u8] {
    let mut i = end;
    while i > 0 && is_ident(s[i - 1]) {
        i -= 1;
    }
    &s[i..end]
}

// Which of the repo's own Android plugins (android_conventions) s applies
// by id (gradle_applies_at): its ANDROID_PLUGINS index, or -1.
fn convention_plugin_in(s: &[u8], conventions: &[u8]) -> i64 {
    let mut k = -1;
    for c in conventions.split(|&c| c == b'\n') {
        let tab = find(c, b"\t");
        if !(k < 0 && tab > 0) {
            continue;
        }
        let id = &c[..tab as usize];
        for q in [&b"\""[..], b"'"] {
            let quoted = [q, id, q].concat();
            let mut p = 0;
            while k < 0 && p < s.len() {
                let a = find(&s[p..], &quoted);
                if a < 0 {
                    break;
                }
                let at = p + a as usize;
                if gradle_applies_at(s, at) {
                    if let Some(n) = parse_int(&c[tab as usize + 1..]) {
                        k = n;
                    }
                }
                p = at + 1;
            }
        }
    }
    k
}

// Slashy strings occur where an expression may start; a slash after a value
// is division instead. The detector does not evaluate arbitrary Groovy code.
fn groovy_slashy_start(s: &[u8], at: usize) -> bool {
    let mut i = at;
    while i > 0 && is_blank(s[i - 1]) {
        i -= 1;
    }
    if i == 0 {
        return true;
    }
    let c = s[i - 1];
    if matches!(c, b'=' | b'(' | b'[' | b'{' | b',' | b':' | b'~' | b'?') {
        return true;
    }
    if c == b'+' || c == b'-' {
        // After postfix ++ or -- the slash is division, not a new string.
        return i < 2 || s[i - 2] != c;
    }
    if matches!(c, b'*' | b'%' | b'&' | b'|' | b'^' | b'!' | b'<' | b'>') {
        return true;
    }
    let end = i;
    while i > 0 && is_ident(s[i - 1]) {
        i -= 1;
    }
    let word = &s[i..end];
    word == b"return" || word == b"case" || word == b"throw" || word == b"assert"
}

// A build file without its comments: /* ... */ (its newlines kept, so lines
// stay lines) and // to the end of the line, neither inside a quoted string.
// Kotlin and Groovy triple-quoted strings can contain newlines and comments.
fn strip_gradle_comments(s: &[u8], kotlin: bool) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    let mut q: u8 = 0;
    let mut triple = false;
    let mut slashy = false;
    let mut dollar_slashy = false;
    let n = s.len();
    let mut i = 0;
    while i < n {
        let c = s[i];
        if dollar_slashy {
            out.push(c);
            if c == b'$' && i + 1 < n && (s[i + 1] == b'$' || s[i + 1] == b'/') {
                out.push(s[i + 1]);
                i += 1;
            } else if c == b'/' && i + 1 < n && s[i + 1] == b'$' {
                out.push(b'$');
                i += 1;
                dollar_slashy = false;
            }
        } else if slashy {
            out.push(c);
            if c == b'\\' && i + 1 < n && s[i + 1] == b'/' {
                out.push(b'/');
                i += 1;
            } else if c == b'/' {
                slashy = false;
            }
        } else if q != 0 {
            out.push(c);
            if c == b'\\' && (!triple || !kotlin) && i + 1 < n {
                out.push(s[i + 1]);
                i += 1;
            } else if triple && c == q && i + 2 < n && s[i + 1] == q && s[i + 2] == q {
                out.push(q);
                out.push(q);
                i += 2;
                q = 0;
                triple = false;
            } else if !triple && (c == q || c == b'\n') {
                q = 0;
            }
        } else if c == b'/' && i + 1 < n && s[i + 1] == b'*' {
            i += 2;
            let mut depth = 1;
            while i < n && depth > 0 {
                if s[i] == b'/' && i + 1 < n && s[i + 1] == b'*' && kotlin {
                    depth += 1;
                    i += 2;
                    continue;
                }
                if s[i] == b'*' && i + 1 < n && s[i + 1] == b'/' {
                    depth -= 1;
                    i += 2;
                    continue;
                }
                if s[i] == b'\n' {
                    out.push(b'\n');
                }
                i += 1;
            }
            continue;
        } else if c == b'/' && i + 1 < n && s[i + 1] == b'/' {
            while i < n && s[i] != b'\n' {
                i += 1;
            }
            continue;
        } else if !kotlin && c == b'$' && i + 1 < n && s[i + 1] == b'/' {
            out.push(c);
            out.push(b'/');
            i += 1;
            dollar_slashy = true;
        } else if !kotlin && c == b'/' && groovy_slashy_start(&out, out.len()) {
            out.push(c);
            slashy = true;
        } else {
            out.push(c);
            if c == b'"' || c == b'\'' {
                q = c;
                if i + 2 < n && s[i + 1] == c && s[i + 2] == c {
                    triple = true;
                    out.push(c);
                    out.push(c);
                    i += 2;
                }
            }
        }
        i += 1;
    }
    out
}

// Mask reaction calls, including multiline argument lists, but keep the
// surrounding code and newlines. A plugin applied in a callback still counts.
fn strip_gradle_reactions(s: &[u8], kotlin: bool) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    let mut q: u8 = 0;
    let mut triple = false;
    let mut depth: i64 = 0;
    let n = s.len();
    let mut i = 0;
    // Masked inside a reaction: a space, but a newline stays a newline.
    let mask = |depth: i64, c: u8| if depth > 0 && c != b'\n' { b' ' } else { c };
    while i < n {
        let c = s[i];
        if depth == 0 && q == 0 && (i == 0 || !is_ident(s[i - 1])) {
            let mut len = 0;
            for name in [&b"withId"[..], b"hasPlugin", b"withPlugin"] {
                if starts_with(&s[i..], name) {
                    len = name.len();
                }
            }
            if len > 0 {
                let mut j = i + len;
                while j < n && is_blank(s[j]) {
                    j += 1;
                }
                if j < n && s[j] == b'(' {
                    while i <= j {
                        out.push(if s[i] == b'\n' { b'\n' } else { b' ' });
                        i += 1;
                    }
                    depth = 1;
                    continue;
                }
            }
        }
        if q != 0 {
            out.push(mask(depth, c));
            if c == b'\\' && (!triple || !kotlin) && i + 1 < n {
                i += 1;
                out.push(mask(depth, s[i]));
            } else if triple && c == q && i + 2 < n && s[i + 1] == q && s[i + 2] == q {
                let k = if depth > 0 { b' ' } else { q };
                out.push(k);
                out.push(k);
                i += 2;
                q = 0;
                triple = false;
            } else if !triple && (c == q || c == b'\n') {
                q = 0;
            }
        } else {
            if c == b'"' || c == b'\'' {
                q = c;
                if i + 2 < n && s[i + 1] == c && s[i + 2] == c {
                    triple = true;
                }
            } else if depth > 0 && c == b'(' {
                depth += 1;
            } else if depth > 0 && c == b')' {
                depth -= 1;
                out.push(b' ');
                i += 1;
                continue;
            }
            out.push(mask(depth, c));
            if triple && q == c && i + 2 < n && s[i + 1] == c && s[i + 2] == c {
                let k = if depth > 0 { b' ' } else { c };
                out.push(k);
                out.push(k);
                i += 2;
            }
        }
        i += 1;
    }
    out
}

// Whether a plugin entry is only declared, with `apply false` / `.apply(false)`
// on its own line or on the chained lines after it (`.version(...)`).
fn gradle_apply_false(lines: &[&[u8]], at: usize) -> bool {
    let mut j = at;
    while j < lines.len() {
        let line = trim(lines[j]);
        if !(j == at || starts_with(line, b".") || starts_with(line, b"apply ") || starts_with(line, b"version ")) {
            return false;
        }
        if find(line, b"apply false") >= 0 || find(line, b"apply(false)") >= 0 {
            return true;
        }
        j += 1;
    }
    false
}

// The Android plugin a build file applies (its ANDROID_PLUGINS index), or
// -1: by id in a plugins {} block, `id("...")`, `id '...'` or `apply
// plugin:`, by one of the repo's own plugins that applies one
// (`conventions`, from android_conventions), or by `alias(libs.plugins....)`
// from the version catalog.
// Comments are skipped. An entry with `apply false`, on its line or the
// chained lines after it, only declares the plugin (a root build file does
// that for its modules), and `plugins.withId(...)`, `hasPlugin(...)` and
// `withPlugin(...)` only react to it.
fn android_plugin_of(build: &[u8], aliases: &[u8], conventions: &[u8], kotlin: bool) -> i64 {
    let mut k = -1;
    let text = strip_gradle_reactions(&strip_gradle_comments(build, kotlin), kotlin);
    let lines = split(&text, b'\n');
    for (at, raw) in lines.iter().enumerate() {
        let line = trim(raw);
        if k >= 0 {
            continue;
        }
        if gradle_apply_false(&lines, at) {
            continue;
        }
        k = android_plugin_in(line);
        if k < 0 {
            k = convention_plugin_in(line, conventions);
        }
        let al = find(line, b"alias");
        if k < 0 && al >= 0 {
            let mut i = al as usize + 5;
            while i < line.len() && (line[i] == b'(' || line[i] == b' ') {
                i += 1;
            }
            let start = i;
            while i < line.len() && (is_ident(line[i]) || line[i] == b'.') {
                i += 1;
            }
            let name = &line[start..i];
            for a in aliases.split(|&c| c == b'\n') {
                let tab = find(a, b"\t");
                if tab > 0 && &a[..tab as usize] == name {
                    if let Some(n) = parse_int(&a[tab as usize + 1..]) {
                        k = n;
                    }
                }
            }
        }
    }
    k
}

// The modules settings.gradle(.kts) includes, as Gradle paths (":app",
// ":core:data"), one per line: every quoted name in an `include(...)` or
// Groovy `include '...', '...'`, which may run over several lines; names
// with ".." or "/" are skipped. Modules moved elsewhere with projectDir are
// looked for at their default place.
fn gradle_includes(repo: &[u8]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    let mut s: Vec<u8> = Vec::new();
    let kotlin = sys::read_file(&[repo, b"/settings.gradle.kts"].concat(), &mut s);
    if !(kotlin || sys::read_file(&[repo, b"/settings.gradle"].concat(), &mut s)) {
        return out;
    }
    let text = strip_gradle_comments(&s, kotlin);
    let mut open = false;
    let mut depth: i64 = 0;
    let mut triple: u8 = 0;
    let mut slashy = false;
    let mut dollar_slashy = false;
    let mut offset = 0;
    for raw in text.split(|&c| c == b'\n') {
        let line = trim(raw);
        let line_start = offset;
        offset += raw.len() + 1;
        let in_string = triple != 0 || slashy || dollar_slashy;
        let mut q: u8 = 0;
        let n = raw.len();
        let mut i = 0;
        while i < n {
            let c = raw[i];
            if dollar_slashy {
                if c == b'$' && i + 1 < n && (raw[i + 1] == b'$' || raw[i + 1] == b'/') {
                    i += 2;
                    continue;
                }
                if c == b'/' && i + 1 < n && raw[i + 1] == b'$' {
                    dollar_slashy = false;
                    i += 2;
                    continue;
                }
                i += 1;
                continue;
            }
            if slashy {
                if c == b'\\' && i + 1 < n && raw[i + 1] == b'/' {
                    i += 2;
                    continue;
                }
                if c == b'/' {
                    slashy = false;
                }
                i += 1;
                continue;
            }
            if c == b'\\' && (q != 0 || (triple != 0 && !kotlin)) && i + 1 < n {
                i += 2;
                continue;
            }
            if triple != 0 {
                if c == triple && i + 2 < n && raw[i + 1] == c && raw[i + 2] == c {
                    triple = 0;
                    i += 3;
                    continue;
                }
            } else if q != 0 {
                if c == q {
                    q = 0;
                }
            } else if !kotlin && c == b'$' && i + 1 < n && raw[i + 1] == b'/' {
                dollar_slashy = true;
                i += 2;
                continue;
            } else if !kotlin && c == b'/' && groovy_slashy_start(&text, line_start + i) {
                slashy = true;
            } else if c == b'"' || c == b'\'' {
                if i + 2 < n && raw[i + 1] == c && raw[i + 2] == c {
                    triple = c;
                    i += 3;
                    continue;
                }
                q = c;
            }
            i += 1;
        }
        if in_string {
            continue;
        }
        let starts = starts_with(line, b"include")
            && line.len() > 7
            && (line[7] == b'(' || line[7] == b' ' || line[7] == b'\t');
        if !(open || starts) {
            continue;
        }
        let mut q: u8 = 0;
        let mut from = 0;
        for (i, &c) in line.iter().enumerate() {
            if q != 0 {
                if c == q {
                    let name = &line[from..i];
                    let path: Vec<u8> = if starts_with(name, b":") { name.to_vec() } else { [&b":"[..], name].concat() };
                    // A name with ".." or "/" is no Gradle path; it would
                    // send the build-file lookup outside the module tree.
                    let bad = find(name, b"..") >= 0 || find(name, b"/") >= 0;
                    if !name.is_empty() && !bad && !contains_line(&out, &path) {
                        out.extend_from_slice(&path);
                        out.push(b'\n');
                    }
                    q = 0;
                }
            } else if c == b'"' || c == b'\'' {
                q = c;
                from = i + 1;
            } else if c == b'(' {
                depth += 1;
            } else if c == b')' {
                depth -= 1;
            }
        }
        open = depth > 0 || ends_with(line, b",");
    }
    out
}

// The Gradle tasks scip-java runs, one per line. Its own scipPrintDependencies
// (the dependency versions behind callees in packages) and scipCompileAll
// (the compiles) do for a plain JVM build. On an Android build (AGP 9, with
// its built-in Kotlin) scipPrintDependencies dies of a
// ConcurrentModificationException (WriteDependencies walks the project's
// configurations while AGP adds some), and scipCompileAll alone has no
// actions there; so when any module looks Android, it goes, and the Kotlin
// compiles are named instead: compileDebugKotlin and compileDebugUnitTestKotlin,
// unqualified. Gradle runs an unqualified task in every project that has it
// and fails only if none does, so a wrong guess about which module is
// Android costs nothing, and a module without a debug variant or without
// Kotlin is just passed over. compileDebugUnitTestKotlin is left out when
// every Android module found is com.android.test (all instrumented tests,
// no unit tests). The variant is taken to be debug: nothing short of running
// Gradle says which variants a module has, and a repo where no module has
// compileDebugKotlin (only flavored variants) fails the run.
// `clean` first: the compiles must run for scip-java to see them.
pub fn gradle_scip_tasks(walk: &Walk, repo: &[u8]) -> Vec<u8> {
    let mut aliases = android_catalog_aliases(repo);
    let catalog = catalog_plugin_ids(repo);
    let conventions = android_conventions(walk, repo, &catalog, &aliases);
    // The catalog's aliases for them, beside the Android plugins' own.
    for e in catalog.split(|&c| c == b'\n') {
        let tab = find(e, b"\t");
        if tab <= 0 {
            continue;
        }
        let k = gradle_field(&conventions, &e[tab as usize + 1..]);
        if !k.is_empty() {
            push_pair(&mut aliases, &e[..tab as usize], &k);
        }
    }
    let mut android = false;
    let mut unit = false;
    let mut module = |dir: &[u8]| {
        let mut b: Vec<u8> = Vec::new();
        let kotlin = sys::read_file(&[dir, b"/build.gradle.kts"].concat(), &mut b);
        if !(kotlin || sys::read_file(&[dir, b"/build.gradle"].concat(), &mut b)) {
            return;
        }
        let k = android_plugin_of(&b, &aliases, &conventions, kotlin);
        if k < 0 {
            return;
        }
        android = true;
        if ANDROID_PLUGINS[k as usize] != b"com.android.test" {
            unit = true;
        }
    };
    module(repo);
    for path in gradle_includes(repo).split(|&c| c == b'\n') {
        if path.len() <= 1 {
            continue;
        }
        let mut dir: Vec<u8> = [repo, b"/", &path[1..]].concat();
        for c in dir[repo.len() + 1..].iter_mut() {
            if *c == b':' {
                *c = b'/';
            }
        }
        module(&dir);
    }
    let mut tasks: Vec<u8> = b"clean\n".to_vec();
    if android {
        tasks.extend_from_slice(b"compileDebugKotlin\n");
        if unit {
            tasks.extend_from_slice(b"compileDebugUnitTestKotlin\n");
        }
    } else {
        tasks.extend_from_slice(b"scipPrintDependencies\n");
    }
    tasks.extend_from_slice(b"scipCompileAll\n");
    tasks
}
