# Where an agent still cannot see: gaps measured on 2026-11-20

The owner asked where Swan leaves an agent blind: what keeps it from seeing a
repo's bugs and errors as an IDE would, without filling its context, so it can
fix code, place new code, and know what an edit touches. He asked for one next
experiment.

There is no "drex" command and no service token in this session, and
"pstack" and a "superpowers" plugin were not available either. Jev was
used, as the owner then asked, through Composio: it is TypeSafe's judging
model (jev-1.14.0), and it judged this report's evidence and choices (last
section). The measurements use Swan itself, with Graphify and ripgrep, on
flask (`49943b5a9441`, 217 files), requests (`3c7baaa05ab4`) and pytest
(`9efd0121a439`). The Swan program is the Goose build of main's `src/`
(`049fd7c`). Pyright is 1.1.414.

## What is now known, worst first

### 1. Without the repo's packages, most of the problems the agent sees are false, and some real ones are hidden

`swan map` then `swan check` on flask took 16 s and 6 s. Pyright reported
**203 errors**. Flask's six dependencies (blinker, click, itsdangerous,
jinja2, markupsafe, werkzeug) and pytest were then put in a scratch
virtualenv, from wheels only, so no package's install code ran and nothing of
flask ran. Pyright was then run as `swan check` runs it, pointed at that
interpreter. It reported **111 errors**.

| | errors |
| --- | --- |
| Without the packages (what Swan showed on this machine, whose `python3` had four of the six) | 203 |
| With them | 111 |
| False: gone once the packages are there (82 unresolved imports, 22 unknown attributes, 16 others) | **120 of 203 (59%)** |
| Hidden: only seen once the packages are there (15 wrong argument types, 4 unchecked `None`, 5 overrides that do not fit werkzeug's classes, 4 imports of optional packages) | **28 of 111 (25%)** |
| The same either way | 83 |

Five of the hidden ones are in flask's own source. One is `Flask.response_class`
(`src/flask/app.py:243`), which overrides the attribute of the same name in
the base class with a type that does not fit. Pyright could not see that while
the base class's package was missing. The 4 optional imports are of
python-dotenv and cryptography, which flask's extras name.

So an agent asking "what is broken here?" gets an answer that is mostly
wrong, and that misses a quarter of the true answer. This is the owner's
point about the environment, with a number on it.

Two more repos, each run twice: with an empty interpreter (a fresh machine)
and with one that holds only the packages the repo declares.

| Repo (pyright mode) | Errors, nothing installed | Errors, declared packages | False | Hidden |
| --- | --- | --- | --- | --- |
| flask (basic) | 261 | 111 | 184 (70%) | 34 |
| requests (strict) | 166 | 11 | 155 (93%) | 0 |
| pytest (basic, with its `dev` extras) | 298 | 319 | 1 | 22 |

The harm differs by repo, but all three mislead. Requests' strict settings
turn every unknown type into an error, so a missing package floods the
list. In pytest the missing packages mostly hide errors. 20 of its 22
hidden errors are general type errors.

The machine decides the answer, too. With no virtualenv, Swan falls back to
the machine's `python3`. On this machine that interpreter's user
site-packages already held all of requests' packages, and four of flask's
six (click, jinja2, markupsafe, blinker). So `swan check` showed 11 errors
for requests here and would show 166 on a clean machine. For flask it
showed 203 here (the first table) and would show 261. The same repo and
the same Swan give different answers on different machines.

The errors an agent hears about after an edit have the same hole. Two
breaking edits were made to flask's `src/flask/helpers.py`, then `swan
broke` (the `what_broke` tool) was asked. It reported the flask call with a
missing argument, in 1.3 s, and left out the 7 false errors already in the
file. It said nothing about `secure_filename(5)`, a number passed to a
werkzeug function that takes text. Pyright reports both once werkzeug is
installed. An agent that misuses a library gets no warning.

Swan already reads a repo's own `.venv` when it has one, for the map. But
`swan check` drops it unless the repo is trusted (`src/checkers.goose`:
running the repo's interpreter is running its code). A fresh clone has no
`.venv` at all. Swan never makes one, because AGENTS.md rule 1 keeps package
managers off a repo nobody trusted. The skill tells agents to beware answers
from a project "whose dependencies are not installed". The answer itself
does not say which errors that explains.

### 2. The problems list does not fit in a context

The whole-repo `get_diagnostics` answer for flask is 53,913 bytes, about 13,500
tokens, for 206 rows. It has no summary and no grouping. An agent needs the
shape first: how many, of which kinds, where, and how many come from the
environment. A summary of that would be about 1 KB. The other answers are
small when asked narrowly: `get_callers` of `Flask.make_response` is 3,987
bytes and `get_callees` 2,956.

### 3. `swan doctor` and `swan map` disagree about what is installed

`swan doctor` says node is missing, so scip-python, scip-typescript, pyright,
typescript-language-server and biome are "missing" too. It looks only in
`/usr/local/bin`, `/usr/bin` and `/bin`. Then `swan map` used node from
`PATH` (`/opt/node22/bin`) and ran scip-python on all four Python projects.
An agent that believes the doctor would think it cannot map Python here.

### 4. Schemas and other non-code files are not in the map

The 17 grammars are code (TypeScript, TSX, JavaScript, Python, Rust, Java,
Kotlin, C, C++, CUDA, C#, PHP, Lua, GDScript, GLSL, HLSL, WGSL). None covers
SQL, migrations, YAML, JSON or JSON Schema, TOML, protobuf, GraphQL, OpenAPI
or templates. "What reads this table's column, this config key, this API
field?" has no answer beyond text search and `search_pattern` on the code
side (`$C.config[$K]`).

### 5. Small: signatures that start with `undefined`

36 of flask's 4,481 symbols have a signature such as
`undefined = t.TypeVar("T_teardown", ...)`, all module-level type
variables. This comes from scip-python and Swan passes it through.

## The next experiment: sealed dependencies

**What it is.** When a repo's packages are not installed, Swan installs them
itself, into the map folder, never into the repo. It installs only what the
repo declares, and nothing it installs may run code: Python wheels only (no
source distributions, which run `setup.py`), and npm with `--ignore-scripts`.
The language servers and `swan check` then see the libraries. Everything
Swan could not set up (a package with no wheel, a private registry, a
missing lockfile) is listed in the map's report. That is the owner's "spell
out areas it didn't touch".

**Pass criteria, written before building.**

1. flask, from a clean interpreter: of the 184 false errors, at most 5
   remain, each named in the report as a package not set up (the docs-only
   `pallets_sphinx_themes` is expected). The 34 hidden ones appear (the
   optional imports only if the extras are set up). The 77 others are
   unchanged. requests and pytest meet the same three numbers from their
   tables.
2. One TypeScript repo (express or shadcn-ui, from those already cloned):
   its errors are counted with and without the packages before anything is
   built, and the same three numbers are met.
3. No code runs: a made-up repo depending on a package that has only a
   source distribution, and on an npm package with an install script. The
   first is skipped and named; the second's script does not run. That check
   is seen failing on Swan from before the change (rule 4).
4. Nothing is written into the repo: `git status` clean after map and check.
5. Time and disk are recorded. The map of flask may not more than double
   (16 s now), and the cached packages are counted separately.
6. The answer no longer depends on the machine: the same errors with and
   without packages in the machine's own `python3`.

**What it needs from the owner.** Rule 1 says no package manager runs on a
repo nobody trusted. This experiment runs Swan's own uv or npm, on the
package list the repo declares, into the map folder, with code execution
turned off. Whether that is inside the rule, or needs trust like a build
does, is the owner's call, before anything is built.

**Why this one first.** It is the gap that makes the other answers wrong.
A summary of the problems list (gap 2) is worth building right after, but
summarising a list that is 59 to 93% false would only make the wrong answer
shorter. Gaps 3 and 5 are small fixes. Gap 4 is large and is better aimed
once the errors are true.

## What runs, and what trust is for

The owner asked whether running Swan runs a repo's code. Searching and
indexing do not. Tree-sitter, scip-python, scip-typescript and pyright read
files. What runs a repo's code is a short list, and it is what `swan trust`
gates (`tools/modules.json` marks it `runs_repo_code`, and
`src/pipeline.goose`'s `build_trusted` checks it):
- Rust's build scripts and macros, through rust-analyzer and `cargo
  clippy`. The map already runs them sealed without trust, offline.
- Gradle, Maven and MSBuild builds, and the Java, Kotlin, C# and Go
  servers that run them.
- The repo's own `.venv` interpreter.
- Tests (`run_tests`), which run the repo's code by design.

All of them run inside Swan's seal (`src/seal.goose`): no writes outside
the map folder, and no network. Trust only loosens the seal, giving the
network and write access to the repo and its build caches. None of the
accuracy lost above comes from this list. It comes from packages that
are not there, and getting packages needs none of the repo's code.

One way code would run, found by testing. A `.pth` file in an installed
Python package runs when an interpreter starts, and `swan check` starts
one, because it gives pyright `--pythonpath`. With a made-up package
holding such a file, `--pythonpath` reported the package's type error and
the file ran. Given the same package as a folder (pyright's
`extraPaths`), pyright reported the same error and nothing ran. So sealed
dependencies hands the language tools the packages' folders and never
starts an interpreter on them. A TypeScript language server can likewise
load plugins that a `tsconfig.json` names from `node_modules`, which is
the same kind of check for step 2.

## How it was measured

- `bin/swan map <flask> <map>`, `bin/swan check <flask> <map>`, then the
  `diagnostics` table of `swan.db`, grouped by pyright's rule.
- `uv venv`, then
  `uv pip install --only-binary :all: blinker click itsdangerous jinja2 markupsafe werkzeug pytest`
  (versions as flask's `pyproject.toml` asks). Then, from the flask folder,
  `pyright --outputjson --pythonpath <venv>/bin/python`. That is how `swan
  check` runs pyright (`src/checkers.goose`), with the interpreter changed.
- Errors were compared by file, 0-based line and rule. The map stores
  pyright's 0-based lines, and the answers add one.
- requests and pytest, and flask's clean row: the same pyright run, once
  with an empty `uv venv` and once with one holding the declared packages
  (pytest's with its `dev` extras too), wheels only.
- The edit test: two functions appended to `src/flask/helpers.py`, `swan
  broke` asked before and after, the file put back with `git checkout`.
- Answer sizes are the byte counts of `swan query <db> diag ""`,
  `callers Flask/make_response` and `callees Flask/make_response`.

## Checked with Jev

Jev (jev-1.14.0, through Composio, about 2,900 tokens over two calls) was
given the measurements as they stood and asked to judge them. Its answers
are evidence, not a decision.

| Question | Before requests, pytest and the edit test | After |
| --- | --- | --- |
| How well do the numbers support the claim? | "Moderate: one repo, clear numbers" (2 of 4) | "Strong: several repos, one language" (2.95 of 4) |
| Which experiment next? | sealed dependencies, 0.99 | still first, 0.6 |
| How good are the pass criteria? | 3.76 of 4 | not asked again |
| Is it inside rule 1? | inside 0.66, needs trust 0.25, the owner must decide 0.09 | not asked again |
| What does the analysis most likely miss? | the edit loop 0.49, errors at run time 0.28 | TypeScript not measured 0.43, no proof yet that installing runs no code 0.38 |

The edit-loop measurement above was made because of the first answer. The
two holes in the second answer are pass criteria 2 and 3, to be met before
the experiment counts.
