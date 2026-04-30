//! Direct-libc filesystem helpers shared across modules. Lives here
//! instead of in main.zig / session.zig because the pre-extraction
//! version had identical implementations in both files. Going through
//! libc syscalls (rather than `std.posix.*` or `std.Io.File`) keeps the
//! posix error-set tables and Reader/Writer dispatch off the link
//! graph, which is the whole point of the strip-everything build.
const std = @import("std");
const builtin = @import("builtin");

pub const Mtime = struct { sec: isize, nsec: isize };

/// File size via `lseek(fd, 0, SEEK_END)`. Portable, cheap, no platform
/// variance like `fstat`/`fstatat` which Zig 0.16 gates behind statx on
/// Linux. The fd position is reset afterwards with `SEEK_SET` so the
/// caller can still read from the start. Returns null on lseek failure.
pub fn fileSize(fd: c_int) ?u64 {
    const end = std.c.lseek(fd, 0, 2); // SEEK_END
    if (end < 0) return null;
    _ = std.c.lseek(fd, 0, 0); // SEEK_SET
    return @intCast(end);
}

/// mtime of a path or null on stat failure. Zig 0.16 dropped
/// cross-platform `fstatat`, so we route through statx on Linux and
/// BSD-style `fstatat` on macOS. Either way it's one direct syscall
/// without std.posix's error wrangling.
pub fn statMtime(path_z: [*:0]const u8) ?Mtime {
    if (comptime builtin.os.tag == .linux) {
        var sx: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(
            std.os.linux.AT.FDCWD,
            path_z,
            std.os.linux.AT.SYMLINK_NOFOLLOW,
            std.os.linux.STATX{ .MTIME = true },
            &sx,
        );
        if (@as(isize, @bitCast(rc)) < 0) return null;
        return .{ .sec = @intCast(sx.mtime.sec), .nsec = @intCast(sx.mtime.nsec) };
    }
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(std.c.AT.FDCWD, path_z, &st, 0) != 0) return null;
    const ts = if (@hasField(std.c.Stat, "mtimespec")) st.mtimespec else st.mtim;
    return .{ .sec = @intCast(ts.sec), .nsec = @intCast(ts.nsec) };
}
