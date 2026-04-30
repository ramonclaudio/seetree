const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Set = struct {
    arena: *std.heap.ArenaAllocator,
    gpa: Allocator,
    patterns: std.ArrayList(Pattern) = .empty,

    pub const Pattern = struct {
        glob: []const u8,
        negate: bool,
        anchored: bool,
        dir_only: bool,
    };

    pub fn init(gpa: Allocator) !Set {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = .init(gpa);
        return .{ .arena = arena, .gpa = gpa };
    }

    pub fn deinit(self: *Set) void {
        self.patterns.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    /// Read and parse `<dir>/<file>` directly via libc. Missing file is
    /// a successful no-op (matches gitignore semantics). Silently caps
    /// at 64 KB since real .gitignores are small.
    pub fn loadFileAbsolute(self: *Set, dir: []const u8, file: []const u8) !void {
        var zpath: [std.fs.max_path_bytes + 1]u8 = undefined;
        const total = dir.len + 1 + file.len;
        if (total > zpath.len - 1) return;
        @memcpy(zpath[0..dir.len], dir);
        zpath[dir.len] = '/';
        @memcpy(zpath[dir.len + 1 ..][0..file.len], file);
        zpath[total] = 0;

        const fd = std.c.open(@ptrCast(&zpath), .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
        if (fd < 0) return; // missing or unreadable -> no patterns
        defer _ = std.c.close(fd);

        var buf: [64 * 1024]u8 = undefined;
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) return;
        try self.loadSlice(buf[0..@intCast(n)]);
    }

    pub fn loadSlice(self: *Set, contents: []const u8) !void {
        const arena = self.arena.allocator();
        var it = std.mem.splitScalar(u8, contents, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);
            if (line.len == 0 or line[0] == '#') continue;

            var p: Pattern = .{
                .glob = line,
                .negate = false,
                .anchored = false,
                .dir_only = false,
            };
            var s = line;
            if (s[0] == '!') {
                p.negate = true;
                s = s[1..];
            }
            if (s.len > 0 and s[0] == '/') {
                p.anchored = true;
                s = s[1..];
            }
            if (s.len > 0 and s[s.len - 1] == '/') {
                p.dir_only = true;
                s = s[0 .. s.len - 1];
            }
            if (s.len == 0) continue;
            p.glob = try arena.dupe(u8, s);
            try self.patterns.append(self.gpa, p);
        }
    }

    pub fn matches(self: *const Set, rel_path: []const u8, basename: []const u8, is_dir: bool) bool {
        var ignored = false;
        for (self.patterns.items) |p| {
            if (p.dir_only and !is_dir) continue;
            const m = if (p.anchored or hasSlash(p.glob))
                matchPath(p.glob, rel_path)
            else
                matchName(p.glob, basename) or matchAnySegment(p.glob, rel_path);
            if (m) ignored = !p.negate;
        }
        return ignored;
    }
};

fn hasSlash(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, '/') != null;
}

fn matchPath(pattern: []const u8, path: []const u8) bool {
    return wildMatch(pattern, path, true);
}

fn matchName(pattern: []const u8, name: []const u8) bool {
    return wildMatch(pattern, name, false);
}

fn matchAnySegment(pattern: []const u8, path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (wildMatch(pattern, seg, false)) return true;
    }
    return false;
}

/// Classic fnmatch with '*' (any chars, never matches '/' unless allow_slash)
/// and '?' (single char).
fn wildMatch(pattern: []const u8, text: []const u8, allow_slash: bool) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len) {
        if (pi < pattern.len and (pattern[pi] == text[ti] or pattern[pi] == '?')) {
            pi += 1;
            ti += 1;
        } else if (pi < pattern.len and pattern[pi] == '*') {
            star_pi = pi;
            star_ti = ti;
            pi += 1;
        } else if (star_pi) |sp| {
            if (!allow_slash and text[star_ti] == '/') return false;
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
        } else {
            return false;
        }
    }
    while (pi < pattern.len and pattern[pi] == '*') pi += 1;
    return pi == pattern.len;
}

test "basic match" {
    try std.testing.expect(wildMatch("*.zig", "main.zig", false));
    try std.testing.expect(!wildMatch("*.zig", "main.ts", false));
    try std.testing.expect(wildMatch("node_modules", "node_modules", false));
    try std.testing.expect(!wildMatch("node_modules", "not_node_modules", false));
    try std.testing.expect(wildMatch("foo*bar", "fooquxbar", false));
    try std.testing.expect(wildMatch("*", "anything", false));
}

test "gitignore load" {
    var s = try Set.init(std.testing.allocator);
    defer s.deinit();
    try s.loadSlice(
        \\# comment
        \\node_modules
        \\*.tmp
        \\/dist/
        \\!keep.tmp
    );
    try std.testing.expect(s.matches("src/node_modules", "node_modules", true));
    try std.testing.expect(s.matches("foo.tmp", "foo.tmp", false));
    try std.testing.expect(!s.matches("keep.tmp", "keep.tmp", false));
    try std.testing.expect(s.matches("dist", "dist", true));
    try std.testing.expect(!s.matches("inner/dist", "dist", true));
}
