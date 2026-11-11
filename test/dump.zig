//! The port's structures as bytes, in the shim's dump format
//! (`shim/recast_shim.cpp`): every field in a fixed order, ints and floats as
//! 4 native bytes, byte and short arrays as they are.

const std = @import("std");
const recast = @import("recast");

const Allocator = std.mem.Allocator;

const Dump = struct {
    gpa: Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn int(d: *Dump, value: anytype) !void {
        const v: i32 = @intCast(value);
        try d.bytes.appendSlice(d.gpa, std.mem.asBytes(&v));
    }

    fn float(d: *Dump, value: f32) !void {
        try d.bytes.appendSlice(d.gpa, std.mem.asBytes(&value));
    }

    fn floats(d: *Dump, values: []const f32) !void {
        try d.bytes.appendSlice(d.gpa, std.mem.sliceAsBytes(values));
    }

    fn raw(d: *Dump, values: anytype) !void {
        try d.bytes.appendSlice(d.gpa, std.mem.sliceAsBytes(values));
    }
};

/// The dump of a port structure, owned by the caller.
pub fn dump(gpa: Allocator, object: anytype) ![]u8 {
    var d: Dump = .{ .gpa = gpa };
    errdefer d.bytes.deinit(gpa);
    switch (@TypeOf(object)) {
        *const recast.Heightfield, *recast.Heightfield => try heightfield(&d, object),
        *const recast.CompactHeightfield, *recast.CompactHeightfield => try compact(&d, object),
        *const recast.HeightfieldLayerSet, *recast.HeightfieldLayerSet => try layers(&d, object),
        *const recast.ContourSet, *recast.ContourSet => try contours(&d, object),
        *const recast.PolyMesh, *recast.PolyMesh => try polyMesh(&d, object),
        *const recast.PolyMeshDetail, *recast.PolyMeshDetail => try detail(&d, object),
        else => @compileError("no dump for " ++ @typeName(@TypeOf(object))),
    }
    return d.bytes.toOwnedSlice(gpa);
}

fn heightfield(d: *Dump, hf: *const recast.Heightfield) !void {
    try d.int(hf.width);
    try d.int(hf.height);
    try d.floats(&hf.bmin);
    try d.floats(&hf.bmax);
    try d.float(hf.cs);
    try d.float(hf.ch);
    for (hf.spans) |column| {
        var n: i32 = 0;
        var span = column;
        while (span) |s| : (span = s.next) n += 1;
        try d.int(n);
        span = column;
        while (span) |s| : (span = s.next) {
            try d.int(s.smin);
            try d.int(s.smax);
            try d.int(s.area);
        }
    }
}

fn compact(d: *Dump, chf: *const recast.CompactHeightfield) !void {
    try d.int(chf.width);
    try d.int(chf.height);
    try d.int(chf.span_count);
    try d.int(chf.walkable_height);
    try d.int(chf.walkable_climb);
    try d.int(chf.border_size);
    try d.int(chf.max_distance);
    try d.int(chf.max_regions);
    try d.floats(&chf.bmin);
    try d.floats(&chf.bmax);
    try d.float(chf.cs);
    try d.float(chf.ch);
    for (chf.cells) |cell| {
        try d.int(cell.index);
        try d.int(cell.count);
    }
    for (chf.spans) |span| {
        try d.int(span.y);
        try d.int(span.reg);
        try d.int(span.con);
        try d.int(span.h);
    }
    // An empty field's distances are empty whether built or not.
    const has_dist = chf.dist.len != 0;
    try d.int(@intFromBool(has_dist));
    if (has_dist) try d.raw(chf.dist);
    try d.raw(chf.areas);
}

fn layers(d: *Dump, lset: *const recast.HeightfieldLayerSet) !void {
    try d.int(lset.layers.len);
    for (lset.layers) |*layer| {
        try d.floats(&layer.bmin);
        try d.floats(&layer.bmax);
        try d.float(layer.cs);
        try d.float(layer.ch);
        try d.int(layer.width);
        try d.int(layer.height);
        try d.int(layer.minx);
        try d.int(layer.maxx);
        try d.int(layer.miny);
        try d.int(layer.maxy);
        try d.int(layer.hmin);
        try d.int(layer.hmax);
        const cells: usize = @intCast(layer.width * layer.height);
        try d.raw(layer.heights[0..cells]);
        try d.raw(layer.areas[0..cells]);
        try d.raw(layer.cons[0..cells]);
    }
}

fn contours(d: *Dump, cset: *const recast.ContourSet) !void {
    try d.int(cset.nconts);
    try d.floats(&cset.bmin);
    try d.floats(&cset.bmax);
    try d.float(cset.cs);
    try d.float(cset.ch);
    try d.int(cset.width);
    try d.int(cset.height);
    try d.int(cset.border_size);
    try d.float(cset.max_error);
    for (cset.conts[0..@intCast(cset.nconts)]) |*cont| {
        try d.int(cont.nverts);
        try d.raw(cont.verts[0..@intCast(cont.nverts * 4)]);
        try d.int(cont.nrverts);
        try d.raw(cont.rverts[0..@intCast(cont.nrverts * 4)]);
        try d.int(cont.reg);
        try d.int(cont.area);
    }
}

fn polyMesh(d: *Dump, pmesh: *const recast.PolyMesh) !void {
    try d.int(pmesh.nverts);
    try d.int(pmesh.npolys);
    try d.int(pmesh.maxpolys);
    try d.int(pmesh.nvp);
    try d.floats(&pmesh.bmin);
    try d.floats(&pmesh.bmax);
    try d.float(pmesh.cs);
    try d.float(pmesh.ch);
    try d.int(pmesh.border_size);
    try d.float(pmesh.max_edge_error);
    try d.raw(pmesh.verts[0..@intCast(pmesh.nverts * 3)]);
    const polys: usize = @intCast(@max(pmesh.maxpolys, pmesh.npolys));
    const nvp: usize = @intCast(pmesh.nvp);
    try d.raw(pmesh.polys[0 .. polys * nvp * 2]);
    try d.raw(pmesh.regs[0..polys]);
    // Flags are allocated for the polygons in use only.
    try d.raw(pmesh.flags[0..@intCast(pmesh.npolys)]);
    try d.raw(pmesh.areas[0..polys]);
}

fn detail(d: *Dump, dmesh: *const recast.PolyMeshDetail) !void {
    try d.int(dmesh.nmeshes);
    try d.int(dmesh.nverts);
    try d.int(dmesh.ntris);
    try d.raw(dmesh.meshes[0..@intCast(dmesh.nmeshes * 4)]);
    try d.raw(dmesh.verts[0..@intCast(dmesh.nverts * 3)]);
    try d.raw(dmesh.tris[0..@intCast(dmesh.ntris * 4)]);
}
