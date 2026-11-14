# Install the Linux package candidate

**No release is published yet** (checked 2026-11-14): the archive and
`install.py` below come from `scripts/package.py` in a source checkout. Until a
release exists, people outside this project use the source build in the README.

This installer targets **Linux x86-64 with glibc**. Native Windows, macOS,
ARM64 and musl/Alpine are unsupported; WSL has not been qualified. Python
3.10 or later must already be available in the system tool paths. A compatible
ELF loader is also required. The installer runs an actual offline Swan test
before activating the installation; accepting the platform prerequisites
does not promise compatibility with every Linux distribution.

The package is a candidate until its exact source revision, build, installation
and runtime checks have been reviewed. It is not an automatic update to an
existing Swan. No public release, system package or agent registration is
created by these commands.

### Candidate qualification, November 6, 2026

Source `bae3873bfd8dfecae5eb5ab64bf0cf45bde9998f` was built with Goose v2026.3
and GCC 13.3 in an Ubuntu 24.04 x86-64 CUA VM (glibc 2.39). Its archive passed
a fresh `python-typescript` installation in a path containing spaces, relocation,
and dependency checks. Real SCIP maps resolved the expected definitions and
references in Python and TypeScript; live diagnostics passed clean, deliberate
type-error, and repaired-source cases. The separately copied skill passed
24/24 pattern checks. Real Pyright returned the deliberate diagnostic in all
three trust cases, with repository-interpreter execution false/true/false.

The `core` installation and offline demo also passed. Existing-prefix and
wrong-checksum installations were refused, and asking a core-only installation
for the missing Python/TypeScript profile failed its dependency check.
The local suite passed 28 installer/archive checks and 7 skill-portability
checks. See [the exact build, archive and runtime receipts](evidence/swan-package-2026-11-06.json).
These results qualify this candidate's tested profiles and environment, not
all languages, Linux distributions, or an official public release. The receipt's
source revision identifies the tested code; later documentation does not
change that artifact's identity.

## Files and profiles

The exporter produces these matching files:

- `swan-linux-x86_64.tar.gz` and its `.sha256` file.
- `install.py` and its `.sha256` file.
- `package_support.py` and its `.sha256` file; keep it beside `install.py`.

Obtain them and their reviewed checksums from the same trusted distribution.
Checksums detect changed bytes; a checksum downloaded from an untrusted party
does not independently authenticate that party.

| Profile | Included behavior | Additional requirements |
|---|---|---|
| `core` | Swan executable, existing-map queries/MCP, structural helpers, offline demo and skill | System Python for installer/doctor; real repository mapping needs indexers |
| `python-typescript` (default) | Core plus Python and TypeScript/JavaScript SCIP indexing, Pyright, TypeScript language server and Biome | Python, Node/npm, Bun and the existing locked npm tools |

Compatible Node/npm and Bun in the trusted system paths are reused. Otherwise
the selected profile downloads pinned Linux runtimes into the new Swan folder,
with verified SHA-256 checksums. The npm tools use the checked-in lockfile and
`npm ci --ignore-scripts`. Bun is a **mapping runtime** dependency, not only
a test runner. Python is a system prerequisite; this installer does not install
it or run sudo. Large Rust, JDK/Kotlin, .NET, CUDA and game/shader toolchains,
and Python ruff/pytest, are unselected by these profiles. Existing advanced
adapter setup remains separate and requires its own qualification.

## Preview, then install into a new folder

Run these commands in the directory containing the downloaded files. Choose
a new directory whose parent already exists. The example is intentionally
different from an existing `~/aya` installation:

```bash
sha256sum -c install.py.sha256 package_support.py.sha256 swan-linux-x86_64.tar.gz.sha256
swan_archive_hash=$(cut -d ' ' -f 1 swan-linux-x86_64.tar.gz.sha256)
python3 -I install.py --archive swan-linux-x86_64.tar.gz \
  --sha256 "$swan_archive_hash" --prefix "$HOME/swan-candidate" \
  --profile python-typescript --dry-run
```

The preview reads the archive and runs bounded version probes on trusted
system tools. It performs no downloads or filesystem writes and never
inspects a repository's `.venv`. It reports the destination, selected tools
and downloads. To apply that operation, repeat the command without `--dry-run`:

```bash
python3 -I install.py --archive swan-linux-x86_64.tar.gz \
  --sha256 "$swan_archive_hash" --prefix "$HOME/swan-candidate" \
  --profile python-typescript
"$HOME/swan-candidate/bin/swan" doctor --profile python-typescript --json
```

An existing destination, even an empty directory, is refused. The installer
uses sibling staging, verifies dependencies and the offline demo, and activates
with a no-overwrite rename. Failure before activation removes only its own
staging directory. No PATH file, shell startup file, saved trust list, map,
MCP configuration or installed agent skill is changed. Keep the whole installed
tree together; copying only `bin/swan` loses its tools and resources.

`swan doctor` is read-only. Exit zero means the selected dependency/version
checks passed, **not** that arbitrary repositories have been correctly indexed.
Exit nonzero names missing, incompatible or unsupported requirements. Optional
unselected adapters do not fail the selected profile. The executable diagnoses
its own installation; `--home` is not a public Swan CLI override.

## Connect an agent and use the included skill

The candidate includes `skills/swan-code-check/`, its known-answer fixture and
pattern pack. Copy that whole directory to the chosen agent's supported skill
directory only when its owner wants it installed. Preserve any locally edited
copy before replacing it. Agent-specific skill directories and MCP settings
vary; this installer changes none of them.

Configure the agent's Swan MCP command with the **absolute** installed binary
path and arguments `serve --maps <absolute-writable-map-directory>`. Do not
copy someone else's maps or trust list. A shell can use the same exact binary;
an optional PATH link must point to it without separating it from its tree.

Test a copied skill against the selected installation:

```bash
python3 -I /path/to/copied/swan-code-check/scripts/selftest.py \
  --swan "$HOME/swan-candidate/bin/swan"
```

Expected: `24/24 patterns match the fixture exactly`. Output is disposable by
default; `--out /new/output/directory` retains it. The test must run real mapping
and search. Its pattern matches do not qualify all index semantics or all
language servers. `SWAN_BINARY` or a resolved `swan` on PATH can also select the
executable when no explicit `--swan` is supplied.

The portable skill preserves explicit repository selection, map freshness and
mutation authorization. It never grants trust automatically. Installing Swan
or its skill does not authorize running an arbitrary repository's build/test
code. Keep the process-wide `SWAN_TRUST_BUILD=1` override out of normal sessions.
The saved-trust-list concurrency exception remains: serialize grants and
never restore a test snapshot over another process's changes.

## Verification and rollback

The candidate exporter includes `scripts/demo-offline.py` and
`scripts/verify-live-trust.py`. The latter requires Bubblewrap, Node and system
Python and creates a separate copied runtime. Use `--bwrap`/`--node` for explicit
trusted paths and an output parent outside the installed prefix. It requires
real successful Pyright diagnostics and interpreter markers false/true/false;
missing prerequisites are an error, never a skipped pass. See its `--help`
before running it. No saved trust grant is needed for its process-only control.

This first installer supports **new installations only**. Keep an active old
installation and its configuration intact while testing a candidate. Switching
an agent to the new absolute executable is a separate explicit configuration
change; rollback is switching that agent back to its old path and restarting
its Swan session. Do not replace an old executable or move its data as an
implicit upgrade. Once disconnected and no longer needed, remove only the
identified new prefix and its separately created test outputs. Preserve user
maps and trust decisions rather than restoring snapshots wholesale.

## Build/export for maintainers

Build in a clean checkout with initialized submodules and a private
`GOOSE_HOME`. `scripts/build.sh` remains the source-build entry point; it
overwrites that checkout's `bin/swan`, so never use a live installation as the
build directory. The SQLite dependency is pinned to a commit with the GCC 13
header correction, and Swan includes its own required Boolean header.

Record a JSON build receipt containing the full `source_revision` and
`binary_sha256`, plus the actual compiler/tool versions and commands. Collect
the original license notices for the Goose runtime, goose-sqlite,
goose-treesitter and each compiled grammar/runtime, and goose-lsp.

```bash
python3 scripts/package.py --binary bin/swan --output /new/export-directory \
  --source-revision FULL_COMMIT_SHA --build-receipt /path/to/build-receipt.json \
  --licenses /path/to/collected-licenses --require-license Goose-LICENSE
```

The exporter requires a clean tracked checkout matching the receipt and hashes
the exact binary and packaged files. It omits installed dependencies, caches,
maps and trust state. The receipt is the builder's attestation, not independent
proof of compilation. Exporting does not publish a release. Qualify the archive
with a fresh installation, real selected-language map/reference/diagnostics
checks, Python trust controls, copied-skill tests and independent review before
claiming the package is ready for distribution.
