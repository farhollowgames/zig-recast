//! Times the port against the original, feature by feature: every public
//! function of Recast, on the same inputs, one thread, the port built
//! ReleaseFast and the original -O3, both for the native CPU. The inputs
//! are each RecastDemo mesh and a large terrain with RecastDemo's
//! defaults, and that terrain and rolling ground as Loomwork's terrain
//! makes it, in tiles with Loomwork's navmesh settings. Each figure is the
//! median of several runs; the two sides take turns, tile by tile. It
//! prints a Markdown table per feature, as the README shows them.
//!
//!   zig build bench -- [--runs n] [--warmup n] [--only part of an input's name]
//!                       [--cpu n]
//!
//! It runs 7 timed runs after 1 warm-up by default. `--cpu` pins the bench
//! to one CPU, so it keeps its caches.

const std = @import("std");
const builtin = @import("builtin");
const recast = @import("recast");
const upstream = @import("upstream");
const meshes = @import("meshes");

const Feature = enum(u8) {
    create_heightfield,
    mark_walkable,
    rasterize,
    filter_low_hanging,
    filter_ledge,
    filter_low_height,
    compact,
    erode,
    distance_field,
    regions,
    contours,
    polymesh,
    detail,
    // After the build, on what it made.
    span_count,
    clear_unwalkable,
    rasterize_u16,
    rasterize_unindexed,
    copy_polymesh,
    heightfield_layers,
    regions_monotone,
    regions_layers,
    median_filter,
    mark_box,
    mark_convex,
    mark_cylinder,
    // Once per input.
    merge_polymeshes,
    merge_detail_meshes,
    calc_bounds,
    calc_grid_size,
    offset_poly,
    /// The sum of the pipeline's features; the last.
    whole_build,
};

const feature_count = @typeInfo(Feature).@"enum".field_names.len;

/// The features of a navmesh build, in Loomwork's order.
const pipeline = [_]Feature{
    .create_heightfield, .mark_walkable,     .rasterize, .filter_low_hanging,
    .filter_ledge,       .filter_low_height, .compact,   .erode,
    .distance_field,     .regions,           .contours,  .polymesh,
    .detail,
};

const Info = struct {
    title: []const u8,
    original: []const u8,
    port: []const u8,
    /// What the feature works through, for its throughput.
    per: Per,
    /// Above 0, the feature is timed over this many calls, and reported
    /// per call.
    calls: u32 = 0,
};

/// The units of work, summed over an input's tiles.
const Per = enum(u8) {
    triangles,
    vertices,
    cells,
    /// The heightfield's spans, after rasterization.
    spans,
    /// The compact heightfield's spans.
    compact_spans,
    /// The polygon mesh's polygons.
    polygons,
    calls,

    fn name(per: Per) []const u8 {
        return switch (per) {
            .triangles => "triangles",
            .vertices => "vertices",
            .cells => "cells",
            .spans => "spans",
            .compact_spans => "compact spans",
            .polygons => "polygons",
            .calls => "calls",
        };
    }
};

const per_count = @typeInfo(Per).@"enum".field_names.len;

/// How much of each unit an input has.
const Work = [per_count]u64;

fn info(feature: Feature) Info {
    return switch (feature) {
        .create_heightfield => .{
            .title = "Heightfield",
            .original = "rcCreateHeightfield",
            .port = "Heightfield.init",
            .per = .cells,
        },
        .mark_walkable => .{
            .title = "Walkable triangles",
            .original = "rcMarkWalkableTriangles",
            .port = "markWalkableTriangles",
            .per = .triangles,
        },
        .rasterize => .{
            .title = "Rasterization, int indices",
            .original = "rcRasterizeTriangles",
            .port = "rasterizeTriangles",
            .per = .triangles,
        },
        .filter_low_hanging => .{
            .title = "Low hanging obstacles filter",
            .original = "rcFilterLowHangingWalkableObstacles",
            .port = "filterLowHangingWalkableObstacles",
            .per = .spans,
        },
        .filter_ledge => .{
            .title = "Ledge filter",
            .original = "rcFilterLedgeSpans",
            .port = "filterLedgeSpans",
            .per = .spans,
        },
        .filter_low_height => .{
            .title = "Low height filter",
            .original = "rcFilterWalkableLowHeightSpans",
            .port = "filterWalkableLowHeightSpans",
            .per = .spans,
        },
        .compact => .{
            .title = "Compact heightfield",
            .original = "rcBuildCompactHeightfield",
            .port = "buildCompactHeightfield",
            .per = .spans,
        },
        .erode => .{
            .title = "Erosion",
            .original = "rcErodeWalkableArea",
            .port = "erodeWalkableArea",
            .per = .compact_spans,
        },
        .distance_field => .{
            .title = "Distance field",
            .original = "rcBuildDistanceField",
            .port = "buildDistanceField",
            .per = .compact_spans,
        },
        .regions => .{
            .title = "Watershed regions",
            .original = "rcBuildRegions",
            .port = "buildRegions",
            .per = .compact_spans,
        },
        .contours => .{
            .title = "Contours",
            .original = "rcBuildContours",
            .port = "buildContours",
            .per = .compact_spans,
        },
        .polymesh => .{
            .title = "Polygon mesh",
            .original = "rcBuildPolyMesh",
            .port = "buildPolyMesh",
            .per = .polygons,
        },
        .detail => .{
            .title = "Detail mesh",
            .original = "rcBuildPolyMeshDetail",
            .port = "buildPolyMeshDetail",
            .per = .polygons,
        },
        .span_count => .{
            .title = "Span count",
            .original = "rcGetHeightFieldSpanCount",
            .port = "getHeightFieldSpanCount",
            .per = .spans,
        },
        .clear_unwalkable => .{
            .title = "Unwalkable triangles",
            .original = "rcClearUnwalkableTriangles",
            .port = "clearUnwalkableTriangles",
            .per = .triangles,
        },
        .rasterize_u16 => .{
            .title = "Rasterization, unsigned short indices",
            .original = "rcRasterizeTriangles",
            .port = "rasterizeTriangles",
            .per = .triangles,
        },
        .rasterize_unindexed => .{
            .title = "Rasterization, unindexed",
            .original = "rcRasterizeTriangles",
            .port = "rasterizeUnindexedTriangles",
            .per = .triangles,
        },
        .copy_polymesh => .{
            .title = "Polygon mesh copy",
            .original = "rcCopyPolyMesh",
            .port = "copyPolyMesh",
            .per = .polygons,
        },
        .heightfield_layers => .{
            .title = "Heightfield layers",
            .original = "rcBuildHeightfieldLayers",
            .port = "buildHeightfieldLayers",
            .per = .compact_spans,
        },
        .regions_monotone => .{
            .title = "Monotone regions",
            .original = "rcBuildRegionsMonotone",
            .port = "buildRegionsMonotone",
            .per = .compact_spans,
        },
        .regions_layers => .{
            .title = "Layer regions",
            .original = "rcBuildLayerRegions",
            .port = "buildLayerRegions",
            .per = .compact_spans,
        },
        .median_filter => .{
            .title = "Median area filter",
            .original = "rcMedianFilterWalkableArea",
            .port = "medianFilterWalkableArea",
            .per = .compact_spans,
        },
        .mark_box => .{
            .title = "Box area",
            .original = "rcMarkBoxArea",
            .port = "markBoxArea",
            .per = .compact_spans,
        },
        .mark_convex => .{
            .title = "Convex area",
            .original = "rcMarkConvexPolyArea",
            .port = "markConvexPolyArea",
            .per = .compact_spans,
        },
        .mark_cylinder => .{
            .title = "Cylinder area",
            .original = "rcMarkCylinderArea",
            .port = "markCylinderArea",
            .per = .compact_spans,
        },
        .merge_polymeshes => .{
            .title = "Polygon mesh merge, every tile",
            .original = "rcMergePolyMeshes",
            .port = "mergePolyMeshes",
            .per = .polygons,
        },
        .merge_detail_meshes => .{
            .title = "Detail mesh merge, every tile",
            .original = "rcMergePolyMeshDetails",
            .port = "mergePolyMeshDetails",
            .per = .polygons,
        },
        .calc_bounds => .{
            .title = "Bounds",
            .original = "rcCalcBounds",
            .port = "calcBounds",
            .per = .vertices,
        },
        .calc_grid_size => .{
            .title = "Grid size",
            .original = "rcCalcGridSize",
            .port = "calcGridSize",
            .per = .calls,
            .calls = 10_000,
        },
        .whole_build => .{
            .title = "Whole build",
            .original = "",
            .port = "",
            .per = .triangles,
        },
        .offset_poly => .{
            .title = "Polygon offset, a hexagon",
            .original = "rcOffsetPoly",
            .port = "offsetPoly",
            .per = .calls,
            .calls = 10_000,
        },
    };
}

/// Nanoseconds per feature in one run; null where a feature does not
/// apply to an input, `failed` where it fails on one of its tiles.
const Times = [feature_count]?u64;

const failed = std.math.maxInt(u64);

const Lap = struct {
    io: std.Io,
    start: std.Io.Timestamp,
    times: *Times,

    fn begin(io: std.Io, times: *Times) Lap {
        return .{ .io = io, .start = std.Io.Clock.awake.now(io), .times = times };
    }

    /// Adds the time since the last mark to `feature`, after making the
    /// compiler keep the work that went into `result`.
    fn end(lap: *Lap, feature: Feature, result: anytype) void {
        std.mem.doNotOptimizeAway(result);
        const now = std.Io.Clock.awake.now(lap.io);
        const t = &lap.times[@backingInt(feature)];
        const elapsed: u64 = @intCast(lap.start.durationTo(now).nanoseconds);
        if (t.* != failed) t.* = (t.* orelse 0) + elapsed;
        lap.start = now;
    }

    /// Leaves the time since the last mark out.
    fn skip(lap: *Lap) void {
        lap.start = std.Io.Clock.awake.now(lap.io);
    }

    /// Marks `feature` as failed on this input, and leaves its time out.
    fn fail(lap: *Lap, feature: Feature) void {
        lap.times[@backingInt(feature)] = failed;
        lap.skip();
    }
};

/// RecastDemo's solo defaults.
fn soloConfig(bmin: [3]f32, bmax: [3]f32) recast.Config {
    var cfg: recast.Config = .{
        .cs = 0.3,
        .ch = 0.2,
        .walkable_slope_angle = 45,
        .walkable_height = 10,
        .walkable_climb = 4,
        .walkable_radius = 2,
        .max_edge_len = 40,
        .max_simplification_error = 1.3,
        .min_region_area = 64,
        .merge_region_area = 400,
        .max_verts_per_poly = 6,
        .detail_sample_dist = 1.8,
        .detail_sample_max_error = 0.2,
        .bmin = bmin,
        .bmax = bmax,
    };
    const grid = recast.calcGridSize(&bmin, &bmax, cfg.cs);
    cfg.width = grid.width;
    cfg.height = grid.height;
    return cfg;
}

/// Loomwork's tiles: 64 m square, 512 cells of 125 mm.
const tile_size: f32 = 64.0;

/// Loomwork's navmesh settings for one tile, as its shim computes them
/// for its default character: 1.8 m tall, 0.35 m across, climbing 0.3 m,
/// on slopes up to 50 degrees.
fn tileConfig(bmin: [3]f32, bmax: [3]f32, tx: i32, tz: i32) recast.Config {
    var cfg: recast.Config = .{
        .cs = 0.125,
        .ch = 0.2,
        .walkable_slope_angle = 50,
        .max_simplification_error = 1.3,
        .max_verts_per_poly = 6,
        .detail_sample_dist = 1.8,
    };
    cfg.walkable_height = @intFromFloat(@ceil(1.8 / cfg.ch));
    cfg.walkable_climb = @intFromFloat(@floor(0.3 / cfg.ch));
    cfg.walkable_radius = @intFromFloat(@ceil(0.35 / cfg.cs));
    cfg.max_edge_len = @intFromFloat(12.0 / cfg.cs);
    cfg.min_region_area = @intFromFloat((2.4 / cfg.cs) * (2.4 / cfg.cs));
    cfg.merge_region_area = @intFromFloat((6.0 / cfg.cs) * (6.0 / cfg.cs));
    cfg.detail_sample_max_error = cfg.ch;
    cfg.tile_size = @intFromFloat(tile_size / cfg.cs + 0.5);
    cfg.border_size = cfg.walkable_radius + 3;
    cfg.width = cfg.tile_size + 2 * cfg.border_size;
    cfg.height = cfg.width;
    const border = @as(f32, @floatFromInt(cfg.border_size)) * cfg.cs;
    const fx: f32 = @floatFromInt(tx);
    const fz: f32 = @floatFromInt(tz);
    cfg.bmin = .{ bmin[0] + fx * tile_size - border, bmin[1], bmin[2] + fz * tile_size - border };
    cfg.bmax = .{
        bmin[0] + (fx + 1) * tile_size + border,
        bmax[1],
        bmin[2] + (fz + 1) * tile_size + border,
    };
    return cfg;
}

/// One build's input: its settings and triangles, and the triangles with
/// 16-bit indices (where the mesh's vertices fit them) and unindexed.
const Tile = struct {
    cfg: recast.Config,
    tris: []const i32,
    tris_u16: ?[]const u16,
    flat_verts: []const f32,
};

/// The triangles of `mesh` whose footprint touches the build's bounds, as a
/// caller culls them per tile.
fn cull(gpa: std.mem.Allocator, mesh: *const meshes.Mesh, cfg: *const recast.Config) ![]i32 {
    var tris: std.ArrayList(i32) = .empty;
    errdefer tris.deinit(gpa);
    var i: usize = 0;
    while (i < mesh.tris.len) : (i += 3) {
        var lo: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
        var hi: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
        for (mesh.tris[i..][0..3]) |v| {
            const p = mesh.verts[@as(usize, @intCast(v)) * 3 ..][0..3];
            lo = .{ @min(lo[0], p[0]), @min(lo[1], p[2]) };
            hi = .{ @max(hi[0], p[0]), @max(hi[1], p[2]) };
        }
        if (hi[0] < cfg.bmin[0] or lo[0] > cfg.bmax[0]) continue;
        if (hi[1] < cfg.bmin[2] or lo[1] > cfg.bmax[2]) continue;
        try tris.appendSlice(gpa, mesh.tris[i..][0..3]);
    }
    return tris.toOwnedSlice(gpa);
}

fn tileOf(gpa: std.mem.Allocator, mesh: *const meshes.Mesh, cfg: recast.Config) !Tile {
    const tris = if (cfg.tile_size == 0) mesh.tris else try cull(gpa, mesh, &cfg);
    const tris_u16: ?[]u16 = if (mesh.verts.len / 3 <= 0xffff) blk: {
        const narrow = try gpa.alloc(u16, tris.len);
        for (narrow, tris) |*n, t| n.* = @intCast(t);
        break :blk narrow;
    } else null;
    const flat_verts = try gpa.alloc(f32, tris.len * 3);
    for (tris, 0..) |t, i| {
        flat_verts[i * 3 ..][0..3].* = mesh.verts[@as(usize, @intCast(t)) * 3 ..][0..3].*;
    }
    return .{ .cfg = cfg, .tris = tris, .tris_u16 = tris_u16, .flat_verts = flat_verts };
}

/// Shapes to mark in the middle of a build's bounds.
const Marks = struct {
    box_min: [3]f32,
    box_max: [3]f32,
    hexagon: [6 * 3]f32,
    centre: [3]f32,
    radius: f32,
    height: f32,

    fn of(cfg: *const recast.Config) Marks {
        const lo = cfg.bmin;
        const hi = cfg.bmax;
        const size = [3]f32{ hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2] };
        const centre = [3]f32{ lo[0] + size[0] / 2, lo[1], lo[2] + size[2] / 2 };
        const radius = @min(size[0], size[2]) / 4;
        var hexagon: [6 * 3]f32 = undefined;
        for (0..6) |i| {
            const a = @as(f32, @floatFromInt(i)) * std.math.pi / 3;
            hexagon[i * 3 ..][0..3].* = .{
                centre[0] + radius * @cos(a),
                centre[1],
                centre[2] + radius * @sin(a),
            };
        }
        return .{
            .box_min = .{ lo[0] + size[0] / 4, lo[1], lo[2] + size[2] / 4 },
            .box_max = .{ hi[0] - size[0] / 4, hi[1], hi[2] - size[2] / 4 },
            .hexagon = hexagon,
            .centre = centre,
            .radius = radius,
            .height = size[1],
        };
    }
};

/// What a tile's build keeps for the merges.
const PortMeshes = struct { pmesh: recast.PolyMesh, dmesh: recast.PolyMeshDetail };
const OriginalMeshes = struct { pmesh: *upstream.PolyMesh, dmesh: *upstream.PolyMeshDetail };

fn buildPort(
    io: std.Io,
    gpa: std.mem.Allocator,
    verts: []const f32,
    tile: *const Tile,
    times: *Times,
    work: *Work,
) !PortMeshes {
    const ctx: recast.Context = .none;
    const cfg = &tile.cfg;
    const tris = tile.tris;
    const areas = try gpa.alloc(u8, tris.len / 3);
    defer gpa.free(areas);
    @memset(areas, 0);

    var lap: Lap = .begin(io, times);
    var hf = try recast.Heightfield.init(
        gpa,
        cfg.width,
        cfg.height,
        &cfg.bmin,
        &cfg.bmax,
        cfg.cs,
        cfg.ch,
    );
    defer hf.deinit(gpa);
    lap.end(.create_heightfield, &hf);
    recast.markWalkableTriangles(ctx, cfg.walkable_slope_angle, verts, tris, areas);
    lap.end(.mark_walkable, areas.ptr);
    try recast.rasterizeTriangles(ctx, gpa, verts, i32, tris, areas, &hf, cfg.walkable_climb);
    lap.end(.rasterize, &hf);
    recast.filterLowHangingWalkableObstacles(ctx, cfg.walkable_climb, &hf);
    lap.end(.filter_low_hanging, &hf);
    recast.filterLedgeSpans(ctx, cfg.walkable_height, cfg.walkable_climb, &hf);
    lap.end(.filter_ledge, &hf);
    recast.filterWalkableLowHeightSpans(ctx, cfg.walkable_height, &hf);
    lap.end(.filter_low_height, &hf);
    var chf = try recast.buildCompactHeightfield(
        ctx,
        gpa,
        cfg.walkable_height,
        cfg.walkable_climb,
        &hf,
    );
    defer chf.deinit(gpa);
    lap.end(.compact, &chf);
    try recast.erodeWalkableArea(ctx, gpa, cfg.walkable_radius, &chf);
    lap.end(.erode, &chf);
    try recast.buildDistanceField(ctx, gpa, &chf);
    lap.end(.distance_field, &chf);
    try recast.buildRegions(
        ctx,
        gpa,
        &chf,
        cfg.border_size,
        cfg.min_region_area,
        cfg.merge_region_area,
    );
    lap.end(.regions, &chf);
    var cset = try recast.buildContours(
        ctx,
        gpa,
        &chf,
        cfg.max_simplification_error,
        cfg.max_edge_len,
        .default,
    );
    defer cset.deinit(gpa);
    lap.end(.contours, &cset);
    var pmesh = try recast.buildPolyMesh(ctx, gpa, &cset, cfg.max_verts_per_poly);
    errdefer pmesh.deinit(gpa);
    lap.end(.polymesh, &pmesh);
    var dmesh = try recast.buildPolyMeshDetail(
        ctx,
        gpa,
        &pmesh,
        &chf,
        cfg.detail_sample_dist,
        cfg.detail_sample_max_error,
    );
    errdefer dmesh.deinit(gpa);
    lap.end(.detail, &dmesh);
    work[@backingInt(Per.triangles)] += tris.len / 3;
    work[@backingInt(Per.cells)] += @intCast(cfg.width * cfg.height);
    work[@backingInt(Per.spans)] += spanCount(&hf);
    work[@backingInt(Per.compact_spans)] += @intCast(chf.span_count);
    work[@backingInt(Per.polygons)] += @intCast(pmesh.npolys);
    lap.skip();

    std.mem.doNotOptimizeAway(recast.getHeightFieldSpanCount(ctx, &hf));
    lap.end(.span_count, {});
    recast.clearUnwalkableTriangles(ctx, cfg.walkable_slope_angle, verts, tris, areas);
    lap.end(.clear_unwalkable, areas.ptr);
    if (tile.tris_u16) |tris_u16| {
        var other = try heightfieldOf(gpa, cfg);
        defer other.deinit(gpa);
        lap.skip();
        const climb = cfg.walkable_climb;
        try recast.rasterizeTriangles(ctx, gpa, verts, u16, tris_u16, areas, &other, climb);
        lap.end(.rasterize_u16, &other);
    }
    {
        var other = try heightfieldOf(gpa, cfg);
        defer other.deinit(gpa);
        lap.skip();
        const flat = tile.flat_verts;
        try recast.rasterizeUnindexedTriangles(ctx, gpa, flat, areas, &other, cfg.walkable_climb);
        lap.end(.rasterize_unindexed, &other);
    }
    {
        var copy = try recast.copyPolyMesh(ctx, gpa, &pmesh);
        lap.end(.copy_polymesh, &copy);
        copy.deinit(gpa);
        lap.skip();
    }
    if (recast.buildHeightfieldLayers(ctx, gpa, &chf, cfg.border_size, cfg.walkable_height)) |set| {
        var lset = set;
        lap.end(.heightfield_layers, &lset);
        lset.deinit(gpa);
        lap.skip();
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        error.RegionIdOverflow, error.LayerOverflow => lap.fail(.heightfield_layers),
    }
    const border = cfg.border_size;
    const min_area = cfg.min_region_area;
    if (recast.buildRegionsMonotone(ctx, gpa, &chf, border, min_area, cfg.merge_region_area)) {
        lap.end(.regions_monotone, &chf);
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        error.RegionIdOverflow => lap.fail(.regions_monotone),
    }
    if (recast.buildLayerRegions(ctx, gpa, &chf, border, min_area)) {
        lap.end(.regions_layers, &chf);
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        error.RegionIdOverflow => lap.fail(.regions_layers),
    }
    try recast.medianFilterWalkableArea(ctx, gpa, &chf);
    lap.end(.median_filter, &chf);
    const marks: Marks = .of(cfg);
    recast.markBoxArea(ctx, &marks.box_min, &marks.box_max, 2, &chf);
    lap.end(.mark_box, &chf);
    recast.markConvexPolyArea(ctx, &marks.hexagon, cfg.bmin[1], cfg.bmax[1], 3, &chf);
    lap.end(.mark_convex, &chf);
    recast.markCylinderArea(ctx, &marks.centre, marks.radius, marks.height, 4, &chf);
    lap.end(.mark_cylinder, &chf);
    return .{ .pmesh = pmesh, .dmesh = dmesh };
}

/// Every span of `hf`, walkable or not.
fn spanCount(hf: *const recast.Heightfield) u64 {
    var count: u64 = 0;
    for (hf.spans) |column| {
        var span = column;
        while (span) |s| : (span = s.next) count += 1;
    }
    return count;
}

fn heightfieldOf(gpa: std.mem.Allocator, cfg: *const recast.Config) !recast.Heightfield {
    const w = cfg.width;
    const h = cfg.height;
    return recast.Heightfield.init(gpa, w, h, &cfg.bmin, &cfg.bmax, cfg.cs, cfg.ch);
}

fn originalHeightfieldOf(log: *upstream.Log, cfg: *const recast.Config) !*upstream.Heightfield {
    const w = cfg.width;
    const h = cfg.height;
    return upstream.shim_hf_create(log, w, h, &cfg.bmin, &cfg.bmax, cfg.cs, cfg.ch) orelse
        return error.OutOfMemory;
}

fn buildOriginal(
    io: std.Io,
    log: *upstream.Log,
    verts: []const f32,
    tile: *const Tile,
    times: *Times,
) !OriginalMeshes {
    const cfg = &tile.cfg;
    const tris = tile.tris;
    const nv: c_int = @intCast(verts.len / 3);
    const nt: c_int = @intCast(tris.len / 3);
    const areas = try std.heap.c_allocator.alloc(u8, tris.len / 3);
    defer std.heap.c_allocator.free(areas);
    @memset(areas, 0);

    var lap: Lap = .begin(io, times);
    const hf = try originalHeightfieldOf(log, cfg);
    defer upstream.shim_hf_free(hf);
    lap.end(.create_heightfield, {});
    const slope = cfg.walkable_slope_angle;
    upstream.shim_mark_walkable(log, slope, verts.ptr, nv, tris.ptr, nt, areas.ptr);
    lap.end(.mark_walkable, {});
    const climb = cfg.walkable_climb;
    _ = upstream.shim_rasterize_triangles(log, verts.ptr, nv, tris.ptr, areas.ptr, nt, hf, climb);
    lap.end(.rasterize, {});
    upstream.shim_filter_low_hanging(log, cfg.walkable_climb, hf);
    lap.end(.filter_low_hanging, {});
    upstream.shim_filter_ledge(log, cfg.walkable_height, cfg.walkable_climb, hf);
    lap.end(.filter_ledge, {});
    upstream.shim_filter_low_height(log, cfg.walkable_height, hf);
    lap.end(.filter_low_height, {});
    const chf = upstream.shim_chf_build(log, cfg.walkable_height, cfg.walkable_climb, hf) orelse
        return error.OutOfMemory;
    defer upstream.shim_chf_free(chf);
    lap.end(.compact, {});
    _ = upstream.shim_erode(log, cfg.walkable_radius, chf);
    lap.end(.erode, {});
    _ = upstream.shim_distance_field(log, chf);
    lap.end(.distance_field, {});
    const border = cfg.border_size;
    _ = upstream.shim_regions(log, chf, border, cfg.min_region_area, cfg.merge_region_area);
    lap.end(.regions, {});
    const cset = upstream.shim_contours_build(
        log,
        chf,
        cfg.max_simplification_error,
        cfg.max_edge_len,
        1,
    ) orelse return error.OutOfMemory;
    defer upstream.shim_contours_free(cset);
    lap.end(.contours, {});
    const pmesh = upstream.shim_polymesh_build(log, cset, cfg.max_verts_per_poly) orelse
        return error.OutOfMemory;
    errdefer upstream.shim_polymesh_free(pmesh);
    lap.end(.polymesh, {});
    const dmesh = upstream.shim_detail_build(
        log,
        pmesh,
        chf,
        cfg.detail_sample_dist,
        cfg.detail_sample_max_error,
    ) orelse return error.OutOfMemory;
    errdefer upstream.shim_detail_free(dmesh);
    lap.end(.detail, {});

    std.mem.doNotOptimizeAway(upstream.shim_hf_span_count(log, hf));
    lap.end(.span_count, {});
    upstream.shim_clear_unwalkable(log, slope, verts.ptr, nv, tris.ptr, nt, areas.ptr);
    lap.end(.clear_unwalkable, {});
    if (tile.tris_u16) |tris_u16| {
        const other = try originalHeightfieldOf(log, cfg);
        defer upstream.shim_hf_free(other);
        lap.skip();
        const t = tris_u16.ptr;
        const a = areas.ptr;
        _ = upstream.shim_rasterize_triangles_u16(log, verts.ptr, nv, t, a, nt, other, climb);
        lap.end(.rasterize_u16, {});
    }
    {
        const other = try originalHeightfieldOf(log, cfg);
        defer upstream.shim_hf_free(other);
        lap.skip();
        const flat = tile.flat_verts.ptr;
        _ = upstream.shim_rasterize_unindexed(log, flat, areas.ptr, nt, other, climb);
        lap.end(.rasterize_unindexed, {});
    }
    {
        const copy = upstream.shim_polymesh_copy(log, pmesh) orelse return error.OutOfMemory;
        lap.end(.copy_polymesh, {});
        upstream.shim_polymesh_free(copy);
        lap.skip();
    }
    if (upstream.shim_layers_build(log, chf, border, cfg.walkable_height)) |lset| {
        lap.end(.heightfield_layers, {});
        upstream.shim_layers_free(lset);
        lap.skip();
    } else lap.fail(.heightfield_layers);
    const min_area = cfg.min_region_area;
    if (upstream.shim_regions_monotone(log, chf, border, min_area, cfg.merge_region_area) != 0) {
        lap.end(.regions_monotone, {});
    } else lap.fail(.regions_monotone);
    if (upstream.shim_layer_regions(log, chf, border, min_area) != 0) {
        lap.end(.regions_layers, {});
    } else lap.fail(.regions_layers);
    _ = upstream.shim_median(log, chf);
    lap.end(.median_filter, {});
    const marks: Marks = .of(cfg);
    upstream.shim_mark_box(log, &marks.box_min, &marks.box_max, 2, chf);
    lap.end(.mark_box, {});
    upstream.shim_mark_convex(log, &marks.hexagon, 6, cfg.bmin[1], cfg.bmax[1], 3, chf);
    lap.end(.mark_convex, {});
    upstream.shim_mark_cylinder(log, &marks.centre, marks.radius, marks.height, 4, chf);
    lap.end(.mark_cylinder, {});
    return .{ .pmesh = pmesh, .dmesh = dmesh };
}

/// The features timed once per input: the merges of every tile's meshes,
/// and the small functions, over many calls.
fn wholePort(
    io: std.Io,
    gpa: std.mem.Allocator,
    mesh: *const meshes.Mesh,
    built: []const PortMeshes,
    times: *Times,
) !void {
    const ctx: recast.Context = .none;
    var lap: Lap = .begin(io, times);
    if (built.len > 1) {
        const pmeshes = try gpa.alloc(*const recast.PolyMesh, built.len);
        defer gpa.free(pmeshes);
        const dmeshes = try gpa.alloc(*const recast.PolyMeshDetail, built.len);
        defer gpa.free(dmeshes);
        for (pmeshes, dmeshes, built) |*p, *d, *b| {
            p.* = &b.pmesh;
            d.* = &b.dmesh;
        }
        lap.skip();
        var pmesh = try recast.mergePolyMeshes(ctx, gpa, pmeshes);
        lap.end(.merge_polymeshes, &pmesh);
        pmesh.deinit(gpa);
        lap.skip();
        var dmesh = try recast.mergePolyMeshDetails(ctx, gpa, dmeshes);
        lap.end(.merge_detail_meshes, &dmesh);
        dmesh.deinit(gpa);
    }
    lap.skip();
    var bmin: [3]f32 = undefined;
    var bmax: [3]f32 = undefined;
    recast.calcBounds(mesh.verts, &bmin, &bmax);
    std.mem.doNotOptimizeAway(&bmin);
    std.mem.doNotOptimizeAway(&bmax);
    lap.end(.calc_bounds, {});
    for (0..info(.calc_grid_size).calls) |i| {
        const cs = 0.3 + @as(f32, @floatFromInt(i)) * 1e-6;
        std.mem.doNotOptimizeAway(recast.calcGridSize(&bmin, &bmax, cs));
    }
    lap.end(.calc_grid_size, {});
    const solo = soloConfig(bmin, bmax);
    const hexagon = Marks.of(&solo).hexagon;
    var out: [64 * 3]f32 = undefined;
    for (0..info(.offset_poly).calls) |i| {
        const offset = 0.5 + @as(f32, @floatFromInt(i)) * 1e-6;
        std.mem.doNotOptimizeAway(recast.offsetPoly(&hexagon, offset, &out));
        std.mem.doNotOptimizeAway(&out);
    }
    lap.end(.offset_poly, {});
}

fn wholeOriginal(
    io: std.Io,
    log: *upstream.Log,
    mesh: *const meshes.Mesh,
    built: []const OriginalMeshes,
    times: *Times,
) !void {
    var lap: Lap = .begin(io, times);
    if (built.len > 1) {
        const gpa = std.heap.c_allocator;
        const pmeshes = try gpa.alloc(*upstream.PolyMesh, built.len);
        defer gpa.free(pmeshes);
        const dmeshes = try gpa.alloc(*upstream.PolyMeshDetail, built.len);
        defer gpa.free(dmeshes);
        for (pmeshes, dmeshes, built) |*p, *d, b| {
            p.* = b.pmesh;
            d.* = b.dmesh;
        }
        const n: c_int = @intCast(built.len);
        lap.skip();
        const pmesh = upstream.shim_polymesh_merge(log, pmeshes.ptr, n) orelse
            return error.OutOfMemory;
        lap.end(.merge_polymeshes, {});
        upstream.shim_polymesh_free(pmesh);
        lap.skip();
        const dmesh = upstream.shim_detail_merge(log, dmeshes.ptr, n) orelse
            return error.OutOfMemory;
        lap.end(.merge_detail_meshes, {});
        upstream.shim_detail_free(dmesh);
    }
    lap.skip();
    var bmin: [3]f32 = undefined;
    var bmax: [3]f32 = undefined;
    upstream.shim_calc_bounds(mesh.verts.ptr, @intCast(mesh.verts.len / 3), &bmin, &bmax);
    lap.end(.calc_bounds, {});
    for (0..info(.calc_grid_size).calls) |i| {
        const cs = 0.3 + @as(f32, @floatFromInt(i)) * 1e-6;
        var w: c_int = undefined;
        var h: c_int = undefined;
        upstream.shim_calc_grid_size(&bmin, &bmax, cs, &w, &h);
        std.mem.doNotOptimizeAway(w);
        std.mem.doNotOptimizeAway(h);
    }
    lap.end(.calc_grid_size, {});
    const solo = soloConfig(bmin, bmax);
    const hexagon = Marks.of(&solo).hexagon;
    var out: [64 * 3]f32 = undefined;
    for (0..info(.offset_poly).calls) |i| {
        const offset = 0.5 + @as(f32, @floatFromInt(i)) * 1e-6;
        std.mem.doNotOptimizeAway(upstream.shim_offset_poly(&hexagon, 6, offset, &out, 64));
    }
    lap.end(.offset_poly, {});
}

/// One input of the bench: solo, or every tile of a terrain.
const Input = struct {
    name: []const u8,
    mesh: *const meshes.Mesh,
    tiles: []Tile,
    original: [feature_count]?Summary = @splat(null),
    port: [feature_count]?Summary = @splat(null),
    work: Work = @splat(0),
};

/// A feature's times over the runs: the median, and the spread from the
/// fastest to the slowest run; all `failed` where it failed.
const Summary = struct {
    median: u64,
    min: u64,
    max: u64,

    fn of(gpa: std.mem.Allocator, runs: []const Times, feature: usize) !?Summary {
        const values = try gpa.alloc(u64, runs.len);
        defer gpa.free(values);
        for (values, runs) |*v, run| v.* = run[feature] orelse return null;
        std.mem.sort(u64, values, {}, std.sort.asc(u64));
        if (values[values.len - 1] == failed) {
            return .{ .median = failed, .min = failed, .max = failed };
        }
        const mid = values.len / 2;
        return .{
            .median = if (values.len % 2 == 1) values[mid] else (values[mid - 1] + values[mid]) / 2,
            .min = values[0],
            .max = values[values.len - 1],
        };
    }

    /// The spread, as a share of the median.
    fn spread(summary: Summary) f64 {
        const range: f64 = @floatFromInt(summary.max - summary.min);
        return range / @as(f64, @floatFromInt(@max(summary.median, 1)));
    }
};

fn printTime(ns: u64, about: Info, amount: u64) void {
    const t: f64 = @floatFromInt(ns);
    if (about.calls > 0) {
        std.debug.print(" {d:.1} ns |", .{t / @as(f64, @floatFromInt(about.calls))});
        return;
    }
    if (ns >= 1_000_000) {
        std.debug.print(" {d:.2} ms", .{t / 1e6});
    } else {
        std.debug.print(" {d:.1} µs", .{t / 1e3});
    }
    const rate = @as(f64, @floatFromInt(amount)) / (t / 1e9);
    if (rate >= 1e9) {
        std.debug.print(", {d:.2} G/s |", .{rate / 1e9});
    } else if (rate >= 1e6) {
        std.debug.print(", {d:.1} M/s |", .{rate / 1e6});
    } else {
        std.debug.print(", {d:.1} k/s |", .{rate / 1e3});
    }
}

fn printAmount(amount: u64) void {
    const a: f64 = @floatFromInt(amount);
    if (amount >= 1_000_000) {
        std.debug.print(" {d:.2} M", .{a / 1e6});
    } else if (amount >= 10_000) {
        std.debug.print(" {d:.1} k", .{a / 1e3});
    } else {
        std.debug.print(" {d}", .{amount});
    }
}

fn printRow(name: []const u8, about: Info, amount: u64, original: Summary, port: Summary) void {
    std.debug.print("| {s} |", .{name});
    printAmount(amount);
    std.debug.print(" {s} |", .{about.per.name()});
    if (original.median == failed or port.median == failed) {
        const original_says = if (original.median == failed) "fails" else "works";
        const port_says = if (port.median == failed) "fails" else "works";
        std.debug.print(" {s} | {s} | | |\n", .{ original_says, port_says });
        return;
    }
    printTime(original.median, about, amount);
    printTime(port.median, about, amount);
    const ratio = @as(f64, @floatFromInt(port.median)) /
        @as(f64, @floatFromInt(@max(original.median, 1)));
    std.debug.print(" {d:.2} | {d:.1}% / {d:.1}% |\n", .{
        ratio,
        original.spread() * 100,
        port.spread() * 100,
    });
}

const table_head =
    \\| input | work | original | port | port ÷ original | spread, original / port |
    \\| --- | ---: | ---: | ---: | ---: | ---: |
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(arena);
    var runs: usize = 7;
    var warmups: usize = 1;
    var only: []const u8 = "";
    var arg: usize = 1;
    while (arg + 1 < args.len) : (arg += 2) {
        const value = args[arg + 1];
        if (std.mem.eql(u8, args[arg], "--runs")) {
            runs = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, args[arg], "--warmup")) {
            warmups = try std.fmt.parseInt(usize, value, 10);
        } else if (std.mem.eql(u8, args[arg], "--only")) {
            only = value;
        } else if (std.mem.eql(u8, args[arg], "--cpu")) {
            const cpu = try std.fmt.parseInt(usize, value, 10);
            var set: std.os.linux.cpu_set_t = @splat(0);
            set[cpu / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
            try std.os.linux.sched_setaffinity(0, &set);
        } else return error.UnknownOption;
    }
    if (arg < args.len or runs == 0) return error.UnknownOption;

    const log = upstream.shim_log_create() orelse return error.OutOfMemory;
    defer upstream.shim_log_destroy(log);
    upstream.shim_log_enable(log, 0, 0);

    var dungeon = try meshes.loadObj(arena, @embedFile("dungeon"));
    var nav_test = try meshes.loadObj(arena, @embedFile("nav_test"));
    var undulating = try meshes.loadObj(arena, @embedFile("undulating"));
    var terrain = try meshes.terrain(arena, 256, 1);
    var vale = try meshes.vale(arena, 256);

    var inputs: std.ArrayList(Input) = .empty;
    for ([_]struct { []const u8, *meshes.Mesh }{
        .{ "dungeon.obj", &dungeon },
        .{ "nav_test.obj", &nav_test },
        .{ "undulating.obj", &undulating },
        .{ "terrain 256 m", &terrain },
    }) |entry| {
        var bmin: [3]f32 = undefined;
        var bmax: [3]f32 = undefined;
        recast.calcBounds(entry[1].verts, &bmin, &bmax);
        const tiles = try arena.alloc(Tile, 1);
        tiles[0] = try tileOf(arena, entry[1], soloConfig(bmin, bmax));
        try inputs.append(arena, .{ .name = entry[0], .mesh = entry[1], .tiles = tiles });
    }
    for ([_]struct { []const u8, *meshes.Mesh }{
        .{ "terrain 256 m, 64 m tiles", &terrain },
        .{ "vale 256 m, 64 m tiles", &vale },
    }) |entry| {
        var bmin: [3]f32 = undefined;
        var bmax: [3]f32 = undefined;
        recast.calcBounds(entry[1].verts, &bmin, &bmax);
        const tiles_x: usize = @intFromFloat(@ceil((bmax[0] - bmin[0]) / tile_size));
        const tiles_z: usize = @intFromFloat(@ceil((bmax[2] - bmin[2]) / tile_size));
        const tiles = try arena.alloc(Tile, tiles_x * tiles_z);
        for (tiles, 0..) |*tile, t| {
            const tx: i32 = @intCast(t % tiles_x);
            const tz: i32 = @intCast(t / tiles_x);
            tile.* = try tileOf(arena, entry[1], tileConfig(bmin, bmax, tx, tz));
        }
        try inputs.append(arena, .{ .name = entry[0], .mesh = entry[1], .tiles = tiles });
    }

    const original_runs = try arena.alloc(Times, runs);
    const port_runs = try arena.alloc(Times, runs);
    for (inputs.items) |*input| {
        if (std.mem.find(u8, input.name, only) == null) continue;
        const original_built = try arena.alloc(OriginalMeshes, input.tiles.len);
        const port_built = try arena.alloc(PortMeshes, input.tiles.len);
        for (0..warmups + runs) |run| {
            var original: Times = @splat(null);
            var port: Times = @splat(null);
            var work: Work = @splat(0);
            for (input.tiles, original_built, port_built) |*tile, *o, *p| {
                o.* = try buildOriginal(io, log, input.mesh.verts, tile, &original);
                p.* = try buildPort(io, gpa, input.mesh.verts, tile, &port, &work);
            }
            try wholeOriginal(io, log, input.mesh, original_built, &original);
            try wholePort(io, gpa, input.mesh, port_built, &port);
            for (original_built, port_built) |o, *p| {
                upstream.shim_polymesh_free(o.pmesh);
                upstream.shim_detail_free(o.dmesh);
                p.pmesh.deinit(gpa);
                p.dmesh.deinit(gpa);
            }
            for ([_]*Times{ &original, &port }) |times| {
                var total: u64 = 0;
                for (pipeline) |f| total +|= times[@backingInt(f)].?;
                times[@backingInt(Feature.whole_build)] = total;
            }
            work[@backingInt(Per.vertices)] = input.mesh.verts.len / 3;
            input.work = work;
            if (run < warmups) continue;
            original_runs[run - warmups] = original;
            port_runs[run - warmups] = port;
        }
        for (0..feature_count) |f| {
            input.original[f] = try Summary.of(arena, original_runs, f);
            input.port[f] = try Summary.of(arena, port_runs, f);
        }
    }

    std.debug.print(
        "Median of {d} runs after {d} warm-up, one thread, Zig {s}, {s}.\n",
        .{ runs, warmups, builtin.zig_version_string, builtin.cpu.model.name },
    );
    // The whole build first, then each feature; the whole build is the
    // last of them.
    for (0..feature_count) |f| {
        const feature: Feature = if (f == 0) .whole_build else @fromBackingInt(@intCast(f - 1));
        const about = info(feature);
        std.debug.print("\n### {s}\n\n", .{about.title});
        if (feature == .whole_build) {
            std.debug.print("Every step of a navmesh build, in Loomwork's order", .{});
        } else {
            std.debug.print("`{s}` and `{s}`", .{ about.original, about.port });
        }
        if (about.calls > 0) std.debug.print(", per call", .{});
        std.debug.print(".\n\n" ++ table_head, .{});
        for (inputs.items) |*input| {
            const original = input.original[@backingInt(feature)] orelse continue;
            const port = input.port[@backingInt(feature)] orelse continue;
            const amount = if (about.calls > 0) about.calls else input.work[@backingInt(about.per)];
            printRow(input.name, about, amount, original, port);
        }
    }
}
