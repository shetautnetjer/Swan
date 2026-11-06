# Per-request map build policy

An agent may need to identify the repository on every call without allowing
automatic indexing. Previously only `use_repo` honored `build:false`;
ordinary tools carrying `repo` unconditionally permitted a build when no
usable map was found. Selecting a map once did not constrain the next call.

Every advertised repository-selecting tool now accepts optional boolean
`build`. The shared request handler validates it before selection, reopening,
live warm-up or tool dispatch:

| Supplied value | Selection behavior |
|---|---|
| Omitted or `true` | Existing first-use behavior: building is allowed |
| `false` | Select an existing usable covering map; otherwise return an error |
| Null, string, number, array or object | Return `build must be a boolean` before selection/tool effects |

For example, after checking that the installed `find_symbol` schema advertises
the property:

```json
{"name":"find_symbol","arguments":{"repo":"/absolute/worktree","build":false,"name_path_pattern":"probe"}}
```

Apply the policy on **each** request. It is not a persistent server setting.
Malformed supplied values also fail on `use_repo` and calls without `repo`.
The existing MCP tool error envelope is retained.

## Scope and compatibility

The policy prevents implicit map creation/rebuilding, not every action that
can write or execute code. Explicit `update_map`, checkers, tests, live
servers, formatting and edit/apply commands retain their existing effects
and require their own authorization. An inherited `SWAN_WARM` can start a
language server; a controlled review launcher should leave it unset/empty
when startup is not authorized. Existing database opens remain read/write,
including SQLite's possible journal recovery; this is not storage read-only.

Root selection is unchanged. An existing usable ancestor or same-root map
can still be chosen. A locked entry that could hide a nearer root still
causes explicit refusal. The policy does not pin one map among duplicates.
For exact identity, use the documented sole-map private registry and verify
the returned root/map, or use the exact database CLI.

Older servers may ignore an unknown `build` field, and the server version
alone does not establish support. Inspect the actual tool schema. For a
legacy server, use an exact database CLI query, or a controlled persistent
session selected with `use_repo(build:false)` and no subsequent `repo`
reselection. Stateless wrappers cannot inherit that selection: route through
the exact database or use a server that supports the request policy.

No database schema, package pin, writer-lock lifetime, snapshot contract,
saved trust or production configuration is changed. See the canonical
[skill](../skills/swan-code-check/SKILL.md) for agent routing and the
[concurrency contract](concurrency.md) for contention/restart behavior.

## Qualification

`tests/test_request_build_policy.py` exercises the exact staged executable
in a disposable installation with synthetic maps and marker tools. A
positive build control must actually invoke those tools; blocked requests
must leave their markers and map artifacts unchanged. It retains schemas,
transcripts and results and bounds child/RPC execution.

```sh
python3 tests/test_request_build_policy.py --binary /absolute/staged/bin/swan --output-parent /absolute/disposable-output --timeout 15
```

This synthetic selection test does not qualify arbitrary external indexers,
other platforms or the separate full-pipeline cache-recovery behavior.
Recorded candidate results belong in the accompanying evidence receipt;
source integration does not update an installed executable.

The [November 6 receipt](evidence/swan-request-build-policy-2026-11-06.json)
records nine passing policy groups on binary `e1411825…` from implementation
`e0a22796`. The old binary fails six policy groups while both authorized-build
controls and the preserved locked-map refusal pass. The candidate also passes
13 native lock tests, five reader cases and nine concurrency scenarios.
