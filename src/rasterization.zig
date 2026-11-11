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
/// merged with the spans there as `addSpan` merges.
pub fn rasterizeTriangle(
    ctx: Context,
    gpa: Allocator,
    v0: *const [3]f32,
    v1: *const [3]f32,
    v2: *const [3]f32,
    area_id: u8,
    hf: *Heightfield,
    flag_merge_threshold: i32,
) Allocator.Error!void {
    ctx.startTimer(.rasterize_triangles);
    defer ctx.stopTimer(.rasterize_triangles);

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
pub fn rasterizeTriangles(
    ctx: Context,
    gpa: Allocator,
    verts: []const f32,
    comptime Index: type,
    tris: []const Index,
    tri_area_ids: []const u8,
    hf: *Heightfield,
    flag_merge_threshold: i32,
) Allocator.Error!void {
    if (Index != i32 and Index != u16) {
        @compileError("rasterizeTriangles takes i32 or u16 vertex indices");
    }
    assert(tris.len == tri_area_ids.len * 3);

    ctx.startTimer(.rasterize_triangles);
    defer ctx.stopTimer(.rasterize_triangles);

    const inverse_cell_size = 1.0 / hf.cs;
    const inverse_cell_height = 1.0 / hf.ch;
    for (tri_area_ids, 0..) |area_id, tri_index| {
        const tri = tris[tri_index * 3 ..][0..3];
        const v0 = verts[@as(usize, @intCast(tri[0])) * 3 ..][0..3];
        const v1 = verts[@as(usize, @intCast(tri[1])) * 3 ..][0..3];
        const v2 = verts[@as(usize, @intCast(tri[2])) * 3 ..][0..3];
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
/// vertex, and `tri_area_ids` each triangle's area id.
pub fn rasterizeUnindexedTriangles(
    ctx: Context,
    gpa: Allocator,
    verts: []const f32,
    tri_area_ids: []const u8,
    hf: *Heightfield,
    flag_merge_threshold: i32,
) Allocator.Error!void {
    assert(verts.len == tri_area_ids.len * 9);

    ctx.startTimer(.rasterize_triangles);
    defer ctx.stopTimer(.rasterize_triangles);

    const inverse_cell_size = 1.0 / hf.cs;
    const inverse_cell_height = 1.0 / hf.ch;
    for (tri_area_ids, 0..) |area_id, tri_index| {
        const v0 = verts[(tri_index * 3 + 0) * 3 ..][0..3];
        const v1 = verts[(tri_index * 3 + 1) * 3 ..][0..3];
        const v2 = verts[(tri_index * 3 + 2) * 3 ..][0..3];
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
