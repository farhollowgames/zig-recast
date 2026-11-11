// An altered version of Recast from recastnavigation 1.6.0, translated to
// Zig. Copyright (c) 2009-2010 Mikko Mononen memon@inside.org; zlib licence,
// see LICENSE.

//! The build context: where the build functions report log messages and
//! timings. Translated from `rcContext` in Recast.h and Recast.cpp.

const std = @import("std");

/// The category of a log message.
pub const LogCategory = enum(u32) {
    progress = 1,
    warning = 2,
    err = 3,
};

/// The build steps the timers measure, in upstream's order.
pub const TimerLabel = enum(u32) {
    /// The caller's total time of a build.
    total,
    /// A caller-defined time.
    temp,
    rasterize_triangles,
    build_compactheightfield,
    build_contours,
    build_contours_trace,
    build_contours_simplify,
    /// Ledge filtering (`filterLedgeSpans`).
    filter_border,
    /// Low-height filtering (`filterWalkableLowHeightSpans`).
    filter_walkable,
    median_area,
    filter_low_obstacles,
    build_polymesh,
    merge_polymesh,
    erode_area,
    mark_box_area,
    mark_cylinder_area,
    mark_convexpoly_area,
    build_distancefield,
    build_distancefield_dist,
    build_distancefield_blur,
    build_regions,
    build_regions_watershed,
    build_regions_expand,
    build_regions_flood,
    build_regions_filter,
    build_layers,
    build_polymeshdetail,
    merge_polymeshdetail,
};

/// The number of timer labels.
pub const max_timers = @typeInfo(TimerLabel).@"enum".fields.len;

/// The longest message `log` passes on; longer ones are cut to this length,
/// after an error saying so.
pub const max_message_len = 511;

/// Optional logging and timing for a build. With no `sink`, or with logging
/// or timers disabled, the calls do nothing. Every build function takes one,
/// as upstream's do; one context may be shared by builds on several threads
/// only if its sink is safe to call from them. It is passed by value; the
/// sink's `ptr` must outlive every build given the context.
pub const Context = struct {
    /// What receives the messages and timings, or null for nothing.
    sink: ?Sink = null,
    log_enabled: bool = true,
    timer_enabled: bool = true,

    /// A receiver of log messages and timings: upstream's virtual `do…`
    /// methods.
    pub const Sink = struct {
        ptr: *anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            resetLog: *const fn (ptr: *anyopaque) void,
            /// `message` is valid only during the call.
            log: *const fn (ptr: *anyopaque, category: LogCategory, message: []const u8) void,
            resetTimers: *const fn (ptr: *anyopaque) void,
            startTimer: *const fn (ptr: *anyopaque, label: TimerLabel) void,
            stopTimer: *const fn (ptr: *anyopaque, label: TimerLabel) void,
            /// The accumulated time of a timer, or -1 if it never ran.
            accumulatedTime: *const fn (ptr: *anyopaque, label: TimerLabel) i32,
        };
    };

    /// A context that reports nothing.
    pub const none: Context = .{};

    pub fn enableLog(ctx: *Context, state: bool) void {
        ctx.log_enabled = state;
    }

    pub fn enableTimer(ctx: *Context, state: bool) void {
        ctx.timer_enabled = state;
    }

    /// Clears the sink's log.
    pub fn resetLog(ctx: Context) void {
        if (!ctx.log_enabled) return;
        const sink = ctx.sink orelse return;
        sink.vtable.resetLog(sink.ptr);
    }

    /// Formats a message and passes it to the sink. A message longer than
    /// `max_message_len` is cut to that length, and an error saying so is
    /// logged before it.
    pub fn log(
        ctx: Context,
        category: LogCategory,
        comptime format: []const u8,
        args: anytype,
    ) void {
        if (!ctx.log_enabled) return;
        const sink = ctx.sink orelse return;
        var buffer: [max_message_len]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        writer.print(format, args) catch {
            const truncated = "Log message was truncated";
            sink.vtable.log(sink.ptr, .err, truncated);
        };
        sink.vtable.log(sink.ptr, category, writer.buffered());
    }

    /// Clears the sink's timers.
    pub fn resetTimers(ctx: Context) void {
        if (!ctx.timer_enabled) return;
        const sink = ctx.sink orelse return;
        sink.vtable.resetTimers(sink.ptr);
    }

    pub fn startTimer(ctx: Context, label: TimerLabel) void {
        if (!ctx.timer_enabled) return;
        const sink = ctx.sink orelse return;
        sink.vtable.startTimer(sink.ptr, label);
    }

    pub fn stopTimer(ctx: Context, label: TimerLabel) void {
        if (!ctx.timer_enabled) return;
        const sink = ctx.sink orelse return;
        sink.vtable.stopTimer(sink.ptr, label);
    }

    /// The accumulated time of a timer, or -1 if timers are disabled or the
    /// timer never ran.
    pub fn accumulatedTime(ctx: Context, label: TimerLabel) i32 {
        if (!ctx.timer_enabled) return -1;
        const sink = ctx.sink orelse return -1;
        return sink.vtable.accumulatedTime(sink.ptr, label);
    }
};

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

const Recorder = struct {
    text: [2048]u8 = undefined,
    len: usize = 0,

    fn sink(recorder: *Recorder) Context.Sink {
        return .{ .ptr = recorder, .vtable = &vtable };
    }

    const vtable: Context.Sink.VTable = .{
        .resetLog = resetLog,
        .log = logMessage,
        .resetTimers = resetLog,
        .startTimer = timer,
        .stopTimer = timer,
        .accumulatedTime = accumulatedTime,
    };

    fn resetLog(ptr: *anyopaque) void {
        const recorder: *Recorder = @ptrCast(@alignCast(ptr));
        recorder.len = 0;
    }

    fn logMessage(ptr: *anyopaque, category: LogCategory, message: []const u8) void {
        const recorder: *Recorder = @ptrCast(@alignCast(ptr));
        const line = std.fmt.bufPrint(
            recorder.text[recorder.len..],
            "{d} {d}\n",
            .{ @backingInt(category), message.len },
        ) catch unreachable;
        recorder.len += line.len;
    }

    fn timer(ptr: *anyopaque, label: TimerLabel) void {
        _ = ptr;
        _ = label;
    }

    fn accumulatedTime(ptr: *anyopaque, label: TimerLabel) i32 {
        _ = ptr;
        return @intCast(@backingInt(label));
    }
};

test "a long message is cut after an error saying so" {
    var recorder: Recorder = .{};
    const ctx: Context = .{ .sink = recorder.sink() };
    const long: [600]u8 = @splat('x');
    ctx.log(.warning, "{s}", .{&long});
    ctx.log(.progress, "{d}", .{12});
    try testing.expectEqualStrings("3 25\n2 511\n1 2\n", recorder.text[0..recorder.len]);
}

test "disabled logging and timers report nothing" {
    var recorder: Recorder = .{};
    var ctx: Context = .{ .sink = recorder.sink() };
    ctx.enableLog(false);
    ctx.enableTimer(false);
    ctx.log(.err, "lost", .{});
    try testing.expectEqual(0, recorder.len);
    try testing.expectEqual(-1, ctx.accumulatedTime(.build_layers));
    ctx.enableTimer(true);
    try testing.expectEqual(25, ctx.accumulatedTime(.build_layers));
    try testing.expectEqual(-1, Context.none.accumulatedTime(.total));
}
