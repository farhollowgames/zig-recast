//! Hand-made edge cases against the original, each through the whole
//! build: empty and one-element inputs, the limits of region ids, mesh
//! vertices, layers, span heights and column sizes, and degenerate
//! geometry. Each checks the case reaches the limit it is about.

const std = @import("std");
const recast = @import("recast");
const pipeline = @import("pipeline.zig");

const testing = std.testing;
const gpa = testing.allocator;

/// A tile of `width` by `height` cells of size 1 and height 0.5 from the
/// origin to `top`, with settings that keep every span and region: no
/// erosion, no area limits.
fn tile(width: i32, height: i32, top: f32) recast.Config {
    return .{
        .width = width,
        .height = height,
        .cs = 1,
        .ch = 0.5,
        .bmin = .{ 0, 0, 0 },
        .bmax = .{ @floatFromInt(width), top, @floatFromInt(height) },
        .walkable_height = 2,
        .walkable_climb = 1,
        .walkable_radius = 0,
        .max_edge_len = 12,
        .max_simplification_error = 0.5,
        .min_region_area = 0,
        .merge_region_area = 0,
        .max_verts_per_poly = 6,
        .detail_sample_dist = 6,
        .detail_sample_max_error = 1,
    };
}

/// Runs `case` with each partition and returns the summaries.
fn expectSameEveryPartition(case: pipeline.Case, label: []const u8) ![3]pipeline.Summary {
    var summaries: [3]pipeline.Summary = undefined;
    const partitions = [_]pipeline.Partition{ .watershed, .monotone, .layers };
    for (&summaries, partitions) |*summary, partition| {
        var c = case;
        c.partition = partition;
        var buffer: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&buffer, "{s}, {t} regions", .{ label, partition });
        summary.* = try pipeline.expectSame(&c, name, true);
    }
    return summaries;
}

fn walkableSpan(x: i32, z: i32, smin: u16, smax: u16) pipeline.ExtraSpan {
    const area = recast.walkable_area;
    return .{ .x = x, .z = z, .smin = smin, .smax = smax, .area = area, .merge = 1 };
}

/// Walkable spans in a `size` by `size` field where `keep` says, and with
/// `block` a solid 3 by 3 block in a corner: its middle is the only span
/// away from an edge, which makes the watershed flood every span.
fn pattern(size: i32, block: bool, keep: fn (x: i32, z: i32) bool) ![]pipeline.ExtraSpan {
    var spans: std.ArrayList(pipeline.ExtraSpan) = .empty;
    errdefer spans.deinit(gpa);
    var z: i32 = 0;
    while (z < size) : (z += 1) {
        var x: i32 = 0;
        while (x < size) : (x += 1) {
            const in_block = block and x < 3 and z < 3;
            if (!keep(x, z) and !in_block) continue;
            try spans.append(gpa, walkableSpan(x, z, 0, 2));
        }
    }
    return spans.toOwnedSlice(gpa);
}

/// Every other column, no two of them neighbours: each span a region with
/// no contour, as the original keeps no contour of a lone span.
fn checkerboard(x: i32, z: i32) bool {
    return @mod(x + z, 2) == 0;
}

/// Pairs of neighbours along x on every other row: each pair a region whose
/// contour has four vertices.
fn dominoes(x: i32, z: i32) bool {
    return @mod(z, 2) == 0 and @mod(x, 3) != 2;
}

test "an empty scene builds empty meshes as the original" {
    const tiles = [_]recast.Config{ tile(0, 0, 4), tile(8, 8, 4) };
    const case: pipeline.Case = .{
        .verts = &.{},
        .tris = &.{},
        .areas = &.{},
        .layers = true,
        .tiles = &tiles,
    };
    for (try expectSameEveryPartition(case, "empty scene")) |summary| {
        try testing.expectEqual(null, summary.failedStep());
    }
}

test "one triangle builds as the original, with and without a border" {
    const verts = [_]f32{ 0.5, 1, 0.5, 0.5, 1, 3.5, 3.5, 1, 0.5 };
    const tris = [_]i32{ 0, 1, 2 };
    const areas = [_]u8{0};
    var bordered = tile(8, 8, 4);
    bordered.border_size = 2;
    bordered.bmin = .{ -2, 0, -2 };
    bordered.bmax = .{ 6, 4, 6 };
    for ([_]recast.Config{ tile(4, 4, 4), bordered }) |cfg| {
        const tiles = [_]recast.Config{cfg};
        const case: pipeline.Case = .{
            .verts = &verts,
            .tris = &tris,
            .areas = &areas,
            .layers = true,
            .tiles = &tiles,
        };
        for (try expectSameEveryPartition(case, "one triangle")) |summary| {
            try testing.expectEqual(null, summary.failedStep());
        }
    }
}

test "borders of half the field and wider build as the original" {
    // Two triangles over the whole field, under borders from half its
    // width, which leaves no cell inside, to wider than the field.
    const verts = [_]f32{ 0, 1, 0, 0, 1, 8, 8, 1, 8, 8, 1, 0 };
    const tris = [_]i32{ 0, 1, 2, 0, 2, 3 };
    const areas = [_]u8{ 0, 0 };
    for ([_]i32{ 3, 4, 5, 8, 9, 30 }) |border| {
        var cfg = tile(8, 8, 4);
        cfg.border_size = border;
        const tiles = [_]recast.Config{cfg};
        const case: pipeline.Case = .{
            .verts = &verts,
            .tris = &tris,
            .areas = &areas,
            .layers = true,
            .tiles = &tiles,
        };
        _ = try expectSameEveryPartition(case, "wide border");
    }
}

test "tiles off the cell grid and of other cell sizes merge as the original" {
    // A floor under four tiles: the first sets the merge's grid, the second
    // starts off that grid, and the last two have other cell sizes, which
    // the merge reads on the first tile's grid.
    const verts = [_]f32{ 0, 1, 0, 0, 1, 12, 12, 1, 12, 12, 1, 0 };
    const tris = [_]i32{ 0, 1, 2, 0, 2, 3 };
    const areas = [_]u8{ 0, 0 };
    const tiles = [_]recast.Config{
        squareTile(-0.3, -0.3, 6.5, 0.5),
        squareTile(5.83, -0.3, 6.5, 0.5),
        squareTile(0.1, 6.0, 6, 0.3),
        squareTile(6.05, 6.11, 6, 0.4),
    };
    const case: pipeline.Case = .{
        .verts = &verts,
        .tris = &tris,
        .areas = &areas,
        .tiles = &tiles,
    };
    for (try expectSameEveryPartition(case, "tiles off the grid")) |summary| {
        try testing.expectEqual(null, summary.failedStep());
    }
}

/// A tile from (`x`, `z`) at least `size` wide, in cells of size `cs`.
fn squareTile(x: f32, z: f32, size: f32, cs: f32) recast.Config {
    const cells: i32 = @intFromFloat(@ceil(size / cs));
    const extent = @as(f32, @floatFromInt(cells)) * cs;
    var cfg = tile(cells, cells, 4);
    cfg.cs = cs;
    cfg.bmin = .{ x, 0, z };
    cfg.bmax = .{ x + extent, 4, z + extent };
    return cfg;
}

test "one span builds as the original" {
    const spans = [_]pipeline.ExtraSpan{walkableSpan(0, 0, 0, 2)};
    for ([_]i32{ 1, 3 }) |size| {
        const tiles = [_]recast.Config{tile(size, size, 4)};
        const case: pipeline.Case = .{
            .verts = &.{},
            .tris = &.{},
            .areas = &.{},
            .spans = &spans,
            .filters = @splat(false),
            .layers = true,
            .tiles = &tiles,
        };
        for (try expectSameEveryPartition(case, "one span")) |summary| {
            try testing.expectEqual(null, summary.failedStep());
        }
    }
}

test "more regions than 16 bits hold fail the watershed as the original" {
    // The block makes the distance field reach 2, so the watershed floods
    // at level 0 and makes each lone span a region of its own.
    const spans = try pattern(384, true, checkerboard);
    defer gpa.free(spans);
    const tiles = [_]recast.Config{tile(384, 384, 4)};
    const case: pipeline.Case = .{
        .verts = &.{},
        .tris = &.{},
        .areas = &.{},
        .spans = spans,
        .filters = @splat(false),
        .tiles = &tiles,
    };
    const summary = try pipeline.expectSame(&case, "region id overflow", false);
    try testing.expectEqualStrings("tile 0: regions", summary.failedStep().?);
}

test "more contour vertices than a mesh indexes fail the polygon mesh as the original" {
    // 24,576 regions of two spans, with four contour vertices each.
    const spans = try pattern(384, true, dominoes);
    defer gpa.free(spans);
    const tiles = [_]recast.Config{tile(384, 384, 4)};
    const case: pipeline.Case = .{
        .verts = &.{},
        .tris = &.{},
        .areas = &.{},
        .spans = spans,
        .filters = @splat(false),
        .tiles = &tiles,
    };
    for (try expectSameEveryPartition(case, "too many vertices")) |summary| {
        try testing.expectEqualStrings("tile 0: polymesh", summary.failedStep().?);
    }
}

test "more than 255 layer regions fail the heightfield layers as the original" {
    const spans = try pattern(32, false, checkerboard);
    defer gpa.free(spans);
    const tiles = [_]recast.Config{tile(32, 32, 4)};
    const case: pipeline.Case = .{
        .verts = &.{},
        .tris = &.{},
        .areas = &.{},
        .spans = spans,
        .filters = @splat(false),
        .layers = true,
        .tiles = &tiles,
    };
    const summary = try pipeline.expectSame(&case, "layer region overflow", true);
    try testing.expectEqualStrings("tile 0: layers", summary.failedStep().?);
}

test "a floor under more platforms than a layer holds fails the layers as the original" {
    // A 20 by 10 floor, and over it 100 platforms two cells long, at two
    // heights in a checkerboard so no two platforms join. A row has 11
    // sweeps, within the 20 the original holds.
    var spans: std.ArrayList(pipeline.ExtraSpan) = .empty;
    defer spans.deinit(gpa);
    var z: i32 = 0;
    while (z < 10) : (z += 1) {
        var x: i32 = 0;
        while (x < 20) : (x += 1) {
            const smin: u16 = if (@mod(@divTrunc(x, 2) + z, 2) == 0) 48 else 58;
            try spans.append(gpa, walkableSpan(x, z, 0, 2));
            try spans.append(gpa, walkableSpan(x, z, smin, smin + 2));
        }
    }
    const tiles = [_]recast.Config{tile(20, 10, 40)};
    const case: pipeline.Case = .{
        .verts = &.{},
        .tris = &.{},
        .areas = &.{},
        .spans = spans.items,
        .filters = @splat(false),
        .layers = true,
        .tiles = &tiles,
    };
    const summary = try pipeline.expectSame(&case, "layer overflow", true);
    try testing.expectEqualStrings("tile 0: layers", summary.failedStep().?);
}

test "spans at the top of the height range build as the original" {
    // A flat quad just under the 8,191 cells a span's limits hold, a ramp
    // through them, and spans beyond them, whose limits keep 13 bits.
    const ch = 0.5;
    const flat_y = 8189.2 * ch;
    const verts = [_]f32{
        0, flat_y,      0, 0, flat_y,      6, 3, flat_y,      6, 3, flat_y,      0,
        3, 8180.0 * ch, 0, 3, 8180.0 * ch, 6, 6, 8200.0 * ch, 6, 6, 8200.0 * ch, 0,
    };
    const tris = [_]i32{ 0, 1, 3, 3, 1, 2, 4, 5, 7, 7, 5, 6 };
    const areas = [_]u8{ 0, 0, 0, 0 };
    const spans = [_]pipeline.ExtraSpan{
        walkableSpan(1, 1, 8190, 8191),
        walkableSpan(2, 2, 8191, 8195),
        walkableSpan(4, 4, 8000, 9000),
        walkableSpan(5, 5, 0xfff0, 0xffff),
    };
    const tiles = [_]recast.Config{tile(6, 6, 8191 * ch + 40)};
    const case: pipeline.Case = .{
        .verts = &verts,
        .tris = &tris,
        .areas = &areas,
        .spans = &spans,
        .layers = true,
        .tiles = &tiles,
    };
    _ = try expectSameEveryPartition(case, "tallest spans");
}

test "a column of more walkable spans than a compact cell counts wraps as the original's" {
    // 300 floors in one column: the cell's 8-bit count keeps 44 of them.
    // The field is 64 wide, so a row's sweeps fit the original's buffers.
    var spans: std.ArrayList(pipeline.ExtraSpan) = .empty;
    defer spans.deinit(gpa);
    for (0..300) |i| {
        const smin: u16 = @intCast(i * 3);
        try spans.append(gpa, walkableSpan(1, 1, smin, smin + 1));
    }
    try spans.append(gpa, walkableSpan(0, 1, 0, 1));
    try spans.append(gpa, walkableSpan(2, 1, 3, 4));
    const tiles = [_]recast.Config{tile(64, 3, 500)};
    const case: pipeline.Case = .{
        .verts = &.{},
        .tris = &.{},
        .areas = &.{},
        .spans = spans.items,
        .filters = @splat(false),
        .layers = true,
        .tiles = &tiles,
    };
    _ = try expectSameEveryPartition(case, "300 spans in a column");
}

test "degenerate triangles build as the original" {
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const verts = [_]f32{
        // A point.
        1.5, 1,   1.5, 1.5, 1,   1.5, 1.5, 1,    1.5,
        // A line along x, on a cell boundary.
        0,   1,   2,   3,   1,   2,   6,   1,    2,
        // A vertical triangle.
        1,   0,   4,   1,   3,   4,   4,   0,    4,
        // A sliver.
        0,   1,   5,   6,   1,   5,   6,   1,    5.001,
        // Heights that are not a number or infinite.
        1,   nan, 1,   2,   1,   1,   2,   1,    3,
        3,   1,   3,   4,   inf, 3,   5,   -inf, 5,
        // A proper triangle, so something gets built.
        0.2, 0.5, 0.2, 0.2, 0.5, 5.8, 5.8, 0.5,  0.2,
    };
    var tris: [verts.len / 3]i32 = undefined;
    for (&tris, 0..) |*t, i| t.* = @intCast(i);
    const areas: [tris.len / 3]u8 = @splat(0);
    const tiles = [_]recast.Config{tile(6, 6, 4)};
    for ([_]pipeline.Raster{ .int, .u16, .unindexed, .single }) |raster| {
        const case: pipeline.Case = .{
            .verts = &verts,
            .tris = &tris,
            .areas = &areas,
            .raster = raster,
            .layers = true,
            .tiles = &tiles,
        };
        _ = try expectSameEveryPartition(case, "degenerate triangles");
    }
}
