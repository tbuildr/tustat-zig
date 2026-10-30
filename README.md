# tustat

Update status for tbzos (Bazzite-based): when image, Flatpak and AppImage updates
were last applied, and what was applied. Companion to `tu`.

Read-only, no root. The only thing it writes is the AppImage snapshot and change log
in `${XDG_STATE_HOME:-~/.local/state}/tustat/` (same format as the old bash version).

## Build

Needs Zig 0.16.0.

```bash
zig build -Doptimize=ReleaseSafe
install -Dm755 zig-out/bin/tustat ~/.local/bin/tustat
```

## Use

```bash
tustat                 # overview + all sections
tustat image flatpak   # just these
tustat -c              # also check what's available (network)
tustat -a              # every package / day / log line
tustat -d 90 flatpak   # wider Flatpak window
```

## Where the data comes from

| Section   | Source |
|-----------|--------|
| Image     | `rpm-ostree status --json`; applied time from `ostree-finalize-staged` in the journal; changes from `rpm-ostree db diff` (rollback → booted, booted → staged) |
| Flatpak   | `flatpak history` (journal) + `flatpak list` for current versions |
| AppImage  | scans `~/AppImages`, `~/Applications`, `~/.local/bin` (override with `TUSTAT_APPIMAGE_DIRS`); name/version from Gear Lever `.desktop` files; own snapshot diff for history |
| Timers    | `systemctl show` for uupd / ublue-update / rpm-ostreed-automatic / flatpak update timers |

<!-- agent-sandbox:begin (managed by sandbox-note.sh, edits are overwritten) -->
## Agent sandboxes

**If `devenv` is not on PATH, you are in an agent sandbox** (a tmakr pod or
a local `agents-sandbox` container). These instructions then take precedence
over anything elsewhere in this file: devenv, direnv, `devenv shell` /
`devenv up`, push and pull-request steps.

### Git: commit, never push

- Commit your work on a branch. **Never push.** In a tmakr pod the GitHub
  token is read-only, so `git push` fails with 403 by design. Don't retry it,
  change remotes, switch to SSH, or look for other credentials.
- Tom fetches your commits from the sandbox, reviews them and pushes from his
  own machine. Uncommitted changes and stashes can't be fetched: commit before
  you say a task is done.
- Start each piece of work on a new branch off `main`. Keep `main` matching
  `origin/main`; don't commit to it.
- Don't open pull requests or use `gh`. Once you've said a branch is done,
  don't rewrite its history (no rebase, amend or force): Tom may have fetched
  it already.

### Tools: no devenv

`devenv.nix` is for local development only.

- Don't install or bootstrap Nix, devenv or direnv. Use the tools already on
  PATH: Python 3.14 with `uv` (`uv sync`, `uv run …`; Python downloads are
  disabled), Node 24 with pnpm/bun, Go, Rust, C/C++ toolchains, ruff, eslint,
  Tailwind v4, git.
- Postgres: connection settings come from the environment. In a tmakr pod,
  if `PGHOST` is unset, run `set -a; . /etc/agent-db/database.env; set +a`.
  Don't start your own database server.
- Services that `devenv up` would start aren't running. Start what you need
  in the foreground (for example `uv run manage.py runserver`), or say what
  is missing.
- If something in `devenv.nix` has no equivalent here, say so and stop rather
  than working around it.
<!-- agent-sandbox:end -->
