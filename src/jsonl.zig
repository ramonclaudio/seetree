//! Minimal JSONL field scanner. Replaces std.json.parseFromSliceLeaky for
//! the handful of fields we actually care about on the Claude transcript.
//! No AST, no allocator: values are returned as slices into the input
//! line. Escape sequences in strings (`\\` and `\"`) are accepted but not
//! decoded; callers either compare against unescaped patterns or ignore
//! rare escapes (tool ids and absolute paths never contain them).
const std = @import("std");

/// Iterator over the top-level key/value pairs of a JSON object. Use on
/// a whole jsonl line (the line is the root object).
pub const ObjectIterator = struct {
    src: []const u8,
    /// Byte index pointing to either the first key or a value separator.
    pos: usize,

    pub const KeyValue = struct {
        key: []const u8,
        /// Raw value slice (with quotes on strings, braces on objects,
        /// brackets on arrays, digits on numbers, etc.).
        raw: []const u8,
    };

    pub fn next(self: *ObjectIterator) ?KeyValue {
        skipWs(self.src, &self.pos);
        if (self.pos >= self.src.len) return null;
        if (self.src[self.pos] == '}') return null;
        if (self.src[self.pos] == ',') {
            self.pos += 1;
            skipWs(self.src, &self.pos);
        }
        if (self.pos >= self.src.len or self.src[self.pos] != '"') return null;
        const key = readString(self.src, &self.pos) orelse return null;
        skipWs(self.src, &self.pos);
        if (self.pos >= self.src.len or self.src[self.pos] != ':') return null;
        self.pos += 1;
        skipWs(self.src, &self.pos);
        const value_start = self.pos;
        skipValue(self.src, &self.pos);
        const raw = self.src[value_start..self.pos];
        return .{ .key = key, .raw = raw };
    }
};

/// Open a JSON object for iteration. Accepts either the raw line (which
/// starts with `{`) or any slice whose first non-whitespace char is `{`.
pub fn iterateObject(src: []const u8) ObjectIterator {
    var pos: usize = 0;
    skipWs(src, &pos);
    if (pos < src.len and src[pos] == '{') pos += 1;
    return .{ .src = src, .pos = pos };
}

pub const ArrayIterator = struct {
    src: []const u8,
    pos: usize,

    pub fn next(self: *ArrayIterator) ?[]const u8 {
        skipWs(self.src, &self.pos);
        if (self.pos >= self.src.len) return null;
        if (self.src[self.pos] == ']') return null;
        if (self.src[self.pos] == ',') {
            self.pos += 1;
            skipWs(self.src, &self.pos);
        }
        const start = self.pos;
        skipValue(self.src, &self.pos);
        return self.src[start..self.pos];
    }
};

pub fn iterateArray(src: []const u8) ArrayIterator {
    var pos: usize = 0;
    skipWs(src, &pos);
    if (pos < src.len and src[pos] == '[') pos += 1;
    return .{ .src = src, .pos = pos };
}

/// Find a top-level string field by key. Returns the value slice without
/// the surrounding quotes, or null if the key isn't present or the value
/// isn't a string.
pub fn stringField(src: []const u8, key: []const u8) ?[]const u8 {
    var it = iterateObject(src);
    while (it.next()) |kv| {
        if (!std.mem.eql(u8, kv.key, key)) continue;
        return stringValue(kv.raw);
    }
    return null;
}

/// Find a top-level field by key, returning its raw slice (useful for
/// objects and arrays to pass back into iterateObject / iterateArray).
pub fn fieldRaw(src: []const u8, key: []const u8) ?[]const u8 {
    var it = iterateObject(src);
    while (it.next()) |kv| {
        if (std.mem.eql(u8, kv.key, key)) return kv.raw;
    }
    return null;
}

/// Unwrap a raw value known to be a string into its contents (no quotes,
/// no escape decoding).
pub fn stringValue(raw: []const u8) ?[]const u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return null;
    return raw[1 .. raw.len - 1];
}

/// Unwrap a raw value known to be an object.
pub fn objectValue(raw: []const u8) ?[]const u8 {
    if (raw.len < 2 or raw[0] != '{' or raw[raw.len - 1] != '}') return null;
    return raw;
}

/// Unwrap a raw value known to be an array.
pub fn arrayValue(raw: []const u8) ?[]const u8 {
    if (raw.len < 2 or raw[0] != '[' or raw[raw.len - 1] != ']') return null;
    return raw;
}

fn skipWs(src: []const u8, pos: *usize) void {
    while (pos.* < src.len) : (pos.* += 1) {
        const c = src[pos.*];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') return;
    }
}

/// Consume a string starting at pos.* (which must point at the opening
/// `"`). Advances pos past the closing `"` and returns the contents
/// slice (without quotes, escapes not decoded).
fn readString(src: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= src.len or src[pos.*] != '"') return null;
    pos.* += 1;
    const start = pos.*;
    while (pos.* < src.len) : (pos.* += 1) {
        const c = src[pos.*];
        if (c == '\\') {
            pos.* += 1;
            if (pos.* >= src.len) return null;
            continue;
        }
        if (c == '"') {
            const s = src[start..pos.*];
            pos.* += 1;
            return s;
        }
    }
    return null;
}

/// Advance pos past the next JSON value (string, number, true/false/null,
/// object, or array). Assumes pos points at the first char of the value.
fn skipValue(src: []const u8, pos: *usize) void {
    if (pos.* >= src.len) return;
    const c = src[pos.*];
    switch (c) {
        '"' => _ = readString(src, pos),
        '{' => skipBalanced(src, pos, '{', '}'),
        '[' => skipBalanced(src, pos, '[', ']'),
        else => {
            // number, true, false, null: anything until the next
            // structural character.
            while (pos.* < src.len) : (pos.* += 1) {
                const x = src[pos.*];
                if (x == ',' or x == '}' or x == ']' or x == ' ' or x == '\t' or x == '\n' or x == '\r') return;
            }
        },
    }
}

fn skipBalanced(src: []const u8, pos: *usize, open: u8, close: u8) void {
    var depth: usize = 0;
    while (pos.* < src.len) : (pos.* += 1) {
        const c = src[pos.*];
        if (c == '"') {
            _ = readString(src, pos);
            // readString already moved past the closing quote.
            if (pos.* < src.len) {
                // Recheck this character without advancing again.
                pos.* -= 1;
            }
            continue;
        }
        if (c == open) depth += 1;
        if (c == close) {
            depth -= 1;
            if (depth == 0) {
                pos.* += 1;
                return;
            }
        }
    }
}

test "object iteration" {
    const line = "{\"type\":\"user\",\"message\":{\"role\":\"x\"},\"n\":3}";
    try std.testing.expectEqualStrings("user", stringField(line, "type").?);
    try std.testing.expectEqualStrings("{\"role\":\"x\"}", fieldRaw(line, "message").?);
}

test "structured patch lines count" {
    const line =
        \\{"toolUseResult":{"filePath":"/x.zig","structuredPatch":[{"lines":["+a","-b"," c"]}]}}
    ;
    const tur_raw = fieldRaw(line, "toolUseResult").?;
    try std.testing.expectEqualStrings("/x.zig", stringField(tur_raw, "filePath").?);
    const patch_raw = fieldRaw(tur_raw, "structuredPatch").?;
    var a_it = iterateArray(patch_raw);
    const hunk = a_it.next().?;
    const lines_raw = fieldRaw(hunk, "lines").?;
    var l_it = iterateArray(lines_raw);
    var adds: u32 = 0;
    var rems: u32 = 0;
    while (l_it.next()) |raw| {
        const s = stringValue(raw) orelse continue;
        if (s.len == 0) continue;
        if (s[0] == '+') adds += 1;
        if (s[0] == '-') rems += 1;
    }
    try std.testing.expectEqual(@as(u32, 1), adds);
    try std.testing.expectEqual(@as(u32, 1), rems);
}
