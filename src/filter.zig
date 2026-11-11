// An altered version of Recast from recastnavigation 1.6.0, translated to
// Zig. Copyright (c) 2009-2010 Mikko Mononen memon@inside.org; zlib licence,
// see LICENSE.

//! Heightfield filters: they mark spans walkable or not by the spans around
//! them and the space above them. Translated from RecastFilter.cpp.

const std = @import("std");

const recast = @import("recast.zig");
const Context = recast.Context;
const Heightfield = recast.Heightfield;
const Span = recast.Span;

/// The ceiling of the top span of a column.
const max_heightfield_height = 0xffff;

/// Marks an unwalkable span walkable, with the area id of the walkable span
/// just below it, when its top is at most `walkable_climb` above that span's
/// top, so an agent can step over low obstacles such as curbs. Only spans
/// walkable before the filter make the one above them walkable.
pub fn filterLowHangingWalkableObstacles(ctx: Context, walkable_climb: i32, hf: *Heightfield) void {
    ctx.startTimer(.filter_low_obstacles);
    defer ctx.stopTimer(.filter_low_obstacles);

    for (hf.spans) |column| {
        var previous_span: ?*Span = null;
        var previous_was_walkable = false;
        var previous_area_id: u6 = recast.null_area;

        var span = column;
        while (span) |s| : ({
            previous_span = s;
            span = s.next;
        }) {
            const walkable = s.area != recast.null_area;

            // An unwalkable span just above a walkable one, close enough to
            // climb, becomes walkable too.
            if (!walkable and previous_was_walkable and
                @as(i32, s.smax) - @as(i32, previous_span.?.smax) <= walkable_climb)
            {
                s.area = previous_area_id;
            }

            // Keep whether the span was walkable before this filter, so a
            // stack of unwalkable spans does not become walkable one by one.
            previous_was_walkable = walkable;
            previous_area_id = s.area;
        }
    }
}

/// Marks walkable spans at ledges unwalkable: a span with a drop of more
/// than `walkable_climb` to a neighbor an agent fits into, or with no
/// neighbor on some side, and a span whose reachable neighbors' floors
/// differ by more than `walkable_climb`, as on a steep slope.
pub fn filterLedgeSpans(
    ctx: Context,
    walkable_height: i32,
    walkable_climb: i32,
    hf: *Heightfield,
) void {
    ctx.startTimer(.filter_border);
    defer ctx.stopTimer(.filter_border);

    const x_size = hf.width;
    const z_size = hf.height;

    var z: i32 = 0;
    while (z < z_size) : (z += 1) {
        var x: i32 = 0;
        while (x < x_size) : (x += 1) {
            var span = hf.spans[@intCast(x + z * x_size)];
            while (span) |s| : (span = s.next) {
                // Skip unwalkable spans.
                if (s.area == recast.null_area) continue;

                const floor: i32 = s.smax;
                const ceiling: i32 = if (s.next) |next| next.smin else max_heightfield_height;

                // The lowest floor of the neighbor spans an agent fits into,
                // relative to this floor, whatever the slope.
                var lowest_neighbor_floor_difference: i32 = max_heightfield_height;

                // The lowest and highest floors of the neighbors an agent
                // can step to.
                var lowest_traversable_neighbor_floor: i32 = s.smax;
                var highest_traversable_neighbor_floor: i32 = s.smax;

                for ([4]u2{ 0, 1, 2, 3 }) |direction| {
                    const neighbor_x = x + recast.getDirOffsetX(direction);
                    const neighbor_z = z + recast.getDirOffsetY(direction);

                    // Outside the field counts as a drop.
                    if (neighbor_x < 0 or neighbor_z < 0 or
                        neighbor_x >= x_size or neighbor_z >= z_size)
                    {
                        lowest_neighbor_floor_difference = -walkable_climb - 1;
                        break;
                    }

                    var neighbor_span = hf.spans[@intCast(neighbor_x + neighbor_z * x_size)];

                    // The open space below the neighbor's lowest span has no
                    // floor: if an agent fits into it, it is a drop.
                    var neighbor_ceiling: i32 =
                        if (neighbor_span) |n| n.smin else max_heightfield_height;
                    if (@min(ceiling, neighbor_ceiling) - floor >= walkable_height) {
                        lowest_neighbor_floor_difference = -walkable_climb - 1;
                        break;
                    }

                    // For each span in the neighboring column...
                    while (neighbor_span) |n| : (neighbor_span = n.next) {
                        const neighbor_floor: i32 = n.smax;
                        neighbor_ceiling =
                            if (n.next) |next| next.smin else max_heightfield_height;

                        // Skip neighbors without room for an agent to move
                        // between them and this span.
                        const gap_top = @min(ceiling, neighbor_ceiling);
                        const gap_bottom = @max(floor, neighbor_floor);
                        if (gap_top - gap_bottom < walkable_height) continue;

                        const neighbor_floor_difference = neighbor_floor - floor;
                        lowest_neighbor_floor_difference = @min(
                            lowest_neighbor_floor_difference,
                            neighbor_floor_difference,
                        );

                        // Track the floors within `walkable_climb`: the ones an
                        // agent can step to.
                        if (@abs(neighbor_floor_difference) <= walkable_climb) {
                            lowest_traversable_neighbor_floor = @min(
                                lowest_traversable_neighbor_floor,
                                neighbor_floor,
                            );
                            highest_traversable_neighbor_floor = @max(
                                highest_traversable_neighbor_floor,
                                neighbor_floor,
                            );
                        } else if (neighbor_floor_difference < -walkable_climb) {
                            // A drop: this span is a ledge whatever the
                            // other neighbors are.
                            break;
                        }
                    }
                }

                // A drop of more than `walkable_climb` to a neighbor an agent
                // fits into makes a ledge.
                if (lowest_neighbor_floor_difference < -walkable_climb) {
                    s.area = recast.null_area;
                } else if (highest_traversable_neighbor_floor -
                    lowest_traversable_neighbor_floor > walkable_climb)
                {
                    // Reachable floors too far apart make a steep slope.
                    s.area = recast.null_area;
                }
            }
        }
    }
}

/// Marks walkable spans unwalkable when the open space above them is lower
/// than `walkable_height`.
pub fn filterWalkableLowHeightSpans(ctx: Context, walkable_height: i32, hf: *Heightfield) void {
    ctx.startTimer(.filter_walkable);
    defer ctx.stopTimer(.filter_walkable);

    for (hf.spans) |column| {
        var span = column;
        while (span) |s| : (span = s.next) {
            const floor: i32 = s.smax;
            const ceiling: i32 = if (s.next) |next| next.smin else max_heightfield_height;
            if (ceiling - floor < walkable_height) s.area = recast.null_area;
        }
    }
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;
const rasterization = @import("rasterization.zig");

fn columnAreas(hf: *const Heightfield, column: usize, areas: []u6) []u6 {
    var count: usize = 0;
    var span = hf.spans[column];
    while (span) |s| : (span = s.next) {
        areas[count] = s.area;
        count += 1;
    }
    return areas[0..count];
}

test "a low obstacle becomes walkable, the span above it does not" {
    const gpa = testing.allocator;
    var hf = try Heightfield.init(gpa, 1, 1, &.{ 0, 0, 0 }, &.{ 1, 1, 1 }, 1, 1);
    defer hf.deinit(gpa);
    try rasterization.addSpan(.none, gpa, &hf, 0, 0, 0, 10, recast.walkable_area, 1);
    try rasterization.addSpan(.none, gpa, &hf, 0, 0, 11, 12, recast.null_area, 1);
    try rasterization.addSpan(.none, gpa, &hf, 0, 0, 13, 14, recast.null_area, 1);

    filterLowHangingWalkableObstacles(.none, 2, &hf);
    var areas: [3]u6 = undefined;
    try testing.expectEqualSlices(u6, &.{ 63, 63, 0 }, columnAreas(&hf, 0, &areas));
}

test "spans without headroom or beside the field's edge become unwalkable" {
    const gpa = testing.allocator;
    var hf = try Heightfield.init(gpa, 1, 1, &.{ 0, 0, 0 }, &.{ 1, 1, 1 }, 1, 1);
    defer hf.deinit(gpa);
    try rasterization.addSpan(.none, gpa, &hf, 0, 0, 0, 10, recast.walkable_area, 1);
    try rasterization.addSpan(.none, gpa, &hf, 0, 0, 12, 20, recast.walkable_area, 1);

    filterWalkableLowHeightSpans(.none, 3, &hf);
    var areas: [2]u6 = undefined;
    try testing.expectEqualSlices(u6, &.{ 0, 63 }, columnAreas(&hf, 0, &areas));

    filterLedgeSpans(.none, 3, 2, &hf);
    try testing.expectEqualSlices(u6, &.{ 0, 0 }, columnAreas(&hf, 0, &areas));
}
