//! Seeded fuzzing against the original: random scenes and settings through
//! every build step, tile by tile and merged; random spans, triangles,
//! slopes, bounds, polygons and helper inputs through the functions that
//! take them; every output compared byte for byte. Each test runs at least
//! 1,000 cases from fixed seeds and prints the seed of a case that fails:
//! `-Dfuzz-replay=` that seed runs that case alone, and `-Dfuzz-seed=N`
//! runs other cases.

const std = @import("std");
const recast = @import("recast");
const upstream = @import("upstream.zig");
const meshes = @import("meshes.zig");
const oracle = @import("oracle.zig");
const pipeline = @import("pipeline.zig");
const fuzz_options = @import("fuzz_options");

const testing = std.testing;
const gpa = testing.allocator;
const Allocator = std.mem.Allocator;
const Random = std.Random;

/// `-Dfuzz-seed`: offsets the seeds of every fuzz test; 0, the default,
/// runs the recorded cases.
const seed_offset: u64 = fuzz_options.fuzz_seed;

/// `-Dfuzz-replay`: the seed of a failed case, to run only that case in
/// each fuzz test.
const replay: ?u64 = fuzz_options.fuzz_replay;

/// Runs `check` on `count` seeds made from `salt` and the seed offset, or
/// on the replayed seed alone, and prints the seed of a case that fails.
fn fuzz(name: []const u8, salt: u64, count: usize, check: anytype) !void {
    upstream.shim_init();
    if (replay) |seed| return runSeed(name, seed, check);
    for (0..count) |i| try runSeed(name, splitMix((salt ^ seed_offset) +% i), check);
}

fn runSeed(name: []const u8, seed: u64, check: anytype) !void {
    check(seed) catch |err| {
        std.debug.print("{s}: seed {d} fails; -Dfuzz-replay={d} runs it alone\n", .{
            name,
            seed,
            seed,
        });
        return err;
    };
}

/// SplitMix64: well spread seeds from consecutive numbers.
fn splitMix(x: u64) u64 {
    var z = x +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

fn between(r: Random, lo: f32, hi: f32) f32 {
    return lo + r.float(f32) * (hi - lo);
}

fn chance(r: Random, p: f32) bool {
    return r.float(f32) < p;
}

fn pick(r: Random, comptime T: type, values: []const T) T {
    return values[r.uintLessThan(usize, values.len)];
}

/// A float that is not a number, infinite, huge, tiny or a signed zero.
fn oddFloat(r: Random) f32 {
    const odd = [_]f32{
        std.math.nan(f32),
        -std.math.nan(f32),
        std.math.inf(f32),
        -std.math.inf(f32),
        1e30,
        -1e30,
        0.0,
        -0.0,
        std.math.floatMin(f32),
        std.math.floatTrueMin(f32),
        std.math.floatMax(f32),
        -std.math.floatMax(f32),
    };
    return pick(r, f32, &odd);
}

/// A coordinate far outside the field, for x and z. Ones past the vertex
/// range, where the original's clipper can overrun its buffers, have their
/// own test.
fn farFloat(r: Random) f32 {
    return pick(r, f32, &.{ 1e3, -1e3, 300, -300 });
}

/// Floats compared as their bits, except that any two NaNs match: neither
/// C++ nor Zig defines which NaN an operation on NaNs gives.
fn sameFloats(expected: []const f32, actual: []const f32) bool {
    for (expected, actual) |e, a| {
        if (std.math.isNan(e) and std.math.isNan(a)) continue;
        if (@as(u32, @bitCast(e)) != @as(u32, @bitCast(a))) return false;
    }
    return true;
}

fn expectSameFloats(what: []const u8, expected: []const f32, actual: []const f32) !void {
    if (sameFloats(expected, actual)) return;
    std.debug.print("{s}: original {any}, port {any}\n", .{ what, expected, actual });
    return error.TestExpectedEqual;
}

// Whole builds.

test "fuzz: random scenes build the same at every step, tile by tile and merged" {
    try fuzz("scenes", 0x5ce4e5, 1200, checkScene);
}

fn checkScene(seed: u64) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var prng: Random.DefaultPrng = .init(seed);
    const case = try randomScene(arena_state.allocator(), prng.random());
    var buffer: [64]u8 = undefined;
    const label = try std.fmt.bufPrint(&buffer, "scene 0x{x}", .{seed});
    // Every eighth case runs the port twice: the same bytes on every run.
    _ = try pipeline.expectSame(&case, label, seed % 8 == 0);
}

/// A random scene in a box of `size`: ground with holes, boxes, stacked
/// floors, ramps and loose triangles, some degenerate, and now and then a
/// vertex far away or at a height that is not a number, infinite or huge.
fn scene(arena: Allocator, r: Random, size: [3]f32) !meshes.Mesh {
    var b: meshes.Builder = .{ .gpa = arena };
    const base = between(r, -2, 2);
    if (chance(r, 0.8)) {
        const quads_x = r.intRangeAtMost(usize, 1, 24);
        const quads_z = r.intRangeAtMost(usize, 1, 24);
        const amplitude = if (chance(r, 0.3)) between(r, 0, 6) else between(r, 0, 1.5);
        const roughness = r.float(f32);
        const hole_rate: f32 = if (chance(r, 0.3)) between(r, 0, 0.3) else 0;
        const row = quads_x + 1;
        const grid = try arena.alloc(i32, row * (quads_z + 1));
        for (0..quads_z + 1) |z| for (0..quads_x + 1) |x| {
            const fx = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(quads_x));
            const fz = @as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(quads_z));
            const wave = @sin(fx * 5.0 + base) * @cos(fz * 4.0);
            const noise = r.float(f32) - 0.5;
            const y = base + amplitude * (wave * (1 - roughness) + noise * roughness);
            grid[z * row + x] = try b.vertex(fx * size[0], y, fz * size[2]);
        };
        for (0..quads_z) |z| for (0..quads_x) |x| {
            if (chance(r, hole_rate)) continue;
            const v00 = grid[z * row + x];
            const v10 = grid[z * row + x + 1];
            const v01 = grid[(z + 1) * row + x];
            const v11 = grid[(z + 1) * row + x + 1];
            try b.tri(v00, v01, v10);
            try b.tri(v10, v01, v11);
        };
    }
    for (0..r.uintLessThan(usize, 7)) |_| {
        const x = between(r, -0.2, 1) * size[0];
        const z = between(r, -0.2, 1) * size[2];
        const y = base + between(r, -1, 2);
        const w = between(r, 0.05, 0.5) * size[0];
        const d = between(r, 0.05, 0.5) * size[2];
        try b.box(.{ x, y, z }, .{ x + w, y + between(r, 0.02, 3), z + d });
    }
    if (chance(r, 0.2)) {
        // Thin floors stacked over the same columns, some closer than an
        // agent is tall.
        const x = between(r, 0, 0.6) * size[0];
        const z = between(r, 0, 0.6) * size[2];
        const w = between(r, 0.1, 0.4) * size[0];
        const d = between(r, 0.1, 0.4) * size[2];
        var y = base;
        for (0..r.intRangeAtMost(usize, 2, 8)) |_| {
            try b.box(.{ x, y, z }, .{ x + w, y + 0.05, z + d });
            y += between(r, 0.1, 2.5);
        }
    }
    for (0..r.uintLessThan(usize, 4)) |_| {
        const x0 = between(r, 0, 0.8) * size[0];
        const z0 = between(r, 0, 0.8) * size[2];
        const x1 = x0 + between(r, 0.05, 0.6) * size[0];
        const z1 = z0 + between(r, 0.05, 0.6) * size[2];
        const y0 = base + between(r, -1, 1);
        const y1 = y0 + between(r, -3, 3);
        try b.quad(.{ .{ x0, y0, z0 }, .{ x0, y0, z1 }, .{ x1, y1, z1 }, .{ x1, y1, z0 } });
    }
    for (0..r.uintLessThan(usize, 17)) |_| {
        var v: [3][3]f32 = undefined;
        for (&v) |*p| p.* = .{
            between(r, -0.3, 1.3) * size[0],
            base + between(r, -2, 3),
            between(r, -0.3, 1.3) * size[2],
        };
        if (chance(r, 0.15)) v[2] = v[0];
        if (chance(r, 0.1)) {
            // On one line.
            for (0..3) |k| v[2][k] = v[0][k] + (v[1][k] - v[0][k]) * 0.5;
        }
        const a = try b.vertex(v[0][0], v[0][1], v[0][2]);
        const c = try b.vertex(v[1][0], v[1][1], v[1][2]);
        const d = try b.vertex(v[2][0], v[2][1], v[2][2]);
        if (r.boolean()) try b.tri(a, c, d) else try b.tri(a, d, c);
    }
    const mesh = try b.finish();
    if (mesh.verts.len > 0 and chance(r, 0.05)) {
        for (0..r.intRangeAtMost(usize, 1, 3)) |_| {
            const i = r.uintLessThan(usize, mesh.verts.len);
            mesh.verts[i] = if (i % 3 == 1) oddFloat(r) else farFloat(r);
        }
    }
    return mesh;
}

/// A span to add straight to a heightfield: near the ground, anywhere, or
/// near the 13 bits a span's limits keep, sometimes of no or negative size.
fn randomSpan(r: Random) pipeline.ExtraSpan {
    const smin: u16 = switch (r.uintLessThan(u8, 4)) {
        0 => r.uintLessThan(u16, 64),
        1 => r.uintLessThan(u16, 600),
        2 => 8170 + r.uintLessThan(u16, 40),
        else => r.int(u16),
    };
    const smax = if (chance(r, 0.1))
        smin -| r.uintLessThan(u16, 4)
    else
        smin +| r.intRangeAtMost(u16, 1, 40);
    return .{
        .x = r.intRangeAtMost(i32, 0, 300),
        .z = r.intRangeAtMost(i32, 0, 300),
        .smin = smin,
        .smax = smax,
        .area = r.int(u8),
        .merge = r.intRangeAtMost(i32, -1, 5),
    };
}

fn randomMark(arena: Allocator, r: Random, size: [3]f32) !pipeline.Mark {
    const centre: [3]f32 = .{
        between(r, -0.2, 1.2) * size[0],
        between(r, -3, 3),
        between(r, -0.2, 1.2) * size[2],
    };
    const extent = between(r, 0.05, 0.6) * @max(size[0], size[2]);
    const area = r.int(u8);
    var low = centre[1] - between(r, 0, 4);
    var high = centre[1] + between(r, 0, 4);
    if (chance(r, 0.05)) std.mem.swap(f32, &low, &high);
    switch (r.uintLessThan(u8, 3)) {
        0 => {
            var min: [3]f32 = .{ centre[0] - extent, low, centre[2] - extent };
            var max: [3]f32 = .{ centre[0] + extent, high, centre[2] + extent };
            if (chance(r, 0.05)) std.mem.swap([3]f32, &min, &max);
            return .{ .box = .{ .min = min, .max = max, .area = area } };
        },
        1 => {
            const n: usize = if (chance(r, 0.1))
                r.intRangeAtMost(usize, 1, 2)
            else
                r.intRangeAtMost(usize, 3, 8);
            const verts = try arena.alloc(f32, n * 3);
            var angle: f32 = 0;
            for (0..n) |k| {
                angle += between(r, 0.1, std.math.tau / @as(f32, @floatFromInt(n)));
                verts[k * 3 ..][0..3].* = .{
                    centre[0] + extent * @cos(angle),
                    centre[1],
                    centre[2] + extent * @sin(angle),
                };
            }
            return .{ .convex = .{
                .verts = verts,
                .offset = if (r.boolean()) between(r, -0.5, 1) else 0,
                .min_y = low,
                .max_y = high,
                .area = area,
            } };
        },
        else => return .{ .cylinder = .{
            .pos = centre,
            .radius = if (chance(r, 0.05)) between(r, -1, 0) else extent,
            .height = between(r, -1, 6),
            .area = area,
        } },
    }
}

fn randomScene(arena: Allocator, r: Random) !pipeline.Case {
    const cs = pick(r, f32, &.{ 0.1, 0.15, 0.2, 0.3, 0.5 });
    const ch = pick(r, f32, &.{ 0.05, 0.1, 0.2, 0.3 });
    const cells_x = r.intRangeAtMost(i32, 1, 64);
    const cells_z = r.intRangeAtMost(i32, 1, 64);
    const size: [3]f32 = .{
        @as(f32, @floatFromInt(cells_x)) * cs,
        4,
        @as(f32, @floatFromInt(cells_z)) * cs,
    };

    const mesh = try scene(arena, r, size);
    const areas = try arena.alloc(u8, mesh.tris.len / 3);
    for (areas) |*a| a.* = if (chance(r, 0.3)) r.int(u8) else 0;

    var spans: std.ArrayList(pipeline.ExtraSpan) = .empty;
    if (chance(r, 0.3)) {
        for (0..r.intRangeAtMost(usize, 1, 40)) |_| try spans.append(arena, randomSpan(r));
    }
    if (chance(r, 0.05)) {
        // Two neighbouring columns of more floors than a compact span's
        // connection can index.
        const x = r.intRangeAtMost(i32, 0, 300);
        const z = r.intRangeAtMost(i32, 0, 300);
        for (0..r.intRangeAtMost(u16, 60, 90)) |i| {
            const smin: u16 = @intCast(i * 4);
            for ([2]i32{ 0, 1 }) |dx| {
                try spans.append(arena, .{
                    .x = x + dx,
                    .z = z,
                    .smin = smin,
                    .smax = smin + 1,
                    .area = recast.walkable_area,
                    .merge = 1,
                });
            }
        }
    }

    var marks: std.ArrayList(pipeline.Mark) = .empty;
    for (0..r.uintLessThan(usize, 4)) |_| {
        try marks.append(arena, try randomMark(arena, r, size));
    }

    // Now and then a setting below its documented range, where the
    // original's arithmetic still defines the result.
    const cfg: recast.Config = .{
        .cs = cs,
        .ch = ch,
        .walkable_height = if (chance(r, 0.05))
            r.intRangeAtMost(i32, -2, 0)
        else
            r.intRangeAtMost(i32, 1, 24),
        .walkable_climb = if (chance(r, 0.05)) -1 else r.intRangeAtMost(i32, 0, 12),
        .walkable_radius = if (chance(r, 0.05))
            r.intRangeAtMost(i32, -2, -1)
        else
            r.intRangeAtMost(i32, 0, 8),
        .max_edge_len = r.intRangeAtMost(i32, -1, 64),
        .max_simplification_error = between(r, 0, 3),
        .min_region_area = r.intRangeAtMost(i32, -1, 64),
        .merge_region_area = r.intRangeAtMost(i32, -1, 400),
        .max_verts_per_poly = r.intRangeAtMost(i32, 3, 12),
        .detail_sample_dist = cs * if (chance(r, 0.1)) between(r, 0.3, 1) else between(r, 1, 12),
        .detail_sample_max_error = between(r, 0, 1.5),
        .border_size = if (chance(r, 0.6)) r.intRangeAtMost(i32, 1, 8) else 0,
    };

    // The scene's bounds, cut or grown, in one to three tiles along x that
    // overlap by the border.
    const lo_y = between(r, -4, -1) + if (chance(r, 0.1)) between(r, 0, 3) else 0;
    const hi_y = between(r, 1, 6) - if (chance(r, 0.1)) between(r, 0, 4) else 0;
    const grow = between(r, -0.1, 0.2);
    const field_min: [3]f32 = .{ -grow * size[0], lo_y, -grow * size[2] };
    const field_max: [3]f32 = .{ (1 + grow) * size[0], hi_y, (1 + grow) * size[2] };
    const tiles = try arena.alloc(recast.Config, r.intRangeAtMost(usize, 1, 3));
    const border = @as(f32, @floatFromInt(cfg.border_size)) * cs;
    const tile_x = (field_max[0] - field_min[0]) / @as(f32, @floatFromInt(tiles.len));
    for (tiles, 0..) |*tile, t| {
        const ft: f32 = @floatFromInt(t);
        tile.* = cfg;
        tile.bmin = .{ field_min[0] + ft * tile_x - border, field_min[1], field_min[2] - border };
        tile.bmax = .{
            field_min[0] + (ft + 1) * tile_x + border,
            field_max[1],
            field_max[2] + border,
        };
        const grid = recast.calcGridSize(&tile.bmin, &tile.bmax, cs);
        tile.width = grid.width;
        tile.height = grid.height;
    }

    const slopes = [_]f32{ 0, 30, 45, 60, 89.9, 90 };
    const rasters = [_]pipeline.Raster{ .u16, .unindexed, .single };
    return .{
        .verts = mesh.verts,
        .tris = mesh.tris,
        .areas = areas,
        .walkable_slope = if (chance(r, 0.3)) pick(r, f32, &slopes) else between(r, 0, 90),
        .clear_slope = if (chance(r, 0.3)) between(r, 0, 90) else null,
        .raster = if (chance(r, 0.6)) .int else pick(r, pipeline.Raster, &rasters),
        .spans = spans.items,
        .filters = .{ chance(r, 0.8), chance(r, 0.8), chance(r, 0.8) },
        .median = chance(r, 0.3),
        .marks = marks.items,
        .layers = chance(r, 0.4),
        .partition = if (r.boolean())
            .watershed
        else
            pick(r, pipeline.Partition, &.{ .monotone, .layers }),
        .flags = .{ .tess_wall_edges = r.boolean(), .tess_area_edges = r.boolean() },
        .tiles = tiles,
    };
}

// Spans.

test "fuzz: spans added directly merge, filter and compact as the original's" {
    try fuzz("spans", 0x5a4e5, 1000, checkSpans);
}

fn checkSpans(seed: u64) !void {
    var prng: Random.DefaultPrng = .init(seed);
    const r = prng.random();
    var logs: oracle.Logs = try .init();
    defer logs.deinit();
    const ctx = logs.port();
    const log = logs.original;

    const width = r.intRangeAtMost(i32, 1, 12);
    const height = r.intRangeAtMost(i32, 1, 12);
    const cs = pick(r, f32, &.{ 0.1, 0.3, 1 });
    const ch = pick(r, f32, &.{ 0.1, 0.2, 2 });
    const bmin: [3]f32 = .{ between(r, -5, 5), between(r, -5, 5), between(r, -5, 5) };
    const bmax: [3]f32 = .{
        bmin[0] + @as(f32, @floatFromInt(width)) * cs,
        bmin[1] + between(r, 1, 30),
        bmin[2] + @as(f32, @floatFromInt(height)) * cs,
    };
    var hf: recast.Heightfield = try .init(gpa, width, height, &bmin, &bmax, cs, ch);
    defer hf.deinit(gpa);
    const original_hf = upstream.shim_hf_create(log, width, height, &bmin, &bmax, cs, ch) orelse
        return error.OutOfMemory;
    defer upstream.shim_hf_free(original_hf);
    try logs.expectSame("create heightfield");

    // The spans fall in a few columns, so they overlap and merge; more than
    // a pool's worth of them makes the heightfield take another pool.
    const columns = r.intRangeAtMost(i32, 1, width * height);
    const count = if (chance(r, 0.1))
        r.intRangeAtMost(usize, 2000, 3000)
    else
        r.intRangeAtMost(usize, 1, 300);
    for (0..count) |i| {
        const column = r.intRangeLessThan(i32, 0, columns);
        const x = @mod(column, width);
        const z = @divTrunc(column, width);
        const s = randomSpan(r);
        const ok = recast.addSpan(ctx, gpa, &hf, x, z, s.smin, s.smax, s.area, s.merge);
        const original_ok = upstream.shim_add_span(
            log,
            original_hf,
            x,
            z,
            s.smin,
            s.smax,
            s.area,
            s.merge,
        );
        _ = try oracle.sameOutcome(&logs, "add span", oracle.succeeded(ok), original_ok != 0);
        if (i % 16 == 15 or i + 1 == count) {
            try oracle.expectSameDump("add span", &hf, original_hf);
        }
    }

    // The filters in any order, any number of times, with any settings.
    for (0..r.uintLessThan(usize, 5)) |_| {
        const walkable_height = r.intRangeAtMost(i32, -1, 30);
        const climb = r.intRangeAtMost(i32, -1, 15);
        switch (r.uintLessThan(u8, 3)) {
            0 => {
                recast.filterLowHangingWalkableObstacles(ctx, climb, &hf);
                upstream.shim_filter_low_hanging(log, climb, original_hf);
            },
            1 => {
                recast.filterLedgeSpans(ctx, walkable_height, climb, &hf);
                upstream.shim_filter_ledge(log, walkable_height, climb, original_hf);
            },
            else => {
                recast.filterWalkableLowHeightSpans(ctx, walkable_height, &hf);
                upstream.shim_filter_low_height(log, walkable_height, original_hf);
            },
        }
        try logs.expectSame("filter");
        try oracle.expectSameDump("filter", &hf, original_hf);
    }
    const span_count = recast.getHeightFieldSpanCount(ctx, &hf);
    try testing.expectEqual(upstream.shim_hf_span_count(log, original_hf), span_count);
    try logs.expectSame("span count");

    const walkable_height = r.intRangeAtMost(i32, -1, 30);
    const climb = r.intRangeAtMost(i32, -1, 15);
    var chf = try recast.buildCompactHeightfield(ctx, gpa, walkable_height, climb, &hf);
    defer chf.deinit(gpa);
    const original_chf = upstream.shim_chf_build(log, walkable_height, climb, original_hf) orelse
        return error.OutOfMemory;
    defer upstream.shim_chf_free(original_chf);
    try logs.expectSame("compact");
    try oracle.expectSameDump("compact", &chf, original_chf);

    const radius = r.intRangeAtMost(i32, -1, 4);
    const eroded = recast.erodeWalkableArea(ctx, gpa, radius, &chf);
    const original_eroded = upstream.shim_erode(log, radius, original_chf);
    _ = try oracle.sameOutcome(&logs, "erode", oracle.succeeded(eroded), original_eroded != 0);
    try oracle.expectSameDump("erode", &chf, original_chf);
    if (r.boolean()) {
        const median = recast.medianFilterWalkableArea(ctx, gpa, &chf);
        const original_median = upstream.shim_median(log, original_chf);
        const ok = oracle.succeeded(median);
        _ = try oracle.sameOutcome(&logs, "median", ok, original_median != 0);
        try oracle.expectSameDump("median", &chf, original_chf);
    }
}

// Rasterization.

test "fuzz: random triangles rasterize the same through every entry point" {
    try fuzz("rasterization", 0x7a5, 1000, checkRasterization);
}

/// A coordinate in [lo, hi] and a little beyond: anywhere, on a cell
/// boundary, just off one, far away, or with `odd` not a number, infinite
/// or huge.
fn coordinate(r: Random, lo: f32, hi: f32, step: f32, odd: bool) f32 {
    const cells = @max(1, @floor((hi - lo) / step));
    return switch (r.uintLessThan(u8, 20)) {
        0...9 => between(r, lo - 2 * step, hi + 2 * step),
        10...14 => lo + @floor(between(r, -2, cells + 2)) * step,
        15...18 => lo + @floor(between(r, -2, cells + 2)) * step + between(r, -1e-4, 1e-4),
        else => if (!chance(r, 0.3))
            between(r, -1e3, 1e3)
        else if (odd)
            oddFloat(r)
        else
            farFloat(r),
    };
}

const Entry = enum { int, u16, unindexed, single };

fn checkRasterization(seed: u64) !void {
    var prng: Random.DefaultPrng = .init(seed);
    const r = prng.random();
    var logs: oracle.Logs = try .init();
    defer logs.deinit();
    const ctx = logs.port();
    const log = logs.original;

    const width = if (chance(r, 0.05)) 0 else r.intRangeAtMost(i32, 1, 32);
    const height = if (chance(r, 0.05)) 0 else r.intRangeAtMost(i32, 1, 32);
    const cs = pick(r, f32, &.{ 0.1, 0.25, 0.3, 1, 1.5 });
    const ch = pick(r, f32, &.{ 0.1, 0.2, 0.5, 2 });
    const bmin: [3]f32 = .{ between(r, -10, 10), between(r, -10, 10), between(r, -10, 10) };
    const bmax: [3]f32 = .{
        bmin[0] + @as(f32, @floatFromInt(width)) * cs,
        bmin[1] + between(r, -1, 20),
        bmin[2] + @as(f32, @floatFromInt(height)) * cs,
    };

    const nv = r.intRangeAtMost(usize, 3, 60);
    const verts = try gpa.alloc(f32, nv * 3);
    defer gpa.free(verts);
    for (0..nv) |v| {
        verts[v * 3 + 0] = coordinate(r, bmin[0], bmax[0], cs, false);
        verts[v * 3 + 1] = coordinate(r, bmin[1], @max(bmin[1], bmax[1]), ch, true);
        verts[v * 3 + 2] = coordinate(r, bmin[2], bmax[2], cs, false);
    }
    const nt = r.uintLessThan(usize, 41);
    const tris = try gpa.alloc(i32, nt * 3);
    defer gpa.free(tris);
    const tris_u16 = try gpa.alloc(u16, nt * 3);
    defer gpa.free(tris_u16);
    const flat = try gpa.alloc(f32, nt * 9);
    defer gpa.free(flat);
    for (tris, tris_u16, 0..) |*index, *narrow, i| {
        // Now and then a triangle with a repeated vertex.
        const v = if (i % 3 != 0 and chance(r, 0.05))
            tris[i - 1]
        else
            r.intRangeLessThan(i32, 0, @intCast(nv));
        index.* = v;
        narrow.* = @intCast(v);
        flat[i * 3 ..][0..3].* = verts[@as(usize, @intCast(v)) * 3 ..][0..3].*;
    }
    const areas = try gpa.alloc(u8, nt);
    defer gpa.free(areas);
    for (areas) |*a| a.* = if (r.boolean()) recast.walkable_area else r.int(u8);
    const merge = r.intRangeAtMost(i32, -1, 6);
    const nv_c: c_int = @intCast(nv);
    const nt_c: c_int = @intCast(nt);

    for ([_]Entry{ .int, .u16, .unindexed, .single }) |entry| {
        var hf: recast.Heightfield = try .init(gpa, width, height, &bmin, &bmax, cs, ch);
        defer hf.deinit(gpa);
        const original_hf = upstream.shim_hf_create(log, width, height, &bmin, &bmax, cs, ch) orelse
            return error.OutOfMemory;
        defer upstream.shim_hf_free(original_hf);
        try logs.expectSame("create heightfield");
        var ok = true;
        var original_ok = true;
        switch (entry) {
            .int => {
                const result = recast.rasterizeTriangles(
                    ctx,
                    gpa,
                    verts,
                    i32,
                    tris,
                    areas,
                    &hf,
                    merge,
                );
                ok = oracle.succeeded(result);
                original_ok = upstream.shim_rasterize_triangles(
                    log,
                    verts.ptr,
                    nv_c,
                    tris.ptr,
                    areas.ptr,
                    nt_c,
                    original_hf,
                    merge,
                ) != 0;
            },
            .u16 => {
                const result = recast.rasterizeTriangles(
                    ctx,
                    gpa,
                    verts,
                    u16,
                    tris_u16,
                    areas,
                    &hf,
                    merge,
                );
                ok = oracle.succeeded(result);
                original_ok = upstream.shim_rasterize_triangles_u16(
                    log,
                    verts.ptr,
                    nv_c,
                    tris_u16.ptr,
                    areas.ptr,
                    nt_c,
                    original_hf,
                    merge,
                ) != 0;
            },
            .unindexed => {
                const result = recast.rasterizeUnindexedTriangles(
                    ctx,
                    gpa,
                    flat,
                    areas,
                    &hf,
                    merge,
                );
                ok = oracle.succeeded(result);
                original_ok = upstream.shim_rasterize_unindexed(
                    log,
                    flat.ptr,
                    areas.ptr,
                    nt_c,
                    original_hf,
                    merge,
                ) != 0;
            },
            .single => for (areas, 0..) |area, i| {
                const v = flat[i * 9 ..][0..9];
                const result = recast.rasterizeTriangle(
                    ctx,
                    gpa,
                    v[0..3],
                    v[3..6],
                    v[6..9],
                    area,
                    &hf,
                    merge,
                );
                const original_result = upstream.shim_rasterize_triangle(
                    log,
                    v[0..3],
                    v[3..6],
                    v[6..9],
                    area,
                    original_hf,
                    merge,
                );
                ok = ok and oracle.succeeded(result);
                original_ok = original_ok and original_result != 0;
            },
        }
        _ = try oracle.sameOutcome(&logs, @tagName(entry), ok, original_ok);
        try oracle.expectSameDump(@tagName(entry), &hf, original_hf);
    }
}

test "fuzz: triangles out to the vertex range rasterize as the original's, and past it fail" {
    try fuzz("vertex range", 0x7a6, 1000, checkVertexRange);
}

/// A coordinate for a corner near `lo`..`hi`, or with `far` out to the edge
/// of the vertex range, `limit`, but inside it.
fn rangeCoordinate(r: Random, lo: f32, hi: f32, step: f32, far: bool, limit: f32) f32 {
    const inside = std.math.nextAfter(f32, limit, 0);
    if (!far) return std.math.clamp(between(r, lo - 4 * step, hi + 4 * step), -inside, inside);
    return pick(r, f32, &.{ inside, -inside, between(r, -inside, inside) });
}

/// A field anywhere in the vertex range, out to its edge, with triangles
/// over it and long ones out to the edge of the range, rasterized through
/// every entry point by both sides; then the same with a triangle past the
/// range among them, which the port refuses where it comes, keeping what
/// the triangles before it made, as the original makes them.
fn checkVertexRange(seed: u64) !void {
    var prng: Random.DefaultPrng = .init(seed);
    const r = prng.random();
    var logs: oracle.Logs = try .init();
    defer logs.deinit();
    const ctx = logs.port();
    const log = logs.original;

    const cs = pick(r, f32, &.{ 0.05, 0.125, 0.3, 1, 4 });
    const ch = pick(r, f32, &.{ 0.1, 0.2, 0.5 });
    const limit = cs * @as(f32, recast.vertex_cells_max);
    const width = r.intRangeAtMost(i32, 1, 16);
    const height = r.intRangeAtMost(i32, 1, 16);
    const size_x = @as(f32, @floatFromInt(width)) * cs;
    const size_z = @as(f32, @floatFromInt(height)) * cs;
    // The field's corner, from the origin out to the edge of the range.
    const reach = limit * pick(r, f32, &.{ 0, 0.001, 0.25, 0.5, 0.99 });
    const bmin: [3]f32 = .{
        @min(between(r, -reach, reach), limit * 0.99 - size_x),
        between(r, -10, 10),
        @min(between(r, -reach, reach), limit * 0.99 - size_z),
    };
    const bmax: [3]f32 = .{ bmin[0] + size_x, bmin[1] + between(r, 1, 20), bmin[2] + size_z };

    const nv = r.intRangeAtMost(usize, 3, 30);
    const verts = try gpa.alloc(f32, nv * 3);
    defer gpa.free(verts);
    for (0..nv) |v| {
        const far = chance(r, 0.15);
        verts[v * 3 + 0] = rangeCoordinate(r, bmin[0], bmax[0], cs, far, limit);
        verts[v * 3 + 1] = between(r, bmin[1] - 2, bmax[1] + 2);
        verts[v * 3 + 2] = rangeCoordinate(r, bmin[2], bmax[2], cs, far, limit);
    }
    // One more vertex, past the range in x or z.
    const bad = verts.len / 3;
    const verts_bad = try gpa.alloc(f32, verts.len + 3);
    defer gpa.free(verts_bad);
    @memcpy(verts_bad[0..verts.len], verts);
    const bad_value = pick(r, f32, &.{
        std.math.nan(f32),
        std.math.inf(f32),
        -std.math.inf(f32),
        limit,
        -limit,
        limit * 2,
        1e30,
    });
    verts_bad[verts.len..][0..3].* = if (r.boolean())
        .{ bad_value, bmin[1], bmin[2] }
    else
        .{ bmin[0], bmin[1], bad_value };

    const nt = r.intRangeAtMost(usize, 1, 24);
    const tris = try gpa.alloc(i32, nt * 3);
    defer gpa.free(tris);
    for (tris) |*t| t.* = r.intRangeLessThan(i32, 0, @intCast(nv));
    const areas = try gpa.alloc(u8, nt);
    defer gpa.free(areas);
    for (areas) |*a| a.* = if (r.boolean()) recast.walkable_area else r.int(u8);
    const merge = r.intRangeAtMost(i32, 0, 4);
    // The refused triangle: one corner past the range.
    const refused = r.uintLessThan(usize, nt);
    const tris_bad = try gpa.dupe(i32, tris);
    defer gpa.free(tris_bad);
    tris_bad[refused * 3 + r.uintLessThan(usize, 3)] = @intCast(bad);

    for ([_]bool{ false, true }) |with_bad| {
        const corners = if (with_bad) verts_bad else verts;
        const indices = if (with_bad) tris_bad else tris;
        // The triangles the original is given: all, or those before the
        // refused one.
        const given = if (with_bad) refused else nt;
        const indices_u16 = try gpa.alloc(u16, indices.len);
        defer gpa.free(indices_u16);
        for (indices_u16, indices) |*n, i| n.* = @intCast(i);
        const flat = try gpa.alloc(f32, indices.len * 3);
        defer gpa.free(flat);
        for (indices, 0..) |v, i| {
            flat[i * 3 ..][0..3].* = corners[@as(usize, @intCast(v)) * 3 ..][0..3].*;
        }
        const nv_c: c_int = @intCast(corners.len / 3);
        const given_c: c_int = @intCast(given);
        for ([_]Entry{ .int, .u16, .unindexed, .single }) |entry| {
            var hf: recast.Heightfield = try .init(gpa, width, height, &bmin, &bmax, cs, ch);
            defer hf.deinit(gpa);
            const original_hf =
                upstream.shim_hf_create(log, width, height, &bmin, &bmax, cs, ch) orelse
                return error.OutOfMemory;
            defer upstream.shim_hf_free(original_hf);
            try logs.expectSame("create heightfield");
            var result: recast.RasterizeError!void = {};
            var original_ok = true;
            switch (entry) {
                .int => {
                    result = recast.rasterizeTriangles(
                        ctx,
                        gpa,
                        corners,
                        i32,
                        indices,
                        areas,
                        &hf,
                        merge,
                    );
                    original_ok = upstream.shim_rasterize_triangles(
                        log,
                        corners.ptr,
                        nv_c,
                        indices.ptr,
                        areas.ptr,
                        given_c,
                        original_hf,
                        merge,
                    ) != 0;
                },
                .u16 => {
                    result = recast.rasterizeTriangles(
                        ctx,
                        gpa,
                        corners,
                        u16,
                        indices_u16,
                        areas,
                        &hf,
                        merge,
                    );
                    original_ok = upstream.shim_rasterize_triangles_u16(
                        log,
                        corners.ptr,
                        nv_c,
                        indices_u16.ptr,
                        areas.ptr,
                        given_c,
                        original_hf,
                        merge,
                    ) != 0;
                },
                .unindexed => {
                    result = recast.rasterizeUnindexedTriangles(
                        ctx,
                        gpa,
                        flat,
                        areas,
                        &hf,
                        merge,
                    );
                    original_ok = upstream.shim_rasterize_unindexed(
                        log,
                        flat.ptr,
                        areas.ptr,
                        given_c,
                        original_hf,
                        merge,
                    ) != 0;
                },
                .single => for (areas, 0..) |area, i| {
                    const v = flat[i * 9 ..][0..9];
                    result = recast.rasterizeTriangle(
                        ctx,
                        gpa,
                        v[0..3],
                        v[3..6],
                        v[6..9],
                        area,
                        &hf,
                        merge,
                    );
                    if (i == given) break;
                    original_ok = original_ok and upstream.shim_rasterize_triangle(
                        log,
                        v[0..3],
                        v[3..6],
                        v[6..9],
                        area,
                        original_hf,
                        merge,
                    ) != 0;
                    try result;
                },
            }
            try testing.expect(original_ok);
            if (with_bad) {
                try testing.expectError(error.NonFiniteVertex, result);
                if (entry == .single) {
                    // The refused call's timer, which the original was not
                    // given.
                    const timer = recast.TimerLabel.rasterize_triangles;
                    const label: c_int = @intCast(@backingInt(timer));
                    upstream.shim_log_timer(log, label, 1);
                    upstream.shim_log_timer(log, label, 0);
                }
                const line = switch (entry) {
                    .single => oracle.refusalLine("rcRasterizeTriangle"),
                    else => oracle.refusalLine("rcRasterizeTriangles"),
                };
                try oracle.expectSameWithRefusal(&logs, @tagName(entry), line);
            } else {
                try result;
                try logs.expectSame(@tagName(entry));
            }
            try oracle.expectSameDump(@tagName(entry), &hf, original_hf);
        }
    }
}

// Polygon offsets.

test "fuzz: polygons offset the same, including into short buffers" {
    try fuzz("offsetPoly", 0x0ff5e7, 2000, checkOffsetPoly);
}

fn checkOffsetPoly(seed: u64) !void {
    var prng: Random.DefaultPrng = .init(seed);
    const r = prng.random();
    const n = r.uintLessThan(usize, 13);
    var verts: [12 * 3]f32 = undefined;
    const shape = r.uintLessThan(u8, 4);
    var angle: f32 = 0;
    const turn: f32 = if (r.boolean()) 1 else -1;
    for (0..n) |i| {
        const p = verts[i * 3 ..][0..3];
        switch (shape) {
            // Convex, either winding.
            0 => {
                angle += turn * between(r, 0.05, std.math.tau / @as(f32, @floatFromInt(n)));
                const radius = between(r, 0.5, 5);
                p.* = .{ radius * @cos(angle), between(r, -1, 1), radius * @sin(angle) };
            },
            // Anywhere: concave or crossing itself.
            1 => p.* = .{ between(r, -10, 10), between(r, -1, 1), between(r, -10, 10) },
            // Repeated and collinear points.
            2 => if (i > 0 and r.boolean()) {
                const q = verts[(i - 1) * 3 ..][0..3];
                p.* = if (r.boolean()) q.* else .{ q[0] + 1, q[1], q[2] };
            } else {
                p.* = .{ @floor(between(r, -3, 3)), 0, @floor(between(r, -3, 3)) };
            },
            else => p.* = .{
                if (chance(r, 0.3)) oddFloat(r) else between(r, -10, 10),
                between(r, -1, 1),
                if (chance(r, 0.3)) oddFloat(r) else between(r, -10, 10),
            },
        }
    }
    const offset: f32 = switch (r.uintLessThan(u8, 8)) {
        0 => 0,
        1 => between(r, -1e-6, 1e-6),
        2 => if (r.boolean()) 1e6 else -1e6,
        3 => oddFloat(r),
        else => between(r, -3, 3),
    };
    const max_out = r.uintLessThan(usize, 2 * n + 3);
    const sentinel: f32 = 12345.5;
    var out: [26 * 3]f32 = @splat(sentinel);
    var original_out: [26 * 3]f32 = @splat(sentinel);
    const count = recast.offsetPoly(verts[0 .. n * 3], offset, out[0 .. max_out * 3]);
    const original_count = upstream.shim_offset_poly(
        &verts,
        @intCast(n),
        offset,
        &original_out,
        @intCast(max_out),
    );
    try testing.expectEqual(original_count, count);
    try expectSameFloats("offsetPoly", &original_out, &out);
}

// Triangle slopes, bounds and grid sizes.

test "fuzz: triangles are marked and cleared the same at any slope" {
    try fuzz("slopes", 0x510be, 1000, checkSlopes);
}

fn checkSlopes(seed: u64) !void {
    var prng: Random.DefaultPrng = .init(seed);
    const r = prng.random();
    var logs: oracle.Logs = try .init();
    defer logs.deinit();
    const ctx = logs.port();
    const log = logs.original;

    const nv = r.intRangeAtMost(usize, 1, 40);
    const verts = try gpa.alloc(f32, nv * 3);
    defer gpa.free(verts);
    const flat = chance(r, 0.2);
    for (verts, 0..) |*v, i| {
        v.* = if (chance(r, 0.03))
            oddFloat(r)
        else if (flat and i % 3 == 1)
            0
        else
            between(r, -10, 10);
    }
    const nt = r.uintLessThan(usize, 61);
    const tris = try gpa.alloc(i32, nt * 3);
    defer gpa.free(tris);
    for (tris) |*t| t.* = r.intRangeLessThan(i32, 0, @intCast(nv));
    const areas = try gpa.alloc(u8, nt);
    defer gpa.free(areas);
    for (areas) |*a| a.* = r.int(u8);
    const original_areas = try gpa.dupe(u8, areas);
    defer gpa.free(original_areas);

    const angles = [_]f32{ 0, 30, 45, 60, 89.9, 90, 135, 180, -45, 360 };
    const nv_c: c_int = @intCast(nv);
    const nt_c: c_int = @intCast(nt);
    for (0..2) |pass| {
        const slope = switch (r.uintLessThan(u8, 4)) {
            0 => pick(r, f32, &angles),
            1 => oddFloat(r),
            else => between(r, -30, 200),
        };
        if (pass == 0) {
            recast.markWalkableTriangles(ctx, slope, verts, tris, areas);
            upstream.shim_mark_walkable(
                log,
                slope,
                verts.ptr,
                nv_c,
                tris.ptr,
                nt_c,
                original_areas.ptr,
            );
        } else {
            recast.clearUnwalkableTriangles(ctx, slope, verts, tris, areas);
            upstream.shim_clear_unwalkable(
                log,
                slope,
                verts.ptr,
                nv_c,
                tris.ptr,
                nt_c,
                original_areas.ptr,
            );
        }
        try logs.expectSame("slopes");
        try testing.expectEqualSlices(u8, original_areas, areas);
    }
}

test "fuzz: bounds and grid sizes match, with odd floats" {
    try fuzz("bounds", 0xb0d5, 2000, checkBounds);
}

fn checkBounds(seed: u64) !void {
    var prng: Random.DefaultPrng = .init(seed);
    const r = prng.random();
    const nv = r.intRangeAtMost(usize, 1, 40);
    var verts: [40 * 3]f32 = undefined;
    for (verts[0 .. nv * 3]) |*v| v.* = if (chance(r, 0.1)) oddFloat(r) else between(r, -100, 100);
    var bounds: [6]f32 = undefined;
    var original_bounds: [6]f32 = undefined;
    recast.calcBounds(verts[0 .. nv * 3], bounds[0..3], bounds[3..6]);
    upstream.shim_calc_bounds(&verts, @intCast(nv), original_bounds[0..3], original_bounds[3..6]);
    // Bounds pick the vertices' own values, so even NaNs keep their bits.
    try testing.expectEqualSlices(u8, std.mem.asBytes(&original_bounds), std.mem.asBytes(&bounds));

    var bmin: [3]f32 = undefined;
    var bmax: [3]f32 = undefined;
    for (&bmin, &bmax) |*lo, *hi| {
        lo.* = if (chance(r, 0.05)) oddFloat(r) else between(r, -1000, 1000);
        hi.* = if (chance(r, 0.05)) oddFloat(r) else lo.* + between(r, -10, 2000);
    }
    const cs = switch (r.uintLessThan(u8, 8)) {
        0 => oddFloat(r),
        1 => -between(r, 0.01, 2),
        2 => between(r, 1e-6, 1e-3),
        else => between(r, 0.01, 10),
    };
    const grid = recast.calcGridSize(&bmin, &bmax, cs);
    var width: c_int = undefined;
    var height: c_int = undefined;
    upstream.shim_calc_grid_size(&bmin, &bmax, cs, &width, &height);
    try testing.expectEqual(width, grid.width);
    try testing.expectEqual(height, grid.height);
}

// Helpers.

test "fuzz: vector helpers give the same floats" {
    try fuzz("vectors", 0x7ec, 2000, checkVectors);
}

fn randomVector(r: Random) [3]f32 {
    var v: [3]f32 = undefined;
    for (&v) |*c| c.* = if (chance(r, 0.1)) oddFloat(r) else between(r, -1000, 1000);
    return v;
}

fn checkVectors(seed: u64) !void {
    var prng: Random.DefaultPrng = .init(seed);
    const r = prng.random();
    const a = randomVector(r);
    const b = randomVector(r);
    const s = if (chance(r, 0.1)) oddFloat(r) else between(r, -10, 10);
    var original: [3]f32 = undefined;

    upstream.shim_vcross(&original, &a, &b);
    try expectSameFloats("vcross", &original, &recast.vcross(&a, &b));
    try expectSameFloats("vdot", &.{upstream.shim_vdot(&a, &b)}, &.{recast.vdot(&a, &b)});
    upstream.shim_vmad(&original, &a, &b, s);
    try expectSameFloats("vmad", &original, &recast.vmad(&a, &b, s));
    upstream.shim_vadd(&original, &a, &b);
    try expectSameFloats("vadd", &original, &recast.vadd(&a, &b));
    upstream.shim_vsub(&original, &a, &b);
    try expectSameFloats("vsub", &original, &recast.vsub(&a, &b));
    try expectSameFloats("vdist", &.{upstream.shim_vdist(&a, &b)}, &.{recast.vdist(&a, &b)});
    const dist_sqr = recast.vdistSqr(&a, &b);
    try expectSameFloats("vdistSqr", &.{upstream.shim_vdist_sqr(&a, &b)}, &.{dist_sqr});

    var port = a;
    original = a;
    recast.vmin(&port, &b);
    upstream.shim_vmin(&original, &b);
    try expectSameFloats("vmin", &original, &port);
    port = a;
    original = a;
    recast.vmax(&port, &b);
    upstream.shim_vmax(&original, &b);
    try expectSameFloats("vmax", &original, &port);
    port = a;
    original = a;
    recast.vnormalize(&port);
    upstream.shim_vnormalize(&original);
    try expectSameFloats("vnormalize", &original, &port);
    // The port copies a vector by assignment.
    original = b;
    upstream.shim_vcopy(&original, &a);
    try expectSameFloats("vcopy", &original, &a);
}

test "fuzz: min, max, clamp, square root and float to int match C++" {
    try fuzz("scalars", 0x5ca1a, 4000, checkScalars);
}

fn randomScalar(r: Random) f32 {
    return switch (r.uintLessThan(u8, 6)) {
        0 => oddFloat(r),
        1 => @floor(between(r, -5, 5)),
        2 => between(r, -3e9, 3e9),
        else => between(r, -100, 100),
    };
}

fn checkScalars(seed: u64) !void {
    var prng: Random.DefaultPrng = .init(seed);
    const r = prng.random();
    const a = randomScalar(r);
    const b = randomScalar(r);
    const c = randomScalar(r);
    try expectSameFloats("min", &.{upstream.shim_min(a, b)}, &.{recast.selectMin(a, b)});
    try expectSameFloats("max", &.{upstream.shim_max(a, b)}, &.{recast.selectMax(a, b)});
    const clamped = recast.clamp(f32, a, b, c);
    try expectSameFloats("clamp", &.{upstream.shim_clamp(a, b, c)}, &.{clamped});
    try expectSameFloats("sqrt", &.{upstream.shim_sqrt(a)}, &.{@sqrt(a)});
    try testing.expectEqual(upstream.shim_float_to_int(a), recast.truncateToInt(a));
    const i = r.intRangeAtMost(i32, -1000, 1000);
    const lo = r.intRangeAtMost(i32, -1000, 1000);
    const hi = r.intRangeAtMost(i32, -1000, 1000);
    try testing.expectEqual(upstream.shim_clamp_int(i, lo, hi), recast.clamp(i32, i, lo, hi));
}

test "fuzz: span connections set and get the same bits" {
    try fuzz("connections", 0xc0, 4000, checkConnections);
}

fn checkConnections(seed: u64) !void {
    var prng: Random.DefaultPrng = .init(seed);
    const r = prng.random();
    const con = r.int(u24);
    const dir = r.int(u2);
    const neighbor = if (r.boolean()) r.intRangeAtMost(i32, 0, 63) else r.int(i32);
    var span: recast.CompactSpan = .{ .y = 0, .reg = 0, .con = con, .h = 0 };
    try testing.expectEqual(upstream.shim_get_con(con, dir), recast.getCon(span, dir));
    recast.setCon(&span, dir, neighbor);
    try testing.expectEqual(upstream.shim_set_con(con, dir, neighbor), span.con);
}

test "directions and their offsets match for every direction" {
    for (0..4) |d| {
        const dir: u2 = @intCast(d);
        try testing.expectEqual(upstream.shim_dir_offset_x(dir), recast.getDirOffsetX(dir));
        try testing.expectEqual(upstream.shim_dir_offset_y(dir), recast.getDirOffsetY(dir));
    }
    // Every offset the original's table holds: one step along an axis, or
    // none, and the two diagonals that index inside it.
    const offsets = [_][2]i32{
        .{ 0, -1 }, .{ 1, -1 }, .{ -1, 0 }, .{ 0, 0 }, .{ 1, 0 }, .{ -1, 1 }, .{ 0, 1 },
    };
    for (offsets) |o| {
        const expected = upstream.shim_dir_for_offset(o[0], o[1]);
        try testing.expectEqual(expected, recast.getDirForOffset(o[0], o[1]));
    }
}
