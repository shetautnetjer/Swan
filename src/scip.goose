// What a SCIP symbol string says about itself. The grammar (scip.proto):
//   <scheme> ' ' <manager> ' ' <package-name> ' ' <version> ' ' <descriptors>
// where a space inside a field is written as two, and each descriptor ends
// in a suffix: '/' namespace, '#' type, '.' term, '(disambiguator).' method,
// '(name)' parameter, '[name]' type parameter, ':' meta, '!' macro.
// Swan names the suffixes with one byte: the grammar's own for '/', '#',
// '.', ':' and '!', and 'm' method, 'p' parameter, 'g' type parameter.

import std;

fn is_ident(c: u8) -> bool {
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
        c == '_' || c == '+' || c == '-' || c == '$'
}

// The descriptors: everything after the four header fields.
fn descriptors_of(sym: const u8[:]) -> const u8[:] {
    var i = 0;
    var fields = 0;
    while i < sym.len && fields < 4 {
        if sym[i] == ' ' {
            if i + 1 < sym.len && sym[i + 1] == ' ' { i += 2; continue; }
            fields++;
        }
        i++;
    }
    return sym[i..];
}

// A name at d[i..]: an identifier, or text between backticks (`` is a
// literal backtick, kept doubled in the slice). Returns it and where it ends.
fn read_name(d: const u8[:], at: i64) -> const u8[:], i64 {
    var i = at;
    if i < d.len && d[i] == '`' {
        i++;
        let start = i;
        while i < d.len {
            if d[i] == '`' {
                if i + 1 < d.len && d[i + 1] == '`' { i += 2; continue; }
                break;
            }
            i++;
        }
        let name = d[start..i];
        return name, if i < d.len { i + 1 } else { i };
    }
    let start = i;
    while i < d.len && is_ident(d[i]) { i++; }
    return d[start..i], i;
}

// Calls F(name, suffix) for each descriptor, outermost first.
fn each_descriptor<F>(d: const u8[:]) {
    var i = 0;
    while i < d.len {
        let open = d[i];
        if open == '(' || open == '[' {
            let name, end = read_name(d, i + 1);
            i = end;
            if i < d.len && (d[i] == ')' || d[i] == ']') { i++; }
            F(name, if open == '(' { 'p' as u8 } else { 'g' as u8 });
            continue;
        }
        let name, end = read_name(d, i);
        i = end;
        guard i < d.len else { F(name, '?' as u8); break; }
        let c = d[i];
        if c == '(' {
            while i < d.len && d[i] != ')' { i++; }
            i++;
            if i < d.len && d[i] == '.' { i++; }
            F(name, 'm' as u8);
        } else {
            i++;
            F(name, c);
        }
    }
}

// The innermost descriptor's name and suffix, and the Serena-style name
// path: the non-namespace names joined by '/' (Store/add), or for a module
// the file name itself.
fn describe(sym: const u8[:], path: u8[>..]&) -> const u8[:], u8 {
    let d = descriptors_of(sym);
    var last = d[0..0];
    var suffix: u8 = '?';
    each_descriptor(d) { name, s =>
        last = name;
        suffix = s;
        if s != '/' {
            if path.len > 0 { path.push('/'); }
            path.append(name);
        }
    };
    if path.len == 0 { path.append(last); }
    return last, suffix;
}

// A kind word for an agent. The signature scip-typescript writes starts with
// it ("class Store", "(method) add(...)"); otherwise the suffix says it.
fn kind_word(sig: const u8[:], suffix: u8) -> const u8[:] {
    if sig.len > 1 && sig[0] == '(' {
        let close = find(sig, ")");
        if close > 1 { return sig[1..close]; }
    }
    let sp = find(sig, " ");
    let first = if sp > 0 { sig[..sp] } else { sig };
    if first == "class" || first == "interface" || first == "function" || first == "enum" ||
        first == "module" || first == "namespace" || first == "type" { return first; }
    if first == "var" || first == "let" { return "variable"; }
    if first == "const" { return "constant"; }
    return match suffix {
        '/' => "namespace",
        '#' => "type",
        '.' => "term",
        'm' => "method",
        'p' => "parameter",
        'g' => "type_parameter",
        ':' => "meta",
        '!' => "macro",
        _ => "unknown",
    };
}

// The package a symbol belongs to, "<name> <version>" from the header
// ("scip-typescript npm bun-types 1.3.7 ..." gives "bun-types 1.3.7").
fn package_of(sym: const u8[:]) -> const u8[:] {
    var i = 0;
    var field = 0;
    var start = 0;
    while i < sym.len {
        if sym[i] == ' ' {
            if i + 1 < sym.len && sym[i + 1] == ' ' { i += 2; continue; }
            field++;
            if field == 2 { start = i + 1; }
            if field == 4 { return sym[start..i]; }
        }
        i++;
    }
    return sym[0..0];
}
