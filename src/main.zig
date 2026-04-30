const std = @import("std");
const builtin = @import("builtin");
const tree = @import("tree.zig");
const session = @import("session.zig");
const render = @import("render.zig");
const term = @import("term.zig");
const sys = @import("sys.zig");

// Cuts dead weight out of std when building ReleaseSmall. Everything
// here is either functionality seetree never uses (networking, TLS,
// thread-local alt-stacks) or diagnostic machinery we replace with
// noops. logFn is wired to a tight direct-write stub; std.log.*
// callers bypass it entirely in favour of `logErr` below so the
// formatter never gets instantiated.
pub const std_options: std.Options = .{
    .enable_segfault_handler = false,
    .signal_stack_size = null,
    .allow_stack_tracing = false,
    .networking = false,
    .http_disable_tls = true,
    .unexpected_error_tracing = false,
    .fmt_max_depth = 0,
    .page_size_min = 16384,
    .page_size_max = 16384,
    .logFn = logNoop,
};

// Disable std.debug.print's default Io.Threaded singleton in release
// builds so std.debug doesn't pull the whole threaded io implementation
// in. We never call std.debug.print (logFn is a noop, panic uses
// c.exit). In Debug, std.zig dereferences this singleton from
// `debug_io = debug_threaded_io.?.io()`, so we keep the std default
// alive there or `zig build` would fail to compile.
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = if (builtin.mode == .Debug)
    std.Io.Threaded.global_single_threaded
else
    null;

fn logNoop(
    comptime _: std.log.Level,
    comptime _: @EnumLiteral(),
    comptime _: []const u8,
    _: anytype,
) void {}

/// Decimal i64 parser. Avoids `std.fmt.parseInt` which would pull in the
/// formatter machinery we deliberately stripped from this build.
fn parseI64Env(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var i: usize = 0;
    var neg = false;
    if (s[0] == '-') {
        neg = true;
        i = 1;
        if (i == s.len) return null;
    }
    var n: i64 = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c < '0' or c > '9') return null;
        n = n * 10 + @as(i64, c - '0');
    }
    return if (neg) -n else n;
}

/// Write an error message to stderr. Takes a slice of string pieces so
/// callers can splice in dynamic values (like `@errorName(err)`) without
/// pulling std.fmt into the binary. Always appends `\n`.
fn logErr(parts: []const []const u8) void {
    _ = std.c.write(2, "seetree: ", 9);
    for (parts) |p| _ = std.c.write(2, p.ptr, p.len);
    _ = std.c.write(2, "\n", 1);
}

// Replace the default panic handler with a one-byte write; the default
// one drags in stack unwinding, symbol lookup and formatted output.
pub const panic = std.debug.FullPanic(panicFn);
fn panicFn(_: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    std.c.exit(134);
}

const usage =
    \\seetree: terminal tree view that tints files as Claude Code edits them
    \\
    \\usage: seetree [options] [dir]
    \\
    \\options:
    \\  -h, --help       show this help
    \\      --version    print version
    \\      --once       print once and exit (default is live view)
    \\      --detach     open seetree in a new Ghostty window (macOS only)
    \\      --side       split the current Ghostty terminal to the right (macOS only)
    \\      --install-hook
    \\                   write ~/.claude/hooks/seetree-refresh.sh and print the
    \\                   FileChanged hook config to add to ~/.claude/settings.json
    \\      --install-hook --apply
    \\                   edit ~/.claude/settings.json directly (with .bak backup)
    \\      --theme=NAME color scheme: claude (default), mono, gruvbox, nord,
    \\                   dracula, tokyo-night, catppuccin, rose-pine, solarized
    \\                   (also: SEETREE_THEME env var)
    \\  -l, --list       list known Claude projects sorted by last activity, then exit
    \\
    \\live view controls:
    \\  j/k or ↓/↑       move selection
    \\  h/← or l/→       collapse/expand (or jump to parent)
    \\  space            toggle collapse on selected dir
    \\  enter            open selected in editor
    \\  g / G            jump to top / bottom
    \\  pgup / pgdn      page up / page down
    \\  t                cycle theme (claude → mono → gruvbox → …)
    \\  s                open settings popup
    \\  /                search (esc to clear)
    \\  click name       open file/dir in editor
    \\  click ▸/▾        toggle expand/collapse
    \\  scroll wheel     scroll the tree
    \\  q or ctrl-c      quit
    \\
    \\env vars:
    \\  SEETREE_THEME       alias for --theme
    \\  SEETREE_EDITOR      zed | cursor | code   (default: zed)
    \\  SEETREE_OPEN_CMD    full override for the open command (path is appended)
    \\  SEETREE_FRESH_MS    how long the [Edit]/[Read] chip + diff stays
    \\                      visible after a touch (default: 3000)
    \\  SEETREE_POLL_MS     ms between filesystem rescans (default: 2000;
    \\                      drops to 30000 when the FileChanged hook is
    \\                      installed)
    \\
;

const version_str = "seetree 0.1.0\n";

const Args = struct {
    dir: ?[]const u8 = null,
    help: bool = false,
    show_version: bool = false,
    once: bool = false,
    detach: bool = false,
    side: bool = false,
    list: bool = false,
    install_hook: bool = false,
    /// Paired with --install-hook: edits ~/.claude/settings.json directly
    /// instead of printing the JSON for the user to paste.
    apply: bool = false,
    theme: ?[]const u8 = null,
    /// Set by spawned children to break the auto-side recursion.
    no_auto_side: bool = false,
};

fn parseArgs(argv: []const [:0]const u8) !Args {
    var out: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            out.help = true;
        } else if (std.mem.eql(u8, a, "--version")) {
            out.show_version = true;
        } else if (std.mem.eql(u8, a, "--once")) {
            out.once = true;
        } else if (std.mem.eql(u8, a, "--detach")) {
            out.detach = true;
        } else if (std.mem.eql(u8, a, "--side")) {
            out.side = true;
        } else if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--list")) {
            out.list = true;
        } else if (std.mem.eql(u8, a, "--install-hook")) {
            out.install_hook = true;
        } else if (std.mem.eql(u8, a, "--apply")) {
            out.apply = true;
        } else if (std.mem.startsWith(u8, a, "--theme=")) {
            out.theme = a["--theme=".len..];
        } else if (std.mem.eql(u8, a, "--theme") and i + 1 < argv.len) {
            i += 1;
            out.theme = argv[i];
        } else if (std.mem.eql(u8, a, "--no-auto-side")) {
            out.no_auto_side = true;
        } else if (a.len > 0 and a[0] != '-') {
            out.dir = a;
        } else {
            return error.UnknownArg;
        }
    }
    return out;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    const args = parseArgs(argv) catch |err| {
        logErr(&.{ "bad args: ", @errorName(err) });
        return err;
    };
    if (args.apply and !args.install_hook) {
        logErr(&.{"--apply only works with --install-hook"});
        return error.UnknownArg;
    }

    var out_buf: [64 * 1024]u8 = undefined;
    var stdout_w = FdWriter.init(1, &out_buf);
    const out = &stdout_w.interface;

    if (args.help) {
        try out.writeAll(usage);
        try out.flush();
        return;
    }
    if (args.show_version) {
        try out.writeAll(version_str);
        try out.flush();
        return;
    }

    const home = init.environ_map.get("HOME") orelse {
        try out.writeAll("HOME not set\n");
        try out.flush();
        return error.HomeMissing;
    };

    // Theme selection: --theme=X beats SEETREE_THEME beats default.
    const theme_name = args.theme orelse init.environ_map.get("SEETREE_THEME");
    if (theme_name) |n| _ = render.setThemeByName(n);

    // Tunable timings via env var. Useful when scripting demos where
    // the default 3 s freshness window expires before the recording
    // captures it.
    if (init.environ_map.get("SEETREE_FRESH_MS")) |s| {
        if (parseI64Env(s)) |v| if (v > 0) {
            render.fresh_window_ms = v;
        };
    }
    if (init.environ_map.get("SEETREE_POLL_MS")) |s| {
        if (parseI64Env(s)) |v| if (v > 0) {
            render.tree_poll_ms = v;
        };
    }

    // Resolve the Claude Code config root. Defaults to `$HOME/.claude`;
    // honors `CLAUDE_CONFIG_DIR` so demo recordings, multi-account
    // setups, and any tooling that runs claude with a custom config dir
    // still see their sessions tinted in seetree.
    const claude_dir = if (init.environ_map.get("CLAUDE_CONFIG_DIR")) |d|
        try arena.dupe(u8, d)
    else blk: {
        const buf = try arena.alloc(u8, home.len + "/.claude".len);
        @memcpy(buf[0..home.len], home);
        @memcpy(buf[home.len..], "/.claude");
        break :blk buf;
    };

    if (args.list) {
        try listProjects(gpa, out, claude_dir);
        try out.flush();
        return;
    }

    if (args.install_hook) {
        if (args.apply) {
            try applyHook(arena, out, claude_dir);
        } else {
            try installHook(arena, out, claude_dir);
        }
        try out.flush();
        return;
    }

    const root_path = try resolveRoot(arena, args.dir);

    // If invoked from inside a running Claude Code session without explicit mode,
    // auto-switch to --side so we don't clobber Claude's terminal. Only on
    // macOS; other platforms don't have the Ghostty+osascript pipeline. The
    // spawned child passes --no-auto-side to break the recursion.
    const in_claude = init.environ_map.get("CLAUDE_CODE_ENTRYPOINT") != null;
    const auto_side = mac_like and in_claude and !args.no_auto_side and !args.once and !args.detach;
    const side = args.side or auto_side;

    if (side) return spawnWindow(gpa, arena, init.environ_map, root_path, .side);
    if (args.detach) return spawnWindow(gpa, arena, init.environ_map, root_path, .detach);

    var t = tree.Tree.init(gpa);
    defer t.deinit();
    try tree.build(&t, root_path);

    var sess_opt: ?session.Session = null;
    defer if (sess_opt) |*s| s.deinit();

    if (session.findNewest(gpa, claude_dir, root_path)) |p| {
        defer gpa.free(p);
        sess_opt = try session.open(gpa, p);
        _ = session.pump(&sess_opt.?, nowMs()) catch 0;
    } else |_| {}

    if (args.once) {
        try render.drawOnce(out, gpa, root_path, &t, if (sess_opt) |*s| s else null);
        try out.flush();
        return;
    }

    try runLive(gpa, out, home, claude_dir, root_path, &t, if (sess_opt) |*s| s else null);
}

fn runLive(
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    home: []const u8,
    claude_dir: []const u8,
    root_path: []const u8,
    t: *tree.Tree,
    s: ?*session.Session,
) !void {
    var tm = try term.Term.init();
    const base = basenameOf(root_path);
    const prefix_str = "seetree · ";
    const title = try gpa.alloc(u8, prefix_str.len + base.len);
    defer gpa.free(title);
    @memcpy(title[0..prefix_str.len], prefix_str);
    @memcpy(title[prefix_str.len..], base);
    try tm.enter(out, title);
    defer tm.leave(out);

    var collapsed: render.Collapsed = .init(gpa);
    defer {
        var ci = collapsed.keyIterator();
        while (ci.next()) |k| gpa.free(k.*);
        collapsed.deinit();
    }

    var search: render.Search = .{};
    defer search.deinit(gpa);

    // Snapshot of the previous tree's paths (gpa-owned strings) so we can
    // diff against the next rebuild and detect deletions. Value = is_dir
    // so the [Deleted] indicator can render the right glyph.
    var prev_paths: std.StringHashMap(bool) = .init(gpa);
    defer {
        var pit = prev_paths.keyIterator();
        while (pit.next()) |k| gpa.free(k.*);
        prev_paths.deinit();
    }
    // Recently-deleted entries that still show in the tree with [Deleted]
    // for fresh_window_ms before falling off.
    var ghosts: render.Ghosts = .{};
    defer ghosts.deinit(gpa);

    // Flat list of currently visible rows, rebuilt on any state change.
    // We use one arena that we reset between rebuilds so row.prefix
    // strings don't pile up.
    var row_arena: std.heap.ArenaAllocator = .init(gpa);
    defer row_arena.deinit();
    var rows: []render.VisibleRow = &.{};
    var selection: usize = 0;
    var scroll: usize = 0;
    var show_help: bool = false;
    var show_settings: bool = false;
    var settings_cursor: usize = 0;

    // Fixed-buffer copy of the selected node's abs_path so we can
    // re-find it after a tree rebuild frees the tree arena. Stack
    // buffer instead of gpa.dupe avoids pulling the allocator-error
    // paths into this loop (cost measured: 17KB of binary).
    // Small fixed buffer (covers typical project paths). Longer
    // abs_paths drop stickiness but still render correctly.
    var selected_path_buf: [256]u8 = undefined;
    var selected_path_len: usize = 0;

    // Start polling slower when the FileChanged hook is already
    // installed; the settings popup can override this live.
    if (hookInstalled(claude_dir)) render.tree_poll_ms = 30_000;
    const redraw_poll_ms: i64 = 500;

    var rows_dirty = true;
    var screen_dirty = true;
    const now_start = nowMs();
    var last_tree_poll_ms: i64 = now_start;
    var last_redraw_ms: i64 = now_start;

    while (!tm.shouldStop()) {
        if (tm.consumeResize()) {
            try tm.refreshSize();
            screen_dirty = true;
        }
        if (s) |sess| {
            const n = session.pump(sess, nowMs()) catch 0;
            if (n > 0) screen_dirty = true;
        }

        const now_ms = nowMs();
        const force_rebuild = tm.consumeRefresh();
        if (force_rebuild or now_ms - last_tree_poll_ms >= render.tree_poll_ms) {
            last_tree_poll_ms = now_ms;
            tree.build(t, root_path) catch {};
            // Diff: any path in prev_paths missing from the new tree just
            // got deleted. Record it as a ghost so the user sees it fade
            // out with a [Deleted] badge before disappearing.
            diffPaths(gpa, &prev_paths, t, &ghosts, now_ms) catch {};
            rows_dirty = true;
            screen_dirty = true; // ghosts may need re-render even if rows unchanged
        }
        // Prune expired ghosts. Cheap; covers the case where the tree
        // hasn't rebuilt but some ghosts have aged out.
        if (ghosts.list.items.len > 0) {
            var live: std.StringHashMap(bool) = .init(gpa);
            defer live.deinit();
            collectPaths(t.root, &live) catch {};
            ghosts.prune(gpa, now_ms, &live);
            screen_dirty = true;
        }
        if (now_ms - last_redraw_ms >= redraw_poll_ms) {
            last_redraw_ms = now_ms;
            screen_dirty = true;
        }

        if (rows_dirty) {
            _ = row_arena.reset(.retain_capacity);
            rows = try render.collectRows(row_arena.allocator(), t, &collapsed, &search);
            // Re-anchor the cursor by path. Safe after tree rebuild
            // because the copy lives on this stack frame, not in the
            // tree arena.
            if (selected_path_len > 0) {
                if (findByPath(rows, selected_path_buf[0..selected_path_len])) |idx| {
                    selection = idx;
                } else if (rows.len == 0) {
                    selection = 0;
                } else if (selection >= rows.len) {
                    selection = rows.len - 1;
                }
            } else if (rows.len > 0 and selection >= rows.len) {
                selection = rows.len - 1;
            }
            // Row list changed; keep the cursor in view.
            ensureSelectionVisible(rows.len, visibleTreeRows(&tm, &search), selection, &scroll);
            rows_dirty = false;
            screen_dirty = true;
        }


        const visible_rows: u16 = visibleTreeRows(&tm, &search);
        // Per tick we only clamp scroll to the valid range (e.g. after
        // a row list shrinks). Snapping scroll to the selection happens
        // only in response to selection-changing events so mouse-wheel
        // scroll isn't yanked back to the selection on the next redraw.
        clampScroll(rows.len, visible_rows, &scroll);

        if (screen_dirty) {
            try render.drawLive(
                out,
                &tm,
                root_path,
                home,
                rows,
                if (s) |ss| @as(?*const session.Session, ss) else null,
                selection,
                scroll,
                &search,
                now_ms,
                show_help,
                show_settings,
                settings_cursor,
                &ghosts,
            );
            screen_dirty = false;
        }

        // Drain every event queued on stdin this tick. A fast paste or
        // held arrow key arrives as one read of multiple bytes; handling
        // only the first would silently drop the rest.
        while (tm.pollEvent()) |ev| switch (ev) {
            .none => {},
            .key => |k| {
                // Overlays swallow keys until closed.
                if (show_help) {
                    if (isQuitKey(k)) return;
                    show_help = false;
                    screen_dirty = true;
                    continue;
                }
                if (show_settings) {
                    if (isQuitKey(k)) return;
                    if (handleSettingsKey(k, &settings_cursor)) |outcome| {
                        if (outcome.close) show_settings = false;
                        if (outcome.rebuild) rows_dirty = true;
                        screen_dirty = true;
                    }
                    continue;
                }
                // Search mode consumes every printable key as input.
                // Global shortcuts (? help, s settings, t theme, etc.)
                // only apply in normal mode so they can't hijack a
                // query mid-type.
                if (search.mode != .search) {
                    if (isHelpKey(k)) {
                        show_help = true;
                        screen_dirty = true;
                        continue;
                    }
                    if (isSettingsKey(k)) {
                        show_settings = true;
                        screen_dirty = true;
                        continue;
                    }
                }
                const handled = try handleKey(gpa, &search, &selection, &scroll, &collapsed, rows, visible_rows, k);
                switch (handled) {
                    .quit => return,
                    .rows_changed => rows_dirty = true,
                    .screen_changed => screen_dirty = true,
                    .none => {},
                }
                // Keyboard events intentionally snap scroll so the
                // selection stays visible even if a prior wheel scroll
                // had pushed the viewport off the cursor.
                if (handled != .none and handled != .quit) {
                    ensureSelectionVisible(rows.len, visible_rows, selection, &scroll);
                    // Event-driven snapshot: record the selected abs_path
                    // NOW while rows is guaranteed valid. A tree rebuild
                    // next tick can then use selected_path_buf to re-find
                    // the cursor without dereferencing rows[].
                    selected_path_len = snapshotPath(&selected_path_buf, rows, selection);
                }
            },
            .click => |c| {
                if (render.rowIndexAt(c.row, rows, scroll, &tm, &search)) |idx| {
                    const row = rows[idx];
                    const icon_col = render.chevronCol(row);
                    const hit_icon = row.node.is_dir and icon_col != 0 and c.col >= icon_col and c.col <= icon_col + 1;
                    const name_range = render.nameColRange(row);
                    const hit_name = c.col >= name_range.start and c.col <= name_range.end;
                    // Selection always follows the click so keyboard
                    // nav can continue from where the mouse landed.
                    selection = idx;
                    ensureSelectionVisible(rows.len, visible_rows, selection, &scroll);
                    screen_dirty = true;
                    selected_path_len = snapshotPath(&selected_path_buf, rows, selection);
                    if (hit_icon) {
                        try toggleCollapsed(gpa, &collapsed, row.node.abs_path);
                        rows_dirty = true;
                    } else if (hit_name) {
                        try openPath(gpa, row.node.abs_path);
                    }
                    // Clicks on prefix/branch whitespace just move the
                    // cursor, no open, no toggle.
                }
            },
            .scroll => |dir| {
                // Overlays eat scroll so it doesn't sneak past the popup.
                if (show_help or show_settings) continue;
                const step: usize = 3;
                const max = if (rows.len > visible_rows) rows.len - visible_rows else 0;
                scroll = switch (dir) {
                    .up => if (scroll > step) scroll - step else 0,
                    .down => @min(scroll + step, max),
                };
                screen_dirty = true;
            },
        };

        const sleep_ts: std.c.timespec = .{ .sec = 0, .nsec = 100 * 1_000_000 };
        _ = c_nanosleep(&sleep_ts, null);
    }
}

const KeyResult = enum { none, quit, rows_changed, screen_changed };

fn handleKey(
    gpa: std.mem.Allocator,
    search: *render.Search,
    selection: *usize,
    scroll: *usize,
    collapsed: *render.Collapsed,
    rows: []const render.VisibleRow,
    visible_rows: u16,
    key: term.Key,
) !KeyResult {
    if (search.mode == .search) return handleSearchKey(gpa, search, selection, key);

    switch (key) {
        .char => |c| switch (c) {
            'q', 3 => return .quit,
            'j' => return moveSelection(selection, scroll, rows.len, visible_rows, 1, false),
            'k' => return moveSelection(selection, scroll, rows.len, visible_rows, -1, false),
            'g' => return moveTo(selection, 0),
            'G' => return moveTo(selection, if (rows.len == 0) 0 else rows.len - 1),
            '/' => {
                search.mode = .search;
                return .screen_changed;
            },
            'h' => return collapseOrParent(gpa, collapsed, selection, rows),
            'l' => return expandOrEnter(gpa, collapsed, selection.*, rows),
            't' => {
                _ = render.cycleTheme();
                return .screen_changed;
            },
            else => return .none,
        },
        .up => return moveSelection(selection, scroll, rows.len, visible_rows, -1, false),
        .down => return moveSelection(selection, scroll, rows.len, visible_rows, 1, false),
        .left => return collapseOrParent(gpa, collapsed, selection, rows),
        .right => return expandOrEnter(gpa, collapsed, selection.*, rows),
        .page_up => return moveSelection(selection, scroll, rows.len, visible_rows, -@as(i32, visible_rows), true),
        .page_down => return moveSelection(selection, scroll, rows.len, visible_rows, @as(i32, visible_rows), true),
        .home => return moveTo(selection, 0),
        .end => return moveTo(selection, if (rows.len == 0) 0 else rows.len - 1),
        .enter => {
            if (selection.* < rows.len) {
                try openPath(gpa, rows[selection.*].node.abs_path);
            }
            return .none;
        },
        .space => {
            if (selection.* < rows.len and rows[selection.*].node.is_dir) {
                try toggleCollapsed(gpa, collapsed, rows[selection.*].node.abs_path);
                return .rows_changed;
            }
            return .none;
        },
        .esc => return .none,
        else => return .none,
    }
}

fn handleSearchKey(
    gpa: std.mem.Allocator,
    search: *render.Search,
    selection: *usize,
    key: term.Key,
) !KeyResult {
    switch (key) {
        .esc => {
            search.query.clearRetainingCapacity();
            search.mode = .normal;
            return .rows_changed;
        },
        .enter => {
            search.mode = .normal;
            return .screen_changed;
        },
        .backspace => {
            if (search.query.items.len > 0) {
                _ = search.query.pop();
                selection.* = 0;
                return .rows_changed;
            }
            // Backspace on an empty query exits search mode (same
            // behaviour as vim / editor search prompts).
            search.mode = .normal;
            selection.* = 0;
            return .screen_changed;
        },
        .char => |c| {
            if (c >= 0x20 and c < 0x7f) {
                try search.query.append(gpa, c);
                selection.* = 0;
                return .rows_changed;
            }
            return .none;
        },
        else => return .none,
    }
}

fn moveSelection(
    selection: *usize,
    scroll: *usize,
    total: usize,
    visible: u16,
    delta: i32,
    jump: bool,
) KeyResult {
    _ = scroll;
    _ = visible;
    _ = jump;
    if (total == 0) return .none;
    const cur: i64 = @intCast(selection.*);
    var nxt: i64 = cur + delta;
    if (nxt < 0) nxt = 0;
    const max: i64 = @intCast(total - 1);
    if (nxt > max) nxt = max;
    const new_sel: usize = @intCast(nxt);
    if (new_sel == selection.*) return .none;
    selection.* = new_sel;
    return .screen_changed;
}

fn moveTo(selection: *usize, target: usize) KeyResult {
    if (selection.* == target) return .none;
    selection.* = target;
    return .screen_changed;
}

fn collapseOrParent(
    gpa: std.mem.Allocator,
    collapsed: *render.Collapsed,
    selection: *usize,
    rows: []const render.VisibleRow,
) !KeyResult {
    if (selection.* >= rows.len) return .none;
    const row = rows[selection.*];
    // On a dir that is open, collapse it in place.
    if (row.node.is_dir and !row.collapsed) {
        try toggleCollapsed(gpa, collapsed, row.node.abs_path);
        return .rows_changed;
    }
    // Otherwise jump to the parent row by scanning backwards for a row
    // with strictly shallower depth.
    if (selection.* == 0) return .none;
    var i: usize = selection.* - 1;
    while (true) : (i -%= 1) {
        if (rows[i].depth < row.depth) {
            selection.* = i;
            return .screen_changed;
        }
        if (i == 0) break;
    }
    return .none;
}

fn expandOrEnter(
    gpa: std.mem.Allocator,
    collapsed: *render.Collapsed,
    selection: usize,
    rows: []const render.VisibleRow,
) !KeyResult {
    if (selection >= rows.len) return .none;
    const row = rows[selection];
    if (row.node.is_dir) {
        if (row.collapsed) {
            try toggleCollapsed(gpa, collapsed, row.node.abs_path);
            return .rows_changed;
        }
        return .none;
    }
    try openPath(gpa, row.node.abs_path);
    return .none;
}

fn ensureSelectionVisible(total: usize, visible: u16, selection: usize, scroll: *usize) void {
    if (total == 0) {
        scroll.* = 0;
        return;
    }
    if (selection < scroll.*) {
        scroll.* = selection;
        return;
    }
    const vis: usize = @intCast(visible);
    if (vis == 0) return;
    if (selection >= scroll.* + vis) {
        scroll.* = selection + 1 - vis;
    }
    clampScroll(total, visible, scroll);
}

fn clampScroll(total: usize, visible: u16, scroll: *usize) void {
    if (total == 0) {
        scroll.* = 0;
        return;
    }
    const vis: usize = @intCast(visible);
    const max_scroll = if (total > vis) total - vis else 0;
    if (scroll.* > max_scroll) scroll.* = max_scroll;
}

fn visibleTreeRows(tm: *const term.Term, _: *const render.Search) u16 {
    const reserved: u16 = render.chromeTopRows(tm.size.rows) + render.chrome_bottom_rows;
    return if (tm.size.rows > reserved) tm.size.rows - reserved else tm.size.rows;
}

fn findByPath(rows: []const render.VisibleRow, path: []const u8) ?usize {
    for (rows, 0..) |r, i| {
        if (std.mem.eql(u8, r.node.abs_path, path)) return i;
    }
    return null;
}

/// Walk `node` recursively, inserting every descendant's abs_path -> is_dir
/// into `out`. Pointers are borrowed from the tree's arena, so the map is
/// only valid until the next tree rebuild.
fn collectPaths(node: *const tree.Node, out: *std.StringHashMap(bool)) !void {
    try out.put(node.abs_path, node.is_dir);
    for (node.children.items) |c| try collectPaths(c, out);
}

/// Compare prev_paths (gpa-owned) against the live tree. Anything in
/// prev but not in the new tree is a deletion: push as a ghost. After
/// the diff, prev_paths is rewritten to mirror the new tree (paths
/// duped into gpa). Mid-tick allocation failures are non-fatal: a
/// failed dupe just leaves a phantom that re-resolves on the next tick.
fn diffPaths(
    gpa: std.mem.Allocator,
    prev_paths: *std.StringHashMap(bool),
    t: *const tree.Tree,
    ghosts: *render.Ghosts,
    now_ms: i64,
) !void {
    var current: std.StringHashMap(bool) = .init(gpa);
    defer current.deinit();
    try collectPaths(t.root, &current);

    var pit = prev_paths.iterator();
    while (pit.next()) |entry| {
        if (!current.contains(entry.key_ptr.*)) {
            ghosts.push(gpa, entry.key_ptr.*, entry.value_ptr.*, now_ms) catch {};
        }
    }

    // Replace prev_paths with current (gpa-duped so it survives the next
    // tree.build's arena reset).
    var pit2 = prev_paths.keyIterator();
    while (pit2.next()) |k| gpa.free(k.*);
    prev_paths.clearRetainingCapacity();
    var cit = current.iterator();
    while (cit.next()) |entry| {
        const dup = try gpa.dupe(u8, entry.key_ptr.*);
        try prev_paths.put(dup, entry.value_ptr.*);
    }
}

fn isHelpKey(k: term.Key) bool {
    return switch (k) {
        .char => |c| c == '?',
        else => false,
    };
}

fn isSettingsKey(k: term.Key) bool {
    return switch (k) {
        .char => |c| c == 's' or c == ',',
        else => false,
    };
}

fn isQuitKey(k: term.Key) bool {
    return switch (k) {
        .char => |c| c == 'q' or c == 3,
        else => false,
    };
}

const SettingsOutcome = struct { close: bool = false, rebuild: bool = false };

/// Returns null when the key is ignored. `close` asks the caller to
/// dismiss the popup; `rebuild` asks it to rebuild the flat row list
/// (set only for settings whose cycle changes tree contents).
fn handleSettingsKey(k: term.Key, cursor: *usize) ?SettingsOutcome {
    switch (k) {
        .esc => return .{ .close = true },
        .char => |c| switch (c) {
            's', ',' => return .{ .close = true },
            'j' => {
                if (cursor.* + 1 < render.num_settings) cursor.* += 1;
                return .{};
            },
            'k' => {
                if (cursor.* > 0) cursor.* -= 1;
                return .{};
            },
            else => return null,
        },
        .up => {
            if (cursor.* > 0) cursor.* -= 1;
            return .{};
        },
        .down => {
            if (cursor.* + 1 < render.num_settings) cursor.* += 1;
            return .{};
        },
        .enter, .space => {
            render.cycleSetting(cursor.*);
            return .{ .rebuild = render.settingAffectsRows(cursor.*) };
        },
        else => return null,
    }
}

noinline fn snapshotPath(buf: []u8, rows: []const render.VisibleRow, selection: usize) usize {
    if (rows.len == 0 or selection >= rows.len) return 0;
    const live = rows[selection].node.abs_path;
    if (live.len > buf.len) return 0;
    // Manual byte copy avoids any memcpy-family intrinsic emission.
    var i: usize = 0;
    while (i < live.len) : (i += 1) buf[i] = live[i];
    return live.len;
}

/// True iff the seetree hook is actually wired into Claude's settings.
/// The script existing at `<claude_dir>/hooks/seetree-refresh.sh` isn't
/// enough; the user might have run `--install-hook` (drops the script
/// + prints JSON to paste) without `--apply` (writes settings.json), so
/// Claude never calls it. We grep settings.json for the hook command
/// string, which is exactly what `--apply` writes. No JSON parser, no
/// allocation: stack buffer for the path, stack buffer for the slurp.
fn hookInstalled(claude_dir: []const u8) bool {
    const suffix = "/settings.json";
    var pathbuf: [1024]u8 = undefined;
    if (claude_dir.len + suffix.len + 1 > pathbuf.len) return false;
    @memcpy(pathbuf[0..claude_dir.len], claude_dir);
    @memcpy(pathbuf[claude_dir.len..][0..suffix.len], suffix);
    pathbuf[claude_dir.len + suffix.len] = 0;

    const fd = std.c.open(@ptrCast(&pathbuf), .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return false;
    defer _ = std.c.close(fd);

    // settings.json is small (kilobytes). 64KB is way more than any real
    // user's config ever contains.
    var buf: [65536]u8 = undefined;
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.c.read(fd, buf[off..].ptr, buf.len - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    return std.mem.indexOf(u8, buf[0..off], hook_command) != null;
}

/// Hand the file or directory off to the user's editor.
///
/// `SEETREE_EDITOR` picks the preset (`zed`, `cursor`, `code`/`vscode`)
/// and defaults to Zed. `SEETREE_OPEN_CMD` is a full-command override
/// that takes precedence; the path is appended as the last arg.
fn openPath(gpa: std.mem.Allocator, path: []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);

    if (std.c.getenv("SEETREE_OPEN_CMD")) |cmd_ptr| {
        const cmd = std.mem.span(cmd_ptr);
        var it = std.mem.tokenizeScalar(u8, cmd, ' ');
        while (it.next()) |tok| try argv.append(gpa, tok);
        try argv.append(gpa, path);
    } else switch (builtin.os.tag) {
        .macos, .maccatalyst, .ios => {
            // `open -a <App>` routes via LaunchServices: works for any
            // file type (bare `open <file>` fails when no default
            // handler is registered, e.g. `.zig`) and opens directories
            // as projects in the editor.
            try argv.append(gpa, "/usr/bin/open");
            try argv.append(gpa, "-a");
            try argv.append(gpa, macAppName());
            try argv.append(gpa, path);
        },
        else => {
            if (linuxEditorBin()) |bin| {
                try argv.append(gpa, bin);
                try argv.append(gpa, path);
            } else {
                try argv.append(gpa, "xdg-open");
                try argv.append(gpa, path);
            }
        },
    }

    // Fire and forget so seetree's TUI stays responsive. Zombies are
    // auto-reaped via SIGCHLD = SA_NOCLDWAIT in term.installSigHandlers.
    posixSpawnDetached(gpa, argv.items) catch {};
}

const c_execvp = @extern(*const fn (file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) callconv(.c) c_int, .{ .name = "execvp" });
const c_unsetenv = @extern(*const fn (name: [*:0]const u8) callconv(.c) c_int, .{ .name = "unsetenv" });
const c_getcwd = @extern(*const fn (buf: [*]u8, size: usize) callconv(.c) ?[*:0]u8, .{ .name = "getcwd" });
const c_NSGetExecutablePath = @extern(*const fn (buf: [*]u8, size: *u32) callconv(.c) c_int, .{ .name = "_NSGetExecutablePath" });
const c_nanosleep = @extern(*const fn (req: *const std.c.timespec, rem: ?*std.c.timespec) callconv(.c) c_int, .{ .name = "nanosleep" });


/// Path to the running executable. macOS-only here (we only need it
/// for spawnWindow, which is mac_like-gated). _NSGetExecutablePath
/// fills the buffer and writes the actual length back into `size`.
fn executablePath(arena: std.mem.Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var size: u32 = buf.len;
    if (c_NSGetExecutablePath(&buf, &size) != 0) return error.PathTooLong;
    const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
    return try arena.dupe(u8, buf[0..len]);
}

/// Basename: everything after the last '/' in `p`, or `p` itself if
/// none. POSIX semantics.
fn basenameOf(p: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return p[i + 1 ..];
    return p;
}

/// std.Io.Writer implementation that drains straight to a raw fd via
/// libc `write`. Skips the full std.Io.File stack so nothing in
/// std.Io.File / std.Io vtable code needs to be emitted for stdout.
const FdWriter = struct {
    fd: c_int,
    interface: std.Io.Writer,

    pub fn init(fd: c_int, buf: []u8) FdWriter {
        return .{
            .fd = fd,
            .interface = .{
                .vtable = &vtable,
                .buffer = buf,
            },
        };
    }

    const vtable: std.Io.Writer.VTable = .{ .drain = drain };

    fn writeAll(fd: c_int, bytes: []const u8) std.Io.Writer.Error!void {
        var p: usize = 0;
        while (p < bytes.len) {
            const n = std.c.write(fd, bytes.ptr + p, bytes.len - p);
            if (n < 0) return error.WriteFailed;
            p += @intCast(n);
        }
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *FdWriter = @alignCast(@fieldParentPtr("interface", w));
        try writeAll(self.fd, w.buffer[0..w.end]);
        w.end = 0;
        if (data.len == 0) return 0;
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            try writeAll(self.fd, slice);
            total += slice.len;
        }
        const last = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            try writeAll(self.fd, last);
            total += last.len;
        }
        return total;
    }
};

/// Monotonic (well, wall-clock) milliseconds since the Unix epoch.
/// Tight replacement for `std.nowMs()`
/// which drags in the full Io vtable for one clock read.
fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return ts.sec * 1000 + @divFloor(ts.nsec, 1_000_000);
}

/// Build a null-terminated argv array on `arena`, duplicating each
/// string with a trailing zero byte. Cheaper than std.process.Child's
/// SpawnOptions construction because it skips the pipe/env/cwd plumbing.
fn argvZ(arena: std.mem.Allocator, argv: []const []const u8) ![*:null]const ?[*:0]const u8 {
    const slice = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |a, i| {
        slice[i] = (try arena.dupeZ(u8, a)).ptr;
    }
    return slice.ptr;
}

fn childSetupNullStdio() void {
    const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR }, @as(c_uint, 0));
    if (devnull < 0) return;
    _ = std.c.dup2(devnull, 0);
    _ = std.c.dup2(devnull, 1);
    _ = std.c.dup2(devnull, 2);
    if (devnull > 2) _ = std.c.close(devnull);
}

/// fork + execvp. Parent returns immediately; child redirects stdio to
/// /dev/null then execs argv[0] via PATH. Caller must have SIGCHLD set
/// to SA_NOCLDWAIT (done in term.installSigHandlers) so zombies don't
/// accumulate.
fn posixSpawnDetached(gpa: std.mem.Allocator, argv: []const []const u8) !void {
    if (argv.len == 0) return;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cargs = try argvZ(arena, argv);
    const pid = std.c.fork();
    if (pid == 0) {
        childSetupNullStdio();
        _ = c_execvp(cargs[0].?, cargs);
        std.c._exit(127);
    }
}

/// fork + execvp + waitpid. Returns the child's exit code (0..255) on
/// normal termination, or -1 on fork failure / abnormal exit. Callers
/// must be able to waitpid (i.e. SIGCHLD not set to SA_NOCLDWAIT).
fn posixSpawnWait(gpa: std.mem.Allocator, argv: []const []const u8) !i32 {
    if (argv.len == 0) return -1;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const cargs = try argvZ(arena, argv);
    const pid = std.c.fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        childSetupNullStdio();
        _ = c_execvp(cargs[0].?, cargs);
        std.c._exit(127);
    }
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) < 0) return -1;
    if ((status & 0x7f) == 0) return @as(i32, (status >> 8) & 0xff);
    return -1;
}

/// Editor key from `SEETREE_EDITOR`, or null if unset / unknown.
fn editorKey() ?[]const u8 {
    const e_ptr = std.c.getenv("SEETREE_EDITOR") orelse return null;
    const e = std.mem.span(e_ptr);
    if (std.mem.eql(u8, e, "zed") or
        std.mem.eql(u8, e, "cursor") or
        std.mem.eql(u8, e, "code") or
        std.mem.eql(u8, e, "vscode")) return e;
    return null;
}

/// macOS `.app` bundle name for LaunchServices (`open -a NAME`).
fn macAppName() []const u8 {
    if (editorKey()) |e| {
        if (std.mem.eql(u8, e, "cursor")) return "Cursor";
        if (std.mem.eql(u8, e, "code") or std.mem.eql(u8, e, "vscode")) return "Visual Studio Code";
    }
    return "Zed";
}

/// Linux CLI binary name. Returns null when `SEETREE_EDITOR` isn't a
/// recognised preset, letting the caller fall back to `xdg-open`.
fn linuxEditorBin() ?[]const u8 {
    const e = editorKey() orelse return null;
    if (std.mem.eql(u8, e, "zed")) return "zed";
    if (std.mem.eql(u8, e, "cursor")) return "cursor";
    if (std.mem.eql(u8, e, "code") or std.mem.eql(u8, e, "vscode")) return "code";
    return null;
}

fn toggleCollapsed(gpa: std.mem.Allocator, set: *render.Collapsed, path: []const u8) !void {
    if (set.fetchRemove(path)) |entry| {
        gpa.free(entry.key);
    } else {
        const dup = try gpa.dupe(u8, path);
        errdefer gpa.free(dup);
        try set.put(dup, {});
    }
}

fn resolveRoot(arena: std.mem.Allocator, dir_arg: ?[]const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (dir_arg) |d| {
        // POSIX absolute: begins with '/'. On macOS/Linux that's all we care about.
        if (d.len > 0 and d[0] == '/') return try arena.dupe(u8, d);
        const cwd_ptr = c_getcwd(&buf, buf.len) orelse return error.GetCwdFailed;
        const cwd = std.mem.span(cwd_ptr);
        const out = try arena.alloc(u8, cwd.len + 1 + d.len);
        @memcpy(out[0..cwd.len], cwd);
        out[cwd.len] = '/';
        @memcpy(out[cwd.len + 1 ..], d);
        return out;
    }
    const cwd_ptr = c_getcwd(&buf, buf.len) orelse return error.GetCwdFailed;
    return try arena.dupe(u8, std.mem.span(cwd_ptr));
}

const WindowMode = enum { detach, side };
const mac_like = builtin.os.tag == .macos or builtin.os.tag == .maccatalyst;

fn spawnWindow(
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    env: *std.process.Environ.Map,
    root_path: []const u8,
    mode: WindowMode,
) !void {
    if (comptime !mac_like) {
        logErr(&.{"--detach/--side are macOS-only; Ghostty + osascript required"});
        return error.UnsupportedOs;
    } else {
        // Belt-and-suspenders against the spawn loop: --no-auto-side is the
        // primary recursion break, but if it ever stops being parsed we still
        // strip the env var that triggers auto-side in the child.
        _ = env.swapRemove("CLAUDE_CODE_ENTRYPOINT");

        const self_path = try executablePath(arena);

        // Build the shell command Ghostty will run in the new window. Single-quote
        // each path so spaces survive sh -c. Single quotes inside paths get the
        // standard '\'' escape.
        var cmd_buf: std.ArrayList(u8) = .empty;
        try shellQuote(&cmd_buf, arena, self_path);
        try cmd_buf.append(arena, ' ');
        try shellQuote(&cmd_buf, arena, root_path);
        try cmd_buf.appendSlice(arena, " --no-auto-side");

        // Build the AppleScript. We tell the running Ghostty (via its own
        // AppleScript dictionary) to either:
        //   - .side: split the focused terminal of the front window to the right.
        //     Truly side-by-side with claude in the same window. No System
        //     Events / accessibility needed.
        //   - .detach: open a new standalone window.
        //
        // Either way it's a single op against the running Ghostty, so no
        // `open -na`, no second instance, no saved-state restore.
        var script: std.ArrayList(u8) = .empty;
        try script.appendSlice(arena,
            \\tell application "Ghostty"
            \\    set cfg to new surface configuration
            \\    set command of cfg to "
        );
        try appleScriptEscape(&script, arena, cmd_buf.items);
        try script.appendSlice(arena, "\"\n");
        switch (mode) {
            .side => try script.appendSlice(arena,
                \\    set t to focused terminal of selected tab of front window
                \\    split t direction right with configuration cfg
                \\end tell
                \\
            ),
            .detach => try script.appendSlice(arena,
                \\    new window with configuration cfg
                \\end tell
                \\
            ),
        }

        // Break the auto-side recursion by clearing the inherited env
        // var. Our posixSpawnWait uses execvp which inherits environ as
        // of the fork, so direct unsetenv is both cheaper and correct.
        // The Zig-side env map was swapRemoved above as belt-and-braces.
        _ = c_unsetenv("CLAUDE_CODE_ENTRYPOINT");

        const osa_argv = [_][]const u8{ "/usr/bin/osascript", "-e", script.items };
        const code = posixSpawnWait(gpa, &osa_argv) catch {
            logErr(&.{"couldn't run osascript; install Ghostty or use --once"});
            return error.GhosttySpawnFailed;
        };
        if (code != 0) {
            logErr(&.{"ghostty spawn failed; is Ghostty running?"});
            return error.GhosttySpawnFailed;
        }
    }
}

fn shellQuote(buf: *std.ArrayList(u8), arena: std.mem.Allocator, s: []const u8) !void {
    try buf.append(arena, '\'');
    for (s) |c| {
        if (c == '\'') {
            try buf.appendSlice(arena, "'\\''");
        } else {
            try buf.append(arena, c);
        }
    }
    try buf.append(arena, '\'');
}

fn appleScriptEscape(buf: *std.ArrayList(u8), arena: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(arena, "\\\\"),
            '"' => try buf.appendSlice(arena, "\\\""),
            else => try buf.append(arena, c),
        }
    }
}

const hook_script =
    \\#!/bin/sh
    \\# Installed by `seetree --install-hook`. Pings every running seetree
    \\# instance so it rebuilds the tree immediately instead of waiting on
    \\# its 200ms poll. Always exits 0 so the hook never blocks Claude.
    \\PIDS=$(pgrep -x seetree 2>/dev/null) || exit 0
    \\for pid in $PIDS; do kill -USR1 "$pid" 2>/dev/null; done
    \\exit 0
    \\
;

const hook_command = "~/.claude/hooks/seetree-refresh.sh";

/// Write `<claude_dir>/hooks/seetree-refresh.sh`, creating the parent
/// directories as needed. chmods the script 0755. Returns the hooks
/// dir path (allocated on `arena`). Pure libc: no std.Io.File or
/// std.Io.Dir machinery.
fn writeHookScript(arena: std.mem.Allocator, claude_dir: []const u8) ![]const u8 {
    const hooks_dir = try arena.alloc(u8, claude_dir.len + "/hooks".len);
    @memcpy(hooks_dir[0..claude_dir.len], claude_dir);
    @memcpy(hooks_dir[claude_dir.len..], "/hooks");

    // mkdir each level. EEXIST is fine.
    try mkdirP(claude_dir);
    try mkdirP(hooks_dir);

    // Open + truncate + write + chmod.
    const script_path = try arena.alloc(u8, hooks_dir.len + "/seetree-refresh.sh".len);
    @memcpy(script_path[0..hooks_dir.len], hooks_dir);
    @memcpy(script_path[hooks_dir.len..], "/seetree-refresh.sh");

    const fd = try openCreate(script_path, 0o755);
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < hook_script.len) {
        const n = std.c.write(fd, hook_script.ptr + off, hook_script.len - off);
        if (n < 0) return error.WriteFailed;
        off += @intCast(n);
    }
    return hooks_dir;
}

/// `mkdir(path, 0755)` ignoring EEXIST. Caller must NUL-terminate via
/// `arena`-allocated buffer; we copy onto the stack for the syscall.
fn mkdirP(path: []const u8) !void {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len > z.len - 1) return error.NameTooLong;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const rc = std.c.mkdir(@ptrCast(&z), 0o755);
    if (rc < 0) {
        const err = std.c._errno().*;
        if (err != 17) return error.MkdirFailed; // 17 = EEXIST on macOS+Linux
    }
}

fn openCreate(path: []const u8, mode: c_uint) !c_int {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len > z.len - 1) return error.NameTooLong;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fd = std.c.open(@ptrCast(&z), .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, mode);
    if (fd < 0) return error.OpenFailed;
    return fd;
}

fn installHook(arena: std.mem.Allocator, out: *std.Io.Writer, claude_dir: []const u8) !void {
    const hooks_dir = try writeHookScript(arena, claude_dir);

    try out.writeAll("wrote ");
    try out.writeAll(hooks_dir);
    try out.writeAll("/seetree-refresh.sh\n\n");
    try out.writeAll(
        \\Add this to ~/.claude/settings.json under "hooks" (or re-run with
        \\--install-hook --apply to let seetree splice it in for you):
        \\
        \\  "FileChanged": [
        \\    {
        \\      "matcher": ".*",
        \\      "hooks": [
        \\        {
        \\          "type": "command",
        \\          "command": "~/.claude/hooks/seetree-refresh.sh",
        \\          "timeout": 2000
        \\        }
        \\      ]
        \\    }
        \\  ]
        \\
        \\Then reload claude. seetree will refresh on every file change Claude
        \\watches instead of waiting on its 200ms poll.
        \\
    );
}

const fresh_settings_json =
    \\{
    \\  "hooks": {
    \\    "FileChanged": [
    \\      {
    \\        "matcher": ".*",
    \\        "hooks": [
    \\          {
    \\            "type": "command",
    \\            "command": "~/.claude/hooks/seetree-refresh.sh",
    \\            "timeout": 2000
    \\          }
    \\        ]
    \\      }
    \\    ]
    \\  }
    \\}
    \\
;

/// Like installHook, but also wires the hook into ~/.claude/settings.json
/// when it's safe to do so without a full JSON parser (the parser costs
/// ~50KB of binary that we don't want to drag in for a one-shot
/// command). Behaviour:
///
///   missing or trivially empty (`{}` / whitespace): write fresh JSON
///   already contains the hook command string: idempotent no-op
///   has other content: refuse and print the snippet to paste
fn applyHook(arena: std.mem.Allocator, out: *std.Io.Writer, claude_dir: []const u8) !void {
    const hooks_dir = try writeHookScript(arena, claude_dir);
    // The Claude Code config root is the parent of `hooks_dir`
    // (stripped trailing "/hooks").
    const claude_dir_path = hooks_dir[0 .. hooks_dir.len - "/hooks".len];

    // Build absolute paths to settings.json and its backup.
    const settings_path = try arena.alloc(u8, claude_dir_path.len + "/settings.json".len);
    @memcpy(settings_path[0..claude_dir_path.len], claude_dir_path);
    @memcpy(settings_path[claude_dir_path.len..], "/settings.json");
    const bak_path = try arena.alloc(u8, claude_dir_path.len + "/settings.json.bak".len);
    @memcpy(bak_path[0..claude_dir_path.len], claude_dir_path);
    @memcpy(bak_path[claude_dir_path.len..], "/settings.json.bak");

    // Slurp existing settings.json if present.
    const existing = readFileAlloc(arena, settings_path) catch null;

    if (existing) |bytes| {
        if (std.mem.indexOf(u8, bytes, hook_command) != null) {
            try out.writeAll("hook already wired in ");
            try out.writeAll(settings_path);
            try out.writeAll("\n");
            return;
        }
        if (!isTriviallyEmpty(bytes)) {
            try out.writeAll(settings_path);
            try out.writeAll(
                \\ has other content; refusing to edit without a JSON
                \\parser. Paste the snippet below under the top-level "hooks"
                \\key yourself, or move settings.json aside and re-run
                \\`seetree --install-hook --apply` to regenerate it.
                \\
                \\
            );
            try out.writeAll(paste_snippet);
            return;
        }
        // Trivially empty; rename old to .bak before overwriting.
        try renamePath(settings_path, bak_path);
    }

    try writeFileAll(settings_path, fresh_settings_json);
    if (existing != null) {
        try out.writeAll("wired hook into ");
        try out.writeAll(settings_path);
        try out.writeAll(" (backup at ");
        try out.writeAll(bak_path);
        try out.writeAll(")\n");
    } else {
        try out.writeAll("wrote ");
        try out.writeAll(settings_path);
        try out.writeAll(" with the seetree hook\n");
    }
    try out.writeAll("reload claude for the hook to take effect.\n");
}

/// `open(O_RDONLY) + read all + close`. Returns null on FileNotFound,
/// errors on anything else. Caps at 1MB which is plenty for a settings
/// file.
fn readFileAlloc(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len > z.len - 1) return error.NameTooLong;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const fd = std.c.open(@ptrCast(&z), .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return error.FileNotFound;
    defer _ = std.c.close(fd);
    const size: usize = @intCast(sys.fileSize(fd) orelse return error.StatFailed);
    const buf = try arena.alloc(u8, size);
    var off: usize = 0;
    while (off < size) {
        const n = std.c.read(fd, buf.ptr + off, size - off);
        if (n <= 0) break;
        off += @intCast(n);
    }
    return buf[0..off];
}

fn writeFileAll(path: []const u8, data: []const u8) !void {
    const fd = try openCreate(path, 0o644);
    defer _ = std.c.close(fd);
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data.ptr + off, data.len - off);
        if (n < 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

fn renamePath(old: []const u8, new: []const u8) !void {
    var zo: [std.fs.max_path_bytes + 1]u8 = undefined;
    var zn: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (old.len > zo.len - 1 or new.len > zn.len - 1) return error.NameTooLong;
    @memcpy(zo[0..old.len], old);
    zo[old.len] = 0;
    @memcpy(zn[0..new.len], new);
    zn[new.len] = 0;
    if (std.c.rename(@ptrCast(&zo), @ptrCast(&zn)) != 0) return error.RenameFailed;
}

/// True for a file that's empty, whitespace-only, or just `{}` padded
/// by whitespace. Anything else is treated as "has content, don't
/// clobber" by applyHook.
fn isTriviallyEmpty(bytes: []const u8) bool {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    return trimmed.len == 0 or std.mem.eql(u8, trimmed, "{}");
}

const paste_snippet =
    \\  "FileChanged": [
    \\    {
    \\      "matcher": ".*",
    \\      "hooks": [
    \\        {
    \\          "type": "command",
    \\          "command": "~/.claude/hooks/seetree-refresh.sh",
    \\          "timeout": 2000
    \\        }
    \\      ]
    \\    }
    \\  ]
    \\
;

fn listProjects(gpa: std.mem.Allocator, out: *std.Io.Writer, claude_dir: []const u8) !void {
    const suffix = "/projects";
    const projects_dir = try gpa.alloc(u8, claude_dir.len + suffix.len);
    defer gpa.free(projects_dir);
    @memcpy(projects_dir[0..claude_dir.len], claude_dir);
    @memcpy(projects_dir[claude_dir.len..], suffix);

    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (projects_dir.len > z.len - 1) return;
    @memcpy(z[0..projects_dir.len], projects_dir);
    z[projects_dir.len] = 0;

    const dir = std.c.opendir(@ptrCast(&z)) orelse {
        try out.writeAll("no projects directory at ");
        try out.writeAll(projects_dir);
        try out.writeAll("\n");
        return;
    };
    defer _ = std.c.closedir(dir);

    const Entry = struct { path: []const u8, mtime_sec: isize, mtime_nsec: isize };
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |e| gpa.free(e.path);
        entries.deinit(gpa);
    }

    while (std.c.readdir(dir)) |entry| {
        if (entry.type != 4) continue; // DT_DIR
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);
        if (name.len == 0 or name[0] == '.') continue;

        const sub_path = try projectSubdir(gpa, projects_dir, name);
        defer gpa.free(sub_path);

        const newest = newestJsonlIn(sub_path) orelse continue;
        const path = readCwdFromJsonl(gpa, sub_path, newest.name[0..newest.name_len]) catch
            try fallbackPath(gpa, name);

        try entries.append(gpa, .{
            .path = path,
            .mtime_sec = newest.sec,
            .mtime_nsec = newest.nsec,
        });
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.mtime_sec != b.mtime_sec) return a.mtime_sec > b.mtime_sec;
            return a.mtime_nsec > b.mtime_nsec;
        }
    }.lt);

    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const now_sec: isize = @intCast(ts.sec);
    for (entries.items, 0..) |e, i| {
        try writeRightPadDec(out, @as(u32, @intCast(i + 1)), 3);
        try out.writeAll("  ");
        try formatAgoSecs(out, now_sec - e.mtime_sec);
        try out.writeAll("  ");
        try out.writeAll(e.path);
        try out.writeAll("\n");
    }
}

fn projectSubdir(gpa: std.mem.Allocator, parent: []const u8, name: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, parent.len + 1 + name.len);
    @memcpy(out[0..parent.len], parent);
    out[parent.len] = '/';
    @memcpy(out[parent.len + 1 ..][0..name.len], name);
    return out;
}

const NewestJsonl = struct {
    name: [256]u8,
    name_len: usize,
    sec: isize,
    nsec: isize,
};

fn newestJsonlIn(dir_path: []const u8) ?NewestJsonl {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (dir_path.len > z.len - 1) return null;
    @memcpy(z[0..dir_path.len], dir_path);
    z[dir_path.len] = 0;
    const dir = std.c.opendir(@ptrCast(&z)) orelse return null;
    defer _ = std.c.closedir(dir);

    var best: ?NewestJsonl = null;
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(path_buf[0..dir_path.len], dir_path);
    path_buf[dir_path.len] = '/';

    while (std.c.readdir(dir)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);
        if (name.len < 6 or !std.mem.endsWith(u8, name, ".jsonl")) continue;

        const total = dir_path.len + 1 + name.len;
        if (total >= path_buf.len) continue;
        @memcpy(path_buf[dir_path.len + 1 ..][0..name.len], name);
        path_buf[total] = 0;

        const mt = sys.statMtime(@ptrCast(&path_buf)) orelse continue;
        const sec = mt.sec;
        const nsec = mt.nsec;

        const newer = if (best) |b| (sec > b.sec or (sec == b.sec and nsec > b.nsec)) else true;
        if (!newer) continue;
        if (name.len > 256) continue;

        var n: NewestJsonl = .{ .name = undefined, .name_len = name.len, .sec = sec, .nsec = nsec };
        @memcpy(n.name[0..name.len], name);
        best = n;
    }
    return best;
}

fn readCwdFromJsonl(gpa: std.mem.Allocator, dir_path: []const u8, file_name: []const u8) ![]u8 {
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    const total = dir_path.len + 1 + file_name.len;
    if (total > z.len - 1) return error.NameTooLong;
    @memcpy(z[0..dir_path.len], dir_path);
    z[dir_path.len] = '/';
    @memcpy(z[dir_path.len + 1 ..][0..file_name.len], file_name);
    z[total] = 0;

    const fd = std.c.open(@ptrCast(&z), .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);

    var buf: [8192]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return error.ReadFailed;
    const bytes = buf[0..@intCast(n)];

    const needle = "\"cwd\":\"";
    const idx = std.mem.indexOf(u8, bytes, needle) orelse return error.NoCwd;
    const start = idx + needle.len;
    const end = std.mem.indexOfScalarPos(u8, bytes, start, '"') orelse return error.NoCwd;
    return try gpa.dupe(u8, bytes[start..end]);
}

fn fallbackPath(gpa: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, encoded.len);
    for (encoded, 0..) |c, i| out[i] = if (c == '-') '/' else c;
    return out;
}

fn formatAgoSecs(w: *std.Io.Writer, secs: isize) !void {
    const s: u64 = if (secs < 0) 0 else @intCast(secs);
    if (s < 60) {
        try writeRightPadDec(w, @intCast(s), 3);
        return w.writeAll("s ago");
    }
    const m = s / 60;
    if (m < 60) {
        try writeRightPadDec(w, @intCast(m), 3);
        return w.writeAll("m ago");
    }
    const h = m / 60;
    if (h < 24) {
        try writeRightPadDec(w, @intCast(h), 3);
        return w.writeAll("h ago");
    }
    const d = h / 24;
    try writeRightPadDec(w, @intCast(d), 3);
    return w.writeAll("d ago");
}

fn writeRightPadDec(w: *std.Io.Writer, n: u32, width: u8) !void {
    var buf: [10]u8 = undefined;
    var i: usize = buf.len;
    var x = n;
    if (x == 0) {
        i -= 1;
        buf[i] = '0';
    } else while (x > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(x % 10));
        x /= 10;
    }
    const used = buf.len - i;
    if (used < width) {
        var pad = width - used;
        while (pad > 0) : (pad -= 1) try w.writeAll(" ");
    }
    try w.writeAll(buf[i..]);
}

