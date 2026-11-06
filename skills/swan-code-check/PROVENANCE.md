# swan-code-check provenance

## Source and ownership

Originally written on 2026-11-01 by Jabari (Claude Code), with a Letta/AEON
adaptation by Aya. The copies were merged into this directory on 2026-11-02
at the project owner's request. **`skills/swan-code-check/` in the Swan
repository is the single source.** Changes belong in a normal Swan PR.

On 2026-11-06 the shared instructions and self-test were made portable:
host checkout paths and named-agent trust authority were removed; executable
discovery uses an explicit binary, `SWAN_BINARY`, then `PATH`; default test
output is disposable. This supersedes the earlier host-specific setup and
`~/.cache/aya/tmp/swan-skill-selftest` default. The original 24-pattern pack,
fixture and known matcher canaries are preserved.

## Distribution

The Linux package includes this directory under its installation prefix.
It does not install a skill into agent settings or register an MCP server.
A caller can copy this whole directory to its host's supported skill
location, preserving relative paths to `scripts/`, `references/` and
`fixture/`. Keep the copy's source revision recorded in that host's own
configuration/change record and refresh it from a reviewed Swan revision.
Do not assume an agent-specific skill directory or command is present.

For validation, use the exact installed binary rather than assuming the
first `swan` on `PATH` is the same version:

```sh
/path/to/installation/bin/swan doctor --profile python-typescript --json
python3 -I /path/to/copied-skill/scripts/selftest.py --swan /path/to/installation/bin/swan
```

Doctor checks dependency availability, and the self-test checks the fixture's
pattern results. Neither proves other languages, live tools or the target
repository's map are complete. Missing dependencies or skipped indexers must
be reported. The self-test never grants repository trust or changes agent
configuration. Its default output is newly allocated and removed at exit;
`--out` or `SWAN_SELFTEST_OUT` retains a new empty directory when needed.

Run `python3 -I skills/swan-code-check/scripts/test_selftest.py` for portable
executable discovery, output handling and copied-resource checks. Run the
pattern self-test against an actual Swan binary before releasing the skill.
