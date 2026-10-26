# Offline demo

After building Swan, run this from the checkout:

```bash
python3 scripts/demo-offline.py
```

The demo needs an already-built `bin/swan` and Python 3. It does not fetch
packages, start an indexer or language server, or require Bun, an SDK, or a
network connection. To use another built binary:

```bash
python3 scripts/demo-offline.py --binary /absolute/path/to/swan
```

It creates a new directory under `data/demo-offline-*` on every run. No
existing project is edited and no previous demo output is deleted. Use
`--output-parent /path/to/output` to choose a different parent directory.

The generated TypeScript file has two functions, `square` and `area`.
Alongside it, the script writes **synthetic flattened SCIP rows** with known
definition and reference positions. These are deliberately hand-authored:
the demo checks Swan's consumer boundary, not whether an external SCIP
indexer understands TypeScript correctly.

The script builds a real SQLite map with `swan index`, then drives
`swan serve` over MCP stdio and checks:

- initialization and the advertised tools;
- a definition and its source body, and the reference to it inside `area`;
- the direct user in Swan's reference graph;
- a tree-sitter match with repeated `$X`, its capture, and enclosing symbol;
- a pattern with no matches;
- rewrite planning that leaves the source intact;
- explicit apply that changes only the planned expression;
- refusal after an outside edit, with no additional source change;
- the JSON-RPC error for an unknown method.

Every check must pass for exit status 0. Each MCP request has a 15-second
deadline. The output directory retains the source, row files, database,
input provenance, index log, MCP request/response transcript, and server
stderr for review, including when a check fails after the server starts.

This is a small, reproducible demonstration of the map, MCP, and structural
rewrite path. It does not establish precise call-graph semantics, broad
language coverage, live diagnostics, compiler/indexer correctness, or
JetBrains feature parity. Those require the relevant integration suites and
real external tools described elsewhere in this repository.
