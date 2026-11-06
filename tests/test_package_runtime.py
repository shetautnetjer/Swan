#!/usr/bin/env python3
"""Bounded real Python/TypeScript indexing and diagnostics on an installed Swan.

Creates only disposable fixtures/maps below --output-parent. No trust grants,
repository code execution, source rebuild, or agent configuration changes.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile


def digest(path):
    """Hash a file for before/after comparison, or return None when absent."""
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None


def main():
    """Qualify real Python and TypeScript maps and live diagnostics using disposable repositories."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, required=True)
    parser.add_argument('--output-parent', type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    home = binary.parent.parent
    folder = Path(tempfile.mkdtemp(prefix='swan-package-smoke-', dir=args.output_parent)).resolve()
    trust = home / 'data/trusted-repos'
    original = digest(trust)
    # Use the package's own bounded stdio client rather than a second protocol.
    spec = importlib.util.spec_from_file_location('swan_demo', home / 'scripts/demo-offline.py')
    demo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(demo)
    result = {'status': 'FAIL', 'binary_sha256': digest(binary), 'cases': []}
    languages = {
        'python': ('maths.py', 'def square(x: int) -> int:\n    return x * x\n\ndef area(side: int) -> int:\n    return square(side)\n',
                   'broken: int = "SWAN_PACKAGE_PROBE"\n', 'reportAssignmentType'),
        'typescript': ('maths.ts', 'export function square(x: number): number {\n    return x * x;\n}\nexport function area(side: number): number {\n    return square(side);\n}\n',
                       'export const broken: number = "SWAN_PACKAGE_PROBE";\n', '2322'),
    }
    try:
        for language, (filename, source, broken, code) in languages.items():
            case = folder / language
            repo = case / 'repository with spaces'
            repo.mkdir(parents=True)
            source_file = repo / filename
            source_file.write_text(source)
            if language == 'typescript':
                (repo / 'tsconfig.json').write_text(json.dumps({'compilerOptions': {
                    'strict': True, 'target': 'ES2022', 'module': 'commonjs'}, 'include': ['*.ts']}))
                (repo / 'package.json').write_text('{"name":"swan-package-probe","version":"1.0.0"}\n')
            mapping = subprocess.run([str(binary), 'map', str(repo), str(case / 'map')],
                                     capture_output=True, text=True, timeout=90)
            (case / 'map.log').write_text(mapping.stdout + mapping.stderr)
            if mapping.returncode:
                raise RuntimeError(language + ': real mapping failed')
            client = demo.MCP(binary, case / 'map/swan.db', case)
            try:
                init = client.request('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                    'clientInfo': {'name': 'installed-package-check', 'version': '1'}})
                assert init['result']['serverInfo']['name'] == 'swan'
                client.notify('notifications/initialized')
                found = client.tool('find_symbol', {'name_path_pattern': '/square', 'include_body': True})
                assert len(found) == 1 and found[0]['relative_path'] == filename and found[0]['line'] == 1, found
                assert 'return x * x' in found[0]['body'], found
                refs = client.tool('find_referencing_symbols', {'name_path': '/square'})
                assert len(refs) == 1, refs
                assert any(x['relative_path'] == filename and x['in_symbol'] == 'area'
                           and x['line'] == 5 for x in refs[0]['references']), refs
                clean = client.tool('get_diagnostics', {'relative_path': filename, 'live': True})
                assert clean.get('ok') is True and not any(d['severity'] == 'error' for d in clean['diagnostics']), clean
                source_file.write_text(source + broken)
                bad = client.tool('get_diagnostics', {'relative_path': filename, 'live': True})
                assert bad.get('ok') is True and any(str(d.get('code')) == code and d['severity'] == 'error'
                                                   for d in bad['diagnostics']), bad
                source_file.write_text(source)
                fixed = client.tool('get_diagnostics', {'relative_path': filename, 'live': True})
                assert fixed.get('ok') is True and not any(d['severity'] == 'error' for d in fixed['diagnostics']), fixed
                result['cases'].append({'language': language, 'real_index': True, 'definition_and_reference': True,
                                        'live_clean_error_fixed': True, 'diagnostic_code': code})
            finally:
                (case / 'mcp-transcript.json').write_text(json.dumps(client.transcript, indent=2) + '\n')
                try:
                    client.close()
                finally:
                    if client.process.poll() is None:
                        client.process.kill()
                        client.process.wait(timeout=5)
                if client.process.returncode != 0:
                    raise RuntimeError(language + ': server shutdown failed')
        result['status'] = 'PASS'
    except Exception as error:
        result['error'] = str(error)
    finally:
        result['trust_unchanged'] = digest(trust) == original
        if not result['trust_unchanged']:
            result['status'] = 'FAIL'
        (folder / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, indent=2))
        print('Evidence: ' + str(folder))
    return 0 if result['status'] == 'PASS' else 1


if __name__ == '__main__':
    # Explicit process-only cleanup; this never grants repository trust.
    for variable in ('SWAN_TRUST_BUILD', 'VIRTUAL_ENV', 'PYTHONPATH', 'PYTHONHOME', 'NODE_OPTIONS'):
        os.environ.pop(variable, None)
    raise SystemExit(main())
