# Where an agent still cannot see: gaps measured on 2026-11-20

The owner asked where Swan leaves an agent blind: what keeps it from seeing a
repo's bugs and errors as an IDE would, without filling its context, so it can
fix code, place new code, and know what an edit touches. He asked for one next
experiment.

The tools he named were not available here. There is no "drex" command and no
service token in this session. jev-cli is not installed; Graphify shows its
`search` is a lexical chunk search with an optional semantic pass through a
model provider, which would need that provider's key. Nor were "pstack" or a
"superpowers" plugin available. The measurements below use Swan itself, with
Graphify and ripgrep, on flask (`49943b5a9441`, 217 files). The Swan program
is the Goose build of main's `src/` (`049fd7c`). Pyright is 1.1.414.

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
| Without the packages (what Swan shows today) | 203 |
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

1. flask: of the 120 false errors, at most 5 remain, each named in the
   report as a package not set up (the docs-only `pallets_sphinx_themes`
   is expected). The 24 hidden type errors appear, and so do the 4 optional
   imports unless the extras are set up. The 83 others are unchanged.
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

**What it needs from the owner.** Rule 1 says no package manager runs on a
repo nobody trusted. This experiment runs Swan's own uv or npm, on the
package list the repo declares, into the map folder, with code execution
turned off. Whether that is inside the rule, or needs trust like a build
does, is the owner's call, before anything is built.

**Why this one first.** It is the gap that makes the other answers wrong.
A summary of the problems list (gap 2) is worth building right after, but
summarising a list that is 59% false would only make the wrong answer
shorter. Gaps 3 and 5 are small fixes. Gap 4 is large and is better aimed
once the errors are true.

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
- Answer sizes are the byte counts of `swan query <db> diag ""`,
  `callers Flask/make_response` and `callees Flask/make_response`.
