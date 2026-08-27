# AGENTS.md §4's format-and-lint table, in one place a human can run.
#
# Nothing here is a new assertion. `bash scripts/validate.sh` is the
# verification entry point and stays the only one; this file covers the static
# stages that were a maintainer's memory until now, and it is deliberately not a
# wrapper around the suite.
#
# Every file list is derived with `git ls-files` rather than written out, so a
# file added to the repository is covered without an edit here. `--others
# --exclude-standard` is what makes that true of a file you have only just
# written: without it a new file is invisible until it is staged, which is
# exactly when a format check is worth having. The ignore rules still apply, so
# `logs/`, `refs/` and the project's own state directories stay out.
#
# Each list is flattened onto one line because an interpolated newline would end
# the recipe's line and leave the rest of the list to the shell as commands of
# its own.
#
# Two exclusions, both deliberate. A symlink is skipped because `CLAUDE.md`
# points at `AGENTS.md`, and formatting one file twice through two names is a
# write nobody asked for. A markdown file opening with `---` is skipped because
# mdformat destroys YAML frontmatter, which AGENTS.md §4 says in as many words.
#
# The table's `*.json` row has nothing to act on: the repository tracks no JSON
# file, and the one JSON it produces — a confinement description — is validated
# against nono's own schema by `check_confinement_validates`, in the suite,
# where the thing being validated has been built.

nix_files := `git ls-files --cached --others --exclude-standard '*.nix' | tr '\n' ' '`
sh_files := `git ls-files --cached --others --exclude-standard '*.sh' | tr '\n' ' '`
# .yamlfmt is named because it carries no extension, so no glob reaches it.
yaml_files := `git ls-files --cached --others --exclude-standard '*.yml' '*.yaml' '.yamlfmt' | tr '\n' ' '`
md_files := `git ls-files --cached --others --exclude-standard '*.md' | while read -r f; do [ -L "$f" ] && continue; [ "$(head -n 1 "$f")" = '---' ] && continue; printf '%s ' "$f"; done`

# List the recipes.
default:
    @just --list

# Format every file kind, in place.
fmt:
    nixfmt {{ nix_files }}
    mdformat {{ md_files }}
    yamlfmt {{ yaml_files }}
    shfmt --write {{ sh_files }}

# The same, asserted rather than applied. Non-zero on a file that would change.
fmt-check:
    nixfmt --check {{ nix_files }}
    mdformat --check {{ md_files }}
    yamlfmt -lint {{ yaml_files }}
    shfmt --diff {{ sh_files }}

# `nix flake check` warns four times on every run, about `leakRegistry`,
# `leakRegistryCheckEntry`, `agents` and `agentBinaries` being outputs it does
# not recognise. They are deliberate — the flake exposes them so the registry
# and the agent table are readable without a build — and the warning is nix
# declining to schema-check a non-standard output, not a finding. It also omits
# the darwin system, because this host cannot evaluate it.

# Lint every file kind. Reads, never writes.
lint:
    shellcheck {{ sh_files }}
    yamllint {{ yaml_files }}
    nix flake check --accept-flake-config

# Every action in the workflow is pinned to a commit, and every pin carries the
# tag it claims to be. This recipe is what proves the second half, so it reaches
# the GitHub API and fails on a host with no network. `pinact run -fix=false
# --no-api` is the offline half, which only sees whether a pin is a
# 40-character SHA at all.

# Check that every action pin still matches the tag its comment claims.
pins:
    pinact run -fix=false --verify-comment

# Everything static, in the order a review wants it: shape, then substance.
#
# The closing line exists because three of these stages say nothing at all when
# they pass, and `nix flake check` warns on every run whether or not anything is
# wrong. Without it a reader cannot tell a clean run from one that stopped early,
# which is the same silent-pass problem the suite prints a count to avoid.
static: fmt-check lint pins
    @echo 'static: formatting, linting and the action pins all pass.'
