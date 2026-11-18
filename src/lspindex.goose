// `swan lsp-index <repo> <out-dir> <lang> <target.scip>`: a map for a
// language that has a language server but no SCIP indexer, made by asking
// the server. For every file of the language it asks for the document's
// symbols (definitions, with their nesting and ranges), then for each
// definition its references. What comes back is what the server's own
// compiler resolved, so these rows are exact, not matched by name.
//
// The answers are written as a SCIP index, like `swan syntax-index`, so the
// flattener and everything after it treat the language like any other.
// Which languages are mapped this way is data: `"map": "lsp"` on the
// language's entry in tools/modules.json (Goose is the first).
//
// Limits: only what is defined in the repo is asked about, so uses of the
// standard library and of packages are not in the map; symbols nested more
// than four deep are left out.

import std;
import os;
import json;
import dictionary;

// LSP SymbolKind to SCIP's SymbolInformation.Kind (src/scip.goose reads it).
fn lx_scip_kind(k: i64) -> i64 {
    return match k {
        2 => 29, 3 => 30, 5 => 7, 6 => 26, 8 => 15, 9 => 9, 10 => 11, 11 => 21, 12 => 17,
        13 => 61, 14 => 8, 22 => 12, 23 => 49, 26 => 58,
        _ => 61,
    };
}

// The SCIP descriptor suffix for an LSP SymbolKind: 'm' for what is called
// (written "()."), '#' for a type, '.' for the rest.
fn lx_suffix(k: i64) -> u8 {
    return match k {
        6, 9, 12 => 'm',
        5, 10, 11, 23 => '#',
        _ => '.',
    };
}

// The repo-relative path a file:// URI names, percent-decoded; false when
// it is not inside the repo.
fn lx_uri_rel(uri: const u8[:], repo: const u8[:], out: u8[>..]&) -> bool {
    guard starts_with(uri, "file://") else { return false; }
    var path: u8[>..] = [];
    var i = 7;
    while i < uri.len {
        let c = uri[i];
        if c == '%' && i + 2 < uri.len {
            let v, ok = parse_int(str("0x", uri[i + 1..i + 3]));
            if ok { path.push(v as! u8); i += 3; continue; }
        }
        path.push(c);
        i++;
    }
    guard path.len > repo.len + 1 && starts_with(path, repo) && path[repo.len] == '/' else { return false; }
    out.append(path[repo.len + 1..]);
    return true;
}

// Line n (0-based) of text, without its newline.
fn lx_line(text: const u8[:], n: i64) -> const u8[:] {
    var at = 0;
    var k = 0;
    while k < n && at < text.len {
        let nl = find(text[at..], "\n");
        if nl < 0 { return text[text.len..]; }
        at += nl + 1;
        k++;
    }
    guard at <= text.len else { return text[text.len..]; }
    let nl = find(text[at..], "\n");
    return if nl < 0 { text[at..] } else { text[at..at + nl] };
}

// `within`: a folder of the repo ("" for all of it). Only its files are
// asked about and the server is started in it, the way an editor opens a Go
// module; the paths written stay relative to the repo, so the rows are the
// ones a run over the whole repo would give.
fn lsp_index_main(repo: const u8[:], out: const u8[:], lang: const u8[:], target: const u8[:], within: const u8[:] = "") -> bool {
    let t0 = clock();
    walk_ignore_load(repo, out);
    var why: u8[>..] = [];
    live_within.clear();
    if within.len > 0 && within != "." { live_within.append(within); }
    guard live_start_at(repo, out, lang, why) else {
        write_stderr(str("lsp-index: ", why, "\n"));
        return false;
    }
    // What the server is asked about a file by: its path from the server's
    // own folder.
    let cut = if live_within.len > 0 { live_within.len + 1 } else { 0 };
    // The language's files, in the order the repo is walked.
    var paths: u8[>..] = [];
    each_file(repo) { full, name =>
        if lang_of_path(name) == lang && full.len > repo.len + 1 {
            let rel = full[repo.len + 1..];
            if cut == 0 || (rel.len > cut && starts_with(rel, live_within[..]) && rel[cut - 1] == '/') { format(paths, rel, "\n"); }
        }
    };
    var p_off: i64[>..] = [];
    var p_len: i64[>..] = [];
    var by_path = dictionary<u64, i64> {};       // path hash -> file number + 1
    var at = 0;
    each_split(paths, '\n') { rel =>
        if rel.len > 0 { by_path.insert(hash(rel), p_off.len + 1); p_off.push(at); p_len.push(rel.len); }
        at += rel.len + 1;
    };
    let nfiles = p_off.len;

    var pkg: u8[>..] = [];
    format(pkg, "swan-lsp-", lang, " . ");      // src/scip.goose reads the language from the scheme
    var rn: u8[>..] = [];
    sx_ident(sx_basename(repo), rn);
    for c in rn { pkg.push(if c == ' ' { '_' } else { c }); }
    pkg.append(" 0 ");

    // Definitions, as parallel arrays; strings in shared buffers.
    var names: u8[>..] = [];
    var descs: u8[>..] = [];
    var sigs: u8[>..] = [];
    var d_noff: i64[>..] = []; var d_nlen: i64[>..] = [];
    var d_doff: i64[>..] = []; var d_dlen: i64[>..] = [];
    var d_goff: i64[>..] = []; var d_glen: i64[>..] = [];
    var d_file: i64[>..] = []; var d_kind: i64[>..] = [];
    var d_line: i64[>..] = []; var d_col: i64[>..] = []; var d_ecol: i64[>..] = [];
    var d_rl: i64[>..] = []; var d_rc: i64[>..] = []; var d_el: i64[>..] = []; var d_ec: i64[>..] = [];
    var d_raw: i64[>..] = [];                    // the LSP SymbolKind as sent
    var d_parent: i64[>..] = [];                 // the definition this one is nested in, or -1
    var def_at = dictionary<u64, i64> {};        // "file:line:col" of a name -> definition number + 1
    var f_first: i64[>..] = [];
    var overloads = dictionary<u64, i64> {};     // a callable's path -> how many have it so far
    var file_ns: u8[>..] = [];
    var text: u8[>..] = [];
    var cur_file = 0;

    // One symbol of a documentSymbol answer; `parent` is the definition it is
    // nested in, or -1. Returns its number, or -1 when the node is not usable.
    fn add_def(node: json::Node?, parent: i64) -> i64 {
        let name, n_ok = json::as_string(json::member(node, "name"));
        let kind, k_ok = json::as_i64(json::member(node, "kind"));
        let sel = json::member(node, "selectionRange");
        let rng = json::member(node, "range");
        let sl, a_ok = json::as_i64(json::member(json::member(sel, "start"), "line"));
        let sc, b_ok = json::as_i64(json::member(json::member(sel, "start"), "character"));
        let se, c_ok = json::as_i64(json::member(json::member(sel, "end"), "character"));
        let rl, d_ok = json::as_i64(json::member(json::member(rng, "start"), "line"));
        let rc, e_ok = json::as_i64(json::member(json::member(rng, "start"), "character"));
        let el, f_ok = json::as_i64(json::member(json::member(rng, "end"), "line"));
        let ec, g_ok = json::as_i64(json::member(json::member(rng, "end"), "character"));
        guard n_ok && k_ok && a_ok && b_ok && c_ok && d_ok && e_ok && f_ok && g_ok && name.len > 0 else { return -1; }
        // "(Greeter).Greet" at the top of a file (a Go method, named so by the
        // bridge) is Greet nested under the type Greeter.
        let close = find(name, ").");
        let has_recv = parent < 0 && name.len > 3 && name[0] == '(' && close > 1 && close + 2 < name.len;
        let recv = if has_recv { name[1..close] } else { name[..0] };
        let short = if has_recv { name[close + 2..] } else { name };
        var desc: u8[>..] = [];
        if parent >= 0 { desc.append(descs[d_doff[parent]..d_doff[parent] + d_dlen[parent]]); } else { desc.append(file_ns); }
        if has_recv { sx_ident(recv, desc); desc.push('#'); }
        sx_ident(short, desc);
        let suf = lx_suffix(kind);
        if suf == 'm' {
            // A second callable on the same path (an overload): SCIP's disambiguator.
            let key = hash(desc);
            let seen = overloads.get(key);
            var n: i64 = 0;
            if seen { n = seen; }
            overloads.insert(key, n + 1);
            if n == 0 { desc.append("()."); } else { format(desc, "(+", n, ")."); }
        } else {
            desc.push(suf);
        }
        let d = d_kind.len;
        d_noff.push(names.len); d_nlen.push(short.len); names.append(short);
        d_doff.push(descs.len); d_dlen.push(desc.len); descs.append(desc);
        let sig = sx_cut(trim(lx_line(text, sl)), 200);
        d_goff.push(sigs.len); d_glen.push(sig.len); sigs.append(sig);
        d_file.push(cur_file); d_kind.push(lx_scip_kind(kind));
        d_raw.push(kind); d_parent.push(parent);
        def_at.insert(hash(str(cur_file, ":", sl, ":", sc)), d + 1);
        d_line.push(sl); d_col.push(sc); d_ecol.push(se);
        d_rl.push(rl); d_rc.push(rc); d_el.push(el); d_ec.push(ec);
        return d;
    }

    var asked_failed = 0;
    for fi in nfiles {
        f_first.push(d_kind.len);
        let rel = paths[p_off[fi]..p_off[fi] + p_len[fi]];
        file_ns.clear();
        sx_ns(sx_dirname(rel), file_ns);
        sx_ident(sx_basename(rel), file_ns);
        file_ns.push('/');
        cur_file = fi;
        text.clear();
        read_file(str(repo, "/", rel), text);
        var ans: u8[>..] = [];
        guard live_request(repo, out, rel[cut..], "textDocument/documentSymbol", 0, 0, "", ans) else {
            asked_failed++;
            write_stderr(str("lsp-index: no symbols for ", rel, ": ", ans[..min(ans.len, 200)], "\n"));
            continue;
        }
        var doc: json::Node[>..] = [];
        var dec: u8[>..] = [];
        let root, perr = json::parse(ans, doc, dec);
        let res = json::member(root, "result");
        if res {
            json::each(res) { s1 =>
                let i1 = add_def(s1, -1);
                let c1 = json::member(s1, "children");
                if i1 >= 0 && c1 {
                    json::each(c1) { s2 =>
                        let i2 = add_def(s2, i1);
                        let c2 = json::member(s2, "children");
                        if i2 >= 0 && c2 {
                            json::each(c2) { s3 =>
                                let i3 = add_def(s3, i2);
                                let c3 = json::member(s3, "children");
                                if i3 >= 0 && c3 { json::each(c3) { s4 => add_def(s4, i3); }; }
                            };
                        }
                    };
                }
            };
        }
    }
    f_first.push(d_kind.len);
    guard !(nfiles > 0 && asked_failed == nfiles) else {
        write_stderr("lsp-index: the language server answered for no file\n");
        live_stop();
        return false;
    }

    // Each definition's references, as the server resolved them.
    var o_file: i64[>..] = []; var o_line: i64[>..] = []; var o_col: i64[>..] = [];
    var o_ecol: i64[>..] = []; var o_def: i64[>..] = [];
    for d in d_kind.len {
        let fi = d_file[d];
        let rel = paths[p_off[fi]..p_off[fi] + p_len[fi]];
        var ans: u8[>..] = [];
        guard live_request(repo, out, rel[cut..], "textDocument/references", d_line[d] + 1, d_col[d] + 1,
                           "\"context\":{\"includeDeclaration\":false}", ans) else { continue; }
        var doc: json::Node[>..] = [];
        var dec: u8[>..] = [];
        let root, perr = json::parse(ans, doc, dec);
        let res = json::member(root, "result");
        if res {
            json::each(res) { loc =>
                let u, u_ok = json::as_string(json::member(loc, "uri"));
                let r = json::member(loc, "range");
                let l, l_ok = json::as_i64(json::member(json::member(r, "start"), "line"));
                let c, c_ok = json::as_i64(json::member(json::member(r, "start"), "character"));
                let e, e_ok = json::as_i64(json::member(json::member(r, "end"), "character"));
                var rp: u8[>..] = [];
                if u_ok && l_ok && c_ok && e_ok && lx_uri_rel(u, repo, rp) {
                    let k = by_path.get(hash(rp));
                    if k {
                        let f2: i64 = k;
                        let own = f2 - 1 == fi && l == d_line[d] && c == d_col[d];
                        if !own {
                            o_file.push(f2 - 1); o_line.push(l); o_col.push(c);
                            o_ecol.push(if e > c { e } else { c + d_nlen[d] });
                            o_def.push(d);
                        }
                    }
                }
            };
        }
    }
    // What implements each interface or class, and each of their methods:
    // SCIP keeps that on the implementing symbol, as a relationship.
    var r_from: i64[>..] = [];
    var r_to: i64[>..] = [];
    for d in d_kind.len {
        let own = d_raw[d] == 5 || d_raw[d] == 11;
        let p = d_parent[d];
        let member = p >= 0 && (d_raw[p] == 5 || d_raw[p] == 11) && (d_raw[d] == 6 || d_raw[d] == 12);
        guard own || member else { continue; }
        let fi = d_file[d];
        let rel = paths[p_off[fi]..p_off[fi] + p_len[fi]];
        var ans: u8[>..] = [];
        guard live_request(repo, out, rel[cut..], "textDocument/implementation", d_line[d] + 1, d_col[d] + 1, "", ans) else { continue; }
        var doc: json::Node[>..] = [];
        var dec: u8[>..] = [];
        let root, perr = json::parse(ans, doc, dec);
        let res = json::member(root, "result");
        if res {
            json::each(res) { loc =>
                let u, u_ok = json::as_string(json::member(loc, "uri"));
                let r = json::member(loc, "range");
                let l, l_ok = json::as_i64(json::member(json::member(r, "start"), "line"));
                let c, c_ok = json::as_i64(json::member(json::member(r, "start"), "character"));
                var rp: u8[>..] = [];
                if u_ok && l_ok && c_ok && lx_uri_rel(u, repo, rp) {
                    let k = by_path.get(hash(rp));
                    if k {
                        let f2: i64 = k;
                        let hit = def_at.get(hash(str(f2 - 1, ":", l, ":", c)));
                        if hit {
                            let d2: i64 = hit;
                            if d2 - 1 != d { r_from.push(d2 - 1); r_to.push(d); }
                        }
                    }
                }
            };
        }
    }
    live_stop();

    // The SCIP index: metadata, then one document per file.
    var top: u8[>..] = [];
    var meta: u8[>..] = [];
    var tool: u8[>..] = [];
    pb_int(meta, 1, 0);
    pb_bytes(tool, 1, "swan-lsp");
    pb_bytes(tool, 2, "1");
    pb_bytes(meta, 2, tool);
    pb_bytes(meta, 3, str("file://", repo));
    pb_int(meta, 4, 1);
    pb_bytes(top, 1, meta);
    var occ: u8[>..] = [];
    var info: u8[>..] = [];
    var docm: u8[>..] = [];
    var sym: u8[>..] = [];
    for fi in nfiles {
        let rel = paths[p_off[fi]..p_off[fi] + p_len[fi]];
        var doc: u8[>..] = [];
        pb_bytes(doc, 1, rel);
        pb_bytes(doc, 4, lang);
        for d in f_first[fi]..f_first[fi + 1] {
            sym.clear();
            sym.append(pkg);
            sym.append(descs[d_doff[d]..d_doff[d] + d_dlen[d]]);
            occ.clear();
            pb_range(occ, 1, d_line[d], d_col[d], d_line[d], d_ecol[d]);
            pb_bytes(occ, 2, sym);
            pb_int(occ, 3, 1);
            pb_range(occ, 7, d_rl[d], d_rc[d], d_el[d], d_ec[d]);
            pb_bytes(doc, 2, occ);
        }
        for o in o_def.len {
            if o_file[o] == fi {
                let d = o_def[o];
                sym.clear();
                sym.append(pkg);
                sym.append(descs[d_doff[d]..d_doff[d] + d_dlen[d]]);
                occ.clear();
                pb_range(occ, 1, o_line[o], o_col[o], o_line[o], o_ecol[o]);
                pb_bytes(occ, 2, sym);
                pb_bytes(doc, 2, occ);
            }
        }
        for d in f_first[fi]..f_first[fi + 1] {
            sym.clear();
            sym.append(pkg);
            sym.append(descs[d_doff[d]..d_doff[d] + d_dlen[d]]);
            info.clear();
            pb_bytes(info, 1, sym);
            docm.clear();
            format(docm, "```", lang, "\n", sigs[d_goff[d]..d_goff[d] + d_glen[d]], "\n```");
            pb_bytes(info, 3, docm);
            for r in r_from.len {
                if r_from[r] == d {
                    let t = r_to[r];
                    var rs: u8[>..] = [];
                    var tsym: u8[>..] = [];
                    tsym.append(pkg);
                    tsym.append(descs[d_doff[t]..d_doff[t] + d_dlen[t]]);
                    pb_bytes(rs, 1, tsym);
                    pb_int(rs, 3, 1);
                    pb_bytes(info, 4, rs);
                }
            }
            pb_int(info, 5, d_kind[d]);
            pb_bytes(info, 6, names[d_noff[d]..d_noff[d] + d_nlen[d]]);
            pb_bytes(doc, 3, info);
        }
        pb_bytes(top, 2, doc);
    }
    guard write_file_atomic(target, top) else {
        write_stderr(str("lsp-index: cannot write ", target, "\n"));
        return false;
    }
    write_stderr(str("lsp-index ", lang, ": ", nfiles, " files, ", d_kind.len, " definitions, ", o_def.len,
                     " references, ", r_from.len, " implementations, ", ((clock() - t0) * 1000.0) as i64, " ms\n"));
    return true;
}
