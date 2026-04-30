<img src=".github/assets/seetree-icon.png" width="180" alt="seetree">

# seetree

[![CI](https://github.com/ramonclaudio/seetree/actions/workflows/ci.yml/badge.svg)](https://github.com/ramonclaudio/seetree/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/ramonclaudio/seetree)](https://github.com/ramonclaudio/seetree/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Most of the time while Claude is working, I'm not actually looking at the editor. I'll ask for something, Claude goes off for a few minutes, and I wait. When I come back to peek at the project, my editor can't really tell me which files Claude just touched. Every dirty file shows the same little modified dot, whether it was edited a second ago or two weeks ago. Touched this session, touched on last month's branch, all the same.

So I built seetree, a live tree viewer that lights up as [Claude Code](https://docs.claude.com/en/docs/claude-code) touches files. Each tool gets its own badge: `[Read]`, `[Write]`, `[Edit]`, `[Bash]`. Mutations flash a `+N -M` diff chip; deletions leave a `× name [Delete]` ghost at the bottom for a few seconds before falling off. Colors fade so "just now" looks different from "earlier in the session." Click a name to open it in your editor. Search and click-to-collapse work; it stays usable as a plain tree viewer when Claude's off.

seetree is also my first project in Zig. I picked it for no runtime deps, instant startup, and a tiny binary. Also wanted an excuse to learn it. The build side ended up where I wanted: around 200K depending on target, libc-only on macOS, fully static on Linux musl. Tested in Ghostty (where I live), iTerm2, and Kitty. The Zig itself is a first pass and probably has corners that aren't idiomatic to anyone who actually writes Zig for a living. PRs welcome.

![seetree demo](.github/assets/demo.webp)

## Install

Homebrew (macOS + Linuxbrew):

```bash
brew install ramonclaudio/tap/seetree
```

Or tap once and use the short form thereafter:

```bash
brew tap ramonclaudio/tap
brew install seetree
```

npm (any package manager):

```bash
npm i -g seetree                  # also: bun add -g, pnpm add -g
npx seetree                       # one-shot, no install (also: bunx, pnpx)
```

One-liner for anyone not on brew or npm (auto-detects platform, verifies sha256):

```bash
curl -fsSL https://raw.githubusercontent.com/ramonclaudio/seetree/main/install.sh | bash
```

Or grab a prebuilt from the [releases page](https://github.com/ramonclaudio/seetree/releases/latest) directly:

```
seetree-aarch64-macos
seetree-x86_64-macos
seetree-x86_64-linux-musl
seetree-aarch64-linux-musl
```

Build from source with the Zig version pinned in `build.zig.zon`:

```bash
git clone https://github.com/ramonclaudio/seetree.git
cd seetree
zig build --release=safe
./zig-out/bin/seetree
```

## Usage

```bash
seetree                  # live view of cwd
seetree ~/code/foo       # pointed at a dir
seetree --once           # print the tree and exit
seetree --detach         # new ghostty window (macOS)
seetree --side           # split the focused ghostty pane to the right (macOS)
seetree --list           # print known claude projects by last activity, then exit
seetree --theme=nord     # pick a theme at launch
```

Keys:

```
j / k / arrows     move
h / l / arrows     collapse / expand (or jump to parent)
g / G              top / bottom
space              toggle collapse on a dir
enter / click      open in editor
click ▸ / ▾        toggle collapse
/                  search (backspace on empty exits)
t                  cycle theme
s                  settings (theme, poll rate, show hidden files)
?                  help
q / ctrl-c         quit
```

## Claude Code hook

By default seetree polls `~/.claude/projects/*.jsonl` every 2 seconds. Wire the FileChanged hook for instant updates:

```bash
seetree --install-hook --apply   # edits ~/.claude/settings.json (saves .bak)
seetree --install-hook           # or prints the JSON to paste yourself
```

With the hook wired, seetree drops its poll rate to 30s and refreshes on every `FileChanged` event instead. Idempotent, so running `--apply` twice is a no-op.

## Editor

Click or hit enter on a file and seetree opens it in Zed by default. Pick a different editor with `SEETREE_EDITOR`:

```bash
SEETREE_EDITOR=cursor   # Cursor
SEETREE_EDITOR=code     # VS Code (also: vscode)
SEETREE_EDITOR=zed      # default
```

Or override the command outright:

```bash
SEETREE_OPEN_CMD="code -g"
```

## Ignoring files

seetree reads `.gitignore` at the project root by default. Drop a `.seetreeignore` next to it (same syntax) to hide files from seetree's view without changing what git tracks. Useful for lockfiles, vendored junk, generated SQL dumps, anything you want out of the live tree but kept under version control.

```
# .seetreeignore
yarn.lock
package-lock.json
*.min.js
vendor/
```

Patterns are loaded from the project root only. Nested `.seetreeignore` files in subdirectories aren't picked up, unlike git.

## Performance

Measured on Apple M4 Pro (12 cores, 24 GB RAM, macOS 26.4.1) with hyperfine 1.20.0, `--shell=none`, 20 warmup runs, 200 measured runs (down to 5 runs at 1M to keep total bench time reasonable). Tool versions: seetree 0.1.0 (ReleaseSafe), GNU tree 2.3.2, eza 0.23.4, fd 10.4.2.

`seetree --once`, cold start on synthetic uniform trees:

```
2 files               1.8 ms ± 0.1
50 files              1.9 ms ± 0.1
500 files             2.3 ms ± 0.1
5,000 files           6.0 ms ± 0.3
50,000 files         41.3 ms ± 1.0
100,000 files        71.6 ms ± 0.8
500,000 files       352.2 ms ± 4.4
1,000,000 files     694.7 ms ± 8.1
```

Same workload, same machine, alongside other tree-printers and dir-walkers. These tools do slightly different jobs (`tree` prints a hierarchy, `fd` just lists files, `eza --tree` adds metadata and colors, `seetree --once` builds a tree and prints it with terminal hyperlinks), so this is wall time to walk and print, not raw filesystem traversal cost:

```
                     5K files   50K files  100K files  500K files   1M files
seetree --once        6.0 ms     41.3 ms    71.6 ms     352 ms      695 ms
fd . --type f        13.3 ms     67.5 ms   118.8 ms     625 ms    1,360 ms
tree (GNU)           24.2 ms    228.9 ms   463.3 ms   4,676 ms      n/a
eza --tree           43.4 ms    338.8 ms   622.2 ms   6,301 ms      n/a
```

(`tree` and `eza` on the 1M case weren't completed; `eza` was running over 30s per iteration.)

Memory at scale, `--once`, peak RSS:

```
50,000 files          3 MB
100,000 files        25 MB
500,000 files       120 MB
1,000,000 files     264 MB
```

About 240 bytes per node in the tree arena. For typical project repos (under 50K files), seetree stays under 5 MB.

Live mode under continuous file churn, 200-file tree, 1-second tick: ~2 MB RSS steady-state, <0.5% CPU, single-threaded.

Binary, clean release build:

```
seetree macOS arm64        212 KB     ReleaseSafe
seetree macOS x86_64       206 KB     ReleaseSafe
seetree Linux x86_64 musl  179 KB     ReleaseSmall + LTO
seetree Linux arm64 musl   161 KB     ReleaseSmall + LTO
```

For reference, on the same machine (homebrew-installed where applicable):

```
GNU tree             109 KB
BSD ls               151 KB
BSD find             167 KB
seetree              212 KB
eza                1,231 KB
fd                 2,868 KB
```

Zero leaks across `--once`, the live loop, and the test suite, verified with `zig build test` (DebugAllocator) and macOS `leaks --atExit` against a backgrounded live run with file churn.

## Themes

`claude` (default), `mono`, `gruvbox`, `nord`, `dracula`, `tokyo-night`, `catppuccin`, `rose-pine`, `solarized`. Press `t` to cycle at runtime, or set `--theme=NAME` / `SEETREE_THEME` at launch.

## License

MIT.

[hello@ramonclaudio.com](mailto:hello@ramonclaudio.com) / [GitHub](https://github.com/ramonclaudio) / [X](https://x.com/ramonclaudio) / [ramonclaudio.com](https://ramonclaudio.com)

Ray
