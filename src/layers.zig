// An altered version of Recast from recastnavigation 1.6.0, translated to
// Zig. Copyright (c) 2009-2010 Mikko Mononen memon@inside.org; zlib licence,
// see LICENSE.

//! Heightfield layers: the walkable spans of a compact heightfield split
//! into 2D layers in which no two walkable surfaces overlap, the input of
//! tiles rebuilt at run time. Translated from RecastLayers.cpp.

const std = @import("std");
const Allocator = std.mem.Allocator;

const recast = @import("recast.zig");
const Context = recast.Context;
const CompactHeightfield = recast.CompactHeightfield;
const HeightfieldLayer = recast.HeightfieldLayer;
const HeightfieldLayerSet = recast.HeightfieldLayerSet;
const getCon = recast.getCon;
const getDirOffsetX = recast.getDirOffsetX;
const getDirOffsetY = recast.getDirOffsetY;
const not_connected = recast.not_connected;
const null_area = recast.null_area;

/// The most regions that may overlap one region, and so the most layers a
/// column can take part in. Layer ids are bytes with 0xff for none, so it
/// must stay below 256.
const max_layers = 63;
/// The most neighbor regions a region keeps; further neighbors are dropped,
/// which only makes more layers.
const max_neis = 16;

/// The failures of `buildHeightfieldLayers`.
pub const BuildHeightfieldLayersError = Allocator.Error || error{
    /// More than 255 monotone regions.
    RegionIdOverflow,
    /// A region overlaps more than `max_layers` others.
    LayerOverflow,
};

const LayerRegion = struct {
    /// The regions overlapping this one.
    layers: [max_layers]u8,
    neis: [max_neis]u8,
    ymin: u16,
    ymax: u16,
    layer_id: u8,
    nlayers: u8,
    nneis: u8,
    /// Whether the region is the base its layer's other regions merged into.
    base: bool,
};

fn contains(a: []const u8, an: u8, v: u8) bool {
    for (a[0..an]) |item| {
        if (item == v) return true;
    }
    return false;
}

/// Adds `v` to the first `an.*` items of `a` if it is not there; false if
/// `a` is full.
fn addUnique(a: []u8, an: *u8, v: u8) bool {
    if (contains(a, an.*, v)) return true;
    if (an.* >= a.len) return false;
    a[an.*] = v;
    an.* += 1;
    return true;
}

fn overlapRange(amin: u16, amax: u16, bmin: u16, bmax: u16) bool {
    return !(amin > bmax or amax < bmin);
}

const LayerSweepSpan = struct {
    /// The number of samples.
    ns: u16,
    /// The region id.
    id: u8,
    /// The neighbor region id.
    nei: u8,
};

const layer_overflow_message = "rcBuildHeightfieldLayers: layer overflow " ++
    "(too many overlapping walkable platforms). Try increasing RC_MAX_LAYERS.";

/// Splits the walkable spans of `chf` inside a border of `border_size` cells
/// into layers: 2D heightfields in which no two walkable surfaces overlap,
/// each a byte of height per cell over the layer's lowest point. Spans are
/// first grouped into monotone regions, regions that do not overlap join a
/// layer, and layers whose height ranges come within `walkable_height * 4`
/// cells of each other merge. With no walkable spans inside the border the
/// set is empty. The set owns its memory until its `deinit`.
pub fn buildHeightfieldLayers(
    ctx: Context,
    gpa: Allocator,
    chf: *const CompactHeightfield,
    border_size: i32,
    walkable_height: i32,
) BuildHeightfieldLayersError!HeightfieldLayerSet {
    ctx.startTimer(.build_layers);
    defer ctx.stopTimer(.build_layers);

    const w = chf.width;
    const h = chf.height;

    const src_reg = gpa.alloc(u8, @intCast(chf.span_count)) catch |err| {
        ctx.log(
            .err,
            "rcBuildHeightfieldLayers: Out of memory 'srcReg' ({d}).",
            .{chf.span_count},
        );
        return err;
    };
    defer gpa.free(src_reg);
    @memset(src_reg, 0xff);

    // Sweep ids are bytes, so a row can index 256 sweeps however narrow the
    // field is; the sweeps start zeroed, as the ids a wrapped sweep counter
    // skips are read before they are written.
    const nsweeps = chf.width;
    const sweeps = gpa.alloc(LayerSweepSpan, @intCast(@max(nsweeps, 256))) catch |err| {
        ctx.log(.err, "rcBuildHeightfieldLayers: Out of memory 'sweeps' ({d}).", .{nsweeps});
        return err;
    };
    defer gpa.free(sweeps);
    @memset(sweeps, .{ .ns = 0, .id = 0, .nei = 0 });

    // Partition walkable area into monotone regions.
    var prev_count: [256]i32 = @splat(0);
    var reg_id: u8 = 0;

    var y = border_size;
    while (y < h - border_size) : (y += 1) {
        @memset(prev_count[0..reg_id], 0);
        var sweep_id: u8 = 0;

        var x = border_size;
        while (x < w - border_size) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (first..first + c.count) |i| {
                const s = chf.spans[i];
                if (chf.areas[i] == null_area) continue;

                var sid: u8 = 0xff;

                // -x
                if (getCon(s, 0) != not_connected) {
                    const ax = x + getDirOffsetX(0);
                    const ay = y + getDirOffsetY(0);
                    const neighbor_first: i32 = chf.cells[@intCast(ax + ay * w)].index;
                    const ai: usize = @intCast(neighbor_first + getCon(s, 0));
                    if (chf.areas[ai] != null_area and src_reg[ai] != 0xff) sid = src_reg[ai];
                }

                if (sid == 0xff) {
                    sid = sweep_id;
                    sweep_id +%= 1;
                    sweeps[sid].nei = 0xff;
                    sweeps[sid].ns = 0;
                }

                // -y
                if (getCon(s, 3) != not_connected) {
                    const ax = x + getDirOffsetX(3);
                    const ay = y + getDirOffsetY(3);
                    const neighbor_first: i32 = chf.cells[@intCast(ax + ay * w)].index;
                    const ai: usize = @intCast(neighbor_first + getCon(s, 3));
                    const nr = src_reg[ai];
                    if (nr != 0xff) {
                        // Set neighbour when first valid neighbour is encountered.
                        if (sweeps[sid].ns == 0) sweeps[sid].nei = nr;

                        if (sweeps[sid].nei == nr) {
                            // Update existing neighbour
                            sweeps[sid].ns +%= 1;
                            prev_count[nr] += 1;
                        } else {
                            // More than one neighbour: invalidate the neighbour.
                            sweeps[sid].nei = 0xff;
                        }
                    }
                }

                src_reg[i] = sid;
            }
        }

        // Create unique ID.
        for (sweeps[0..sweep_id]) |*sweep| {
            // If the neighbour is set and there is only one continuous
            // connection to it, the sweep is merged with the previous one,
            // else a new region is created.
            if (sweep.nei != 0xff and prev_count[sweep.nei] == sweep.ns) {
                sweep.id = sweep.nei;
            } else {
                if (reg_id == 255) {
                    ctx.log(.err, "rcBuildHeightfieldLayers: Region ID overflow.", .{});
                    return error.RegionIdOverflow;
                }
                sweep.id = reg_id;
                reg_id += 1;
            }
        }

        // Remap local sweep ids to region ids.
        x = border_size;
        while (x < w - border_size) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (src_reg[first .. first + c.count]) |*reg| {
                if (reg.* != 0xff) reg.* = sweeps[reg.*].id;
            }
        }
    }

    // Allocate and init layer regions.
    const nregs: i32 = reg_id;
    const regs = gpa.alloc(LayerRegion, @intCast(nregs)) catch |err| {
        ctx.log(.err, "rcBuildHeightfieldLayers: Out of memory 'regs' ({d}).", .{nregs});
        return err;
    };
    defer gpa.free(regs);
    @memset(regs, .{
        .layers = @splat(0),
        .neis = @splat(0),
        .ymin = 0xffff,
        .ymax = 0,
        .layer_id = 0xff,
        .nlayers = 0,
        .nneis = 0,
        .base = false,
    });

    // Find region neighbours and overlapping regions.
    y = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];

            var lregs: [max_layers]u8 = undefined;
            var nlregs: usize = 0;

            const first: usize = c.index;
            for (first..first + c.count) |i| {
                const s = chf.spans[i];
                const ri = src_reg[i];
                if (ri == 0xff) continue;

                regs[ri].ymin = @min(regs[ri].ymin, s.y);
                regs[ri].ymax = @max(regs[ri].ymax, s.y);

                // Collect all region layers.
                if (nlregs < max_layers) {
                    lregs[nlregs] = ri;
                    nlregs += 1;
                }

                // Update neighbours
                for ([4]u2{ 0, 1, 2, 3 }) |dir| {
                    if (getCon(s, dir) != not_connected) {
                        const ax = x + getDirOffsetX(dir);
                        const ay = y + getDirOffsetY(dir);
                        const neighbor_first: i32 = chf.cells[@intCast(ax + ay * w)].index;
                        const ai: usize = @intCast(neighbor_first + getCon(s, dir));
                        const rai = src_reg[ai];
                        if (rai != 0xff and rai != ri) {
                            // A neighbour that does not fit only makes a
                            // few more regions.
                            _ = addUnique(&regs[ri].neis, &regs[ri].nneis, rai);
                        }
                    }
                }
            }

            // Update overlapping regions.
            for (0..nlregs) |i| {
                for (i + 1..nlregs) |j| {
                    if (lregs[i] != lregs[j]) {
                        const ri = &regs[lregs[i]];
                        const rj = &regs[lregs[j]];
                        if (!addUnique(&ri.layers, &ri.nlayers, lregs[j]) or
                            !addUnique(&rj.layers, &rj.nlayers, lregs[i]))
                        {
                            ctx.log(.err, layer_overflow_message, .{});
                            return error.LayerOverflow;
                        }
                    }
                }
            }
        }
    }

    // Create 2D layers from regions.
    var layer_id: u8 = 0;

    const max_stack = 64;
    var stack: [max_stack]u8 = undefined;
    var nstack: usize = 0;

    for (regs, 0..) |*root, i| {
        // Skip already visited.
        if (root.layer_id != 0xff) continue;

        // Start search.
        root.layer_id = layer_id;
        root.base = true;

        nstack = 0;
        stack[nstack] = @intCast(i);
        nstack += 1;

        while (nstack != 0) {
            // Pop front
            const reg = &regs[stack[0]];
            nstack -= 1;
            for (0..nstack) |j| stack[j] = stack[j + 1];

            const nneis = reg.nneis;
            for (reg.neis[0..nneis]) |nei| {
                const regn = &regs[nei];
                // Skip already visited.
                if (regn.layer_id != 0xff) continue;
                // Skip if the neighbour is overlapping root region.
                if (contains(&root.layers, root.nlayers, nei)) continue;
                // Skip if the height range would become too large.
                const ymin: i32 = @min(root.ymin, regn.ymin);
                const ymax: i32 = @max(root.ymax, regn.ymax);
                if (ymax - ymin >= 255) continue;

                if (nstack < max_stack) {
                    // Deepen
                    stack[nstack] = nei;
                    nstack += 1;

                    // Mark layer id
                    regn.layer_id = layer_id;
                    // Merge current layers to root.
                    for (regn.layers[0..regn.nlayers]) |layer| {
                        if (!addUnique(&root.layers, &root.nlayers, layer)) {
                            ctx.log(.err, layer_overflow_message, .{});
                            return error.LayerOverflow;
                        }
                    }
                    root.ymin = @min(root.ymin, regn.ymin);
                    root.ymax = @max(root.ymax, regn.ymax);
                }
            }
        }

        layer_id +%= 1;
    }

    // Merge non-overlapping regions that are close in height. The sums of a
    // height and this wrap at 16 bits, as upstream's unsigned shorts do.
    const merge_height = @as(u16, @truncate(@as(u32, @bitCast(walkable_height)))) *% 4;

    for (regs, 0..) |*ri, i| {
        if (!ri.base) continue;

        const new_id = ri.layer_id;

        while (true) {
            var old_id: u8 = 0xff;

            for (regs, 0..) |*rj, j| {
                if (i == j) continue;
                if (!rj.base) continue;

                // Skip if the regions are not close to each other.
                if (!overlapRange(
                    ri.ymin,
                    ri.ymax +% merge_height,
                    rj.ymin,
                    rj.ymax +% merge_height,
                )) continue;
                // Skip if the height range would become too large.
                const ymin: i32 = @min(ri.ymin, rj.ymin);
                const ymax: i32 = @max(ri.ymax, rj.ymax);
                if (ymax - ymin >= 255) continue;

                // Make sure that there is no overlap when merging 'ri' and 'rj'.
                var overlap = false;
                // Iterate over all regions which have the same layer id as 'rj'.
                for (regs, 0..) |*reg, k| {
                    if (reg.layer_id != rj.layer_id) continue;
                    // Check if region 'k' is overlapping region 'ri'. The
                    // index to 'regs' is the region id.
                    if (contains(&ri.layers, ri.nlayers, @intCast(k))) {
                        overlap = true;
                        break;
                    }
                }
                // Cannot merge if the regions overlap.
                if (overlap) continue;

                // Can merge i and j.
                old_id = rj.layer_id;
                break;
            }

            // Could not find anything to merge with, stop.
            if (old_id == 0xff) break;

            // Merge
            for (regs) |*rj| {
                if (rj.layer_id == old_id) {
                    rj.base = false;
                    // Remap layer ids.
                    rj.layer_id = new_id;
                    // Add overlaid layers from 'rj' to 'ri'.
                    var k: usize = 0;
                    while (k < rj.nlayers) : (k += 1) {
                        if (!addUnique(&ri.layers, &ri.nlayers, rj.layers[k])) {
                            ctx.log(.err, layer_overflow_message, .{});
                            return error.LayerOverflow;
                        }
                    }

                    // Update height bounds.
                    ri.ymin = @min(ri.ymin, rj.ymin);
                    ri.ymax = @max(ri.ymax, rj.ymax);
                }
            }
        }
    }

    // Compact layer ids.
    var remap: [256]u8 = @splat(0);

    // Find number of unique layers.
    layer_id = 0;
    for (regs) |reg| remap[reg.layer_id] = 1;
    for (&remap) |*id| {
        if (id.* != 0) {
            id.* = layer_id;
            layer_id +%= 1;
        } else {
            id.* = 0xff;
        }
    }
    // Remap ids.
    for (regs) |*reg| reg.layer_id = remap[reg.layer_id];

    // No layers, return empty.
    if (layer_id == 0) return .{ .layers = &.{} };

    // Create layers.
    const lw = w - border_size * 2;
    const lh = h - border_size * 2;

    // Build contracted bbox for layers.
    var bmin = chf.bmin;
    var bmax = chf.bmax;
    bmin[0] += @as(f32, @floatFromInt(border_size)) * chf.cs;
    bmin[2] += @as(f32, @floatFromInt(border_size)) * chf.cs;
    bmax[0] -= @as(f32, @floatFromInt(border_size)) * chf.cs;
    bmax[2] -= @as(f32, @floatFromInt(border_size)) * chf.cs;

    const nlayers: i32 = layer_id;
    const layers = gpa.alloc(HeightfieldLayer, @intCast(nlayers)) catch |err| {
        ctx.log(.err, "rcBuildHeightfieldLayers: Out of memory 'layers' ({d}).", .{nlayers});
        return err;
    };
    @memset(layers, .{
        .bmin = .{ 0, 0, 0 },
        .bmax = .{ 0, 0, 0 },
        .cs = 0,
        .ch = 0,
        .width = 0,
        .height = 0,
        .minx = 0,
        .maxx = 0,
        .miny = 0,
        .maxy = 0,
        .hmin = 0,
        .hmax = 0,
        .heights = &.{},
        .areas = &.{},
        .cons = &.{},
    });
    var lset: HeightfieldLayerSet = .{ .layers = layers };
    errdefer lset.deinit(gpa);

    // Store layers.
    for (layers, 0..) |*layer, i| {
        const cur_id: u8 = @intCast(i);

        const grid_size = lw * lh;

        layer.heights = gpa.alloc(u8, @intCast(grid_size)) catch |err| {
            ctx.log(.err, "rcBuildHeightfieldLayers: Out of memory 'heights' ({d}).", .{grid_size});
            return err;
        };
        @memset(layer.heights, 0xff);

        layer.areas = gpa.alloc(u8, @intCast(grid_size)) catch |err| {
            ctx.log(.err, "rcBuildHeightfieldLayers: Out of memory 'areas' ({d}).", .{grid_size});
            return err;
        };
        @memset(layer.areas, 0);

        layer.cons = gpa.alloc(u8, @intCast(grid_size)) catch |err| {
            ctx.log(.err, "rcBuildHeightfieldLayers: Out of memory 'cons' ({d}).", .{grid_size});
            return err;
        };
        @memset(layer.cons, 0);

        // Find layer height bounds.
        var hmin: i32 = 0;
        var hmax: i32 = 0;
        for (regs) |reg| {
            if (reg.base and reg.layer_id == cur_id) {
                hmin = reg.ymin;
                hmax = reg.ymax;
            }
        }

        layer.width = lw;
        layer.height = lh;
        layer.cs = chf.cs;
        layer.ch = chf.ch;

        // Adjust the bbox to fit the heightfield.
        layer.bmin = bmin;
        layer.bmax = bmax;
        layer.bmin[1] = bmin[1] + @as(f32, @floatFromInt(hmin)) * chf.ch;
        layer.bmax[1] = bmin[1] + @as(f32, @floatFromInt(hmax)) * chf.ch;
        layer.hmin = hmin;
        layer.hmax = hmax;

        // Update usable data region.
        layer.minx = layer.width;
        layer.maxx = 0;
        layer.miny = layer.height;
        layer.maxy = 0;

        // Copy height and area from compact heightfield.
        var ly: i32 = 0;
        while (ly < lh) : (ly += 1) {
            var lx: i32 = 0;
            while (lx < lw) : (lx += 1) {
                const cx = border_size + lx;
                const cy = border_size + ly;
                const c = chf.cells[@intCast(cx + cy * w)];
                const first: usize = c.index;
                for (first..first + c.count) |j| {
                    const s = chf.spans[j];
                    // Skip unassigned regions.
                    if (src_reg[j] == 0xff) continue;
                    // Skip if it does not belong to the current layer.
                    const lid = regs[src_reg[j]].layer_id;
                    if (lid != cur_id) continue;

                    // Update data bounds.
                    layer.minx = @min(layer.minx, lx);
                    layer.maxx = @max(layer.maxx, lx);
                    layer.miny = @min(layer.miny, ly);
                    layer.maxy = @max(layer.maxy, ly);

                    // Store height and area type.
                    const idx: usize = @intCast(lx + ly * lw);
                    layer.heights[idx] = @truncate(@as(u32, @bitCast(@as(i32, s.y) - hmin)));
                    layer.areas[idx] = chf.areas[j];

                    // Check connection.
                    var portal: u8 = 0;
                    var con: u8 = 0;
                    for ([4]u2{ 0, 1, 2, 3 }) |dir| {
                        if (getCon(s, dir) != not_connected) {
                            const ax = cx + getDirOffsetX(dir);
                            const ay = cy + getDirOffsetY(dir);
                            const neighbor_first: i32 = chf.cells[@intCast(ax + ay * w)].index;
                            const ai: usize = @intCast(neighbor_first + getCon(s, dir));
                            const alid: u8 = if (src_reg[ai] != 0xff)
                                regs[src_reg[ai]].layer_id
                            else
                                0xff;
                            // Portal mask
                            if (chf.areas[ai] != null_area and lid != alid) {
                                portal |= @as(u8, 1) << dir;
                                // Update height so that it matches on both
                                // sides of the portal.
                                const neighbor_span = chf.spans[ai];
                                if (neighbor_span.y > hmin) {
                                    const rise = @as(i32, neighbor_span.y) - hmin;
                                    layer.heights[idx] = @max(
                                        layer.heights[idx],
                                        @as(u8, @truncate(@as(u32, @bitCast(rise)))),
                                    );
                                }
                            }
                            // Valid connection mask
                            if (chf.areas[ai] != null_area and lid == alid) {
                                const nx = ax - border_size;
                                const ny = ay - border_size;
                                if (nx >= 0 and ny >= 0 and nx < lw and ny < lh) {
                                    con |= @as(u8, 1) << dir;
                                }
                            }
                        }
                    }

                    layer.cons[idx] = (portal << 4) | con;
                }
            }
        }

        if (layer.minx > layer.maxx) {
            layer.minx = 0;
            layer.maxx = 0;
        }
        if (layer.miny > layer.maxy) {
            layer.miny = 0;
            layer.maxy = 0;
        }
    }

    return lset;
}
