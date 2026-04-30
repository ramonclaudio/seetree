//! Claude-Code session tailer. All file I/O is direct libc (open/read/
//! stat/opendir/readdir) so std.Io.File/Dir/Reader machinery gets
//! dead-stripped by the linker. No `io: Io` parameters anywhere.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const jsonl = @import("jsonl.zig");
const sys = @import("sys.zig");

pub const ToolCat = enum { write, edit, read, exec, other };

pub const FileInfo = struct {
    last_touch_ms: i64 = 0,
    write_count: u8 = 0,
    edit_count: u8 = 0,
    read_count: u8 = 0,
    exec_count: u8 = 0,
    other_count: u8 = 0,
    lines_added: u32 = 0,
    lines_removed: u32 = 0,
    last_cat: ?ToolCat = null,

    pub fn count(self: FileInfo, cat: ToolCat) u8 {
        return switch (cat) {
            .write => self.write_count,
            .edit => self.edit_count,
            .read => self.read_count,
            .exec => self.exec_count,
            .other => self.other_count,
        };
    }

    pub fn dominantCat(self: FileInfo) ?ToolCat {
        // Edit ranks above Write so a file that was created and then
        // edited reads as "Edit" in the idle state.
        if (self.edit_count > 0) return .edit;
        if (self.write_count > 0) return .write;
        if (self.read_count > 0) return .read;
        if (self.exec_count > 0) return .exec;
        if (self.other_count > 0) return .other;
        return null;
    }
};

const Pending = struct {
    path: []const u8,
    cat: ToolCat,
    started_ms: i64,
};

pub const Stream = struct {
    path: []const u8,
    read_offset: u64 = 0,
};

pub const Session = struct {
    gpa: Allocator,
    arena: *std.heap.ArenaAllocator,
    id: []const u8,
    jsonl_path: []const u8,
    subagents_dir: []const u8,
    streams: std.ArrayList(Stream),
    files: std.StringHashMap(FileInfo),
    pending: std.StringHashMap(Pending),
    last_recent: ?[]const u8 = null,
    last_subagent_scan_ms: i64 = 0,

    pub fn deinit(self: *Session) void {
        self.files.deinit();
        self.pending.deinit();
        self.streams.deinit(self.gpa);
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    pub fn recent(self: *const Session) ?[]const u8 {
        return self.last_recent;
    }

    pub fn info(self: *const Session, abs_path: []const u8) ?FileInfo {
        return self.files.get(abs_path);
    }
};

pub const FindError = error{ NoSessionDir, NoSessions } || Allocator.Error;

/// Pick the newest `.jsonl` in `~/.claude/projects/<encoded_cwd>/`. We
/// keep a running mtime max over the readdir stream rather than
/// collecting + sorting.
/// `claude_dir` is the Claude Code config root (defaults to `$HOME/.claude`,
/// overridable via `CLAUDE_CONFIG_DIR`). The session jsonls live at
/// `<claude_dir>/projects/<encoded_cwd>/<id>.jsonl`.
pub fn findNewest(gpa: Allocator, claude_dir: []const u8, cwd_abs: []const u8) FindError![]u8 {
    const encoded = try encodePath(gpa, cwd_abs);
    defer gpa.free(encoded);

    var zpath: [std.fs.max_path_bytes + 1]u8 = undefined;
    const projects_dir_len = claude_dir.len + "/projects/".len + encoded.len;
    if (projects_dir_len > zpath.len - 1) return error.NoSessionDir;
    var w: usize = 0;
    @memcpy(zpath[w..][0..claude_dir.len], claude_dir);
    w += claude_dir.len;
    @memcpy(zpath[w..][0.."/projects/".len], "/projects/");
    w += "/projects/".len;
    @memcpy(zpath[w..][0..encoded.len], encoded);
    w += encoded.len;
    zpath[w] = 0;

    const dir = std.c.opendir(@ptrCast(&zpath)) orelse return error.NoSessionDir;
    defer _ = std.c.closedir(dir);

    var best_name_buf: [256]u8 = undefined;
    var best_name_len: usize = 0;
    var best_sec: isize = std.math.minInt(isize);
    var best_nsec: isize = 0;

    // Null-terminate the dir path so we can append entry names.
    zpath[w] = '/';
    w += 1;

    while (std.c.readdir(dir)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);
        if (name.len < 6 or !std.mem.endsWith(u8, name, ".jsonl")) continue;

        if (w + name.len >= zpath.len) continue;
        @memcpy(zpath[w..][0..name.len], name);
        zpath[w + name.len] = 0;

        const mt = sys.statMtime(@ptrCast(&zpath)) orelse continue;
        if (mt.sec > best_sec or (mt.sec == best_sec and mt.nsec > best_nsec)) {
            best_sec = mt.sec;
            best_nsec = mt.nsec;
            if (name.len > best_name_buf.len) continue;
            @memcpy(best_name_buf[0..name.len], name);
            best_name_len = name.len;
        }
    }

    if (best_name_len == 0) return error.NoSessions;

    // Final path: projects_dir + "/" + best_name
    const total = projects_dir_len + 1 + best_name_len;
    const out = try gpa.alloc(u8, total);
    @memcpy(out[0..projects_dir_len], zpath[0..projects_dir_len]);
    out[projects_dir_len] = '/';
    @memcpy(out[projects_dir_len + 1 ..][0..best_name_len], best_name_buf[0..best_name_len]);
    return out;
}

/// Match Claude Code's project-dir encoding: '/' AND '.' both become
/// '-'. Paths under macOS tempdirs (e.g. `/var/folders/.../foo.XXXXXX`)
/// would otherwise mismatch and seetree would never find the session.
fn encodePath(gpa: Allocator, p: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, p.len);
    for (p, 0..) |c, i| out[i] = if (c == '/' or c == '.') '-' else c;
    return out;
}


pub fn open(gpa: Allocator, jsonl_path: []const u8) !Session {
    const arena_ptr = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena_ptr);
    arena_ptr.* = .init(gpa);
    errdefer arena_ptr.deinit();
    const arena = arena_ptr.allocator();

    const id = sessionIdFromPath(jsonl_path);
    const jsonl_dup = try arena.dupe(u8, jsonl_path);
    const dir = dirnameOf(jsonl_path);
    const suffix = "/subagents";
    const subagents_dir = try arena.alloc(u8, dir.len + 1 + id.len + suffix.len);
    @memcpy(subagents_dir[0..dir.len], dir);
    subagents_dir[dir.len] = '/';
    @memcpy(subagents_dir[dir.len + 1 ..][0..id.len], id);
    @memcpy(subagents_dir[dir.len + 1 + id.len ..], suffix);

    var streams: std.ArrayList(Stream) = .empty;
    errdefer streams.deinit(gpa);
    try streams.append(gpa, .{ .path = jsonl_dup });

    return .{
        .gpa = gpa,
        .arena = arena_ptr,
        .id = try arena.dupe(u8, id),
        .jsonl_path = jsonl_dup,
        .subagents_dir = subagents_dir,
        .streams = streams,
        .files = .init(gpa),
        .pending = .init(gpa),
    };
}

fn sessionIdFromPath(p: []const u8) []const u8 {
    const base = basenameOf(p);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| return base[0..dot];
    return base;
}

fn basenameOf(p: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return p[i + 1 ..];
    return p;
}

fn dirnameOf(p: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| return p[0..i];
    return ".";
}

pub fn pump(self: *Session, now_ms: i64) !u32 {
    discoverSubagents(self, now_ms) catch {};

    var total: u32 = 0;
    var i: usize = 0;
    while (i < self.streams.items.len) : (i += 1) {
        total += pumpStream(self, &self.streams.items[i], now_ms) catch 0;
    }
    sweepStalePending(self, now_ms);
    return total;
}

fn pumpStream(self: *Session, stream: *Stream, now_ms: i64) !u32 {
    var zpath: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (stream.path.len > zpath.len - 1) return 0;
    @memcpy(zpath[0..stream.path.len], stream.path);
    zpath[stream.path.len] = 0;

    const fd = std.c.open(@ptrCast(&zpath), .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);

    const size: u64 = sys.fileSize(fd) orelse return 0;
    if (size <= stream.read_offset) {
        stream.read_offset = size;
        return 0;
    }
    _ = std.c.lseek(fd, @intCast(stream.read_offset), 0);

    // Line reader: reads chunks into `chunk`, carries partial line in
    // `line_buf`. A complete line is everything between two '\n'; the
    // trailing byte may be short-of-newline and gets carried to the
    // next read. We intentionally cap line length at `line_buf.len`;
    // longer lines get skipped (matches the old StreamTooLong branch).
    var chunk: [16 * 1024]u8 = undefined;
    var line_buf: [128 * 1024]u8 = undefined;
    var line_end: usize = 0;
    var overflow = false;
    var count: u32 = 0;
    var consumed: u64 = 0;

    while (true) {
        const got = std.c.read(fd, &chunk, chunk.len);
        if (got <= 0) break;
        const n: usize = @intCast(got);
        consumed += n;

        var i: usize = 0;
        while (i < n) {
            if (std.mem.indexOfScalar(u8, chunk[i..n], '\n')) |rel| {
                const seg = chunk[i .. i + rel];
                if (!overflow) {
                    if (line_end + seg.len <= line_buf.len) {
                        @memcpy(line_buf[line_end..][0..seg.len], seg);
                        line_end += seg.len;
                        handleLine(self, line_buf[0..line_end], now_ms) catch {};
                        count += 1;
                    }
                }
                line_end = 0;
                overflow = false;
                i += rel + 1;
            } else {
                const seg = chunk[i..n];
                if (!overflow) {
                    if (line_end + seg.len > line_buf.len) {
                        overflow = true;
                        line_end = 0;
                    } else {
                        @memcpy(line_buf[line_end..][0..seg.len], seg);
                        line_end += seg.len;
                    }
                }
                i = n;
            }
        }
    }

    // Only advance offset by complete-line bytes we processed; leave
    // the partial tail for next pump. `consumed` is total read;
    // `line_end` is bytes held for the partial tail.
    stream.read_offset += consumed - line_end;
    return count;
}

fn discoverSubagents(self: *Session, now_ms: i64) !void {
    if (now_ms - self.last_subagent_scan_ms < 500) return;
    self.last_subagent_scan_ms = now_ms;

    var zpath: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (self.subagents_dir.len > zpath.len - 1) return;
    @memcpy(zpath[0..self.subagents_dir.len], self.subagents_dir);
    zpath[self.subagents_dir.len] = 0;

    const dir = std.c.opendir(@ptrCast(&zpath)) orelse return;
    defer _ = std.c.closedir(dir);

    const arena = self.arena.allocator();
    while (std.c.readdir(dir)) |entry| {
        const name_ptr: [*:0]const u8 = @ptrCast(&entry.name);
        const name = std.mem.span(name_ptr);
        if (name.len < 6 or !std.mem.endsWith(u8, name, ".jsonl")) continue;

        const full_len = self.subagents_dir.len + 1 + name.len;
        const full = try arena.alloc(u8, full_len);
        @memcpy(full[0..self.subagents_dir.len], self.subagents_dir);
        full[self.subagents_dir.len] = '/';
        @memcpy(full[self.subagents_dir.len + 1 ..][0..name.len], name);

        if (alreadyTracked(self, full)) continue;
        try self.streams.append(self.gpa, .{ .path = full });
    }
}

fn alreadyTracked(self: *const Session, path: []const u8) bool {
    for (self.streams.items) |s| {
        if (std.mem.eql(u8, s.path, path)) return true;
    }
    return false;
}

fn handleLine(self: *Session, line: []const u8, now_ms: i64) !void {
    if (line.len == 0) return;
    const type_s = jsonl.stringField(line, "type") orelse return;

    const entry_ms: i64 = blk: {
        const t = jsonl.stringField(line, "timestamp") orelse break :blk now_ms;
        break :blk parseIsoMs(t) orelse now_ms;
    };

    if (std.mem.eql(u8, type_s, "assistant")) {
        try handleAssistant(self, line, entry_ms);
    } else if (std.mem.eql(u8, type_s, "user")) {
        try handleUser(self, line);
        try handleToolUseResult(self, line);
    }
}

fn handleAssistant(self: *Session, line: []const u8, now_ms: i64) !void {
    const msg_raw = jsonl.fieldRaw(line, "message") orelse return;
    const content_raw = jsonl.fieldRaw(msg_raw, "content") orelse return;

    const arena = self.arena.allocator();
    var items = jsonl.iterateArray(content_raw);
    while (items.next()) |item| {
        const t = jsonl.stringField(item, "type") orelse continue;
        if (!std.mem.eql(u8, t, "tool_use")) continue;

        const id = jsonl.stringField(item, "id") orelse continue;
        const name = jsonl.stringField(item, "name") orelse continue;
        const input_raw = jsonl.fieldRaw(item, "input") orelse continue;
        const path = pathFromInput(input_raw) orelse continue;

        const cat = categorize(name);
        try markTouched(self, path, cat, now_ms);
        const id_dup = try arena.dupe(u8, id);
        const path_dup = try arena.dupe(u8, path);
        try self.pending.put(id_dup, .{ .path = path_dup, .cat = cat, .started_ms = now_ms });
    }
}

fn handleUser(self: *Session, line: []const u8) !void {
    const msg_raw = jsonl.fieldRaw(line, "message") orelse return;
    const content_raw = jsonl.fieldRaw(msg_raw, "content") orelse return;

    var items = jsonl.iterateArray(content_raw);
    while (items.next()) |item| {
        const t = jsonl.stringField(item, "type") orelse continue;
        if (!std.mem.eql(u8, t, "tool_result")) continue;
        const id = jsonl.stringField(item, "tool_use_id") orelse continue;
        if (self.pending.fetchRemove(id)) |kv| {
            if (self.files.getPtr(kv.value.path)) |f| {
                decrementCat(f, kv.value.cat);
            }
        }
    }
}

fn handleToolUseResult(self: *Session, line: []const u8) !void {
    const tur = jsonl.fieldRaw(line, "toolUseResult") orelse return;
    const path = jsonl.stringField(tur, "filePath") orelse return;
    const patch = jsonl.fieldRaw(tur, "structuredPatch") orelse return;

    var added: u32 = 0;
    var removed: u32 = 0;
    var hunks = jsonl.iterateArray(patch);
    while (hunks.next()) |hunk| {
        const lines_raw = jsonl.fieldRaw(hunk, "lines") orelse continue;
        var l_it = jsonl.iterateArray(lines_raw);
        while (l_it.next()) |raw| {
            const s = jsonl.stringValue(raw) orelse continue;
            if (s.len == 0) continue;
            switch (s[0]) {
                '+' => added += 1,
                '-' => removed += 1,
                else => {},
            }
        }
    }
    if (added == 0 and removed == 0) return;

    const arena = self.arena.allocator();
    const key = try arena.dupe(u8, path);
    const gop = try self.files.getOrPut(key);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    gop.value_ptr.lines_added = added;
    gop.value_ptr.lines_removed = removed;
}

pub fn categorize(tool: []const u8) ToolCat {
    const eq = std.mem.eql;
    // Write/NotebookCreate create new files. Edit/MultiEdit/NotebookEdit
    // mutate existing ones. Keep them apart so the badge text matches
    // the tool the user actually ran.
    if (eq(u8, tool, "Write") or eq(u8, tool, "NotebookCreate")) return .write;
    if (eq(u8, tool, "Edit") or eq(u8, tool, "MultiEdit") or eq(u8, tool, "NotebookEdit"))
        return .edit;
    if (eq(u8, tool, "Read") or eq(u8, tool, "Glob") or eq(u8, tool, "Grep") or
        eq(u8, tool, "LS") or eq(u8, tool, "NotebookRead"))
        return .read;
    if (eq(u8, tool, "Bash") or eq(u8, tool, "BashOutput")) return .exec;
    return .other;
}

fn incrementCat(fi: *FileInfo, cat: ToolCat) void {
    const ptr = switch (cat) {
        .write => &fi.write_count,
        .edit => &fi.edit_count,
        .read => &fi.read_count,
        .exec => &fi.exec_count,
        .other => &fi.other_count,
    };
    if (ptr.* < std.math.maxInt(u8)) ptr.* += 1;
}

fn decrementCat(fi: *FileInfo, cat: ToolCat) void {
    const ptr = switch (cat) {
        .write => &fi.write_count,
        .edit => &fi.edit_count,
        .read => &fi.read_count,
        .exec => &fi.exec_count,
        .other => &fi.other_count,
    };
    if (ptr.* > 0) ptr.* -= 1;
}

fn markTouched(self: *Session, path: []const u8, cat: ToolCat, now_ms: i64) !void {
    const arena = self.arena.allocator();
    const key = try arena.dupe(u8, path);

    const gop = try self.files.getOrPut(key);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    gop.value_ptr.last_touch_ms = now_ms;
    gop.value_ptr.last_cat = cat;
    incrementCat(gop.value_ptr, cat);
    self.last_recent = key;
}

fn sweepStalePending(self: *Session, now_ms: i64) void {
    const stale_threshold_ms: i64 = 60 * 1000;
    var stale: std.ArrayList([]const u8) = .empty;
    defer stale.deinit(self.gpa);

    var it = self.pending.iterator();
    while (it.next()) |kv| {
        if (now_ms - kv.value_ptr.started_ms < stale_threshold_ms) continue;
        stale.append(self.gpa, kv.key_ptr.*) catch return;
    }
    for (stale.items) |id| {
        if (self.pending.fetchRemove(id)) |kv| {
            if (self.files.getPtr(kv.value.path)) |f| {
                decrementCat(f, kv.value.cat);
            }
        }
    }
}

fn pathFromInput(input_raw: []const u8) ?[]const u8 {
    const keys = [_][]const u8{ "file_path", "notebook_path", "path" };
    inline for (keys) |k| {
        if (jsonl.stringField(input_raw, k)) |s| return s;
    }
    return null;
}

fn parseIsoMs(s: []const u8) ?i64 {
    if (s.len < 20) return null;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    const y = parseDec(s[0..4]) orelse return null;
    const mo = parseDec(s[5..7]) orelse return null;
    const d = parseDec(s[8..10]) orelse return null;
    const h = parseDec(s[11..13]) orelse return null;
    const mi = parseDec(s[14..16]) orelse return null;
    const se = parseDec(s[17..19]) orelse return null;

    var ms: i64 = 0;
    if (s.len > 20 and s[19] == '.') {
        var end: usize = 20;
        while (end < s.len and end < 23 and s[end] >= '0' and s[end] <= '9') end += 1;
        const digits = end - 20;
        if (digits > 0) {
            ms = parseDec(s[20..end]) orelse 0;
            switch (digits) {
                1 => ms *= 100,
                2 => ms *= 10,
                else => {},
            }
        }
    }

    var yy: i32 = @intCast(y);
    const mm: i32 = @intCast(mo);
    yy -= if (mm <= 2) @as(i32, 1) else 0;
    const era: i32 = @divFloor(if (yy >= 0) yy else yy - 399, 400);
    const yoe: i32 = yy - era * 400;
    const doy: i32 = @divFloor(153 * (mm + (if (mm > 2) @as(i32, -3) else 9)) + 2, 5) + @as(i32, @intCast(d)) - 1;
    const doe: i32 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days: i64 = @as(i64, era) * 146097 + @as(i64, doe) - 719468;

    const seconds: i64 = days * 86400 + @as(i64, @intCast(h)) * 3600 + @as(i64, @intCast(mi)) * 60 + @as(i64, @intCast(se));
    return seconds * 1000 + ms;
}

fn parseDec(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var acc: i64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        acc = acc * 10 + (c - '0');
    }
    return acc;
}
