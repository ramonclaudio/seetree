const std = @import("std");
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;
const tree = @import("tree.zig");
const session = @import("session.zig");
const term = @import("term.zig");

/// Set of directory abs_paths the user has collapsed. Owned by main's
/// runLive loop (paths duped via gpa so they survive tree rebuilds).
pub const Collapsed = std.StringHashMap(void);

/// Flat representation of the tree after applying collapse + search
/// filters. Re-built whenever the tree, collapsed set, or search query
/// changes. Selection and scroll are indices into this list so keyboard
/// nav and mouse clicks both become O(1).
pub const VisibleRow = struct {
    node: *const tree.Node,
    depth: u16,
    is_last: bool,
    /// Pre-rendered indent prefix ("│ │   " etc), borrowed from the
    /// flatten arena. Empty for the root row.
    prefix: []const u8,
    /// True if this dir is currently collapsed. Only meaningful for dirs.
    collapsed: bool,
    /// True if this is the project root (special bold styling).
    is_root: bool = false,
};

pub const Mode = enum { normal, search };

pub const Search = struct {
    mode: Mode = .normal,
    query: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Search, gpa: Allocator) void {
        self.query.deinit(gpa);
    }

    pub fn active(self: *const Search) bool {
        return self.query.items.len > 0;
    }
};

/// A file/dir that was in the previous tree snapshot but isn't in the
/// current one (i.e. just got deleted). Stays in the row list with a
/// `[Delete]` badge for `fresh_window_ms`, then drops away.
pub const Ghost = struct {
    abs_path: []const u8, // gpa-owned
    name: []const u8, // points into abs_path
    deleted_at_ms: i64,
    is_dir: bool,
};

pub const Ghosts = struct {
    list: std.ArrayList(Ghost) = .empty,

    pub fn deinit(self: *Ghosts, gpa: Allocator) void {
        for (self.list.items) |g| gpa.free(g.abs_path);
        self.list.deinit(gpa);
    }

    pub fn push(self: *Ghosts, gpa: Allocator, abs_path: []const u8, is_dir: bool, now_ms: i64) !void {
        // Skip if we already track this path; a re-create wipes it elsewhere.
        for (self.list.items) |g| if (std.mem.eql(u8, g.abs_path, abs_path)) return;
        const dup = try gpa.dupe(u8, abs_path);
        const slash = std.mem.lastIndexOfScalar(u8, dup, '/');
        const name: []const u8 = if (slash) |i| dup[i + 1 ..] else dup;
        try self.list.append(gpa, .{
            .abs_path = dup,
            .name = name,
            .deleted_at_ms = now_ms,
            .is_dir = is_dir,
        });
    }

    /// Drop ghosts older than `fresh_window_ms`; also drop any whose path
    /// reappeared in the live tree (caller passes the new path set).
    pub fn prune(
        self: *Ghosts,
        gpa: Allocator,
        now_ms: i64,
        live_paths: *const std.StringHashMap(bool),
    ) void {
        var i: usize = 0;
        while (i < self.list.items.len) {
            const g = self.list.items[i];
            const expired = now_ms - g.deleted_at_ms >= fresh_window_ms;
            const reborn = live_paths.contains(g.abs_path);
            if (expired or reborn) {
                gpa.free(g.abs_path);
                _ = self.list.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }
};

const Style = struct {
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";
    const bold = "\x1b[1m";
    const bg_reset = "\x1b[49m";
    /// Clear from cursor to end-of-line using current bg color.
    const clear_eol = "\x1b[K";
};

/// Colorway. Everything beyond the basic control codes lives here so a
/// user can pick a theme at startup.
pub const Theme = struct {
    /// Selection bar background (keeps per-node fg colors readable).
    sel_bg: []const u8,
    /// In-flight tool category colors.
    cat_write: []const u8,
    cat_read: []const u8,
    cat_exec: []const u8,
    cat_other: []const u8,
    /// Most-recently-touched file, idle (fresh window closed).
    recent: []const u8,
    /// Tracked files/dirs (any session touch ever).
    tracked_file: []const u8,
    tracked_dir: []const u8,
    /// Untouched files/dirs.
    untouched_file: []const u8,
    untouched_dir: []const u8,
    /// Search match highlight inside names.
    match: []const u8,
    /// Project root row.
    root: []const u8,
    /// +N and -N diff chips (shown only inside the freshness window).
    plus: []const u8,
    minus: []const u8,
    /// Chevron glyph.
    chevron: []const u8,
    /// Trailing trivia (· touch count, brackets around badges).
    dim_text: []const u8,
    /// Rounded border around the live view (and mascot).
    border: []const u8,
    /// Tree-guy mascot foliage.
    mascot_leaf: []const u8,
    /// Tree-guy mascot trunk.
    mascot_trunk: []const u8,
};

pub const themes = struct {
    // Default. Salmon accents (Claude Code's rgb(215,119,87)) on a neutral
    // grey base. Border, active dirs, root, match, chevron, and mascot
    // all pick up the warmth.
    pub const claude: Theme = .{
        .sel_bg = "\x1b[48;5;238m",
        .cat_write = "\x1b[1;38;2;215;119;87m",
        .cat_read = "\x1b[1;38;2;230;166;134m",
        .cat_exec = "\x1b[1;38;2;200;180;160m",
        .cat_other = "\x1b[1;38;2;230;166;134m",
        .recent = "\x1b[1;38;2;230;150;110m",
        .tracked_file = "\x1b[38;5;252m",
        .tracked_dir = "\x1b[1;38;2;215;119;87m",
        .untouched_file = "\x1b[38;5;244m",
        .untouched_dir = "\x1b[1;38;5;244m",
        .match = "\x1b[1;38;2;255;180;130m",
        .root = "\x1b[1;38;2;215;119;87m",
        .plus = "\x1b[38;2;160;200;140m",
        .minus = "\x1b[38;2;215;119;87m",
        .chevron = "\x1b[38;2;215;119;87m",
        .dim_text = "\x1b[2m",
        .border = "\x1b[38;2;215;119;87m",
        .mascot_leaf = "\x1b[38;2;215;119;87m",
        .mascot_trunk = "\x1b[38;2;176;98;71m",
    };
    // Pure greyscale. No accent colors, just brightness ramps.
    pub const mono: Theme = .{
        .sel_bg = "\x1b[48;5;238m",
        .cat_write = "\x1b[1;97m",
        .cat_read = "\x1b[1;97m",
        .cat_exec = "\x1b[1;97m",
        .cat_other = "\x1b[1;97m",
        .recent = "\x1b[1;252m",
        .tracked_file = "\x1b[38;5;252m",
        .tracked_dir = "\x1b[1;38;5;252m",
        .untouched_file = "\x1b[38;5;244m",
        .untouched_dir = "\x1b[1;38;5;244m",
        .match = "\x1b[7m",
        .root = "\x1b[1;97m",
        .plus = "\x1b[38;5;250m",
        .minus = "\x1b[38;5;244m",
        .chevron = "\x1b[2m",
        .dim_text = "\x1b[2m",
        .border = "\x1b[38;5;244m",
        .mascot_leaf = "\x1b[38;5;252m",
        .mascot_trunk = "\x1b[38;5;244m",
    };
    pub const nord: Theme = .{
        .sel_bg = "\x1b[48;5;17m",
        .cat_write = "\x1b[1;38;5;174m",
        .cat_read = "\x1b[1;38;5;109m",
        .cat_exec = "\x1b[1;38;5;108m",
        .cat_other = "\x1b[1;38;5;179m",
        .recent = "\x1b[1;38;5;141m",
        .tracked_file = "\x1b[38;5;253m",
        .tracked_dir = "\x1b[1;38;5;253m",
        .untouched_file = "\x1b[38;5;240m",
        .untouched_dir = "\x1b[1;38;5;240m",
        .match = "\x1b[1;38;5;179m",
        .root = "\x1b[1;38;5;253m",
        .plus = "\x1b[38;5;108m",
        .minus = "\x1b[38;5;174m",
        .chevron = "\x1b[2;38;5;109m",
        .dim_text = "\x1b[2;38;5;240m",
        .border = "\x1b[38;5;109m",
        .mascot_leaf = "\x1b[38;5;108m",
        .mascot_trunk = "\x1b[38;5;137m",
    };
    pub const dracula: Theme = .{
        .sel_bg = "\x1b[48;5;53m",
        .cat_write = "\x1b[1;38;5;210m",
        .cat_read = "\x1b[1;38;5;117m",
        .cat_exec = "\x1b[1;38;5;157m",
        .cat_other = "\x1b[1;38;5;215m",
        .recent = "\x1b[1;38;5;141m",
        .tracked_file = "\x1b[38;5;255m",
        .tracked_dir = "\x1b[1;38;5;255m",
        .untouched_file = "\x1b[38;5;245m",
        .untouched_dir = "\x1b[1;38;5;245m",
        .match = "\x1b[1;38;5;228m",
        .root = "\x1b[1;38;5;255m",
        .plus = "\x1b[38;5;157m",
        .minus = "\x1b[38;5;210m",
        .chevron = "\x1b[2;38;5;103m",
        .dim_text = "\x1b[2;38;5;103m",
        .border = "\x1b[38;5;141m",
        .mascot_leaf = "\x1b[38;5;157m",
        .mascot_trunk = "\x1b[38;5;180m",
    };
    pub const gruvbox: Theme = .{
        .sel_bg = "\x1b[48;5;237m",
        .cat_write = "\x1b[1;38;5;167m",
        .cat_read = "\x1b[1;38;5;109m",
        .cat_exec = "\x1b[1;38;5;142m",
        .cat_other = "\x1b[1;38;5;214m",
        .recent = "\x1b[1;38;5;175m",
        .tracked_file = "\x1b[38;5;223m",
        .tracked_dir = "\x1b[1;38;5;223m",
        .untouched_file = "\x1b[38;5;244m",
        .untouched_dir = "\x1b[1;38;5;244m",
        .match = "\x1b[1;38;5;214m",
        .root = "\x1b[1;38;5;223m",
        .plus = "\x1b[38;5;142m",
        .minus = "\x1b[38;5;167m",
        .chevron = "\x1b[2;38;5;246m",
        .dim_text = "\x1b[2;38;5;246m",
        .border = "\x1b[38;5;208m",
        .mascot_leaf = "\x1b[38;5;142m",
        .mascot_trunk = "\x1b[38;5;172m",
    };
    pub const tokyo_night: Theme = .{
        .sel_bg = "\x1b[48;5;60m",
        .cat_write = "\x1b[1;38;5;203m",
        .cat_read = "\x1b[1;38;5;111m",
        .cat_exec = "\x1b[1;38;5;114m",
        .cat_other = "\x1b[1;38;5;179m",
        .recent = "\x1b[1;38;5;140m",
        .tracked_file = "\x1b[38;5;189m",
        .tracked_dir = "\x1b[1;38;5;189m",
        .untouched_file = "\x1b[38;5;243m",
        .untouched_dir = "\x1b[1;38;5;243m",
        .match = "\x1b[1;38;5;179m",
        .root = "\x1b[1;38;5;189m",
        .plus = "\x1b[38;5;114m",
        .minus = "\x1b[38;5;203m",
        .chevron = "\x1b[2;38;5;61m",
        .dim_text = "\x1b[2;38;5;243m",
        .border = "\x1b[38;5;111m",
        .mascot_leaf = "\x1b[38;5;114m",
        .mascot_trunk = "\x1b[38;5;180m",
    };
    pub const catppuccin: Theme = .{
        .sel_bg = "\x1b[48;5;60m",
        .cat_write = "\x1b[1;38;5;211m",
        .cat_read = "\x1b[1;38;5;116m",
        .cat_exec = "\x1b[1;38;5;151m",
        .cat_other = "\x1b[1;38;5;222m",
        .recent = "\x1b[1;38;5;183m",
        .tracked_file = "\x1b[38;5;224m",
        .tracked_dir = "\x1b[1;38;5;224m",
        .untouched_file = "\x1b[38;5;244m",
        .untouched_dir = "\x1b[1;38;5;244m",
        .match = "\x1b[1;38;5;222m",
        .root = "\x1b[1;38;5;224m",
        .plus = "\x1b[38;5;151m",
        .minus = "\x1b[38;5;211m",
        .chevron = "\x1b[2;38;5;103m",
        .dim_text = "\x1b[2;38;5;244m",
        .border = "\x1b[38;5;211m",
        .mascot_leaf = "\x1b[38;5;151m",
        .mascot_trunk = "\x1b[38;5;180m",
    };
    pub const rose_pine: Theme = .{
        .sel_bg = "\x1b[48;5;59m",
        .cat_write = "\x1b[1;38;5;174m",
        .cat_read = "\x1b[1;38;5;109m",
        .cat_exec = "\x1b[1;38;5;108m",
        .cat_other = "\x1b[1;38;5;179m",
        .recent = "\x1b[1;38;5;132m",
        .tracked_file = "\x1b[38;5;252m",
        .tracked_dir = "\x1b[1;38;5;252m",
        .untouched_file = "\x1b[38;5;245m",
        .untouched_dir = "\x1b[1;38;5;245m",
        .match = "\x1b[1;38;5;179m",
        .root = "\x1b[1;38;5;252m",
        .plus = "\x1b[38;5;108m",
        .minus = "\x1b[38;5;174m",
        .chevron = "\x1b[2;38;5;102m",
        .dim_text = "\x1b[2;38;5;245m",
        .border = "\x1b[38;5;174m",
        .mascot_leaf = "\x1b[38;5;108m",
        .mascot_trunk = "\x1b[38;5;137m",
    };
    pub const solarized: Theme = .{
        .sel_bg = "\x1b[48;5;19m",
        .cat_write = "\x1b[1;38;5;160m",
        .cat_read = "\x1b[1;38;5;33m",
        .cat_exec = "\x1b[1;38;5;64m",
        .cat_other = "\x1b[1;38;5;136m",
        .recent = "\x1b[1;38;5;125m",
        .tracked_file = "\x1b[38;5;230m",
        .tracked_dir = "\x1b[1;38;5;230m",
        .untouched_file = "\x1b[38;5;241m",
        .untouched_dir = "\x1b[1;38;5;241m",
        .match = "\x1b[1;38;5;136m",
        .root = "\x1b[1;38;5;230m",
        .plus = "\x1b[38;5;64m",
        .minus = "\x1b[38;5;160m",
        .chevron = "\x1b[2;38;5;66m",
        .dim_text = "\x1b[2;38;5;241m",
        .border = "\x1b[38;5;136m",
        .mascot_leaf = "\x1b[38;5;64m",
        .mascot_trunk = "\x1b[38;5;94m",
    };
};

const theme_order = [_]struct { name: []const u8, ptr: *const Theme }{
    .{ .name = "claude", .ptr = &themes.claude },
    .{ .name = "mono", .ptr = &themes.mono },
    .{ .name = "gruvbox", .ptr = &themes.gruvbox },
    .{ .name = "nord", .ptr = &themes.nord },
    .{ .name = "dracula", .ptr = &themes.dracula },
    .{ .name = "tokyo-night", .ptr = &themes.tokyo_night },
    .{ .name = "catppuccin", .ptr = &themes.catppuccin },
    .{ .name = "rose-pine", .ptr = &themes.rose_pine },
    .{ .name = "solarized", .ptr = &themes.solarized },
};

/// Active theme. Swapped at startup by setThemeByName() or at runtime
/// via cycleTheme() (the settings popup). Defaults to claude.
pub var current: *const Theme = &themes.claude;

pub fn setThemeByName(name: []const u8) bool {
    for (theme_order) |t| {
        if (std.mem.eql(u8, t.name, name)) {
            current = t.ptr;
            return true;
        }
    }
    return false;
}

pub fn cycleTheme() []const u8 {
    var idx: usize = 0;
    for (theme_order, 0..) |t, i| {
        if (t.ptr == current) {
            idx = i;
            break;
        }
    }
    const next = (idx + 1) % theme_order.len;
    current = theme_order[next].ptr;
    return theme_order[next].name;
}

pub fn themeName() []const u8 {
    for (theme_order) |t| {
        if (t.ptr == current) return t.name;
    }
    return "claude";
}

const clear_screen = "\x1b[2J";
const cursor_home = "\x1b[H";
const clear_line = "\x1b[2K";

/// How long after a touch the `[Bash]` / `[Edit]` / `[Read]` chip and
/// diff counts stay visible. This is the whole point of the highlight:
/// it fades fast so "just now" looks different from "touched earlier".
/// Exposed as a `var` so the settings popup can cycle it live.
pub var fresh_window_ms: i64 = 3000;

/// How often runLive rebuilds the tree from disk. main.zig reads this
/// every tick, so cycling it in the settings popup takes effect on the
/// next poll without restarting.
pub var tree_poll_ms: i64 = 2000;

/// Walk the tree applying collapse state and (optionally) a search
/// filter, returning a flat list of rows ready to render. Strings in
/// each row (the indent prefix) are allocated out of the provided
/// arena; caller owns the slice.
pub fn collectRows(
    arena: Allocator,
    t: *const tree.Tree,
    collapsed: *const Collapsed,
    search: *const Search,
) Allocator.Error![]VisibleRow {
    var rows: std.ArrayList(VisibleRow) = .empty;

    // If a search is active, first compute the set of nodes to keep:
    // every match plus all its ancestors (so context survives the
    // filter). Stored as a set of node pointers.
    var keep_set: ?std.AutoHashMap(*const tree.Node, void) = null;
    defer if (keep_set) |*k| k.deinit();
    if (search.active()) {
        keep_set = .init(arena);
        try collectSearchKeep(&keep_set.?, t.root, search.query.items);
    }

    const root_coll = collapsed.contains(t.root.abs_path);
    if (keep_set == null or keep_set.?.contains(t.root)) {
        try rows.append(arena, .{
            .node = t.root,
            .depth = 0,
            .is_last = true,
            .prefix = "",
            .collapsed = root_coll,
            .is_root = true,
        });
    }
    if (root_coll) return rows.toOwnedSlice(arena);
    try appendChildren(arena, &rows, t.root, "", 1, collapsed, if (keep_set) |*k| k else null);
    return rows.toOwnedSlice(arena);
}

fn appendChildren(
    arena: Allocator,
    rows: *std.ArrayList(VisibleRow),
    parent: *const tree.Node,
    parent_prefix: []const u8,
    depth: u16,
    collapsed: *const Collapsed,
    keep: ?*std.AutoHashMap(*const tree.Node, void),
) Allocator.Error!void {
    const children = parent.children.items;
    // When searching, filter siblings down to those we're keeping; last
    // marker is computed after filtering so the tree branch glyphs stay
    // correct.
    var visible: std.ArrayList(*tree.Node) = .empty;
    defer visible.deinit(arena);
    for (children) |c| {
        if (keep) |k| {
            if (!k.contains(c)) continue;
        }
        try visible.append(arena, c);
    }

    for (visible.items, 0..) |child, i| {
        const is_last = i == visible.items.len - 1;
        try rows.append(arena, .{
            .node = child,
            .depth = depth,
            .is_last = is_last,
            .prefix = parent_prefix,
            .collapsed = child.is_dir and collapsed.contains(child.abs_path),
        });
        if (child.is_dir and !collapsed.contains(child.abs_path) and child.children.items.len > 0) {
            const suffix = if (is_last) "   " else "│  ";
            const child_prefix = try std.mem.concat(arena, u8, &.{ parent_prefix, suffix });
            try appendChildren(arena, rows, child, child_prefix, depth + 1, collapsed, keep);
        }
    }
}

fn collectSearchKeep(
    keep: *std.AutoHashMap(*const tree.Node, void),
    node: *const tree.Node,
    query: []const u8,
) Allocator.Error!void {
    for (node.children.items) |child| {
        const matched = containsCaseInsensitive(child.name, query);
        const before = keep.count();
        if (matched) try keep.put(child, {});
        if (child.is_dir) try collectSearchKeep(keep, child, query);
        // If we added descendants or matched ourselves, the chain of
        // ancestors up to the root needs to be visible too.
        if (matched or keep.count() != before) {
            try keep.put(child, {});
            try keep.put(node, {});
        }
    }
}

fn containsCaseInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (lower(haystack[i + j]) != lower(needle[j])) break;
        }
        if (j == needle.len) return true;
    }
    return false;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

pub fn drawOnce(
    w: *Writer,
    gpa: Allocator,
    _: []const u8,
    t: *const tree.Tree,
    s: ?*const session.Session,
) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var empty: Collapsed = .init(gpa);
    defer empty.deinit();
    var empty_search: Search = .{};
    defer empty_search.deinit(gpa);

    const rows = try collectRows(arena, t, &empty, &empty_search);
    for (rows) |row| {
        try renderRow(w, row, s, std.math.maxInt(i64), false, "", std.math.maxInt(u16));
        try w.writeByte('\n');
    }
}

// Full top chrome: border (1) + blank (1) + 4-row mascot (4) + blank (1).
// Compact top chrome (used when the terminal is short): just the border.
const chrome_top_full: u16 = 7;
const chrome_top_compact: u16 = 1;
/// Terminal height below which the mascot strip is dropped and the tree
/// starts right under the top border.
const compact_rows_threshold: u16 = 16;

/// How many rows of chrome sit above the tree area for a given terminal
/// height. Drops the mascot on short terminals so the tree stays useful.
pub fn chromeTopRows(rows: u16) u16 {
    return if (rows >= compact_rows_threshold) chrome_top_full else chrome_top_compact;
}

// Box bottom border (1) + status row (1).
pub const chrome_bottom_rows: u16 = 2;
pub const version: []const u8 = "v0.1.1";

/// 4-row tree-guy mascot rendered into the top of the box. Rows 0-2 are
/// foliage (mascot_leaf); row 3 is the trunk (mascot_trunk).
const mascot_rows = 4;
const mascot_width: u16 = 9;
const mascot = [mascot_rows][]const u8{
    "   ▄█▄   ",
    "  ▄███▄  ",
    " ▄█████▄ ",
    "    █    ",
};

pub fn drawLive(
    w: *Writer,
    tm: *const term.Term,
    root_path: []const u8,
    home: []const u8,
    rows: []const VisibleRow,
    s: ?*const session.Session,
    selection: usize,
    scroll: usize,
    search: *const Search,
    now_ms: i64,
    show_help: bool,
    show_settings: bool,
    settings_cursor: usize,
    ghosts: *const Ghosts,
) !void {
    try w.writeAll(cursor_home ++ clear_screen);

    const total_rows = tm.size.rows;
    const total_cols = tm.size.cols;
    const chrome_top = chromeTopRows(total_rows);
    const reserved: u16 = chrome_top + chrome_bottom_rows;
    const tree_rows: usize = if (total_rows > reserved) total_rows - reserved else 0;

    // Top border with title.
    try drawBoxTop(w, root_path, home, total_cols);

    // Full chrome renders the mascot strip; compact chrome skips it.
    if (chrome_top == chrome_top_full) try drawMascotStrip(w, total_cols);

    const tree_first: u16 = chrome_top + 1;

    if (rows.len == 0 and search.active()) {
        // Fill the whole tree area with empty box rows, then overlay the
        // centered "no match" message.
        var r: u16 = tree_first;
        const last_row: u16 = chrome_top + @as(u16, @intCast(tree_rows));
        while (r <= last_row) : (r += 1) try drawBoxEmptyRow(w, r, total_cols);
        try drawEmptySearch(w, tm, chrome_top, tree_rows, search.query.items);
    } else {
        var end = scroll + tree_rows;
        if (end > rows.len) end = rows.len;
        var i: usize = scroll;
        var screen_row: u16 = tree_first;
        while (i < end) : (i += 1) {
            try drawTreeRow(w, screen_row, total_cols, rows[i], s, now_ms, i == selection, search.query.items);
            screen_row += 1;
        }
        const last_row: u16 = chrome_top + @as(u16, @intCast(tree_rows));
        // Spill ghost rows into whatever space the live tree didn't fill.
        // Newest first so a quick succession of deletes shows the most
        // recent ones even if the budget is tight.
        var gi: usize = ghosts.list.items.len;
        while (gi > 0 and screen_row <= last_row) {
            gi -= 1;
            try drawGhostRow(w, screen_row, total_cols, ghosts.list.items[gi], now_ms);
            screen_row += 1;
        }
        while (screen_row <= last_row) : (screen_row += 1) {
            try drawBoxEmptyRow(w, screen_row, total_cols);
        }
    }

    // Bottom border sits on the row just above the status line.
    if (total_rows >= 2) try drawBoxBottom(w, total_rows - 1, total_cols);

    // Popups overlay the whole box.
    if (show_help) try drawHelp(w, tm);
    if (show_settings) try drawSettings(w, tm, settings_cursor);

    // Status / search prompt on the very last row, outside the box.
    if (total_rows >= 1) {
        try moveCursor(w, total_rows, 1);
        try w.writeAll(clear_line);
        if (search.mode == .search) {
            try drawSearchPrompt(w, tm.size.cols, search.query.items);
        } else {
            try drawStatusBar(w, tm.size.cols, show_help, show_settings);
        }
    }
    try w.flush();
}

/// Render `/query` on the last row. Truncates with a leading `…` so
/// the cursor end (where the user is typing) always stays visible.
fn drawSearchPrompt(w: *Writer, cols: u16, query: []const u8) !void {
    try w.writeAll("  ");
    try w.writeAll(current.dim_text);
    try w.writeAll("/");
    try w.writeAll(Style.reset);
    const prefix_cols: u16 = 3; // "  /"
    const avail: u16 = if (cols > prefix_cols) cols - prefix_cols else 0;
    const q_cols = nameCols(query);
    if (q_cols <= avail) {
        try w.writeAll(query);
    } else if (avail >= 2) {
        try w.writeAll("…");
        const tail_cols = avail - 1;
        // Drop bytes from the front until what's left fits.
        var skip = q_cols - tail_cols;
        var i: usize = 0;
        while (skip > 0 and i < query.len) : (skip -= 1) {
            const b = query[i];
            const step: usize = if (b < 0x80) 1 else if (b < 0xc0) 1 else if (b < 0xe0) 2 else if (b < 0xf0) 3 else 4;
            i = @min(i + step, query.len);
        }
        try w.writeAll(query[i..]);
    }
}

/// Draw the rounded top border with the title ("seetree v0.1.1 · ~/path")
/// embedded between `╭─` and the trailing dashes. Path truncates with a
/// leading `…` when narrow; drops entirely when even shorter.
fn drawBoxTop(w: *Writer, root_path: []const u8, home: []const u8, cols: u16) !void {
    try moveCursor(w, 1, 1);
    try w.writeAll(clear_line);

    // Tilde-fold the home prefix; path_cols is the cell count of the
    // displayed form ("~/...").
    const use_tilde = home.len > 0 and std.mem.startsWith(u8, root_path, home);
    const path_str = if (use_tilde) root_path[home.len..] else root_path;
    const path_cols: u16 = @intCast((if (use_tilde) @as(usize, 1) else 0) + path_str.len);

    // Title forms in priority order. Each "fixed" is the cell count the
    // form needs without the path itself.
    //   full:    "╭─ seetree v0.1.1 · path "         + "╮"
    //   no_path: "╭─ seetree v0.1.1 "                + "╮"
    //   no_ver:  "╭─ seetree "                       + "╮"
    //   bare:    "╭"                                 + "╮"  (just dashes)
    const fixed_no_path: u16 = 3 + 8 + @as(u16, @intCast(version.len)) + 1 + 1;
    const fixed_with_path: u16 = fixed_no_path + 3;
    const fixed_no_ver: u16 = 3 + 7 + 1 + 1; // "╭─ " + "seetree" + " " + "╮"
    const fixed_bare: u16 = 2; // "╭" + "╮"

    const TitleMode = enum { full, truncated, no_path, no_ver, bare };
    var mode: TitleMode = .bare;
    var path_visible_cols: u16 = 0;
    if (cols >= fixed_with_path + path_cols) {
        mode = .full;
    } else if (cols >= fixed_with_path + 2) {
        mode = .truncated;
        path_visible_cols = cols - fixed_with_path; // includes "…"
    } else if (cols >= fixed_no_path) {
        mode = .no_path;
    } else if (cols >= fixed_no_ver) {
        mode = .no_ver;
    } else if (cols < fixed_bare) {
        // Nothing useful to draw.
        return;
    }

    try w.writeAll(current.border);
    try w.writeAll("╭");
    var used: u16 = 1;
    if (mode != .bare) {
        try w.writeAll("─ ");
        used += 2;
        try w.writeAll(Style.reset);
        try w.writeAll(current.tracked_file);
        try w.writeAll("seetree");
        used += 7;
        if (mode == .full or mode == .truncated or mode == .no_path) {
            try w.writeAll(" ");
            try w.writeAll(version);
            used += 1 + @as(u16, @intCast(version.len));
        }
        try w.writeAll(Style.reset);
    }

    if (mode == .full or mode == .truncated) {
        try w.writeAll(current.dim_text);
        try w.writeAll(" · ");
        used += 3;
        if (mode == .truncated) {
            try w.writeAll("…");
            const tail_cols: u16 = path_visible_cols - 1;
            const start = path_str.len -| @as(usize, tail_cols);
            try w.writeAll(path_str[start..]);
            used += path_visible_cols;
        } else {
            if (use_tilde) try w.writeAll("~");
            try w.writeAll(path_str);
            used += path_cols;
        }
        try w.writeAll(Style.reset);
    }

    try w.writeAll(current.border);
    if (mode != .bare) {
        try w.writeAll(" ");
        used += 1;
    }
    const dash_count: u16 = if (cols > used + 1) cols - used - 1 else 0;
    try writeRepeat(w, "─", dash_count);
    // Always anchor the top-right corner at the last column.
    try moveCursor(w, 1, cols);
    try w.writeAll(current.border);
    try w.writeAll("╮");
    try w.writeAll(Style.reset);
}

fn drawBoxBottom(w: *Writer, row: u16, cols: u16) !void {
    try moveCursor(w, row, 1);
    try w.writeAll(clear_line);
    try w.writeAll(current.border);
    try w.writeAll("╰");
    if (cols > 2) try writeRepeat(w, "─", cols - 2);
    try moveCursor(w, row, cols);
    try w.writeAll("╯");
    try w.writeAll(Style.reset);
}

/// Render an otherwise-empty row inside the box: `│` on the left edge,
/// `│` on the right edge, nothing between.
fn drawBoxEmptyRow(w: *Writer, row: u16, cols: u16) !void {
    try moveCursor(w, row, 1);
    try w.writeAll(clear_line);
    try w.writeAll(current.border);
    try w.writeAll("│");
    try w.writeAll(Style.reset);
    try moveCursor(w, row, cols);
    try w.writeAll(current.border);
    try w.writeAll("│");
    try w.writeAll(Style.reset);
}

/// Rows 2..7 inside the box: blank, mascot × 4, blank. Mascot is
/// left-aligned just inside the border + 2-col margin; each row's
/// non-space cells get leaf/trunk color.
fn drawMascotStrip(w: *Writer, cols: u16) !void {
    // Row 2: blank padding above the mascot.
    try drawBoxEmptyRow(w, 2, cols);

    // Skip the mascot glyph entirely when the box is too narrow.
    const have_room = cols > mascot_width + 4;
    // Border (col 1) + 2-col margin (cols 2-3) -> mascot starts at col 4.
    const mascot_start_col: u16 = 4;

    var i: usize = 0;
    while (i < mascot_rows) : (i += 1) {
        const screen_row: u16 = 3 + @as(u16, @intCast(i));
        try drawBoxEmptyRow(w, screen_row, cols);
        if (!have_room) continue;
        try moveCursor(w, screen_row, mascot_start_col);
        const color = if (i < mascot_rows - 1) current.mascot_leaf else current.mascot_trunk;
        try w.writeAll(color);
        try w.writeAll(mascot[i]);
        try w.writeAll(Style.reset);
    }

    // Blank padding between mascot and first tree row.
    try drawBoxEmptyRow(w, chrome_top_full, cols);
}

/// Render a ghost (recently-deleted) row inside the box borders. The
/// styling intentionally diverges from drawTreeRow: no chevron, no tint
/// from the session, dim leading "× " in the minus color, the basename
/// struck through, and a `[Delete]` chip. Fades to dim_text after
/// fresh_window_ms / 2.
fn drawGhostRow(
    w: *Writer,
    screen_row: u16,
    cols: u16,
    g: Ghost,
    now_ms: i64,
) !void {
    try moveCursor(w, screen_row, 1);
    try w.writeAll(clear_line);
    try w.writeAll(current.border);
    try w.writeAll("│");
    try w.writeAll(Style.reset);

    // Body. 2-col left margin to match tree rows.
    try w.writeAll("  ");

    const half = @divTrunc(fresh_window_ms, 2);
    const aged = now_ms - g.deleted_at_ms >= half;
    const tint = if (aged) current.dim_text else current.minus;

    try w.writeAll(tint);
    try w.writeAll("× ");
    // Strike-through (SGR 9) on the name; many terminals render it.
    try w.writeAll("\x1b[9m");
    try w.writeAll(g.name);
    if (g.is_dir) try w.writeByte('/');
    try w.writeAll("\x1b[29m");
    try w.writeAll(" ");
    try w.writeAll(current.dim_text);
    try w.writeAll("[Delete]");
    try w.writeAll(Style.reset);

    try moveCursor(w, screen_row, cols);
    try w.writeAll(current.border);
    try w.writeAll("│");
    try w.writeAll(Style.reset);
}

/// Render a single tree row wrapped in the box borders. Left border at
/// col 1, tree content via `renderRow`, then `│` at the right edge.
fn drawTreeRow(
    w: *Writer,
    screen_row: u16,
    cols: u16,
    row: VisibleRow,
    s: ?*const session.Session,
    now_ms: i64,
    selected: bool,
    query: []const u8,
) !void {
    try moveCursor(w, screen_row, 1);
    try w.writeAll(clear_line);
    try w.writeAll(current.border);
    try w.writeAll("│");
    try w.writeAll(Style.reset);

    try renderRow(w, row, s, now_ms, selected, query, cols);

    try moveCursor(w, screen_row, cols);
    try w.writeAll(current.border);
    try w.writeAll("│");
    try w.writeAll(Style.reset);
}

pub const num_settings: usize = 4;

pub const SettingRow = struct {
    label: []const u8,
    value: []const u8,
};

fn settingRow(i: usize) SettingRow {
    return switch (i) {
        0 => .{ .label = "theme", .value = themeName() },
        1 => .{ .label = "poll rate", .value = pollLabel() },
        2 => .{ .label = "fade", .value = freshLabel() },
        3 => .{ .label = "hidden files", .value = if (tree.show_hidden) "show" else "hide" },
        else => .{ .label = "", .value = "" },
    };
}

fn pollLabel() []const u8 {
    return switch (tree_poll_ms) {
        500 => "500 ms",
        1000 => "1 s",
        2000 => "2 s",
        5000 => "5 s",
        10000 => "10 s",
        30000 => "30 s",
        else => "custom",
    };
}

fn freshLabel() []const u8 {
    return switch (fresh_window_ms) {
        500 => "500 ms",
        1000 => "1 s",
        3000 => "3 s",
        5000 => "5 s",
        10000 => "10 s",
        else => "custom",
    };
}

fn cyclePoll() void {
    tree_poll_ms = switch (tree_poll_ms) {
        500 => 1000,
        1000 => 2000,
        2000 => 5000,
        5000 => 10000,
        10000 => 30000,
        30000 => 500,
        else => 2000,
    };
}

fn cycleFresh() void {
    fresh_window_ms = switch (fresh_window_ms) {
        500 => 1000,
        1000 => 3000,
        3000 => 5000,
        5000 => 10000,
        10000 => 500,
        else => 3000,
    };
}

pub fn drawSettings(w: *Writer, tm: *const term.Term, cursor: usize) !void {
    const min_inner: u16 = 18; // "settings" title + some slack
    const natural_inner: u16 = 38;
    // Terminal too tiny to hold the popup at all, bail.
    if (tm.size.cols < min_inner + 2 or tm.size.rows < 3) return;

    // Shrink to fit. Width caps at the natural size; height drops rows
    // as needed (blank padding, hint, separator) before giving up.
    const inner: u16 = @min(natural_inner, tm.size.cols -| 2);
    const width: u16 = inner + 2;
    const budget_rows: u16 = tm.size.rows -| 2;
    const show_blank = budget_rows >= 3 + num_settings + 2;
    const show_hint = budget_rows >= 3 + num_settings + 1;
    const show_sep = show_hint;
    const reserve: u16 = @as(u16, 2) +
        @as(u16, @intFromBool(show_blank)) +
        @as(u16, @intFromBool(show_sep)) +
        @as(u16, @intFromBool(show_hint));
    const visible_items: u16 = @min(@as(u16, num_settings), budget_rows -| reserve);
    const height: u16 = 2 + @as(u16, @intFromBool(show_blank)) + visible_items +
        @as(u16, @intFromBool(show_sep)) + @as(u16, @intFromBool(show_hint));
    const origin_row: u16 = (tm.size.rows - height) / 2 + 1;
    const origin_col: u16 = (tm.size.cols - width) / 2 + 1;

    var row: u16 = origin_row;

    // Top border with title. Truncate the title if the popup got narrow.
    try moveCursor(w, row, origin_col);
    try w.writeAll(current.dim_text);
    if (inner >= 11) {
        try w.writeAll("┌─ settings ");
        try writeRepeat(w, "─", inner - 11);
    } else {
        try w.writeAll("┌");
        try writeRepeat(w, "─", inner);
    }
    try w.writeAll("┐");
    try w.writeAll(Style.reset);
    row += 1;

    if (show_blank) {
        try drawBoxBlank(w, row, origin_col, inner);
        row += 1;
    }

    // Keep the selected row visible by scrolling the item list.
    var first_item: u16 = 0;
    if (visible_items < num_settings) {
        const cur: u16 = @intCast(cursor);
        if (cur >= visible_items) first_item = cur - visible_items + 1;
    }
    var i: u16 = first_item;
    while (i < first_item + visible_items and i < num_settings) : (i += 1) {
        const item = settingRow(i);
        try drawSettingItem(w, row, origin_col, inner, item, i == cursor);
        row += 1;
    }

    if (show_sep) {
        try moveCursor(w, row, origin_col);
        try w.writeAll(current.dim_text);
        try w.writeAll("├");
        try writeRepeat(w, "─", inner);
        try w.writeAll("┤");
        try w.writeAll(Style.reset);
        row += 1;
    }

    if (show_hint) {
        const hint_full = "  j/k move   enter cycle   esc close";
        const hint_short = "  j/k  enter  esc";
        const hint = if (inner >= visibleWidth(hint_full)) hint_full else hint_short;
        const hint_used: u16 = 1 + visibleWidth(hint);
        try moveCursor(w, row, origin_col);
        try w.writeAll(current.dim_text);
        try w.writeAll("│");
        if (visibleWidth(hint) <= inner) {
            try w.writeAll(hint);
            if (hint_used < inner + 1) try writeRepeat(w, " ", inner + 1 - hint_used);
        } else {
            try writeRepeat(w, " ", inner);
        }
        try w.writeAll("│");
        try w.writeAll(Style.reset);
        row += 1;
    }

    // Bottom border.
    try moveCursor(w, row, origin_col);
    try w.writeAll(current.dim_text);
    try w.writeAll("└");
    try writeRepeat(w, "─", inner);
    try w.writeAll("┘");
    try w.writeAll(Style.reset);
}

fn drawBoxBlank(w: *Writer, row: u16, col: u16, inner: u16) !void {
    try moveCursor(w, row, col);
    try w.writeAll(current.dim_text);
    try w.writeAll("│");
    try w.writeAll(Style.reset);
    try writeRepeat(w, " ", inner);
    try w.writeAll(current.dim_text);
    try w.writeAll("│");
    try w.writeAll(Style.reset);
}

fn drawSettingItem(
    w: *Writer,
    row: u16,
    col: u16,
    inner: u16,
    item: SettingRow,
    selected: bool,
) !void {
    try moveCursor(w, row, col);
    try w.writeAll(current.dim_text);
    try w.writeAll("│");
    try w.writeAll(Style.reset);
    if (selected) try w.writeAll(current.sel_bg);
    try w.writeAll(" ");
    try w.writeAll(if (selected) "›" else " ");
    try w.writeAll(" ");
    try w.writeAll(item.label);
    // pad label column to fixed width so values align.
    const label_col: u16 = 12;
    if (item.label.len < label_col) try writeRepeat(w, " ", label_col - @as(u16, @intCast(item.label.len)));
    try w.writeAll(current.tracked_file);
    try w.writeAll(item.value);
    try w.writeAll(Style.reset);
    if (selected) try w.writeAll(current.sel_bg);
    // pad to inner width.
    const used: u16 = 3 + label_col + @as(u16, @intCast(item.value.len));
    if (used < inner) try writeRepeat(w, " ", inner - used);
    if (selected) try w.writeAll(Style.reset);
    try w.writeAll(current.dim_text);
    try w.writeAll("│");
    try w.writeAll(Style.reset);
}

pub fn cycleSetting(i: usize) void {
    switch (i) {
        0 => _ = cycleTheme(),
        1 => cyclePoll(),
        2 => cycleFresh(),
        3 => tree.show_hidden = !tree.show_hidden,
        else => {},
    }
}

/// True if cycling setting `i` requires rebuilding the row list (i.e.
/// the tree contents change). Only the hidden-files toggle qualifies;
/// the rest are visual only.
pub fn settingAffectsRows(i: usize) bool {
    return i == 3;
}

fn moveCursor(w: *Writer, row: u16, col: u16) !void {
    try w.writeAll("\x1b[");
    try writeU32(w, @intCast(row));
    try w.writeByte(';');
    try writeU32(w, @intCast(col));
    try w.writeByte('H');
}

fn writeRepeat(w: *Writer, s: []const u8, n: u16) !void {
    var i: u16 = 0;
    while (i < n) : (i += 1) try w.writeAll(s);
}

const help_lines = [_][]const u8{
    "j / k           move down / up",
    "g / G           top / bottom",
    "PgUp / PgDn     page up / page down",
    "h / l           collapse / expand",
    "space           toggle collapse on dir",
    "enter           open in editor",
    "/               search  (backspace empty to exit)",
    "s               settings popup",
    "t               cycle theme",
    "?               this help",
    "q  ctrl-c       quit",
    "",
    "click name      open in editor",
    "click chevron   toggle collapse",
    "scroll wheel    scroll the tree",
};

/// Render the help panel as a centered box, matching the settings
/// popup style.
/// Centered "nothing matched" placeholder shown while search is active
/// but the query filters every row away. Keeps the tree area from
/// looking broken/empty.
fn drawEmptySearch(
    w: *Writer,
    tm: *const term.Term,
    chrome_top: u16,
    tree_rows: usize,
    query: []const u8,
) !void {
    const prefix = "no match for ";
    const prefix_len = prefix.len;
    const total_len = prefix_len + 1 + query.len + 1; // prefix "query"
    // Center vertically within the tree area (which begins after the box
    // chrome), and horizontally within the terminal.
    const offset: u16 = @intCast(@max(@as(usize, 1), tree_rows / 2));
    const mid_row: u16 = chrome_top + offset;
    const mid_col: u16 = if (tm.size.cols > total_len)
        @intCast((tm.size.cols - total_len) / 2)
    else
        2;
    try moveCursor(w, mid_row, mid_col);
    try w.writeAll(current.dim_text);
    try w.writeAll(prefix);
    try w.writeAll("\"");
    try w.writeAll(query);
    try w.writeAll("\"");
    try w.writeAll(Style.reset);
}

fn drawHelp(w: *Writer, tm: *const term.Term) !void {
    const natural_inner: u16 = 56;
    const min_inner: u16 = 20;
    if (tm.size.cols < min_inner + 2 or tm.size.rows < 3) return;

    const inner: u16 = @min(natural_inner, tm.size.cols -| 2);
    const width: u16 = inner + 2;
    const budget_rows: u16 = tm.size.rows -| 2;
    const natural_body: u16 = @intCast(help_lines.len);
    // Structure budget: top (1) + optional blank (1) + body + optional sep+hint (2) + bottom (1).
    const show_blank = budget_rows >= natural_body + 5;
    const show_hint = budget_rows >= 2 + 1 + 2 + 1; // top + at least 1 body + sep + hint + bottom
    const show_sep = show_hint;
    const reserve: u16 = @as(u16, 2) +
        @as(u16, @intFromBool(show_blank)) +
        @as(u16, @intFromBool(show_sep)) +
        @as(u16, @intFromBool(show_hint));
    const body_budget: u16 = budget_rows -| reserve;
    const body_rows: u16 = @min(natural_body, body_budget);
    const height: u16 = 2 + @as(u16, @intFromBool(show_blank)) + body_rows +
        @as(u16, @intFromBool(show_sep)) + @as(u16, @intFromBool(show_hint));
    const origin_row: u16 = (tm.size.rows - height) / 2 + 1;
    const origin_col: u16 = (tm.size.cols - width) / 2 + 1;

    var row: u16 = origin_row;

    // Top border with title. Truncate the title label when narrow.
    try moveCursor(w, row, origin_col);
    try w.writeAll(current.dim_text);
    if (inner >= 7) {
        try w.writeAll("┌─ help ");
        try writeRepeat(w, "─", inner - 7);
    } else {
        try w.writeAll("┌");
        try writeRepeat(w, "─", inner);
    }
    try w.writeAll("┐");
    try w.writeAll(Style.reset);
    row += 1;

    if (show_blank) {
        try drawBoxBlank(w, row, origin_col, inner);
        row += 1;
    }

    var drawn: u16 = 0;
    for (help_lines) |line| {
        if (drawn >= body_rows) break;
        try moveCursor(w, row, origin_col);
        try w.writeAll(current.dim_text);
        try w.writeAll("│ ");
        try w.writeAll(Style.reset);
        try w.writeAll(current.tracked_file);
        // Truncate long lines to fit the current inner width (inner - 1
        // columns of usable text after the leading space).
        const cw = visibleWidth(line);
        const usable: u16 = inner -| 1;
        if (cw <= usable) {
            try w.writeAll(line);
            if (cw + 1 < inner) try writeRepeat(w, " ", inner - cw - 1);
        } else {
            try w.writeAll(line[0..usable]);
        }
        try w.writeAll(Style.reset);
        try w.writeAll(current.dim_text);
        try w.writeAll("│");
        try w.writeAll(Style.reset);
        row += 1;
        drawn += 1;
    }

    if (show_sep) {
        try moveCursor(w, row, origin_col);
        try w.writeAll(current.dim_text);
        try w.writeAll("├");
        try writeRepeat(w, "─", inner);
        try w.writeAll("┤");
        try w.writeAll(Style.reset);
        row += 1;
    }

    if (show_hint) {
        const hint_full = "  any key closes";
        const hint_short = "  any key";
        const hint = if (inner >= visibleWidth(hint_full)) hint_full else hint_short;
        const hint_cw: u16 = visibleWidth(hint);
        try moveCursor(w, row, origin_col);
        try w.writeAll(current.dim_text);
        try w.writeAll("│");
        if (hint_cw <= inner) {
            try w.writeAll(hint);
            if (hint_cw < inner) try writeRepeat(w, " ", inner - hint_cw);
        } else {
            try writeRepeat(w, " ", inner);
        }
        try w.writeAll("│");
        try w.writeAll(Style.reset);
        row += 1;
    }

    // Bottom.
    try moveCursor(w, row, origin_col);
    try w.writeAll(current.dim_text);
    try w.writeAll("└");
    try writeRepeat(w, "─", inner);
    try w.writeAll("┘");
    try w.writeAll(Style.reset);
}

/// Display width (in terminal columns) of a static UTF-8 string.
/// Handles the specific glyphs we actually render: box drawing, arrows,
/// triangles, middle dots, em-dash. The arrow + triangle ranges count
/// as 2 columns because most modern terminals (Ghostty, iTerm2, Kitty
/// with default font config) render them as wide glyphs.
fn visibleWidth(s: []const u8) u16 {
    var n: u16 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        const step: usize = if (b < 0x80) 1 else if (b < 0xc0) 1 else if (b < 0xe0) 2 else if (b < 0xf0) 3 else 4;
        const end = @min(i + step, s.len);
        n += glyphCols(s[i..end]);
        i = end;
    }
    return n;
}

fn glyphCols(_: []const u8) u16 {
    // Every codepoint in the static text we ship (ASCII, box drawing,
    // middle dot, em-dash) renders as 1 display column in the
    // terminals we target. Arrows and geometric-shape triangles are
    // East-Asian-Width "Ambiguous" and render differently per
    // terminal/font, so we keep those out of padded text (see
    // help_lines and the settings popup hint).
    return 1;
}

// Hint candidates, longest first. drawStatusBar picks the first one
// whose width fits the terminal. Theme name lives in the settings
// popup, so the status row is hints-only now.
const overlay_hints = [_][]const u8{
    "  esc to close",
    "  esc",
};
const normal_hints = [_][]const u8{
    "  s settings  ·  / search  ·  ? help  ·  q quit",
    "  s  ·  /  ·  ?  ·  q",
    "  ? help",
    "  ?",
};

fn drawStatusBar(w: *Writer, cols: u16, show_help: bool, show_settings: bool) !void {
    const hints: []const []const u8 = if (show_help or show_settings)
        &overlay_hints
    else
        &normal_hints;
    for (hints) |h| {
        if (nameCols(h) <= cols) {
            try w.writeAll(current.dim_text);
            try w.writeAll(h);
            try w.writeAll(Style.reset);
            return;
        }
    }
}

/// Map a click row (1-indexed screen row) to a row index in the visible
/// list, given the current scroll. Returns null if the click falls
/// outside the rendered tree area.
pub fn rowIndexAt(
    screen_row: u16,
    rows: []const VisibleRow,
    scroll: usize,
    tm: *const term.Term,
    _: *const Search,
) ?usize {
    const chrome_top = chromeTopRows(tm.size.rows);
    const reserved: u16 = chrome_top + chrome_bottom_rows;
    const tree_rows: u16 = if (tm.size.rows > reserved) tm.size.rows - reserved else 0;
    const tree_first: u16 = chrome_top + 1;
    if (tree_rows == 0) return null;
    const tree_last: u16 = tree_first + tree_rows - 1;
    if (screen_row < tree_first or screen_row > tree_last) return null;
    const idx = scroll + @as(usize, screen_row - tree_first);
    if (idx >= rows.len) return null;
    return idx;
}

/// The column of the collapse/expand chevron for a given row, 1-indexed.
/// 0 means no chevron (the row is a file).
///
/// Layout: 1-col left border, 2-col left margin, then per level 3 cols of
/// prefix ("│  " or "   "), then a 3-col branch glyph ("├─ " / "└─ "),
/// then chevron. For the root row there is no branch; chevron sits
/// right after border + margin.
pub fn chevronCol(row: VisibleRow) u16 {
    if (!row.node.is_dir) return 0;
    if (row.is_root) return 4;
    // border (1) + margin (2) + prefix ((depth-1)*3) + branch (3) + 1
    return 3 + (row.depth - 1) * 3 + 3 + 1;
}

pub const NameRange = struct { start: u16, end: u16 };

/// Inclusive column range occupied by the row's clickable name. Used by
/// the click handler to only open files when the user clicks the text
/// itself, not whitespace or tree glyphs.
pub fn nameColRange(row: VisibleRow) NameRange {
    const name_len: u16 = @intCast(row.node.name.len);
    const trailing_slash: u16 = if (row.node.is_dir) 1 else 0;
    const start: u16 = if (row.is_root)
        // border (1) + margin (2) + chevron (1) + space (1) = col 6
        6
    else if (row.node.is_dir)
        // border + margin + prefix + branch + chevron + space
        3 + (row.depth - 1) * 3 + 3 + 2
    else
        // border + margin + prefix + branch (trailing space absorbed by
        // the branch glyph)
        3 + (row.depth - 1) * 3 + 3 + 1;
    return .{ .start = start, .end = start + name_len + trailing_slash - 1 };
}

/// Cursor column where the row's name begins. Cells consumed before
/// the name plus 1 (cols are 1-indexed).
fn nameStartCol(row: VisibleRow) u16 {
    if (row.is_root) return 6; // border(1) + margin(2) + chevron(1) + space(1) + 1
    const base: u16 = 1 + 2 + (row.depth - 1) * 3 + 3; // border + margin + prefix + branch
    return 1 + base + (if (row.node.is_dir) @as(u16, 2) else 0);
}

/// Visible columns of `s` assuming each codepoint is 1 col (matches
/// `glyphCols`). Sufficient for ASCII-dominant file names.
fn nameCols(s: []const u8) u16 {
    var n: u16 = 0;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        const step: usize = if (b < 0x80) 1 else if (b < 0xc0) 1 else if (b < 0xe0) 2 else if (b < 0xf0) 3 else 4;
        i = @min(i + step, s.len);
        n += 1;
    }
    return n;
}

/// Byte length of the longest UTF-8 prefix of `s` whose visible width
/// fits in `max_cols`. Won't split a codepoint.
fn nameTake(s: []const u8, max_cols: u16) usize {
    if (max_cols == 0) return 0;
    var i: usize = 0;
    var cols: u16 = 0;
    while (i < s.len) {
        const b = s[i];
        const step: usize = if (b < 0x80) 1 else if (b < 0xc0) 1 else if (b < 0xe0) 2 else if (b < 0xf0) 3 else 4;
        if (cols + 1 > max_cols) break;
        i = @min(i + step, s.len);
        cols += 1;
    }
    return i;
}

fn decimalCols(n: u32) u16 {
    if (n == 0) return 1;
    var w: u16 = 0;
    var x = n;
    while (x > 0) : (w += 1) x /= 10;
    return w;
}

/// Total visible cols the trailing freshness chips would occupy:
/// optional ` +A -R` (mutations only) plus optional ` [Cat]`. After a
/// Read the +A -R from the previous edit would be misleading, so we
/// suppress the diff chip on .read.
fn chipsCols(fi: session.FileInfo) u16 {
    var w: u16 = 0;
    if (showDiffChip(fi)) {
        w += 2 + decimalCols(fi.lines_added);
        w += 2 + decimalCols(fi.lines_removed);
    }
    if (fi.last_cat orelse fi.dominantCat()) |cat| {
        w += 3 + @as(u16, @intCast(categoryLabel(cat).len)); // " [Cat]"
    }
    return w;
}

fn showDiffChip(fi: session.FileInfo) bool {
    if (fi.lines_added == 0 and fi.lines_removed == 0) return false;
    const cat = fi.last_cat orelse fi.dominantCat() orelse return false;
    return cat == .write or cat == .edit;
}

fn writeChips(w: *Writer, fi: session.FileInfo, selected: bool) !void {
    if (showDiffChip(fi)) {
        try w.writeAll(" ");
        try w.writeAll(current.plus);
        try w.writeAll("+");
        try writeU32(w, fi.lines_added);
        try resetKeepBg(w, selected);
        try w.writeAll(" ");
        try w.writeAll(current.minus);
        try w.writeAll("-");
        try writeU32(w, fi.lines_removed);
        try resetKeepBg(w, selected);
    }
    try writeBadges(w, fi, selected);
}

fn renderRow(
    w: *Writer,
    row: VisibleRow,
    s: ?*const session.Session,
    now_ms: i64,
    selected: bool,
    query: []const u8,
    cols: u16,
) !void {
    if (selected) try w.writeAll(current.sel_bg);
    // 2-col left margin so the tree breathes from the terminal edge.
    try w.writeAll("  ");

    if (!row.is_root) {
        try w.writeAll(current.dim_text);
        try w.writeAll(row.prefix);
        try w.writeAll(if (row.is_last) "└─ " else "├─ ");
        try resetKeepBg(w, selected);
    }

    if (row.node.is_dir) {
        try writeChevron(w, row.collapsed, selected);
        try w.writeByte(' ');
    }

    const info = if (s) |sess| sess.info(row.node.abs_path) else null;
    const is_recent = if (s) |sess| blk: {
        const r = sess.recent() orelse break :blk false;
        break :blk std.mem.eql(u8, r, row.node.abs_path);
    } else false;
    const fresh = if (info) |fi| now_ms - fi.last_touch_ms < fresh_window_ms else false;

    const style = if (row.is_root)
        current.root
    else
        pickStyle(row.node.is_dir, info, is_recent, fresh);

    // Layout. Right border eats col `cols`, so the name + slash + chips
    // share `avail` cells. Drop chips first, truncate name with `…`
    // last so the user always knows what file they're looking at.
    const name_col = nameStartCol(row);
    const avail: u16 = if (cols > name_col) cols - name_col else 0;
    const slash: u16 = if (row.node.is_dir) 1 else 0;
    const name_w = nameCols(row.node.name);
    const chips_w: u16 = if (info) |fi| (if (fresh and !row.node.is_dir) chipsCols(fi) else 0) else 0;

    var name_bytes: usize = row.node.name.len;
    var ellipsis = false;
    var draw_slash = row.node.is_dir;
    var chips_to_draw: u16 = chips_w;

    if (name_w + slash + chips_w > avail) {
        chips_to_draw = 0;
        if (name_w + slash <= avail) {
            // name + slash fits; chips dropped above.
        } else if (avail >= slash + 2) {
            name_bytes = nameTake(row.node.name, avail - slash - 1);
            ellipsis = true;
        } else if (avail >= 2) {
            name_bytes = nameTake(row.node.name, avail - 1);
            ellipsis = true;
            draw_slash = false;
        } else if (avail == 1) {
            name_bytes = nameTake(row.node.name, 1);
            draw_slash = false;
        } else {
            name_bytes = 0;
            draw_slash = false;
        }
    }

    if (name_bytes > 0 or ellipsis) {
        try w.writeAll(style);
        try writeHyperlinkHighlighted(w, row.node.abs_path, row.node.name[0..name_bytes], query, style, selected, ellipsis);
        if (draw_slash) try w.writeByte('/');
        try resetKeepBg(w, selected);
    }

    if (chips_to_draw > 0) {
        if (info) |fi| try writeChips(w, fi, selected);
    }

    if (selected) {
        try w.writeAll(current.sel_bg);
        try w.writeAll(Style.clear_eol);
    }
    try w.writeAll(Style.reset);
}

/// Emit a full SGR reset, then re-establish the selection background so
/// downstream writes keep the bar. Used between styled segments within
/// a row that needs a solid highlight bg.
fn resetKeepBg(w: *Writer, selected: bool) !void {
    try w.writeAll(Style.reset);
    if (selected) try w.writeAll(current.sel_bg);
}

fn writeChevron(w: *Writer, collapsed: bool, selected: bool) !void {
    try w.writeAll(current.chevron);
    try w.writeAll(if (collapsed) "▸" else "▾");
    try resetKeepBg(w, selected);
}

/// Decimal writer. Replaces every `w.print("{d}", .{n})` so std.fmt's
/// full format machinery gets dead-stripped.
fn writeU32(w: *Writer, n: u32) !void {
    if (n == 0) return w.writeAll("0");
    var buf: [10]u8 = undefined;
    var i: usize = buf.len;
    var x = n;
    while (x > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(x % 10));
        x /= 10;
    }
    try w.writeAll(buf[i..]);
}

fn pickStyle(is_dir: bool, info: ?session.FileInfo, is_recent: bool, fresh: bool) []const u8 {
    if (info) |fi| {
        if (fresh) {
            if (fi.last_cat) |cat| return categoryStyle(cat);
            if (is_recent) return current.recent;
        }
        if (is_dir) return current.tracked_dir;
        return current.tracked_file;
    }
    if (is_dir) return current.untouched_dir;
    return current.untouched_file;
}

fn categoryStyle(cat: session.ToolCat) []const u8 {
    return switch (cat) {
        .write, .edit => current.cat_write,
        .read => current.cat_read,
        .exec => current.cat_exec,
        .other => current.cat_other,
    };
}

fn categoryLabel(cat: session.ToolCat) []const u8 {
    return switch (cat) {
        .write => "Write",
        .edit => "Edit",
        .read => "Read",
        .exec => "Bash",
        .other => "Tool",
    };
}

fn writeBadges(w: *Writer, fi: session.FileInfo, selected: bool) !void {
    const cat = fi.last_cat orelse fi.dominantCat() orelse return;
    try w.writeAll(" ");
    try w.writeAll(categoryStyle(cat));
    try w.writeAll("[");
    try w.writeAll(categoryLabel(cat));
    try w.writeAll("]");
    try resetKeepBg(w, selected);
}

fn writeHyperlinkHighlighted(
    w: *Writer,
    abs_path: []const u8,
    label: []const u8,
    query: []const u8,
    base_style: []const u8,
    selected: bool,
    ellipsis: bool,
) !void {
    try w.writeAll("\x1b]8;;file://");
    try writePercentEncoded(w, abs_path);
    try w.writeAll("\x1b\\");
    if (query.len > 0) {
        try writeLabelHighlighted(w, label, query, base_style, selected);
    } else {
        try w.writeAll(label);
    }
    if (ellipsis) try w.writeAll("…");
    try w.writeAll("\x1b]8;;\x1b\\");
}

fn writeLabelHighlighted(
    w: *Writer,
    label: []const u8,
    query: []const u8,
    base_style: []const u8,
    selected: bool,
) !void {
    var i: usize = 0;
    while (i < label.len) {
        if (i + query.len <= label.len and caseInsensEql(label[i..][0..query.len], query)) {
            try w.writeAll(current.match);
            try w.writeAll(label[i..][0..query.len]);
            try resetKeepBg(w, selected);
            try w.writeAll(base_style);
            i += query.len;
        } else {
            try w.writeByte(label[i]);
            i += 1;
        }
    }
}

fn caseInsensEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) if (lower(a[i]) != lower(b[i])) return false;
    return true;
}

fn writePercentEncoded(w: *Writer, s: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        if (isUnreserved(c)) {
            try w.writeByte(c);
        } else {
            try w.writeByte('%');
            try w.writeByte(hex[(c >> 4) & 0xF]);
            try w.writeByte(hex[c & 0xF]);
        }
    }
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '/', '-', '_', '.', '~' => true,
        else => false,
    };
}
