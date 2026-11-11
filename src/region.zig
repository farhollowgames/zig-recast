// An altered version of Recast from recastnavigation 1.6.0, translated to
// Zig. Copyright (c) 2009-2010 Mikko Mononen memon@inside.org; zlib licence,
// see LICENSE.

//! Region partitioning of a compact heightfield: the distance field, and the
//! watershed, monotone and layer partitions that split the walkable spans
//! into regions. Translated from RecastRegion.cpp.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const recast = @import("recast.zig");
const Context = recast.Context;
const CompactHeightfield = recast.CompactHeightfield;
const getCon = recast.getCon;
const getDirOffsetX = recast.getDirOffsetX;
const getDirOffsetY = recast.getDirOffsetY;
const border_reg = recast.border_reg;
const not_connected = recast.not_connected;
const null_area = recast.null_area;

/// How building regions can fail.
pub const BuildRegionsError = Allocator.Error || error{
    /// The watershed needs more region ids than 16 bits hold.
    RegionIdOverflow,
};

const directions = [4]u2{ 0, 1, 2, 3 };

/// A span waiting in a level stack: its column, and its index, or -1 once
/// it has a region.
const LevelStackEntry = struct {
    x: i32,
    y: i32,
    index: i32,
};

/// The index of span `con` of column (x, y): how a connection names a
/// neighbour.
fn spanIndexAt(chf: *const CompactHeightfield, x: i32, y: i32, con: i32) usize {
    const first: usize = chf.cells[@intCast(x + y * chf.width)].index;
    return first + @as(usize, @intCast(con));
}

/// Each span's distance to the nearest border or area change into `src`, 2
/// per step along an axis and 3 per diagonal step; returns the largest.
fn calculateDistanceField(chf: *const CompactHeightfield, src: []u16) u16 {
    const w = chf.width;
    const h = chf.height;

    // Init distance and points.
    @memset(src, 0xffff);

    // Mark boundary cells.
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (first..first + c.count) |i| {
                const s = chf.spans[i];
                const area = chf.areas[i];
                var nc: i32 = 0;
                for (directions) |dir| {
                    if (getCon(s, dir) != not_connected) {
                        const ax = x + getDirOffsetX(dir);
                        const ay = y + getDirOffsetY(dir);
                        const ai = spanIndexAt(chf, ax, ay, getCon(s, dir));
                        if (area == chf.areas[ai]) nc += 1;
                    }
                }
                if (nc != 4) src[i] = 0;
            }
        }
    }

    // Pass 1
    y = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (first..first + c.count) |i| {
                const s = chf.spans[i];
                if (getCon(s, 0) != not_connected) {
                    // (-1,0)
                    const ax = x + getDirOffsetX(0);
                    const ay = y + getDirOffsetY(0);
                    const ai = spanIndexAt(chf, ax, ay, getCon(s, 0));
                    const a_span = chf.spans[ai];
                    if (@as(i32, src[ai]) + 2 < src[i]) src[i] = src[ai] + 2;

                    // (-1,-1)
                    if (getCon(a_span, 3) != not_connected) {
                        const aax = ax + getDirOffsetX(3);
                        const aay = ay + getDirOffsetY(3);
                        const aai = spanIndexAt(chf, aax, aay, getCon(a_span, 3));
                        if (@as(i32, src[aai]) + 3 < src[i]) src[i] = src[aai] + 3;
                    }
                }
                if (getCon(s, 3) != not_connected) {
                    // (0,-1)
                    const ax = x + getDirOffsetX(3);
                    const ay = y + getDirOffsetY(3);
                    const ai = spanIndexAt(chf, ax, ay, getCon(s, 3));
                    const a_span = chf.spans[ai];
                    if (@as(i32, src[ai]) + 2 < src[i]) src[i] = src[ai] + 2;

                    // (1,-1)
                    if (getCon(a_span, 2) != not_connected) {
                        const aax = ax + getDirOffsetX(2);
                        const aay = ay + getDirOffsetY(2);
                        const aai = spanIndexAt(chf, aax, aay, getCon(a_span, 2));
                        if (@as(i32, src[aai]) + 3 < src[i]) src[i] = src[aai] + 3;
                    }
                }
            }
        }
    }

    // Pass 2
    y = h - 1;
    while (y >= 0) : (y -= 1) {
        var x: i32 = w - 1;
        while (x >= 0) : (x -= 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (first..first + c.count) |i| {
                const s = chf.spans[i];
                if (getCon(s, 2) != not_connected) {
                    // (1,0)
                    const ax = x + getDirOffsetX(2);
                    const ay = y + getDirOffsetY(2);
                    const ai = spanIndexAt(chf, ax, ay, getCon(s, 2));
                    const a_span = chf.spans[ai];
                    if (@as(i32, src[ai]) + 2 < src[i]) src[i] = src[ai] + 2;

                    // (1,1)
                    if (getCon(a_span, 1) != not_connected) {
                        const aax = ax + getDirOffsetX(1);
                        const aay = ay + getDirOffsetY(1);
                        const aai = spanIndexAt(chf, aax, aay, getCon(a_span, 1));
                        if (@as(i32, src[aai]) + 3 < src[i]) src[i] = src[aai] + 3;
                    }
                }
                if (getCon(s, 1) != not_connected) {
                    // (0,1)
                    const ax = x + getDirOffsetX(1);
                    const ay = y + getDirOffsetY(1);
                    const ai = spanIndexAt(chf, ax, ay, getCon(s, 1));
                    const a_span = chf.spans[ai];
                    if (@as(i32, src[ai]) + 2 < src[i]) src[i] = src[ai] + 2;

                    // (-1,1)
                    if (getCon(a_span, 0) != not_connected) {
                        const aax = ax + getDirOffsetX(0);
                        const aay = ay + getDirOffsetY(0);
                        const aai = spanIndexAt(chf, aax, aay, getCon(a_span, 0));
                        if (@as(i32, src[aai]) + 3 < src[i]) src[i] = src[aai] + 3;
                    }
                }
            }
        }
    }

    var max_dist: u16 = 0;
    for (src) |d| max_dist = @max(d, max_dist);
    return max_dist;
}

/// Blurs `src` into `dst`: each span farther than `thr` * 2 from the border
/// gets the rounded mean of itself and its 8 neighbours, a missing neighbour
/// counting as the span itself.
fn boxBlur(chf: *const CompactHeightfield, thr: i32, src: []const u16, dst: []u16) void {
    const w = chf.width;
    const h = chf.height;
    const threshold = thr * 2;

    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (first..first + c.count) |i| {
                const s = chf.spans[i];
                const cd = src[i];
                if (cd <= threshold) {
                    dst[i] = cd;
                    continue;
                }

                var d: i32 = cd;
                for (directions) |dir| {
                    if (getCon(s, dir) != not_connected) {
                        const ax = x + getDirOffsetX(dir);
                        const ay = y + getDirOffsetY(dir);
                        const ai = spanIndexAt(chf, ax, ay, getCon(s, dir));
                        d += src[ai];

                        const a_span = chf.spans[ai];
                        const dir2 = dir +% 1;
                        if (getCon(a_span, dir2) != not_connected) {
                            const ax2 = ax + getDirOffsetX(dir2);
                            const ay2 = ay + getDirOffsetY(dir2);
                            const ai2 = spanIndexAt(chf, ax2, ay2, getCon(a_span, dir2));
                            d += src[ai2];
                        } else {
                            d += cd;
                        }
                    } else {
                        d += @as(i32, cd) * 2;
                    }
                }
                dst[i] = @intCast(@divTrunc(d + 5, 9));
            }
        }
    }
}

/// Floods region `r` from span `i` of column (x, y) over the connected spans
/// of the same area at least `level` - 2 from the border, stopping at spans
/// next to another region. Returns whether any span joined the region.
fn floodRegion(
    gpa: Allocator,
    x: i32,
    y: i32,
    i: usize,
    level: u16,
    r: u16,
    chf: *const CompactHeightfield,
    src_reg: []u16,
    src_dist: []u16,
    stack: *std.ArrayList(LevelStackEntry),
) Allocator.Error!bool {
    const area = chf.areas[i];

    // Flood fill mark region.
    stack.clearRetainingCapacity();
    try stack.append(gpa, .{ .x = x, .y = y, .index = @intCast(i) });
    src_reg[i] = r;
    src_dist[i] = 0;

    const lev: u16 = if (level >= 2) level - 2 else 0;
    var count: i32 = 0;

    while (stack.pop()) |back| {
        const cx = back.x;
        const cy = back.y;
        const ci: usize = @intCast(back.index);

        const cs = chf.spans[ci];

        // Check if any of the neighbours already have a valid region set.
        var ar: u16 = 0;
        for (directions) |dir| {
            // 8 connected
            if (getCon(cs, dir) != not_connected) {
                const ax = cx + getDirOffsetX(dir);
                const ay = cy + getDirOffsetY(dir);
                const ai = spanIndexAt(chf, ax, ay, getCon(cs, dir));
                if (chf.areas[ai] != area) continue;
                const nr = src_reg[ai];
                // Do not take borders into account.
                if ((nr & border_reg) != 0) continue;
                if (nr != 0 and nr != r) {
                    ar = nr;
                    break;
                }

                const a_span = chf.spans[ai];

                const dir2 = dir +% 1;
                if (getCon(a_span, dir2) != not_connected) {
                    const ax2 = ax + getDirOffsetX(dir2);
                    const ay2 = ay + getDirOffsetY(dir2);
                    const ai2 = spanIndexAt(chf, ax2, ay2, getCon(a_span, dir2));
                    if (chf.areas[ai2] != area) continue;
                    const nr2 = src_reg[ai2];
                    if (nr2 != 0 and nr2 != r) {
                        ar = nr2;
                        break;
                    }
                }
            }
        }
        if (ar != 0) {
            src_reg[ci] = 0;
            continue;
        }

        count += 1;

        // Expand neighbours.
        for (directions) |dir| {
            if (getCon(cs, dir) != not_connected) {
                const ax = cx + getDirOffsetX(dir);
                const ay = cy + getDirOffsetY(dir);
                const ai = spanIndexAt(chf, ax, ay, getCon(cs, dir));
                if (chf.areas[ai] != area) continue;
                if (chf.dist[ai] >= lev and src_reg[ai] == 0) {
                    src_reg[ai] = r;
                    src_dist[ai] = 0;
                    try stack.append(gpa, .{ .x = ax, .y = ay, .index = @intCast(ai) });
                }
            }
        }
    }

    return count > 0;
}

/// A change to a span's region, kept until a pass of `expandRegions` ends so
/// the pass reads only the regions it started with.
const DirtyEntry = struct {
    index: i32,
    region: u16,
    distance2: u16,
};

/// Grows the regions into the unassigned spans of `stack`, or with
/// `fill_stack` into every unassigned span at least `level` from the border,
/// a ring per pass: each span joins the neighbouring region it is closest to
/// through. Stops when a pass assigns nothing, or after `max_iter` passes
/// when `level` is above 0.
fn expandRegions(
    gpa: Allocator,
    max_iter: i32,
    level: u16,
    chf: *const CompactHeightfield,
    src_reg: []u16,
    src_dist: []u16,
    stack: *std.ArrayList(LevelStackEntry),
    fill_stack: bool,
) Allocator.Error!void {
    const w = chf.width;
    const h = chf.height;

    if (fill_stack) {
        // Find cells revealed by the raised level.
        stack.clearRetainingCapacity();
        var y: i32 = 0;
        while (y < h) : (y += 1) {
            var x: i32 = 0;
            while (x < w) : (x += 1) {
                const c = chf.cells[@intCast(x + y * w)];
                const first: usize = c.index;
                for (first..first + c.count) |i| {
                    if (chf.dist[i] >= level and src_reg[i] == 0 and chf.areas[i] != null_area) {
                        try stack.append(gpa, .{ .x = x, .y = y, .index = @intCast(i) });
                    }
                }
            }
        }
    } else {
        // Mark all cells which already have a region.
        for (stack.items) |*entry| {
            if (src_reg[@intCast(entry.index)] != 0) entry.index = -1;
        }
    }

    var dirty_entries: std.ArrayList(DirtyEntry) = .empty;
    defer dirty_entries.deinit(gpa);
    var iter: i32 = 0;
    while (stack.items.len > 0) {
        var failed: usize = 0;
        dirty_entries.clearRetainingCapacity();

        for (stack.items) |*entry| {
            const x = entry.x;
            const y = entry.y;
            if (entry.index < 0) {
                failed += 1;
                continue;
            }
            const i: usize = @intCast(entry.index);

            var r = src_reg[i];
            var d2: u16 = 0xffff;
            const area = chf.areas[i];
            const s = chf.spans[i];
            for (directions) |dir| {
                if (getCon(s, dir) == not_connected) continue;
                const ax = x + getDirOffsetX(dir);
                const ay = y + getDirOffsetY(dir);
                const ai = spanIndexAt(chf, ax, ay, getCon(s, dir));
                if (chf.areas[ai] != area) continue;
                if (src_reg[ai] > 0 and (src_reg[ai] & border_reg) == 0) {
                    if (@as(i32, src_dist[ai]) + 2 < d2) {
                        r = src_reg[ai];
                        d2 = src_dist[ai] + 2;
                    }
                }
            }
            if (r != 0) {
                // Mark as used.
                entry.index = -1;
                try dirty_entries.append(gpa, .{
                    .index = @intCast(i),
                    .region = r,
                    .distance2 = d2,
                });
            } else {
                failed += 1;
            }
        }

        // Copy entries that differ between src and dst to keep them in sync.
        for (dirty_entries.items) |entry| {
            const index: usize = @intCast(entry.index);
            src_reg[index] = entry.region;
            src_dist[index] = entry.distance2;
        }

        if (failed == stack.items.len) break;

        if (level > 0) {
            iter += 1;
            if (iter >= max_iter) break;
        }
    }
}

/// Clears `stacks` and puts each unassigned walkable span in the stack of its
/// distance band below `start_level`, 2^`log_levels_per_stack` levels per
/// stack; spans above `start_level` go to the first stack, spans below the
/// last band to none.
fn sortCellsByLevel(
    gpa: Allocator,
    start_level: u16,
    chf: *const CompactHeightfield,
    src_reg: []const u16,
    stacks: []std.ArrayList(LevelStackEntry),
    log_levels_per_stack: u4,
) Allocator.Error!void {
    const w = chf.width;
    const h = chf.height;
    const start = start_level >> log_levels_per_stack;

    for (stacks) |*stack| stack.clearRetainingCapacity();

    // Put all cells in the level range into the appropriate stacks.
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (first..first + c.count) |i| {
                if (chf.areas[i] == null_area or src_reg[i] != 0) continue;

                const level: i32 = chf.dist[i] >> log_levels_per_stack;
                var s_id: i32 = @as(i32, start) - level;
                if (s_id >= @as(i32, @intCast(stacks.len))) continue;
                if (s_id < 0) s_id = 0;

                try stacks[@intCast(s_id)].append(gpa, .{ .x = x, .y = y, .index = @intCast(i) });
            }
        }
    }
}

/// Appends the entries of `src_stack` still without a region to `dst_stack`.
fn appendStacks(
    gpa: Allocator,
    src_stack: []const LevelStackEntry,
    dst_stack: *std.ArrayList(LevelStackEntry),
    src_reg: []const u16,
) Allocator.Error!void {
    for (src_stack) |entry| {
        const i = entry.index;
        if (i < 0 or src_reg[@intCast(i)] != 0) continue;
        try dst_stack.append(gpa, entry);
    }
}

/// A region while regions are merged and filtered.
const Region = struct {
    /// Number of spans belonging to this region.
    span_count: i32,
    /// The id the region's spans get; merged and removed regions change it.
    id: u16,
    area_type: u8,
    remap: bool,
    visited: bool,
    overlap: bool,
    connects_to_border: bool,
    ymin: u16,
    ymax: u16,
    /// The ids of the neighbouring regions around the region's outline, in
    /// order; 0 where the outline borders no region.
    connections: std.ArrayList(i32),
    /// The ids of the regions above or below the region's spans.
    floors: std.ArrayList(i32),

    fn init(id: u16) Region {
        return .{
            .span_count = 0,
            .id = id,
            .area_type = 0,
            .remap = false,
            .visited = false,
            .overlap = false,
            .connects_to_border = false,
            .ymin = 0xffff,
            .ymax = 0,
            .connections = .empty,
            .floors = .empty,
        };
    }
};

fn deinitRegions(gpa: Allocator, regions: []Region) void {
    for (regions) |*reg| {
        reg.connections.deinit(gpa);
        reg.floors.deinit(gpa);
    }
    gpa.free(regions);
}

/// Removes repeated neighbours next to each other in `reg`'s outline,
/// keeping at least one.
fn removeAdjacentNeighbours(reg: *Region) void {
    const connections = &reg.connections;
    var i: usize = 0;
    while (i < connections.items.len and connections.items.len > 1) {
        const ni = (i + 1) % connections.items.len;
        if (connections.items[i] == connections.items[ni]) {
            // Remove duplicate
            _ = connections.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

fn replaceNeighbour(reg: *Region, old_id: u16, new_id: u16) void {
    var nei_changed = false;
    for (reg.connections.items) |*connection| {
        if (connection.* == old_id) {
            connection.* = new_id;
            nei_changed = true;
        }
    }
    for (reg.floors.items) |*floor| {
        if (floor.* == old_id) floor.* = new_id;
    }
    if (nei_changed) removeAdjacentNeighbours(reg);
}

fn canMergeWithRegion(rega: *const Region, regb: *const Region) bool {
    if (rega.area_type != regb.area_type) return false;
    var n: i32 = 0;
    for (rega.connections.items) |connection| {
        if (connection == regb.id) n += 1;
    }
    if (n > 1) return false;
    for (rega.floors.items) |floor| {
        if (floor == regb.id) return false;
    }
    return true;
}

fn addUniqueFloorRegion(gpa: Allocator, reg: *Region, n: i32) Allocator.Error!void {
    for (reg.floors.items) |floor| {
        if (floor == n) return;
    }
    try reg.floors.append(gpa, n);
}

/// Merges `regb` into `rega`, joining their outlines where they touch.
/// Returns false, changing nothing, if they do not touch.
fn mergeRegions(gpa: Allocator, rega: *Region, regb: *Region) Allocator.Error!bool {
    const aid = rega.id;
    const bid = regb.id;

    // Duplicate current neighbourhood.
    const acon = try gpa.dupe(i32, rega.connections.items);
    defer gpa.free(acon);
    const bcon = &regb.connections;

    // Find insertion point on A.
    const insa = std.mem.findScalar(i32, acon, bid) orelse return false;

    // Find insertion point on B.
    const insb = std.mem.findScalar(i32, bcon.items, aid) orelse return false;

    // Merge neighbours.
    rega.connections.clearRetainingCapacity();
    {
        const ni = acon.len;
        var i: usize = 0;
        while (i + 1 < ni) : (i += 1) {
            try rega.connections.append(gpa, acon[(insa + 1 + i) % ni]);
        }
    }
    {
        const ni = bcon.items.len;
        var i: usize = 0;
        while (i + 1 < ni) : (i += 1) {
            try rega.connections.append(gpa, bcon.items[(insb + 1 + i) % ni]);
        }
    }

    removeAdjacentNeighbours(rega);

    for (regb.floors.items) |floor| try addUniqueFloorRegion(gpa, rega, floor);
    rega.span_count += regb.span_count;
    regb.span_count = 0;
    regb.connections.clearRetainingCapacity();

    return true;
}

fn isRegionConnectedToBorder(reg: *const Region) bool {
    // Region is connected to border if one of the neighbours is null id.
    for (reg.connections.items) |connection| {
        if (connection == 0) return true;
    }
    return false;
}

/// Whether the neighbour of span `i` of column (x, y) in direction `dir` is
/// missing or in another region.
fn isSolidEdge(
    chf: *const CompactHeightfield,
    src_reg: []const u16,
    x: i32,
    y: i32,
    i: usize,
    dir: u2,
) bool {
    const s = chf.spans[i];
    var r: u16 = 0;
    if (getCon(s, dir) != not_connected) {
        const ax = x + getDirOffsetX(dir);
        const ay = y + getDirOffsetY(dir);
        const ai = spanIndexAt(chf, ax, ay, getCon(s, dir));
        r = src_reg[ai];
    }
    if (r == src_reg[i]) return false;
    return true;
}

/// Walks the outline of the region of span `i` of column (x, y), starting at
/// its edge in direction `dir`, and appends to `cont` the region beyond each
/// stretch of the outline. Removes repeats next to each other after the walk,
/// which can leave `cont` empty.
fn walkContour(
    gpa: Allocator,
    start_x: i32,
    start_y: i32,
    start_i: usize,
    start_dir: u2,
    chf: *const CompactHeightfield,
    src_reg: []const u16,
    cont: *std.ArrayList(i32),
) Allocator.Error!void {
    var x = start_x;
    var y = start_y;
    var i = start_i;
    var dir = start_dir;

    const ss = chf.spans[i];
    var cur_reg: u16 = 0;
    if (getCon(ss, dir) != not_connected) {
        const ax = x + getDirOffsetX(dir);
        const ay = y + getDirOffsetY(dir);
        const ai = spanIndexAt(chf, ax, ay, getCon(ss, dir));
        cur_reg = src_reg[ai];
    }
    try cont.append(gpa, cur_reg);

    var iter: i32 = 1;
    while (iter < 40000) : (iter += 1) {
        const s = chf.spans[i];

        if (isSolidEdge(chf, src_reg, x, y, i, dir)) {
            // Choose the edge corner
            var r: u16 = 0;
            if (getCon(s, dir) != not_connected) {
                const ax = x + getDirOffsetX(dir);
                const ay = y + getDirOffsetY(dir);
                const ai = spanIndexAt(chf, ax, ay, getCon(s, dir));
                r = src_reg[ai];
            }
            if (r != cur_reg) {
                cur_reg = r;
                try cont.append(gpa, cur_reg);
            }

            // Rotate CW
            dir +%= 1;
        } else {
            var ni: i32 = -1;
            const nx = x + getDirOffsetX(dir);
            const ny = y + getDirOffsetY(dir);
            if (getCon(s, dir) != not_connected) {
                const nc = chf.cells[@intCast(nx + ny * chf.width)];
                ni = @as(i32, nc.index) + getCon(s, dir);
            }
            if (ni == -1) {
                // Should not happen.
                return;
            }
            x = nx;
            y = ny;
            i = @intCast(ni);
            // Rotate CCW
            dir +%= 3;
        }

        if (start_i == i and start_dir == dir) break;
    }

    // Remove adjacent duplicates.
    if (cont.items.len > 1) {
        var j: usize = 0;
        while (j < cont.items.len) {
            const nj = (j + 1) % cont.items.len;
            if (cont.items[j] == cont.items[nj]) {
                _ = cont.orderedRemove(j);
            } else {
                j += 1;
            }
        }
    }
}

/// Removes groups of connected regions smaller than `min_region_area` spans
/// that reach no tile border, merges regions of at most `merge_region_size`
/// spans, or not reaching a border, into their smallest mergeable neighbour,
/// and renumbers the regions from 1 in `src_reg`. Regions with spans above
/// one another go to `overlaps`. Returns the largest region id.
fn mergeAndFilterRegions(
    ctx: Context,
    gpa: Allocator,
    min_region_area: i32,
    merge_region_size: i32,
    max_region_id: u16,
    chf: *const CompactHeightfield,
    src_reg: []u16,
    overlaps: *std.ArrayList(i32),
) Allocator.Error!u16 {
    const w = chf.width;
    const h = chf.height;

    const nreg: usize = @as(usize, max_region_id) + 1;
    const regions = gpa.alloc(Region, nreg) catch |err| {
        ctx.log(.err, "mergeAndFilterRegions: Out of memory 'regions' ({d}).", .{nreg});
        return err;
    };
    // Construct regions
    for (regions, 0..) |*reg, i| reg.* = .init(@intCast(i));
    defer deinitRegions(gpa, regions);

    // Find edge of a region and find connections around the contour.
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            const end = first + c.count;
            for (first..end) |i| {
                const r = src_reg[i];
                if (r == 0 or r >= nreg) continue;

                const reg = &regions[r];
                reg.span_count += 1;

                // Update floors.
                for (first..end) |j| {
                    if (i == j) continue;
                    const floor_id = src_reg[j];
                    if (floor_id == 0 or floor_id >= nreg) continue;
                    if (floor_id == r) reg.overlap = true;
                    try addUniqueFloorRegion(gpa, reg, floor_id);
                }

                // Have found contour
                if (reg.connections.items.len > 0) continue;

                reg.area_type = chf.areas[i];

                // Check if this cell is next to a border.
                const ndir: ?u2 = for (directions) |dir| {
                    if (isSolidEdge(chf, src_reg, x, y, i, dir)) break dir;
                } else null;

                if (ndir) |dir| {
                    // The cell is at border.
                    // Walk around the contour to find all the neighbours.
                    try walkContour(gpa, x, y, i, dir, chf, src_reg, &reg.connections);
                }
            }
        }
    }

    // Remove too small regions.
    var stack: std.ArrayList(i32) = .empty;
    defer stack.deinit(gpa);
    var trace: std.ArrayList(i32) = .empty;
    defer trace.deinit(gpa);
    for (regions, 0..) |*reg, i| {
        if (reg.id == 0 or (reg.id & border_reg) != 0) continue;
        if (reg.span_count == 0) continue;
        if (reg.visited) continue;

        // Count the total size of all the connected regions.
        // Also keep track of the regions connects to a tile border.
        var connects_to_border = false;
        var span_count: i32 = 0;
        stack.clearRetainingCapacity();
        trace.clearRetainingCapacity();

        reg.visited = true;
        try stack.append(gpa, @intCast(i));

        while (stack.pop()) |ri| {
            const creg = &regions[@intCast(ri)];

            span_count += creg.span_count;
            try trace.append(gpa, ri);

            for (creg.connections.items) |connection| {
                if ((connection & border_reg) != 0) {
                    connects_to_border = true;
                    continue;
                }
                const neireg = &regions[@intCast(connection)];
                if (neireg.visited) continue;
                if (neireg.id == 0 or (neireg.id & border_reg) != 0) continue;
                // Visit
                try stack.append(gpa, neireg.id);
                neireg.visited = true;
            }
        }

        // If the accumulated regions size is too small, remove it.
        // Do not remove areas which connect to tile borders
        // as their size cannot be estimated correctly and removing them
        // can potentially remove necessary areas.
        if (span_count < min_region_area and !connects_to_border) {
            // Kill all visited regions.
            for (trace.items) |t| {
                regions[@intCast(t)].span_count = 0;
                regions[@intCast(t)].id = 0;
            }
        }
    }

    // Merge too small regions to neighbour regions.
    while (true) {
        var merge_count: i32 = 0;
        for (regions) |*reg| {
            if (reg.id == 0 or (reg.id & border_reg) != 0) continue;
            if (reg.overlap) continue;
            if (reg.span_count == 0) continue;

            // Check to see if the region should be merged.
            if (reg.span_count > merge_region_size and isRegionConnectedToBorder(reg)) continue;

            // Small region with more than 1 connection.
            // Or region which is not connected to a border at all.
            // Find smallest neighbour region that connects to this one.
            var smallest: i32 = 0xfffffff;
            var merge_id = reg.id;
            for (reg.connections.items) |connection| {
                if ((connection & border_reg) != 0) continue;
                const mreg = &regions[@intCast(connection)];
                if (mreg.id == 0 or (mreg.id & border_reg) != 0 or mreg.overlap) continue;
                if (mreg.span_count < smallest and
                    canMergeWithRegion(reg, mreg) and
                    canMergeWithRegion(mreg, reg))
                {
                    smallest = mreg.span_count;
                    merge_id = mreg.id;
                }
            }
            // Found new id.
            if (merge_id != reg.id) {
                const old_id = reg.id;
                const target = &regions[merge_id];

                // Merge neighbours.
                if (try mergeRegions(gpa, target, reg)) {
                    // Fixup regions pointing to current region.
                    for (regions) |*other| {
                        if (other.id == 0 or (other.id & border_reg) != 0) continue;
                        // If another region was already merged into current region
                        // change the nid of the previous region too.
                        if (other.id == old_id) other.id = merge_id;
                        // Replace the current region with the new one if the
                        // current regions is neighbour.
                        replaceNeighbour(other, old_id, merge_id);
                    }
                    merge_count += 1;
                }
            }
        }
        if (merge_count <= 0) break;
    }

    // Compress region Ids.
    for (regions) |*reg| {
        reg.remap = false;
        // Skip nil regions.
        if (reg.id == 0) continue;
        // Skip external regions.
        if ((reg.id & border_reg) != 0) continue;
        reg.remap = true;
    }

    var reg_id_gen: u16 = 0;
    for (regions, 0..) |*reg, i| {
        if (!reg.remap) continue;
        const old_id = reg.id;
        reg_id_gen +%= 1;
        const new_id = reg_id_gen;
        for (regions[i..]) |*other| {
            if (other.id == old_id) {
                other.id = new_id;
                other.remap = false;
            }
        }
    }

    // Remap regions.
    for (src_reg) |*r| {
        if ((r.* & border_reg) == 0) r.* = regions[r.*].id;
    }

    // Return regions that we found to be overlapping.
    for (regions) |*reg| {
        if (reg.overlap) try overlaps.append(gpa, reg.id);
    }

    return reg_id_gen;
}

fn addUniqueConnection(gpa: Allocator, reg: *Region, n: i32) Allocator.Error!void {
    for (reg.connections.items) |connection| {
        if (connection == n) return;
    }
    try reg.connections.append(gpa, n);
}

/// Merges neighbouring monotone regions of one area into layers whose spans
/// never lie above one another, removes layers smaller than
/// `min_region_area` spans that reach no tile border, and renumbers the
/// layers from 1 in `src_reg`. Returns the largest region id.
fn mergeAndFilterLayerRegions(
    ctx: Context,
    gpa: Allocator,
    min_region_area: i32,
    max_region_id: u16,
    chf: *const CompactHeightfield,
    src_reg: []u16,
) Allocator.Error!u16 {
    const w = chf.width;
    const h = chf.height;

    const nreg: usize = @as(usize, max_region_id) + 1;

    // Construct regions
    const regions = gpa.alloc(Region, nreg) catch |err| {
        ctx.log(.err, "mergeAndFilterLayerRegions: Out of memory 'regions' ({d}).", .{nreg});
        return err;
    };
    for (regions, 0..) |*reg, i| reg.* = .init(@intCast(i));
    defer deinitRegions(gpa, regions);

    // Find region neighbours and overlapping regions.
    var lregs: std.ArrayList(i32) = .empty;
    defer lregs.deinit(gpa);
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];

            lregs.clearRetainingCapacity();

            const first: usize = c.index;
            for (first..first + c.count) |i| {
                const s = chf.spans[i];
                const area = chf.areas[i];
                const ri = src_reg[i];
                if (ri == 0 or ri >= nreg) continue;
                const reg = &regions[ri];

                reg.span_count += 1;
                reg.area_type = area;

                reg.ymin = @min(reg.ymin, s.y);
                reg.ymax = @max(reg.ymax, s.y);

                // Collect all region layers.
                try lregs.append(gpa, ri);

                // Update neighbours
                for (directions) |dir| {
                    if (getCon(s, dir) != not_connected) {
                        const ax = x + getDirOffsetX(dir);
                        const ay = y + getDirOffsetY(dir);
                        const ai = spanIndexAt(chf, ax, ay, getCon(s, dir));
                        const rai = src_reg[ai];
                        if (rai > 0 and rai < nreg and rai != ri) {
                            try addUniqueConnection(gpa, reg, rai);
                        }
                        if ((rai & border_reg) != 0) reg.connects_to_border = true;
                    }
                }
            }

            // Update overlapping regions.
            var i: usize = 0;
            while (i + 1 < lregs.items.len) : (i += 1) {
                var j = i + 1;
                while (j < lregs.items.len) : (j += 1) {
                    if (lregs.items[i] != lregs.items[j]) {
                        const region_i = &regions[@intCast(lregs.items[i])];
                        const region_j = &regions[@intCast(lregs.items[j])];
                        try addUniqueFloorRegion(gpa, region_i, lregs.items[j]);
                        try addUniqueFloorRegion(gpa, region_j, lregs.items[i]);
                    }
                }
            }
        }
    }

    // Create 2D layers from regions.
    var layer_id: u16 = 1;

    for (regions) |*reg| reg.id = 0;

    // Merge montone regions to create non-overlapping areas.
    var stack: std.ArrayList(i32) = .empty;
    defer stack.deinit(gpa);
    for (regions[1..], 1..) |*root, i| {
        // Skip already visited.
        if (root.id != 0) continue;

        // Start search.
        root.id = layer_id;

        stack.clearRetainingCapacity();
        try stack.append(gpa, @intCast(i));

        while (stack.items.len > 0) {
            // Pop front
            const reg = &regions[@intCast(stack.items[0])];
            _ = stack.orderedRemove(0);

            for (reg.connections.items) |nei| {
                const regn = &regions[@intCast(nei)];
                // Skip already visited.
                if (regn.id != 0) continue;
                // Skip if different area type, do not connect regions with different area type.
                if (reg.area_type != regn.area_type) continue;
                // Skip if the neighbour is overlapping root region.
                const overlap = std.mem.findScalar(i32, root.floors.items, nei) != null;
                if (overlap) continue;

                // Deepen
                try stack.append(gpa, nei);

                // Mark layer id
                regn.id = layer_id;
                // Merge current layers to root.
                for (regn.floors.items) |floor| try addUniqueFloorRegion(gpa, root, floor);
                root.ymin = @min(root.ymin, regn.ymin);
                root.ymax = @max(root.ymax, regn.ymax);
                root.span_count += regn.span_count;
                regn.span_count = 0;
                root.connects_to_border = root.connects_to_border or regn.connects_to_border;
            }
        }

        layer_id +%= 1;
    }

    // Remove small regions
    for (regions) |*reg| {
        if (reg.span_count > 0 and reg.span_count < min_region_area and !reg.connects_to_border) {
            const reg_id = reg.id;
            for (regions) |*other| {
                if (other.id == reg_id) other.id = 0;
            }
        }
    }

    // Compress region Ids.
    for (regions) |*reg| {
        reg.remap = false;
        // Skip nil regions.
        if (reg.id == 0) continue;
        // Skip external regions.
        if ((reg.id & border_reg) != 0) continue;
        reg.remap = true;
    }

    var reg_id_gen: u16 = 0;
    for (regions, 0..) |*reg, i| {
        if (!reg.remap) continue;
        const old_id = reg.id;
        reg_id_gen +%= 1;
        const new_id = reg_id_gen;
        for (regions[i..]) |*other| {
            if (other.id == old_id) {
                other.id = new_id;
                other.remap = false;
            }
        }
    }

    // Remap regions.
    for (src_reg) |*r| {
        if ((r.* & border_reg) == 0) r.* = regions[r.*].id;
    }

    return reg_id_gen;
}

/// Builds `chf.dist`, each span's distance to the nearest border or area
/// change, blurred, and `chf.max_distance`, the largest before the blur.
/// `buildRegions` needs it. Replaces an existing distance field.
pub fn buildDistanceField(
    ctx: Context,
    gpa: Allocator,
    chf: *CompactHeightfield,
) Allocator.Error!void {
    ctx.startTimer(.build_distancefield);
    defer ctx.stopTimer(.build_distancefield);

    gpa.free(chf.dist);
    chf.dist = &.{};

    const span_count: usize = @intCast(chf.span_count);
    const src = gpa.alloc(u16, span_count) catch |err| {
        ctx.log(.err, "rcBuildDistanceField: Out of memory 'src' ({d}).", .{chf.span_count});
        return err;
    };
    const dst = gpa.alloc(u16, span_count) catch |err| {
        ctx.log(.err, "rcBuildDistanceField: Out of memory 'dst' ({d}).", .{chf.span_count});
        gpa.free(src);
        return err;
    };
    // The blur writes only spans in a column; any other stays 0.
    @memset(dst, 0);

    {
        ctx.startTimer(.build_distancefield_dist);
        defer ctx.stopTimer(.build_distancefield_dist);

        chf.max_distance = calculateDistanceField(chf, src);
    }

    {
        ctx.startTimer(.build_distancefield_blur);
        defer ctx.stopTimer(.build_distancefield_blur);

        // Blur
        boxBlur(chf, 1, src, dst);

        // Store distance.
        chf.dist = dst;
    }

    gpa.free(src);
}

/// Sets the region of the walkable spans in columns [minx, maxx) by
/// [miny, maxy) to `reg_id`.
fn paintRectRegion(
    minx: i32,
    maxx: i32,
    miny: i32,
    maxy: i32,
    reg_id: u16,
    chf: *const CompactHeightfield,
    src_reg: []u16,
) void {
    const w = chf.width;
    var y = miny;
    while (y < maxy) : (y += 1) {
        var x = minx;
        while (x < maxx) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (first..first + c.count) |i| {
                if (chf.areas[i] != null_area) src_reg[i] = reg_id;
            }
        }
    }
}

const null_nei: u16 = 0xffff;

/// A run of spans connected along x in one row of a monotone partition.
const SweepSpan = struct {
    /// Row id.
    rid: u16,
    /// Region id.
    id: u16,
    /// Number of samples.
    ns: u16,
    /// Neighbour id.
    nei: u16,
};

const zero_sweep: SweepSpan = .{ .rid = 0, .id = 0, .ns = 0, .nei = 0 };

/// Paints the four border strips of `border_size` columns with border
/// regions from `id` on; returns the next id.
fn paintBorderRegions(
    chf: *const CompactHeightfield,
    border_size: i32,
    first_id: u16,
    src_reg: []u16,
) u16 {
    const w = chf.width;
    const h = chf.height;
    var id = first_id;
    // Make sure border will not overflow.
    const bw = @min(w, border_size);
    const bh = @min(h, border_size);
    // Paint regions
    paintRectRegion(0, bw, 0, h, id | border_reg, chf, src_reg);
    id += 1;
    paintRectRegion(w - bw, w, 0, h, id | border_reg, chf, src_reg);
    id += 1;
    paintRectRegion(0, w, 0, bh, id | border_reg, chf, src_reg);
    id += 1;
    paintRectRegion(0, w, h - bh, h, id | border_reg, chf, src_reg);
    id += 1;
    return id;
}

/// Gives the walkable spans inside the border monotone regions, a row at a
/// time: spans connected along x form a sweep, and a sweep continues the
/// region of the row before when that region is its only neighbour there
/// and no other sweep touches it; any other sweep gets a new id from
/// `first_id` on. Returns the next unused id. `sweeps` grows when a row has
/// more sweeps than it holds.
fn partitionMonotone(
    gpa: Allocator,
    chf: *const CompactHeightfield,
    border_size: i32,
    first_id: u16,
    src_reg: []u16,
    sweeps: *std.ArrayList(SweepSpan),
) Allocator.Error!u16 {
    const w = chf.width;
    const h = chf.height;
    var id = first_id;

    var prev: std.ArrayList(i32) = .empty;
    defer prev.deinit(gpa);

    // Sweep one line at a time.
    var y = border_size;
    while (y < h - border_size) : (y += 1) {
        // Collect spans from this row.
        try prev.resize(gpa, @as(usize, id) + 1);
        @memset(prev.items, 0);
        var rid: u16 = 1;

        var x = border_size;
        while (x < w - border_size) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (first..first + c.count) |i| {
                const s = chf.spans[i];
                if (chf.areas[i] == null_area) continue;

                // -x
                var previd: u16 = 0;
                if (getCon(s, 0) != not_connected) {
                    const ax = x + getDirOffsetX(0);
                    const ay = y + getDirOffsetY(0);
                    const ai = spanIndexAt(chf, ax, ay, getCon(s, 0));
                    if ((src_reg[ai] & border_reg) == 0 and chf.areas[i] == chf.areas[ai]) {
                        previd = src_reg[ai];
                    }
                }

                if (previd == 0) {
                    previd = rid;
                    rid +%= 1;
                    // A row can have more sweeps than the field's longer
                    // side, the size the sweeps start with.
                    if (previd >= sweeps.items.len) {
                        const missing = @as(usize, previd) + 1 - sweeps.items.len;
                        try sweeps.appendNTimes(gpa, zero_sweep, missing);
                    }
                    const sweep = &sweeps.items[previd];
                    sweep.rid = previd;
                    sweep.ns = 0;
                    sweep.nei = 0;
                }

                // -y
                if (getCon(s, 3) != not_connected) {
                    const ax = x + getDirOffsetX(3);
                    const ay = y + getDirOffsetY(3);
                    const ai = spanIndexAt(chf, ax, ay, getCon(s, 3));
                    if (src_reg[ai] != 0 and (src_reg[ai] & border_reg) == 0 and
                        chf.areas[i] == chf.areas[ai])
                    {
                        const nr = src_reg[ai];
                        const sweep = &sweeps.items[previd];
                        if (sweep.nei == 0 or sweep.nei == nr) {
                            sweep.nei = nr;
                            sweep.ns +%= 1;
                            prev.items[nr] += 1;
                        } else {
                            sweep.nei = null_nei;
                        }
                    }
                }

                src_reg[i] = previd;
            }
        }

        // Create unique ID.
        {
            var i: usize = 1;
            while (i < rid) : (i += 1) {
                const sweep = &sweeps.items[i];
                if (sweep.nei != null_nei and sweep.nei != 0 and
                    prev.items[sweep.nei] == sweep.ns)
                {
                    sweep.id = sweep.nei;
                } else {
                    sweep.id = id;
                    id +%= 1;
                }
            }
        }

        // Remap IDs
        x = border_size;
        while (x < w - border_size) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (first..first + c.count) |i| {
                if (src_reg[i] > 0 and src_reg[i] < rid) src_reg[i] = sweeps.items[src_reg[i]].id;
            }
        }
    }

    return id;
}

/// Splits the walkable spans into regions by monotone partitioning: a sweep
/// along each row, so regions never wrap around holes and need no distance
/// field, though they tend to be long and thin. Spans within `border_size`
/// of the field's edge get border regions. Groups of connected regions
/// smaller than `min_region_area` spans that reach no tile border are
/// removed, and regions of at most `merge_region_area` spans merge into a
/// neighbour where they can. Sets each span's `reg`, `chf.max_regions` and
/// `chf.border_size`.
pub fn buildRegionsMonotone(
    ctx: Context,
    gpa: Allocator,
    chf: *CompactHeightfield,
    border_size: i32,
    min_region_area: i32,
    merge_region_area: i32,
) BuildRegionsError!void {
    ctx.startTimer(.build_regions);
    defer ctx.stopTimer(.build_regions);

    var id: u16 = 1;

    const src_reg = gpa.alloc(u16, @intCast(chf.span_count)) catch |err| {
        ctx.log(.err, "rcBuildRegionsMonotone: Out of memory 'src' ({d}).", .{chf.span_count});
        return err;
    };
    defer gpa.free(src_reg);
    @memset(src_reg, 0);

    const nsweeps = @max(chf.width, chf.height);
    var sweeps: std.ArrayList(SweepSpan) = .empty;
    defer sweeps.deinit(gpa);
    sweeps.appendNTimes(gpa, zero_sweep, @intCast(nsweeps)) catch |err| {
        ctx.log(.err, "rcBuildRegionsMonotone: Out of memory 'sweeps' ({d}).", .{nsweeps});
        return err;
    };

    // Mark border regions.
    if (border_size > 0) id = paintBorderRegions(chf, border_size, id, src_reg);

    chf.border_size = border_size;

    id = try partitionMonotone(gpa, chf, border_size, id, src_reg, &sweeps);

    {
        ctx.startTimer(.build_regions_filter);
        defer ctx.stopTimer(.build_regions_filter);

        // Merge regions and filter out small regions.
        var overlaps: std.ArrayList(i32) = .empty;
        defer overlaps.deinit(gpa);
        chf.max_regions = id;
        chf.max_regions = try mergeAndFilterRegions(
            ctx,
            gpa,
            min_region_area,
            merge_region_area,
            chf.max_regions,
            chf,
            src_reg,
            &overlaps,
        );

        // Monotone partitioning does not generate overlapping regions.
    }

    // Store the result out.
    for (chf.spans, src_reg) |*span, reg| span.reg = reg;
}

/// Splits the walkable spans into regions by watershed over the distance
/// field, which `buildDistanceField` must build first: regions grow from the
/// spans farthest from any border, giving the roundest regions. Spans within
/// `border_size` of the field's edge get border regions. Groups of connected
/// regions smaller than `min_region_area` spans that reach no tile border
/// are removed, and regions of at most `merge_region_area` spans merge into a
/// neighbour where they can. Sets each span's `reg`, `chf.max_regions` and
/// `chf.border_size`.
pub fn buildRegions(
    ctx: Context,
    gpa: Allocator,
    chf: *CompactHeightfield,
    border_size: i32,
    min_region_area: i32,
    merge_region_area: i32,
) BuildRegionsError!void {
    assert(chf.dist.len == chf.spans.len);

    ctx.startTimer(.build_regions);
    defer ctx.stopTimer(.build_regions);

    const span_count: usize = @intCast(chf.span_count);
    const buf = gpa.alloc(u16, span_count * 2) catch |err| {
        ctx.log(.err, "rcBuildRegions: Out of memory 'tmp' ({d}).", .{chf.span_count * 4});
        return err;
    };
    defer gpa.free(buf);

    // Not stopped when the build fails partway.
    ctx.startTimer(.build_regions_watershed);

    const log_nb_stacks = 3;
    const nb_stacks = 1 << log_nb_stacks;
    var lvl_stacks: [nb_stacks]std.ArrayList(LevelStackEntry) = @splat(.empty);
    defer {
        for (&lvl_stacks) |*lvl_stack| lvl_stack.deinit(gpa);
    }
    for (&lvl_stacks) |*lvl_stack| try lvl_stack.ensureTotalCapacity(gpa, 256);

    var stack: std.ArrayList(LevelStackEntry) = .empty;
    defer stack.deinit(gpa);
    try stack.ensureTotalCapacity(gpa, 256);

    const src_reg = buf[0..span_count];
    const src_dist = buf[span_count..];

    @memset(src_reg, 0);
    @memset(src_dist, 0);

    var region_id: u16 = 1;
    var level: u16 = @truncate((@as(u32, chf.max_distance) + 1) & ~@as(u32, 1));

    // How far the watershed "overflows" and simplifies the regions.
    const expand_iters = 8;

    if (border_size > 0) region_id = paintBorderRegions(chf, border_size, region_id, src_reg);

    chf.border_size = border_size;

    var s_id: i32 = -1;
    while (level > 0) {
        level = if (level >= 2) level - 2 else 0;
        s_id = (s_id + 1) & (nb_stacks - 1);
        const lvl_stack = &lvl_stacks[@intCast(s_id)];

        if (s_id == 0) {
            try sortCellsByLevel(gpa, level, chf, src_reg, &lvl_stacks, 1);
        } else {
            // Copy left overs from last level.
            const last = lvl_stacks[@intCast(s_id - 1)].items;
            try appendStacks(gpa, last, lvl_stack, src_reg);
        }

        {
            ctx.startTimer(.build_regions_expand);
            defer ctx.stopTimer(.build_regions_expand);

            // Expand current regions until no empty connected cells found.
            try expandRegions(gpa, expand_iters, level, chf, src_reg, src_dist, lvl_stack, false);
        }

        {
            ctx.startTimer(.build_regions_flood);
            defer ctx.stopTimer(.build_regions_flood);

            // Mark new regions with IDs.
            var j: usize = 0;
            while (j < lvl_stack.items.len) : (j += 1) {
                const current = lvl_stack.items[j];
                if (current.index < 0) continue;
                const i: usize = @intCast(current.index);
                if (src_reg[i] != 0) continue;
                const flooded = try floodRegion(
                    gpa,
                    current.x,
                    current.y,
                    i,
                    level,
                    region_id,
                    chf,
                    src_reg,
                    src_dist,
                    &stack,
                );
                if (flooded) {
                    if (region_id == 0xffff) {
                        ctx.log(.err, "rcBuildRegions: Region ID overflow", .{});
                        return error.RegionIdOverflow;
                    }
                    region_id += 1;
                }
            }
        }
    }

    // Expand current regions until no empty connected cells found.
    try expandRegions(gpa, expand_iters * 8, 0, chf, src_reg, src_dist, &stack, true);

    ctx.stopTimer(.build_regions_watershed);

    {
        ctx.startTimer(.build_regions_filter);
        defer ctx.stopTimer(.build_regions_filter);

        // Merge regions and filter out small regions.
        var overlaps: std.ArrayList(i32) = .empty;
        defer overlaps.deinit(gpa);
        chf.max_regions = region_id;
        chf.max_regions = try mergeAndFilterRegions(
            ctx,
            gpa,
            min_region_area,
            merge_region_area,
            chf.max_regions,
            chf,
            src_reg,
            &overlaps,
        );

        // If overlapping regions were found during merging, split those regions.
        if (overlaps.items.len > 0) {
            ctx.log(.err, "rcBuildRegions: {d} overlapping regions.", .{overlaps.items.len});
        }
    }

    // Write the result out.
    for (chf.spans, src_reg) |*span, reg| span.reg = reg;
}

/// Splits the walkable spans into regions that never lie above one another,
/// for tiles built in layers: monotone regions of one area merged into
/// non-overlapping layers. Spans within `border_size` of the field's edge get
/// border regions, and layers smaller than `min_region_area` spans that reach
/// no tile border are removed. Sets each span's `reg`, `chf.max_regions` and
/// `chf.border_size`.
pub fn buildLayerRegions(
    ctx: Context,
    gpa: Allocator,
    chf: *CompactHeightfield,
    border_size: i32,
    min_region_area: i32,
) BuildRegionsError!void {
    ctx.startTimer(.build_regions);
    defer ctx.stopTimer(.build_regions);

    var id: u16 = 1;

    const src_reg = gpa.alloc(u16, @intCast(chf.span_count)) catch |err| {
        ctx.log(.err, "rcBuildLayerRegions: Out of memory 'src' ({d}).", .{chf.span_count});
        return err;
    };
    defer gpa.free(src_reg);
    @memset(src_reg, 0);

    const nsweeps = @max(chf.width, chf.height);
    var sweeps: std.ArrayList(SweepSpan) = .empty;
    defer sweeps.deinit(gpa);
    sweeps.appendNTimes(gpa, zero_sweep, @intCast(nsweeps)) catch |err| {
        ctx.log(.err, "rcBuildLayerRegions: Out of memory 'sweeps' ({d}).", .{nsweeps});
        return err;
    };

    // Mark border regions.
    if (border_size > 0) id = paintBorderRegions(chf, border_size, id, src_reg);

    chf.border_size = border_size;

    id = try partitionMonotone(gpa, chf, border_size, id, src_reg, &sweeps);

    {
        ctx.startTimer(.build_regions_filter);
        defer ctx.stopTimer(.build_regions_filter);

        // Merge monotone regions to layers and remove small regions.
        chf.max_regions = id;
        chf.max_regions = try mergeAndFilterLayerRegions(
            ctx,
            gpa,
            min_region_area,
            chf.max_regions,
            chf,
            src_reg,
        );
    }

    // Store the result out.
    for (chf.spans, src_reg) |*span, reg| span.reg = reg;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "removing repeated neighbours keeps one and wraps around" {
    const gpa = testing.allocator;
    var reg: Region = .init(1);
    defer reg.connections.deinit(gpa);
    try reg.connections.appendSlice(gpa, &.{ 2, 2, 3, 3, 2 });
    removeAdjacentNeighbours(&reg);
    try testing.expectEqualSlices(i32, &.{ 2, 3 }, reg.connections.items);

    reg.connections.clearRetainingCapacity();
    try reg.connections.appendSlice(gpa, &.{ 4, 4, 4 });
    removeAdjacentNeighbours(&reg);
    try testing.expectEqualSlices(i32, &.{4}, reg.connections.items);
}
