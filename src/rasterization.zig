// An altered version of Recast from recastnavigation 1.6.0, translated to
// Zig. Copyright (c) 2009-2010 Mikko Mononen memon@inside.org; zlib licence,
// see LICENSE.

//! Rasterization: turns triangles into the solid spans of a heightfield.
//! Translated from RecastRasterization.cpp.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const recast = @import("recast.zig");
const Context = recast.Context;
const Heightfield = recast.Heightfield;
const Span = recast.Span;
const SpanPool = recast.SpanPool;
const clamp = recast.clamp;
const truncateToInt = recast.truncateToInt;

/// How rasterization can fail.
pub const RasterizeError = Allocator.Error || error{
    /// A triangle has an x or z that is not finite, or that is
    /// `recast.vertex_cells_max` cells or more from the origin.
    NonFiniteVertex,
};

/// Whether the x and z of the three vertices are finite and nearer the
/// origin than `limit`.
fn inRange(v0: *const [3]f32, v1: *const [3]f32, v2: *const [3]f32, limit: f32) bool {
    const xz: @Vector(6, f32) = .{ v0[0], v0[2], v1[0], v1[2], v2[0], v2[2] };
    return @reduce(.And, @abs(xz) < @as(@Vector(6, f32), @splat(limit)));
}

/// The bound `inRange` checks a heightfield's triangles against.
fn vertexLimit(hf: *const Heightfield) f32 {
    return hf.cs * recast.vertex_cells_max;
}

/// The log message of a triangle `inRange` rejects.
const out_of_range_message = "Triangle with an x or z that is not finite or too far " ++
    "from the origin.";

/// Whether two bounding boxes overlap or touch.
fn overlapBounds(
    a_min: *const [3]f32,
    a_max: *const [3]f32,
    b_min: *const [3]f32,
    b_max: *const [3]f32,
) bool {
    return a_min[0] <= b_max[0] and a_max[0] >= b_min[0] and
        a_min[1] <= b_max[1] and a_max[1] >= b_min[1] and
        a_min[2] <= b_max[2] and a_max[2] >= b_min[2];
}

/// Takes a span from the heightfield's free list, first refilling the list
/// from a new pool when it holds one span or none.
fn allocSpan(gpa: Allocator, hf: *Heightfield) Allocator.Error!*Span {
    if (hf.freelist == null or hf.freelist.?.next == null) {
        const pool = try gpa.create(SpanPool);
        pool.next = hf.pools;
        hf.pools = pool;

        // Put the new spans in front of the free list, the first item first.
        var free_list = hf.freelist;
        var i: usize = recast.spans_per_pool;
        while (i > 0) {
            i -= 1;
            pool.items[i].next = free_list;
            free_list = &pool.items[i];
        }
        hf.freelist = free_list;
    }

    // Pop the span at the front of the free list.
    const new_span = hf.freelist.?;
    hf.freelist = new_span.next;
    return new_span;
}

/// Returns a span to the front of the heightfield's free list for reuse.
fn freeSpan(hf: *Heightfield, span: *Span) void {
    span.next = hf.freelist;
    hf.freelist = span;
}

/// Adds a span to column (x, z), merging it with the spans it overlaps or
/// touches. The limits keep their low 13 bits, as upstream's bitfields do.
fn insertSpan(
    gpa: Allocator,
    hf: *Heightfield,
    x: i32,
    z: i32,
    min: u16,
    max: u16,
    area_id: u8,
    flag_merge_threshold: i32,
) Allocator.Error!void {
    const new_span = try allocSpan(gpa, hf);
    new_span.smin = @truncate(min);
    new_span.smax = @truncate(max);
    new_span.area = @truncate(area_id);
    new_span.next = null;

    const column_index: usize = @intCast(x + z * hf.width);
    var previous_span: ?*Span = null;
    var current_span = hf.spans[column_index];

    // Insert the new span, possibly merging it with existing spans.
    while (current_span) |current| {
        if (current.smin > new_span.smax) {
            // The current span is completely above the new span.
            break;
        }

        if (current.smax < new_span.smin) {
            // The current span is completely below the new span. Keep going.
            previous_span = current;
            current_span = current.next;
        } else {
            // The new span overlaps the current one. Merge them.
            if (current.smin < new_span.smin) new_span.smin = current.smin;
            if (current.smax > new_span.smax) new_span.smax = current.smax;

            // Merge the area ids where the tops are close: higher area ids
            // take priority.
            const top_difference = @as(i32, new_span.smax) - @as(i32, current.smax);
            if (@abs(top_difference) <= flag_merge_threshold) {
                new_span.area = @max(new_span.area, current.area);
            }

            // Remove the current span, now merged into the new one, and keep
            // going: more spans above may overlap too.
            const next = current.next;
            freeSpan(hf, current);
            if (previous_span) |previous| {
                previous.next = next;
            } else {
                hf.spans[column_index] = next;
            }
            current_span = next;
        }
    }

    // Insert the new span after the previous one.
    if (previous_span) |previous| {
        new_span.next = previous.next;
        previous.next = new_span;
    } else {
        // The new span goes below the others in the column.
        new_span.next = hf.spans[column_index];
        hf.spans[column_index] = new_span;
    }
}

/// Adds a span from `span_min` to `span_max` to column (x, z), merging it
/// with the spans it overlaps or touches. The merged span takes the larger
/// area id of each span whose top is within `flag_merge_threshold` of its
/// own. The limits keep their low 13 bits. A span of zero or negative size
/// is ignored with a warning. Merged spans go back to the heightfield's free
/// list, so a pointer to one then names a span that later additions reuse.
pub fn addSpan(
    ctx: Context,
    gpa: Allocator,
    hf: *Heightfield,
    x: i32,
    z: i32,
    span_min: u16,
    span_max: u16,
    area_id: u8,
    flag_merge_threshold: i32,
) Allocator.Error!void {
    assert(x >= 0 and x < hf.width and z >= 0 and z < hf.height);
    if (span_min >= span_max) {
        ctx.log(.warning, "rcAddSpan: Adding a span with zero or negative size. Ignored.", .{});
        return;
    }
    insertSpan(gpa, hf, x, z, span_min, span_max, area_id, flag_merge_threshold) catch |err| {
        ctx.log(.err, "rcAddSpan: Out of memory.", .{});
        return err;
    };
}

/// The axis a polygon is divided across.
const Axis = enum(u2) { x = 0, y = 1, z = 2 };

/// Copies the three floats of a vertex.
fn copyVertex(dest: []f32, v: []const f32) void {
    dest[0] = v[0];
    dest[1] = v[1];
    dest[2] = v[2];
}

/// Divides a convex polygon of at most 12 vertices in two across the line
/// where `axis` is `axis_offset`: `out_verts1` gets the part on the lower
/// side, `out_verts2` the rest. Vertices on the line go to both.
fn dividePoly(
    in_verts: []const f32,
    in_verts_count: usize,
    out_verts1: []f32,
    out_verts1_count: *usize,
    out_verts2: []f32,
    out_verts2_count: *usize,
    axis_offset: f32,
    axis: Axis,
) void {
    // How far each vertex is below the dividing line, negative above it.
    var in_vert_axis_delta: [12]f32 = undefined;
    const component = @backingInt(axis);
    for (0..in_verts_count) |in_vert| {
        in_vert_axis_delta[in_vert] = axis_offset - in_verts[in_vert * 3 + component];
    }

    var poly1_vert: usize = 0;
    var poly2_vert: usize = 0;
    var in_vert_a: usize = 0;
    var in_vert_b: usize = in_verts_count -% 1;
    while (in_vert_a < in_verts_count) : ({
        in_vert_b = in_vert_a;
        in_vert_a += 1;
    }) {
        const delta_a = in_vert_axis_delta[in_vert_a];
        const delta_b = in_vert_axis_delta[in_vert_b];
        const va = in_verts[in_vert_a * 3 ..];
        const vb = in_verts[in_vert_b * 3 ..];

        // Whether the two vertices are on the same side of the line.
        const same_side = (delta_a >= 0) == (delta_b >= 0);
        if (!same_side) {
            const s = delta_b / (delta_b - delta_a);
            const out1 = out_verts1[poly1_vert * 3 ..];
            out1[0] = vb[0] + (va[0] - vb[0]) * s;
            out1[1] = vb[1] + (va[1] - vb[1]) * s;
            out1[2] = vb[2] + (va[2] - vb[2]) * s;
            copyVertex(out_verts2[poly2_vert * 3 ..], out1);
            poly1_vert += 1;
            poly2_vert += 1;

            // Add vertex A to the polygon on its side. A vertex on the line
            // is not added: the crossing above already is that vertex.
            if (delta_a > 0) {
                copyVertex(out_verts1[poly1_vert * 3 ..], va);
                poly1_vert += 1;
            } else if (delta_a < 0) {
                copyVertex(out_verts2[poly2_vert * 3 ..], va);
                poly2_vert += 1;
            }
        } else {
            // Add vertex A to the polygon on its side, or to both if it is
            // on the line.
            if (delta_a >= 0) {
                copyVertex(out_verts1[poly1_vert * 3 ..], va);
                poly1_vert += 1;
                if (delta_a != 0) continue;
            }
            copyVertex(out_verts2[poly2_vert * 3 ..], va);
            poly2_vert += 1;
        }
    }

    out_verts1_count.* = poly1_vert;
    out_verts2_count.* = poly2_vert;
}

/// Rasterizes one triangle: each cell it covers gets a span from its lowest
/// to its highest point over the cell, clamped to the heightfield's bounds.
fn rasterizeTri(
    gpa: Allocator,
    v0: *const [3]f32,
    v1: *const [3]f32,
    v2: *const [3]f32,
    area_id: u8,
    hf: *Heightfield,
    hf_bb_min: *const [3]f32,
    hf_bb_max: *const [3]f32,
    cell_size: f32,
    inverse_cell_size: f32,
    inverse_cell_height: f32,
    flag_merge_threshold: i32,
) Allocator.Error!void {
    // The bounding box of the triangle.
    var tri_bb_min = v0.*;
    recast.vmin(&tri_bb_min, v1);
    recast.vmin(&tri_bb_min, v2);
    var tri_bb_max = v0.*;
    recast.vmax(&tri_bb_max, v1);
    recast.vmax(&tri_bb_max, v2);

    // Skip the triangle if it does not touch the heightfield's bounds.
    if (!overlapBounds(&tri_bb_min, &tri_bb_max, hf_bb_min, hf_bb_max)) return;

    const w = hf.width;
    const h = hf.height;
    const by = hf_bb_max[1] - hf_bb_min[1];

    // The rows of the grid the triangle covers.
    var z0 = truncateToInt((tri_bb_min[2] - hf_bb_min[2]) * inverse_cell_size);
    var z1 = truncateToInt((tri_bb_max[2] - hf_bb_min[2]) * inverse_cell_size);

    // Start at -1 rather than 0 to cut the polygon at the start of the
    // field.
    z0 = clamp(i32, z0, -1, h - 1);
    z1 = clamp(i32, z1, 0, h - 1);

    // Clip the triangle into all the cells it touches. The four polygons of
    // up to 7 vertices share one buffer, each slice running to its end.
    var buf: [7 * 3 * 4]f32 = undefined;
    var in_poly: []f32 = buf[0..];
    var in_row: []f32 = buf[7 * 3 ..];
    var p1: []f32 = buf[7 * 3 * 2 ..];
    var p2: []f32 = buf[7 * 3 * 3 ..];

    copyVertex(in_poly[0..], v0);
    copyVertex(in_poly[1 * 3 ..], v1);
    copyVertex(in_poly[2 * 3 ..], v2);
    var nv_row: usize = undefined;
    var nv_in: usize = 3;

    var z = z0;
    while (z <= z1) : (z += 1) {
        // Clip the polygon to the row, keeping the rest for the next rows.
        const cell_z = hf_bb_min[2] + @as(f32, @floatFromInt(z)) * cell_size;
        dividePoly(in_poly, nv_in, in_row, &nv_row, p1, &nv_in, cell_z + cell_size, .z);
        std.mem.swap([]f32, &in_poly, &p1);

        if (nv_row < 3) continue;
        if (z < 0) continue;

        // The x bounds of the row.
        var min_x = in_row[0];
        var max_x = in_row[0];
        for (1..nv_row) |vert| {
            if (min_x > in_row[vert * 3]) min_x = in_row[vert * 3];
            if (max_x < in_row[vert * 3]) max_x = in_row[vert * 3];
        }
        var x0 = truncateToInt((min_x - hf_bb_min[0]) * inverse_cell_size);
        var x1 = truncateToInt((max_x - hf_bb_min[0]) * inverse_cell_size);
        if (x1 < 0 or x0 >= w) continue;
        x0 = clamp(i32, x0, -1, w - 1);
        x1 = clamp(i32, x1, 0, w - 1);

        var nv: usize = undefined;
        var nv2 = nv_row;

        var x = x0;
        while (x <= x1) : (x += 1) {
            // Clip the row to the cell, keeping the rest for the next cells.
            const cx = hf_bb_min[0] + @as(f32, @floatFromInt(x)) * cell_size;
            dividePoly(in_row, nv2, p1, &nv, p2, &nv2, cx + cell_size, .x);
            std.mem.swap([]f32, &in_row, &p2);

            if (nv < 3) continue;
            if (x < 0) continue;

            // The height range of the polygon over the cell.
            var span_min = p1[1];
            var span_max = p1[1];
            for (1..nv) |vert| {
                span_min = recast.selectMin(span_min, p1[vert * 3 + 1]);
                span_max = recast.selectMax(span_max, p1[vert * 3 + 1]);
            }
            span_min -= hf_bb_min[1];
            span_max -= hf_bb_min[1];

            // Skip the span if it is completely outside the heightfield's
            // bounds.
            if (span_max < 0.0) continue;
            if (span_min > by) continue;

            // Clamp the span to the heightfield's bounds.
            if (span_min < 0.0) span_min = 0;
            if (span_max > by) span_max = by;

            // Snap the span to the height grid. The upper limit can come
            // out as one past the largest height, which the span's 13 bits
            // store as 0.
            const span_min_floor = truncateToInt(@floor(span_min * inverse_cell_height));
            const span_min_cell_index: u16 =
                @intCast(clamp(i32, span_min_floor, 0, recast.span_max_height));
            const span_max_ceil = truncateToInt(@ceil(span_max * inverse_cell_height));
            const span_max_cell_index: u16 = @intCast(clamp(
                i32,
                span_max_ceil,
                @as(i32, span_min_cell_index) + 1,
                recast.span_max_height,
            ));

            try insertSpan(
                gpa,
                hf,
                x,
                z,
                span_min_cell_index,
                span_max_cell_index,
                area_id,
                flag_merge_threshold,
            );
        }
    }
}

/// Rasterizes a triangle into the heightfield: each cell it covers gets a
/// span from the triangle's lowest to its highest point over the cell,
/// merged with the spans there as `addSpan` merges. A triangle with an x or
/// z that is not finite, or `recast.vertex_cells_max` cells or more from the
/// origin, changes nothing and gives `error.NonFiniteVertex`.
pub fn rasterizeTriangle(
    ctx: Context,
    gpa: Allocator,
    v0: *const [3]f32,
    v1: *const [3]f32,
    v2: *const [3]f32,
    area_id: u8,
    hf: *Heightfield,
    flag_merge_threshold: i32,
) RasterizeError!void {
    ctx.startTimer(.rasterize_triangles);
    defer ctx.stopTimer(.rasterize_triangles);

    if (!inRange(v0, v1, v2, vertexLimit(hf))) {
        ctx.log(.err, "rcRasterizeTriangle: " ++ out_of_range_message, .{});
        return error.NonFiniteVertex;
    }
    const inverse_cell_size = 1.0 / hf.cs;
    const inverse_cell_height = 1.0 / hf.ch;
    rasterizeTri(
        gpa,
        v0,
        v1,
        v2,
        area_id,
        hf,
        &hf.bmin,
        &hf.bmax,
        hf.cs,
        inverse_cell_size,
        inverse_cell_height,
        flag_merge_threshold,
    ) catch |err| {
        ctx.log(.err, "rcRasterizeTriangle: Out of memory.", .{});
        return err;
    };
}

/// Rasterizes indexed triangles, as `rasterizeTriangle` does each:
/// `verts` holds x, y and z per vertex, `tris` three vertex indices per
/// triangle (`i32` or `u16`) and `tri_area_ids` each triangle's area id.
/// Stops with `error.NonFiniteVertex` at the first triangle that
/// `rasterizeTriangle` would reject, keeping the spans of those before it.
pub fn rasterizeTriangles(
    ctx: Context,
    gpa: Allocator,
    verts: []const f32,
    comptime Index: type,
    tris: []const Index,
    tri_area_ids: []const u8,
    hf: *Heightfield,
    flag_merge_threshold: i32,
) RasterizeError!void {
    if (Index != i32 and Index != u16) {
        @compileError("rasterizeTriangles takes i32 or u16 vertex indices");
    }
    assert(tris.len == tri_area_ids.len * 3);

    ctx.startTimer(.rasterize_triangles);
    defer ctx.stopTimer(.rasterize_triangles);

    const inverse_cell_size = 1.0 / hf.cs;
    const inverse_cell_height = 1.0 / hf.ch;
    const limit = vertexLimit(hf);
    for (tri_area_ids, 0..) |area_id, tri_index| {
        const tri = tris[tri_index * 3 ..][0..3];
        const v0 = verts[@as(usize, @intCast(tri[0])) * 3 ..][0..3];
        const v1 = verts[@as(usize, @intCast(tri[1])) * 3 ..][0..3];
        const v2 = verts[@as(usize, @intCast(tri[2])) * 3 ..][0..3];
        if (!inRange(v0, v1, v2, limit)) {
            ctx.log(.err, "rcRasterizeTriangles: " ++ out_of_range_message, .{});
            return error.NonFiniteVertex;
        }
        rasterizeTri(
            gpa,
            v0,
            v1,
            v2,
            area_id,
            hf,
            &hf.bmin,
            &hf.bmax,
            hf.cs,
            inverse_cell_size,
            inverse_cell_height,
            flag_merge_threshold,
        ) catch |err| {
            ctx.log(.err, "rcRasterizeTriangles: Out of memory.", .{});
            return err;
        };
    }
}

/// Rasterizes triangles given by their vertices, as `rasterizeTriangle`
/// does each: `verts` holds nine floats per triangle, x, y and z of each
/// vertex, and `tri_area_ids` each triangle's area id. Stops with
/// `error.NonFiniteVertex` as `rasterizeTriangles` does.
pub fn rasterizeUnindexedTriangles(
    ctx: Context,
    gpa: Allocator,
    verts: []const f32,
    tri_area_ids: []const u8,
    hf: *Heightfield,
    flag_merge_threshold: i32,
) RasterizeError!void {
    assert(verts.len == tri_area_ids.len * 9);

    ctx.startTimer(.rasterize_triangles);
    defer ctx.stopTimer(.rasterize_triangles);

    const inverse_cell_size = 1.0 / hf.cs;
    const inverse_cell_height = 1.0 / hf.ch;
    const limit = vertexLimit(hf);
    for (tri_area_ids, 0..) |area_id, tri_index| {
        const v0 = verts[(tri_index * 3 + 0) * 3 ..][0..3];
        const v1 = verts[(tri_index * 3 + 1) * 3 ..][0..3];
        const v2 = verts[(tri_index * 3 + 2) * 3 ..][0..3];
        if (!inRange(v0, v1, v2, limit)) {
            ctx.log(.err, "rcRasterizeTriangles: " ++ out_of_range_message, .{});
            return error.NonFiniteVertex;
        }
        rasterizeTri(
            gpa,
            v0,
            v1,
            v2,
            area_id,
            hf,
            &hf.bmin,
            &hf.bmax,
            hf.cs,
            inverse_cell_size,
            inverse_cell_height,
            flag_merge_threshold,
        ) catch |err| {
            ctx.log(.err, "rcRasterizeTriangles: Out of memory.", .{});
            return err;
        };
    }
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "addSpan merges the spans it touches and keeps the area id near the top" {
    const gpa = testing.allocator;
    var hf = try Heightfield.init(gpa, 1, 1, &.{ 0, 0, 0 }, &.{ 1, 1, 1 }, 1, 1);
    defer hf.deinit(gpa);

    try addSpan(.none, gpa, &hf, 0, 0, 10, 20, 3, 1);
    try addSpan(.none, gpa, &hf, 0, 0, 30, 40, 2, 1);
    // Ignored: zero size.
    try addSpan(.none, gpa, &hf, 0, 0, 25, 25, 9, 1);
    try testing.expectEqual(20, hf.spans[0].?.smax);
    try testing.expectEqual(30, hf.spans[0].?.next.?.smin);

    // Touches both: all three merge. The first span's top is 10 below the
    // new span's, so only the second's area id competes.
    try addSpan(.none, gpa, &hf, 0, 0, 15, 30, 1, 1);
    const span = hf.spans[0].?;
    try testing.expectEqual(10, span.smin);
    try testing.expectEqual(40, span.smax);
    try testing.expectEqual(2, span.area);
    try testing.expectEqual(null, span.next);
}

test "a span's limits keep their low 13 bits" {
    const gpa = testing.allocator;
    var hf = try Heightfield.init(gpa, 1, 1, &.{ 0, 0, 0 }, &.{ 1, 1, 1 }, 1, 1);
    defer hf.deinit(gpa);

    try addSpan(.none, gpa, &hf, 0, 0, 100, 9000, 1, 1);
    try testing.expectEqual(100, hf.spans[0].?.smin);
    try testing.expectEqual(9000 - 8192, hf.spans[0].?.smax);
}

test "triangles with an x or z out of range fail, the same in every build" {
    const gpa = testing.allocator;
    const cs: f32 = 0.5;
    const limit = cs * recast.vertex_cells_max;
    const near_limit = std.math.nextAfter(f32, limit, 0);
    var hf = try Heightfield.init(gpa, 4, 4, &.{ 0, 0, 0 }, &.{ 2, 4, 2 }, cs, 1);
    defer hf.deinit(gpa);

    // Each bad value in each corner's x and z. Heights take any float.
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    for ([_]f32{ nan, -nan, inf, -inf, limit, -limit, 1e30 }) |bad| {
        for (0..9) |k| {
            if (k % 3 == 1) continue;
            var v = [9]f32{ 0.1, 1, 0.1, 0.1, 1, 1.9, 1.9, 1, 0.1 };
            v[k] = bad;
            const result = rasterizeTriangle(.none, gpa, v[0..3], v[3..6], v[6..9], 1, &hf, 1);
            try testing.expectError(error.NonFiniteVertex, result);
        }
    }
    for (hf.spans) |column| try testing.expectEqual(null, column);

    // A long triangle from the field to just inside the range rasterizes,
    // and so does one with odd heights.
    const far = [9]f32{ near_limit, 1, 0.1, 0.1, 2, 1.9, -near_limit, 3, -near_limit };
    try rasterizeTriangle(.none, gpa, far[0..3], far[3..6], far[6..9], 1, &hf, 1);
    const odd = [9]f32{ 0.1, nan, 0.1, 0.1, inf, 1.9, 1.9, -inf, 0.1 };
    try rasterizeTriangle(.none, gpa, odd[0..3], odd[3..6], odd[6..9], 1, &hf, 1);

    // The batch entry points stop at the bad triangle, keeping the ones
    // before it.
    const verts = [_]f32{ 0.1, 1, 0.1, 0.1, 1, 1.9, 1.9, 1, 0.1, inf, 1, 0 };
    const good_then_bad = [_]i32{ 0, 1, 2, 3, 1, 2 };
    const good_then_bad_u16 = [_]u16{ 0, 1, 2, 3, 1, 2 };
    const areas = [_]u8{ 1, 1 };
    const flat = [_]f32{ 0.1, 1, 0.1, 0.1, 1, 1.9, 1.9, 1, 0.1, inf, 1, 0, 0, 1, 0, 1, 1, 1 };
    for (0..3) |entry| {
        var fresh = try Heightfield.init(gpa, 4, 4, &.{ 0, 0, 0 }, &.{ 2, 4, 2 }, cs, 1);
        defer fresh.deinit(gpa);
        const result = switch (entry) {
            0 => rasterizeTriangles(.none, gpa, &verts, i32, &good_then_bad, &areas, &fresh, 1),
            1 => rasterizeTriangles(.none, gpa, &verts, u16, &good_then_bad_u16, &areas, &fresh, 1),
            else => rasterizeUnindexedTriangles(.none, gpa, &flat, &areas, &fresh, 1),
        };
        try testing.expectError(error.NonFiniteVertex, result);
        try testing.expect(fresh.spans[0] != null);
    }

    // Cells of no size leave no range at all.
    var no_size = try Heightfield.init(gpa, 1, 1, &.{ 0, 0, 0 }, &.{ 1, 1, 1 }, 0, 1);
    defer no_size.deinit(gpa);
    const tri = [9]f32{ 0, 0, 0, 0, 0, 1, 1, 0, 0 };
    const result = rasterizeTriangle(.none, gpa, tri[0..3], tri[3..6], tri[6..9], 1, &no_size, 1);
    try testing.expectError(error.NonFiniteVertex, result);
}

test "a field farther out than the vertex range fails instead of overrunning the clipper" {
    // At 2^24 cells from the origin a cell is less than two float steps
    // wide; the original's clipper then writes past its buffers.
    const gpa = testing.allocator;
    const cs: f32 = 0.125;
    const base = cs * (1 << 24);
    const bmin = [3]f32{ base, 0, base };
    const bmax = [3]f32{ base + 16 * cs, 10, base + 16 * cs };
    var hf = try Heightfield.init(gpa, 16, 16, &bmin, &bmax, cs, 0.2);
    defer hf.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(1);
    const r = prng.random();
    for (0..200) |_| {
        var v: [9]f32 = undefined;
        for (0..3) |i| {
            v[i * 3 + 0] = base + r.float(f32) * 16 * cs + (r.float(f32) - 0.5) * 8 * cs;
            v[i * 3 + 1] = r.float(f32) * 10;
            v[i * 3 + 2] = base + r.float(f32) * 16 * cs + (r.float(f32) - 0.5) * 8 * cs;
        }
        const result = rasterizeTriangle(.none, gpa, v[0..3], v[3..6], v[6..9], 1, &hf, 1);
        try testing.expectError(error.NonFiniteVertex, result);
    }
}
