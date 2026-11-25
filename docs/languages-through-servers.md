# Languages mapped through a language server

Which languages `swan map` (the Rust program) maps by asking a language
server for every definition and its references, through SolidLSP behind
`tools/solidlsp/bridge.py`; which were tried and left with the syntax index;
and why. Each was measured on a real repo, sealed and never trusted, before it
was kept or left out. The Goose program that ships reads none of this: it
knows only `"map": "lsp"` (Go and Goose).

How a language is added: a `"map_lsp"` list in its entry in
`tools/modules.json` (the server through the bridge, `"sealed": true`, the
real server's path under `"needs"`), a pinned fetch in
`scripts/fetch-tools.sh`, a two-file fixture under `fixtures/lsp-<lang>` and
its rows asserted in `rust/tests/lsp_languages.rs`. Nothing is downloaded
when a map runs: SolidLSP is told where the fetched server is
(`SWAN_SOLIDLSP_SETTINGS`, or `SWAN_BRIDGE_PATH` for a server it looks for on
the PATH).

## The verdicts

| Language | Verdict | Server (licence) | Measured on | Seconds | What the map holds |
|---|---|---|---|---|---|
| Go | kept, since 2026-11-17 | gopls (BSD-3-Clause) | cobra, 36 files | 4.8 | 789 definitions, 5,920 references, all from the server; unchanged by this work |
| Lua | kept, 2026-11-25 | lua-language-server 3.19.2 (MIT) | Penlight, 117 files | 18.7, against 0.2 by name | 6,026 definitions and 17,796 references from the server; before, 941 definitions and 11,895 references matched by name |
| PHP | kept, 2026-11-25 | PHPantom 1.1.0 (MIT) | Slim, 125 files | 1.2 | 1,119 definitions, 4,387 references, 194 implements; before, nothing (PHP was only searched) |
| Shell | left with the syntax index | bash-language-server 5.6.0 (MIT) | bats-core, 54 files | 8.2, against 0.78 | its answers are name matches |
| Ruby | left with the syntax index | ruby-lsp 0.26.11 (MIT); Solargraph 0.62.2 (MIT) | rack, 104 files | 112.6 | ruby-lsp matches methods by name; Solargraph runs the repo's code |

## Lua: kept

lua-language-server is found by SolidLSP on the PATH the entry gives it
(`SWAN_BRIDGE_PATH`), and writes its log and meta folders into the map
folder (`LLS_LOG_PATH`, `LLS_META_PATH`).

Penlight at 44007e5, sealed, not trusted:

| | Seconds | Definitions | References |
|---|---|---|---|
| Before (syntax index) | 0.2 | 941 | 11,895, by name |
| Every symbol the server lists | 224 | 10,505 | 27,442 |
| What a function declares inside it left out | 84 | 6,026 | 17,796 |
| Files held open while they are asked about | 18.7 | 6,026 | 17,796 |

- **What is left out.** lua-language-server lists every local, parameter
  and block inside a function; each would get its own references question.
  Go's and PHP's servers list none of these. A symbol with a function above
  it is not mapped, and the map's report says how many (10,552 on Penlight).
- **Files held open.** SolidLSP opens and closes a file around every
  question, and the server reads and checks it again each time. With
  `SWAN_SOLIDLSP_HOLD_OPEN=1` in the entry the bridge keeps a file open once
  Swan has opened it. This is for a map only: a held file is not read from
  disk again, so a server that answers live, after edits, must not set it.
  Of the 18.7 s, 13.4 s is the server itself (2.2 ms a question).
- **Judged.** 20 sites read in the source where the two maps disagree: the
  server right at 17, the match by name at 3. By name a call goes to every
  function of that name (`sip.compile` and `template.compile`), or to none
  when there are more than three; the server follows the module the call
  goes through. The 3 are calls through a file-level alias (`local asserteq
  = test.asserteq`): the server links the call to the alias, which is where
  it is defined, not to the function behind it.
- **When the server fails**, the language's files are mapped by name in the
  same map and the report says so; when it is not fetched, the same, with
  the path that is missing. Before this work Lua always had its by-name
  rows, and it still does.

Limits: one question on Penlight went unanswered (an error inside the
server). A change to one Lua file redoes the whole language's job. An
install (`SWAN_RUNTIME_ONLY`) fetches neither lua-language-server nor
PHPantom, since the program that ships maps through neither; both fetches
are for a dev checkout until the Rust program ships. No
JetBrains IDE here judges Lua.

## PHP: kept

PHPantom is one binary with no PHP, no node and no licence key behind it,
fetched by `scripts/fetch-tools.sh` (group `php`) and pinned by sha256 for
x86_64 and aarch64 Linux. Three servers were tried on 2026-11-24, sealed:

| | PHPantom 1.1.0 | Intelephense 1.18.5 | Devsense 1.0.19567 |
|---|---|---|---|
| Licence | MIT | proprietary; implementations behind a paid key | proprietary |
| Needs | nothing | node | node |
| References | by type | by type | by type, plus name matches on receivers it cannot type |
| Implementations | answered, both ways | none without a key | none without activation |

Phpactor (MIT) needs PHP 8.1 on the machine and was not tried.

By type means: with `Circle` and `Square` each defining `describe()`, a call
on a `Circle` is a use of `Circle::describe` only (fixtures/lsp-php). A call
through the interface is a use of the interface's method and of each
implementer's.

Two things in SolidLSP's PHP launchers had to be gone around, and one
setting does both (`SWAN_SOLIDLSP_UNOPENED=1`: each question goes to the
server as asked, and no file is opened in it):
- They sleep 1 s before every references and definition question. Slim took
  1,123 s that way and 1.2 s without.
- PHPantom loses a use its index had once a file is opened after the
  workspace is indexed (the same messages replayed 2 ms apart lose it; never
  opening a file keeps it). Waiting after start does not help: 10 s and 60 s
  were measured.

Slim at e257f61, sealed, not trusted, its dependencies never installed:
1.2 s; against the slept run 1,116 of 1,119 definitions have the same
answers, and the difference is five more references (calls narrowed by
`instanceof`, each right). The use that opening a file loses is there. 28 references were read in
the source (20 across a method on a typed variable, a static call, an
interface method and a property; 8 more across files): 28 right.

Limits: `vendor/` is absent in a repo as cloned, and filling it means
running composer, the repo's own package manager, so a call through a type
that comes from a package resolves to nothing; 55% of Slim's definitions
have a reference. PHPantom answers one call differently from run to run
(`MiddlewareDispatcher.php:176`). Not yet put beside PhpStorm.

## Shell: left with the syntax index

bash-language-server 5.6.0 (MIT) starts sealed with no network once
SolidLSP is given its path, so the recipe works. Its answers do not: for a
name it gives every occurrence of that name in the workspace. On bats-core
(54 .sh and .bash files) the map took 8.2 s against 0.78 s, and of 10 sites
read where the two maps disagree the server was right at 5 and matching by
name at 5. Every reference only the server had (52) sat on another
definition of the same name. A map made this way would hold the same guesses
as the syntax index, slower, and marked as resolved when they are not. So
shell stays with the syntax index, where a reference says it was matched by
name. The server is still the right tool for live errors (with ShellCheck),
which is a separate step.

## Ruby: left with the syntax index

Two servers were tried on 2026-11-24, each sealed, on a fixture and on
rack/rack (104 files).

**ruby-lsp 0.26.11 (MIT)** runs sealed and never ran the repo's code once
three things were stopped (below). It is not kept, for two measured reasons:
- Methods are matched by name. With two classes that each define
  `describe`, each definition was given both calls and the other class's
  definition. On rack, of 81 method names defined more than once, 74 got the
  same reference count for every definition (`close`: 18 definitions, 105
  references each). Classes and modules resolve exactly; a constant asked at
  its assignment got an answer for 18 of 180.
- Each references question took 70 ms on a 104-file repo (112.6 s for 1,595
  definitions), and the server has no implementation answer.

What had to be stopped for it to be safe, each shown with a marker file in a
trap fixture:
1. The gem's own executable composes a bundle from the repo (evaluates its
   Gemfile and gemspecs, writes `.ruby-lsp/` into the repo, runs `bundle
   install`) unless `BUNDLE_GEMFILE` is set. Stopped by pointing it at a
   Gemfile of Swan's own, locked with checksums, `BUNDLE_FROZEN=true`.
2. The server requires every `ruby_lsp/**/addon.rb` in the workspace: planted
   code ran. Stopped by a launcher that loads add-ons from installed gems
   only (below).
3. SolidLSP's launcher picks the start command from the repo: a
   `.ruby-version` with mise, rbenv or asdf on PATH, or a Gemfile.lock naming
   ruby-lsp with a `bundle` (the repo's own `bin/bundle` counts), leads to
   `mise exec` or `bundle exec` in the repo. Stopped by replacing
   `RubyLsp._setup_runtime_dependencies` in the bridge with one that returns
   the launcher.
4. RuboCop, when it is in the bundle, loads what the repo's `.rubocop.yml`
   names. Stopped by leaving RuboCop out of the bundle.

It needs a Ruby of 3.3 or newer on the machine (rbs 4.2.0); its gems hold
C extensions built for that Ruby, so a fingerprint would have to take in
`ruby --version`.

**Solargraph 0.62.2 (MIT)** answers methods by type (YARD tags, inferred
locals) but is not a recipe for a repo that is not trusted: it evaluates
every gemspec in the workspace, evaluates the Gemfile when a lock exists,
runs RuboCop by default, and SolidLSP's launcher for it ran the repo's
`bin/bundle`. Each start also waits 60 s for a status the server never
sends. For a trusted repo it could be a candidate marked
`"runs_repo_code": true`; that was not built or measured.

What would make Ruby worth mapping this way: the server's symbols
(documentSymbol over all of rack takes 0.29 s and its parser is exact where
the syntax index reads lines) with references still matched by name and
marked so, or Solargraph for trusted repos. Neither is started.

The launcher that was measured, for whoever picks this up
(`BUNDLE_GEMFILE` names a Gemfile holding only `gem "ruby-lsp", "0.26.11"`):

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# ruby-lsp for a sealed map.
#
# The gem's own executable composes a bundle from the repository's Gemfile
# (evaluating it, and installing gems) unless BUNDLE_GEMFILE is set, and its
# server requires every <workspace>/**/ruby_lsp/**/addon.rb it finds. This
# launcher sets up only the bundle BUNDLE_GEMFILE names (ours, locked and
# installed ahead) and loads add-ons from installed gems only, never from the
# repository.
abort("ruby-lsp launcher: BUNDLE_GEMFILE must name the launcher's own Gemfile") unless ENV["BUNDLE_GEMFILE"]

require "bundler/setup"
require "ruby_lsp/internal"

module NoProjectAddons
  def load_addons(global_state, outgoing_queue, include_project_addons: true)
    super(global_state, outgoing_queue, include_project_addons: false)
  end
end
RubyLsp::Addon.singleton_class.prepend(NoProjectAddons)

$stdin.sync = true
$stdout.sync = true
$stderr.sync = true
$stdin.binmode
$stdout.binmode
$stderr.binmode

server = RubyLsp::Server.new
$> = $stderr
server.start
```

## Not judged against an IDE yet

PHP is to be put beside PhpStorm and Go beside GoLand
(`compare/refs_vs_ide.py` in the JetBrains kit); both wait for the owner to
add the trial repos' folder to each IDE's trusted locations. There is no
JetBrains IDE for Lua here, so Lua's judge is its fixture and the sites read
in Penlight.
