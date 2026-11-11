// An altered version of Recast from recastnavigation 1.6.0, translated to
// Zig. Copyright (c) 2009-2010 Mikko Mononen memon@inside.org; zlib licence,
// see LICENSE.

//! Area marking on a compact heightfield: erosion by the agent's radius, the
//! median filter, and marking boxes, convex polygons and cylinders with an
//! area id. Translated from RecastArea.cpp.

const std = @import("std");
const Allocator = std.mem.Allocator;

const recast = @import("recast.zig");
const Context = recast.Context;
const CompactHeightfield = recast.CompactHeightfield;
const getCon = recast.getCon;
const getDirOffsetX = recast.getDirOffsetX;
const getDirOffsetY = recast.getDirOffsetY;
const not_connected = recast.not_connected;
const null_area = recast.null_area;
const truncateToInt = recast.truncateToInt;

/// Sorts `data` in place, by insertion.
fn insertSort(data: []u8) void {
    var value_index: i32 = 1;
    while (value_index < data.len) : (value_index += 1) {
        const value = data[@intCast(value_index)];
        var insertion_index = value_index - 1;
        while (insertion_index >= 0 and data[@intCast(insertion_index)] > value) {
            // Shift over values.
            data[@intCast(insertion_index + 1)] = data[@intCast(insertion_index)];
            insertion_index -= 1;
        }
        // Insert the value in sorted order.
        data[@intCast(insertion_index + 1)] = value;
    }
}

/// Whether `point` lies within the polygon of the first `num_verts` vertices
/// of `verts`, on the xz-plane.
fn pointInPoly(num_verts: i32, verts: []const f32, point: *const [3]f32) bool {
    var in_poly = false;
    var i: i32 = 0;
    var j = num_verts - 1;
    while (i < num_verts) : ({
        j = i;
        i += 1;
    }) {
        const vi = verts[@intCast(i * 3)..][0..3];
        const vj = verts[@intCast(j * 3)..][0..3];
        if ((vi[2] > point[2]) == (vj[2] > point[2])) continue;
        if (point[0] >= (vj[0] - vi[0]) * (point[2] - vi[2]) / (vj[2] - vi[2]) + vi[0]) continue;
        in_poly = !in_poly;
    }
    return in_poly;
}

/// Removes the walkable spans closer than `erosion_radius` cells to a
/// boundary: an unwalkable span or the edge of the walkable surface. The
/// distance is a chamfer distance of 2 per straight step and 3 per diagonal
/// one, capped at 255, and is compared with twice the radius.
pub fn erodeWalkableArea(
    ctx: Context,
    gpa: Allocator,
    erosion_radius: i32,
    chf: *CompactHeightfield,
) Allocator.Error!void {
    const x_size = chf.width;
    const z_size = chf.height;
    const z_stride = x_size;

    ctx.startTimer(.erode_area);
    defer ctx.stopTimer(.erode_area);

    const distance_to_boundary = gpa.alloc(u8, @intCast(chf.span_count)) catch |err| {
        ctx.log(.err, "erodeWalkableArea: Out of memory 'dist' ({d}).", .{chf.span_count});
        return err;
    };
    defer gpa.free(distance_to_boundary);
    @memset(distance_to_boundary, 0xff);

    // Mark boundary cells.
    var z: i32 = 0;
    while (z < z_size) : (z += 1) {
        var x: i32 = 0;
        while (x < x_size) : (x += 1) {
            const cell = chf.cells[@intCast(x + z * z_stride)];
            var span_index: i32 = cell.index;
            const max_span_index = @as(i32, cell.index) + cell.count;
            while (span_index < max_span_index) : (span_index += 1) {
                if (chf.areas[@intCast(span_index)] == null_area) {
                    distance_to_boundary[@intCast(span_index)] = 0;
                    continue;
                }
                const span = chf.spans[@intCast(span_index)];

                // Check for a walkable neighbour in each of the 4 cardinal directions.
                var neighbor_count: i32 = 0;
                for ([4]u2{ 0, 1, 2, 3 }) |direction| {
                    const neighbor_connection = getCon(span, direction);
                    if (neighbor_connection == not_connected) break;
                    const neighbor_x = x + getDirOffsetX(direction);
                    const neighbor_z = z + getDirOffsetY(direction);
                    const neighbor_cell = chf.cells[@intCast(neighbor_x + neighbor_z * z_stride)];
                    const neighbor_span_index = @as(i32, neighbor_cell.index) + neighbor_connection;
                    if (chf.areas[@intCast(neighbor_span_index)] == null_area) break;
                    neighbor_count += 1;
                }

                // At least one missing neighbour, so this is a boundary cell.
                if (neighbor_count != 4) distance_to_boundary[@intCast(span_index)] = 0;
            }
        }
    }

    // Pass 1
    z = 0;
    while (z < z_size) : (z += 1) {
        var x: i32 = 0;
        while (x < x_size) : (x += 1) {
            const cell = chf.cells[@intCast(x + z * z_stride)];
            const max_span_index = @as(i32, cell.index) + cell.count;
            var span_index: i32 = cell.index;
            while (span_index < max_span_index) : (span_index += 1) {
                const span = chf.spans[@intCast(span_index)];

                if (getCon(span, 0) != not_connected) {
                    // (-1,0)
                    const a_x = x + getDirOffsetX(0);
                    const a_y = z + getDirOffsetY(0);
                    const a_index = @as(i32, chf.cells[@intCast(a_x + a_y * x_size)].index) +
                        getCon(span, 0);
                    const a_span = chf.spans[@intCast(a_index)];
                    lowerDistance(distance_to_boundary, span_index, a_index, 2);

                    // (-1,-1)
                    if (getCon(a_span, 3) != not_connected) {
                        const b_x = a_x + getDirOffsetX(3);
                        const b_y = a_y + getDirOffsetY(3);
                        const b_index = @as(i32, chf.cells[@intCast(b_x + b_y * x_size)].index) +
                            getCon(a_span, 3);
                        lowerDistance(distance_to_boundary, span_index, b_index, 3);
                    }
                }
                if (getCon(span, 3) != not_connected) {
                    // (0,-1)
                    const a_x = x + getDirOffsetX(3);
                    const a_y = z + getDirOffsetY(3);
                    const a_index = @as(i32, chf.cells[@intCast(a_x + a_y * x_size)].index) +
                        getCon(span, 3);
                    const a_span = chf.spans[@intCast(a_index)];
                    lowerDistance(distance_to_boundary, span_index, a_index, 2);

                    // (1,-1)
                    if (getCon(a_span, 2) != not_connected) {
                        const b_x = a_x + getDirOffsetX(2);
                        const b_y = a_y + getDirOffsetY(2);
                        const b_index = @as(i32, chf.cells[@intCast(b_x + b_y * x_size)].index) +
                            getCon(a_span, 2);
                        lowerDistance(distance_to_boundary, span_index, b_index, 3);
                    }
                }
            }
        }
    }

    // Pass 2
    z = z_size - 1;
    while (z >= 0) : (z -= 1) {
        var x = x_size - 1;
        while (x >= 0) : (x -= 1) {
            const cell = chf.cells[@intCast(x + z * z_stride)];
            const max_span_index = @as(i32, cell.index) + cell.count;
            var span_index: i32 = cell.index;
            while (span_index < max_span_index) : (span_index += 1) {
                const span = chf.spans[@intCast(span_index)];

                if (getCon(span, 2) != not_connected) {
                    // (1,0)
                    const a_x = x + getDirOffsetX(2);
                    const a_y = z + getDirOffsetY(2);
                    const a_index = @as(i32, chf.cells[@intCast(a_x + a_y * x_size)].index) +
                        getCon(span, 2);
                    const a_span = chf.spans[@intCast(a_index)];
                    lowerDistance(distance_to_boundary, span_index, a_index, 2);

                    // (1,1)
                    if (getCon(a_span, 1) != not_connected) {
                        const b_x = a_x + getDirOffsetX(1);
                        const b_y = a_y + getDirOffsetY(1);
                        const b_index = @as(i32, chf.cells[@intCast(b_x + b_y * x_size)].index) +
                            getCon(a_span, 1);
                        lowerDistance(distance_to_boundary, span_index, b_index, 3);
                    }
                }
                if (getCon(span, 1) != not_connected) {
                    // (0,1)
                    const a_x = x + getDirOffsetX(1);
                    const a_y = z + getDirOffsetY(1);
                    const a_index = @as(i32, chf.cells[@intCast(a_x + a_y * x_size)].index) +
                        getCon(span, 1);
                    const a_span = chf.spans[@intCast(a_index)];
                    lowerDistance(distance_to_boundary, span_index, a_index, 2);

                    // (-1,1)
                    if (getCon(a_span, 0) != not_connected) {
                        const b_x = a_x + getDirOffsetX(0);
                        const b_y = a_y + getDirOffsetY(0);
                        const b_index = @as(i32, chf.cells[@intCast(b_x + b_y * x_size)].index) +
                            getCon(a_span, 0);
                        lowerDistance(distance_to_boundary, span_index, b_index, 3);
                    }
                }
            }
        }
    }

    // The radius converts to the distance's unsigned char, wrapping as in C.
    const min_boundary_distance: u8 = @truncate(@as(u32, @bitCast(erosion_radius *% 2)));
    for (distance_to_boundary, 0..) |distance, span_index| {
        if (distance < min_boundary_distance) chf.areas[span_index] = null_area;
    }
}

/// Lowers the distance of the span at `span_index` to that of the span at
/// `neighbor_index` plus `step`, if that is smaller, capped at 255.
fn lowerDistance(distance_to_boundary: []u8, span_index: i32, neighbor_index: i32, step: i32) void {
    const neighbor_distance: i32 = distance_to_boundary[@intCast(neighbor_index)];
    const new_distance: u8 = @intCast(@min(neighbor_distance + step, 255));
    if (new_distance < distance_to_boundary[@intCast(span_index)]) {
        distance_to_boundary[@intCast(span_index)] = new_distance;
    }
}

/// Replaces the area id of each walkable span with the median of its own and
/// its eight neighbours' ids, where an unwalkable neighbour counts as the
/// span's own id. Unwalkable spans stay unwalkable.
pub fn medianFilterWalkableArea(
    ctx: Context,
    gpa: Allocator,
    chf: *CompactHeightfield,
) Allocator.Error!void {
    const x_size = chf.width;
    const z_size = chf.height;
    const z_stride = x_size;

    ctx.startTimer(.median_area);
    defer ctx.stopTimer(.median_area);

    const areas = gpa.alloc(u8, @intCast(chf.span_count)) catch |err| {
        ctx.log(.err, "medianFilterWalkableArea: Out of memory 'areas' ({d}).", .{chf.span_count});
        return err;
    };
    defer gpa.free(areas);
    @memset(areas, 0xff);

    var z: i32 = 0;
    while (z < z_size) : (z += 1) {
        var x: i32 = 0;
        while (x < x_size) : (x += 1) {
            const cell = chf.cells[@intCast(x + z * z_stride)];
            const max_span_index = @as(i32, cell.index) + cell.count;
            var span_index: i32 = cell.index;
            while (span_index < max_span_index) : (span_index += 1) {
                const span = chf.spans[@intCast(span_index)];
                const span_area = chf.areas[@intCast(span_index)];
                if (span_area == null_area) {
                    areas[@intCast(span_index)] = span_area;
                    continue;
                }

                var neighbor_areas: [9]u8 = @splat(span_area);
                for ([4]u2{ 0, 1, 2, 3 }) |dir| {
                    if (getCon(span, dir) == not_connected) continue;

                    const a_x = x + getDirOffsetX(dir);
                    const a_z = z + getDirOffsetY(dir);
                    const a_index = @as(i32, chf.cells[@intCast(a_x + a_z * z_stride)].index) +
                        getCon(span, dir);
                    if (chf.areas[@intCast(a_index)] != null_area) {
                        neighbor_areas[@as(usize, dir) * 2 + 0] = chf.areas[@intCast(a_index)];
                    }

                    const a_span = chf.spans[@intCast(a_index)];
                    const dir2 = dir +% 1;
                    const neighbor_connection2 = getCon(a_span, dir2);
                    if (neighbor_connection2 != not_connected) {
                        const b_x = a_x + getDirOffsetX(dir2);
                        const b_z = a_z + getDirOffsetY(dir2);
                        const b_index = @as(i32, chf.cells[@intCast(b_x + b_z * z_stride)].index) +
                            neighbor_connection2;
                        if (chf.areas[@intCast(b_index)] != null_area) {
                            neighbor_areas[@as(usize, dir) * 2 + 1] = chf.areas[@intCast(b_index)];
                        }
                    }
                }
                insertSort(&neighbor_areas);
                areas[@intCast(span_index)] = neighbor_areas[4];
            }
        }
    }

    @memcpy(chf.areas[0..areas.len], areas);
}

/// Sets the area id of the walkable spans whose floor lies within the box.
pub fn markBoxArea(
    ctx: Context,
    box_min: *const [3]f32,
    box_max: *const [3]f32,
    area_id: u8,
    chf: *CompactHeightfield,
) void {
    ctx.startTimer(.mark_box_area);
    defer ctx.stopTimer(.mark_box_area);

    const x_size = chf.width;
    const z_size = chf.height;
    const z_stride = x_size;

    // Find the footprint of the box area in grid cell coordinates.
    var min_x = truncateToInt((box_min[0] - chf.bmin[0]) / chf.cs);
    const min_y = truncateToInt((box_min[1] - chf.bmin[1]) / chf.ch);
    var min_z = truncateToInt((box_min[2] - chf.bmin[2]) / chf.cs);
    var max_x = truncateToInt((box_max[0] - chf.bmin[0]) / chf.cs);
    const max_y = truncateToInt((box_max[1] - chf.bmin[1]) / chf.ch);
    var max_z = truncateToInt((box_max[2] - chf.bmin[2]) / chf.cs);

    // Early-out if the box is outside the bounds of the grid.
    if (max_x < 0) return;
    if (min_x >= x_size) return;
    if (max_z < 0) return;
    if (min_z >= z_size) return;

    // Clamp relevant bound coordinates to the grid.
    if (min_x < 0) min_x = 0;
    if (max_x >= x_size) max_x = x_size - 1;
    if (min_z < 0) min_z = 0;
    if (max_z >= z_size) max_z = z_size - 1;

    // Mark relevant cells.
    var z = min_z;
    while (z <= max_z) : (z += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const cell = chf.cells[@intCast(x + z * z_stride)];
            const max_span_index = @as(i32, cell.index) + cell.count;
            var span_index: i32 = cell.index;
            while (span_index < max_span_index) : (span_index += 1) {
                const span = chf.spans[@intCast(span_index)];

                // Skip if the span is outside the box extents.
                if (@as(i32, span.y) < min_y or @as(i32, span.y) > max_y) continue;

                // Skip if the span has been removed.
                if (chf.areas[@intCast(span_index)] == null_area) continue;

                // Mark the span.
                chf.areas[@intCast(span_index)] = area_id;
            }
        }
    }
}

/// Sets the area id of the walkable spans whose floor lies between `min_y`
/// and `max_y` and whose cell centre lies within the convex polygon `verts`,
/// x, y and z per vertex; there must be at least one vertex.
pub fn markConvexPolyArea(
    ctx: Context,
    verts: []const f32,
    min_y: f32,
    max_y: f32,
    area_id: u8,
    chf: *CompactHeightfield,
) void {
    ctx.startTimer(.mark_convexpoly_area);
    defer ctx.stopTimer(.mark_convexpoly_area);

    const x_size = chf.width;
    const z_size = chf.height;
    const z_stride = x_size;
    const num_verts: i32 = @intCast(verts.len / 3);

    // Compute the bounding box of the polygon.
    var bmin: [3]f32 = verts[0..3].*;
    var bmax: [3]f32 = verts[0..3].*;
    var i: i32 = 1;
    while (i < num_verts) : (i += 1) {
        recast.vmin(&bmin, verts[@intCast(i * 3)..][0..3]);
        recast.vmax(&bmax, verts[@intCast(i * 3)..][0..3]);
    }
    bmin[1] = min_y;
    bmax[1] = max_y;

    // Compute the grid footprint of the polygon.
    var min_x = truncateToInt((bmin[0] - chf.bmin[0]) / chf.cs);
    const min_cell_y = truncateToInt((bmin[1] - chf.bmin[1]) / chf.ch);
    var min_z = truncateToInt((bmin[2] - chf.bmin[2]) / chf.cs);
    var max_x = truncateToInt((bmax[0] - chf.bmin[0]) / chf.cs);
    const max_cell_y = truncateToInt((bmax[1] - chf.bmin[1]) / chf.ch);
    var max_z = truncateToInt((bmax[2] - chf.bmin[2]) / chf.cs);

    // Early-out if the polygon lies entirely outside the grid.
    if (max_x < 0) return;
    if (min_x >= x_size) return;
    if (max_z < 0) return;
    if (min_z >= z_size) return;

    // Clamp the polygon footprint to the grid.
    if (min_x < 0) min_x = 0;
    if (max_x >= x_size) max_x = x_size - 1;
    if (min_z < 0) min_z = 0;
    if (max_z >= z_size) max_z = z_size - 1;

    var z = min_z;
    while (z <= max_z) : (z += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const cell = chf.cells[@intCast(x + z * z_stride)];
            const max_span_index = @as(i32, cell.index) + cell.count;
            var span_index: i32 = cell.index;
            while (span_index < max_span_index) : (span_index += 1) {
                const span = chf.spans[@intCast(span_index)];

                // Skip if span is removed.
                if (chf.areas[@intCast(span_index)] == null_area) continue;

                // Skip if y extents don't overlap.
                if (@as(i32, span.y) < min_cell_y or @as(i32, span.y) > max_cell_y) continue;

                const point = [3]f32{
                    chf.bmin[0] + (@as(f32, @floatFromInt(x)) + 0.5) * chf.cs,
                    0,
                    chf.bmin[2] + (@as(f32, @floatFromInt(z)) + 0.5) * chf.cs,
                };
                if (pointInPoly(num_verts, verts, &point)) {
                    chf.areas[@intCast(span_index)] = area_id;
                }
            }
        }
    }
}

const epsilon: f32 = 1e-6;

/// Normalizes `v` if its squared length is above `epsilon`, else leaves it.
fn vsafeNormalize(v: *[3]f32) void {
    const sq_mag = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
    if (sq_mag > epsilon) {
        const inverse_mag = 1.0 / @sqrt(sq_mag);
        v[0] *= inverse_mag;
        v[1] *= inverse_mag;
        v[2] *= inverse_mag;
    }
}

/// Offsets the polygon `verts` (x, y and z per vertex) outward by `offset` on
/// the xz-plane into `out_verts`, and returns the number of vertices written.
/// A sharp convex corner is bevelled into two vertices; a polygon whose
/// result does not fit in `out_verts` gives 0.
pub fn offsetPoly(verts: []const f32, offset: f32, out_verts: []f32) i32 {
    // The limit at which a miter becomes a bevel, as SVG's stroke-miterlimit.
    const miter_limit: f32 = 1.20;

    const num_verts: i32 = @intCast(verts.len / 3);
    const max_out_verts: i32 = @intCast(out_verts.len / 3);
    var num_out_verts: i32 = 0;

    var vert_index: i32 = 0;
    while (vert_index < num_verts) : (vert_index += 1) {
        // Grab three vertices of the polygon.
        const vert_index_a = @rem(vert_index + num_verts - 1, num_verts);
        const vert_index_b = vert_index;
        const vert_index_c = @rem(vert_index + 1, num_verts);
        const vert_a = verts[@intCast(vert_index_a * 3)..][0..3];
        const vert_b = verts[@intCast(vert_index_b * 3)..][0..3];
        const vert_c = verts[@intCast(vert_index_c * 3)..][0..3];

        // From A to B on the x/z plane.
        var prev_segment_dir = recast.vsub(vert_b, vert_a);
        prev_segment_dir[1] = 0; // Squash onto x/z plane
        vsafeNormalize(&prev_segment_dir);

        // From B to C on the x/z plane.
        var curr_segment_dir = recast.vsub(vert_c, vert_b);
        curr_segment_dir[1] = 0; // Squash onto x/z plane
        vsafeNormalize(&curr_segment_dir);

        // The y component of the cross product of the two segment directions;
        // the x and z components are zero, both lying on the x/z plane.
        const cross = curr_segment_dir[0] * prev_segment_dir[2] -
            prev_segment_dir[0] * curr_segment_dir[2];

        // CCW perpendicular vector to AB. The segment normal.
        const prev_segment_norm_x = -prev_segment_dir[2];
        const prev_segment_norm_z = prev_segment_dir[0];

        // CCW perpendicular vector to BC. The segment normal.
        const curr_segment_norm_x = -curr_segment_dir[2];
        const curr_segment_norm_z = curr_segment_dir[0];

        // Average the two segment normals to get the proportional miter
        // offset for B. It is not normalized: it is how far, and in which
        // direction, the corner moves in proportion to the edge offsets.
        var corner_miter_x = (prev_segment_norm_x + curr_segment_norm_x) * 0.5;
        var corner_miter_z = (prev_segment_norm_z + curr_segment_norm_z) * 0.5;
        const corner_miter_sq_mag = corner_miter_x * corner_miter_x +
            corner_miter_z * corner_miter_z;

        // If the magnitude of the segment normal average is less than about
        // .69444, the corner is acute enough that the result is bevelled.
        const bevel = corner_miter_sq_mag * miter_limit * miter_limit < 1.0;

        // Scale the corner miter so it's proportional to how much the corner
        // should be offset compared to the edges.
        if (corner_miter_sq_mag > epsilon) {
            const scale = 1.0 / corner_miter_sq_mag;
            corner_miter_x *= scale;
            corner_miter_z *= scale;
        }

        if (bevel and cross < 0.0) {
            // The corner is convex and acute enough: bevel it.
            if (num_out_verts + 2 > max_out_verts) return 0;

            // Two bevel vertices at distances from B proportional to the
            // angle between the segments, each moved out by the offset.
            const d = (1.0 - (prev_segment_dir[0] * curr_segment_dir[0] +
                prev_segment_dir[2] * curr_segment_dir[2])) * 0.5;

            const out0 = out_verts[@intCast(num_out_verts * 3)..][0..3];
            out0[0] = vert_b[0] + (-prev_segment_norm_x + prev_segment_dir[0] * d) * offset;
            out0[1] = vert_b[1];
            out0[2] = vert_b[2] + (-prev_segment_norm_z + prev_segment_dir[2] * d) * offset;
            num_out_verts += 1;

            const out1 = out_verts[@intCast(num_out_verts * 3)..][0..3];
            out1[0] = vert_b[0] + (-curr_segment_norm_x - curr_segment_dir[0] * d) * offset;
            out1[1] = vert_b[1];
            out1[2] = vert_b[2] + (-curr_segment_norm_z - curr_segment_dir[2] * d) * offset;
            num_out_verts += 1;
        } else {
            if (num_out_verts + 1 > max_out_verts) return 0;

            // Move B along the miter direction by the specified offset.
            const out = out_verts[@intCast(num_out_verts * 3)..][0..3];
            out[0] = vert_b[0] - corner_miter_x * offset;
            out[1] = vert_b[1];
            out[2] = vert_b[2] - corner_miter_z * offset;
            num_out_verts += 1;
        }
    }

    return num_out_verts;
}

/// Sets the area id of the walkable spans whose floor lies within the
/// upright cylinder standing on `position`, by their cell centre.
pub fn markCylinderArea(
    ctx: Context,
    position: *const [3]f32,
    radius: f32,
    height: f32,
    area_id: u8,
    chf: *CompactHeightfield,
) void {
    ctx.startTimer(.mark_cylinder_area);
    defer ctx.stopTimer(.mark_cylinder_area);

    const x_size = chf.width;
    const z_size = chf.height;
    const z_stride = x_size;

    // Compute the bounding box of the cylinder.
    const cylinder_bb_min = [3]f32{
        position[0] - radius,
        position[1],
        position[2] - radius,
    };
    const cylinder_bb_max = [3]f32{
        position[0] + radius,
        position[1] + height,
        position[2] + radius,
    };

    // Compute the grid footprint of the cylinder.
    var min_x = truncateToInt((cylinder_bb_min[0] - chf.bmin[0]) / chf.cs);
    const min_y = truncateToInt((cylinder_bb_min[1] - chf.bmin[1]) / chf.ch);
    var min_z = truncateToInt((cylinder_bb_min[2] - chf.bmin[2]) / chf.cs);
    var max_x = truncateToInt((cylinder_bb_max[0] - chf.bmin[0]) / chf.cs);
    const max_y = truncateToInt((cylinder_bb_max[1] - chf.bmin[1]) / chf.ch);
    var max_z = truncateToInt((cylinder_bb_max[2] - chf.bmin[2]) / chf.cs);

    // Early-out if the cylinder is completely outside the grid bounds.
    if (max_x < 0) return;
    if (min_x >= x_size) return;
    if (max_z < 0) return;
    if (min_z >= z_size) return;

    // Clamp the cylinder bounds to the grid.
    if (min_x < 0) min_x = 0;
    if (max_x >= x_size) max_x = x_size - 1;
    if (min_z < 0) min_z = 0;
    if (max_z >= z_size) max_z = z_size - 1;

    const radius_sq = radius * radius;

    var z = min_z;
    while (z <= max_z) : (z += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const cell = chf.cells[@intCast(x + z * z_stride)];
            const max_span_index = @as(i32, cell.index) + cell.count;

            const cell_x = chf.bmin[0] + (@as(f32, @floatFromInt(x)) + 0.5) * chf.cs;
            const cell_z = chf.bmin[2] + (@as(f32, @floatFromInt(z)) + 0.5) * chf.cs;
            const delta_x = cell_x - position[0];
            const delta_z = cell_z - position[2];

            // Skip this column if it's too far from the center point of the cylinder.
            if (delta_x * delta_x + delta_z * delta_z >= radius_sq) continue;

            // Mark all overlapping spans.
            var span_index: i32 = cell.index;
            while (span_index < max_span_index) : (span_index += 1) {
                const span = chf.spans[@intCast(span_index)];

                // Skip if span is removed.
                if (chf.areas[@intCast(span_index)] == null_area) continue;

                // Mark if y extents overlap.
                if (@as(i32, span.y) >= min_y and @as(i32, span.y) <= max_y) {
                    chf.areas[@intCast(span_index)] = area_id;
                }
            }
        }
    }
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "insertSort orders bytes" {
    var data = [9]u8{ 9, 3, 7, 3, 0, 255, 1, 8, 2 };
    insertSort(&data);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 3, 7, 8, 9, 255 }, &data);
}

test "offsetPoly bevels convex corners and mitres the others" {
    // Counter-clockwise on the xz-plane (x right, z up): every corner is
    // convex and sharp enough to bevel, so each gives two vertices. An
    // offset of 0 leaves them on the corner.
    const ccw = [9]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    var out: [18]f32 = undefined;
    try testing.expectEqual(6, offsetPoly(&ccw, 0, &out));
    const expected = [18]f32{ 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1 };
    try testing.expectEqualSlices(f32, &expected, &out);

    // Clockwise, the corners mitre: one vertex each.
    const cw = [9]f32{ 0, 0, 0, 0, 0, 1, 1, 0, 0 };
    try testing.expectEqual(3, offsetPoly(&cw, 0, &out));
    try testing.expectEqualSlices(f32, &cw, out[0..9]);
}

test "offsetPoly gives 0 when the result does not fit" {
    const ccw = [9]f32{ 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    var out: [15]f32 = undefined;
    try testing.expectEqual(0, offsetPoly(&ccw, 0.5, &out));
}
