//! Times the port against the original, both built ReleaseFast, step by
//! step: a solo build of each RecastDemo mesh and of a large terrain with
//! RecastDemo's defaults, and the terrain in tiles with Loomwork's navmesh
//! settings. Each figure is the best of several runs, on one thread.
//!
//!   zig build bench -- [runs]

const std = @import("std");
const recast = @import("recast");
const upstream = @import("upstream");
const meshes = @import("meshes");

const Step = enum {
    rasterize,
    filters,
    compact,
    erode,
    distance,
    regions,
    contours,
    polymesh,
    detail,
};

const step_count = @typeInfo(Step).@"enum".fields.len;

/// Nanoseconds per step.
const Times = [step_count]u64;

const Lap = struct {
    io: std.Io,
    start: std.Io.Timestamp,
    times: *Times,

    fn begin(io: std.Io, times: *Times) Lap {
        return .{ .io = io, .start = std.Io.Clock.awake.now(io), .times = times };
    }

    fn end(lap: *Lap, step: Step) void {
        const now = std.Io.Clock.awake.now(lap.io);
        lap.times[@backingInt(step)] += @intCast(lap.start.durationTo(now).nanoseconds);
        lap.start = now;
    }
};

/// The settings of one build: RecastDemo's solo defaults, or Loomwork's
/// tile settings.
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

const tile_size: f32 = 12.0;

fn tileConfig(bmin: [3]f32, bmax: [3]f32, tx: i32, tz: i32) recast.Config {
    var cfg = soloConfig(bmin, bmax);
    cfg.max_edge_len = @intFromFloat(12.0 / cfg.cs);
    cfg.min_region_area = @intFromFloat((2.4 / cfg.cs) * (2.4 / cfg.cs));
    cfg.merge_region_area = @intFromFloat((6.0 / cfg.cs) * (6.0 / cfg.cs));
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

fn buildPort(
    io: std.Io,
    gpa: std.mem.Allocator,
    verts: []const f32,
    tris: []const i32,
    cfg: *const recast.Config,
    times: *Times,
) !void {
    const ctx: recast.Context = .none;
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
    const areas = try gpa.alloc(u8, tris.len / 3);
    defer gpa.free(areas);
    @memset(areas, 0);
    recast.markWalkableTriangles(ctx, cfg.walkable_slope_angle, verts, tris, areas);
    try recast.rasterizeTriangles(ctx, gpa, verts, i32, tris, areas, &hf, cfg.walkable_climb);
    lap.end(.rasterize);
    recast.filterLowHangingWalkableObstacles(ctx, cfg.walkable_climb, &hf);
    recast.filterLedgeSpans(ctx, cfg.walkable_height, cfg.walkable_climb, &hf);
    recast.filterWalkableLowHeightSpans(ctx, cfg.walkable_height, &hf);
    lap.end(.filters);
    var chf = try recast.buildCompactHeightfield(
        ctx,
        gpa,
        cfg.walkable_height,
        cfg.walkable_climb,
        &hf,
    );
    defer chf.deinit(gpa);
    lap.end(.compact);
    try recast.erodeWalkableArea(ctx, gpa, cfg.walkable_radius, &chf);
    lap.end(.erode);
    try recast.buildDistanceField(ctx, gpa, &chf);
    lap.end(.distance);
    try recast.buildRegions(
        ctx,
        gpa,
        &chf,
        cfg.border_size,
        cfg.min_region_area,
        cfg.merge_region_area,
    );
    lap.end(.regions);
    var cset = try recast.buildContours(
        ctx,
        gpa,
        &chf,
        cfg.max_simplification_error,
        cfg.max_edge_len,
        .default,
    );
    defer cset.deinit(gpa);
    lap.end(.contours);
    var pmesh = try recast.buildPolyMesh(ctx, gpa, &cset, cfg.max_verts_per_poly);
    defer pmesh.deinit(gpa);
    lap.end(.polymesh);
    var dmesh = try recast.buildPolyMeshDetail(
        ctx,
        gpa,
        &pmesh,
        &chf,
        cfg.detail_sample_dist,
        cfg.detail_sample_max_error,
    );
    defer dmesh.deinit(gpa);
    lap.end(.detail);
}

fn buildOriginal(
    io: std.Io,
    log: *upstream.Log,
    verts: []const f32,
    tris: []const i32,
    cfg: *const recast.Config,
    times: *Times,
) !void {
    const nv: c_int = @intCast(verts.len / 3);
    const nt: c_int = @intCast(tris.len / 3);
    var lap: Lap = .begin(io, times);
    const hf = upstream.shim_hf_create(
        log,
        cfg.width,
        cfg.height,
        &cfg.bmin,
        &cfg.bmax,
        cfg.cs,
        cfg.ch,
    ) orelse return error.OutOfMemory;
    defer upstream.shim_hf_free(hf);
    const areas = try std.heap.c_allocator.alloc(u8, tris.len / 3);
    defer std.heap.c_allocator.free(areas);
    @memset(areas, 0);
    const slope = cfg.walkable_slope_angle;
    upstream.shim_mark_walkable(log, slope, verts.ptr, nv, tris.ptr, nt, areas.ptr);
    _ = upstream.shim_rasterize_triangles(
        log,
        verts.ptr,
        nv,
        tris.ptr,
        areas.ptr,
        nt,
        hf,
        cfg.walkable_climb,
    );
    lap.end(.rasterize);
    upstream.shim_filter_low_hanging(log, cfg.walkable_climb, hf);
    upstream.shim_filter_ledge(log, cfg.walkable_height, cfg.walkable_climb, hf);
    upstream.shim_filter_low_height(log, cfg.walkable_height, hf);
    lap.end(.filters);
    const chf = upstream.shim_chf_build(log, cfg.walkable_height, cfg.walkable_climb, hf) orelse
        return error.OutOfMemory;
    defer upstream.shim_chf_free(chf);
    lap.end(.compact);
    _ = upstream.shim_erode(log, cfg.walkable_radius, chf);
    lap.end(.erode);
    _ = upstream.shim_distance_field(log, chf);
    lap.end(.distance);
    const border = cfg.border_size;
    _ = upstream.shim_regions(log, chf, border, cfg.min_region_area, cfg.merge_region_area);
    lap.end(.regions);
    const cset = upstream.shim_contours_build(
        log,
        chf,
        cfg.max_simplification_error,
        cfg.max_edge_len,
        1,
    ) orelse return error.OutOfMemory;
    defer upstream.shim_contours_free(cset);
    lap.end(.contours);
    const pmesh = upstream.shim_polymesh_build(log, cset, cfg.max_verts_per_poly) orelse
        return error.OutOfMemory;
    defer upstream.shim_polymesh_free(pmesh);
    lap.end(.polymesh);
    const dmesh = upstream.shim_detail_build(
        log,
        pmesh,
        chf,
        cfg.detail_sample_dist,
        cfg.detail_sample_max_error,
    ) orelse return error.OutOfMemory;
    defer upstream.shim_detail_free(dmesh);
    lap.end(.detail);
}

/// One build of the bench: solo, or every tile of the terrain.
const Build = struct {
    name: []const u8,
    mesh: *const meshes.Mesh,
    /// The builds' settings, one per tile, with each tile's triangles.
    cfgs: []recast.Config,
    tris: [][]i32,
};

fn report(name: []const u8, original: *const Times, port: *const Times) void {
    var original_total: u64 = 0;
    var port_total: u64 = 0;
    std.debug.print("\n{s}\n  {s:<10} {s:>12} {s:>12} {s:>8}\n", .{
        name,
        "step",
        "original ms",
        "port ms",
        "ratio",
    });
    for (original, port, 0..) |o, p, i| {
        original_total += o;
        port_total += p;
        std.debug.print("  {s:<10} {d:>12.3} {d:>12.3} {d:>8.3}\n", .{
            @tagName(@as(Step, @fromBackingInt(@intCast(i)))),
            ms(o),
            ms(p),
            ms(p) / ms(o),
        });
    }
    std.debug.print("  {s:<10} {d:>12.3} {d:>12.3} {d:>8.3}\n", .{
        "total",
        ms(original_total),
        ms(port_total),
        ms(port_total) / ms(original_total),
    });
}

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const gpa = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(arena);
    const runs: usize = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 5;

    const log = upstream.shim_log_create() orelse return error.OutOfMemory;
    defer upstream.shim_log_destroy(log);
    upstream.shim_log_enable(log, 0, 0);

    var dungeon = try meshes.loadObj(arena, @embedFile("dungeon"));
    var nav_test = try meshes.loadObj(arena, @embedFile("nav_test"));
    var undulating = try meshes.loadObj(arena, @embedFile("undulating"));
    var terrain = try meshes.terrain(arena, 256, 1);

    var builds: std.ArrayList(Build) = .empty;
    for ([_]struct { []const u8, *meshes.Mesh }{
        .{ "dungeon.obj, solo", &dungeon },
        .{ "nav_test.obj, solo", &nav_test },
        .{ "undulating.obj, solo", &undulating },
        .{ "terrain 256 m, solo", &terrain },
    }) |entry| {
        var bmin: [3]f32 = undefined;
        var bmax: [3]f32 = undefined;
        recast.calcBounds(entry[1].verts, &bmin, &bmax);
        const cfgs = try arena.alloc(recast.Config, 1);
        cfgs[0] = soloConfig(bmin, bmax);
        const tris = try arena.alloc([]i32, 1);
        tris[0] = entry[1].tris;
        try builds.append(arena, .{
            .name = entry[0],
            .mesh = entry[1],
            .cfgs = cfgs,
            .tris = tris,
        });
    }
    {
        var bmin: [3]f32 = undefined;
        var bmax: [3]f32 = undefined;
        recast.calcBounds(terrain.verts, &bmin, &bmax);
        const tiles_x: usize = @intFromFloat(@ceil((bmax[0] - bmin[0]) / tile_size));
        const tiles_z: usize = @intFromFloat(@ceil((bmax[2] - bmin[2]) / tile_size));
        const cfgs = try arena.alloc(recast.Config, tiles_x * tiles_z);
        const tris = try arena.alloc([]i32, cfgs.len);
        for (cfgs, tris, 0..) |*cfg, *t, i| {
            cfg.* = tileConfig(bmin, bmax, @intCast(i % tiles_x), @intCast(i / tiles_x));
            t.* = try cull(arena, &terrain, cfg);
        }
        try builds.append(arena, .{
            .name = "terrain 256 m, 12 m tiles (Loomwork's settings)",
            .mesh = &terrain,
            .cfgs = cfgs,
            .tris = tris,
        });
    }

    std.debug.print("best of {d} runs, one thread\n", .{runs});
    for (builds.items) |build| {
        var original_best: Times = @splat(std.math.maxInt(u64));
        var port_best: Times = @splat(std.math.maxInt(u64));
        for (0..runs) |_| {
            var original: Times = @splat(0);
            var port: Times = @splat(0);
            for (build.cfgs, build.tris) |*cfg, tris| {
                try buildOriginal(io, log, build.mesh.verts, tris, cfg, &original);
                try buildPort(io, gpa, build.mesh.verts, tris, cfg, &port);
            }
            for (&original_best, original) |*best, t| best.* = @min(best.*, t);
            for (&port_best, port) |*best, t| best.* = @min(best.*, t);
        }
        report(build.name, &original_best, &port_best);
    }
}
