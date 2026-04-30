const std = @import("std");
const Writer = std.Io.Writer;
const builtin = @import("builtin");
const posix = std.posix;

const STDIN_FD: c_int = 0;
const STDOUT_FD: c_int = 1;
const STDERR_FD: c_int = 2;

// std.c.ioctl declares `request: c_int` but POSIX libc signature is
// `unsigned long request`. The 4-byte vs 8-byte mismatch lets the
// upper 32 bits of the register leak in as part of the request value,
// so TIOCGWINSZ (0x40087468) intermittently looks like an unknown
// request and returns ENOTTY. A correctly-typed extern dodges that.
const c_ioctl = @extern(*const fn (fd: c_int, request: c_ulong, ...) callconv(.c) c_int, .{ .name = "ioctl" });
fn tiocgwinsz(fd: c_int, out: *posix.winsize) c_int {
    return c_ioctl(fd, @intCast(posix.T.IOCGWINSZ), out);
}

pub const Size = struct { rows: u16, cols: u16 };

pub const Key = union(enum) {
    char: u8,
    up,
    down,
    left,
    right,
    enter,
    space,
    backspace,
    tab,
    esc,
    home,
    end,
    page_up,
    page_down,
};

pub const Event = union(enum) {
    none,
    key: Key,
    click: struct { row: u16, col: u16 },
    scroll: enum { up, down },
};

var sigwinch_flag: std.atomic.Value(bool) = .init(true);
var shutdown_flag: std.atomic.Value(bool) = .init(false);
var refresh_flag: std.atomic.Value(bool) = .init(false);

pub const Term = struct {
    size: Size,
    original_termios: ?posix.termios = null,
    mouse_enabled: bool = false,
    active: bool = false,
    /// Raw stdin bytes left to parse. `pollEvent` refills this only when
    /// drained, and parses one event per call so bursty input (paste,
    /// multi-byte CSI arriving together) isn't silently dropped.
    ev_buf: [128]u8 = undefined,
    ev_start: usize = 0,
    ev_end: usize = 0,

    pub fn init() !Term {
        installSigHandlers();
        var t: Term = .{ .size = .{ .rows = 24, .cols = 80 } };
        try t.refreshSize();
        return t;
    }

    pub fn enter(self: *Term, w: *Writer, title: ?[]const u8) !void {
        const old = posix.tcgetattr(STDIN_FD) catch null;
        if (old) |o| {
            self.original_termios = o;
            var raw = o;
            raw.lflag.ECHO = false;
            raw.lflag.ICANON = false;
            raw.lflag.IEXTEN = false;
            raw.cc[@intFromEnum(posix.V.MIN)] = 0;
            raw.cc[@intFromEnum(posix.V.TIME)] = 0;
            posix.tcsetattr(STDIN_FD, .NOW, raw) catch {};
        }
        // \x1b[?7l disables line wrap. The box borders sit on the last
        // column; writing a glyph at col cols would otherwise wrap.
        try w.writeAll("\x1b[?1049h\x1b[?25l\x1b[?1000h\x1b[?1006h\x1b[?7l");
        if (title) |t| {
            try w.writeAll("\x1b]0;");
            try w.writeAll(t);
            try w.writeAll("\x07");
        }
        try w.flush();
        self.mouse_enabled = true;
        self.active = true;
    }

    pub fn leave(self: *Term, w: *Writer) void {
        if (!self.active) return;
        w.writeAll("\x1b[?7h\x1b[?1006l\x1b[?1000l\x1b[?25h\x1b[?1049l") catch {};
        w.flush() catch {};
        if (self.original_termios) |o| posix.tcsetattr(STDIN_FD, .NOW, o) catch {};
        self.mouse_enabled = false;
        self.active = false;
    }

    pub fn refreshSize(self: *Term) !void {
        var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const fds = [_]c_int{ STDOUT_FD, STDIN_FD, STDERR_FD };
        for (fds) |fd| {
            if (tiocgwinsz(fd, &ws) == 0 and ws.row > 0 and ws.col > 0) {
                self.size = .{ .rows = ws.row, .cols = ws.col };
                return;
            }
        }
        // /dev/tty fallback covers stdin/out/err all redirected away.
        const tty_fd = std.c.open("/dev/tty", .{ .ACCMODE = .RDONLY }, @as(c_uint, 0));
        if (tty_fd >= 0) {
            defer _ = std.c.close(tty_fd);
            if (tiocgwinsz(tty_fd, &ws) == 0 and ws.row > 0 and ws.col > 0) {
                self.size = .{ .rows = ws.row, .cols = ws.col };
            }
        }
    }

    pub fn consumeResize(_: *Term) bool {
        return sigwinch_flag.swap(false, .monotonic);
    }

    pub fn shouldStop(_: *const Term) bool {
        return shutdown_flag.load(.monotonic);
    }

    pub fn consumeRefresh(_: *Term) bool {
        return refresh_flag.swap(false, .monotonic);
    }

    /// Returns one event per call, or null when the stdin buffer is
    /// drained and no more bytes are ready. Callers should loop until
    /// null between ticks so a fast paste doesn't leak characters.
    pub fn pollEvent(self: *Term) ?Event {
        if (self.ev_start == self.ev_end) {
            const n = posix.read(STDIN_FD, &self.ev_buf) catch 0;
            if (n == 0) return null;
            self.ev_start = 0;
            self.ev_end = n;
        }
        const parsed = parseEvent(self.ev_buf[self.ev_start..self.ev_end]);
        self.ev_start += parsed.consumed;
        return parsed.event;
    }
};

const Parsed = struct { event: Event, consumed: usize };

fn parseEvent(bytes: []const u8) Parsed {
    if (bytes.len == 0) return .{ .event = .none, .consumed = 0 };
    const b0 = bytes[0];
    if (b0 != 0x1b) return .{ .event = .{ .key = keyFromByte(b0) }, .consumed = 1 };
    if (bytes.len == 1) return .{ .event = .{ .key = .esc }, .consumed = 1 };
    // ESC-ESC: some terminals send this for a double-press of Escape.
    if (bytes[1] == 0x1b) return .{ .event = .{ .key = .esc }, .consumed = 1 };
    if (bytes[1] != '[') {
        // Unknown ESC prefix; drop just the ESC and let the next iter
        // re-parse what follows.
        return .{ .event = .none, .consumed = 1 };
    }

    // CSI: ESC [ [params...] final (final in 0x40..0x7E).
    var end: usize = 2;
    while (end < bytes.len) : (end += 1) {
        const b = bytes[end];
        if (b >= 0x40 and b <= 0x7E) break;
    }
    if (end >= bytes.len) {
        // Incomplete CSI at buffer tail. Consume the rest so the caller
        // doesn't livelock; real terminals send complete sequences.
        return .{ .event = .none, .consumed = bytes.len };
    }
    const consumed = end + 1;
    const final = bytes[end];

    // xterm mouse SGR: ESC [ < button ; col ; row M|m
    if (bytes[2] == '<') return .{ .event = parseMouse(bytes[3..consumed]), .consumed = consumed };

    // 3-byte sequences: ESC [ {A,B,C,D,H,F}
    if (consumed == 3) {
        return .{ .event = switch (final) {
            'A' => .{ .key = .up },
            'B' => .{ .key = .down },
            'C' => .{ .key = .right },
            'D' => .{ .key = .left },
            'H' => .{ .key = .home },
            'F' => .{ .key = .end },
            else => .none,
        }, .consumed = consumed };
    }

    // N~ terminators: ESC [ N ~ (home/end/page-up/page-down).
    if (final == '~' and consumed >= 4) {
        return .{ .event = switch (bytes[2]) {
            '1', '7' => .{ .key = .home },
            '4', '8' => .{ .key = .end },
            '5' => .{ .key = .page_up },
            '6' => .{ .key = .page_down },
            else => .none,
        }, .consumed = consumed };
    }

    return .{ .event = .none, .consumed = consumed };
}

fn keyFromByte(b: u8) Key {
    return switch (b) {
        0x0a, 0x0d => .enter,
        0x20 => .space,
        0x09 => .tab,
        0x08, 0x7f => .backspace,
        else => .{ .char = b },
    };
}

fn parseMouse(rest: []const u8) Event {
    var i: usize = 0;
    const button = parseNum(rest, &i);
    if (i >= rest.len or rest[i] != ';') return .none;
    i += 1;
    const col = parseNum(rest, &i);
    if (i >= rest.len or rest[i] != ';') return .none;
    i += 1;
    const row = parseNum(rest, &i);
    if (i >= rest.len) return .none;
    const term = rest[i];
    if (term != 'm' and term != 'M') return .none;

    // Mask off shift/meta/ctrl bits so modified wheel and click events
    // still register. Button codes after masking: 0 = left, 64 = wheel
    // up, 65 = wheel down.
    const base = button & ~@as(u16, 4 | 8 | 16);
    if (base == 64) return .{ .scroll = .up };
    if (base == 65) return .{ .scroll = .down };
    // Left click: SGR sends both press and release; we only act on
    // release ('m') so we don't fire on drag-starts.
    if (base == 0 and term == 'm') return .{ .click = .{ .row = row, .col = col } };
    return .none;
}

fn parseNum(bytes: []const u8, i: *usize) u16 {
    var n: u16 = 0;
    while (i.* < bytes.len) : (i.* += 1) {
        const c = bytes[i.*];
        if (c < '0' or c > '9') break;
        n = n * 10 + (c - '0');
    }
    return n;
}

fn installSigHandlers() void {
    if (comptime !have_sigwinch) return;

    const winch_act: posix.Sigaction = .{
        .handler = .{ .sigaction = sigwinchHandler },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.SIGINFO | posix.SA.RESTART,
    };
    posix.sigaction(.WINCH, &winch_act, null);

    const term_act: posix.Sigaction = .{
        .handler = .{ .handler = shutdownHandler },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(.INT, &term_act, null);
    posix.sigaction(.TERM, &term_act, null);
    posix.sigaction(.HUP, &term_act, null);

    const refresh_act: posix.Sigaction = .{
        .handler = .{ .handler = refreshHandler },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(.USR1, &refresh_act, null);

    // Auto-reap spawned editors. main.openPath fires git/difftool +
    // editor fire-and-forget so the TUI stays responsive; SA_NOCLDWAIT
    // keeps the kernel from parking those as zombies on exit.
    const chld_act: posix.Sigaction = .{
        .handler = .{ .handler = chldNoop },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.NOCLDWAIT | posix.SA.RESTART,
    };
    posix.sigaction(.CHLD, &chld_act, null);
}

fn sigwinchHandler(_: posix.SIG, _: *const posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    sigwinch_flag.store(true, .monotonic);
}

fn shutdownHandler(_: posix.SIG) callconv(.c) void {
    shutdown_flag.store(true, .monotonic);
}

fn refreshHandler(_: posix.SIG) callconv(.c) void {
    refresh_flag.store(true, .monotonic);
}

fn chldNoop(_: posix.SIG) callconv(.c) void {}

const have_sigwinch = switch (builtin.os.tag) {
    .linux,
    .macos,
    .ios,
    .watchos,
    .tvos,
    .visionos,
    .driverkit,
    .maccatalyst,
    .freebsd,
    .netbsd,
    .openbsd,
    .dragonfly,
    => true,
    else => false,
};

test "parseEvent click" {
    const p = parseEvent("\x1b[<0;10;5m");
    try std.testing.expectEqual(@as(usize, 10), p.consumed);
    switch (p.event) {
        .click => |c| {
            try std.testing.expectEqual(@as(u16, 10), c.col);
            try std.testing.expectEqual(@as(u16, 5), c.row);
        },
        else => try std.testing.expect(false),
    }
}

test "parseEvent char" {
    const p = parseEvent("q");
    try std.testing.expectEqual(@as(usize, 1), p.consumed);
    switch (p.event) {
        .key => |k| switch (k) {
            .char => |c| try std.testing.expectEqual(@as(u8, 'q'), c),
            else => try std.testing.expect(false),
        },
        else => try std.testing.expect(false),
    }
}

test "parseEvent arrows" {
    try std.testing.expect(parseEvent("\x1b[A").event.key == .up);
    try std.testing.expect(parseEvent("\x1b[B").event.key == .down);
    try std.testing.expect(parseEvent("\x1b[C").event.key == .right);
    try std.testing.expect(parseEvent("\x1b[D").event.key == .left);
    try std.testing.expect(parseEvent("\x1b[5~").event.key == .page_up);
    try std.testing.expect(parseEvent("\x1b[6~").event.key == .page_down);
    try std.testing.expect(parseEvent("\x1b").event.key == .esc);
}

test "parseEvent drains multiple events" {
    // Two arrow keys concatenated in one read.
    var bytes: []const u8 = "\x1b[A\x1b[B";
    var p = parseEvent(bytes);
    try std.testing.expectEqual(@as(usize, 3), p.consumed);
    try std.testing.expect(p.event.key == .up);
    bytes = bytes[p.consumed..];
    p = parseEvent(bytes);
    try std.testing.expect(p.event.key == .down);
    try std.testing.expectEqual(@as(usize, 3), p.consumed);
}

test "parseEvent typed fast" {
    // "abc" arriving as one read should decompose into three char events.
    var bytes: []const u8 = "abc";
    var out: [3]u8 = undefined;
    var i: usize = 0;
    while (bytes.len > 0) : (i += 1) {
        const p = parseEvent(bytes);
        try std.testing.expect(p.consumed > 0);
        out[i] = p.event.key.char;
        bytes = bytes[p.consumed..];
    }
    try std.testing.expectEqualStrings("abc", &out);
}
