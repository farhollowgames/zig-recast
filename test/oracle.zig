//! What the oracle tests share: a sink that records the port's log and
//! timer calls as the shim records the original's, and the comparisons of
//! logs, dumps and outcomes.

const std = @import("std");
const recast = @import("recast");
const upstream = @import("upstream.zig");
const dump = @import("dump.zig").dump;

const testing = std.testing;
const gpa = testing.allocator;

/// A sink for the port's context that records as the shim's
/// `RecordingContext` does.
pub const Recorder = struct {
    text: std.ArrayList(u8) = .empty,
    failed: bool = false,

    pub fn context(recorder: *Recorder) recast.Context {
        return .{ .sink = .{ .ptr = recorder, .vtable = &vtable } };
    }

    const vtable: recast.Context.Sink.VTable = .{
        .resetLog = resetLog,
        .log = log,
        .resetTimers = resetTimers,
        .startTimer = startTimer,
        .stopTimer = stopTimer,
        .accumulatedTime = accumulatedTime,
    };

    fn fromPtr(ptr: *anyopaque) *Recorder {
        return @ptrCast(@alignCast(ptr));
    }

    fn print(recorder: *Recorder, comptime format: []const u8, args: anytype) void {
        recorder.text.print(gpa, format, args) catch {
            recorder.failed = true;
        };
    }

    fn resetLog(ptr: *anyopaque) void {
        fromPtr(ptr).print("R\n", .{});
    }

    fn log(ptr: *anyopaque, category: recast.LogCategory, message: []const u8) void {
        fromPtr(ptr).print("L{d} {s}\n", .{ @backingInt(category), message });
    }

    fn resetTimers(ptr: *anyopaque) void {
        fromPtr(ptr).print("T\n", .{});
    }

    fn startTimer(ptr: *anyopaque, label: recast.TimerLabel) void {
        fromPtr(ptr).print("S{d}\n", .{@backingInt(label)});
    }

    fn stopTimer(ptr: *anyopaque, label: recast.TimerLabel) void {
        fromPtr(ptr).print("E{d}\n", .{@backingInt(label)});
    }

    /// A time that tells the labels apart, as the shim's.
    fn accumulatedTime(ptr: *anyopaque, label: recast.TimerLabel) i32 {
        _ = ptr;
        return @as(i32, @intCast(@backingInt(label))) * 3 + 1;
    }
};

/// The port's and the original's recorded contexts, compared after each
/// step and then cleared.
pub const Logs = struct {
    recorder: Recorder = .{},
    original: *upstream.Log,

    pub fn init() !Logs {
        upstream.shim_init();
        return .{ .original = upstream.shim_log_create() orelse return error.OutOfMemory };
    }

    pub fn deinit(logs: *Logs) void {
        logs.recorder.text.deinit(gpa);
        upstream.shim_log_destroy(logs.original);
    }

    pub fn port(logs: *Logs) recast.Context {
        return logs.recorder.context();
    }

    pub fn expectSame(logs: *Logs, step: []const u8) !void {
        if (logs.recorder.failed) return error.OutOfMemory;
        const expected = upstream.logText(logs.original);
        const actual = logs.recorder.text.items;
        if (!std.mem.eql(u8, expected, actual) and !try samePointerless(expected, actual)) {
            std.debug.print(
                "{s}: logs differ\n--- original\n{s}--- port\n{s}---\n",
                .{ step, expected, actual },
            );
            return error.TestExpectedEqual;
        }
        logs.recorder.text.clearRetainingCapacity();
        upstream.shim_log_clear(logs.original);
    }
};

/// Whether two logs are the same once the addresses two contour warnings
/// print (C's `%p`, `0x` and hex digits) are taken out.
pub fn samePointerless(expected: []const u8, actual: []const u8) !bool {
    const a = try withoutAddresses(expected);
    defer gpa.free(a);
    const b = try withoutAddresses(actual);
    defer gpa.free(b);
    return std.mem.eql(u8, a, b);
}

pub fn withoutAddresses(text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        try out.append(gpa, text[i]);
        if (text[i] == '0' and i + 1 < text.len and text[i + 1] == 'x') {
            try out.append(gpa, 'x');
            i += 2;
            while (i < text.len and std.ascii.isHex(text[i])) i += 1;
            i -= 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn expectSameDump(step: []const u8, port: anytype, original: anytype) !void {
    const expected = try upstream.dump(gpa, original);
    defer gpa.free(expected);
    const actual = try dump(gpa, port);
    defer gpa.free(actual);
    if (std.mem.findDiff(u8, expected, actual)) |at| {
        std.debug.print(
            "{s}: dumps differ at byte {d} (original {d} bytes, port {d})\n",
            .{ step, at, expected.len, actual.len },
        );
        return error.TestExpectedEqual;
    }
}

/// Checks that a step succeeded on both sides or failed on both, with the
/// same log, and says whether it succeeded.
pub fn sameOutcome(logs: *Logs, step: []const u8, port_ok: bool, original_ok: bool) !bool {
    if (port_ok != original_ok) {
        std.debug.print("{s}: port ok {}, original ok {}\n", .{ step, port_ok, original_ok });
        return error.TestExpectedEqual;
    }
    try logs.expectSame(step);
    return port_ok;
}

pub fn succeeded(result: anytype) bool {
    return if (result) |_| true else |_| false;
}
