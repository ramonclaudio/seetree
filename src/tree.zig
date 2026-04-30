const std = @import("std");
const Allocator = std.mem.Allocator;
const ignore = @import("ignore.zig");

pub const Node = struct {
    name: []const u8,
    abs_path: []const u8,
    is_dir: bool,
    children: std.ArrayList(*Node) = .empty,

    fn less(_: void, a: *Node, b: *Node) bool {
        if (a.is_dir != b.is_dir) return a.is_dir and !b.is_dir;
        return std.mem.lessThan(u8, a.name, b.name);
    }

    pub fn sort(self: *Node) void {
        std.mem.sort(*Node, self.children.items, {}, less);
        for (self.children.items) |c| if (c.is_dir) c.sort();
    }
};

pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,

    pub fn init(gpa: Allocator) Tree {
        return .{ .arena = .init(gpa), .root = undefined };
    }

    pub fn deinit(self: *Tree) void {
        self.arena.deinit();
    }
};

const builtin_ignores = [_][]const u8{
    ".git",
    ".zig-cache",
    "zig-cache",
    "zig-out",
    "node_modules",
    "target",
    "dist",
    "build",
    ".next",
    ".turbo",
    ".cache",
    ".DS_Store",
    "__pycache__",
    ".venv",
    "venv",
};

const keep_hidden = [_][]const u8{
    ".gitignore",
    ".github",
    ".claude",
    ".env.example",
    ".zed",
};

/// Toggle from the settings popup. When true, hidden files (any name
/// starting with `.`) show up in the tree; when false, only the
/// `keep_hidden` exceptions pass through.
pub var show_hidden: bool = false;

fn builtinIgnored(name: []const u8) bool {
    for (builtin_ignores) |ig| if (std.mem.eql(u8, name, ig)) return true;
    if (name.len > 0 and name[0] == '.') {
        for (keep_hidden) |k| if (std.mem.eql(u8, name, k)) return false;
        return !show_hidden;
    }
    return false;
}

/// POSIX dirent.d_type value for directories. Same on macOS and Linux.
const DT_DIR: u8 = 4;

/// Populate a Tree (or refresh an existing one) from `abs_root`. The
/// arena is reset with retain_capacity so memory blocks are reused
/// across rebuilds, with no malloc/free of arena state per poll. On
/// any error t.root is left pointing at a valid empty root so callers
/// can keep rendering.
pub fn build(t: *Tree, abs_root: []const u8) !void {
    _ = t.arena.reset(.retain_capacity);
    const arena = t.arena.allocator();
    const gpa = t.arena.child_allocator;

    const base = if (std.mem.lastIndexOfScalar(u8, abs_root, '/')) |i| abs_root[i + 1 ..] else abs_root;
    const root = try arena.create(Node);
    root.* = .{
        .name = try arena.dupe(u8, if (base.len == 0) abs_root else base),
        .abs_path = try arena.dupe(u8, abs_root),
        .is_dir = true,
    };
    // Commit the (empty) root immediately. If we error out below the tree
    // is still in a valid state, and the user sees just the root directory
    // until the next poll succeeds.
    t.root = root;

    var zpath: [std.fs.max_path_bytes + 1]u8 = undefined;
    const root_dir = openDirZ(abs_root, &zpath) orelse return error.OpenDir;
    defer _ = std.c.closedir(root_dir);

    var ig = try ignore.Set.init(gpa);
    defer ig.deinit();
    try ig.loadFileAbsolute(abs_root, ".gitignore");
    // .seetreeignore takes the same pattern syntax as .gitignore but
    // applies only to seetree's view. Use it to hide files that are
    // tracked in git but you don't want to see in the live tree
    // (lockfiles, vendored junk, generated SQL dumps, etc.).
    try ig.loadFileAbsolute(abs_root, ".seetreeignore");

    try walk(arena, root_dir, abs_root, "", root, &ig);
    root.sort();
}

/// Null-terminate `path` into `buf` and call `opendir`. Returns null on
/// path-too-long, permission failure, or non-directory.
fn openDirZ(path: []const u8, buf: *[std.fs.max_path_bytes + 1]u8) ?*std.c.DIR {
    if (path.len > buf.len - 1) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return std.c.opendir(@ptrCast(buf));
}

fn walk(
    arena: Allocator,
    dir: *std.c.DIR,
    dir_abs: []const u8,
    rel_prefix: []const u8,
    parent: *Node,
    ig: *const ignore.Set,
) !void {
    while (std.c.readdir(dir)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);
        if (name.len == 0) continue;
        if (name[0] == '.' and (name.len == 1 or (name.len == 2 and name[1] == '.'))) continue;
        if (builtinIgnored(name)) continue;

        var rel_buf: [std.fs.max_path_bytes]u8 = undefined;
        const sep: []const u8 = if (rel_prefix.len == 0) "" else "/";
        const total = rel_prefix.len + sep.len + name.len;
        if (total > rel_buf.len) continue;
        @memcpy(rel_buf[0..rel_prefix.len], rel_prefix);
        @memcpy(rel_buf[rel_prefix.len..][0..sep.len], sep);
        @memcpy(rel_buf[rel_prefix.len + sep.len ..][0..name.len], name);
        const rel = rel_buf[0..total];

        const is_dir = entry.type == DT_DIR;
        if (ig.matches(rel, name, is_dir)) continue;

        const abs = try joinSlash(arena, dir_abs, name);
        const node = try arena.create(Node);
        node.* = .{
            .name = try arena.dupe(u8, name),
            .abs_path = abs,
            .is_dir = is_dir,
        };
        try parent.children.append(arena, node);

        if (is_dir) {
            var zpath: [std.fs.max_path_bytes + 1]u8 = undefined;
            const child = openDirZ(abs, &zpath) orelse continue;
            defer _ = std.c.closedir(child);
            const rel_dup = try arena.dupe(u8, rel);
            try walk(arena, child, abs, rel_dup, node, ig);
        }
    }
}

/// `a + "/" + b` in one allocation. Avoids `std.fs.path.join` which
/// pulls in the full path-joining vtable.
fn joinSlash(arena: Allocator, a: []const u8, b: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, a.len + 1 + b.len);
    @memcpy(out[0..a.len], a);
    out[a.len] = '/';
    @memcpy(out[a.len + 1 ..], b);
    return out;
}
