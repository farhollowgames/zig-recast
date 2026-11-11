// An altered version of Recast from recastnavigation 1.6.0, translated to
// Zig. Copyright (c) 2009-2010 Mikko Mononen memon@inside.org; zlib licence,
// see LICENSE.

//! Recast builds navigation meshes from triangle meshes: it voxelizes the
//! triangles into a heightfield, finds the walkable surface, splits it into
//! regions, traces their contours and turns them into convex polygons, with
//! a detail mesh that follows the surface's height.
//!
//! A translation of Recast from recastnavigation 1.6.0 by Mikko Mononen,
//! with the same output for the same input. The build steps, in order:
//!
//! 1. `Heightfield.init`, then `markWalkableTriangles` and
//!    `rasterizeTriangles` to fill it with spans;
//! 2. `filterLowHangingWalkableObstacles`, `filterLedgeSpans` and
//!    `filterWalkableLowHeightSpans`;
//! 3. `buildCompactHeightfield`, then `erodeWalkableArea` and the
//!    `mark…Area` functions;
//! 4. `buildDistanceField` and `buildRegions` (or `buildRegionsMonotone`,
//!    `buildLayerRegions`);
//! 5. `buildContours`, `buildPolyMesh` and `buildPolyMeshDetail`.
//!
//! Every step takes a `Context` for its log and timers, and an allocator
//! for what it builds and its scratch memory.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const context = @import("context.zig");
const rasterization = @import("rasterization.zig");
const filter = @import("filter.zig");
const area = @import("area.zig");
const region = @import("region.zig");
const contour = @import("contour.zig");
const mesh = @import("mesh.zig");
const mesh_detail = @import("mesh_detail.zig");
const layers = @import("layers.zig");

pub const Context = context.Context;
pub const LogCategory = context.LogCategory;
pub const TimerLabel = context.TimerLabel;
pub const max_timers = context.max_timers;

pub const RasterizeError = rasterization.RasterizeError;
pub const addSpan = rasterization.addSpan;
pub const rasterizeTriangle = rasterization.rasterizeTriangle;
pub const rasterizeTriangles = rasterization.rasterizeTriangles;
pub const rasterizeUnindexedTriangles = rasterization.rasterizeUnindexedTriangles;

pub const filterLowHangingWalkableObstacles = filter.filterLowHangingWalkableObstacles;
pub const filterLedgeSpans = filter.filterLedgeSpans;
pub const filterWalkableLowHeightSpans = filter.filterWalkableLowHeightSpans;

pub const erodeWalkableArea = area.erodeWalkableArea;
pub const medianFilterWalkableArea = area.medianFilterWalkableArea;
pub const markBoxArea = area.markBoxArea;
pub const markConvexPolyArea = area.markConvexPolyArea;
pub const offsetPoly = area.offsetPoly;
pub const markCylinderArea = area.markCylinderArea;

pub const buildDistanceField = region.buildDistanceField;
pub const buildRegions = region.buildRegions;
pub const buildLayerRegions = region.buildLayerRegions;
pub const buildRegionsMonotone = region.buildRegionsMonotone;

pub const buildContours = contour.buildContours;

pub const buildPolyMesh = mesh.buildPolyMesh;
pub const mergePolyMeshes = mesh.mergePolyMeshes;
pub const copyPolyMesh = mesh.copyPolyMesh;

pub const buildPolyMeshDetail = mesh_detail.buildPolyMeshDetail;
pub const mergePolyMeshDetails = mesh_detail.mergePolyMeshDetails;

pub const buildHeightfieldLayers = layers.buildHeightfieldLayers;

/// Recast's value of pi, used for slope angles.
pub const pi: f32 = 3.14159265;

/// The number of bits of a span's lower and upper limits.
pub const span_height_bits = 13;
/// The largest value of a span's limits.
pub const span_max_height: i32 = (1 << span_height_bits) - 1;
/// The number of spans allocated together in a heightfield's pool.
pub const spans_per_pool = 2048;
/// How far from the origin, in cells, the x and z of a rasterized
/// triangle's vertices must stay. Past it a cell is only a few float steps
/// wide, and rounding while clipping a triangle to the cells can make
/// polygons of more vertices than the clipping's buffers hold.
pub const vertex_cells_max = 1 << 22;

/// Marks a region id as a border region: it is not part of the navmesh.
pub const border_reg: u16 = 0x8000;
/// Marks a polygon of a layer region shared by several regions.
pub const multiple_regs: u16 = 0;
/// Marks a contour vertex on the tile border, for polygon simplification
/// that keeps tile borders straight.
pub const border_vertex: i32 = 0x10000;
/// Marks a contour vertex where the area changes.
pub const area_border: i32 = 0x20000;
/// The bits of a contour vertex's fourth value that hold the region id.
pub const contour_reg_mask: i32 = 0xffff;
/// An unused polygon vertex index or neighbor.
pub const mesh_null_idx: u16 = 0xffff;
/// The area id of unwalkable spans, triangles and polygons.
pub const null_area: u8 = 0;
/// The area id walkable triangles get by default; also the largest id.
pub const walkable_area: u8 = 63;
/// A compact span's connection value for no neighbor.
pub const not_connected: i32 = 0x3f;

/// The settings of a build. Recast's functions take the values they need as
/// parameters; this holds them in one place, as upstream's `rcConfig` does.
pub const Config = struct {
    /// The width of the field along the x-axis, in cells.
    width: i32 = 0,
    /// The height of the field along the z-axis, in cells.
    height: i32 = 0,
    /// The width and height of a tile on the xz-plane, in cells.
    tile_size: i32 = 0,
    /// The size of the border around the field's bounds, in cells.
    border_size: i32 = 0,
    /// The size of a cell on the xz-plane, in world units.
    cs: f32 = 0,
    /// The height of a cell along the y-axis, in world units.
    ch: f32 = 0,
    bmin: [3]f32 = .{ 0, 0, 0 },
    bmax: [3]f32 = .{ 0, 0, 0 },
    /// The steepest walkable slope, in degrees.
    walkable_slope_angle: f32 = 0,
    /// The lowest ceiling an agent can stand under, in cells.
    walkable_height: i32 = 0,
    /// The highest ledge an agent can climb, in cells.
    walkable_climb: i32 = 0,
    /// The agent's radius, in cells.
    walkable_radius: i32 = 0,
    /// The longest contour edge on the mesh border, in cells.
    max_edge_len: i32 = 0,
    /// How far a simplified contour may stray from the raw one, in cells.
    max_simplification_error: f32 = 0,
    /// The smallest isolated region kept, in cells.
    min_region_area: i32 = 0,
    /// Regions smaller than this merge into larger ones, in cells.
    merge_region_area: i32 = 0,
    /// The most vertices a polygon may have.
    max_verts_per_poly: i32 = 0,
    /// The distance between height samples of the detail mesh, in world
    /// units.
    detail_sample_dist: f32 = 0,
    /// How far the detail mesh may stray from the heightfield, in world
    /// units.
    detail_sample_max_error: f32 = 0,
};

/// A run of solid voxels in a heightfield column.
pub const Span = struct {
    /// The lower limit, inclusive.
    smin: u13,
    /// The upper limit, exclusive.
    smax: u13,
    area: u6,
    /// The next span up the column, or null.
    next: ?*Span,
};

/// Spans allocated together. A heightfield gets its spans from these.
pub const SpanPool = struct {
    next: ?*SpanPool,
    items: [spans_per_pool]Span,
};

/// A voxel grid of solid spans, filled by rasterizing triangles.
pub const Heightfield = struct {
    /// The size along the x-axis, in cells.
    width: i32,
    /// The size along the z-axis, in cells.
    height: i32,
    bmin: [3]f32,
    bmax: [3]f32,
    /// The size of a cell on the xz-plane.
    cs: f32,
    /// The height of a cell along the y-axis.
    ch: f32,
    /// The lowest span of each column, or null, at `x + z * width`. A span
    /// pointer stays valid until `deinit`; a span removed from a column goes
    /// to `freelist` and the next added span reuses it.
    spans: []?*Span,
    /// The pools all spans live in.
    pools: ?*SpanPool = null,
    /// Spans free for reuse.
    freelist: ?*Span = null,

    /// An empty heightfield of `width` by `height` columns.
    pub fn init(
        gpa: Allocator,
        width: i32,
        height: i32,
        bmin: *const [3]f32,
        bmax: *const [3]f32,
        cs: f32,
        ch: f32,
    ) Allocator.Error!Heightfield {
        const spans = try gpa.alloc(?*Span, @intCast(width * height));
        @memset(spans, null);
        return .{
            .width = width,
            .height = height,
            .bmin = bmin.*,
            .bmax = bmax.*,
            .cs = cs,
            .ch = ch,
            .spans = spans,
        };
    }

    pub fn deinit(hf: *Heightfield, gpa: Allocator) void {
        gpa.free(hf.spans);
        var pool = hf.pools;
        while (pool) |p| {
            pool = p.next;
            gpa.destroy(p);
        }
        hf.* = undefined;
    }
};

/// A column of a compact heightfield: its spans are `count` spans from
/// `index` in the compact heightfield's spans.
pub const CompactCell = packed struct(u32) {
    index: u24,
    count: u8,
};

/// The open space above a solid span.
pub const CompactSpan = packed struct(u64) {
    /// The lower extent, from the heightfield's base.
    y: u16,
    /// The region id, or 0 for none.
    reg: u16,
    /// The neighbor in each direction: 6 bits each, the index of the span in
    /// the neighbor column, or `not_connected`.
    con: u24,
    /// The height, from `y`.
    h: u8,
};

/// The walkable open space of a heightfield, as spans with their neighbors.
pub const CompactHeightfield = struct {
    /// The size along the x-axis, in cells.
    width: i32,
    /// The size along the z-axis, in cells.
    height: i32,
    span_count: i32,
    walkable_height: i32,
    walkable_climb: i32,
    /// The border size the regions were built with.
    border_size: i32,
    /// The largest distance of a span to the border.
    max_distance: u16,
    /// The largest region id in use.
    max_regions: u16,
    bmin: [3]f32,
    bmax: [3]f32,
    /// The size of a cell on the xz-plane.
    cs: f32,
    /// The height of a cell along the y-axis.
    ch: f32,
    /// The columns, at `x + z * width`.
    cells: []CompactCell,
    spans: []CompactSpan,
    /// Each span's distance to the border; empty until `buildDistanceField`.
    dist: []u16,
    /// Each span's area id.
    areas: []u8,

    pub fn deinit(chf: *CompactHeightfield, gpa: Allocator) void {
        gpa.free(chf.cells);
        gpa.free(chf.spans);
        gpa.free(chf.dist);
        gpa.free(chf.areas);
        chf.* = undefined;
    }
};

/// One layer of a heightfield layer set: a 2D grid of heights where no two
/// walkable surfaces overlap.
pub const HeightfieldLayer = struct {
    bmin: [3]f32,
    bmax: [3]f32,
    /// The size of a cell on the xz-plane.
    cs: f32,
    /// The height of a cell along the y-axis.
    ch: f32,
    /// The size along the x-axis, in cells.
    width: i32,
    /// The size along the z-axis, in cells.
    height: i32,
    /// The bounds of the cells in use.
    minx: i32,
    maxx: i32,
    miny: i32,
    maxy: i32,
    /// The bounds of the heights in use.
    hmin: i32,
    hmax: i32,
    /// The height of each cell, 0xff for none, at `x + y * width`.
    heights: []u8,
    /// The area id of each cell.
    areas: []u8,
    /// Each cell's connections: the low 4 bits for neighbors in the layer,
    /// the high 4 bits for portals to other layers.
    cons: []u8,
};

pub const HeightfieldLayerSet = struct {
    layers: []HeightfieldLayer,

    pub fn deinit(lset: *HeightfieldLayerSet, gpa: Allocator) void {
        for (lset.layers) |*layer| {
            gpa.free(layer.heights);
            gpa.free(layer.areas);
            gpa.free(layer.cons);
        }
        gpa.free(lset.layers);
        lset.* = undefined;
    }
};

/// A region's outline.
pub const Contour = struct {
    /// The simplified outline: x, y, z and flags of each vertex.
    verts: []i32,
    nverts: i32,
    /// The raw outline: x, y, z and flags of each vertex.
    rverts: []i32,
    nrverts: i32,
    /// The region id.
    reg: u16,
    /// The area id.
    area: u8,
};

pub const ContourSet = struct {
    /// The contours; only the first `nconts` are set.
    conts: []Contour,
    nconts: i32,
    bmin: [3]f32,
    bmax: [3]f32,
    /// The size of a cell on the xz-plane.
    cs: f32,
    /// The height of a cell along the y-axis.
    ch: f32,
    /// The size along the x-axis, in cells.
    width: i32,
    /// The size along the z-axis, in cells.
    height: i32,
    border_size: i32,
    /// The error the contours were simplified with.
    max_error: f32,

    pub fn deinit(cset: *ContourSet, gpa: Allocator) void {
        for (cset.conts[0..@intCast(cset.nconts)]) |*cont| {
            gpa.free(cont.verts);
            gpa.free(cont.rverts);
        }
        gpa.free(cset.conts);
        cset.* = undefined;
    }
};

/// Convex polygons over the walkable surface, with their neighbors.
pub const PolyMesh = struct {
    /// The vertices, x, y and z in cells; the first `nverts` are set.
    verts: []u16,
    /// Each polygon's `nvp` vertex indices then `nvp` neighbor polygon
    /// indices, `mesh_null_idx` for unused entries; `maxpolys` polygons.
    polys: []u16,
    /// The region id of each polygon.
    regs: []u16,
    /// The flags of each polygon, for the caller to set.
    flags: []u16,
    /// The area id of each polygon.
    areas: []u8,
    nverts: i32,
    npolys: i32,
    maxpolys: i32,
    /// The most vertices a polygon has.
    nvp: i32,
    bmin: [3]f32,
    bmax: [3]f32,
    /// The size of a cell on the xz-plane.
    cs: f32,
    /// The height of a cell along the y-axis.
    ch: f32,
    border_size: i32,
    /// The error the polygon edges were simplified with.
    max_edge_error: f32,

    /// A mesh with nothing in it.
    pub const empty: PolyMesh = .{
        .verts = &.{},
        .polys = &.{},
        .regs = &.{},
        .flags = &.{},
        .areas = &.{},
        .nverts = 0,
        .npolys = 0,
        .maxpolys = 0,
        .nvp = 0,
        .bmin = .{ 0, 0, 0 },
        .bmax = .{ 0, 0, 0 },
        .cs = 0,
        .ch = 0,
        .border_size = 0,
        .max_edge_error = 0,
    };

    pub fn deinit(pmesh: *PolyMesh, gpa: Allocator) void {
        gpa.free(pmesh.verts);
        gpa.free(pmesh.polys);
        gpa.free(pmesh.regs);
        gpa.free(pmesh.flags);
        gpa.free(pmesh.areas);
        pmesh.* = undefined;
    }
};

/// Triangles that follow the surface's height, a sub-mesh per polygon of a
/// poly mesh.
pub const PolyMeshDetail = struct {
    /// Each sub-mesh's first vertex, vertex count, first triangle and
    /// triangle count; the first `nmeshes` are set.
    meshes: []u32,
    /// The vertices, x, y and z in world units; the first `nverts` are set.
    verts: []f32,
    /// Each triangle's three vertex indices into its sub-mesh and edge
    /// flags; the first `ntris` are set.
    tris: []u8,
    nmeshes: i32,
    nverts: i32,
    ntris: i32,

    /// A detail mesh with nothing in it.
    pub const empty: PolyMeshDetail = .{
        .meshes = &.{},
        .verts = &.{},
        .tris = &.{},
        .nmeshes = 0,
        .nverts = 0,
        .ntris = 0,
    };

    pub fn deinit(dmesh: *PolyMeshDetail, gpa: Allocator) void {
        gpa.free(dmesh.meshes);
        gpa.free(dmesh.verts);
        gpa.free(dmesh.tris);
        dmesh.* = undefined;
    }
};

/// What contour simplification tessellates.
pub const ContourBuildFlags = packed struct(u32) {
    /// Splits solid edges longer than the maximum edge length.
    tess_wall_edges: bool = false,
    /// Splits edges between areas longer than the maximum edge length.
    tess_area_edges: bool = false,
    _: u30 = 0,

    /// Upstream's default: only wall edges.
    pub const default: ContourBuildFlags = .{ .tess_wall_edges = true };
};

/// `a < b ? a : b`, as upstream's `rcMin`: on equal or unordered values it
/// gives `b`, where `@min` may give either zero or the non-NaN value.
pub fn selectMin(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}

/// `a > b ? a : b`, as upstream's `rcMax`.
pub fn selectMax(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

/// C's `(int)x` as x86-64 computes it: toward zero, and the most negative
/// int for NaN and values out of range, where C leaves the result undefined.
pub fn truncateToInt(x: f32) i32 {
    if (x >= -2147483648.0 and x < 2147483648.0) return @intFromFloat(x);
    return std.math.minInt(i32);
}

/// Upstream's `rcClamp`, which unlike `std.math.clamp` allows `min > max`:
/// then a value below `min` gives `min` and any other `max`.
pub fn clamp(comptime T: type, value: T, min: T, max: T) T {
    return if (value < min) min else if (value > max) max else value;
}

pub fn vcross(v1: *const [3]f32, v2: *const [3]f32) [3]f32 {
    return .{
        v1[1] * v2[2] - v1[2] * v2[1],
        v1[2] * v2[0] - v1[0] * v2[2],
        v1[0] * v2[1] - v1[1] * v2[0],
    };
}

pub fn vdot(v1: *const [3]f32, v2: *const [3]f32) f32 {
    return v1[0] * v2[0] + v1[1] * v2[1] + v1[2] * v2[2];
}

/// `v1 + v2 * s`.
pub fn vmad(v1: *const [3]f32, v2: *const [3]f32, s: f32) [3]f32 {
    return .{ v1[0] + v2[0] * s, v1[1] + v2[1] * s, v1[2] + v2[2] * s };
}

pub fn vadd(v1: *const [3]f32, v2: *const [3]f32) [3]f32 {
    return .{ v1[0] + v2[0], v1[1] + v2[1], v1[2] + v2[2] };
}

pub fn vsub(v1: *const [3]f32, v2: *const [3]f32) [3]f32 {
    return .{ v1[0] - v2[0], v1[1] - v2[1], v1[2] - v2[2] };
}

/// Lowers each component of `mn` to `v`'s where `v`'s is smaller.
pub fn vmin(mn: *[3]f32, v: *const [3]f32) void {
    mn[0] = selectMin(mn[0], v[0]);
    mn[1] = selectMin(mn[1], v[1]);
    mn[2] = selectMin(mn[2], v[2]);
}

/// Raises each component of `mx` to `v`'s where `v`'s is larger.
pub fn vmax(mx: *[3]f32, v: *const [3]f32) void {
    mx[0] = selectMax(mx[0], v[0]);
    mx[1] = selectMax(mx[1], v[1]);
    mx[2] = selectMax(mx[2], v[2]);
}

pub fn vdist(v1: *const [3]f32, v2: *const [3]f32) f32 {
    return @sqrt(vdistSqr(v1, v2));
}

pub fn vdistSqr(v1: *const [3]f32, v2: *const [3]f32) f32 {
    const dx = v2[0] - v1[0];
    const dy = v2[1] - v1[1];
    const dz = v2[2] - v1[2];
    return dx * dx + dy * dy + dz * dz;
}

pub fn vnormalize(v: *[3]f32) void {
    const d = 1.0 / @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    v[0] *= d;
    v[1] *= d;
    v[2] *= d;
}

/// Sets the neighbor of `span` in direction `dir` to the span at
/// `neighbor_index` in the neighbor column, or `not_connected`.
pub fn setCon(span: *CompactSpan, dir: u2, neighbor_index: i32) void {
    const shift = @as(u5, dir) * 6;
    const con: u32 = span.con;
    const index: u32 = @as(u32, @bitCast(neighbor_index)) & 0x3f;
    span.con = @truncate((con & ~(@as(u32, 0x3f) << shift)) | (index << shift));
}

/// The neighbor of `span` in direction `dir`: an index into the neighbor
/// column's spans, or `not_connected`.
pub fn getCon(span: CompactSpan, dir: u2) i32 {
    const shift = @as(u5, dir) * 6;
    return @intCast((@as(u32, span.con) >> shift) & 0x3f);
}

/// The x offset of the neighbor in direction `dir`: west, north, east and
/// south are 0 to 3.
pub fn getDirOffsetX(dir: u2) i32 {
    const offset = [4]i32{ -1, 0, 1, 0 };
    return offset[dir];
}

/// The z offset of the neighbor in direction `dir`.
pub fn getDirOffsetY(dir: u2) i32 {
    const offset = [4]i32{ 0, 1, 0, -1 };
    return offset[dir];
}

/// The direction of a neighbor offset by one cell on one axis, or -1 for no
/// offset.
pub fn getDirForOffset(offset_x: i32, offset_z: i32) i32 {
    const dirs = [5]i32{ 3, 0, -1, 2, 1 };
    return dirs[@intCast(((offset_z + 1) << 1) + offset_x)];
}

/// The bounds of `verts`, x, y and z per vertex; there must be at least one.
pub fn calcBounds(verts: []const f32, bmin: *[3]f32, bmax: *[3]f32) void {
    bmin.* = verts[0..3].*;
    bmax.* = verts[0..3].*;
    var i: usize = 3;
    while (i + 3 <= verts.len) : (i += 3) {
        const v = verts[i..][0..3];
        vmin(bmin, v);
        vmax(bmax, v);
    }
}

pub const GridSize = struct {
    /// Along the x-axis.
    width: i32,
    /// Along the z-axis.
    height: i32,
};

/// The number of cells of size `cs` that cover the bounds on the xz-plane.
pub fn calcGridSize(bmin: *const [3]f32, bmax: *const [3]f32, cs: f32) GridSize {
    return .{
        .width = truncateToInt((bmax[0] - bmin[0]) / cs + 0.5),
        .height = truncateToInt((bmax[2] - bmin[2]) / cs + 0.5),
    };
}

fn calcTriNormal(v0: *const [3]f32, v1: *const [3]f32, v2: *const [3]f32) [3]f32 {
    const e0 = vsub(v1, v0);
    const e1 = vsub(v2, v0);
    var normal = vcross(&e0, &e1);
    vnormalize(&normal);
    return normal;
}

/// Sets the area id of each triangle no steeper than `walkable_slope_angle`
/// degrees to `walkable_area`, leaving the others. `tris` holds three
/// vertex indices per triangle, `tri_area_ids` an id per triangle.
pub fn markWalkableTriangles(
    ctx: Context,
    walkable_slope_angle: f32,
    verts: []const f32,
    tris: []const i32,
    tri_area_ids: []u8,
) void {
    _ = ctx;
    assert(tris.len == tri_area_ids.len * 3);
    const walkable_thr = @cos(walkable_slope_angle / 180.0 * pi);
    for (tri_area_ids, 0..) |*id, i| {
        const normal = triangleNormal(verts, tris[i * 3 ..][0..3]);
        if (normal[1] > walkable_thr) id.* = walkable_area;
    }
}

/// Sets the area id of each triangle steeper than `walkable_slope_angle`
/// degrees to `null_area`, leaving the others.
pub fn clearUnwalkableTriangles(
    ctx: Context,
    walkable_slope_angle: f32,
    verts: []const f32,
    tris: []const i32,
    tri_area_ids: []u8,
) void {
    _ = ctx;
    assert(tris.len == tri_area_ids.len * 3);
    const walkable_limit_y = @cos(walkable_slope_angle / 180.0 * pi);
    for (tri_area_ids, 0..) |*id, i| {
        const normal = triangleNormal(verts, tris[i * 3 ..][0..3]);
        if (normal[1] <= walkable_limit_y) id.* = null_area;
    }
}

fn triangleNormal(verts: []const f32, tri: *const [3]i32) [3]f32 {
    const v0 = verts[@intCast(tri[0] * 3)..][0..3];
    const v1 = verts[@intCast(tri[1] * 3)..][0..3];
    const v2 = verts[@intCast(tri[2] * 3)..][0..3];
    return calcTriNormal(v0, v1, v2);
}

/// The number of walkable spans in the heightfield.
pub fn getHeightFieldSpanCount(ctx: Context, hf: *const Heightfield) i32 {
    _ = ctx;
    var span_count: i32 = 0;
    for (hf.spans) |column| {
        var span = column;
        while (span) |s| : (span = s.next) {
            if (s.area != null_area) span_count += 1;
        }
    }
    return span_count;
}

/// The open space above the walkable spans of `hf`, with each span's
/// neighbors: a neighbor is a span in the next column whose open space
/// overlaps by at least `walkable_height` and whose floor is at most
/// `walkable_climb` away.
pub fn buildCompactHeightfield(
    ctx: Context,
    gpa: Allocator,
    walkable_height: i32,
    walkable_climb: i32,
    hf: *const Heightfield,
) Allocator.Error!CompactHeightfield {
    ctx.startTimer(.build_compactheightfield);
    defer ctx.stopTimer(.build_compactheightfield);

    const x_size = hf.width;
    const z_size = hf.height;
    const span_count = getHeightFieldSpanCount(ctx, hf);

    var bmax = hf.bmax;
    bmax[1] += @as(f32, @floatFromInt(walkable_height)) * hf.ch;
    const cells = gpa.alloc(CompactCell, @intCast(x_size * z_size)) catch |err| {
        ctx.log(
            .err,
            "rcBuildCompactHeightfield: Out of memory 'chf.cells' ({d})",
            .{x_size * z_size},
        );
        return err;
    };
    errdefer gpa.free(cells);
    @memset(cells, .{ .index = 0, .count = 0 });
    const spans = gpa.alloc(CompactSpan, @intCast(span_count)) catch |err| {
        ctx.log(.err, "rcBuildCompactHeightfield: Out of memory 'chf.spans' ({d})", .{span_count});
        return err;
    };
    errdefer gpa.free(spans);
    @memset(spans, .{ .y = 0, .reg = 0, .con = 0, .h = 0 });
    const areas = gpa.alloc(u8, @intCast(span_count)) catch |err| {
        ctx.log(.err, "rcBuildCompactHeightfield: Out of memory 'chf.areas' ({d})", .{span_count});
        return err;
    };
    @memset(areas, null_area);

    const max_height = 0xffff;

    // Fill in cells and spans.
    var current_cell_index: u32 = 0;
    for (hf.spans, cells) |column, *cell| {
        // A column with no spans keeps index 0 and count 0.
        var span = column orelse continue;
        const first = current_cell_index;
        var count: u8 = 0;
        while (true) {
            if (span.area != null_area) {
                const bot: i32 = span.smax;
                const top: i32 = if (span.next) |next| next.smin else max_height;
                spans[current_cell_index].y = @intCast(clamp(i32, bot, 0, 0xffff));
                spans[current_cell_index].h = @intCast(clamp(i32, top - bot, 0, 0xff));
                areas[current_cell_index] = span.area;
                current_cell_index += 1;
                count +%= 1;
            }
            span = span.next orelse break;
        }
        cell.* = .{ .index = @truncate(first), .count = count };
    }

    // Find neighbour connections.
    const max_layers = not_connected - 1;
    var max_layer_index: i32 = 0;
    const width: usize = @intCast(x_size);
    for (0..@intCast(z_size)) |z| {
        for (0..width) |x| {
            const cell = cells[x + z * width];
            for (spans[cell.index..][0..cell.count]) |*span| {
                const y: i32 = span.y;
                const y_top = y + span.h;
                // Not connected in every direction, until a neighbour is.
                var con: u24 = 0xffffff;
                inline for (0..4) |dir| {
                    const shift = dir * 6;
                    const neighbor_x = @as(i32, @intCast(x)) + comptime getDirOffsetX(dir);
                    const neighbor_z = @as(i32, @intCast(z)) + comptime getDirOffsetY(dir);
                    // First check that the neighbour cell is in bounds.
                    if (neighbor_x >= 0 and neighbor_z >= 0 and
                        neighbor_x < x_size and neighbor_z < z_size)
                    {
                        // Find the first neighbour span reachable from
                        // this one.
                        const neighbor_cell = cells[@intCast(neighbor_x + neighbor_z * x_size)];
                        const column = spans[neighbor_cell.index..][0..neighbor_cell.count];
                        for (column, 0..) |neighbor_span, layer_index| {
                            const neighbor_y: i32 = neighbor_span.y;
                            const bot = @max(y, neighbor_y);
                            const top = @min(y_top, neighbor_y + neighbor_span.h);
                            // The gap must be tall enough and the climb
                            // low enough.
                            const climb = neighbor_y - y;
                            if (top - bot >= walkable_height and @abs(climb) <= walkable_climb) {
                                if (layer_index > max_layers) {
                                    const index: i32 = @intCast(layer_index);
                                    max_layer_index = @max(max_layer_index, index);
                                    continue;
                                }
                                const index: u24 = @intCast(layer_index);
                                con = (con & ~(@as(u24, 0x3f) << shift)) | (index << shift);
                                break;
                            }
                        }
                    }
                }
                span.con = con;
            }
        }
    }

    if (max_layer_index > max_layers) {
        ctx.log(
            .err,
            "rcBuildCompactHeightfield: Heightfield has too many layers {d} (max: {d})",
            .{ max_layer_index, max_layers },
        );
    }

    return .{
        .width = x_size,
        .height = z_size,
        .span_count = span_count,
        .walkable_height = walkable_height,
        .walkable_climb = walkable_climb,
        .border_size = 0,
        .max_distance = 0,
        .max_regions = 0,
        .bmin = hf.bmin,
        .bmax = bmax,
        .cs = hf.cs,
        .ch = hf.ch,
        .cells = cells,
        .spans = spans,
        .dist = &.{},
        .areas = areas,
    };
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test {
    _ = context;
    _ = rasterization;
    _ = filter;
    _ = area;
    _ = region;
    _ = contour;
    _ = mesh;
    _ = mesh_detail;
    _ = layers;
}

test "connections pack six bits per direction" {
    var span: CompactSpan = .{ .y = 0, .reg = 0, .con = 0, .h = 0 };
    for ([4]u2{ 0, 1, 2, 3 }) |dir| setCon(&span, dir, not_connected);
    try testing.expectEqual(0xffffff, span.con);
    setCon(&span, 2, 5);
    try testing.expectEqual(5, getCon(span, 2));
    try testing.expectEqual(not_connected, getCon(span, 1));
    try testing.expectEqual(0, getDirForOffset(-1, 0));
    try testing.expectEqual(3, getDirForOffset(0, -1));
    try testing.expectEqual(-1, getDirForOffset(0, 0));
}
