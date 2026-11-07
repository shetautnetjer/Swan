#!/usr/bin/env python3
"""Exercise clean rebuild against an explicit binary in a disposable installation.

Native CLI/MCP, SQLite publication and inherited writer locks are real. Synthetic
indexers/flattener expose cache reuse, partial failure and interruption without
running repository build files, language servers or changing installed maps.
Artifacts, transcripts and the exact binary hash are retained on success/failure.
"""
import argparse
from contextlib import closing
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import time

from check_concurrency import connect, require
from test_request_build_policy import PolicyChecks, digest, inventory

SENTINEL = r'''import json, os, sys, time
from pathlib import Path
home, mode = Path(sys.argv[1]), sys.argv[2]
args = sys.argv[3:]
with (home / 'invocations.jsonl').open('a') as stream:
    stream.write(json.dumps({'mode': mode, 'cwd': os.getcwd(), 'args': args, 'pid': os.getpid()}) + '\n')
control = (home / 'control').read_text() if (home / 'control').exists() else ''
generation = (home / 'generation').read_text() if (home / 'generation').exists() else 'one'
if mode == 'tsc':
    print('\n'.join(str(p) for p in sorted(Path.cwd().rglob('*.ts'))))
elif mode in ('indexer', 'python'):
    assert '--output' in args, args
    target = Path(args[args.index('--output') + 1])
    if control == 'hold':
        (home / 'held').write_text(str(os.getpid()))
        while not (home / 'release').exists(): time.sleep(.01)
    if control == 'fail' or (control == 'fail-python' and mode == 'python'): sys.exit(9)
    if control != 'silent': target.write_text(generation)
elif mode == 'flatten':
    if control == 'flatten-fail': sys.exit(8)
    if control == 'flatten-silent': sys.exit(0)
    repo, output = Path(args[2]), Path(args[4])
    for index in [args[3], *args[5:]]:
        assert Path(index.split('=', 1)[0]).read_text() == generation, 'reused stale SCIP or merge layer: ' + index
    symbol = 'scip-typescript npm clean-fixture 0.0.0 probe().'
    source = 'probe.ts' if (repo / 'probe.ts').exists() else 'probe.py'
    (output / 'symbols.tsv').write_text(f'{symbol}\tprobe\t17\t\tgeneration:{generation}\t\n')
    (output / 'extents.tsv').write_text(f'{symbol}\t{source}\t0\t0\t0\t29\n')
    (output / 'occurrences.tsv').write_text(f'{symbol}\t{source}\t0\t9\t0\t14\tdef\n')
    (output / 'relationships.tsv').write_text('')
    if control == 'malformed-symbols':
        (output / 'symbols.tsv').write_text('not a valid symbol row\n')
        (output / 'extents.tsv').write_text('')
        (output / 'occurrences.tsv').write_text('')
    if control == 'malformed-kind':
        (output / 'symbols.tsv').write_text(f'{symbol}\tprobe\tnot-a-number\t\tgeneration:{generation}\n')
    if control == 'malformed-extents':
        (output / 'extents.tsv').write_text(f'{symbol}\t{source}\tnot-a-number\t0\t0\t29\n')
    if control == 'malformed-extents-short':
        (output / 'extents.tsv').write_text('one-field\n')
    if control == 'malformed-occurrences':
        (output / 'occurrences.tsv').write_text(f'{symbol}\t{source}\t0\t9\t0\t14\tbogus-role\n')
    if control == 'malformed-relationships':
        (output / 'relationships.tsv').write_text(f'{symbol}\t{source}\t{symbol}\tbogus-flag\n')
    if control == 'empty-flatten':
        for name in ('symbols.tsv', 'extents.tsv', 'occurrences.tsv', 'relationships.tsv'):
            (output / name).write_text('\n')
    if control == 'legacy-symbols':
        (output / 'symbols.tsv').write_text(f'{symbol}\tprobe\t17\t\tgeneration:{generation}\n')
else: raise RuntimeError(mode)
'''


class CleanChecks(PolicyChecks):
    """Qualify native clean publication and recovery with disposable synthetic tools."""

    def __init__(self, options):
        """Prepare the private binary copy, synthetic tools and isolated trust fixture."""
        super().__init__(options)
        (self.prefix / 'sentinel.py').write_text(SENTINEL)
        tsc = self.prefix / 'tools/node_modules/.bin/tsc'
        tsc.write_text(tsc.read_text().replace('unexpected-tsc', 'tsc'))
        python = self.prefix / 'tools/node_modules/.bin/scip-python'
        python.write_text((self.prefix / 'tools/node_modules/.bin/scip-typescript').read_text().replace(' indexer ', ' python '))
        python.chmod(0o755)
        self.environment['SWAN_JOBS'] = '2'
        (self.prefix / 'data').mkdir()
        (self.prefix / 'data/trusted-repos').write_text('/not-this-fixture\n')
        (self.prefix / 'tools/modules.json').write_text('{}\n')

    def control(self, mode='', generation=None):
        """Select the synthetic child behavior and optional output generation."""
        (self.prefix / 'control').write_text(mode)
        if generation is not None:
            (self.prefix / 'generation').write_text(generation)

    def map(self, repo, out, clean=False, success=True):
        """Run the native mapper, retain its log and assert the expected exit outcome."""
        command = [str(self.binary), 'map', str(repo), str(out)] + (['--clean'] if clean else [])
        result = subprocess.run(command, env=self.environment, capture_output=True, text=True, timeout=self.options.timeout)
        self.serial += 1
        (self.directory / f'map-{self.serial}.log').write_text(result.stdout + result.stderr)
        require((result.returncode == 0) == success, result.stdout + result.stderr)
        return result

    def signature(self, client, repo):
        """Read the single probe symbol's generation through the persistent MCP client."""
        rows = client.good('find_symbol', {'repo': str(repo), 'build': False, 'name_path_pattern': 'probe'})
        require(len(rows) == 1, repr(rows))
        return rows[0]['signature']

    def cached_layers_and_reader(self):
        """Prove clean replaces reused TS layers while preserving reader and lock identity."""
        folder, registry = self.context('layers-reader')
        repo = self.repository(folder, 'typescript')
        for n in range(11): (repo / f'extra{n}.ts').write_text(f'export const extra{n} = {n};\n')
        out = registry / 'typescript'
        self.control(generation='one')
        self.map(repo, out)
        # A small edit creates a real delta layer through the ordinary planner.
        with (repo / 'probe.ts').open('a') as f: f.write('// changed\n')
        self.map(repo, out)
        require((out / 'typescript-layers.txt').read_text().strip(), 'fixture did not create a delta layer')
        calls = len(self.marker())
        self.map(repo, out)
        require(len(self.marker()) == calls, 'unchanged control unexpectedly indexed')
        with closing(connect(out / 'swan.db')) as db:
            db.execute('CREATE TABLE stale_orphan(value TEXT)')
            db.execute("INSERT INTO stale_orphan VALUES ('must disappear on full replacement')")
            db.commit()
        source_before = inventory(repo)
        trust_before = digest(self.prefix / 'data/trusted-repos')
        sibling = registry / 'unrelated'
        sibling.mkdir()
        (sibling / 'swan.db').write_text('unrelated map sentinel')
        sibling_before = inventory(sibling)
        lock_inode = (out / 'swan.db.lock').stat().st_ino
        client = self.client(folder, registry)
        require(self.signature(client, repo) == 'generation:one', 'bad initial reader')
        self.control(generation='two')
        before = len(self.marker())
        self.map(repo, out, clean=True)
        events = self.marker()[before:]
        require(sum(e['mode'] == 'tsc' for e in events) == 1, 'clean reused cached listing')
        require(sum(e['mode'] == 'indexer' for e in events) == 2, 'clean reused chunks')
        require(not (out / 'typescript-layers.txt').read_text(), 'clean kept delta merge list')
        with closing(connect(out / 'swan.db')) as db:
            require(not db.execute("SELECT name FROM sqlite_master WHERE name='stale_orphan'").fetchall(), 'fresh database was not built')
        require(self.signature(client, repo) == 'generation:two', 'persistent reader did not reopen replacement')
        require((out / 'swan.db.lock').stat().st_ino == lock_inode, 'writer lock inode replaced')
        require(inventory(repo) == source_before and inventory(sibling) == sibling_before, 'source/unrelated map changed')
        require(digest(self.prefix / 'data/trusted-repos') == trust_before, 'saved trust changed')
        before = len(self.marker())
        self.map(repo, out)
        require(len(self.marker()) == before, 'successful clean did not publish reusable metadata')
        return 'real TS delta plan discarded; all chunks/listing rerun; fresh DB replaced; persistent reader and lock identity preserved'

    def failed_output_and_recovery(self):
        """Retain the old database on failed or missing output and force ordinary recovery."""
        folder, registry = self.context('failures')
        repo = self.repository(folder, 'mixed')
        (repo / 'probe.py').write_text('def probe(): return 1\n')
        out = registry / 'mixed'
        self.control(generation='one')
        self.map(repo, out)
        database = out / 'swan.db'
        for mode in ('fail-python', 'silent', 'flatten-fail', 'flatten-silent'):
            before = digest(database)
            self.control(mode, 'two')
            self.map(repo, out, clean=True, success=False)
            require(digest(database) == before, mode + ' replaced old database')
            require(not (out / 'index-manifest.tsv').exists() and not (out / 'python-pieces.tsv').exists(), 'failed run published reusable metadata')
            self.control(generation='one')
            start = len(self.marker())
            self.map(repo, out)
            require(any(e['mode'] == 'indexer' for e in self.marker()[start:]) and any(e['mode'] == 'python' for e in self.marker()[start:]), 'recovery reused failed output')
        self.control(generation='two')
        self.map(repo, out, clean=True)
        return 'partial indexer failure, successful no-output indexer/flattener and flatten failure preserve old DB; ordinary retry rebuilds'

    def python_pieces(self):
        """Require clean rebuild to rerun every unchanged Python piece after a reuse control."""
        folder, registry = self.context('python-pieces')
        repo = folder / 'repos/python'
        repo.mkdir(parents=True)
        for n in range(8): (repo / ('probe.py' if n == 0 else f'extra{n}.py')).write_text(f'def p{n}(): return {n}\n')
        out = registry / 'python'
        self.control(generation='one')
        self.map(repo, out)
        count = len((out / 'python-pieces.tsv').read_text().splitlines())
        require(count > 1, 'fixture did not split Python')
        before = len(self.marker())
        self.map(repo, out)
        require(not any(e['mode'] == 'python' for e in self.marker()[before:]), 'ordinary piece reuse control failed')
        self.control(generation='two')
        before = len(self.marker())
        self.map(repo, out, clean=True)
        require(sum(e['mode'] == 'python' for e in self.marker()[before:]) == count, 'clean reused Python piece')
        return f'{count} unchanged Python pieces rerun by clean'

    def malformed_rows_and_recovery(self):
        """Reject malformed rows before publication and retain empty-output compatibility."""
        folder, registry = self.context('malformed-rows')
        repo = self.repository(folder, 'rows')
        out = registry / 'rows'
        self.control(generation='one')
        self.map(repo, out)
        client = self.client(folder, registry)
        require(self.signature(client, repo) == 'generation:one', 'bad initial reader')
        cache_names = ('index-manifest.tsv', 'tsc-files.txt', 'typescript-chunks.txt',
                       'typescript-shared.txt', 'typescript-files.tsv', 'typescript-layers.txt',
                       'python-files.tsv', 'python-pieces.tsv')
        for mode in ('malformed-symbols', 'malformed-kind', 'malformed-extents', 'malformed-extents-short',
                     'malformed-occurrences', 'malformed-relationships'):
            before = digest(out / 'swan.db')
            self.control(mode, 'two')
            failed, text = client.call('update_map', {'repo': str(repo), 'build': False, 'clean': True})
            require(failed and 'malformed flattened output' in text, mode + ': ' + text)
            require(digest(out / 'swan.db') == before, mode + ' replaced old database')
            require(not any((out / name).exists() for name in cache_names), mode + ' published reusable metadata')
            require(self.signature(client, repo) == 'generation:one', mode + ' lost old reader generation')
            # The same MCP process must recover, and an ordinary retry must not
            # consider this rejected generation reusable.
            self.control(generation='one')
            start = len(self.marker())
            self.map(repo, out)
            require(any(e['mode'] == 'indexer' for e in self.marker()[start:]), mode + ' recovery reused failed output')
        self.control('empty-flatten', 'two')
        client.good('update_map', {'repo': str(repo), 'build': False, 'clean': True})
        require(not client.good('find_symbol', {'repo': str(repo), 'build': False, 'name_path_pattern': 'probe'}),
                'legitimate empty row files were not published')
        self.control('legacy-symbols', 'three')
        client.good('update_map', {'repo': str(repo), 'build': False, 'clean': True})
        require(self.signature(client, repo) == 'generation:three', 'same reader did not recover valid output')
        return 'malformed shapes/numbers/roles/flags rejected before publication; caches remain invalidated; same reader recovers; empty output stays valid'

    def target_and_mcp(self):
        """Reject invalid policy and map identity before effects, then recover on the same server."""
        folder, registry = self.context('target-policy')
        repo = self.repository(folder, 'selected')
        out = registry / 'selected'
        self.control(generation='one')
        self.map(repo, out)
        client = self.client(folder, registry)
        schema = next(t for t in client.request('tools/list', {})['result']['tools'] if t['name'] == 'update_map')
        require(schema['inputSchema']['properties']['clean']['type'] == 'boolean', 'missing clean schema')
        unknown = self.repository(folder, 'unknown')
        before = inventory(registry)
        for value in (None, 'true', 1, [], {}):
            failed, text = client.call('update_map', {'repo': str(unknown), 'clean': value})
            require(failed and 'clean must be a boolean' in text, text)
        failed, text = client.call('update_map', {'clean': True})
        require(failed and 'explicit repo' in text, text)
        failed, text = client.call('update_map', {'repo': str(unknown), 'clean': True})
        require(failed, 'clean implicitly created missing map')
        require(inventory(registry) == before, 'invalid MCP call changed registry')
        self.map(unknown, out, clean=True, success=False)
        require(inventory(registry) == before, 'wrong-root CLI changed map/cache')
        subdir = repo / 'inside'
        subdir.mkdir()
        failed, text = client.call('update_map', {'repo': str(subdir), 'build': False, 'clean': True})
        require(failed and 'exact recorded root' in text, text)
        with closing(connect(out / 'swan.db')) as db:
            db.execute("UPDATE meta SET value=? WHERE key='source'", (str(folder / 'missing-original-output'),))
            db.commit()
        moved_before = inventory(registry)
        failed, text = client.call('update_map', {'repo': str(repo), 'build': False, 'clean': True})
        require(failed and 'recorded output directory' in text, text)
        require(inventory(registry) == moved_before, 'moved-map refusal changed cache/map')
        with closing(connect(out / 'swan.db')) as db:
            db.execute("UPDATE meta SET value=? WHERE key='source'", (str(out),))
            db.commit()
        self.control(generation='two')
        client.good('update_map', {'repo': str(repo), 'build': False, 'clean': True})
        require(self.signature(client, repo) == 'generation:two', 'MCP clean failed to publish')
        before = digest(out / 'swan.db')
        self.control('flatten-silent', 'three')
        failed, text = client.call('update_map', {'repo': str(repo), 'build': False, 'clean': True})
        require(failed and 'missing flattened output' in text, text)
        require(digest(out / 'swan.db') == before, 'missing flattened output replaced database')
        require(self.signature(client, repo) == 'generation:two', 'same MCP server lost previous map after missing output')
        self.control(generation='three')
        client.good('update_map', {'repo': str(repo), 'build': False, 'clean': True})
        require(self.signature(client, repo) == 'generation:three', 'same MCP server did not recover')
        return 'strict schema/value checks precede selection; missing, ancestor, wrong-root and moved-map targets refused; exact MCP rebuild succeeds'

    def interrupted_writer(self):
        """Verify a surviving child keeps the stable writer lock after its parent is interrupted."""
        folder, registry = self.context('interruption')
        repo = self.repository(folder, 'held')
        out = registry / 'held'
        self.control(generation='one')
        self.map(repo, out)
        before = digest(out / 'swan.db')
        lock_inode = (out / 'swan.db.lock').stat().st_ino
        client = self.client(folder, registry)
        require(self.signature(client, repo) == 'generation:one', 'bad initial reader')
        self.control('hold', 'two')
        held, release = self.prefix / 'held', self.prefix / 'release'
        log = (folder / 'interrupted.log').open('wb')
        process = subprocess.Popen([str(self.binary), 'map', str(repo), str(out), '--clean'], env=self.environment,
                                   stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + self.options.timeout
            while not held.exists() and time.monotonic() < deadline:
                require(process.poll() is None, 'writer exited before child barrier')
                select.select([], [], [], .01)
            require(held.exists(), 'child barrier not reached')
            require(self.signature(client, repo) == 'generation:one', 'reader lost complete old generation during rebuild')
            # Only the launcher is interrupted: its surviving indexer owns the
            # same inherited lock and must exclude a second writer.
            process.send_signal(signal.SIGINT)
            process.wait(timeout=self.options.timeout)
            require(digest(out / 'swan.db') == before, 'interrupted writer published')
            refused = self.map(repo, out, clean=True, success=False)
            require('another writer' in refused.stdout.lower(), refused.stdout + refused.stderr)
            require((out / 'swan.db.lock').stat().st_ino == lock_inode, 'lock identity changed')
            release.write_text('release')
            # Use the real lock as the completion barrier, not an arbitrary sleep.
            import fcntl
            with (out / 'swan.db.lock').open('rb') as lock:
                while True:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        fcntl.flock(lock, fcntl.LOCK_UN)
                        break
                    except BlockingIOError:
                        require(time.monotonic() < deadline, 'child never released writer lock')
                        select.select([], [], [], .01)
            self.control(generation='two')
            self.map(repo, out, clean=True)
            require(self.signature(client, repo) == 'generation:two', 'same reader missed recovered generation')
            return 'reader retains old generation during rebuild; SIGINT child excludes competitor on stable lock; retry and reader recover after child exit'
        finally:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            process.wait(timeout=self.options.timeout)
            log.close()

    def run(self):
        """Run isolated scenarios, close clients and retain the receipt even after failures."""
        print('Artifacts: ' + str(self.directory), flush=True)
        try:
            for operation in (self.cached_layers_and_reader, self.failed_output_and_recovery,
                              self.python_pieces, self.malformed_rows_and_recovery,
                              self.target_and_mcp, self.interrupted_writer):
                try:
                    detail, status = operation(), 'PASS'
                except Exception as exc:
                    detail, status = type(exc).__name__ + ': ' + str(exc), 'FAIL'
                finally:
                    for client in self.clients: client.close()
                    self.clients.clear()
                self.results.append({'case': operation.__name__, 'status': status, 'detail': detail})
                print(status + ' ' + operation.__name__ + ': ' + detail, flush=True)
        finally: self.save()
        return all(r['status'] == 'PASS' for r in self.results)


def main():
    """Parse the explicit binary/output scope and exit nonzero if a scenario fails."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--output-parent', required=True, type=Path)
    parser.add_argument('--timeout', type=float, default=20)
    args = parser.parse_args()
    raise SystemExit(0 if CleanChecks(args).run() else 1)


if __name__ == '__main__': main()
