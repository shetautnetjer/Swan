#!/usr/bin/env python3
"""Bounded, disposable PR #11 regression check. Never edits a saved trust list.

Copies an existing Swan executable and its Pyright. Uses Bubblewrap to make
the host filesystem read-only, except the new lab directory, with no network.
The trusted control sets SWAN_TRUST_BUILD=1 only inside its test process.
No build, package installation, production restart, or production map occurs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import subprocess
import tempfile
import time


def digest(path):
    """Hash a file for before/after comparison, or return None when absent."""
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def main():
    """Parse command-line options and return or report the operation status."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output-parent', type=Path, required=True)
    parser.add_argument('--bwrap', type=Path, default=Path('/usr/bin/bwrap'))
    parser.add_argument('--node', type=Path, default=Path('/usr/bin/node'))
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error('Run as the ordinary Swan owner, never root.')
    try:
        original = args.binary.resolve(strict=True)
        parent = args.output_parent.resolve(strict=True)
        bwrap = args.bwrap.resolve(strict=True)
        node = args.node.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        parser.error(str(error))
    source_home = original.parent.parent
    if parent == source_home or source_home in parent.parents:
        parser.error('Put the disposable lab outside the installed Swan tree.')
    for executable in [str(bwrap), str(node), '/usr/bin/python3']:
        if not os.access(executable, os.X_OK):
            parser.error('Required executable missing: ' + executable)
    pyright = source_home / 'tools/node_modules/pyright'
    modules = source_home / 'tools/modules.json'
    if not (pyright / 'langserver.index.js').is_file() or not modules.is_file():
        parser.error('Installed Pyright or modules.json missing; do not count a skip as a pass.')
    if original.parent.name != 'bin':
        parser.error('Expected a real executable in a Swan bin/ directory.')
    trust = source_home / 'data/trusted-repos'
    before = {'binary': digest(original), 'trust': digest(trust), 'modules': digest(modules)}
    lab = Path(tempfile.mkdtemp(prefix='swan-verify-', dir=parent)).resolve()
    os.chmod(lab, 0o700)
    print('LAB=' + str(lab), flush=True)
    home = lab / 'swan'
    (home / 'bin').mkdir(parents=True)
    (home / 'data').mkdir()
    (home / 'tools/node_modules/.bin').mkdir(parents=True)
    binary = home / 'bin/swan'
    shutil.copy2(original, binary)  # A real copy, not a symlink or hard link.
    shutil.copy2(modules, home / 'tools/modules.json')
    shutil.copytree(pyright, home / 'tools/node_modules/pyright', symlinks=False)
    (home / 'tools/node_modules/.bin/pyright-langserver').symlink_to('../pyright/langserver.index.js')
    (lab / 'backup').mkdir()
    if trust.exists():
        shutil.copy2(trust, lab / 'backup/production-trusted-repos.snapshot')
    assert digest(binary) == before['binary'], 'Binary changed during copying; stop and retry later.'
    assert not (home / 'data/trusted-repos').exists()
    provenance = {'source_binary': str(original), 'source_home': str(source_home),
                  'before': before, 'copy_sha256': digest(binary),
                  'pyright_version': json.loads((pyright / 'package.json').read_text())['version'],
                  'bwrap': str(bwrap), 'node': str(node),
                  'input': 'synthetic TSV rows, not SCIP-indexer output',
                  'isolation': 'host read-only; only lab writable; network namespace disabled',
                  'trusted_control': 'process-local SWAN_TRUST_BUILD=1; no saved trust grants'}
    (lab / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')

    def command(argv, trusted=False):
        """Build a read-only, network-isolated sandbox command with process-local trust control."""
        cmd = [str(bwrap), '--die-with-parent', '--new-session',
               '--unshare-pid', '--unshare-ipc', '--unshare-net',
               '--ro-bind', '/', '/', '--bind', str(lab), str(lab),
               '--proc', '/proc', '--dev', '/dev', '--chdir', str(lab),
               '--clearenv', '--setenv', 'PATH', str(node.parent) + ':/usr/bin:/bin',
               '--setenv', 'LANG', 'C.UTF-8',
               '--setenv', 'PYTHONDONTWRITEBYTECODE', '1',
               '--setenv', 'PYTHONNOUSERSITE', '1']
        if trusted:
            cmd += ['--setenv', 'SWAN_TRUST_BUILD', '1']
        return cmd + ['--'] + list(map(str, argv))

    def bounded(argv, label):
        """Run a sandbox setup command with a deadline and retain its diagnostic log."""
        result = subprocess.run(command(argv), capture_output=True, timeout=30)
        (lab / (label + '.log')).write_bytes(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError(label + ' failed; see its log. Do not retry without isolation.')

    report = {'status': 'INCONCLUSIVE', 'cases': []}
    try:
        bounded(['/usr/bin/true'], 'sandbox-preflight')
        repo = lab / 'repo'
        repo.mkdir()
        (repo / 'main.py').write_text('answer: int = "SWAN_TRUST_PROBE"\n')
        rows = lab / 'rows'
        rows.mkdir()
        symbol = 'scip-python python swan-trust-probe 0.0.0 main/answer.'
        (rows / 'symbols.tsv').write_text(symbol + '\tanswer\t13\t\tanswer: int\n')
        (rows / 'extents.tsv').write_text(symbol + '\tmain.py\t0\t0\t0\t31\n')
        (rows / 'occurrences.tsv').write_text(symbol + '\tmain.py\t0\t0\t0\t6\tdef\n')
        (rows / 'relationships.tsv').write_text('')
        db = lab / 'swan.db'
        bounded([binary, 'index', rows, db, repo], 'index')
        # Plant only after map construction, so any marker comes from live mode.
        marker = lab / 'repo-python-ran'
        venv = repo / '.venv'
        (venv / 'bin').mkdir(parents=True)
        (venv / 'pyvenv.cfg').write_text('home = /usr/bin\n')
        fake = '#!/bin/sh\nprintf "ran\\n" >> ' + shlex.quote(str(marker)) + '\nexec /usr/bin/python3 "$@"\n'
        for name in ['python', 'python3', 'pip']:
            path = venv / 'bin' / name
            path.write_text(fake)
            path.chmod(0o755)

        def live_case(label, trusted):
            """Require real Pyright diagnostics and record whether this trust case ran the planted interpreter."""
            marker.unlink(missing_ok=True)
            transcript = []
            stderr = (lab / (label + '.stderr.log')).open('wb')
            process = subprocess.Popen(command([binary, 'serve', db], trusted),
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=stderr, start_new_session=True)
            buffer = b''
            def send(message):
                """Send one JSON-RPC message and retain it in the evidence transcript."""
                process.stdin.write(json.dumps(message).encode() + b'\n')
                process.stdin.flush()
                transcript.append({'sent': message})
            def request(ident, method, params):
                """Wait for the matching JSON-RPC result within the deadline; errors never count as passes."""
                nonlocal buffer
                send({'jsonrpc': '2.0', 'id': ident, 'method': method, 'params': params})
                deadline = time.monotonic() + 45
                while True:
                    while b'\n' not in buffer:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0 or not select.select([process.stdout], [], [], remaining)[0]:
                            raise RuntimeError(label + ': timed out; this is not a pass')
                        chunk = os.read(process.stdout.fileno(), 65536)
                        if not chunk:
                            raise RuntimeError(label + ': server exited before replying')
                        buffer += chunk
                    line, buffer = buffer.split(b'\n', 1)
                    answer = json.loads(line)
                    transcript.append({'received': answer})
                    if answer.get('id') == ident:
                        if 'error' in answer:
                            raise RuntimeError(label + ': JSON-RPC error')
                        return answer['result']
                    if time.monotonic() >= deadline:
                        raise RuntimeError(label + ': reply deadline exceeded')
            try:
                init = request(1, 'initialize', {'protocolVersion': '2025-06-18',
                               'capabilities': {}, 'clientInfo': {'name': 'trust-verification', 'version': '1'}})
                if init.get('serverInfo', {}).get('name') != 'swan':
                    raise RuntimeError('Unexpected MCP server')
                send({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
                result = request(2, 'tools/call', {'name': 'get_diagnostics',
                                 'arguments': {'relative_path': 'main.py', 'live': True}})
                if result.get('isError'):
                    raise RuntimeError(label + ': diagnostics tool returned an error')
                payload = json.loads(result['content'][0]['text'])
                if payload.get('ok') is not True:
                    raise RuntimeError(label + ': language server did not report success')
                # A deliberately wrong annotation must produce a real type error.
                text = json.dumps(payload)
                if 'reportAssignmentType' not in text:
                    raise RuntimeError(label + ': deliberate type error missing; inconclusive')
            finally:
                process.stdin.close()
                try:
                    status = process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
                    raise RuntimeError(label + ': server shutdown timed out')
                finally:
                    stderr.close()
                    (lab / (label + '.json')).write_text(json.dumps(transcript, indent=2) + '\n')
                if status != 0:
                    raise RuntimeError(label + ': server exited nonzero: ' + str(status))
            ran = marker.exists()
            if ran:
                shutil.copy2(marker, lab / (label + '.marker'))
            report['cases'].append({'case': label, 'diagnostics': 'reportAssignmentType',
                                    'repo_interpreter_executed': ran, 'expected': trusted})
            return ran == trusted

        outcomes = [live_case('untrusted-before', False),
                    live_case('trusted-control', True),
                    live_case('untrusted-after', False)]
        report['status'] = 'PASS' if all(outcomes) else 'FAIL'
    except Exception as exc:
        report['error'] = str(exc)
    finally:
        report['after'] = {'binary': digest(original), 'trust': digest(trust), 'modules': digest(modules)}
        report['production_unchanged'] = before == report['after']
        report['isolated_trust_list_absent'] = not (home / 'data/trusted-repos').exists()
        if not report['production_unchanged'] or not report['isolated_trust_list_absent']:
            report['status'] = 'INCONCLUSIVE'
            report['warning'] = 'State changed. Investigate; never restore a saved trust list automatically.'
        (lab / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2), flush=True)
        print('Evidence retained at ' + str(lab), flush=True)
    return {'PASS': 0, 'FAIL': 1, 'INCONCLUSIVE': 2}[report['status']]


if __name__ == '__main__':
    raise SystemExit(main())
