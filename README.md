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
