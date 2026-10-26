#!/usr/bin/env python3
"""Measure Goose package build boundaries without downloads or shared caches.

Requires an installed Goose compiler, a C compiler, Python 3 and GNU time.
Source packages (including initialized tree-sitter submodules) must exist.
The output directory must be new. It retains sources, caches and raw logs.
"""
import argparse
import collections
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def files(root):
    return sorted(p for p in root.rglob('*') if p.is_file() and '.git' not in p.parts)


def footprint(root):
    by_suffix = collections.defaultdict(lambda: {'files': 0, 'bytes': 0})
    total = 0
    for path in files(root):
        size = path.stat().st_size
        total += size
        entry = by_suffix[path.suffix or '(none)']
        entry['files'] += 1
        entry['bytes'] += size
    return {'bytes': total, 'by_suffix': dict(sorted(by_suffix.items()))}


def snapshot(source, destination):
    # A tracked-source snapshot includes local modifications, but no build
    # products or credentials. Recurse through checked-out Git submodules.
    if (source / '.git').exists():
        listing = subprocess.check_output(['git', '-C', str(source), 'ls-files', '--stage', '-z'])
        destination.mkdir(parents=True)
        for record in listing.split(b'\0'):
            if not record:
                continue
            meta, filename = record.split(b'\t', 1)
            name = os.fsdecode(filename)
            src, dst = source / name, destination / name
            if meta.startswith(b'160000 '):
                snapshot(src, dst)
            else:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst, follow_symlinks=False)
    else:
        shutil.copytree(source, destination, ignore=shutil.ignore_patterns('.git', '__pycache__'))


def capture(command, env):
    return subprocess.check_output(command, env=env, text=True, stderr=subprocess.STDOUT).strip()


def cache_state(root):
    return {str(p.relative_to(root)): (p.stat().st_size, p.stat().st_mtime_ns) for p in files(root)}


def timed(command, directory, env, stem):
    log, metrics = stem.with_suffix('.log'), stem.with_suffix('.time')
    start = time.perf_counter()
    with log.open('w') as output:
        result = subprocess.run(['/usr/bin/time', '-f', '%e\t%M', '-o', str(metrics), *command],
                                cwd=directory, env=env, stdout=output, stderr=subprocess.STDOUT)
    elapsed = time.perf_counter() - start
    raw = metrics.read_text().splitlines()[-1].split('\t')
    return {'command': command, 'cwd': str(directory), 'exit_code': result.returncode,
            'wall_seconds': elapsed, 'gnu_time_wall_seconds': float(raw[0]),
            'max_process_rss_kib': int(raw[1]), 'log': str(log)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--goose', required=True, type=Path)
    parser.add_argument('--sqlite', required=True, type=Path)
    parser.add_argument('--treesitter', required=True, type=Path)
    parser.add_argument('--lsp', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--warm-runs', type=int, default=3)
    args = parser.parse_args()
    if args.warm_runs < 1:
        parser.error('--warm-runs must be at least 1')
    goose, out = args.goose.resolve(), args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    sources = out / 'sources'
    for name in ('sqlite', 'treesitter', 'lsp'):
        snapshot(getattr(args, name).resolve(), sources / name)
    env = dict(os.environ, GOOSE_HOME=str(out / 'metadata-home'), GOOSE_PROGRESS='plain')
    source_manifest = {str(p.relative_to(sources)): {'sha256': digest(p), 'bytes': p.stat().st_size}
                       for p in files(sources)}
    (out / 'source-manifest.json').write_text(json.dumps(source_manifest, indent=2) + '\n')
    metadata = {
        'started_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'machine': platform.platform(), 'architecture': platform.machine(),
        'cpu_count': os.cpu_count(), 'load_average_at_start': os.getloadavg(),
        'cpu_model': next((line.split(':', 1)[1].strip() for line in Path('/proc/cpuinfo').read_text().splitlines()
                           if line.startswith('model name')), 'unknown'),
        'goose': str(goose), 'goose_sha256': digest(goose),
        'goose_version': capture([str(goose), 'version'], env),
        'toolchain': json.loads(capture([str(goose), 'toolchain', '--json'], env)),
        'source_footprint': {name: footprint(sources / name) for name in ('sqlite', 'treesitter', 'lsp')},
        'method': 'Each case uses its own empty GOOSE_HOME, local source imports, -O2 AOT build. '
                  'Cold includes runtime/native compilation but excludes downloads and source-copy time. '
                  'Warm rebuilds exactly the same program in that cache; no source edits. '
                  'No OS page-cache flush; no server startup or indexing in these timings. '
                  'RSS is GNU time maximum process RSS, not aggregate concurrent memory. '
                  'Source and cache sizes are logical file bytes, excluding .git; binary sizes are unstripped.',
    }
    sqlite_import = 'import sqlite from "' + str(sources / 'sqlite') + '";\n'
    treesitter_import = 'import treesitter from "' + str(sources / 'treesitter') + '";\n'
    cases = {
        'baseline': 'import std;\nfn main() { print("ok"); }\n',
        'sqlite-import-only': 'import std;\n' + sqlite_import + 'fn main() { print("ok"); }\n',
        'sqlite-used': 'import std;\n' + sqlite_import + '''fn main() {
    var err: u8[>..] = [];
    let db = sqlite::open(":memory:", err);
    assert(db != 0);
    sqlite::exec_or_die(db, "CREATE TABLE n (v INTEGER); INSERT INTO n VALUES (42)");
    let st = sqlite::prepare_or_die(db, "SELECT v FROM n");
    assert(sqlite::step(st, err) == 1);
    assert(sqlite::col_int(st, 0) == 42);
    sqlite::finalize(st);
    sqlite::close(db);
    print("ok");
}\n''',
        'treesitter-import-only': 'import std;\n' + treesitter_import + 'fn main() { print("ok"); }\n',
        'treesitter-goose-helper': 'import std;\n' + treesitter_import + '''fn main() {
    assert(treesitter::language_of_path("sample.py") == "python");
    assert(treesitter::language_of_path("sample.txt") == "");
    print("ok");
}\n''',
        'treesitter-rust-parse': 'import std;\n' + treesitter_import + '''fn main() {
    var nodes: i32[>..] = [];
    assert(treesitter::parse("rust", "fn main() {}", nodes));
    assert(nodes.len > 0);
    print("ok");
}\n''',
        'lsp-link-only': 'import std;\nextern fn golsp_stop();\nfn main() { golsp_stop(); print("ok"); }\n',
    }
    results = {'metadata': metadata, 'cases': {}}
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    failed = False
    for name, source in cases.items():
        directory = out / name
        directory.mkdir()
        program = directory / 'main.goose'
        program.write_text(source)
        cache = directory / 'goose-home'
        case_env = dict(env, GOOSE_HOME=str(cache), GOOSE=str(goose))
        runs = []
        generation = None
        if name == 'lsp-link-only':
            generated = directory / 'generated'
            generation = timed(['bash', str(sources / 'lsp/scripts/build.sh'), str(generated)], directory,
                               case_env, directory / 'generation')
            native = [sources / 'lsp/native/proc.c', sources / 'lsp/native/glue.c', generated / 'golsp.c']
            (directory / 'main.build').write_text('c_sources = ' + json.dumps([str(p) for p in native]) + ';\n')
            if generation['exit_code']:
                failed = True
                results['cases'][name] = {'generation': generation, 'runs': [], 'status': 'failed'}
                continue
        for index in range(args.warm_runs + 1):
            before = cache_state(cache)
            label = 'cold' if index == 0 else f'warm-{index}'
            run = timed([str(goose), 'build', '--offline', '-v', str(program), '-o', str(directory / 'program')],
                        directory, case_env, directory / label)
            after = cache_state(cache)
            changed = [path for path, stamp in after.items() if before.get(path) != stamp]
            run.update(label=label, cache_bytes=sum(stamp[0] for stamp in after.values()),
                       changed_object_files=[path for path in changed if path.endswith('.o')],
                       native_package_objects=[path for path in after if path.startswith('build/pkg/') and path.endswith('.o')])
            if run['exit_code'] == 0:
                binary = directory / 'program'
                run['binary_bytes'] = binary.stat().st_size
                run['binary_sha256'] = digest(binary)
                smoke = subprocess.run([str(binary)], cwd=directory, env=case_env, text=True,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=10)
                run['smoke_exit_code'] = smoke.returncode
                run['smoke_output'] = smoke.stdout
                if smoke.returncode != 0 or smoke.stdout != 'ok\n':
                    failed = True
            else:
                failed = True
            runs.append(run)
            results['cases'][name] = {'generation': generation, 'runs': runs,
                                      'cache_footprint': footprint(cache)}
            (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
            print(f'{name}: {label} {run["wall_seconds"]:.3f}s exit={run["exit_code"]}', flush=True)
            if run['exit_code']:
                break
    results['metadata']['finished_utc'] = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    results['metadata']['load_average_at_end'] = os.getloadavg()
    results['status'] = 'failed' if failed else 'passed'
    (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
