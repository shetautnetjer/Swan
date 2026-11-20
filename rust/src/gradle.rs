// Reading a Gradle build without running it: which modules there are, which
// are Android ones, and so which tasks scip-java should be given. Text only:
// comments, strings and reactions (withId, hasPlugin) are taken out first.
// Carried over from src/gradle.goose.

use crate::scip::is_ident;
use crate::sys;
use crate::util::{contains_line, ends_with, find, parse_int, push_int, split, starts_with, trim};

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
// plugin:`, or by `alias(libs.plugins....)` from the version catalog.
// Comments are skipped. An entry with `apply false`, on its line or the
// chained lines after it, only declares the plugin (a root build file does
// that for its modules), and `plugins.withId(...)`, `hasPlugin(...)` and
// `withPlugin(...)` only react to it.
fn android_plugin_of(build: &[u8], aliases: &[u8], kotlin: bool) -> i64 {
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
pub fn gradle_scip_tasks(repo: &[u8]) -> Vec<u8> {
    let aliases = android_catalog_aliases(repo);
    let mut android = false;
    let mut unit = false;
    let mut module = |dir: &[u8]| {
        let mut b: Vec<u8> = Vec::new();
        let kotlin = sys::read_file(&[dir, b"/build.gradle.kts"].concat(), &mut b);
        if !(kotlin || sys::read_file(&[dir, b"/build.gradle"].concat(), &mut b)) {
            return;
        }
        let k = android_plugin_of(&b, &aliases, kotlin);
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
