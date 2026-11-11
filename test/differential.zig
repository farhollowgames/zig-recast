//! Differential tests: the port and the original Recast, built from source,
//! run on the same inputs, and every structure they build, every log
//! message and every timer call must be the same, byte for byte.

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const std = @import("std");
const recast = @import("recast");
const upstream = @import("upstream.zig");
const meshes = @import("meshes.zig");
const dump = @import("dump.zig").dump;

const testing = std.testing;
const gpa = testing.allocator;
const Allocator = std.mem.Allocator;

const oracle = @import("oracle.zig");
const Recorder = oracle.Recorder;
const Logs = oracle.Logs;
const expectSameDump = oracle.expectSameDump;
const sameOutcome = oracle.sameOutcome;
const succeeded = oracle.succeeded;

test {
    _ = @import("fuzz.zig");
    _ = @import("edges.zig");
    _ = @import("upstream_tests.zig");
}

fn loadMesh(source: meshes.Source) !meshes.Mesh {
    return switch (source) {
        .dungeon => meshes.loadObj(gpa, @embedFile("dungeon")),
        .nav_test => meshes.loadObj(gpa, @embedFile("nav_test")),
        .undulating => meshes.loadObj(gpa, @embedFile("undulating")),
        .terrain => meshes.terrain(gpa, 72, 1),
    };
}

const Partition = enum { watershed, monotone, layers };

/// RecastDemo's build settings, with its defaults.
const Settings = struct {
    cell_size: f32 = 0.3,
    cell_height: f32 = 0.2,
    agent_height: f32 = 2.0,
    agent_radius: f32 = 0.6,
    agent_max_climb: f32 = 0.9,
    agent_max_slope: f32 = 45.0,
    region_min_size: f32 = 8,
    region_merge_size: f32 = 20,
    edge_max_len: f32 = 12.0,
    edge_max_error: f32 = 1.3,
    verts_per_poly: i32 = 6,
    detail_sample_dist: f32 = 6.0,
    detail_sample_max_error: f32 = 1.0,
    partition: Partition = .watershed,
    filter_low_hanging_obstacles: bool = true,
    filter_ledge_spans: bool = true,
    filter_walkable_low_height_spans: bool = true,
    contour_flags: recast.ContourBuildFlags = .default,
    /// Also runs the median filter and marks a box, a cylinder and a convex
    /// volume, as RecastDemo's tools can.
    mark_areas: bool = false,
};

/// The configuration RecastDemo's solo mesh sample makes from its settings.
fn soloConfig(s: Settings, bmin: [3]f32, bmax: [3]f32) recast.Config {
    var cfg: recast.Config = .{
        .cs = s.cell_size,
        .ch = s.cell_height,
        .walkable_slope_angle = s.agent_max_slope,
        .walkable_height = @intFromFloat(@ceil(s.agent_height / s.cell_height)),
        .walkable_climb = @intFromFloat(@floor(s.agent_max_climb / s.cell_height)),
        .walkable_radius = @intFromFloat(@ceil(s.agent_radius / s.cell_size)),
        .max_edge_len = @intFromFloat(s.edge_max_len / s.cell_size),
        .max_simplification_error = s.edge_max_error,
        .min_region_area = @intFromFloat(s.region_min_size * s.region_min_size),
        .merge_region_area = @intFromFloat(s.region_merge_size * s.region_merge_size),
        .max_verts_per_poly = s.verts_per_poly,
        .detail_sample_dist = if (s.detail_sample_dist < 0.9)
            0
        else
            s.cell_size * s.detail_sample_dist,
        .detail_sample_max_error = s.cell_height * s.detail_sample_max_error,
        .bmin = bmin,
        .bmax = bmax,
    };
    const grid = recast.calcGridSize(&bmin, &bmax, cfg.cs);
    cfg.width = grid.width;
    cfg.height = grid.height;
    return cfg;
}

/// Both sides' compact heightfields, built from a mesh up to erosion, with
/// every step compared on the way.
const Compact = struct {
    logs: Logs,
    cfg: recast.Config,
    chf: recast.CompactHeightfield,
    original: *upstream.CompactHeightfield,

    fn deinit(c: *Compact) void {
        c.chf.deinit(gpa);
        upstream.shim_chf_free(c.original);
        c.logs.deinit();
    }
};

fn buildCompact(mesh: *const meshes.Mesh, s: Settings) !Compact {
    var logs = try Logs.init();
    errdefer logs.deinit();
    const ctx = logs.port();
    const log = logs.original;
    const nv = mesh.vertCount();
    const nt = mesh.triCount();

    var bmin: [3]f32 = undefined;
    var bmax: [3]f32 = undefined;
    recast.calcBounds(mesh.verts, &bmin, &bmax);
    var original_bmin: [3]f32 = undefined;
    var original_bmax: [3]f32 = undefined;
    upstream.shim_calc_bounds(mesh.verts.ptr, nv, &original_bmin, &original_bmax);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&original_bmin), std.mem.asBytes(&bmin));
    try testing.expectEqualSlices(u8, std.mem.asBytes(&original_bmax), std.mem.asBytes(&bmax));

    const cfg = soloConfig(s, bmin, bmax);
    var width: c_int = 0;
    var height: c_int = 0;
    upstream.shim_calc_grid_size(&bmin, &bmax, cfg.cs, &width, &height);
    try testing.expectEqual(width, cfg.width);
    try testing.expectEqual(height, cfg.height);

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
    const original_hf = upstream.shim_hf_create(
        log,
        cfg.width,
        cfg.height,
        &cfg.bmin,
        &cfg.bmax,
        cfg.cs,
        cfg.ch,
    ) orelse return error.OutOfMemory;
    defer upstream.shim_hf_free(original_hf);

    const areas = try gpa.alloc(u8, @intCast(nt));
    defer gpa.free(areas);
    @memset(areas, 0);
    const original_areas = try gpa.alloc(u8, @intCast(nt));
    defer gpa.free(original_areas);
    @memset(original_areas, 0);
    recast.markWalkableTriangles(ctx, cfg.walkable_slope_angle, mesh.verts, mesh.tris, areas);
    upstream.shim_mark_walkable(
        log,
        cfg.walkable_slope_angle,
        mesh.verts.ptr,
        nv,
        mesh.tris.ptr,
        nt,
        original_areas.ptr,
    );
    try testing.expectEqualSlices(u8, original_areas, areas);

    const rasterized = recast.rasterizeTriangles(
        ctx,
        gpa,
        mesh.verts,
        i32,
        mesh.tris,
        areas,
        &hf,
        cfg.walkable_climb,
    );
    const original_rasterized = upstream.shim_rasterize_triangles(
        log,
        mesh.verts.ptr,
        nv,
        mesh.tris.ptr,
        areas.ptr,
        nt,
        original_hf,
        cfg.walkable_climb,
    );
    _ = try sameOutcome(&logs, "rasterize", succeeded(rasterized), original_rasterized != 0);
    try expectSameDump("rasterize", &hf, original_hf);

    if (s.filter_low_hanging_obstacles) {
        recast.filterLowHangingWalkableObstacles(ctx, cfg.walkable_climb, &hf);
        upstream.shim_filter_low_hanging(log, cfg.walkable_climb, original_hf);
        try logs.expectSame("filter low hanging obstacles");
        try expectSameDump("filter low hanging obstacles", &hf, original_hf);
    }
    if (s.filter_ledge_spans) {
        recast.filterLedgeSpans(ctx, cfg.walkable_height, cfg.walkable_climb, &hf);
        upstream.shim_filter_ledge(log, cfg.walkable_height, cfg.walkable_climb, original_hf);
        try logs.expectSame("filter ledge spans");
        try expectSameDump("filter ledge spans", &hf, original_hf);
    }
    if (s.filter_walkable_low_height_spans) {
        recast.filterWalkableLowHeightSpans(ctx, cfg.walkable_height, &hf);
        upstream.shim_filter_low_height(log, cfg.walkable_height, original_hf);
        try logs.expectSame("filter low height spans");
        try expectSameDump("filter low height spans", &hf, original_hf);
    }
    try testing.expectEqual(
        upstream.shim_hf_span_count(log, original_hf),
        recast.getHeightFieldSpanCount(ctx, &hf),
    );

    var chf = try recast.buildCompactHeightfield(
        ctx,
        gpa,
        cfg.walkable_height,
        cfg.walkable_climb,
        &hf,
    );
    errdefer chf.deinit(gpa);
    const original_chf = upstream.shim_chf_build(
        log,
        cfg.walkable_height,
        cfg.walkable_climb,
        original_hf,
    ) orelse return error.TestUnexpectedResult;
    errdefer upstream.shim_chf_free(original_chf);
    try logs.expectSame("compact");
    try expectSameDump("compact", &chf, original_chf);

    const eroded = recast.erodeWalkableArea(ctx, gpa, cfg.walkable_radius, &chf);
    const original_eroded = upstream.shim_erode(log, cfg.walkable_radius, original_chf);
    _ = try sameOutcome(&logs, "erode", succeeded(eroded), original_eroded != 0);
    try expectSameDump("erode", &chf, original_chf);

    if (s.mark_areas) {
        const median = recast.medianFilterWalkableArea(ctx, gpa, &chf);
        const original_median = upstream.shim_median(log, original_chf);
        _ = try sameOutcome(&logs, "median", succeeded(median), original_median != 0);
        try expectSameDump("median", &chf, original_chf);
        try markVolumes(&logs, &chf, original_chf, bmin, bmax);
    }
    return .{ .logs = logs, .cfg = cfg, .chf = chf, .original = original_chf };
}

/// Marks a box, a cylinder and a convex volume placed by the bounds, as
/// RecastDemo's tools do.
fn markVolumes(
    logs: *Logs,
    chf: *recast.CompactHeightfield,
    original: *upstream.CompactHeightfield,
    bmin: [3]f32,
    bmax: [3]f32,
) !void {
    const ctx = logs.port();
    var size: [3]f32 = undefined;
    for (&size, bmin, bmax) |*d, lo, hi| d.* = hi - lo;
    const box_min: [3]f32 = .{ bmin[0] + size[0] * 0.2, bmin[1], bmin[2] + size[2] * 0.3 };
    const box_max: [3]f32 = .{ bmin[0] + size[0] * 0.45, bmax[1], bmin[2] + size[2] * 0.5 };
    recast.markBoxArea(ctx, &box_min, &box_max, 7, chf);
    upstream.shim_mark_box(logs.original, &box_min, &box_max, 7, original);
    try logs.expectSame("mark box");
    try expectSameDump("mark box", chf, original);

    const center: [3]f32 = .{ bmin[0] + size[0] * 0.6, bmin[1], bmin[2] + size[2] * 0.6 };
    const radius = size[0] * 0.12;
    recast.markCylinderArea(ctx, &center, radius, size[1], 12, chf);
    upstream.shim_mark_cylinder(logs.original, &center, radius, size[1], 12, original);
    try logs.expectSame("mark cylinder");
    try expectSameDump("mark cylinder", chf, original);

    var poly: [6 * 3]f32 = undefined;
    for (0..6) |i| {
        const angle = @as(f32, @floatFromInt(i)) * (std.math.tau / 6.0);
        poly[i * 3 + 0] = bmin[0] + size[0] * (0.3 + 0.15 * @cos(angle));
        poly[i * 3 + 1] = bmin[1];
        poly[i * 3 + 2] = bmin[2] + size[2] * (0.75 + 0.15 * @sin(angle));
    }
    const min_y = bmin[1] - 1.0;
    const max_y = bmin[1] + size[1] * 0.5;
    recast.markConvexPolyArea(ctx, &poly, min_y, max_y, 21, chf);
    upstream.shim_mark_convex(logs.original, &poly, 6, min_y, max_y, 21, original);
    try logs.expectSame("mark convex");
    try expectSameDump("mark convex", chf, original);
}

/// Builds a whole navmesh both ways, as RecastDemo's solo mesh sample does,
/// and compares every step.
fn expectSamePipeline(mesh: *const meshes.Mesh, s: Settings) !void {
    var compact = try buildCompact(mesh, s);
    defer compact.deinit();
    const logs = &compact.logs;
    const ctx = logs.port();
    const log = logs.original;
    const cfg = compact.cfg;
    const chf = &compact.chf;
    const original_chf = compact.original;

    layers: {
        const original = upstream.shim_layers_build(log, original_chf, 0, cfg.walkable_height);
        defer if (original) |o| upstream.shim_layers_free(o);
        const result = recast.buildHeightfieldLayers(ctx, gpa, chf, 0, cfg.walkable_height);
        var lset = result catch |err| {
            if (err == error.OutOfMemory) return err;
            _ = try sameOutcome(logs, "layers", false, original != null);
            break :layers;
        };
        defer lset.deinit(gpa);
        _ = try sameOutcome(logs, "layers", true, original != null);
        try expectSameDump("layers", &lset, original.?);
    }

    switch (s.partition) {
        .watershed => {
            const field = recast.buildDistanceField(ctx, gpa, chf);
            const original_field = upstream.shim_distance_field(log, original_chf);
            if (!try sameOutcome(logs, "distance", succeeded(field), original_field != 0)) return;
            try expectSameDump("distance", chf, original_chf);
            const regions = recast.buildRegions(
                ctx,
                gpa,
                chf,
                0,
                cfg.min_region_area,
                cfg.merge_region_area,
            );
            const original_regions = upstream.shim_regions(
                log,
                original_chf,
                0,
                cfg.min_region_area,
                cfg.merge_region_area,
            );
            if (!try sameOutcome(logs, "regions", succeeded(regions), original_regions != 0)) {
                return;
            }
        },
        .monotone => {
            const regions = recast.buildRegionsMonotone(
                ctx,
                gpa,
                chf,
                0,
                cfg.min_region_area,
                cfg.merge_region_area,
            );
            const original_regions = upstream.shim_regions_monotone(
                log,
                original_chf,
                0,
                cfg.min_region_area,
                cfg.merge_region_area,
            );
            if (!try sameOutcome(logs, "regions", succeeded(regions), original_regions != 0)) {
                return;
            }
        },
        .layers => {
            const regions = recast.buildLayerRegions(ctx, gpa, chf, 0, cfg.min_region_area);
            const original_regions = upstream.shim_layer_regions(
                log,
                original_chf,
                0,
                cfg.min_region_area,
            );
            if (!try sameOutcome(logs, "regions", succeeded(regions), original_regions != 0)) {
                return;
            }
        },
    }
    try expectSameDump("regions", chf, original_chf);

    const flags: c_int = @bitCast(s.contour_flags);
    const original_cset = upstream.shim_contours_build(
        log,
        original_chf,
        cfg.max_simplification_error,
        cfg.max_edge_len,
        flags,
    );
    defer if (original_cset) |o| upstream.shim_contours_free(o);
    var cset = recast.buildContours(
        ctx,
        gpa,
        chf,
        cfg.max_simplification_error,
        cfg.max_edge_len,
        s.contour_flags,
    ) catch |err| {
        if (err == error.OutOfMemory) return err;
        _ = try sameOutcome(logs, "contours", false, original_cset != null);
        return;
    };
    defer cset.deinit(gpa);
    _ = try sameOutcome(logs, "contours", true, original_cset != null);
    try expectSameDump("contours", &cset, original_cset.?);

    const original_pmesh = upstream.shim_polymesh_build(
        log,
        original_cset.?,
        cfg.max_verts_per_poly,
    );
    defer if (original_pmesh) |o| upstream.shim_polymesh_free(o);
    var pmesh = recast.buildPolyMesh(ctx, gpa, &cset, cfg.max_verts_per_poly) catch |err| {
        if (err == error.OutOfMemory) return err;
        _ = try sameOutcome(logs, "polymesh", false, original_pmesh != null);
        return;
    };
    defer pmesh.deinit(gpa);
    _ = try sameOutcome(logs, "polymesh", true, original_pmesh != null);
    try expectSameDump("polymesh", &pmesh, original_pmesh.?);

    {
        const original_copy = upstream.shim_polymesh_copy(log, original_pmesh.?);
        defer if (original_copy) |o| upstream.shim_polymesh_free(o);
        var copy = try recast.copyPolyMesh(ctx, gpa, &pmesh);
        defer copy.deinit(gpa);
        _ = try sameOutcome(logs, "copy polymesh", true, original_copy != null);
        try expectSameDump("copy polymesh", &copy, original_copy.?);
    }

    const original_dmesh = upstream.shim_detail_build(
        log,
        original_pmesh.?,
        original_chf,
        cfg.detail_sample_dist,
        cfg.detail_sample_max_error,
    );
    defer if (original_dmesh) |o| upstream.shim_detail_free(o);
    var dmesh = recast.buildPolyMeshDetail(
        ctx,
        gpa,
        &pmesh,
        chf,
        cfg.detail_sample_dist,
        cfg.detail_sample_max_error,
    ) catch |err| {
        if (err == error.OutOfMemory) return err;
        _ = try sameOutcome(logs, "detail", false, original_dmesh != null);
        return;
    };
    defer dmesh.deinit(gpa);
    _ = try sameOutcome(logs, "detail", true, original_dmesh != null);
    try expectSameDump("detail", &dmesh, original_dmesh.?);
}

const all_sources = [_]meshes.Source{ .dungeon, .nav_test, .undulating, .terrain };

test "RecastDemo's defaults build the same navmesh on every mesh and partition" {
    for (all_sources) |source| {
        var mesh = try loadMesh(source);
        defer mesh.deinit(gpa);
        for ([_]Partition{ .watershed, .monotone, .layers }) |partition| {
            expectSamePipeline(&mesh, .{ .partition = partition, .mark_areas = true }) catch |err| {
                std.debug.print("mesh {t}, partition {t}\n", .{ source, partition });
                return err;
            };
        }
    }
}

test "other settings build the same navmesh" {
    const variants = [_]Settings{
        .{ .cell_size = 0.15, .cell_height = 0.1, .detail_sample_dist = 2 },
        .{ .cell_size = 0.5, .cell_height = 0.3, .agent_radius = 0, .verts_per_poly = 3 },
        .{ .agent_max_slope = 60, .agent_max_climb = 1.8, .verts_per_poly = 12 },
        .{ .region_min_size = 0, .region_merge_size = 0, .edge_max_len = 0 },
        .{ .region_min_size = 30, .region_merge_size = 100, .edge_max_error = 3.0 },
        .{ .edge_max_error = 0.0, .detail_sample_max_error = 0.0, .verts_per_poly = 4 },
        .{
            .contour_flags = .{ .tess_wall_edges = true, .tess_area_edges = true },
            .mark_areas = true,
        },
        .{ .contour_flags = .{}, .partition = .monotone, .mark_areas = true },
        .{
            .contour_flags = .{ .tess_area_edges = true },
            .partition = .layers,
            .mark_areas = true,
        },
        .{
            .filter_low_hanging_obstacles = false,
            .filter_ledge_spans = false,
            .filter_walkable_low_height_spans = false,
            .detail_sample_dist = 1.0,
        },
        .{ .agent_height = 0.2, .agent_max_climb = 0, .agent_max_slope = 89.9 },
        .{ .agent_radius = 2.0, .detail_sample_dist = 20.0, .detail_sample_max_error = 5.0 },
    };
    for ([_]meshes.Source{ .nav_test, .terrain }) |source| {
        var mesh = try loadMesh(source);
        defer mesh.deinit(gpa);
        for (variants, 0..) |settings, i| {
            expectSamePipeline(&mesh, settings) catch |err| {
                std.debug.print("mesh {t}, variant {d}\n", .{ source, i });
                return err;
            };
        }
    }
}

test "regions build the same with borders and area limits" {
    var mesh = try loadMesh(.dungeon);
    defer mesh.deinit(gpa);
    for ([_]i32{ 0, 3, 12 }) |border| {
        for ([_][2]i32{ .{ 0, 0 }, .{ 64, 400 }, .{ 1000, 5 } }) |limits| {
            for ([_]Partition{ .watershed, .monotone, .layers }) |partition| {
                var compact = try buildCompact(&mesh, .{});
                defer compact.deinit();
                const logs = &compact.logs;
                const ctx = logs.port();
                const chf = &compact.chf;
                const original = compact.original;
                const log = logs.original;
                const min_area = limits[0];
                const merge_area = limits[1];
                const port_ok, const original_ok = switch (partition) {
                    .watershed => step: {
                        try recast.buildDistanceField(ctx, gpa, chf);
                        try testing.expect(upstream.shim_distance_field(log, original) != 0);
                        const port = recast.buildRegions(
                            ctx,
                            gpa,
                            chf,
                            border,
                            min_area,
                            merge_area,
                        );
                        const original_ok =
                            upstream.shim_regions(log, original, border, min_area, merge_area);
                        break :step .{ succeeded(port), original_ok != 0 };
                    },
                    .monotone => step: {
                        const port = recast.buildRegionsMonotone(
                            ctx,
                            gpa,
                            chf,
                            border,
                            min_area,
                            merge_area,
                        );
                        const original_ok = upstream.shim_regions_monotone(
                            log,
                            original,
                            border,
                            min_area,
                            merge_area,
                        );
                        break :step .{ succeeded(port), original_ok != 0 };
                    },
                    .layers => .{
                        succeeded(recast.buildLayerRegions(ctx, gpa, chf, border, min_area)),
                        upstream.shim_layer_regions(log, original, border, min_area) != 0,
                    },
                };
                _ = try sameOutcome(logs, "regions", port_ok, original_ok);
                try expectSameDump("regions", chf, original);
            }
        }
    }
}

test "heightfield layers build the same with borders" {
    for ([_]meshes.Source{ .dungeon, .terrain }) |source| {
        var mesh = try loadMesh(source);
        defer mesh.deinit(gpa);
        var compact = try buildCompact(&mesh, .{});
        defer compact.deinit();
        const logs = &compact.logs;
        for ([_]i32{ 0, 4, 9 }) |border| {
            for ([_]i32{ compact.cfg.walkable_height, 1, 40 }) |walkable_height| {
                const original = upstream.shim_layers_build(
                    logs.original,
                    compact.original,
                    border,
                    walkable_height,
                );
                defer if (original) |o| upstream.shim_layers_free(o);
                const result = recast.buildHeightfieldLayers(
                    logs.port(),
                    gpa,
                    &compact.chf,
                    border,
                    walkable_height,
                );
                if (result) |lset_const| {
                    var lset = lset_const;
                    defer lset.deinit(gpa);
                    _ = try sameOutcome(logs, "layers", true, original != null);
                    try expectSameDump("layers", &lset, original.?);
                } else |err| {
                    if (err == error.OutOfMemory) return err;
                    _ = try sameOutcome(logs, "layers", false, original != null);
                }
            }
        }
    }
}

test "erosion of every radius matches" {
    var mesh = try loadMesh(.undulating);
    defer mesh.deinit(gpa);
    for ([_]i32{ 0, 1, 2, 5, 127, 128, 129, 200, 300 }) |radius| {
        var compact = try buildCompact(&mesh, .{ .agent_radius = 0 });
        defer compact.deinit();
        const logs = &compact.logs;
        try recast.erodeWalkableArea(logs.port(), gpa, radius, &compact.chf);
        try testing.expect(upstream.shim_erode(logs.original, radius, compact.original) != 0);
        try logs.expectSame("erode");
        try expectSameDump("erode", &compact.chf, compact.original);
    }
}

test "area marks match inside, across and outside the field" {
    var mesh = try loadMesh(.nav_test);
    defer mesh.deinit(gpa);
    var compact = try buildCompact(&mesh, .{});
    defer compact.deinit();
    const logs = &compact.logs;
    const ctx = logs.port();
    const chf = &compact.chf;
    const original = compact.original;
    const lo = chf.bmin;
    const hi = chf.bmax;
    const nan = std.math.nan(f32);
    const huge: f32 = 1e30;
    const boxes = [_][2][3]f32{
        .{ lo, hi },
        .{ .{ lo[0] - 5, lo[1], lo[2] - 5 }, .{ lo[0] + 3, hi[1], lo[2] + 4 } },
        .{ .{ hi[0] - 2, lo[1] + 1, hi[2] - 2 }, .{ hi[0] + 9, lo[1] + 2, hi[2] + 9 } },
        .{ .{ hi[0] + 1, lo[1], lo[2] }, .{ hi[0] + 2, hi[1], hi[2] } },
        .{ .{ lo[0], lo[1], lo[2] - 3 }, .{ hi[0], hi[1], lo[2] - 1 } },
        .{ .{ lo[0] + 4, hi[1], lo[2] + 4 }, .{ lo[0] + 2, lo[1], lo[2] + 2 } },
        .{ .{ -huge, -huge, -huge }, .{ huge, huge, huge } },
        .{ .{ nan, lo[1], lo[2] }, .{ hi[0], hi[1], nan } },
    };
    for (boxes, 0..) |box, i| {
        const id: u8 = @intCast(10 + i);
        recast.markBoxArea(ctx, &box[0], &box[1], id, chf);
        upstream.shim_mark_box(logs.original, &box[0], &box[1], id, original);
        try logs.expectSame("mark box");
        try expectSameDump("mark box", chf, original);
    }
    const cylinders = [_]struct { [3]f32, f32, f32 }{
        .{ .{ (lo[0] + hi[0]) / 2, lo[1], (lo[2] + hi[2]) / 2 }, 3.0, 4.0 },
        .{ .{ lo[0], lo[1] + 1, lo[2] }, 5.0, 100.0 },
        .{ .{ hi[0] + 1, lo[1], hi[2] + 1 }, 2.0, 2.0 },
        .{ .{ lo[0] + 7.5, lo[1], lo[2] + 7.5 }, 0.9, 50.0 },
        .{ .{ lo[0] + 8, lo[1], lo[2] + 8 }, 0, 50.0 },
        .{ .{ nan, lo[1], lo[2] }, 2.0, 5.0 },
        .{ .{ lo[0], lo[1], lo[2] }, huge, huge },
    };
    for (cylinders, 0..) |cylinder, i| {
        const id: u8 = @intCast(30 + i);
        recast.markCylinderArea(ctx, &cylinder[0], cylinder[1], cylinder[2], id, chf);
        upstream.shim_mark_cylinder(
            logs.original,
            &cylinder[0],
            cylinder[1],
            cylinder[2],
            id,
            original,
        );
        try logs.expectSame("mark cylinder");
        try expectSameDump("mark cylinder", chf, original);
    }
    var prng: std.Random.DefaultPrng = .init(5);
    const random = prng.random();
    for (0..40) |i| {
        // Convex polygons of 3 to 12 corners, some partly outside, some with
        // corners on cell centers.
        const n = 3 + random.uintLessThan(usize, 10);
        var poly: [12 * 3]f32 = undefined;
        const cx = lo[0] + random.float(f32) * (hi[0] - lo[0] + 10) - 5;
        const cz = lo[2] + random.float(f32) * (hi[2] - lo[2] + 10) - 5;
        const r = 0.5 + random.float(f32) * 12;
        for (0..n) |k| {
            const angle = @as(f32, @floatFromInt(k)) * std.math.tau / @as(f32, @floatFromInt(n));
            var x = cx + r * @cos(angle);
            var z = cz + r * @sin(angle);
            if (i % 4 == 0) {
                x = lo[0] + (@floor((x - lo[0]) / chf.cs) + 0.5) * chf.cs;
                z = lo[2] + (@floor((z - lo[2]) / chf.cs) + 0.5) * chf.cs;
            }
            poly[k * 3 ..][0..3].* = .{ x, lo[1], z };
        }
        const min_y = lo[1] + random.float(f32) * 3 - 1;
        const max_y = min_y + random.float(f32) * 6;
        const id: u8 = @intCast(i);
        recast.markConvexPolyArea(ctx, poly[0 .. n * 3], min_y, max_y, id, chf);
        upstream.shim_mark_convex(logs.original, &poly, @intCast(n), min_y, max_y, id, original);
        try logs.expectSame("mark convex");
        try expectSameDump("mark convex", chf, original);
    }
    const median = recast.medianFilterWalkableArea(ctx, gpa, chf);
    const original_median = upstream.shim_median(logs.original, original);
    _ = try sameOutcome(logs, "median", succeeded(median), original_median != 0);
    try expectSameDump("median", chf, original);
}

test "offsetPoly matches on both windings, degenerate corners and short buffers" {
    var prng: std.Random.DefaultPrng = .init(11);
    const random = prng.random();
    for (0..400) |i| {
        const n = 1 + random.uintLessThan(usize, 12);
        var verts: [12 * 3]f32 = undefined;
        for (0..n) |k| {
            const angle = @as(f32, @floatFromInt(k)) * std.math.tau / @as(f32, @floatFromInt(n));
            const r = 1 + random.float(f32) * 4;
            const flip: f32 = if (i % 2 == 0) 1 else -1;
            const y = random.float(f32);
            verts[k * 3 ..][0..3].* = .{ r * @cos(angle), y, flip * r * @sin(angle) };
            if (i % 7 == 0 and k > 0) verts[k * 3 ..][0..3].* = verts[(k - 1) * 3 ..][0..3].*;
        }
        const offset = (random.float(f32) - 0.3) * 2;
        const max_out = random.uintLessThan(usize, 40);
        var out: [40 * 3]f32 = @splat(0);
        var original_out: [40 * 3]f32 = @splat(0);
        const count = recast.offsetPoly(verts[0 .. n * 3], offset, out[0 .. max_out * 3]);
        const original_count = upstream.shim_offset_poly(
            &verts,
            @intCast(n),
            offset,
            &original_out,
            @intCast(max_out),
        );
        try testing.expectEqual(original_count, count);
        try testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&original_out),
            std.mem.asBytes(&out),
        );
    }
}

test "contours and polygons match for every contour flag and vertex limit" {
    var mesh = try loadMesh(.terrain);
    defer mesh.deinit(gpa);
    var compact = try buildCompact(&mesh, .{ .mark_areas = true });
    defer compact.deinit();
    const logs = &compact.logs;
    const ctx = logs.port();
    const chf = &compact.chf;
    const original_chf = compact.original;
    try recast.buildDistanceField(ctx, gpa, chf);
    try testing.expect(upstream.shim_distance_field(logs.original, original_chf) != 0);
    try recast.buildRegions(ctx, gpa, chf, 0, 64, 400);
    try testing.expect(upstream.shim_regions(logs.original, original_chf, 0, 64, 400) != 0);
    try logs.expectSame("regions");
    for (0..4) |bits| {
        const flags: recast.ContourBuildFlags = @bitCast(@as(u32, @intCast(bits)));
        for ([_]f32{ 0, 0.7, 1.3, 4 }) |max_error| {
            for ([_]i32{ 0, 5, 40 }) |max_edge_len| {
                var cset = try recast.buildContours(ctx, gpa, chf, max_error, max_edge_len, flags);
                defer cset.deinit(gpa);
                const original_cset = upstream.shim_contours_build(
                    logs.original,
                    original_chf,
                    max_error,
                    max_edge_len,
                    @intCast(bits),
                ) orelse return error.TestUnexpectedResult;
                defer upstream.shim_contours_free(original_cset);
                try logs.expectSame("contours");
                try expectSameDump("contours", &cset, original_cset);
                for ([_]i32{ 3, 6, 9 }) |nvp| {
                    var pmesh = try recast.buildPolyMesh(ctx, gpa, &cset, nvp);
                    defer pmesh.deinit(gpa);
                    const original_pmesh = upstream.shim_polymesh_build(
                        logs.original,
                        original_cset,
                        nvp,
                    ) orelse return error.TestUnexpectedResult;
                    defer upstream.shim_polymesh_free(original_pmesh);
                    try logs.expectSame("polymesh");
                    try expectSameDump("polymesh", &pmesh, original_pmesh);
                }
            }
        }
    }
}

test "detail meshes match for every sample distance and error" {
    var mesh = try loadMesh(.undulating);
    defer mesh.deinit(gpa);
    var compact = try buildCompact(&mesh, .{});
    defer compact.deinit();
    const logs = &compact.logs;
    const ctx = logs.port();
    const chf = &compact.chf;
    const original_chf = compact.original;
    try recast.buildDistanceField(ctx, gpa, chf);
    try testing.expect(upstream.shim_distance_field(logs.original, original_chf) != 0);
    try recast.buildRegions(ctx, gpa, chf, 0, 64, 400);
    try testing.expect(upstream.shim_regions(logs.original, original_chf, 0, 64, 400) != 0);
    var cset = try recast.buildContours(ctx, gpa, chf, 1.3, 40, .default);
    defer cset.deinit(gpa);
    const original_cset = upstream.shim_contours_build(
        logs.original,
        original_chf,
        1.3,
        40,
        1,
    ) orelse return error.TestUnexpectedResult;
    defer upstream.shim_contours_free(original_cset);
    var pmesh = try recast.buildPolyMesh(ctx, gpa, &cset, 6);
    defer pmesh.deinit(gpa);
    const original_pmesh = upstream.shim_polymesh_build(logs.original, original_cset, 6) orelse
        return error.TestUnexpectedResult;
    defer upstream.shim_polymesh_free(original_pmesh);
    try logs.expectSame("polymesh");
    // A sample distance of 0 never finishes in the original.
    for ([_]f32{ 0.3, 0.9, 1.8, 5 }) |sample_dist| {
        for ([_]f32{ 0, 0.05, 0.2, 1 }) |sample_max_error| {
            var dmesh = try recast.buildPolyMeshDetail(
                ctx,
                gpa,
                &pmesh,
                chf,
                sample_dist,
                sample_max_error,
            );
            defer dmesh.deinit(gpa);
            const original_dmesh = upstream.shim_detail_build(
                logs.original,
                original_pmesh,
                original_chf,
                sample_dist,
                sample_max_error,
            ) orelse return error.TestUnexpectedResult;
            defer upstream.shim_detail_free(original_dmesh);
            try logs.expectSame("detail");
            try expectSameDump("detail", &dmesh, original_dmesh);
        }
    }
}

test "walkable triangles match at every slope" {
    for (all_sources) |source| {
        var mesh = try loadMesh(source);
        defer mesh.deinit(gpa);
        const nt: usize = @intCast(mesh.triCount());
        const areas = try gpa.alloc(u8, nt);
        defer gpa.free(areas);
        const original_areas = try gpa.alloc(u8, nt);
        defer gpa.free(original_areas);
        var logs = try Logs.init();
        defer logs.deinit();
        var slope: f32 = 0;
        while (slope <= 90) : (slope += 2.5) {
            for (areas, original_areas, 0..) |*a, *b, i| {
                a.* = @truncate(i);
                b.* = @truncate(i);
            }
            recast.markWalkableTriangles(logs.port(), slope, mesh.verts, mesh.tris, areas);
            upstream.shim_mark_walkable(
                logs.original,
                slope,
                mesh.verts.ptr,
                mesh.vertCount(),
                mesh.tris.ptr,
                mesh.triCount(),
                original_areas.ptr,
            );
            try testing.expectEqualSlices(u8, original_areas, areas);
            recast.clearUnwalkableTriangles(logs.port(), slope + 1, mesh.verts, mesh.tris, areas);
            upstream.shim_clear_unwalkable(
                logs.original,
                slope + 1,
                mesh.verts.ptr,
                mesh.vertCount(),
                mesh.tris.ptr,
                mesh.triCount(),
                original_areas.ptr,
            );
            try testing.expectEqualSlices(u8, original_areas, areas);
        }
        try logs.expectSame("walkable triangles");
    }
}

test "slope thresholds round as the original's cosf" {
    var slope: f32 = 0;
    while (slope <= 90) : (slope += 0.125) {
        const x = slope / 180.0 * recast.pi;
        try testing.expectEqual(
            @as(u32, @bitCast(upstream.shim_cosf(x))),
            @as(u32, @bitCast(@cos(x))),
        );
    }
}

test "every rasterization entry point matches on crafted triangles" {
    var prng: std.Random.DefaultPrng = .init(3);
    const random = prng.random();
    var logs = try Logs.init();
    defer logs.deinit();
    const ctx = logs.port();
    const bmin: [3]f32 = .{ -10, -2, -10 };
    const bmax: [3]f32 = .{ 10, 1640, 10 };
    for ([_][2]f32{ .{ 0.3, 0.2 }, .{ 1.0, 0.1 }, .{ 0.25, 0.25 } }) |cell| {
        var hf = try recast.Heightfield.init(gpa, 67, 67, &bmin, &bmax, cell[0], cell[1]);
        defer hf.deinit(gpa);
        const original_hf = upstream.shim_hf_create(
            logs.original,
            67,
            67,
            &bmin,
            &bmax,
            cell[0],
            cell[1],
        ) orelse return error.OutOfMemory;
        defer upstream.shim_hf_free(original_hf);
        const nan = std.math.nan(f32);
        const special = [_][3][3]f32{
            .{ .{ -10, 0, -10 }, .{ -10, 0, 10 }, .{ 10, 0, -10 } },
            .{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } },
            .{ .{ 0, 0, 0 }, .{ 0, 5, 0 }, .{ 0, 5, 3 } },
            .{ .{ -50, 1, -50 }, .{ -50, 1, 50 }, .{ 50, 1, 0 } },
            .{ .{ -1e20, 0, -1e20 }, .{ -1e20, 0, 1e20 }, .{ 1e20, 0, 0 } },
            .{ .{ 20, 0, 20 }, .{ 20, 0, 30 }, .{ 30, 0, 20 } },
            .{ .{ 0, -5, 0 }, .{ 0, -3, 1 }, .{ 1, -4, 0 } },
            .{ .{ 0, 1630, 0 }, .{ 0, 1700, 1 }, .{ 1, 1650, 0 } },
            .{ .{ 0, 1638, 0 }, .{ 0, 1639, 1 }, .{ 1, 1638.5, 0 } },
            .{ .{ 0.3, 0, 0.3 }, .{ 0.3, 0, 0.6 }, .{ 0.6, 0, 0.3 } },
            .{ .{ nan, 0, 0 }, .{ 0, 0, 1 }, .{ 1, 0, 0 } },
            .{ .{ 2, nan, 2 }, .{ 2, 0, 3 }, .{ 3, 0, 2 } },
        };
        for (special, 0..) |tri, i| {
            const area: u8 = @intCast(i * 6);
            for ([_]i32{ 0, 1, 4 }) |merge| {
                const ok = recast.rasterizeTriangle(
                    ctx,
                    gpa,
                    &tri[0],
                    &tri[1],
                    &tri[2],
                    area,
                    &hf,
                    merge,
                );
                if (!oracle.inVertexRange(hf.cs, &tri)) {
                    // The original's step would be its timer alone.
                    try testing.expectError(error.NonFiniteVertex, ok);
                    const timer = recast.TimerLabel.rasterize_triangles;
                    const label: c_int = @intCast(@backingInt(timer));
                    upstream.shim_log_timer(logs.original, label, 1);
                    upstream.shim_log_timer(logs.original, label, 0);
                    const line = oracle.refusalLine("rcRasterizeTriangle");
                    try oracle.expectSameWithRefusal(&logs, "triangle", line);
                    continue;
                }
                const original_ok = upstream.shim_rasterize_triangle(
                    logs.original,
                    &tri[0],
                    &tri[1],
                    &tri[2],
                    area,
                    original_hf,
                    merge,
                );
                _ = try sameOutcome(&logs, "triangle", succeeded(ok), original_ok != 0);
            }
        }
        try expectSameDump("special triangles", &hf, original_hf);

        // Random triangles, some across the bounds, as an index list of both
        // widths and as a list of corners.
        var verts: [300 * 3]f32 = undefined;
        for (&verts, 0..) |*v, i| {
            const axis = i % 3;
            v.* = if (axis == 1) random.float(f32) * 30 - 5 else random.float(f32) * 26 - 13;
        }
        var tris: [200 * 3]i32 = undefined;
        var tris_u16: [200 * 3]u16 = undefined;
        for (&tris, &tris_u16) |*t, *t16| {
            t.* = @as(i32, @intCast(random.uintLessThan(u32, 300)));
            t16.* = @intCast(t.*);
        }
        var areas: [200]u8 = undefined;
        for (&areas) |*a| a.* = random.uintLessThan(u8, 70);
        var flat: [200 * 9]f32 = undefined;
        for (0..200) |t| {
            for (0..3) |k| {
                const v: usize = @intCast(tris[t * 3 + k]);
                flat[t * 9 + k * 3 ..][0..3].* = verts[v * 3 ..][0..3].*;
            }
        }
        try recast.rasterizeTriangles(ctx, gpa, &verts, i32, &tris, &areas, &hf, 2);
        try testing.expect(upstream.shim_rasterize_triangles(
            logs.original,
            &verts,
            300,
            &tris,
            &areas,
            200,
            original_hf,
            2,
        ) != 0);
        try logs.expectSame("triangles");
        try expectSameDump("triangles", &hf, original_hf);
        try recast.rasterizeTriangles(ctx, gpa, &verts, u16, &tris_u16, &areas, &hf, 0);
        try testing.expect(upstream.shim_rasterize_triangles_u16(
            logs.original,
            &verts,
            300,
            &tris_u16,
            &areas,
            200,
            original_hf,
            0,
        ) != 0);
        try logs.expectSame("u16 triangles");
        try expectSameDump("u16 triangles", &hf, original_hf);
        try recast.rasterizeUnindexedTriangles(ctx, gpa, &flat, &areas, &hf, 7);
        try testing.expect(upstream.shim_rasterize_unindexed(
            logs.original,
            &flat,
            &areas,
            200,
            original_hf,
            7,
        ) != 0);
        try logs.expectSame("unindexed triangles");
        try expectSameDump("unindexed triangles", &hf, original_hf);
    }
}

test "spans added directly merge, wrap and filter as the original's" {
    var prng: std.Random.DefaultPrng = .init(9);
    const random = prng.random();
    var logs = try Logs.init();
    defer logs.deinit();
    const ctx = logs.port();
    const bmin: [3]f32 = .{ 0, 0, 0 };
    const bmax: [3]f32 = .{ 6, 100, 6 };
    for (0..6) |round| {
        var hf = try recast.Heightfield.init(gpa, 6, 6, &bmin, &bmax, 1, 0.1);
        defer hf.deinit(gpa);
        const original_hf = upstream.shim_hf_create(
            logs.original,
            6,
            6,
            &bmin,
            &bmax,
            1,
            0.1,
        ) orelse return error.OutOfMemory;
        defer upstream.shim_hf_free(original_hf);
        // Enough spans to need more than one pool.
        for (0..5000) |_| {
            const x = @as(i32, @intCast(random.uintLessThan(u32, 6)));
            const z = @as(i32, @intCast(random.uintLessThan(u32, 6)));
            const top: u16 = if (round % 2 == 0) 400 else 8200;
            const smin = random.uintLessThan(u16, top);
            const smax = smin + random.uintLessThan(u16, 30);
            const area = random.uintLessThan(u8, 70);
            const merge = @as(i32, @intCast(random.uintLessThan(u32, 4)));
            const ok = recast.addSpan(ctx, gpa, &hf, x, z, smin, smax, area, merge);
            const original_ok = upstream.shim_add_span(
                logs.original,
                original_hf,
                x,
                z,
                smin,
                smax,
                area,
                merge,
            );
            _ = try sameOutcome(&logs, "add span", succeeded(ok), original_ok != 0);
        }
        try expectSameDump("add span", &hf, original_hf);
        const climb: i32 = @intCast(round * 3);
        const height: i32 = @intCast(2 + round * 4);
        recast.filterLowHangingWalkableObstacles(ctx, climb, &hf);
        upstream.shim_filter_low_hanging(logs.original, climb, original_hf);
        try expectSameDump("filter low hanging obstacles", &hf, original_hf);
        recast.filterLedgeSpans(ctx, height, climb, &hf);
        upstream.shim_filter_ledge(logs.original, height, climb, original_hf);
        try expectSameDump("filter ledge spans", &hf, original_hf);
        recast.filterWalkableLowHeightSpans(ctx, height, &hf);
        upstream.shim_filter_low_height(logs.original, height, original_hf);
        try expectSameDump("filter low height spans", &hf, original_hf);
        try logs.expectSame("filters");

        var chf = try recast.buildCompactHeightfield(ctx, gpa, height, climb, &hf);
        defer chf.deinit(gpa);
        const original_chf = upstream.shim_chf_build(
            logs.original,
            height,
            climb,
            original_hf,
        ) orelse return error.TestUnexpectedResult;
        defer upstream.shim_chf_free(original_chf);
        try logs.expectSame("compact");
        try expectSameDump("compact", &chf, original_chf);
    }
}

test "a column of more than 63 floors logs too many layers as the original" {
    var logs = try Logs.init();
    defer logs.deinit();
    const ctx = logs.port();
    const bmin: [3]f32 = .{ 0, 0, 0 };
    const bmax: [3]f32 = .{ 2, 100, 1 };
    var hf = try recast.Heightfield.init(gpa, 2, 1, &bmin, &bmax, 1, 0.1);
    defer hf.deinit(gpa);
    const original_hf = upstream.shim_hf_create(logs.original, 2, 1, &bmin, &bmax, 1, 0.1) orelse
        return error.OutOfMemory;
    defer upstream.shim_hf_free(original_hf);
    for (0..300) |i| {
        for (0..2) |x| {
            const smin: u16 = @intCast(i * 20);
            const ok = recast.addSpan(ctx, gpa, &hf, @intCast(x), 0, smin, smin + 2, 63, 0);
            const original_ok = upstream.shim_add_span(
                logs.original,
                original_hf,
                @intCast(x),
                0,
                smin,
                smin + 2,
                63,
                0,
            );
            _ = try sameOutcome(&logs, "add span", succeeded(ok), original_ok != 0);
        }
    }
    var chf = try recast.buildCompactHeightfield(ctx, gpa, 5, 3, &hf);
    defer chf.deinit(gpa);
    const original_chf = upstream.shim_chf_build(logs.original, 5, 3, original_hf) orelse
        return error.TestUnexpectedResult;
    defer upstream.shim_chf_free(original_chf);
    try logs.expectSame("compact");
    try expectSameDump("compact", &chf, original_chf);
}

test "the context logs, cuts messages and times as the original's" {
    var logs = try Logs.init();
    defer logs.deinit();
    for ([_]usize{ 0, 1, 510, 511, 512, 600, 2000 }) |len| {
        const text = try gpa.allocSentinel(u8, len, 0);
        defer gpa.free(text);
        for (text, 0..) |*c, i| c.* = 'a' + @as(u8, @intCast(i % 26));
        logs.port().log(.warning, "{s}", .{text});
        upstream.shim_log_message(logs.original, 2, text.ptr);
        try logs.expectSame("log");
    }
    var ctx = logs.port();
    ctx.resetLog();
    ctx.resetTimers();
    upstream.shim_log_reset(logs.original);
    try logs.expectSame("reset");
    for (0..recast.max_timers) |i| {
        const label: recast.TimerLabel = @fromBackingInt(@as(u32, @intCast(i)));
        const c_label: c_int = @intCast(i);
        ctx.startTimer(label);
        ctx.stopTimer(label);
        upstream.shim_log_timer(logs.original, c_label, 1);
        upstream.shim_log_timer(logs.original, c_label, 0);
        const time = upstream.shim_log_accumulated(logs.original, c_label);
        try testing.expectEqual(time, ctx.accumulatedTime(label));
        const default_time = upstream.shim_default_accumulated(c_label, 1);
        try testing.expectEqual(default_time, recast.Context.none.accumulatedTime(label));
    }
    try logs.expectSame("timers");
    ctx.enableLog(false);
    ctx.enableTimer(false);
    upstream.shim_log_enable(logs.original, 0, 0);
    ctx.log(.err, "lost", .{});
    ctx.startTimer(.total);
    ctx.stopTimer(.total);
    ctx.resetLog();
    ctx.resetTimers();
    upstream.shim_log_message(logs.original, 3, "lost");
    upstream.shim_log_timer(logs.original, 0, 1);
    upstream.shim_log_timer(logs.original, 0, 0);
    upstream.shim_log_reset(logs.original);
    try logs.expectSame("disabled");
    const time = upstream.shim_log_accumulated(logs.original, 0);
    try testing.expectEqual(time, ctx.accumulatedTime(.total));
    var none: recast.Context = .none;
    none.enableTimer(false);
    try testing.expectEqual(upstream.shim_default_accumulated(0, 0), none.accumulatedTime(.total));
}

test "constants, log categories and timer labels have the original's values" {
    var original: [32]c_int = undefined;
    var original_pi: f32 = undefined;
    const n: usize = @intCast(upstream.shim_constants(&original, &original_pi));
    const wall: recast.ContourBuildFlags = .{ .tess_wall_edges = true };
    const area: recast.ContourBuildFlags = .{ .tess_area_edges = true };
    const port = [_]i64{
        recast.span_height_bits,
        recast.span_max_height,
        recast.spans_per_pool,
        recast.border_reg,
        recast.multiple_regs,
        recast.border_vertex,
        recast.area_border,
        @as(u32, @bitCast(wall)),
        @as(u32, @bitCast(area)),
        recast.contour_reg_mask,
        recast.mesh_null_idx,
        recast.null_area,
        recast.walkable_area,
        recast.not_connected,
        @backingInt(recast.LogCategory.progress),
        @backingInt(recast.LogCategory.warning),
        @backingInt(recast.LogCategory.err),
    };
    try testing.expectEqual(n, port.len);
    for (original[0..n], port) |o, p| try testing.expectEqual(@as(i64, o), p);
    try testing.expectEqual(@as(u32, @bitCast(original_pi)), @as(u32, @bitCast(recast.pi)));
    try testing.expectEqual(wall, recast.ContourBuildFlags.default);

    // Each label has the original's name, in snake case, and value.
    try testing.expectEqual(upstream.shim_max_timers(), @as(c_int, recast.max_timers));
    for (0..recast.max_timers) |i| {
        const label: recast.TimerLabel = @fromBackingInt(@as(u32, @intCast(i)));
        const name = std.mem.span(upstream.shim_timer_label_name(@intCast(i)));
        var buffer: [64]u8 = undefined;
        try testing.expectEqualStrings("RC_TIMER_", name[0..@min(name.len, 9)]);
        try testing.expectEqualStrings(std.ascii.upperString(&buffer, @tagName(label)), name[9..]);
    }
}

/// Loomwork's navmesh tile settings.
const TileSettings = struct {
    cell_size: f32 = 0.3,
    cell_height: f32 = 0.2,
    max_slope_degrees: f32 = 45,
    agent_height: f32 = 2.0,
    agent_climb: f32 = 0.9,
    agent_radius: f32 = 0.6,
    tile_size: f32 = 12.0,
};

/// The configuration Loomwork builds a navmesh tile with: a square tile and
/// a border wide enough that the tiles' edges meet.
fn tileConfig(t: TileSettings, bmin: [3]f32, bmax: [3]f32, tx: i32, tz: i32) recast.Config {
    var cfg: recast.Config = .{
        .cs = t.cell_size,
        .ch = t.cell_height,
        .walkable_slope_angle = t.max_slope_degrees,
        .walkable_height = @intFromFloat(@ceil(t.agent_height / t.cell_height)),
        .walkable_climb = @intFromFloat(@floor(t.agent_climb / t.cell_height)),
        .walkable_radius = @intFromFloat(@ceil(t.agent_radius / t.cell_size)),
        .max_edge_len = @intFromFloat(12.0 / t.cell_size),
        .max_simplification_error = 1.3,
        .min_region_area = @intFromFloat((2.4 / t.cell_size) * (2.4 / t.cell_size)),
        .merge_region_area = @intFromFloat((6.0 / t.cell_size) * (6.0 / t.cell_size)),
        .max_verts_per_poly = 6,
        .detail_sample_dist = 1.8,
        .detail_sample_max_error = t.cell_height,
    };
    cfg.tile_size = @intFromFloat(t.tile_size / cfg.cs + 0.5);
    cfg.border_size = cfg.walkable_radius + 3;
    cfg.width = cfg.tile_size + 2 * cfg.border_size;
    cfg.height = cfg.width;
    const border = @as(f32, @floatFromInt(cfg.border_size)) * cfg.cs;
    const fx: f32 = @floatFromInt(tx);
    const fz: f32 = @floatFromInt(tz);
    cfg.bmin = .{
        bmin[0] + fx * t.tile_size - border,
        bmin[1],
        bmin[2] + fz * t.tile_size - border,
    };
    cfg.bmax = .{
        bmin[0] + (fx + 1) * t.tile_size + border,
        bmax[1],
        bmin[2] + (fz + 1) * t.tile_size + border,
    };
    return cfg;
}

const PortTile = struct {
    pmesh: recast.PolyMesh,
    dmesh: recast.PolyMeshDetail,

    fn deinit(tile: *PortTile, allocator: Allocator) void {
        tile.pmesh.deinit(allocator);
        tile.dmesh.deinit(allocator);
    }
};

/// Builds a tile with the port as Loomwork's navmesh does.
fn buildPortTile(
    ctx: recast.Context,
    allocator: Allocator,
    mesh: *const meshes.Mesh,
    cfg: *const recast.Config,
) !PortTile {
    var hf = try recast.Heightfield.init(
        allocator,
        cfg.width,
        cfg.height,
        &cfg.bmin,
        &cfg.bmax,
        cfg.cs,
        cfg.ch,
    );
    defer hf.deinit(allocator);
    const areas = try allocator.alloc(u8, @intCast(mesh.triCount()));
    defer allocator.free(areas);
    @memset(areas, 0);
    recast.markWalkableTriangles(ctx, cfg.walkable_slope_angle, mesh.verts, mesh.tris, areas);
    try recast.rasterizeTriangles(
        ctx,
        allocator,
        mesh.verts,
        i32,
        mesh.tris,
        areas,
        &hf,
        cfg.walkable_climb,
    );
    recast.filterLowHangingWalkableObstacles(ctx, cfg.walkable_climb, &hf);
    recast.filterLedgeSpans(ctx, cfg.walkable_height, cfg.walkable_climb, &hf);
    recast.filterWalkableLowHeightSpans(ctx, cfg.walkable_height, &hf);
    var chf = try recast.buildCompactHeightfield(
        ctx,
        allocator,
        cfg.walkable_height,
        cfg.walkable_climb,
        &hf,
    );
    defer chf.deinit(allocator);
    try recast.erodeWalkableArea(ctx, allocator, cfg.walkable_radius, &chf);
    try recast.buildDistanceField(ctx, allocator, &chf);
    try recast.buildRegions(
        ctx,
        allocator,
        &chf,
        cfg.border_size,
        cfg.min_region_area,
        cfg.merge_region_area,
    );
    var cset = try recast.buildContours(
        ctx,
        allocator,
        &chf,
        cfg.max_simplification_error,
        cfg.max_edge_len,
        .default,
    );
    defer cset.deinit(allocator);
    var pmesh = try recast.buildPolyMesh(ctx, allocator, &cset, cfg.max_verts_per_poly);
    errdefer pmesh.deinit(allocator);
    const dmesh = try recast.buildPolyMeshDetail(
        ctx,
        allocator,
        &pmesh,
        &chf,
        cfg.detail_sample_dist,
        cfg.detail_sample_max_error,
    );
    return .{ .pmesh = pmesh, .dmesh = dmesh };
}

const OriginalTile = struct {
    pmesh: *upstream.PolyMesh,
    dmesh: *upstream.PolyMeshDetail,

    fn deinit(tile: *OriginalTile) void {
        upstream.shim_polymesh_free(tile.pmesh);
        upstream.shim_detail_free(tile.dmesh);
    }
};

/// Builds a tile with the original as Loomwork's navmesh does.
fn buildOriginalTile(
    log: *upstream.Log,
    mesh: *const meshes.Mesh,
    cfg: *const recast.Config,
) !OriginalTile {
    const nv = mesh.vertCount();
    const nt = mesh.triCount();
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
    const areas = try gpa.alloc(u8, @intCast(nt));
    defer gpa.free(areas);
    @memset(areas, 0);
    upstream.shim_mark_walkable(
        log,
        cfg.walkable_slope_angle,
        mesh.verts.ptr,
        nv,
        mesh.tris.ptr,
        nt,
        areas.ptr,
    );
    if (upstream.shim_rasterize_triangles(
        log,
        mesh.verts.ptr,
        nv,
        mesh.tris.ptr,
        areas.ptr,
        nt,
        hf,
        cfg.walkable_climb,
    ) == 0) return error.TestUnexpectedResult;
    upstream.shim_filter_low_hanging(log, cfg.walkable_climb, hf);
    upstream.shim_filter_ledge(log, cfg.walkable_height, cfg.walkable_climb, hf);
    upstream.shim_filter_low_height(log, cfg.walkable_height, hf);
    const chf = upstream.shim_chf_build(log, cfg.walkable_height, cfg.walkable_climb, hf) orelse
        return error.TestUnexpectedResult;
    defer upstream.shim_chf_free(chf);
    if (upstream.shim_erode(log, cfg.walkable_radius, chf) == 0) return error.TestUnexpectedResult;
    if (upstream.shim_distance_field(log, chf) == 0) return error.TestUnexpectedResult;
    if (upstream.shim_regions(
        log,
        chf,
        cfg.border_size,
        cfg.min_region_area,
        cfg.merge_region_area,
    ) == 0) return error.TestUnexpectedResult;
    const cset = upstream.shim_contours_build(
        log,
        chf,
        cfg.max_simplification_error,
        cfg.max_edge_len,
        1,
    ) orelse return error.TestUnexpectedResult;
    defer upstream.shim_contours_free(cset);
    const pmesh = upstream.shim_polymesh_build(log, cset, cfg.max_verts_per_poly) orelse
        return error.TestUnexpectedResult;
    errdefer upstream.shim_polymesh_free(pmesh);
    const dmesh = upstream.shim_detail_build(
        log,
        pmesh,
        chf,
        cfg.detail_sample_dist,
        cfg.detail_sample_max_error,
    ) orelse return error.TestUnexpectedResult;
    return .{ .pmesh = pmesh, .dmesh = dmesh };
}

/// A tile built on a pool thread, with its dumps.
const TileTask = struct {
    mesh: *const meshes.Mesh,
    cfg: recast.Config,
    pmesh_dump: []u8 = &.{},
    dmesh_dump: []u8 = &.{},
    failed: ?anyerror = null,

    fn run(task: *TileTask) void {
        task.build() catch |err| {
            task.failed = err;
        };
    }

    fn build(task: *TileTask) !void {
        var tile = try buildPortTile(.none, gpa, task.mesh, &task.cfg);
        defer tile.deinit(gpa);
        task.pmesh_dump = try dump(gpa, &tile.pmesh);
        task.dmesh_dump = try dump(gpa, &tile.dmesh);
    }

    fn deinit(task: *TileTask) void {
        gpa.free(task.pmesh_dump);
        gpa.free(task.dmesh_dump);
    }
};

test "tiles build the same on every thread count, as the original builds them" {
    var mesh = try meshes.terrain(gpa, 60, 4);
    defer mesh.deinit(gpa);
    var bmin: [3]f32 = undefined;
    var bmax: [3]f32 = undefined;
    recast.calcBounds(mesh.verts, &bmin, &bmax);
    const settings: TileSettings = .{};
    const tiles_x: i32 = @intFromFloat(@ceil((bmax[0] - bmin[0]) / settings.tile_size));
    const tiles_z: i32 = @intFromFloat(@ceil((bmax[2] - bmin[2]) / settings.tile_size));
    const count: usize = @intCast(tiles_x * tiles_z);

    var logs = try Logs.init();
    defer logs.deinit();
    const cfgs = try gpa.alloc(recast.Config, count);
    defer gpa.free(cfgs);
    const port_tiles = try gpa.alloc(PortTile, count);
    defer gpa.free(port_tiles);
    const original_tiles = try gpa.alloc(OriginalTile, count);
    defer gpa.free(original_tiles);
    var built: usize = 0;
    defer for (port_tiles[0..built], original_tiles[0..built]) |*p, *o| {
        p.deinit(gpa);
        o.deinit();
    };
    for (cfgs, 0..) |*cfg, i| {
        const tx: i32 = @intCast(i % @as(usize, @intCast(tiles_x)));
        const tz: i32 = @intCast(i / @as(usize, @intCast(tiles_x)));
        cfg.* = tileConfig(settings, bmin, bmax, tx, tz);
        original_tiles[i] = try buildOriginalTile(logs.original, &mesh, cfg);
        port_tiles[i] = buildPortTile(logs.port(), gpa, &mesh, cfg) catch |err| {
            var tile = original_tiles[i];
            tile.deinit();
            return err;
        };
        built += 1;
        try logs.expectSame("tile");
        try expectSameDump("tile polymesh", &port_tiles[i].pmesh, original_tiles[i].pmesh);
        try expectSameDump("tile detail", &port_tiles[i].dmesh, original_tiles[i].dmesh);
    }

    // Merged, as RecastDemo merges a tiled build into one mesh.
    {
        const port_meshes = try gpa.alloc(*const recast.PolyMesh, count);
        defer gpa.free(port_meshes);
        const original_meshes = try gpa.alloc(*upstream.PolyMesh, count);
        defer gpa.free(original_meshes);
        const port_details = try gpa.alloc(*const recast.PolyMeshDetail, count);
        defer gpa.free(port_details);
        const original_details = try gpa.alloc(*upstream.PolyMeshDetail, count);
        defer gpa.free(original_details);
        for (port_tiles, original_tiles, 0..) |*p, o, i| {
            port_meshes[i] = &p.pmesh;
            original_meshes[i] = o.pmesh;
            port_details[i] = &p.dmesh;
            original_details[i] = o.dmesh;
        }
        var merged = try recast.mergePolyMeshes(logs.port(), gpa, port_meshes);
        defer merged.deinit(gpa);
        const original_merged = upstream.shim_polymesh_merge(
            logs.original,
            original_meshes.ptr,
            @intCast(count),
        ) orelse return error.TestUnexpectedResult;
        defer upstream.shim_polymesh_free(original_merged);
        try logs.expectSame("merge polymesh");
        try expectSameDump("merge polymesh", &merged, original_merged);

        var merged_detail = try recast.mergePolyMeshDetails(logs.port(), gpa, port_details);
        defer merged_detail.deinit(gpa);
        const original_merged_detail = upstream.shim_detail_merge(
            logs.original,
            original_details.ptr,
            @intCast(count),
        ) orelse return error.TestUnexpectedResult;
        defer upstream.shim_detail_free(original_merged_detail);
        try logs.expectSame("merge detail");
        try expectSameDump("merge detail", &merged_detail, original_merged_detail);

        var none = try recast.mergePolyMeshes(logs.port(), gpa, &.{});
        defer none.deinit(gpa);
        const original_none = upstream.shim_polymesh_merge(
            logs.original,
            original_meshes.ptr,
            0,
        ) orelse return error.TestUnexpectedResult;
        defer upstream.shim_polymesh_free(original_none);
        try logs.expectSame("merge no polymesh");
        try expectSameDump("merge no polymesh", &none, original_none);
    }

    // On pools of 1 to 8 threads.
    for ([_]usize{ 1, 2, 4, 8 }) |threads| {
        var threaded: std.Io.Threaded = .init(gpa, .{ .async_limit = .limited(threads - 1) });
        defer threaded.deinit();
        const io = threaded.io();
        const tasks = try gpa.alloc(TileTask, count);
        defer gpa.free(tasks);
        for (tasks, cfgs) |*task, cfg| task.* = .{ .mesh = &mesh, .cfg = cfg };
        defer for (tasks) |*task| task.deinit();
        var group: std.Io.Group = .init;
        for (tasks) |*task| group.async(io, TileTask.run, .{task});
        try group.await(io);
        for (tasks, original_tiles) |*task, *original| {
            if (task.failed) |err| return err;
            const expected_pmesh = try upstream.dump(gpa, original.pmesh);
            defer gpa.free(expected_pmesh);
            const expected_dmesh = try upstream.dump(gpa, original.dmesh);
            defer gpa.free(expected_dmesh);
            try testing.expectEqualSlices(u8, expected_pmesh, task.pmesh_dump);
            try testing.expectEqualSlices(u8, expected_dmesh, task.dmesh_dump);
        }
    }
}
