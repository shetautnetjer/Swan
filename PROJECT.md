# Swan: purpose and owner map

## Purpose
Swan gives an AI coding agent the understanding of a codebase that an IDE
has: where a thing is defined, who uses it, what a change would break, which
tests cover it, and what errors a file has now. Agents ask it over MCP. A
wrong answer from Swan is worse than no answer, because agents act on it.

Owner and decision authority: Khamani. He is not a programmer: reports are in
plain words, with numbers before and after.

## Scope
- In scope: the exact map (compiler-grade tools and language servers), the
  questions asked of it, checking and editing through it, the MCP server, and
  the sealing that keeps a mapped repo's code from running unasked.
- Out of scope: what can be learned by only reading files. That is
  Spread-Wings ([who does what](docs/wings-and-swan.md)), which ships inside
  Swan as the `wings/` submodule.
- Done means measured: a change is accepted on a check that was seen to fail
  before it, the full suite in the microVM on the commit that merges, and a
  before/after number on a real repo.

## Where things are
| What | Owner |
|---|---|
| Shared rules for agents | [AGENTS.md](AGENTS.md) |
| What is true now, entry by entry | [STATUS.md](STATUS.md) (add at the end) |
| Choices and why | [DECISIONS.md](DECISIONS.md) (append-only) |
| What Swan is and every command and tool | [README.md](README.md) |
| How the parts fit | [docs/modular-design.md](docs/modular-design.md) |
| Swan and Spread-Wings | [docs/wings-and-swan.md](docs/wings-and-swan.md) |
| The program | `src/*.goose`, `native/`, `lsp/` (submodule), `wings/` (submodule) |
| The port to Rust (branch `rust`) | [docs/rust-port.md](docs/rust-port.md), `rust/`, [HANDOFF.md](HANDOFF.md) |
| Checks | `tests/check/*_suite.goose`, `tests/*.py`, run by `scripts/space-test.sh` |
| The skill agents use to ask Swan | `skills/swan-code-check/` |

## Work in progress
One piece of work at a time has a handoff: [HANDOFF.md](HANDOFF.md). When it
is merged or dropped, its entry in STATUS.md is the record and the handoff is
rewritten for the next piece.
