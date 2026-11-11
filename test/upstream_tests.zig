//! Upstream's own Recast tests (`Tests/Recast` in recastnavigation 1.6.0),
//! section by section: each input goes through the port and the original,
//! the outputs must match byte for byte, and the port must give what the
//! upstream test requires. `Tests_Alloc.cpp` and `Bench_rcVector.cpp` test
//! `rcVector`, and the `rcSwap`, `rcAbs` and `rcSqr` cases test helpers the
//! port has no counterpart of: Zig's `std.ArrayList`, `std.mem.swap`, `@abs`
//! and multiplication take their place.

const std = @import("std");
const recast = @import("recast");
const upstream = @import("upstream.zig");
const oracle = @import("oracle.zig");

const testing = std.testing;
const gpa = testing.allocator;
const walkable = recast.walkable_area;

// Tests_Recast.cpp

test "rcMin, rcMax and rcClamp: upstream's cases" {
    const pairs = [_][2]f32{ .{ 1, 2 }, .{ 2, 1 }, .{ 1, 1 } };
    for (pairs) |p| {
        try testing.expectEqual(upstream.shim_min(p[0], p[1]), recast.selectMin(p[0], p[1]));
        try testing.expectEqual(upstream.shim_max(p[0], p[1]), recast.selectMax(p[0], p[1]));
    }
    try testing.expectEqual(1, recast.selectMin(1, 2));
    try testing.expectEqual(1, recast.selectMin(2, 1));
    try testing.expectEqual(1, recast.selectMin(1, 1));
    try testing.expectEqual(2, recast.selectMax(1, 2));
    try testing.expectEqual(2, recast.selectMax(2, 1));
    try testing.expectEqual(1, recast.selectMax(1, 1));

    const clamps = [_][4]i32{ .{ 2, 0, 1, 1 }, .{ 1, 0, 2, 1 }, .{ 0, 1, 2, 1 } };
    for (clamps) |c| {
        const port = recast.clamp(i32, c[0], c[1], c[2]);
        try testing.expectEqual(upstream.shim_clamp_int(c[0], c[1], c[2]), port);
        try testing.expectEqual(c[3], port);
    }
    // rcSqrt is sqrtf; the port calls @sqrt.
    try testing.expectEqual(upstream.shim_sqrt(4), @sqrt(@as(f32, 4)));
    try testing.expectEqual(upstream.shim_sqrt(81), @sqrt(@as(f32, 81)));
    try testing.expectEqual(2, @sqrt(@as(f32, 4)));
}

fn expectVector(original: [3]f32, port: [3]f32, expected: [3]f32) !void {
    try testing.expectEqualSlices(u8, std.mem.asBytes(&original), std.mem.asBytes(&port));
    for (port, expected) |p, e| try testing.expectApproxEqAbs(e, p, 1e-4);
}

test "rcVcross, rcVdot, rcVmad, rcVadd, rcVsub: upstream's cases" {
    var original: [3]f32 = undefined;
    const v1: [3]f32 = .{ 3, -3, 1 };
    const v2: [3]f32 = .{ 4, 9, 2 };
    upstream.shim_vcross(&original, &v1, &v2);
    try expectVector(original, recast.vcross(&v1, &v2), .{ -15, -2, 39 });
    upstream.shim_vcross(&original, &v1, &v1);
    try expectVector(original, recast.vcross(&v1, &v1), .{ 0, 0, 0 });

    const x: [3]f32 = .{ 1, 0, 0 };
    try testing.expectEqual(upstream.shim_vdot(&x, &x), recast.vdot(&x, &x));
    try testing.expectEqual(1, recast.vdot(&x, &x));
    const a: [3]f32 = .{ 1, 2, 3 };
    const zero: [3]f32 = .{ 0, 0, 0 };
    try testing.expectEqual(upstream.shim_vdot(&a, &zero), recast.vdot(&a, &zero));
    try testing.expectEqual(0, recast.vdot(&a, &zero));

    const b: [3]f32 = .{ 0, 2, 4 };
    upstream.shim_vmad(&original, &a, &b, 2);
    try expectVector(original, recast.vmad(&a, &b, 2), .{ 1, 6, 11 });
    const c: [3]f32 = .{ 5, 6, 7 };
    upstream.shim_vmad(&original, &a, &c, 0);
    try expectVector(original, recast.vmad(&a, &c, 0), .{ 1, 2, 3 });

    upstream.shim_vadd(&original, &a, &c);
    try expectVector(original, recast.vadd(&a, &c), .{ 6, 8, 10 });
    const d: [3]f32 = .{ 5, 4, 3 };
    upstream.shim_vsub(&original, &d, &a);
    try expectVector(original, recast.vsub(&d, &a), .{ 4, 2, 0 });
}

test "rcVmin, rcVmax and rcVcopy: upstream's cases" {
    const cases = [_]struct { v1: [3]f32, v2: [3]f32, min: [3]f32, max: [3]f32 }{
        .{ .v1 = .{ 5, 4, 0 }, .v2 = .{ 1, 2, 9 }, .min = .{ 1, 2, 0 }, .max = .{ 5, 4, 9 } },
        .{ .v1 = .{ 1, 2, 3 }, .v2 = .{ 4, 5, 6 }, .min = .{ 1, 2, 3 }, .max = .{ 4, 5, 6 } },
        .{ .v1 = .{ 4, 5, 6 }, .v2 = .{ 1, 2, 3 }, .min = .{ 1, 2, 3 }, .max = .{ 4, 5, 6 } },
    };
    for (cases) |case| {
        var port = case.v1;
        var original = case.v1;
        recast.vmin(&port, &case.v2);
        upstream.shim_vmin(&original, &case.v2);
        try expectVector(original, port, case.min);
        port = case.v1;
        original = case.v1;
        recast.vmax(&port, &case.v2);
        upstream.shim_vmax(&original, &case.v2);
        try expectVector(original, port, case.max);
    }
    // The port copies by assignment.
    const v1: [3]f32 = .{ 5, 4, 0 };
    var original: [3]f32 = .{ 1, 2, 9 };
    upstream.shim_vcopy(&original, &v1);
    try expectVector(original, v1, .{ 5, 4, 0 });
}

test "rcVdist, rcVdistSqr and rcVnormalize: upstream's cases" {
    const v1: [3]f32 = .{ 3, 1, 3 };
    const v2: [3]f32 = .{ 1, 3, 1 };
    const zero: [3]f32 = .{ 0, 0, 0 };
    try testing.expectEqual(upstream.shim_vdist(&v1, &v2), recast.vdist(&v1, &v2));
    try testing.expectApproxEqAbs(3.4641, recast.vdist(&v1, &v2), 1e-4);
    const magnitude = @sqrt(v1[0] * v1[0] + v1[1] * v1[1] + v1[2] * v1[2]);
    try testing.expectEqual(upstream.shim_vdist(&v1, &zero), recast.vdist(&v1, &zero));
    try testing.expectApproxEqAbs(magnitude, recast.vdist(&v1, &zero), 1e-5);
    try testing.expectEqual(upstream.shim_vdist_sqr(&v1, &v2), recast.vdistSqr(&v1, &v2));
    try testing.expectEqual(12, recast.vdistSqr(&v1, &v2));
    try testing.expectEqual(upstream.shim_vdist_sqr(&v1, &zero), recast.vdistSqr(&v1, &zero));
    try testing.expectEqual(19, recast.vdistSqr(&v1, &zero));

    var port: [3]f32 = .{ 3, 3, 3 };
    var original = port;
    recast.vnormalize(&port);
    upstream.shim_vnormalize(&original);
    const third = @sqrt(@as(f32, 1.0 / 3.0));
    try expectVector(original, port, .{ third, third, third });
}

test "rcCalcBounds, rcCalcGridSize and rcCreateHeightfield: upstream's cases" {
    const one = [_]f32{ 1, 2, 3 };
    const two = [_]f32{ 1, 2, 3, 0, 2, 5 };
    const cases = [_]struct { verts: []const f32, bmin: [3]f32, bmax: [3]f32 }{
        .{ .verts = &one, .bmin = .{ 1, 2, 3 }, .bmax = .{ 1, 2, 3 } },
        .{ .verts = &two, .bmin = .{ 0, 2, 3 }, .bmax = .{ 1, 2, 5 } },
    };
    for (cases) |case| {
        var bmin: [3]f32 = undefined;
        var bmax: [3]f32 = undefined;
        var original_min: [3]f32 = undefined;
        var original_max: [3]f32 = undefined;
        recast.calcBounds(case.verts, &bmin, &bmax);
        const nv: c_int = @intCast(case.verts.len / 3);
        upstream.shim_calc_bounds(case.verts.ptr, nv, &original_min, &original_max);
        try expectVector(original_min, bmin, case.bmin);
        try expectVector(original_max, bmax, case.bmax);
    }

    const verts = [_]f32{ 1, 2, 3, 0, 2, 6 };
    var bmin: [3]f32 = undefined;
    var bmax: [3]f32 = undefined;
    recast.calcBounds(&verts, &bmin, &bmax);
    const cell_size = 1.5;
    const grid = recast.calcGridSize(&bmin, &bmax, cell_size);
    var width: c_int = undefined;
    var height: c_int = undefined;
    upstream.shim_calc_grid_size(&bmin, &bmax, cell_size, &width, &height);
    try testing.expectEqual(width, grid.width);
    try testing.expectEqual(height, grid.height);
    try testing.expectEqual(1, grid.width);
    try testing.expectEqual(2, grid.height);

    var logs: oracle.Logs = try .init();
    defer logs.deinit();
    var hf: recast.Heightfield = try .init(gpa, width, height, &bmin, &bmax, cell_size, 2);
    defer hf.deinit(gpa);
    const log = logs.original;
    const original = upstream.shim_hf_create(log, width, height, &bmin, &bmax, cell_size, 2) orelse
        return error.OutOfMemory;
    defer upstream.shim_hf_free(original);
    try oracle.expectSameDump("create heightfield", &hf, original);
    try testing.expectEqual(width, hf.width);
    try testing.expectEqual(height, hf.height);
    try testing.expectEqual(bmin, hf.bmin);
    try testing.expectEqual(bmax, hf.bmax);
    try testing.expectEqual(cell_size, hf.cs);
    try testing.expectEqual(2, hf.ch);
    try testing.expectEqual(@as(usize, @intCast(width * height)), hf.spans.len);
    try testing.expectEqual(null, hf.pools);
    try testing.expectEqual(null, hf.freelist);
}

test "rcMarkWalkableTriangles and rcClearUnwalkableTriangles: upstream's cases" {
    var logs: oracle.Logs = try .init();
    defer logs.deinit();
    const ctx = logs.port();
    const verts = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, -1 };
    const walkable_tri = [_]i32{ 0, 1, 2 };
    const unwalkable_tri = [_]i32{ 0, 2, 1 };
    const Case = struct { slope: f32, tri: []const i32, area: u8, expected: u8, mark: bool };
    const cases = [_]Case{
        // rcMarkWalkableTriangles: one walkable triangle, one not, an
        // unwalkable triangle's id kept, a slope equal to the limit
        // unwalkable.
        .{ .slope = 45, .tri = &walkable_tri, .area = 0, .expected = walkable, .mark = true },
        .{ .slope = 45, .tri = &unwalkable_tri, .area = 0, .expected = 0, .mark = true },
        .{ .slope = 45, .tri = &unwalkable_tri, .area = 42, .expected = 42, .mark = true },
        .{ .slope = 0, .tri = &walkable_tri, .area = 0, .expected = 0, .mark = true },
        // rcClearUnwalkableTriangles: an unwalkable triangle cleared, a
        // walkable one kept, a slope equal to the limit unwalkable.
        .{ .slope = 45, .tri = &unwalkable_tri, .area = 42, .expected = 0, .mark = false },
        .{ .slope = 45, .tri = &walkable_tri, .area = 42, .expected = 42, .mark = false },
        .{ .slope = 0, .tri = &walkable_tri, .area = 42, .expected = 0, .mark = false },
    };
    for (cases) |case| {
        var areas = [_]u8{case.area};
        var original_areas = areas;
        if (case.mark) {
            recast.markWalkableTriangles(ctx, case.slope, &verts, case.tri, &areas);
            const tri = case.tri.ptr;
            upstream.shim_mark_walkable(
                logs.original,
                case.slope,
                &verts,
                3,
                tri,
                1,
                &original_areas,
            );
        } else {
            recast.clearUnwalkableTriangles(ctx, case.slope, &verts, case.tri, &areas);
            const tri = case.tri.ptr;
            upstream.shim_clear_unwalkable(
                logs.original,
                case.slope,
                &verts,
                3,
                tri,
                1,
                &original_areas,
            );
        }
        try logs.expectSame("slopes");
        try testing.expectEqual(original_areas[0], areas[0]);
        try testing.expectEqual(case.expected, areas[0]);
    }
}

/// A heightfield on each side, changed in step and compared.
const Fields = struct {
    logs: oracle.Logs,
    port: recast.Heightfield,
    original: *upstream.Heightfield,

    fn init(width: i32, height: i32, bmin: [3]f32, bmax: [3]f32, cs: f32, ch: f32) !Fields {
        var logs: oracle.Logs = try .init();
        errdefer logs.deinit();
        var port: recast.Heightfield = try .init(gpa, width, height, &bmin, &bmax, cs, ch);
        errdefer port.deinit(gpa);
        const log = logs.original;
        const original = upstream.shim_hf_create(log, width, height, &bmin, &bmax, cs, ch) orelse
            return error.OutOfMemory;
        return .{ .logs = logs, .port = port, .original = original };
    }

    fn deinit(f: *Fields) void {
        upstream.shim_hf_free(f.original);
        f.port.deinit(gpa);
        f.logs.deinit();
    }

    fn addSpan(f: *Fields, x: i32, z: i32, smin: u16, smax: u16, area: u8, merge: i32) !void {
        const ok = recast.addSpan(f.logs.port(), gpa, &f.port, x, z, smin, smax, area, merge);
        const original = f.original;
        const original_ok = upstream.shim_add_span(
            f.logs.original,
            original,
            x,
            z,
            smin,
            smax,
            area,
            merge,
        );
        const same = try oracle.sameOutcome(
            &f.logs,
            "add span",
            oracle.succeeded(ok),
            original_ok != 0,
        );
        try testing.expect(same);
        try f.expectSame("add span");
    }

    fn expectSame(f: *Fields, step: []const u8) !void {
        try f.logs.expectSame(step);
        try oracle.expectSameDump(step, &f.port, f.original);
    }

    /// The port's spans in column (x, z), from the bottom.
    fn column(f: *const Fields, x: i32, z: i32, out: []recast.Span) []recast.Span {
        var n: usize = 0;
        var span = f.port.spans[@intCast(x + z * f.port.width)];
        while (span) |s| : (span = s.next) {
            out[n] = s.*;
            n += 1;
        }
        return out[0..n];
    }

    /// Checks column (x, z) holds spans of these limits and areas.
    fn expectColumn(f: *const Fields, x: i32, z: i32, expected: []const [3]u16) !void {
        var buffer: [16]recast.Span = undefined;
        const spans = f.column(x, z, &buffer);
        try testing.expectEqual(expected.len, spans.len);
        for (spans, expected) |s, e| {
            try testing.expectEqual(e[0], s.smin);
            try testing.expectEqual(e[1], s.smax);
            try testing.expectEqual(e[2], s.area);
        }
    }
};

test "rcRasterizeTriangles: upstream's three overloads" {
    const verts = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, -1, 0, 0, 1 };
    const tris = [_]i32{ 0, 1, 2, 0, 3, 1 };
    const tris_u16 = [_]u16{ 0, 1, 2, 0, 3, 1 };
    const flat = [_]f32{ 0, 0, 0, 1, 0, 0, 0, 0, -1, 0, 0, 0, 0, 0, 1, 1, 0, 0 };
    const areas = [_]u8{ 1, 2 };
    var bmin: [3]f32 = undefined;
    var bmax: [3]f32 = undefined;
    recast.calcBounds(&verts, &bmin, &bmax);
    const grid = recast.calcGridSize(&bmin, &bmax, 0.5);
    for (0..3) |overload| {
        var f: Fields = try .init(grid.width, grid.height, bmin, bmax, 0.5, 0.5);
        defer f.deinit();
        const ctx = f.logs.port();
        const log = f.logs.original;
        switch (overload) {
            0 => {
                try recast.rasterizeTriangles(ctx, gpa, &verts, i32, &tris, &areas, &f.port, 1);
                const ok = upstream.shim_rasterize_triangles(
                    log,
                    &verts,
                    4,
                    &tris,
                    &areas,
                    2,
                    f.original,
                    1,
                );
                try testing.expect(ok != 0);
            },
            1 => {
                try recast.rasterizeTriangles(ctx, gpa, &verts, u16, &tris_u16, &areas, &f.port, 1);
                const original = f.original;
                const ok = upstream.shim_rasterize_triangles_u16(
                    log,
                    &verts,
                    4,
                    &tris_u16,
                    &areas,
                    2,
                    original,
                    1,
                );
                try testing.expect(ok != 0);
            },
            else => {
                try recast.rasterizeUnindexedTriangles(ctx, gpa, &flat, &areas, &f.port, 1);
                const ok = upstream.shim_rasterize_unindexed(log, &flat, &areas, 2, f.original, 1);
                try testing.expect(ok != 0);
            },
        }
        try f.expectSame("rasterize");
        try f.expectColumn(0, 0, &.{.{ 0, 1, 1 }});
        try f.expectColumn(0, 1, &.{.{ 0, 1, 1 }});
        try f.expectColumn(0, 2, &.{.{ 0, 1, 2 }});
        try f.expectColumn(0, 3, &.{.{ 0, 1, 2 }});
        try f.expectColumn(1, 0, &.{});
        try f.expectColumn(1, 1, &.{.{ 0, 1, 1 }});
        try f.expectColumn(1, 2, &.{.{ 0, 1, 2 }});
        try f.expectColumn(1, 3, &.{});
    }
}

// Tests_RecastRasterization.cpp

/// The 4 by 4 field of upstream's rcAddSpan tests: cells of 1 by 2.
fn addSpanFields() !Fields {
    return .init(4, 4, .{ 0, 0, 0 }, .{ 4, 20, 4 }, 1, 2);
}

test "rcAddSpan: upstream's sections" {
    const area = 42;
    {
        // A span in an empty heightfield.
        var f = try addSpanFields();
        defer f.deinit();
        try f.addSpan(0, 0, 0, 1, area, 1);
        try f.expectColumn(0, 0, &.{.{ 0, 1, area }});
    }
    {
        // Spans of zero or negative size are ignored.
        var f = try addSpanFields();
        defer f.deinit();
        try f.addSpan(0, 0, 0, 0, area, 1);
        try f.expectColumn(0, 0, &.{});
        try f.addSpan(0, 0, 1, 0, area, 1);
        try f.expectColumn(0, 0, &.{});
    }
    {
        // Spans not touching stay apart.
        var f = try addSpanFields();
        defer f.deinit();
        try f.addSpan(0, 0, 0, 1, area, 1);
        try f.addSpan(0, 0, 2, 3, area, 1);
        try f.expectColumn(0, 0, &.{ .{ 0, 1, area }, .{ 2, 3, area } });
    }
    {
        // Merged spans within the merge threshold take the higher area.
        var f = try addSpanFields();
        defer f.deinit();
        try f.addSpan(0, 0, 0, 1, 42, 1);
        try f.addSpan(0, 0, 1, 2, 24, 1);
        try f.expectColumn(0, 0, &.{.{ 0, 2, 42 }});
    }
    {
        // Beyond it, the area of the span added last.
        var f = try addSpanFields();
        defer f.deinit();
        try f.addSpan(0, 0, 0, 1, 42, 1);
        try f.addSpan(0, 0, 1, 8, 24, 1);
        try f.expectColumn(0, 0, &.{.{ 0, 8, 24 }});
    }
    {
        // A span merges with one it touches.
        var f = try addSpanFields();
        defer f.deinit();
        try f.addSpan(0, 0, 0, 1, area, 1);
        try f.addSpan(0, 0, 1, 2, area, 1);
        try f.expectColumn(0, 0, &.{.{ 0, 2, area }});
    }
    {
        // A span merges with the spans above and below it.
        var f = try addSpanFields();
        defer f.deinit();
        try f.addSpan(0, 0, 0, 1, area, 1);
        try f.addSpan(0, 0, 2, 3, area, 1);
        try f.expectColumn(0, 0, &.{ .{ 0, 1, area }, .{ 2, 3, area } });
        try f.addSpan(0, 0, 1, 2, area, 1);
        try f.expectColumn(0, 0, &.{.{ 0, 3, area }});
    }
    {
        // Spans are sorted up the column.
        var f = try addSpanFields();
        defer f.deinit();
        try f.addSpan(0, 0, 2, 3, area, 1);
        try f.addSpan(0, 0, 0, 1, area, 1);
        try f.addSpan(0, 0, 6, 7, area, 1);
        try f.expectColumn(0, 0, &.{ .{ 0, 1, area }, .{ 2, 3, area }, .{ 6, 7, area } });
    }
    {
        // A span inside another merges into it.
        var f = try addSpanFields();
        defer f.deinit();
        try f.addSpan(0, 0, 0, 8, area, 1);
        try f.addSpan(0, 0, 2, 3, area, 1);
        try f.expectColumn(0, 0, &.{.{ 0, 8, area }});
    }
    {
        // Overlapping spans merge.
        var f = try addSpanFields();
        defer f.deinit();
        try f.addSpan(0, 0, 0, 4, area, 1);
        try f.addSpan(0, 0, 2, 6, area, 1);
        try f.expectColumn(0, 0, &.{.{ 0, 6, area }});
    }
}

test "allocSpan: more spans than a pool holds take another pool, as upstream's" {
    var f: Fields = try .init(50, 50, .{ 0, 0, 0 }, .{ 50, 20, 50 }, 1, 2);
    defer f.deinit();
    var x: i32 = 0;
    while (x < 50) : (x += 1) {
        var z: i32 = 0;
        while (z < 50) : (z += 1) {
            const ok = recast.addSpan(f.logs.port(), gpa, &f.port, x, z, 0, 1, 42, 1);
            const original_ok = upstream.shim_add_span(
                f.logs.original,
                f.original,
                x,
                z,
                0,
                1,
                42,
                1,
            );
            const port_ok = oracle.succeeded(ok);
            try testing.expect(
                try oracle.sameOutcome(&f.logs, "add span", port_ok, original_ok != 0),
            );
        }
    }
    try f.expectSame("add spans");
    try testing.expect(f.port.pools.?.next != null);
}

/// The 10 by 10 by 10 field of upstream's rcRasterizeTriangle tests.
fn triangleFields() !Fields {
    return .init(10, 10, .{ 0, 0, 0 }, .{ 10, 10, 10 }, 1, 1);
}

fn rasterizeBoth(f: *Fields, v0: [3]f32, v1: [3]f32, v2: [3]f32) !void {
    try recast.rasterizeTriangle(f.logs.port(), gpa, &v0, &v1, &v2, walkable, &f.port, 1);
    const log = f.logs.original;
    try testing.expect(
        upstream.shim_rasterize_triangle(log, &v0, &v1, &v2, walkable, f.original, 1) != 0,
    );
    try f.expectSame("rasterize triangle");
}

/// Checks that only the listed columns hold spans, each one span from
/// `smin` to `smax`.
fn expectOnly(f: *const Fields, expected: []const [4]u16) !void {
    var x: i32 = 0;
    while (x < 10) : (x += 1) {
        var z: i32 = 0;
        while (z < 10) : (z += 1) {
            const span: ?[4]u16 = for (expected) |e| {
                if (e[0] == x and e[1] == z) break e;
            } else null;
            if (span) |e| {
                try f.expectColumn(x, z, &.{.{ e[2], e[3], walkable }});
            } else {
                try f.expectColumn(x, z, &.{});
            }
        }
    }
}

test "rcRasterizeTriangle: upstream's sections" {
    {
        // A triangle in the xz-plane fills (0,0), (0,1) and (1,0).
        var f = try triangleFields();
        defer f.deinit();
        try rasterizeBoth(&f, .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 0, 0, 2 });
        try expectOnly(&f, &.{ .{ 0, 0, 0, 1 }, .{ 0, 1, 0, 1 }, .{ 1, 0, 0, 1 } });
    }
    {
        // A triangle inside one voxel.
        var f = try triangleFields();
        defer f.deinit();
        try rasterizeBoth(&f, .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 0, 1 });
        try expectOnly(&f, &.{.{ 0, 0, 0, 1 }});
    }
    {
        // Triangles are clipped by the heightfield's bounds.
        var f = try triangleFields();
        defer f.deinit();
        try rasterizeBoth(&f, .{ -2, 0, -2 }, .{ 4, 0, -2 }, .{ -2, 0, 4 });
        try expectOnly(&f, &.{ .{ 0, 0, 0, 1 }, .{ 0, 1, 0, 1 }, .{ 1, 0, 0, 1 } });
    }
    {
        // Triangles outside the bounds, below and above them give nothing.
        var f = try triangleFields();
        defer f.deinit();
        try rasterizeBoth(&f, .{ -5, 0, -5 }, .{ -5, 0, 5 }, .{ 5, 0, -5 });
        try expectOnly(&f, &.{});
        try rasterizeBoth(&f, .{ 0, -1, 0 }, .{ 5, -1, 5 }, .{ 5, -1, 0 });
        try expectOnly(&f, &.{});
        try rasterizeBoth(&f, .{ 0, 40, 0 }, .{ 5, 40, 5 }, .{ 5, 40, 0 });
        try expectOnly(&f, &.{});
    }
    {
        // A voxel the clipped triangle barely overlaps gets a span.
        var f = try triangleFields();
        defer f.deinit();
        try rasterizeBoth(&f, .{ -1, 0, -1 }, .{ 1.01, 0, -1 }, .{ -1, 0, 1.01 });
        try expectOnly(&f, &.{.{ 0, 0, 0, 1 }});
    }
    {
        // A span covers every voxel the triangle touches vertically.
        var f = try triangleFields();
        defer f.deinit();
        try rasterizeBoth(&f, .{ 0, 0, 0 }, .{ 0.5, 0, 0.5 }, .{ 0.5, 2.01, 0.5 });
        try expectOnly(&f, &.{.{ 0, 0, 0, 3 }});
    }
    {
        // A sloped triangle gives spans of varying heights.
        var f = try triangleFields();
        defer f.deinit();
        try rasterizeBoth(&f, .{ 0, 0, 0.5 }, .{ 4, 0, 0.5 }, .{ 2, 2, 0.5 });
        const expected = [_][4]u16{
            .{ 0, 0, 0, 1 }, .{ 3, 0, 0, 1 }, .{ 1, 0, 0, 2 }, .{ 2, 0, 0, 2 },
        };
        try expectOnly(&f, &expected);
    }
    {
        // A triangle crossing the y bounds is clamped to them.
        var f = try triangleFields();
        defer f.deinit();
        try rasterizeBoth(&f, .{ 0, -5, 0 }, .{ 1, -5, 1 }, .{ 0.5, 15, 0.5 });
        try expectOnly(&f, &.{.{ 0, 0, 0, 10 }});
    }
    {
        // Upstream skips this section: degenerate triangles rasterize as a
        // line or point of some volume. The port matches what it does.
        var f = try triangleFields();
        defer f.deinit();
        try rasterizeBoth(&f, .{ 1, 0, 0.5 }, .{ 2, 0, 0.5 }, .{ 4, 0, 0.5 });
        try rasterizeBoth(&f, .{ 0.5, 0, 0.5 }, .{ 0.5, 0, 0.5 }, .{ 0.5, 0, 0.5 });
    }
    {
        // A triangle outside the field whose bounding box overlaps it gives
        // nothing (upstream's pull request 476).
        var f = try triangleFields();
        defer f.deinit();
        try rasterizeBoth(&f, .{ -10, 5.5, -10 }, .{ -10, 5.5, 3 }, .{ 3, 5.5, -10 });
        try expectOnly(&f, &.{});
    }
}

// Tests_RecastFilter.cpp builds its columns by linking spans by hand; here
// `addSpan` builds the same columns on both sides.

fn filterFields(width: i32, height: i32) !Fields {
    const w: f32 = @floatFromInt(width);
    const h: f32 = @floatFromInt(height);
    return .init(width, height, .{ 0, 0, 0 }, .{ w, 1, h }, 1, 1);
}

test "rcFilterLowHangingWalkableObstacles: upstream's sections" {
    // Upstream passes its walkableHeight of 5 as the climb.
    const climb = 5;
    const Section = struct { spans: []const [3]u16, expected: []const u8 };
    const sections = [_]Section{
        // A span with nothing above is unchanged.
        .{ .spans = &.{.{ 0, 1, 1 }}, .expected = &.{1} },
        // A span above higher than the climb is unchanged, with more room
        // too.
        .{ .spans = &.{ .{ 0, 1, 1 }, .{ 6, 7, 0 } }, .expected = &.{ 1, 0 } },
        .{ .spans = &.{ .{ 0, 1, 1 }, .{ 16, 17, 0 } }, .expected = &.{ 1, 0 } },
        // A low obstacle within the climb becomes walkable.
        .{ .spans = &.{ .{ 0, 1, 1 }, .{ 5, 6, 0 } }, .expected = &.{ 1, 1 } },
        // One past the climb is unchanged.
        .{ .spans = &.{ .{ 0, 1, 1 }, .{ 6, 7, 0 } }, .expected = &.{ 1, 0 } },
        // Of a stack of low obstacles only the first becomes walkable.
        .{
            .spans = &.{
                .{ 0, 1, 1 },   .{ 5, 6, 0 },   .{ 10, 11, 0 }, .{ 15, 16, 0 }, .{ 20, 21, 0 },
                .{ 25, 26, 0 }, .{ 30, 31, 0 }, .{ 35, 36, 0 }, .{ 40, 41, 0 }, .{ 45, 46, 0 },
            },
            .expected = &.{ 1, 1, 0, 0, 0, 0, 0, 0, 0, 0 },
        },
    };
    for (sections) |section| {
        var f = try filterFields(1, 1);
        defer f.deinit();
        for (section.spans) |s| try f.addSpan(0, 0, s[0], s[1], @intCast(s[2]), 0);
        recast.filterLowHangingWalkableObstacles(f.logs.port(), climb, &f.port);
        upstream.shim_filter_low_hanging(f.logs.original, climb, f.original);
        try f.expectSame("filter low hanging obstacles");
        var buffer: [16]recast.Span = undefined;
        const spans = f.column(0, 0, &buffer);
        try testing.expectEqual(section.expected.len, spans.len);
        for (spans, section.expected) |s, area| try testing.expectEqual(area, s.area);
    }
}

test "rcFilterLedgeSpans: upstream's section" {
    // A flat plane: its edge spans become unwalkable.
    var f = try filterFields(10, 10);
    defer f.deinit();
    var x: i32 = 0;
    while (x < 10) : (x += 1) {
        var z: i32 = 0;
        while (z < 10) : (z += 1) try f.addSpan(x, z, 0, 1, 1, 0);
    }
    recast.filterLedgeSpans(f.logs.port(), 10, 5, &f.port);
    upstream.shim_filter_ledge(f.logs.original, 10, 5, f.original);
    try f.expectSame("filter ledge spans");
    x = 0;
    while (x < 10) : (x += 1) {
        var z: i32 = 0;
        while (z < 10) : (z += 1) {
            const edge = x == 0 or z == 0 or x == 9 or z == 9;
            try f.expectColumn(x, z, &.{.{ 0, 1, if (edge) 0 else 1 }});
        }
    }
}

test "rcFilterWalkableLowHeightSpans: upstream's sections" {
    const Section = struct { spans: []const [3]u16, expected: []const u8 };
    const sections = [_]Section{
        // A span with nothing above is unchanged.
        .{ .spans = &.{.{ 0, 1, 1 }}, .expected = &.{1} },
        // A span with lots of room above is unchanged.
        .{ .spans = &.{ .{ 0, 1, 1 }, .{ 10, 11, 0 } }, .expected = &.{ 1, 0 } },
        // A span under a low obstacle becomes unwalkable.
        .{ .spans = &.{ .{ 0, 1, 1 }, .{ 3, 4, 0 } }, .expected = &.{ 0, 0 } },
    };
    for (sections) |section| {
        var f = try filterFields(1, 1);
        defer f.deinit();
        for (section.spans) |s| try f.addSpan(0, 0, s[0], s[1], @intCast(s[2]), 0);
        recast.filterWalkableLowHeightSpans(f.logs.port(), 5, &f.port);
        upstream.shim_filter_low_height(f.logs.original, 5, f.original);
        try f.expectSame("filter low height spans");
        var buffer: [16]recast.Span = undefined;
        const spans = f.column(0, 0, &buffer);
        try testing.expectEqual(section.expected.len, spans.len);
        for (spans, section.expected) |s, area| try testing.expectEqual(area, s.area);
    }
}
