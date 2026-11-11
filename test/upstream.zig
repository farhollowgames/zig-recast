//! The original Recast, built from source for the tests and the benchmark,
//! through the C interface in `shim/recast_shim.cpp`. Each handle is the
//! original's object; free it with its `free` function.

const std = @import("std");

/// A recording `rcContext`: its log messages and timer calls as text.
pub const Log = opaque {};
pub const Heightfield = opaque {};
pub const CompactHeightfield = opaque {};
pub const LayerSet = opaque {};
pub const ContourSet = opaque {};
pub const PolyMesh = opaque {};
pub const PolyMeshDetail = opaque {};

/// Receives a dump's bytes.
pub const Write = *const fn (user: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void;

/// Makes the original allocate zero-filled memory.
pub extern fn shim_init() void;

pub extern fn shim_log_create() ?*Log;
pub extern fn shim_log_destroy(log: *Log) void;
pub extern fn shim_log_enable(log: *Log, enable_log: c_int, enable_timer: c_int) void;
/// The text recorded so far; valid until the next call on `log`.
pub extern fn shim_log_text(log: *Log, len: *usize) [*]const u8;
pub extern fn shim_log_clear(log: *Log) void;
pub extern fn shim_log_message(log: *Log, category: c_int, text: [*:0]const u8) void;
pub extern fn shim_log_reset(log: *Log) void;

pub extern fn shim_cosf(x: f32) f32;
pub extern fn shim_calc_bounds(verts: [*]const f32, nv: c_int, bmin: *[3]f32, bmax: *[3]f32) void;
pub extern fn shim_calc_grid_size(
    bmin: *const [3]f32,
    bmax: *const [3]f32,
    cs: f32,
    w: *c_int,
    h: *c_int,
) void;
pub extern fn shim_mark_walkable(
    log: *Log,
    slope: f32,
    verts: [*]const f32,
    nv: c_int,
    tris: [*]const i32,
    nt: c_int,
    areas: [*]u8,
) void;
pub extern fn shim_clear_unwalkable(
    log: *Log,
    slope: f32,
    verts: [*]const f32,
    nv: c_int,
    tris: [*]const i32,
    nt: c_int,
    areas: [*]u8,
) void;

pub extern fn shim_hf_create(
    log: *Log,
    w: c_int,
    h: c_int,
    bmin: *const [3]f32,
    bmax: *const [3]f32,
    cs: f32,
    ch: f32,
) ?*Heightfield;
pub extern fn shim_hf_free(hf: *Heightfield) void;
pub extern fn shim_add_span(
    log: *Log,
    hf: *Heightfield,
    x: c_int,
    z: c_int,
    smin: u16,
    smax: u16,
    area: u8,
    merge: c_int,
) c_int;
pub extern fn shim_rasterize_triangle(
    log: *Log,
    v0: *const [3]f32,
    v1: *const [3]f32,
    v2: *const [3]f32,
    area: u8,
    hf: *Heightfield,
    merge: c_int,
) c_int;
pub extern fn shim_rasterize_triangles(
    log: *Log,
    verts: [*]const f32,
    nv: c_int,
    tris: [*]const i32,
    areas: [*]const u8,
    nt: c_int,
    hf: *Heightfield,
    merge: c_int,
) c_int;
pub extern fn shim_rasterize_triangles_u16(
    log: *Log,
    verts: [*]const f32,
    nv: c_int,
    tris: [*]const u16,
    areas: [*]const u8,
    nt: c_int,
    hf: *Heightfield,
    merge: c_int,
) c_int;
pub extern fn shim_rasterize_unindexed(
    log: *Log,
    verts: [*]const f32,
    areas: [*]const u8,
    nt: c_int,
    hf: *Heightfield,
    merge: c_int,
) c_int;
pub extern fn shim_filter_low_hanging(log: *Log, climb: c_int, hf: *Heightfield) void;
pub extern fn shim_filter_ledge(log: *Log, height: c_int, climb: c_int, hf: *Heightfield) void;
pub extern fn shim_filter_low_height(log: *Log, height: c_int, hf: *Heightfield) void;
pub extern fn shim_hf_span_count(log: *Log, hf: *Heightfield) c_int;

pub extern fn shim_chf_build(
    log: *Log,
    walkable_height: c_int,
    walkable_climb: c_int,
    hf: *Heightfield,
) ?*CompactHeightfield;
pub extern fn shim_chf_free(chf: *CompactHeightfield) void;
pub extern fn shim_erode(log: *Log, radius: c_int, chf: *CompactHeightfield) c_int;
pub extern fn shim_median(log: *Log, chf: *CompactHeightfield) c_int;
pub extern fn shim_mark_box(
    log: *Log,
    bmin: *const [3]f32,
    bmax: *const [3]f32,
    area: u8,
    chf: *CompactHeightfield,
) void;
pub extern fn shim_mark_convex(
    log: *Log,
    verts: [*]const f32,
    nv: c_int,
    miny: f32,
    maxy: f32,
    area: u8,
    chf: *CompactHeightfield,
) void;
pub extern fn shim_offset_poly(
    verts: [*]const f32,
    nv: c_int,
    offset: f32,
    out: [*]f32,
    max_out: c_int,
) c_int;
pub extern fn shim_mark_cylinder(
    log: *Log,
    pos: *const [3]f32,
    radius: f32,
    height: f32,
    area: u8,
    chf: *CompactHeightfield,
) void;
pub extern fn shim_distance_field(log: *Log, chf: *CompactHeightfield) c_int;
pub extern fn shim_regions(
    log: *Log,
    chf: *CompactHeightfield,
    border: c_int,
    min_area: c_int,
    merge_area: c_int,
) c_int;
pub extern fn shim_regions_monotone(
    log: *Log,
    chf: *CompactHeightfield,
    border: c_int,
    min_area: c_int,
    merge_area: c_int,
) c_int;
pub extern fn shim_layer_regions(
    log: *Log,
    chf: *CompactHeightfield,
    border: c_int,
    min_area: c_int,
) c_int;

pub extern fn shim_layers_build(
    log: *Log,
    chf: *CompactHeightfield,
    border: c_int,
    walkable_height: c_int,
) ?*LayerSet;
pub extern fn shim_layers_free(lset: *LayerSet) void;
pub extern fn shim_contours_build(
    log: *Log,
    chf: *CompactHeightfield,
    max_error: f32,
    max_edge_len: c_int,
    flags: c_int,
) ?*ContourSet;
pub extern fn shim_contours_free(cset: *ContourSet) void;
pub extern fn shim_polymesh_build(log: *Log, cset: *ContourSet, nvp: c_int) ?*PolyMesh;
pub extern fn shim_polymesh_merge(log: *Log, meshes: [*]const *PolyMesh, n: c_int) ?*PolyMesh;
pub extern fn shim_polymesh_copy(log: *Log, src: *PolyMesh) ?*PolyMesh;
pub extern fn shim_polymesh_free(pmesh: *PolyMesh) void;
pub extern fn shim_detail_build(
    log: *Log,
    pmesh: *PolyMesh,
    chf: *CompactHeightfield,
    sample_dist: f32,
    sample_max_error: f32,
) ?*PolyMeshDetail;
pub extern fn shim_detail_merge(
    log: *Log,
    meshes: [*]const *PolyMeshDetail,
    n: c_int,
) ?*PolyMeshDetail;
pub extern fn shim_detail_free(dmesh: *PolyMeshDetail) void;

pub extern fn shim_min(a: f32, b: f32) f32;
pub extern fn shim_max(a: f32, b: f32) f32;
pub extern fn shim_clamp(v: f32, min: f32, max: f32) f32;
pub extern fn shim_clamp_int(v: c_int, min: c_int, max: c_int) c_int;
/// C's `(int)x`.
pub extern fn shim_float_to_int(x: f32) c_int;
pub extern fn shim_sqrt(x: f32) f32;
pub extern fn shim_vcross(dest: *[3]f32, v1: *const [3]f32, v2: *const [3]f32) void;
pub extern fn shim_vdot(v1: *const [3]f32, v2: *const [3]f32) f32;
pub extern fn shim_vmad(dest: *[3]f32, v1: *const [3]f32, v2: *const [3]f32, s: f32) void;
pub extern fn shim_vadd(dest: *[3]f32, v1: *const [3]f32, v2: *const [3]f32) void;
pub extern fn shim_vsub(dest: *[3]f32, v1: *const [3]f32, v2: *const [3]f32) void;
pub extern fn shim_vmin(mn: *[3]f32, v: *const [3]f32) void;
pub extern fn shim_vmax(mx: *[3]f32, v: *const [3]f32) void;
pub extern fn shim_vcopy(dest: *[3]f32, v: *const [3]f32) void;
pub extern fn shim_vdist(v1: *const [3]f32, v2: *const [3]f32) f32;
pub extern fn shim_vdist_sqr(v1: *const [3]f32, v2: *const [3]f32) f32;
pub extern fn shim_vnormalize(v: *[3]f32) void;
/// A compact span's 24 bits of connections after `rcSetCon`.
pub extern fn shim_set_con(con: c_uint, dir: c_int, neighbor: c_int) c_uint;
pub extern fn shim_get_con(con: c_uint, dir: c_int) c_int;
pub extern fn shim_dir_offset_x(dir: c_int) c_int;
pub extern fn shim_dir_offset_y(dir: c_int) c_int;
pub extern fn shim_dir_for_offset(x: c_int, z: c_int) c_int;

/// The most sweeps a row inside the border starts, for the region
/// partitions (`same_area`) or the layers.
pub extern fn shim_chf_most_row_sweeps(
    chf: *CompactHeightfield,
    border: c_int,
    same_area: c_int,
) c_int;

pub extern fn shim_dump_hf(hf: *Heightfield, write: Write, user: ?*anyopaque) void;
pub extern fn shim_dump_chf(chf: *CompactHeightfield, write: Write, user: ?*anyopaque) void;
pub extern fn shim_dump_layers(lset: *LayerSet, write: Write, user: ?*anyopaque) void;
pub extern fn shim_dump_contours(cset: *ContourSet, write: Write, user: ?*anyopaque) void;
pub extern fn shim_dump_polymesh(pmesh: *PolyMesh, write: Write, user: ?*anyopaque) void;
pub extern fn shim_dump_detail(dmesh: *PolyMeshDetail, write: Write, user: ?*anyopaque) void;

/// Bytes collected from a dump; the shim cannot fail, so an allocation
/// failure is kept and reported after the dump.
pub const Collector = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    failed: bool = false,

    pub fn write(user: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
        const collector: *Collector = @ptrCast(@alignCast(user.?));
        collector.bytes.appendSlice(collector.gpa, bytes[0..len]) catch {
            collector.failed = true;
        };
    }

    pub fn deinit(collector: *Collector) void {
        collector.bytes.deinit(collector.gpa);
    }
};

/// The dump of one of the original's objects, owned by the caller.
pub fn dump(gpa: std.mem.Allocator, object: anytype) ![]u8 {
    var collector: Collector = .{ .gpa = gpa };
    errdefer collector.deinit();
    const user: *anyopaque = &collector;
    switch (@TypeOf(object)) {
        *Heightfield => shim_dump_hf(object, Collector.write, user),
        *CompactHeightfield => shim_dump_chf(object, Collector.write, user),
        *LayerSet => shim_dump_layers(object, Collector.write, user),
        *ContourSet => shim_dump_contours(object, Collector.write, user),
        *PolyMesh => shim_dump_polymesh(object, Collector.write, user),
        *PolyMeshDetail => shim_dump_detail(object, Collector.write, user),
        else => @compileError("no dump for " ++ @typeName(@TypeOf(object))),
    }
    if (collector.failed) return error.OutOfMemory;
    return collector.bytes.toOwnedSlice(gpa);
}

/// What `log` recorded so far; valid until the next call on it.
pub fn logText(log: *Log) []const u8 {
    var len: usize = 0;
    const text = shim_log_text(log, &len);
    return text[0..len];
}
