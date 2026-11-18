// Reading a Gradle build without running it: which modules there are, which
// are Android ones, and so which tasks scip-java should be given. Text only:
// comments, strings and reactions (withId, hasPlugin) are taken out first.

import std;
import os;
import json;
import dictionary;
import sqlite;

// Gradle plugins that make a module an Android one.
let ANDROID_PLUGINS = ["com.android.application", "com.android.library", "com.android.test",
                       "com.android.dynamic-feature"];

// Which Android plugin id s names in quotes ("id" or 'id', or "id:version"
// in a version catalog): its index in ANDROID_PLUGINS, or -1.
fn android_plugin_in(s: const u8[:]) -> i64 {
    for p, k in ANDROID_PLUGINS {
        for q in ["\"", "'"] {
            if find(s, str(q, p, q)) >= 0 || find(s, str(q, p, ":")) >= 0 { return k; }
        }
    }
    return -1;
}

// The plugin aliases in gradle/libs.versions.toml that name an Android
// plugin, as build files write them ("libs.plugins.android.application"),
// each with its ANDROID_PLUGINS index: "alias\tindex" lines. Gradle's
// accessors turn '-' and '_' in a key into '.'. Other catalogs are not read.
fn android_catalog_aliases(repo: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    var toml: u8[>..] = [];
    guard read_file(str(repo, "/gradle/libs.versions.toml"), toml) else { return out; }
    var plugins = false;
    each_split(toml, '\n') { raw =>
        let line = trim(raw);
        if starts_with(line, "[") {
            plugins = starts_with(line, "[plugins]");
        } else if plugins && !starts_with(line, "#") {
            let eq = find(line, "=");
            let k = if eq > 0 { android_plugin_in(line[eq + 1..]) } else { -1 };
            if k >= 0 {
                var name: u8[>..] = str("libs.plugins.", trim(line[..eq]));
                for i in 0..name.len { if name[i] == '-' || name[i] == '_' { name[i] = '.'; } }
                format(out, name, "\t", k, "\n");
            }
        }
    };
    return out;
}

// Slashy strings occur where an expression may start; a slash after a value
// is division instead. The detector does not evaluate arbitrary Groovy code.
fn groovy_slashy_start(s: const u8[:], at: i64) -> bool {
    var i = at;
    while i > 0 && (s[i - 1] == ' ' || s[i - 1] == '\t' || s[i - 1] == '\n' || s[i - 1] == '\r') { i--; }
    if i == 0 { return true; }
    let c = s[i - 1];
    if c == '=' || c == '(' || c == '[' || c == '{' || c == ',' || c == ':' || c == '~' || c == '?' { return true; }
    if c == '+' || c == '-' {
        // After postfix ++ or -- the slash is division, not a new string.
        return i < 2 || s[i - 2] != c;
    }
    if c == '*' || c == '%' || c == '&' || c == '|' || c == '^' || c == '!' || c == '<' || c == '>' { return true; }
    let end = i;
    while i > 0 && is_ident(s[i - 1]) { i--; }
    let word = s[i..end];
    return word == "return" || word == "case" || word == "throw" || word == "assert";
}

// A build file without its comments: /* ... */ (its newlines kept, so lines
// stay lines) and // to the end of the line, neither inside a quoted string.
// Kotlin and Groovy triple-quoted strings can contain newlines and comments.
fn strip_gradle_comments(s: const u8[:], kotlin: bool) -> u8[>..] {
    var out: u8[>..] = [];
    var q: u8 = 0;
    var triple = false;
    var slashy = false;
    var dollar_slashy = false;
    var i = 0;
    while i < s.len {
        let c = s[i];
        if dollar_slashy {
            out.push(c);
            if c == '$' && i + 1 < s.len && (s[i + 1] == '$' || s[i + 1] == '/') {
                out.push(s[i + 1]); i++;
            } else if c == '/' && i + 1 < s.len && s[i + 1] == '$' {
                out.push('$'); i++; dollar_slashy = false;
            }
        } else if slashy {
            out.push(c);
            if c == '\\' && i + 1 < s.len && s[i + 1] == '/' { out.push('/'); i++; }
            else if c == '/' { slashy = false; }
        } else if q != 0 {
            out.push(c);
            if c == '\\' && (!triple || !kotlin) && i + 1 < s.len { out.push(s[i + 1]); i++; }
            else if triple && c == q && i + 2 < s.len && s[i + 1] == q && s[i + 2] == q {
                out.push(q); out.push(q); i += 2; q = 0; triple = false;
            } else if !triple && (c == q || c == '\n') { q = 0; }
        } else if c == '/' && i + 1 < s.len && s[i + 1] == '*' {
            i += 2;
            var depth = 1;
            while i < s.len && depth > 0 {
                if s[i] == '/' && i + 1 < s.len && s[i + 1] == '*' && kotlin { depth++; i += 2; continue; }
                if s[i] == '*' && i + 1 < s.len && s[i + 1] == '/' { depth--; i += 2; continue; }
                if s[i] == '\n' { out.push('\n'); }
                i++;
            }
            continue;
        } else if c == '/' && i + 1 < s.len && s[i + 1] == '/' {
            while i < s.len && s[i] != '\n' { i++; }
            continue;
        } else if !kotlin && c == '$' && i + 1 < s.len && s[i + 1] == '/' {
            out.push(c); out.push('/'); i++; dollar_slashy = true;
        } else if !kotlin && c == '/' && groovy_slashy_start(out, out.len) {
            out.push(c); slashy = true;
        } else {
            out.push(c);
            if c == '"' || c == '\'' {
                q = c;
                if i + 2 < s.len && s[i + 1] == c && s[i + 2] == c {
                    triple = true; out.push(c); out.push(c); i += 2;
                }
            }
        }
        i++;
    }
    return out;
}

// Mask reaction calls, including multiline argument lists, but keep the
// surrounding code and newlines. A plugin applied in a callback still counts.
fn strip_gradle_reactions(s: const u8[:], kotlin: bool) -> u8[>..] {
    var out: u8[>..] = [];
    var q: u8 = 0;
    var triple = false;
    var depth = 0;
    var i = 0;
    while i < s.len {
        let c = s[i];
        if depth == 0 && q == 0 && (i == 0 || !is_ident(s[i - 1])) {
            var n = 0;
            for name in ["withId", "hasPlugin", "withPlugin"] {
                if starts_with(s[i..], name) { n = name.len; }
            }
            if n > 0 {
                var j = i + n;
                while j < s.len && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n' || s[j] == '\r') { j++; }
                if j < s.len && s[j] == '(' {
                    while i <= j { out.push(if s[i] == '\n' { '\n' } else { ' ' }); i++; }
                    depth = 1;
                    continue;
                }
            }
        }
        if q != 0 {
            out.push(if depth > 0 && c != '\n' { ' ' } else { c });
            if c == '\\' && (!triple || !kotlin) && i + 1 < s.len {
                i++; out.push(if depth > 0 && s[i] != '\n' { ' ' } else { s[i] });
            } else if triple && c == q && i + 2 < s.len && s[i + 1] == q && s[i + 2] == q {
                out.push(if depth > 0 { ' ' } else { q }); out.push(if depth > 0 { ' ' } else { q });
                i += 2; q = 0; triple = false;
            } else if !triple && (c == q || c == '\n') { q = 0; }
        } else {
            if c == '"' || c == '\'' {
                q = c;
                if i + 2 < s.len && s[i + 1] == c && s[i + 2] == c { triple = true; }
            } else if depth > 0 && c == '(' { depth++; }
            else if depth > 0 && c == ')' { depth--; out.push(' '); i++; continue; }
            out.push(if depth > 0 && c != '\n' { ' ' } else { c });
            if triple && q == c && i + 2 < s.len && s[i + 1] == c && s[i + 2] == c {
                out.push(if depth > 0 { ' ' } else { c }); out.push(if depth > 0 { ' ' } else { c }); i += 2;
            }
        }
        i++;
    }
    return out;
}

// Whether a plugin entry is only declared, with `apply false` / `.apply(false)`
// on its own line or on the chained lines after it (`.version(...)`).
fn gradle_apply_false(lines: const u8[:][:], at: i64) -> bool {
    var j = at;
    while j < lines.len {
        let line = trim(lines[j]);
        guard j == at || starts_with(line, ".") || starts_with(line, "apply ") || starts_with(line, "version ") else { return false; }
        if find(line, "apply false") >= 0 || find(line, "apply(false)") >= 0 { return true; }
        j++;
    }
    return false;
}

// The Android plugin a build file applies (its ANDROID_PLUGINS index), or
// -1: by id in a plugins {} block, `id("...")`, `id '...'` or `apply
// plugin:`, or by `alias(libs.plugins....)` from the version catalog.
// Comments are skipped. An entry with `apply false`, on its line or the
// chained lines after it, only declares the plugin (a root build file does
// that for its modules), and `plugins.withId(...)`, `hasPlugin(...)` and
// `withPlugin(...)` only react to it.
fn android_plugin_of(build: const u8[:], aliases: const u8[:], kotlin: bool) -> i64 {
    var k = -1;
    let text = strip_gradle_reactions(strip_gradle_comments(build, kotlin), kotlin);
    let lines = split(text, '\n');
    for raw, at in lines {
        let line = trim(raw);
        guard k < 0 else { continue; }
        guard !gradle_apply_false(lines, at) else { continue; }
        k = android_plugin_in(line);
        let al = find(line, "alias");
        if k < 0 && al >= 0 {
            var i = al + 5;
            while i < line.len && (line[i] == '(' || line[i] == ' ') { i++; }
            let start = i;
            while i < line.len && (is_ident(line[i]) || line[i] == '.') { i++; }
            let name = line[start..i];
            each_split(aliases, '\n') { a =>
                let tab = find(a, "\t");
                if tab > 0 && a[..tab] == name {
                    let n, ok = parse_int(a[tab + 1..]);
                    if ok { k = n; }
                }
            };
        }
    }
    return k;
}

// The modules settings.gradle(.kts) includes, as Gradle paths (":app",
// ":core:data"), one per line: every quoted name in an `include(...)` or
// Groovy `include '...', '...'`, which may run over several lines; names
// with ".." or "/" are skipped. Modules moved elsewhere with projectDir are
// looked for at their default place.
fn gradle_includes(repo: const u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    var s: u8[>..] = [];
    let kotlin = read_file(str(repo, "/settings.gradle.kts"), s);
    guard kotlin || read_file(str(repo, "/settings.gradle"), s) else { return out; }
    let text = strip_gradle_comments(s, kotlin);
    var open = false;
    var depth = 0;
    var triple: u8 = 0;
    var slashy = false;
    var dollar_slashy = false;
    var offset = 0;
    each_split(text, '\n') { raw =>
        let line = trim(raw);
        let line_start = offset;
        offset += raw.len + 1;
        let in_string = triple != 0 || slashy || dollar_slashy;
        var q: u8 = 0;
        var i = 0;
        while i < raw.len {
            let c = raw[i];
            if dollar_slashy {
                if c == '$' && i + 1 < raw.len && (raw[i + 1] == '$' || raw[i + 1] == '/') { i += 2; continue; }
                if c == '/' && i + 1 < raw.len && raw[i + 1] == '$' { dollar_slashy = false; i += 2; continue; }
                i++; continue;
            }
            if slashy {
                if c == '\\' && i + 1 < raw.len && raw[i + 1] == '/' { i += 2; continue; }
                if c == '/' { slashy = false; }
                i++; continue;
            }
            if c == '\\' && (q != 0 || (triple != 0 && !kotlin)) && i + 1 < raw.len { i += 2; continue; }
            if triple != 0 {
                if c == triple && i + 2 < raw.len && raw[i + 1] == c && raw[i + 2] == c { triple = 0; i += 3; continue; }
            } else if q != 0 {
                if c == q { q = 0; }
            } else if !kotlin && c == '$' && i + 1 < raw.len && raw[i + 1] == '/' {
                dollar_slashy = true; i += 2; continue;
            } else if !kotlin && c == '/' && groovy_slashy_start(text, line_start + i) {
                slashy = true;
            } else if c == '"' || c == '\'' {
                if i + 2 < raw.len && raw[i + 1] == c && raw[i + 2] == c { triple = c; i += 3; continue; }
                q = c;
            }
            i++;
        }
        guard !in_string;
        let starts = starts_with(line, "include") && line.len > 7 && (line[7] == '(' || line[7] == ' ' || line[7] == '\t');
        guard open || starts;
        var q: u8 = 0;
        var from = 0;
        for c, i in line {
            if q != 0 {
                if c == q {
                    let name = line[from..i];
                    let path: u8[>..] = if starts_with(name, ":") { str(name) } else { str(":", name) };
                    // A name with ".." or "/" is no Gradle path; it would
                    // send the build-file lookup outside the module tree.
                    let bad = find(name, "..") >= 0 || find(name, "/") >= 0;
                    if name.len > 0 && !bad && !contains_line(out, path) { format(out, path, "\n"); }
                    q = 0;
                }
            } else if c == '"' || c == '\'' {
                q = c;
                from = i + 1;
            } else if c == '(' {
                depth++;
            } else if c == ')' {
                depth--;
            }
        }
        open = depth > 0 || ends_with(line, ",");
    };
    return out;
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
fn gradle_scip_tasks(repo: const u8[:]) -> u8[>..] {
    let aliases = android_catalog_aliases(repo);
    var android = false;
    var unit = false;
    fn module(dir: const u8[:]) {
        var b: u8[>..] = [];
        let kotlin = read_file(str(dir, "/build.gradle.kts"), b);
        guard kotlin || read_file(str(dir, "/build.gradle"), b) else { return; }
        let k = android_plugin_of(b, aliases, kotlin);
        guard k >= 0 else { return; }
        android = true;
        if ANDROID_PLUGINS[k] != "com.android.test" { unit = true; }
    }
    module(repo);
    each_split(gradle_includes(repo), '\n') { path =>
        guard path.len > 1;
        var dir: u8[>..] = str(repo, "/", path[1..]);
        for i in (repo.len + 1)..dir.len { if dir[i] == ':' { dir[i] = '/'; } }
        module(dir);
    };
    var tasks: u8[>..] = [];
    tasks.append("clean\n");
    if android {
        tasks.append("compileDebugKotlin\n");
        if unit { tasks.append("compileDebugUnitTestKotlin\n"); }
    } else {
        tasks.append("scipPrintDependencies\n");
    }
    tasks.append("scipCompileAll\n");
    return tasks;
}
