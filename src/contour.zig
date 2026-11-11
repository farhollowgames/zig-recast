// An altered version of Recast from recastnavigation 1.6.0, translated to
// Zig. Copyright (c) 2009-2010 Mikko Mononen memon@inside.org; zlib licence,
// see LICENSE.

//! Contours: traces the outline of each region of a compact heightfield and
//! simplifies it to a polygon. Translated from RecastContour.cpp.

const std = @import("std");
const Allocator = std.mem.Allocator;

const recast = @import("recast.zig");
const Context = recast.Context;
const CompactHeightfield = recast.CompactHeightfield;
const Contour = recast.Contour;
const ContourSet = recast.ContourSet;
const ContourBuildFlags = recast.ContourBuildFlags;
const getCon = recast.getCon;
const getDirOffsetX = recast.getDirOffsetX;
const getDirOffsetY = recast.getDirOffsetY;
const not_connected = recast.not_connected;
const border_reg = recast.border_reg;
const border_vertex = recast.border_vertex;
const area_border = recast.area_border;
const contour_reg_mask = recast.contour_reg_mask;

/// The index in `chf.spans` of the span `con` up the column at `x`, `y`.
fn spanIndex(chf: *const CompactHeightfield, x: i32, y: i32, con: i32) usize {
    return @intCast(@as(i32, chf.cells[@intCast(x + y * chf.width)].index) + con);
}

/// A span's region id with its area id in bits 16 to 23.
fn regAndArea(chf: *const CompactHeightfield, i: usize) u32 {
    return @as(u32, chf.spans[i].reg) | (@as(u32, chf.areas[i]) << 16);
}

/// The height of the corner of span `i` at the start of its edge in
/// direction `dir`: the highest floor of the up to four spans that share the
/// corner. Sets `is_border_vertex` when the corner sits on the tile border
/// between two interior spans of one area, so simplification can drop it.
fn getCornerHeight(
    x: i32,
    y: i32,
    i: usize,
    dir: u2,
    chf: *const CompactHeightfield,
    is_border_vertex: *bool,
) i32 {
    const s = chf.spans[i];
    var ch: i32 = s.y;
    const dirp = dir +% 1;

    var regs = [4]u32{ 0, 0, 0, 0 };

    // Combine region and area codes in order to prevent
    // border vertices which are in between two areas to be removed.
    regs[0] = regAndArea(chf, i);

    if (getCon(s, dir) != not_connected) {
        const ax = x + getDirOffsetX(dir);
        const ay = y + getDirOffsetY(dir);
        const ai = spanIndex(chf, ax, ay, getCon(s, dir));
        const a_span = chf.spans[ai];
        ch = @max(ch, @as(i32, a_span.y));
        regs[1] = regAndArea(chf, ai);
        if (getCon(a_span, dirp) != not_connected) {
            const ax2 = ax + getDirOffsetX(dirp);
            const ay2 = ay + getDirOffsetY(dirp);
            const ai2 = spanIndex(chf, ax2, ay2, getCon(a_span, dirp));
            ch = @max(ch, @as(i32, chf.spans[ai2].y));
            regs[2] = regAndArea(chf, ai2);
        }
    }
    if (getCon(s, dirp) != not_connected) {
        const ax = x + getDirOffsetX(dirp);
        const ay = y + getDirOffsetY(dirp);
        const ai = spanIndex(chf, ax, ay, getCon(s, dirp));
        const a_span = chf.spans[ai];
        ch = @max(ch, @as(i32, a_span.y));
        regs[3] = regAndArea(chf, ai);
        if (getCon(a_span, dir) != not_connected) {
            const ax2 = ax + getDirOffsetX(dir);
            const ay2 = ay + getDirOffsetY(dir);
            const ai2 = spanIndex(chf, ax2, ay2, getCon(a_span, dir));
            ch = @max(ch, @as(i32, chf.spans[ai2].y));
            regs[2] = regAndArea(chf, ai2);
        }
    }

    // Check if the vertex is special edge vertex, these vertices will be removed later.
    for ([4]u2{ 0, 1, 2, 3 }) |a| {
        const b = a +% 1;
        const c = a +% 2;
        const d = a +% 3;

        // The vertex is a border vertex there are two same exterior cells in a row,
        // followed by two interior cells and none of the regions are out of bounds.
        const two_same_exts = (regs[a] & regs[b] & border_reg) != 0 and regs[a] == regs[b];
        const two_ints = ((regs[c] | regs[d]) & border_reg) == 0;
        const ints_same_area = (regs[c] >> 16) == (regs[d] >> 16);
        const no_zeros = regs[a] != 0 and regs[b] != 0 and regs[c] != 0 and regs[d] != 0;
        if (two_same_exts and two_ints and ints_same_area and no_zeros) {
            is_border_vertex.* = true;
            break;
        }
    }

    return ch;
}

/// Walks the outline of the region of span `i` at `x`, `y` clockwise,
/// appending x, y, z and flags of each corner to `points` and clearing the
/// edges it passes from `flags`.
fn walkContour(
    gpa: Allocator,
    start_x: i32,
    start_y: i32,
    start_i: usize,
    chf: *const CompactHeightfield,
    flags: []u8,
    points: *std.ArrayList(i32),
) Allocator.Error!void {
    var x = start_x;
    var y = start_y;
    var i = start_i;

    // Choose the first non-connected edge
    var dir: u2 = 0;
    while ((flags[i] & (@as(u8, 1) << dir)) == 0) dir += 1;

    const start_dir = dir;
    const starti = i;

    const area = chf.areas[i];

    var iter: i32 = 1;
    while (iter < 40000) : (iter += 1) {
        if ((flags[i] & (@as(u8, 1) << dir)) != 0) {
            // Choose the edge corner
            var is_border_vertex = false;
            var is_area_border = false;
            var px = x;
            const py = getCornerHeight(x, y, i, dir, chf, &is_border_vertex);
            var pz = y;
            switch (dir) {
                0 => pz += 1,
                1 => {
                    px += 1;
                    pz += 1;
                },
                2 => px += 1,
                3 => {},
            }
            var r: i32 = 0;
            const s = chf.spans[i];
            if (getCon(s, dir) != not_connected) {
                const ax = x + getDirOffsetX(dir);
                const ay = y + getDirOffsetY(dir);
                const ai = spanIndex(chf, ax, ay, getCon(s, dir));
                r = chf.spans[ai].reg;
                if (area != chf.areas[ai]) is_area_border = true;
            }
            if (is_border_vertex) r |= border_vertex;
            if (is_area_border) r |= area_border;
            try points.appendSlice(gpa, &.{ px, py, pz, r });

            flags[i] &= ~(@as(u8, 1) << dir); // Remove visited edges
            dir +%= 1; // Rotate CW
        } else {
            const nx = x + getDirOffsetX(dir);
            const ny = y + getDirOffsetY(dir);
            const s = chf.spans[i];
            // An edge without a neighbour is never followed.
            if (getCon(s, dir) == not_connected) return;
            x = nx;
            y = ny;
            i = spanIndex(chf, nx, ny, getCon(s, dir));
            dir +%= 3; // Rotate CCW
        }

        if (starti == i and start_dir == dir) break;
    }
}

/// The squared distance on the xz-plane of point `x`, `z` from the segment
/// `px`, `pz` to `qx`, `qz`.
fn distancePtSeg(x: i32, z: i32, px: i32, pz: i32, qx: i32, qz: i32) f32 {
    const pqx: f32 = @floatFromInt(qx - px);
    const pqz: f32 = @floatFromInt(qz - pz);
    var dx: f32 = @floatFromInt(x - px);
    var dz: f32 = @floatFromInt(z - pz);
    const d = pqx * pqx + pqz * pqz;
    var t = pqx * dx + pqz * dz;
    if (d > 0) t /= d;
    if (t < 0) {
        t = 0;
    } else if (t > 1) {
        t = 1;
    }

    dx = @as(f32, @floatFromInt(px)) + t * pqx - @as(f32, @floatFromInt(x));
    dz = @as(f32, @floatFromInt(pz)) + t * pqz - @as(f32, @floatFromInt(z));

    return dx * dx + dz * dz;
}

/// Inserts raw point `raw` of `points` at position `index` of `simplified`,
/// with the raw point's index as its fourth value.
fn insertPoint(
    gpa: Allocator,
    simplified: *std.ArrayList(i32),
    index: usize,
    points: []const i32,
    raw: usize,
) Allocator.Error!void {
    const raw_index: i32 = @intCast(raw);
    const point = points[raw * 4 ..][0..3];
    try simplified.insertSlice(gpa, index * 4, &.{ point[0], point[1], point[2], raw_index });
}

/// Simplifies the raw contour `points` into `simplified`: keeps the points
/// where the neighbour region or area changes, adds the raw points farthest
/// from the simplified edges until every raw point is within `max_error`,
/// then splits edges longer than `max_edge_len` as `build_flags` asks. Each
/// simplified point's fourth value is the raw point's neighbour region and
/// area border flag, with the border vertex flag of the raw point itself.
fn simplifyContour(
    gpa: Allocator,
    points: []const i32,
    simplified: *std.ArrayList(i32),
    max_error: f32,
    max_edge_len: i32,
    build_flags: ContourBuildFlags,
) Allocator.Error!void {
    // Add initial points.
    var has_connections = false;
    var p: usize = 0;
    while (p < points.len) : (p += 4) {
        if ((points[p + 3] & contour_reg_mask) != 0) {
            has_connections = true;
            break;
        }
    }

    if (has_connections) {
        // The contour has some portals to other regions.
        // Add a new point to every location where the region changes.
        const ni = points.len / 4;
        for (0..ni) |pi| {
            const ii = (pi + 1) % ni;
            const different_regs = (points[pi * 4 + 3] & contour_reg_mask) !=
                (points[ii * 4 + 3] & contour_reg_mask);
            const area_borders = (points[pi * 4 + 3] & area_border) !=
                (points[ii * 4 + 3] & area_border);
            if (different_regs or area_borders) {
                const raw_index: i32 = @intCast(pi);
                try simplified.appendSlice(gpa, &.{
                    points[pi * 4 + 0],
                    points[pi * 4 + 1],
                    points[pi * 4 + 2],
                    raw_index,
                });
            }
        }
    }

    if (simplified.items.len == 0) {
        // If there is no connections at all,
        // create some initial points for the simplification process.
        // Find lower-left and upper-right vertices of the contour.
        var llx = points[0];
        var lly = points[1];
        var llz = points[2];
        var lli: i32 = 0;
        var urx = points[0];
        var ury = points[1];
        var urz = points[2];
        var uri: i32 = 0;
        var q: usize = 0;
        while (q < points.len) : (q += 4) {
            const x = points[q + 0];
            const y = points[q + 1];
            const z = points[q + 2];
            if (x < llx or (x == llx and z < llz)) {
                llx = x;
                lly = y;
                llz = z;
                lli = @intCast(q / 4);
            }
            if (x > urx or (x == urx and z > urz)) {
                urx = x;
                ury = y;
                urz = z;
                uri = @intCast(q / 4);
            }
        }
        try simplified.appendSlice(gpa, &.{ llx, lly, llz, lli });
        try simplified.appendSlice(gpa, &.{ urx, ury, urz, uri });
    }

    // Add points until all raw points are within
    // error tolerance to the simplified shape.
    const pn = points.len / 4;
    var i: usize = 0;
    while (i < simplified.items.len / 4) {
        const ii = (i + 1) % (simplified.items.len / 4);

        var ax = simplified.items[i * 4 + 0];
        var az = simplified.items[i * 4 + 2];
        const ai: usize = @intCast(simplified.items[i * 4 + 3]);

        var bx = simplified.items[ii * 4 + 0];
        var bz = simplified.items[ii * 4 + 2];
        const bi: usize = @intCast(simplified.items[ii * 4 + 3]);

        // Find maximum deviation from the segment.
        var maxd: f32 = 0;
        var maxi: ?usize = null;

        // Traverse the segment in lexilogical order so that the
        // max deviation is calculated similarly when traversing
        // opposite segments.
        const forward = bx > ax or (bx == ax and bz > az);
        const cinc: usize = if (forward) 1 else pn - 1;
        var ci = if (forward) (ai + cinc) % pn else (bi + cinc) % pn;
        const endi = if (forward) bi else ai;
        if (!forward) {
            std.mem.swap(i32, &ax, &bx);
            std.mem.swap(i32, &az, &bz);
        }

        // Tessellate only outer edges or edges between areas.
        if ((points[ci * 4 + 3] & contour_reg_mask) == 0 or
            (points[ci * 4 + 3] & area_border) != 0)
        {
            while (ci != endi) {
                const d = distancePtSeg(points[ci * 4 + 0], points[ci * 4 + 2], ax, az, bx, bz);
                if (d > maxd) {
                    maxd = d;
                    maxi = ci;
                }
                ci = (ci + cinc) % pn;
            }
        }

        // If the max deviation is larger than accepted error,
        // add new point, else continue to next segment.
        if (maxi != null and maxd > max_error * max_error) {
            try insertPoint(gpa, simplified, i + 1, points, maxi.?);
        } else {
            i += 1;
        }
    }

    // Split too long edges.
    if (max_edge_len > 0 and (build_flags.tess_wall_edges or build_flags.tess_area_edges)) {
        i = 0;
        while (i < simplified.items.len / 4) {
            const ii = (i + 1) % (simplified.items.len / 4);

            const ax = simplified.items[i * 4 + 0];
            const az = simplified.items[i * 4 + 2];
            const ai: usize = @intCast(simplified.items[i * 4 + 3]);

            const bx = simplified.items[ii * 4 + 0];
            const bz = simplified.items[ii * 4 + 2];
            const bi: usize = @intCast(simplified.items[ii * 4 + 3]);

            // Find maximum deviation from the segment.
            var maxi: ?usize = null;
            const ci = (ai + 1) % pn;

            // Tessellate only outer edges or edges between areas.
            var tess = false;
            // Wall edges.
            if (build_flags.tess_wall_edges and (points[ci * 4 + 3] & contour_reg_mask) == 0) {
                tess = true;
            }
            // Edges between areas.
            if (build_flags.tess_area_edges and (points[ci * 4 + 3] & area_border) != 0) {
                tess = true;
            }

            if (tess) {
                // In 64 bits: past 46340 the original's int squares
                // overflow, which C leaves undefined. Built at -O3, it
                // compares the wrapped squares as unsigned, which gives
                // this up to 65535.
                const dx: i64 = bx - ax;
                const dz: i64 = bz - az;
                if (dx * dx + dz * dz > @as(i64, max_edge_len) * max_edge_len) {
                    // Round based on the segments in lexilogical order so that the
                    // max tesselation is consistent regardless in which direction
                    // segments are traversed.
                    const n = if (bi < ai) bi + pn - ai else bi - ai;
                    if (n > 1) {
                        if (bx > ax or (bx == ax and bz > az)) {
                            maxi = (ai + n / 2) % pn;
                        } else {
                            maxi = (ai + (n + 1) / 2) % pn;
                        }
                    }
                }
            }

            // If the max deviation is larger than accepted error,
            // add new point, else continue to next segment.
            if (maxi) |m| {
                try insertPoint(gpa, simplified, i + 1, points, m);
            } else {
                i += 1;
            }
        }
    }

    for (0..simplified.items.len / 4) |k| {
        // The edge vertex flag is take from the current raw point,
        // and the neighbour region is take from the next raw point.
        const bi: usize = @intCast(simplified.items[k * 4 + 3]);
        const ai = (bi + 1) % pn;
        simplified.items[k * 4 + 3] = (points[ai * 4 + 3] & (contour_reg_mask | area_border)) |
            (points[bi * 4 + 3] & border_vertex);
    }
}

/// Twice the signed area of a contour on the xz-plane, plus one, halved
/// toward zero: negative for a hole. Sums wrap as two's complement, as
/// upstream's do in practice on fields large enough to overflow.
fn calcAreaOfPolygon2D(verts: []const i32, nverts: i32) i32 {
    var area: i32 = 0;
    var j: i32 = nverts - 1;
    var i: i32 = 0;
    while (i < nverts) : (i += 1) {
        const vi = vertexAt(verts, i);
        const vj = vertexAt(verts, j);
        area +%= (vi[0] *% vj[2]) -% (vj[0] *% vi[2]);
        j = i;
    }
    return @divTrunc(area +% 1, 2);
}

/// The x, y, z and flags of vertex `index` of a contour's vertices.
fn vertexAt(verts: []const i32, index: i32) *const [4]i32 {
    return verts[@intCast(index * 4)..][0..4];
}

fn prev(i: i32, n: i32) i32 {
    return if (i - 1 >= 0) i - 1 else n - 1;
}

fn next(i: i32, n: i32) i32 {
    return if (i + 1 < n) i + 1 else 0;
}

fn area2(a: *const [4]i32, b: *const [4]i32, c: *const [4]i32) i32 {
    return (b[0] - a[0]) * (c[2] - a[2]) - (c[0] - a[0]) * (b[2] - a[2]);
}

/// Whether `c` is strictly to the left of the directed line through `a`
/// to `b`.
fn left(a: *const [4]i32, b: *const [4]i32, c: *const [4]i32) bool {
    return area2(a, b, c) < 0;
}

fn leftOn(a: *const [4]i32, b: *const [4]i32, c: *const [4]i32) bool {
    return area2(a, b, c) <= 0;
}

fn collinear(a: *const [4]i32, b: *const [4]i32, c: *const [4]i32) bool {
    return area2(a, b, c) == 0;
}

/// Whether `ab` properly intersects `cd`: they share a point interior to
/// both segments. The properness of the intersection is ensured by using
/// strict leftness.
fn intersectProp(
    a: *const [4]i32,
    b: *const [4]i32,
    c: *const [4]i32,
    d: *const [4]i32,
) bool {
    // Eliminate improper cases.
    if (collinear(a, b, c) or collinear(a, b, d) or
        collinear(c, d, a) or collinear(c, d, b))
    {
        return false;
    }

    return (left(a, b, c) != left(a, b, d)) and (left(c, d, a) != left(c, d, b));
}

/// Whether `a`, `b` and `c` are collinear and `c` lies on the closed
/// segment `ab`.
fn between(a: *const [4]i32, b: *const [4]i32, c: *const [4]i32) bool {
    if (!collinear(a, b, c)) return false;
    // If ab not vertical, check betweenness on x; else on y.
    if (a[0] != b[0]) {
        return ((a[0] <= c[0]) and (c[0] <= b[0])) or ((a[0] >= c[0]) and (c[0] >= b[0]));
    } else {
        return ((a[2] <= c[2]) and (c[2] <= b[2])) or ((a[2] >= c[2]) and (c[2] >= b[2]));
    }
}

/// Whether segments `ab` and `cd` intersect, properly or improperly.
fn intersect(a: *const [4]i32, b: *const [4]i32, c: *const [4]i32, d: *const [4]i32) bool {
    if (intersectProp(a, b, c, d)) return true;
    return between(a, b, c) or between(a, b, d) or between(c, d, a) or between(c, d, b);
}

fn vequal(a: *const [4]i32, b: *const [4]i32) bool {
    return a[0] == b[0] and a[2] == b[2];
}

/// Whether the segment `d0` to `d1` crosses an edge of the contour of `n`
/// vertices `verts`, skipping the edges at vertex `i` and those sharing an
/// end with the segment.
fn intersectSegContour(
    d0: *const [4]i32,
    d1: *const [4]i32,
    i: i32,
    n: i32,
    verts: []const i32,
) bool {
    // For each edge (k,k+1) of P
    var k: i32 = 0;
    while (k < n) : (k += 1) {
        const k1 = next(k, n);
        // Skip edges incident to i.
        if (i == k or i == k1) continue;
        const p0 = vertexAt(verts, k);
        const p1 = vertexAt(verts, k1);
        if (vequal(d0, p0) or vequal(d1, p0) or vequal(d0, p1) or vequal(d1, p1)) continue;

        if (intersect(d0, d1, p0, p1)) return true;
    }
    return false;
}

/// Whether `pj` lies in the cone of vertex `i` of the contour of `n`
/// vertices `verts`.
fn inCone(i: i32, n: i32, verts: []const i32, pj: *const [4]i32) bool {
    const pi = vertexAt(verts, i);
    const pi1 = vertexAt(verts, next(i, n));
    const pin1 = vertexAt(verts, prev(i, n));

    // If P[i] is a convex vertex [ i+1 left or on (i-1,i) ].
    if (leftOn(pin1, pi, pi1)) return left(pi, pj, pin1) and left(pj, pi, pi1);
    // Assume (i-1,i,i+1) not collinear.
    // else P[i] is reflex.
    return !(leftOn(pi, pj, pi1) and leftOn(pj, pi, pin1));
}

/// Removes a vertex equal on the xz-plane to the vertex after it. Each
/// vertex is compared once, so a run of three equal vertices keeps two.
fn removeDegenerateSegments(simplified: *std.ArrayList(i32)) void {
    // Remove adjacent vertices which are equal on xz-plane,
    // or else the triangulator will get confused.
    var npts: i32 = @intCast(simplified.items.len / 4);
    var i: i32 = 0;
    while (i < npts) : (i += 1) {
        const ni = next(i, npts);

        if (vequal(vertexAt(simplified.items, i), vertexAt(simplified.items, ni))) {
            // Degenerate segment, remove.
            simplified.replaceRangeAssumeCapacity(@intCast(i * 4), 4, &.{});
            npts -= 1;
        }
    }
}

/// Joins hole `cb` into outline `ca` through the diagonal from vertex `ia`
/// of `ca` to vertex `ib` of `cb`. `ca` gets new vertices; `cb` is left with
/// none, its raw vertices kept.
fn mergeContours(
    gpa: Allocator,
    ca: *Contour,
    cb: *Contour,
    ia: i32,
    ib: i32,
) Allocator.Error!void {
    const max_verts = ca.nverts + cb.nverts + 2;
    const verts = try gpa.alloc(i32, @intCast(max_verts * 4));

    var nv: i32 = 0;

    // Copy contour A.
    var i: i32 = 0;
    while (i <= ca.nverts) : (i += 1) {
        verts[@intCast(nv * 4)..][0..4].* = vertexAt(ca.verts, @rem(ia + i, ca.nverts)).*;
        nv += 1;
    }

    // Copy contour B
    i = 0;
    while (i <= cb.nverts) : (i += 1) {
        verts[@intCast(nv * 4)..][0..4].* = vertexAt(cb.verts, @rem(ib + i, cb.nverts)).*;
        nv += 1;
    }

    gpa.free(ca.verts);
    ca.verts = verts;
    ca.nverts = nv;

    gpa.free(cb.verts);
    cb.verts = &.{};
    cb.nverts = 0;
}

const ContourHole = struct {
    /// The hole's index in the contour set.
    contour: usize,
    minx: i32,
    minz: i32,
    leftmost: i32,
};

const ContourRegion = struct {
    /// The outline's index in the contour set.
    outline: ?usize,
    /// Where the region's holes start in the holes of all regions.
    holes_start: usize,
    nholes: usize,
};

const PotentialDiagonal = struct {
    vert: i32,
    dist: i32,
};

/// Finds the lowest leftmost vertex of a contour.
fn findLeftMostVertex(contour: *const Contour, minx: *i32, minz: *i32, leftmost: *i32) void {
    minx.* = contour.verts[0];
    minz.* = contour.verts[2];
    leftmost.* = 0;
    var i: i32 = 1;
    while (i < contour.nverts) : (i += 1) {
        const v = vertexAt(contour.verts, i);
        const x = v[0];
        const z = v[2];
        if (x < minx.* or (x == minx.* and z < minz.*)) {
            minx.* = x;
            minz.* = z;
            leftmost.* = i;
        }
    }
}

fn holeLessThan(_: void, a: ContourHole, b: ContourHole) bool {
    if (a.minx == b.minx) return a.minz < b.minz;
    return a.minx < b.minx;
}

fn diagLessThan(_: void, a: PotentialDiagonal, b: PotentialDiagonal) bool {
    return a.dist < b.dist;
}

/// Merges each hole of a region into its outline, left to right, through
/// the shortest diagonal that crosses neither the outline nor the holes not
/// yet merged.
fn mergeRegionHoles(
    ctx: Context,
    gpa: Allocator,
    conts: []Contour,
    outline_index: usize,
    holes: []ContourHole,
) Allocator.Error!void {
    // Sort holes from left to right.
    for (holes) |*hole| {
        findLeftMostVertex(&conts[hole.contour], &hole.minx, &hole.minz, &hole.leftmost);
    }

    std.mem.sort(ContourHole, holes, {}, holeLessThan);

    var max_verts: i32 = conts[outline_index].nverts;
    for (holes) |hole| max_verts += conts[hole.contour].nverts;

    // Each merged hole also adds two vertices to the outline, which upstream
    // writes past its `max_verts` entries; the extra entries hold them. The
    // entries are zeroed and never cleared: the diagonal search reads entry
    // `i`, the hole's index, which this call may not have written yet.
    const diags_len = @as(usize, @intCast(max_verts)) + 2 * holes.len;
    const diags = gpa.alloc(PotentialDiagonal, diags_len) catch |err| {
        ctx.log(.warning, "mergeRegionHoles: Failed to allocated diags {d}.", .{max_verts});
        return err;
    };
    defer gpa.free(diags);
    @memset(diags, .{ .vert = 0, .dist = 0 });

    const outline = &conts[outline_index];

    // Merge holes into the outline one by one.
    for (holes, 0..) |hole_entry, i| {
        const hole = &conts[hole_entry.contour];

        var index: i32 = -1;
        var best_vertex = hole_entry.leftmost;
        var iter: i32 = 0;
        while (iter < hole.nverts) : (iter += 1) {
            // Find potential diagonals.
            // The 'best' vertex must be in the cone described by 3 consecutive
            // vertices of the outline.
            // ..o j-1
            //   |
            //   |   * best
            //   |
            // j o-----o j+1
            //         :
            var ndiags: usize = 0;
            const corner = vertexAt(hole.verts, best_vertex);
            var j: i32 = 0;
            while (j < outline.nverts) : (j += 1) {
                if (inCone(j, outline.nverts, outline.verts, corner)) {
                    const dx = outline.verts[@intCast(j * 4 + 0)] - corner[0];
                    const dz = outline.verts[@intCast(j * 4 + 2)] - corner[2];
                    // Wrapping, as C's int arithmetic does on the targets,
                    // for fields past 46340 cells.
                    diags[ndiags] = .{ .vert = j, .dist = dx *% dx +% dz *% dz };
                    ndiags += 1;
                }
            }
            // Sort potential diagonals by distance, we want to make the
            // connection as short as possible.
            std.mem.sort(PotentialDiagonal, diags[0..ndiags], {}, diagLessThan);

            // Find a diagonal that is not intersecting the outline not the remaining holes.
            index = -1;
            for (diags[0..ndiags]) |diag| {
                const pt = vertexAt(outline.verts, diag.vert);
                // The outline edges skipped are those at the vertex of entry
                // `i`, not at this diagonal's vertex, as upstream does.
                const skip = diags[i].vert;
                const nverts = outline.nverts;
                var intersects = intersectSegContour(pt, corner, skip, nverts, outline.verts);
                var k = i;
                while (k < holes.len and !intersects) : (k += 1) {
                    const other = &conts[holes[k].contour];
                    intersects = intersectSegContour(pt, corner, -1, other.nverts, other.verts);
                }
                if (!intersects) {
                    index = diag.vert;
                    break;
                }
            }
            // If found non-intersecting diagonal, stop looking.
            if (index != -1) break;
            // All the potential diagonals for the current vertex were
            // intersecting, try next vertex.
            best_vertex = @rem(best_vertex + 1, hole.nverts);
        }

        if (index == -1) {
            ctx.log(
                .warning,
                "mergeHoles: Failed to find merge points for 0x{x} and 0x{x}.",
                .{ @intFromPtr(outline), @intFromPtr(hole) },
            );
            continue;
        }
        mergeContours(gpa, outline, hole, index, best_vertex) catch |err| {
            ctx.log(
                .warning,
                "mergeHoles: Failed to merge contours 0x{x} and 0x{x}.",
                .{ @intFromPtr(outline), @intFromPtr(hole) },
            );
            return err;
        };
    }
}

/// Traces the outline of every region of `chf` (built with its regions) and
/// simplifies it. The raw contours follow the region outlines exactly;
/// `max_error` and `max_edge_len` set how closely the simplified contours
/// follow the raw ones, in cells, and the vertices where the neighbour region
/// or area changes are always kept, so portals match up. A `max_edge_len` of
/// zero splits no edges. A region's holes are merged into its outline, and a
/// merged hole keeps its raw vertices but has no simplified ones. The
/// returned set owns its memory.
pub fn buildContours(
    ctx: Context,
    gpa: Allocator,
    chf: *const CompactHeightfield,
    max_error: f32,
    max_edge_len: i32,
    build_flags: ContourBuildFlags,
) Allocator.Error!ContourSet {
    const w = chf.width;
    const h = chf.height;
    const border_size = chf.border_size;

    ctx.startTimer(.build_contours);
    defer ctx.stopTimer(.build_contours);

    var bmin = chf.bmin;
    var bmax = chf.bmax;
    if (border_size > 0) {
        // If the heightfield was build with bordersize, remove the offset.
        const pad = @as(f32, @floatFromInt(border_size)) * chf.cs;
        bmin[0] += pad;
        bmin[2] += pad;
        bmax[0] -= pad;
        bmax[2] -= pad;
    }

    var max_contours: i32 = @max(@as(i32, chf.max_regions), 8);
    var conts = try gpa.alloc(Contour, @intCast(max_contours));
    var nconts: i32 = 0;
    errdefer {
        for (conts[0..@intCast(nconts)]) |*cont| {
            gpa.free(cont.verts);
            gpa.free(cont.rverts);
        }
        gpa.free(conts);
    }

    const flags = gpa.alloc(u8, @intCast(chf.span_count)) catch |err| {
        ctx.log(.err, "rcBuildContours: Out of memory 'flags' ({d}).", .{chf.span_count});
        return err;
    };
    defer gpa.free(flags);
    @memset(flags, 0);

    ctx.startTimer(.build_contours_trace);

    // Mark boundaries.
    var y: i32 = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (first..first + c.count) |i| {
                var res: u8 = 0;
                const s = chf.spans[i];
                if (s.reg == 0 or (s.reg & border_reg) != 0) {
                    flags[i] = 0;
                    continue;
                }
                for ([4]u2{ 0, 1, 2, 3 }) |dir| {
                    var r: u16 = 0;
                    if (getCon(s, dir) != not_connected) {
                        const ax = x + getDirOffsetX(dir);
                        const ay = y + getDirOffsetY(dir);
                        const ai = spanIndex(chf, ax, ay, getCon(s, dir));
                        r = chf.spans[ai].reg;
                    }
                    if (r == s.reg) res |= @as(u8, 1) << dir;
                }
                flags[i] = res ^ 0xf; // Inverse, mark non connected edges.
            }
        }
    }

    ctx.stopTimer(.build_contours_trace);

    var verts: std.ArrayList(i32) = .empty;
    defer verts.deinit(gpa);
    try verts.ensureTotalCapacity(gpa, 256);
    var simplified: std.ArrayList(i32) = .empty;
    defer simplified.deinit(gpa);
    try simplified.ensureTotalCapacity(gpa, 64);

    y = 0;
    while (y < h) : (y += 1) {
        var x: i32 = 0;
        while (x < w) : (x += 1) {
            const c = chf.cells[@intCast(x + y * w)];
            const first: usize = c.index;
            for (first..first + c.count) |i| {
                if (flags[i] == 0 or flags[i] == 0xf) {
                    flags[i] = 0;
                    continue;
                }
                const reg = chf.spans[i].reg;
                if (reg == 0 or (reg & border_reg) != 0) continue;
                const area = chf.areas[i];

                verts.clearRetainingCapacity();
                simplified.clearRetainingCapacity();

                {
                    ctx.startTimer(.build_contours_trace);
                    defer ctx.stopTimer(.build_contours_trace);
                    try walkContour(gpa, x, y, i, chf, flags, &verts);
                }

                {
                    ctx.startTimer(.build_contours_simplify);
                    defer ctx.stopTimer(.build_contours_simplify);
                    try simplifyContour(
                        gpa,
                        verts.items,
                        &simplified,
                        max_error,
                        max_edge_len,
                        build_flags,
                    );
                    removeDegenerateSegments(&simplified);
                }

                // Store region->contour remap info.
                // Create contour.
                if (simplified.items.len / 4 >= 3) {
                    if (nconts >= max_contours) {
                        // Allocate more contours.
                        // This happens when a region has holes.
                        const old_max = max_contours;
                        max_contours *= 2;
                        conts = try gpa.realloc(conts, @intCast(max_contours));
                        ctx.log(
                            .warning,
                            "rcBuildContours: Expanding max contours from {d} to {d}.",
                            .{ old_max, max_contours },
                        );
                    }

                    const nverts: i32 = @intCast(simplified.items.len / 4);
                    const cont_verts = gpa.alloc(i32, simplified.items.len) catch |err| {
                        ctx.log(.err, "rcBuildContours: Out of memory 'verts' ({d}).", .{nverts});
                        return err;
                    };
                    errdefer gpa.free(cont_verts);
                    @memcpy(cont_verts, simplified.items);
                    if (border_size > 0) {
                        // If the heightfield was build with bordersize, remove the offset.
                        var j: usize = 0;
                        while (j < cont_verts.len) : (j += 4) {
                            cont_verts[j + 0] -= border_size;
                            cont_verts[j + 2] -= border_size;
                        }
                    }

                    const nrverts: i32 = @intCast(verts.items.len / 4);
                    const cont_rverts = gpa.alloc(i32, verts.items.len) catch |err| {
                        ctx.log(.err, "rcBuildContours: Out of memory 'rverts' ({d}).", .{nrverts});
                        return err;
                    };
                    @memcpy(cont_rverts, verts.items);
                    if (border_size > 0) {
                        // If the heightfield was build with bordersize, remove the offset.
                        var j: usize = 0;
                        while (j < cont_rverts.len) : (j += 4) {
                            cont_rverts[j + 0] -= border_size;
                            cont_rverts[j + 2] -= border_size;
                        }
                    }

                    conts[@intCast(nconts)] = .{
                        .verts = cont_verts,
                        .nverts = nverts,
                        .rverts = cont_rverts,
                        .nrverts = nrverts,
                        .reg = reg,
                        .area = area,
                    };
                    nconts += 1;
                }
            }
        }
    }

    // Merge holes if needed.
    if (nconts > 0) {
        const set = conts[0..@intCast(nconts)];

        // Calculate winding of all polygons.
        const winding = gpa.alloc(i8, set.len) catch |err| {
            ctx.log(.err, "rcBuildContours: Out of memory 'hole' ({d}).", .{nconts});
            return err;
        };
        defer gpa.free(winding);
        var nholes: i32 = 0;
        for (set, winding) |*cont, *wind| {
            // If the contour is wound backwards, it is a hole.
            wind.* = if (calcAreaOfPolygon2D(cont.verts, cont.nverts) < 0) -1 else 1;
            if (wind.* < 0) nholes += 1;
        }

        if (nholes > 0) {
            // Collect outline contour and holes contours per region.
            // We assume that there is one outline and multiple holes.
            const nregions: i32 = @as(i32, chf.max_regions) + 1;
            const regions = gpa.alloc(ContourRegion, @intCast(nregions)) catch |err| {
                ctx.log(.err, "rcBuildContours: Out of memory 'regions' ({d}).", .{nregions});
                return err;
            };
            defer gpa.free(regions);
            @memset(regions, .{ .outline = null, .holes_start = 0, .nholes = 0 });

            const holes = gpa.alloc(ContourHole, set.len) catch |err| {
                ctx.log(.err, "rcBuildContours: Out of memory 'holes' ({d}).", .{nconts});
                return err;
            };
            defer gpa.free(holes);
            @memset(holes, .{ .contour = 0, .minx = 0, .minz = 0, .leftmost = 0 });

            for (set, winding, 0..) |*cont, wind, i| {
                // Positively would contours are outlines, negative holes.
                if (wind > 0) {
                    if (regions[cont.reg].outline != null) {
                        ctx.log(
                            .err,
                            "rcBuildContours: Multiple outlines for region {d}.",
                            .{cont.reg},
                        );
                    }
                    regions[cont.reg].outline = i;
                } else {
                    regions[cont.reg].nholes += 1;
                }
            }
            var index: usize = 0;
            for (regions) |*reg| {
                if (reg.nholes > 0) {
                    reg.holes_start = index;
                    index += reg.nholes;
                    reg.nholes = 0;
                }
            }
            for (set, winding, 0..) |*cont, wind, i| {
                const reg = &regions[cont.reg];
                if (wind < 0) {
                    holes[reg.holes_start + reg.nholes].contour = i;
                    reg.nholes += 1;
                }
            }

            // Finally merge each regions holes into the outline.
            for (regions, 0..) |reg, i| {
                if (reg.nholes == 0) continue;

                if (reg.outline) |outline| {
                    const region_holes = holes[reg.holes_start..][0..reg.nholes];
                    try mergeRegionHoles(ctx, gpa, set, outline, region_holes);
                } else {
                    // The region does not have an outline.
                    // This can happen if the contour becaomes selfoverlapping because of
                    // too aggressive simplification settings.
                    ctx.log(
                        .err,
                        "rcBuildContours: Bad outline for region {d}, " ++
                            "contour simplification is likely too aggressive.",
                        .{i},
                    );
                }
            }
        }
    }

    return .{
        .conts = conts,
        .nconts = nconts,
        .bmin = bmin,
        .bmax = bmax,
        .cs = chf.cs,
        .ch = chf.ch,
        .width = chf.width - chf.border_size * 2,
        .height = chf.height - chf.border_size * 2,
        .border_size = chf.border_size,
        .max_error = max_error,
    };
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "polygon area halves toward zero" {
    // x, y, z and flags per vertex; twice the area is -2, then -4.
    const thin = [_]i32{ 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 1, 0 };
    try testing.expectEqual(0, calcAreaOfPolygon2D(&thin, 3));
    const wide = [_]i32{ 0, 0, 0, 0, 4, 0, 0, 0, 0, 0, 1, 0 };
    try testing.expectEqual(-1, calcAreaOfPolygon2D(&wide, 3));
}

test "degenerate segments are compared once per vertex" {
    var simplified: std.ArrayList(i32) = .empty;
    defer simplified.deinit(testing.allocator);
    try simplified.appendSlice(testing.allocator, &.{
        0, 1, 0, 0,
        0, 2, 0, 0,
        0, 3, 0, 0,
        1, 4, 1, 0,
    });
    removeDegenerateSegments(&simplified);
    try testing.expectEqualSlices(i32, &.{ 0, 2, 0, 0, 0, 3, 0, 0, 1, 4, 1, 0 }, simplified.items);
}
