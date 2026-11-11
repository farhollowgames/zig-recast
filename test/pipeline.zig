//! A whole build run step by step on the port and on the original, tile by
//! tile and merged: each step's outcome, log and timer calls and output are
//! kept as bytes, and the two runs must match at every step. The fuzz and
//! edge-case tests describe cases; this runs them.

const std = @import("std");
const recast = @import("recast");
const upstream = @import("upstream.zig");
const oracle = @import("oracle.zig");
const dump = @import("dump.zig").dump;

const testing = std.testing;
const gpa = testing.allocator;

/// How regions are built.
pub const Partition = enum { watershed, monotone, layers };

/// Which rasterization entry point takes the triangles.
pub const Raster = enum {
    /// `rasterizeTriangles` with 32-bit indices.
    int,
    /// `rasterizeTriangles` with 16-bit indices.
    u16,
    /// `rasterizeUnindexedTriangles`.
    unindexed,
    /// `rasterizeTriangle`, once per triangle.
    single,
};

/// An area marked on the compact heightfield.
pub const Mark = union(enum) {
    box: struct { min: [3]f32, max: [3]f32, area: u8 },
    /// A polygon, grown or shrunk by `offsetPoly` first when `offset` is not
    /// 0.
    convex: struct { verts: []const f32, offset: f32, min_y: f32, max_y: f32, area: u8 },
    cylinder: struct { pos: [3]f32, radius: f32, height: f32, area: u8 },
};

/// A span added to each tile's heightfield after the triangles, in column
/// (x mod width, z mod height).
pub const ExtraSpan = struct { x: i32, z: i32, smin: u16, smax: u16, area: u8, merge: i32 };

/// A scene and the steps that build it, in one heightfield per tile, and
/// the merge of the tiles' meshes.
pub const Case = struct {
    /// x, y and z per vertex.
    verts: []const f32,
    /// Three vertex indices per triangle.
    tris: []const i32,
    /// Each triangle's area id before marking.
    areas: []const u8,
    walkable_slope: f32 = 45,
    /// Clears the triangles steeper than this after marking, if not null.
    clear_slope: ?f32 = null,
    raster: Raster = .int,
    spans: []const ExtraSpan = &.{},
    /// Filters low hanging obstacles, ledges and low height spans.
    filters: [3]bool = @splat(true),
    median: bool = false,
    marks: []const Mark = &.{},
    /// Builds heightfield layers before the regions.
    layers: bool = false,
    partition: Partition = .watershed,
    flags: recast.ContourBuildFlags = .default,
    /// Each tile's bounds, grid size and settings.
    tiles: []const recast.Config,
};

/// What a case did on both sides.
pub const Summary = struct {
    failed_name: [64]u8 = undefined,
    failed_len: usize = 0,
    any_failed: bool = false,

    /// The name of the first step that failed, if one did.
    pub fn failedStep(summary: *const Summary) ?[]const u8 {
        return if (summary.any_failed) summary.failed_name[0..summary.failed_len] else null;
    }
};

/// Runs `case` on both sides and checks every step matches; `rerun` runs
/// the port a second time and checks it gives the same bytes. `label`
/// names the case in a failure's message.
pub fn expectSame(case: *const Case, label: []const u8, rerun: bool) !Summary {
    var inputs: Inputs = try .init(case);
    defer inputs.deinit();
    var original: Trace = .{};
    defer original.deinit();
    try originalCase(case, &inputs, &original);
    var port: Trace = .{};
    defer port.deinit();
    try portCase(case, &inputs, &port);
    try expectSameTrace(label, "the port against the original", &original, &port);
    if (rerun) {
        var again: Trace = .{};
        defer again.deinit();
        try portCase(case, &inputs, &again);
        try expectSameTrace(label, "the port against its first run", &port, &again);
    }
    var summary: Summary = .{};
    for (port.steps.items) |step| {
        if (step.bytes[0] != 0) continue;
        const len = @min(step.name.len, summary.failed_name.len);
        @memcpy(summary.failed_name[0..len], step.name[0..len]);
        summary.failed_len = len;
        summary.any_failed = true;
        break;
    }
    return summary;
}

/// The triangles in the other forms the entry points take.
const Inputs = struct {
    /// 16-bit indices, for `.u16` only.
    tris_u16: []u16,
    /// Three vertices per triangle, for `.unindexed` and `.single`.
    flat: []f32,

    fn init(case: *const Case) !Inputs {
        const tris_u16 = try gpa.alloc(u16, if (case.raster == .u16) case.tris.len else 0);
        errdefer gpa.free(tris_u16);
        for (tris_u16, 0..) |*narrow, i| narrow.* = @intCast(case.tris[i]);
        const unindexed = case.raster == .unindexed or case.raster == .single;
        const flat = try gpa.alloc(f32, if (unindexed) case.tris.len * 3 else 0);
        for (0..flat.len / 3) |i| {
            const v: usize = @intCast(case.tris[i]);
            flat[i * 3 ..][0..3].* = case.verts[v * 3 ..][0..3].*;
        }
        return .{ .tris_u16 = tris_u16, .flat = flat };
    }

    fn deinit(inputs: *Inputs) void {
        gpa.free(inputs.tris_u16);
        gpa.free(inputs.flat);
    }
};

/// What one side did: each step's name and bytes, which hold whether it
/// succeeded, its log and timer calls, and the dump of what it built.
const Trace = struct {
    steps: std.ArrayList(Step) = .empty,

    const Step = struct { name: []u8, bytes: []u8 };

    fn deinit(trace: *Trace) void {
        for (trace.steps.items) |step| {
            gpa.free(step.name);
            gpa.free(step.bytes);
        }
        trace.steps.deinit(gpa);
    }

    fn add(
        trace: *Trace,
        comptime format: []const u8,
        args: anytype,
        ok: bool,
        log: []const u8,
        output: []const u8,
    ) !void {
        const name = try std.fmt.allocPrint(gpa, format, args);
        errdefer gpa.free(name);
        // The addresses two contour warnings print differ between runs.
        const plain_log = try oracle.withoutAddresses(log);
        defer gpa.free(plain_log);
        const outcome = [1]u8{@intFromBool(ok)};
        const len: u32 = @intCast(plain_log.len);
        const bytes = try std.mem.concat(gpa, u8, &.{
            &outcome,
            std.mem.asBytes(&len),
            plain_log,
            output,
        });
        errdefer gpa.free(bytes);
        try trace.steps.append(gpa, .{ .name = name, .bytes = bytes });
    }
};

fn expectSameTrace(
    label: []const u8,
    what: []const u8,
    expected: *const Trace,
    actual: *const Trace,
) !void {
    const n = @min(expected.steps.items.len, actual.steps.items.len);
    for (expected.steps.items[0..n], actual.steps.items[0..n]) |e, a| {
        if (std.mem.eql(u8, e.name, a.name) and std.mem.eql(u8, e.bytes, a.bytes)) continue;
        const at = std.mem.findDiff(u8, e.bytes, a.bytes) orelse 0;
        std.debug.print(
            "{s}: {s}: step \"{s}\" against \"{s}\" differs at byte {d} " ++
                "({d} bytes against {d}; byte 0 is the outcome, the log follows)\n",
            .{ label, what, e.name, a.name, at, e.bytes.len, a.bytes.len },
        );
        return error.TestExpectedEqual;
    }
    if (expected.steps.items.len != actual.steps.items.len) {
        std.debug.print("{s}: {s}: {d} steps against {d}\n", .{
            label,
            what,
            expected.steps.items.len,
            actual.steps.items.len,
        });
        return error.TestExpectedEqual;
    }
}

/// The bounds step's output.
const Bounds = extern struct { bmin: [3]f32, bmax: [3]f32, width: i32, height: i32 };

/// The steps a tile takes after marking its areas. The original keeps a
/// row's sweeps in buffers as long as the field is wide (the layers) or one
/// short of its longer side (the monotone and layer partitions), and more
/// sweeps in a row overrun them: such a tile skips the layers or builds
/// watershed regions, on both sides.
const Plan = struct {
    region_sweeps: i32,
    layer_sweeps: i32,
    layers: bool,
    partition: Partition,

    /// The plan as a step's output.
    fn bytes(plan: Plan) [4]i32 {
        return .{
            plan.region_sweeps,
            plan.layer_sweeps,
            @intFromBool(plan.layers),
            @backingInt(plan.partition),
        };
    }

    fn of(
        case: *const Case,
        cfg: *const recast.Config,
        region_sweeps: i32,
        layer_sweeps: i32,
    ) Plan {
        const sweeps_fit = region_sweeps < @max(cfg.width, cfg.height);
        return .{
            .region_sweeps = region_sweeps,
            .layer_sweeps = layer_sweeps,
            .layers = case.layers and layer_sweeps <= cfg.width,
            .partition = if (sweeps_fit) case.partition else .watershed,
        };
    }
};

/// The most sweeps one row of `chf` inside the border starts. A walkable
/// span starts one unless its -x neighbour inside the border continues it:
/// any walkable neighbour for the layers, one of the same area for the
/// region partitions (`same_area`).
fn mostRowSweeps(chf: *const recast.CompactHeightfield, border: i32, same_area: bool) i32 {
    var most: i32 = 0;
    var z = border;
    while (z < chf.height - border) : (z += 1) {
        var n: i32 = 0;
        var x = border;
        while (x < chf.width - border) : (x += 1) {
            const cell = chf.cells[@intCast(x + z * chf.width)];
            for (cell.index..cell.index + cell.count) |i| {
                const area = chf.areas[i];
                if (area == recast.null_area) continue;
                const con = recast.getCon(chf.spans[i], 0);
                const continued = x - 1 >= border and con != recast.not_connected and c: {
                    const left = chf.cells[@intCast(x - 1 + z * chf.width)];
                    const left_area = chf.areas[left.index + @as(u32, @intCast(con))];
                    break :c if (same_area) left_area == area else left_area != recast.null_area;
                };
                if (!continued) n += 1;
            }
        }
        most = @max(most, n);
    }
    return most;
}

// The port's side.

/// The port's context, recording as the shim's does, and the steps.
const PortRun = struct {
    recorder: oracle.Recorder = .{},
    trace: *Trace,

    fn context(run: *PortRun) recast.Context {
        return run.recorder.context();
    }

    /// Adds a step with what was logged since the last one.
    fn step(
        run: *PortRun,
        comptime format: []const u8,
        args: anytype,
        ok: bool,
        output: []const u8,
    ) !void {
        if (run.recorder.failed) return error.OutOfMemory;
        try run.trace.add(format, args, ok, run.recorder.text.items, output);
        run.recorder.text.clearRetainingCapacity();
    }

    /// Adds a step whose output is the dump of `object`.
    fn stepDump(
        run: *PortRun,
        comptime format: []const u8,
        args: anytype,
        ok: bool,
        object: anytype,
    ) !void {
        const bytes = try dump(gpa, object);
        defer gpa.free(bytes);
        try run.step(format, args, ok, bytes);
    }
};

fn portCase(case: *const Case, inputs: *const Inputs, trace: *Trace) !void {
    var run: PortRun = .{ .trace = trace };
    defer run.recorder.text.deinit(gpa);
    const ctx = run.context();

    // The bounds of no vertices are undefined.
    if (case.verts.len > 0) {
        var bounds: Bounds = undefined;
        recast.calcBounds(case.verts, &bounds.bmin, &bounds.bmax);
        const grid = recast.calcGridSize(&bounds.bmin, &bounds.bmax, case.tiles[0].cs);
        bounds.width = grid.width;
        bounds.height = grid.height;
        try run.step("bounds", .{}, true, std.mem.asBytes(&bounds));
    }

    const areas = try gpa.dupe(u8, case.areas);
    defer gpa.free(areas);
    recast.markWalkableTriangles(ctx, case.walkable_slope, case.verts, case.tris, areas);
    try run.step("mark walkable", .{}, true, areas);
    if (case.clear_slope) |slope| {
        recast.clearUnwalkableTriangles(ctx, slope, case.verts, case.tris, areas);
        try run.step("clear unwalkable", .{}, true, areas);
    }

    var pmeshes: std.ArrayList(recast.PolyMesh) = .empty;
    defer {
        for (pmeshes.items) |*pmesh| pmesh.deinit(gpa);
        pmeshes.deinit(gpa);
    }
    var dmeshes: std.ArrayList(recast.PolyMeshDetail) = .empty;
    defer {
        for (dmeshes.items) |*dmesh| dmesh.deinit(gpa);
        dmeshes.deinit(gpa);
    }
    for (case.tiles, 0..) |*cfg, t| {
        try portTile(case, inputs, cfg, t, areas, &run, &pmeshes, &dmeshes);
    }

    const pmesh_list = try gpa.alloc(*const recast.PolyMesh, pmeshes.items.len);
    defer gpa.free(pmesh_list);
    for (pmesh_list, pmeshes.items) |*p, *pmesh| p.* = pmesh;
    var merged_pmesh = try recast.mergePolyMeshes(ctx, gpa, pmesh_list);
    defer merged_pmesh.deinit(gpa);
    try run.stepDump("merge polymeshes", .{}, true, &merged_pmesh);

    const dmesh_list = try gpa.alloc(*const recast.PolyMeshDetail, dmeshes.items.len);
    defer gpa.free(dmesh_list);
    for (dmesh_list, dmeshes.items) |*d, *dmesh| d.* = dmesh;
    var merged_dmesh = try recast.mergePolyMeshDetails(ctx, gpa, dmesh_list);
    defer merged_dmesh.deinit(gpa);
    try run.stepDump("merge detail meshes", .{}, true, &merged_dmesh);
}

fn portTile(
    case: *const Case,
    inputs: *const Inputs,
    cfg: *const recast.Config,
    t: usize,
    areas: []const u8,
    run: *PortRun,
    pmeshes: *std.ArrayList(recast.PolyMesh),
    dmeshes: *std.ArrayList(recast.PolyMeshDetail),
) !void {
    const ctx = run.context();
    const climb = cfg.walkable_climb;
    const height = cfg.walkable_height;

    var hf: recast.Heightfield = try .init(
        gpa,
        cfg.width,
        cfg.height,
        &cfg.bmin,
        &cfg.bmax,
        cfg.cs,
        cfg.ch,
    );
    defer hf.deinit(gpa);
    switch (case.raster) {
        .int => {
            const tris = case.tris;
            try recast.rasterizeTriangles(ctx, gpa, case.verts, i32, tris, areas, &hf, climb);
        },
        .u16 => {
            const tris = inputs.tris_u16;
            try recast.rasterizeTriangles(ctx, gpa, case.verts, u16, tris, areas, &hf, climb);
        },
        .unindexed => {
            try recast.rasterizeUnindexedTriangles(ctx, gpa, inputs.flat, areas, &hf, climb);
        },
        .single => for (areas, 0..) |area, i| {
            const v = inputs.flat[i * 9 ..][0..9];
            try recast.rasterizeTriangle(ctx, gpa, v[0..3], v[3..6], v[6..9], area, &hf, climb);
        },
    }
    try run.stepDump("tile {d}: rasterize", .{t}, true, &hf);
    for (case.spans) |span| {
        const x = @mod(span.x, cfg.width);
        const z = @mod(span.z, cfg.height);
        try recast.addSpan(ctx, gpa, &hf, x, z, span.smin, span.smax, span.area, span.merge);
    }
    if (case.spans.len > 0) try run.stepDump("tile {d}: add spans", .{t}, true, &hf);
    for (case.filters, 0..) |on, f| {
        if (!on) continue;
        switch (f) {
            0 => recast.filterLowHangingWalkableObstacles(ctx, climb, &hf),
            1 => recast.filterLedgeSpans(ctx, height, climb, &hf),
            else => recast.filterWalkableLowHeightSpans(ctx, height, &hf),
        }
        try run.stepDump("tile {d}: filter {d}", .{ t, f }, true, &hf);
    }
    const span_count = recast.getHeightFieldSpanCount(ctx, &hf);
    try run.step("tile {d}: span count", .{t}, true, std.mem.asBytes(&span_count));

    var chf = try recast.buildCompactHeightfield(ctx, gpa, height, climb, &hf);
    defer chf.deinit(gpa);
    try run.stepDump("tile {d}: compact", .{t}, true, &chf);
    try recast.erodeWalkableArea(ctx, gpa, cfg.walkable_radius, &chf);
    try run.stepDump("tile {d}: erode", .{t}, true, &chf);
    if (case.median) {
        try recast.medianFilterWalkableArea(ctx, gpa, &chf);
        try run.stepDump("tile {d}: median", .{t}, true, &chf);
    }
    for (case.marks) |mark| switch (mark) {
        .box => |box| {
            recast.markBoxArea(ctx, &box.min, &box.max, box.area, &chf);
            try run.stepDump("tile {d}: mark box", .{t}, true, &chf);
        },
        .convex => |convex| {
            var buffer: [64 * 3]f32 = undefined;
            var poly = convex.verts;
            if (convex.offset != 0) {
                const n: usize = @intCast(recast.offsetPoly(poly, convex.offset, &buffer));
                poly = buffer[0 .. n * 3];
                try run.step("tile {d}: offset poly", .{t}, true, std.mem.sliceAsBytes(poly));
            }
            // A polygon of no vertices has undefined bounds.
            if (poly.len == 0) continue;
            recast.markConvexPolyArea(ctx, poly, convex.min_y, convex.max_y, convex.area, &chf);
            try run.stepDump("tile {d}: mark convex", .{t}, true, &chf);
        },
        .cylinder => |c| {
            recast.markCylinderArea(ctx, &c.pos, c.radius, c.height, c.area, &chf);
            try run.stepDump("tile {d}: mark cylinder", .{t}, true, &chf);
        },
    };
    const border = cfg.border_size;
    const plan: Plan = .of(
        case,
        cfg,
        mostRowSweeps(&chf, border, true),
        mostRowSweeps(&chf, border, false),
    );
    try run.step("tile {d}: plan", .{t}, true, std.mem.asBytes(&plan.bytes()));
    if (plan.layers) {
        if (recast.buildHeightfieldLayers(ctx, gpa, &chf, border, height)) |set| {
            var lset = set;
            defer lset.deinit(gpa);
            try run.stepDump("tile {d}: layers", .{t}, true, &lset);
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            error.RegionIdOverflow, error.LayerOverflow => {
                try run.step("tile {d}: layers", .{t}, false, &.{});
            },
        }
    }

    const min_area = cfg.min_region_area;
    const merge_area = cfg.merge_region_area;
    const regions = switch (plan.partition) {
        .watershed => blk: {
            try recast.buildDistanceField(ctx, gpa, &chf);
            try run.stepDump("tile {d}: distance field", .{t}, true, &chf);
            break :blk recast.buildRegions(ctx, gpa, &chf, border, min_area, merge_area);
        },
        .monotone => recast.buildRegionsMonotone(ctx, gpa, &chf, border, min_area, merge_area),
        .layers => recast.buildLayerRegions(ctx, gpa, &chf, border, min_area),
    };
    regions catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.RegionIdOverflow => return run.step("tile {d}: regions", .{t}, false, &.{}),
    };
    try run.stepDump("tile {d}: regions", .{t}, true, &chf);

    const max_error = cfg.max_simplification_error;
    var cset = try recast.buildContours(ctx, gpa, &chf, max_error, cfg.max_edge_len, case.flags);
    defer cset.deinit(gpa);
    try run.stepDump("tile {d}: contours", .{t}, true, &cset);

    const nvp = cfg.max_verts_per_poly;
    var pmesh = recast.buildPolyMesh(ctx, gpa, &cset, nvp) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.TooManyVertices, error.TooManyPolygons => {
            return run.step("tile {d}: polymesh", .{t}, false, &.{});
        },
    };
    {
        errdefer pmesh.deinit(gpa);
        try run.stepDump("tile {d}: polymesh", .{t}, true, &pmesh);
        try pmeshes.append(gpa, pmesh);
    }
    const kept = &pmeshes.items[pmeshes.items.len - 1];
    {
        var copy = try recast.copyPolyMesh(ctx, gpa, kept);
        defer copy.deinit(gpa);
        try run.stepDump("tile {d}: copy polymesh", .{t}, true, &copy);
    }

    const sample_dist = cfg.detail_sample_dist;
    const sample_error = cfg.detail_sample_max_error;
    var dmesh = try recast.buildPolyMeshDetail(ctx, gpa, kept, &chf, sample_dist, sample_error);
    errdefer dmesh.deinit(gpa);
    try run.stepDump("tile {d}: detail", .{t}, true, &dmesh);
    try dmeshes.append(gpa, dmesh);
}

// The original's side, step for step as the port's.

const OriginalRun = struct {
    log: *upstream.Log,
    trace: *Trace,

    fn step(
        run: *OriginalRun,
        comptime format: []const u8,
        args: anytype,
        ok: bool,
        output: []const u8,
    ) !void {
        try run.trace.add(format, args, ok, upstream.logText(run.log), output);
        upstream.shim_log_clear(run.log);
    }

    fn stepDump(
        run: *OriginalRun,
        comptime format: []const u8,
        args: anytype,
        ok: bool,
        object: anytype,
    ) !void {
        const bytes = try upstream.dump(gpa, object);
        defer gpa.free(bytes);
        try run.step(format, args, ok, bytes);
    }
};

fn originalCase(case: *const Case, inputs: *const Inputs, trace: *Trace) !void {
    upstream.shim_init();
    const log = upstream.shim_log_create() orelse return error.OutOfMemory;
    defer upstream.shim_log_destroy(log);
    var run: OriginalRun = .{ .log = log, .trace = trace };
    const verts = case.verts;
    const tris = case.tris;
    const nv: c_int = @intCast(verts.len / 3);
    const nt: c_int = @intCast(tris.len / 3);

    if (verts.len > 0) {
        var bounds: Bounds = undefined;
        upstream.shim_calc_bounds(verts.ptr, nv, &bounds.bmin, &bounds.bmax);
        const cs = case.tiles[0].cs;
        upstream.shim_calc_grid_size(&bounds.bmin, &bounds.bmax, cs, &bounds.width, &bounds.height);
        try run.step("bounds", .{}, true, std.mem.asBytes(&bounds));
    }

    const areas = try gpa.dupe(u8, case.areas);
    defer gpa.free(areas);
    upstream.shim_mark_walkable(log, case.walkable_slope, verts.ptr, nv, tris.ptr, nt, areas.ptr);
    try run.step("mark walkable", .{}, true, areas);
    if (case.clear_slope) |slope| {
        upstream.shim_clear_unwalkable(log, slope, verts.ptr, nv, tris.ptr, nt, areas.ptr);
        try run.step("clear unwalkable", .{}, true, areas);
    }

    var pmeshes: std.ArrayList(*upstream.PolyMesh) = .empty;
    defer {
        for (pmeshes.items) |pmesh| upstream.shim_polymesh_free(pmesh);
        pmeshes.deinit(gpa);
    }
    var dmeshes: std.ArrayList(*upstream.PolyMeshDetail) = .empty;
    defer {
        for (dmeshes.items) |dmesh| upstream.shim_detail_free(dmesh);
        dmeshes.deinit(gpa);
    }
    for (case.tiles, 0..) |*cfg, t| {
        try originalTile(case, inputs, cfg, t, areas, &run, &pmeshes, &dmeshes);
    }

    const n_pmeshes: c_int = @intCast(pmeshes.items.len);
    if (upstream.shim_polymesh_merge(log, pmeshes.items.ptr, n_pmeshes)) |pmesh| {
        defer upstream.shim_polymesh_free(pmesh);
        try run.stepDump("merge polymeshes", .{}, true, pmesh);
    } else return run.step("merge polymeshes", .{}, false, &.{});
    const n_dmeshes: c_int = @intCast(dmeshes.items.len);
    if (upstream.shim_detail_merge(log, dmeshes.items.ptr, n_dmeshes)) |dmesh| {
        defer upstream.shim_detail_free(dmesh);
        try run.stepDump("merge detail meshes", .{}, true, dmesh);
    } else return run.step("merge detail meshes", .{}, false, &.{});
}

fn originalTile(
    case: *const Case,
    inputs: *const Inputs,
    cfg: *const recast.Config,
    t: usize,
    areas: []const u8,
    run: *OriginalRun,
    pmeshes: *std.ArrayList(*upstream.PolyMesh),
    dmeshes: *std.ArrayList(*upstream.PolyMeshDetail),
) !void {
    const log = run.log;
    const verts = case.verts;
    const nv: c_int = @intCast(verts.len / 3);
    const nt: c_int = @intCast(case.tris.len / 3);
    const climb = cfg.walkable_climb;
    const height = cfg.walkable_height;

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
    const rasterized = switch (case.raster) {
        .int => upstream.shim_rasterize_triangles(
            log,
            verts.ptr,
            nv,
            case.tris.ptr,
            areas.ptr,
            nt,
            hf,
            climb,
        ) != 0,
        .u16 => upstream.shim_rasterize_triangles_u16(
            log,
            verts.ptr,
            nv,
            inputs.tris_u16.ptr,
            areas.ptr,
            nt,
            hf,
            climb,
        ) != 0,
        .unindexed => upstream.shim_rasterize_unindexed(
            log,
            inputs.flat.ptr,
            areas.ptr,
            nt,
            hf,
            climb,
        ) != 0,
        .single => for (areas, 0..) |area, i| {
            const v = inputs.flat[i * 9 ..][0..9];
            const ok = upstream.shim_rasterize_triangle(
                log,
                v[0..3],
                v[3..6],
                v[6..9],
                area,
                hf,
                climb,
            );
            if (ok == 0) break false;
        } else true,
    };
    if (!rasterized) return run.step("tile {d}: rasterize", .{t}, false, &.{});
    try run.stepDump("tile {d}: rasterize", .{t}, true, hf);
    for (case.spans) |span| {
        const x = @mod(span.x, cfg.width);
        const z = @mod(span.z, cfg.height);
        const added = upstream.shim_add_span(
            log,
            hf,
            x,
            z,
            span.smin,
            span.smax,
            span.area,
            span.merge,
        );
        if (added == 0) return run.step("tile {d}: add spans", .{t}, false, &.{});
    }
    if (case.spans.len > 0) try run.stepDump("tile {d}: add spans", .{t}, true, hf);
    for (case.filters, 0..) |on, f| {
        if (!on) continue;
        switch (f) {
            0 => upstream.shim_filter_low_hanging(log, climb, hf),
            1 => upstream.shim_filter_ledge(log, height, climb, hf),
            else => upstream.shim_filter_low_height(log, height, hf),
        }
        try run.stepDump("tile {d}: filter {d}", .{ t, f }, true, hf);
    }
    const span_count: i32 = upstream.shim_hf_span_count(log, hf);
    try run.step("tile {d}: span count", .{t}, true, std.mem.asBytes(&span_count));

    const chf = upstream.shim_chf_build(log, height, climb, hf) orelse
        return run.step("tile {d}: compact", .{t}, false, &.{});
    defer upstream.shim_chf_free(chf);
    try run.stepDump("tile {d}: compact", .{t}, true, chf);
    if (upstream.shim_erode(log, cfg.walkable_radius, chf) == 0) {
        return run.step("tile {d}: erode", .{t}, false, &.{});
    }
    try run.stepDump("tile {d}: erode", .{t}, true, chf);
    if (case.median) {
        if (upstream.shim_median(log, chf) == 0) {
            return run.step("tile {d}: median", .{t}, false, &.{});
        }
        try run.stepDump("tile {d}: median", .{t}, true, chf);
    }
    for (case.marks) |mark| switch (mark) {
        .box => |box| {
            upstream.shim_mark_box(log, &box.min, &box.max, box.area, chf);
            try run.stepDump("tile {d}: mark box", .{t}, true, chf);
        },
        .convex => |convex| {
            var buffer: [64 * 3]f32 = undefined;
            var poly = convex.verts;
            if (convex.offset != 0) {
                const n_in: c_int = @intCast(poly.len / 3);
                const offset = convex.offset;
                const count = upstream.shim_offset_poly(poly.ptr, n_in, offset, &buffer, 64);
                const n: usize = @intCast(count);
                poly = buffer[0 .. n * 3];
                try run.step("tile {d}: offset poly", .{t}, true, std.mem.sliceAsBytes(poly));
            }
            if (poly.len == 0) continue;
            const n_verts: c_int = @intCast(poly.len / 3);
            const min_y = convex.min_y;
            const max_y = convex.max_y;
            upstream.shim_mark_convex(log, poly.ptr, n_verts, min_y, max_y, convex.area, chf);
            try run.stepDump("tile {d}: mark convex", .{t}, true, chf);
        },
        .cylinder => |c| {
            upstream.shim_mark_cylinder(log, &c.pos, c.radius, c.height, c.area, chf);
            try run.stepDump("tile {d}: mark cylinder", .{t}, true, chf);
        },
    };
    const border = cfg.border_size;
    const plan: Plan = .of(
        case,
        cfg,
        upstream.shim_chf_most_row_sweeps(chf, border, 1),
        upstream.shim_chf_most_row_sweeps(chf, border, 0),
    );
    try run.step("tile {d}: plan", .{t}, true, std.mem.asBytes(&plan.bytes()));
    if (plan.layers) {
        if (upstream.shim_layers_build(log, chf, border, height)) |lset| {
            defer upstream.shim_layers_free(lset);
            try run.stepDump("tile {d}: layers", .{t}, true, lset);
        } else try run.step("tile {d}: layers", .{t}, false, &.{});
    }

    const min_area = cfg.min_region_area;
    const merge_area = cfg.merge_region_area;
    const regions = switch (plan.partition) {
        .watershed => blk: {
            if (upstream.shim_distance_field(log, chf) == 0) {
                return run.step("tile {d}: distance field", .{t}, false, &.{});
            }
            try run.stepDump("tile {d}: distance field", .{t}, true, chf);
            break :blk upstream.shim_regions(log, chf, border, min_area, merge_area);
        },
        .monotone => upstream.shim_regions_monotone(log, chf, border, min_area, merge_area),
        .layers => upstream.shim_layer_regions(log, chf, border, min_area),
    };
    if (regions == 0) return run.step("tile {d}: regions", .{t}, false, &.{});
    try run.stepDump("tile {d}: regions", .{t}, true, chf);

    const flags: c_int = @bitCast(case.flags);
    const max_error = cfg.max_simplification_error;
    const cset = upstream.shim_contours_build(log, chf, max_error, cfg.max_edge_len, flags) orelse
        return run.step("tile {d}: contours", .{t}, false, &.{});
    defer upstream.shim_contours_free(cset);
    try run.stepDump("tile {d}: contours", .{t}, true, cset);

    const pmesh = upstream.shim_polymesh_build(log, cset, cfg.max_verts_per_poly) orelse
        return run.step("tile {d}: polymesh", .{t}, false, &.{});
    {
        errdefer upstream.shim_polymesh_free(pmesh);
        try run.stepDump("tile {d}: polymesh", .{t}, true, pmesh);
        try pmeshes.append(gpa, pmesh);
    }
    if (upstream.shim_polymesh_copy(log, pmesh)) |copy| {
        defer upstream.shim_polymesh_free(copy);
        try run.stepDump("tile {d}: copy polymesh", .{t}, true, copy);
    } else return run.step("tile {d}: copy polymesh", .{t}, false, &.{});

    const sample_dist = cfg.detail_sample_dist;
    const sample_error = cfg.detail_sample_max_error;
    const dmesh = upstream.shim_detail_build(log, pmesh, chf, sample_dist, sample_error) orelse
        return run.step("tile {d}: detail", .{t}, false, &.{});
    errdefer upstream.shim_detail_free(dmesh);
    try run.stepDump("tile {d}: detail", .{t}, true, dmesh);
    try dmeshes.append(gpa, dmesh);
}
