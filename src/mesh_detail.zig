// An altered version of Recast from recastnavigation 1.6.0, translated to
// Zig. Copyright (c) 2009-2010 Mikko Mononen memon@inside.org; zlib licence,
// see LICENSE.

//! The detail mesh: triangles over each polygon of a poly mesh that follow
//! the heightfield's surface, sampled from the compact heightfield.
//! Translated from RecastMeshDetail.cpp.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const recast = @import("recast.zig");
const Context = recast.Context;
const CompactHeightfield = recast.CompactHeightfield;
const PolyMesh = recast.PolyMesh;
const PolyMeshDetail = recast.PolyMeshDetail;

pub const BuildPolyMeshDetailError = Allocator.Error || error{
    /// A polygon has more vertices than a detail mesh holds,
    /// `max_detail_verts`.
    TooManyPolygonVertices,
};

const unset_height: u16 = 0xffff;
const flt_max = std.math.floatMax(f32);

/// The heights of the cells under one polygon's bounds.
const HeightPatch = struct {
    /// A height per cell at `x + y * width`, from the patch's corner.
    data: []u16,
    xmin: i32 = 0,
    ymin: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
};

/// The vertex at `index` of flat x, y, z values.
fn point(values: []const f32, index: i32) *const [3]f32 {
    return values[@intCast(index * 3)..][0..3];
}

fn vdot2(a: *const [3]f32, b: *const [3]f32) f32 {
    return a[0] * b[0] + a[2] * b[2];
}

fn vdistSq2(p: *const [3]f32, q: *const [3]f32) f32 {
    const dx = q[0] - p[0];
    const dy = q[2] - p[2];
    return dx * dx + dy * dy;
}

fn vdist2(p: *const [3]f32, q: *const [3]f32) f32 {
    return @sqrt(vdistSq2(p, q));
}

fn vcross2(p1: *const [3]f32, p2: *const [3]f32, p3: *const [3]f32) f32 {
    const dx1 = p2[0] - p1[0];
    const dz1 = p2[2] - p1[2];
    const dx2 = p3[0] - p1[0];
    const dz2 = p3[2] - p1[2];
    return dx1 * dz2 - dz1 * dx2;
}

/// The circle through three points on the xz-plane: its center in `c` and
/// radius in `r`. False, with `c` at `p1` and `r` 0, if they are collinear.
fn circumCircle(
    p1: *const [3]f32,
    p2: *const [3]f32,
    p3: *const [3]f32,
    c: *[3]f32,
    r: *f32,
) bool {
    const eps: f32 = 1e-6;
    // Calculate the circle relative to p1, to avoid some precision issues.
    const v1 = [3]f32{ 0, 0, 0 };
    const v2 = recast.vsub(p2, p1);
    const v3 = recast.vsub(p3, p1);

    const cp = vcross2(&v1, &v2, &v3);
    if (@abs(cp) > eps) {
        const v1_sq = vdot2(&v1, &v1);
        const v2_sq = vdot2(&v2, &v2);
        const v3_sq = vdot2(&v3, &v3);
        c[0] = (v1_sq * (v2[2] - v3[2]) + v2_sq * (v3[2] - v1[2]) + v3_sq * (v1[2] - v2[2])) /
            (2 * cp);
        c[1] = 0;
        c[2] = (v1_sq * (v3[0] - v2[0]) + v2_sq * (v1[0] - v3[0]) + v3_sq * (v2[0] - v1[0])) /
            (2 * cp);
        r.* = vdist2(c, &v1);
        const center = recast.vadd(c, p1);
        c.* = center;
        return true;
    }

    c.* = p1.*;
    r.* = 0;
    return false;
}

/// The squared distance from `pt` to the segment from `p` to `q`.
fn distancePtSeg(pt: *const [3]f32, p: *const [3]f32, q: *const [3]f32) f32 {
    const pqx = q[0] - p[0];
    const pqy = q[1] - p[1];
    const pqz = q[2] - p[2];
    var dx = pt[0] - p[0];
    var dy = pt[1] - p[1];
    var dz = pt[2] - p[2];
    const d = pqx * pqx + pqy * pqy + pqz * pqz;
    var t = pqx * dx + pqy * dy + pqz * dz;
    if (d > 0) t /= d;
    if (t < 0) {
        t = 0;
    } else if (t > 1) {
        t = 1;
    }

    dx = p[0] + t * pqx - pt[0];
    dy = p[1] + t * pqy - pt[1];
    dz = p[2] + t * pqz - pt[2];

    return dx * dx + dy * dy + dz * dz;
}

/// The squared distance from `pt` to the segment from `p` to `q` on the
/// xz-plane.
fn distancePtSeg2d(pt: *const [3]f32, p: *const [3]f32, q: *const [3]f32) f32 {
    const pqx = q[0] - p[0];
    const pqz = q[2] - p[2];
    var dx = pt[0] - p[0];
    var dz = pt[2] - p[2];
    const d = pqx * pqx + pqz * pqz;
    var t = pqx * dx + pqz * dz;
    if (d > 0) t /= d;
    if (t < 0) {
        t = 0;
    } else if (t > 1) {
        t = 1;
    }

    dx = p[0] + t * pqx - pt[0];
    dz = p[2] + t * pqz - pt[2];

    return dx * dx + dz * dz;
}

const lanes = std.simd.suggestVectorLength(f32) orelse 4;
const Lanes = @Vector(lanes, f32);

fn splat(x: f32) Lanes {
    return @splat(x);
}

/// The interior samples of one polygon, placed where the error search
/// measures them, and each one's least vertical distance to the
/// triangulation, `lanes` samples at a time.
const SampleSearch = struct {
    /// Positions, jittered to get rid of some bad triangulations caused by
    /// the grid's symmetry. Past the samples, to a whole number of lanes,
    /// x is NaN, over no triangle.
    xs: std.ArrayList(f32) = .empty,
    ys: std.ArrayList(f32) = .empty,
    zs: std.ArrayList(f32) = .empty,
    /// The least distance per sample to the triangles it is over, or
    /// `flt_max` if it is over none.
    dmin: std.ArrayList(f32) = .empty,

    fn deinit(search: *SampleSearch, gpa: Allocator) void {
        search.xs.deinit(gpa);
        search.ys.deinit(gpa);
        search.zs.deinit(gpa);
        search.dmin.deinit(gpa);
    }

    /// Places `samples`, each a cell x, height and z and a flag.
    fn place(
        search: *SampleSearch,
        gpa: Allocator,
        samples: []const i32,
        sample_dist: f32,
        cs: f32,
        ch: f32,
    ) Allocator.Error!void {
        const n = samples.len / 4;
        const padded = std.mem.alignForward(usize, n, lanes);
        try search.xs.resize(gpa, padded);
        try search.ys.resize(gpa, padded);
        try search.zs.resize(gpa, padded);
        try search.dmin.resize(gpa, padded);
        for (0..n) |i| {
            const s = samples[i * 4 ..][0..3];
            const jitter: i32 = @intCast(i);
            search.xs.items[i] =
                @as(f32, @floatFromInt(s[0])) * sample_dist + getJitterX(jitter) * cs * 0.1;
            search.ys.items[i] = @as(f32, @floatFromInt(s[1])) * ch;
            search.zs.items[i] =
                @as(f32, @floatFromInt(s[2])) * sample_dist + getJitterY(jitter) * cs * 0.1;
        }
        @memset(search.xs.items[n..], std.math.nan(f32));
        @memset(search.ys.items[n..], 0);
        @memset(search.zs.items[n..], 0);
    }

    fn position(search: *const SampleSearch, i: usize) [3]f32 {
        return .{ search.xs.items[i], search.ys.items[i], search.zs.items[i] };
    }

    /// Sets each sample's least vertical distance to the triangles of
    /// `tris` it is over: within a tolerance of its barycentric
    /// coordinates, the distance to the height they interpolate, as
    /// upstream's `distPtTri`, with what does not depend on the sample
    /// worked out once per triangle.
    fn measure(search: *SampleSearch, verts: []const f32, tris: []const i32) void {
        const eps: f32 = 1e-4;
        const dmin = search.dmin.items;
        @memset(dmin, flt_max);
        var t: usize = 0;
        while (t < tris.len) : (t += 4) {
            const a = point(verts, tris[t + 0]);
            const b = point(verts, tris[t + 1]);
            const c = point(verts, tris[t + 2]);
            const v0 = recast.vsub(c, a);
            const v1 = recast.vsub(b, a);
            const dot00 = vdot2(&v0, &v0);
            const dot01 = vdot2(&v0, &v1);
            const dot11 = vdot2(&v1, &v1);
            const inv_denom = 1.0 / (dot00 * dot11 - dot01 * dot01);

            var k: usize = 0;
            while (k < dmin.len) : (k += lanes) {
                const v2x = @as(Lanes, search.xs.items[k..][0..lanes].*) - splat(a[0]);
                const v2z = @as(Lanes, search.zs.items[k..][0..lanes].*) - splat(a[2]);
                const dot02 = splat(v0[0]) * v2x + splat(v0[2]) * v2z;
                const dot12 = splat(v1[0]) * v2x + splat(v1[2]) * v2z;
                const u = (splat(dot11) * dot02 - splat(dot01) * dot12) * splat(inv_denom);
                const v = (splat(dot00) * dot12 - splat(dot01) * dot02) * splat(inv_denom);
                const inside = (u >= splat(-eps)) & (v >= splat(-eps)) & (u + v <= splat(1 + eps));
                const y = splat(a[1]) + splat(v0[1]) * u + splat(v1[1]) * v;
                const d = @abs(y - @as(Lanes, search.ys.items[k..][0..lanes].*));
                const least: Lanes = dmin[k..][0..lanes].*;
                dmin[k..][0..lanes].* = @select(f32, inside & (d < least), d, least);
            }
        }
    }
};

/// The squared distance from `p` to the polygon's outline on the xz-plane,
/// negative if `p` is inside.
fn distToPoly(nvert: i32, verts: []const f32, p: *const [3]f32) f32 {
    var dmin = flt_max;
    var c = false;
    var i: i32 = 0;
    var j: i32 = nvert - 1;
    while (i < nvert) : ({
        j = i;
        i += 1;
    }) {
        const vi = point(verts, i);
        const vj = point(verts, j);
        if (((vi[2] > p[2]) != (vj[2] > p[2])) and
            (p[0] < (vj[0] - vi[0]) * (p[2] - vi[2]) / (vj[2] - vi[2]) + vi[0]))
        {
            c = !c;
        }
        dmin = recast.selectMin(dmin, distancePtSeg2d(p, vj, vi));
    }
    return if (c) -dmin else dmin;
}

/// The patch's height under a point: the cell's own, or where the cell has
/// none, the one closest in height to `fy` in the nearest ring of cells
/// that has any, up to `radius` cells away.
fn getHeight(
    fx: f32,
    fy: f32,
    fz: f32,
    ics: f32,
    ch: f32,
    radius: i32,
    hp: *const HeightPatch,
) u16 {
    var ix = recast.truncateToInt(@floor(fx * ics + 0.01));
    var iz = recast.truncateToInt(@floor(fz * ics + 0.01));
    // Wrapping, as C's int arithmetic does on the targets, for the NaN
    // coordinates of an edge with no vertices left to sample (0 / 0); its
    // samples are never used.
    ix = recast.clamp(i32, ix -% hp.xmin, 0, hp.width - 1);
    iz = recast.clamp(i32, iz -% hp.ymin, 0, hp.height - 1);
    var h = hp.data[@intCast(ix + iz * hp.width)];
    if (h == unset_height) {
        // Special case when data might be bad.
        // Walk adjacent cells in a spiral up to 'radius', and look
        // for a pixel which has a valid height.
        var x: i32 = 1;
        var z: i32 = 0;
        var dx: i32 = 1;
        var dz: i32 = 0;
        const max_size = radius * 2 + 1;
        const max_iter = max_size * max_size - 1;

        var next_ring_iter_start: i32 = 8;
        var next_ring_iters: i32 = 16;

        var dmin = flt_max;
        var i: i32 = 0;
        while (i < max_iter) : (i += 1) {
            const nx = ix + x;
            const nz = iz + z;

            if (nx >= 0 and nz >= 0 and nx < hp.width and nz < hp.height) {
                const nh = hp.data[@intCast(nx + nz * hp.width)];
                if (nh != unset_height) {
                    const d = @abs(@as(f32, @floatFromInt(nh)) * ch - fy);
                    if (d < dmin) {
                        h = nh;
                        dmin = d;
                    }
                }
            }

            // The search walks rings around the center cell: 8 cells, then
            // 16, each ring 8 more. Once a ring has given a height, the
            // search stops before the next ring, so the height is the best
            // of the closest ring that has one.
            if (i + 1 == next_ring_iter_start) {
                if (h != unset_height) break;

                next_ring_iter_start += next_ring_iters;
                next_ring_iters += 8;
            }

            if ((x == z) or ((x < 0) and (x == -z)) or ((x > 0) and (x == 1 - z))) {
                const tmp = dx;
                dx = -dz;
                dz = tmp;
            }
            x += dx;
            z += dz;
        }
    }
    return h;
}

const ev_undef: i32 = -1;
const ev_hull: i32 = -2;

/// The vertices a polygon's detail mesh holds: its own and the samples
/// added.
const max_detail_verts = 127;

/// Each edge of a triangulation by its two vertices, either way round:
/// a triangulation has at most one edge between two vertices.
const EdgeIndex = struct {
    /// At `lo * max_detail_verts + hi`, for vertices `lo` <= `hi`, the
    /// edge's index, or `none`; set for the vertices `init` was given.
    slots: [max_detail_verts * max_detail_verts]u16,

    const none = std.math.maxInt(u16);

    /// Sets `index` to no edges between the first `nverts` vertices.
    fn init(index: *EdgeIndex, nverts: i32) void {
        @memset(index.slots[0..@intCast(nverts * max_detail_verts)], none);
    }

    fn slot(s: i32, t: i32) usize {
        return @intCast(@min(s, t) * max_detail_verts + @max(s, t));
    }
};

/// The edge between `s` and `t` in either direction, or `ev_undef`.
fn findEdge(index: *const EdgeIndex, s: i32, t: i32) i32 {
    const e = index.slots[EdgeIndex.slot(s, t)];
    return if (e == EdgeIndex.none) ev_undef else e;
}

/// Adds the edge from `s` to `t` with faces `l` and `r` unless the
/// triangulation has it, returning its index, or `ev_undef` if it was not
/// added.
fn addEdge(
    ctx: Context,
    edges: []i32,
    nedges: *i32,
    max_edges: i32,
    index: *EdgeIndex,
    s: i32,
    t: i32,
    l: i32,
    r: i32,
) i32 {
    if (nedges.* >= max_edges) {
        ctx.log(.err, "addEdge: Too many edges ({d}/{d}).", .{ nedges.*, max_edges });
        return ev_undef;
    }

    // Add edge if not already in the triangulation.
    const e = findEdge(index, s, t);
    if (e == ev_undef) {
        const edge = edges[@intCast(nedges.* * 4)..][0..4];
        edge.* = .{ s, t, l, r };
        const added = nedges.*;
        index.slots[EdgeIndex.slot(s, t)] = @intCast(added);
        nedges.* += 1;
        return added;
    }
    return ev_undef;
}

fn updateLeftFace(e: *[4]i32, s: i32, t: i32, f: i32) void {
    if (e[0] == s and e[1] == t and e[2] == ev_undef) {
        e[2] = f;
    } else if (e[1] == s and e[0] == t and e[3] == ev_undef) {
        e[3] = f;
    }
}

fn overlapSegSeg2d(a: *const [3]f32, b: *const [3]f32, c: *const [3]f32, d: *const [3]f32) bool {
    const a1 = vcross2(a, b, d);
    const a2 = vcross2(a, b, c);
    if (a1 * a2 < 0.0) {
        const a3 = vcross2(c, d, a);
        const a4 = a3 + a2 - a1;
        if (a3 * a4 < 0.0) return true;
    }
    return false;
}

fn overlapEdges(pts: []const f32, edges: []const i32, nedges: i32, s1: i32, t1: i32) bool {
    var i: i32 = 0;
    while (i < nedges) : (i += 1) {
        const s0 = edges[@intCast(i * 4 + 0)];
        const t0 = edges[@intCast(i * 4 + 1)];
        // Same or connected edges do not overlap.
        if (s0 == s1 or s0 == t1 or t0 == s1 or t0 == t1) continue;
        if (overlapSegSeg2d(point(pts, s0), point(pts, t0), point(pts, s1), point(pts, t1))) {
            return true;
        }
    }
    return false;
}

/// Adds the triangle on the open side of edge `edge_index`, from the point
/// whose circumcircle holds no other, or marks the edge as hull.
fn completeFacet(
    ctx: Context,
    pts: []const f32,
    npts: i32,
    edges: []i32,
    nedges: *i32,
    max_edges: i32,
    index: *EdgeIndex,
    nfaces: *i32,
    edge_index: i32,
) void {
    const eps: f32 = 1e-5;

    const edge = edges[@intCast(edge_index * 4)..][0..4];

    // Cache s and t.
    var s: i32 = undefined;
    var t: i32 = undefined;
    if (edge[2] == ev_undef) {
        s = edge[0];
        t = edge[1];
    } else if (edge[3] == ev_undef) {
        s = edge[1];
        t = edge[0];
    } else {
        // Edge already completed.
        return;
    }

    // Find best point on left of edge.
    var pt = npts;
    var c = [3]f32{ 0, 0, 0 };
    var r: f32 = -1;
    var u: i32 = 0;
    while (u < npts) : (u += 1) {
        if (u == s or u == t) continue;
        if (vcross2(point(pts, s), point(pts, t), point(pts, u)) > eps) {
            if (r < 0) {
                // The circle is not updated yet, do it now.
                pt = u;
                _ = circumCircle(point(pts, s), point(pts, t), point(pts, u), &c, &r);
                continue;
            }
            const d = vdist2(&c, point(pts, u));
            const tol: f32 = 0.001;
            if (d > r * (1 + tol)) {
                // Outside current circumcircle, skip.
                continue;
            } else if (d < r * (1 - tol)) {
                // Inside safe circumcircle, update circle.
                pt = u;
                _ = circumCircle(point(pts, s), point(pts, t), point(pts, u), &c, &r);
            } else {
                // Inside epsilon circum circle, do extra tests to make sure the edge is valid.
                // s-u and t-u cannot overlap with s-pt nor t-pt if they exists.
                if (overlapEdges(pts, edges, nedges.*, s, u)) continue;
                if (overlapEdges(pts, edges, nedges.*, t, u)) continue;
                // Edge is valid.
                pt = u;
                _ = circumCircle(point(pts, s), point(pts, t), point(pts, u), &c, &r);
            }
        }
    }

    // Add new triangle or update edge info if s-t is on hull.
    if (pt < npts) {
        // Update face information of edge being completed.
        updateLeftFace(edge, s, t, nfaces.*);

        // Add new edge or update face info of old edge.
        var e = findEdge(index, pt, s);
        if (e == ev_undef) {
            _ = addEdge(ctx, edges, nedges, max_edges, index, pt, s, nfaces.*, ev_undef);
        } else {
            updateLeftFace(edges[@intCast(e * 4)..][0..4], pt, s, nfaces.*);
        }

        // Add new edge or update face info of old edge.
        e = findEdge(index, t, pt);
        if (e == ev_undef) {
            _ = addEdge(ctx, edges, nedges, max_edges, index, t, pt, nfaces.*, ev_undef);
        } else {
            updateLeftFace(edges[@intCast(e * 4)..][0..4], t, pt, nfaces.*);
        }

        nfaces.* += 1;
    } else {
        updateLeftFace(edge, s, t, ev_hull);
    }
}

/// Delaunay triangulation of the points inside the hull, into `tris`: three
/// vertex indices and a zero per triangle.
fn delaunayHull(
    ctx: Context,
    gpa: Allocator,
    npts: i32,
    pts: []const f32,
    nhull: i32,
    hull: []const i32,
    tris: *std.ArrayList(i32),
    edges: *std.ArrayList(i32),
) Allocator.Error!void {
    // The edge index holds a polygon's detail vertices.
    assert(npts <= max_detail_verts);
    var nfaces: i32 = 0;
    var nedges: i32 = 0;
    const max_edges = npts * 10;
    // Only the edges added below are read.
    try edges.resize(gpa, @intCast(max_edges * 4));
    var index: EdgeIndex = undefined;
    index.init(npts);

    {
        var i: i32 = 0;
        var j: i32 = nhull - 1;
        while (i < nhull) : ({
            j = i;
            i += 1;
        }) {
            const s = hull[@intCast(j)];
            const t = hull[@intCast(i)];
            _ = addEdge(ctx, edges.items, &nedges, max_edges, &index, s, t, ev_hull, ev_undef);
        }
    }

    var current_edge: i32 = 0;
    while (current_edge < nedges) : (current_edge += 1) {
        for (2..4) |side| {
            if (edges.items[@as(usize, @intCast(current_edge * 4)) + side] != ev_undef) continue;
            completeFacet(
                ctx,
                pts,
                npts,
                edges.items,
                &nedges,
                max_edges,
                &index,
                &nfaces,
                current_edge,
            );
        }
    }

    // Create tris
    try tris.resize(gpa, @intCast(nfaces * 4));
    @memset(tris.items, -1);

    for (0..@intCast(nedges)) |i| {
        const e = edges.items[i * 4 ..][0..4];
        if (e[3] >= 0) {
            // Left face
            const t = tris.items[@intCast(e[3] * 4)..][0..4];
            if (t[0] == -1) {
                t[0] = e[0];
                t[1] = e[1];
            } else if (t[0] == e[1]) {
                t[2] = e[0];
            } else if (t[1] == e[0]) {
                t[2] = e[1];
            }
        }
        if (e[2] >= 0) {
            // Right
            const t = tris.items[@intCast(e[2] * 4)..][0..4];
            if (t[0] == -1) {
                t[0] = e[1];
                t[1] = e[0];
            } else if (t[0] == e[0]) {
                t[2] = e[1];
            } else if (t[1] == e[1]) {
                t[2] = e[0];
            }
        }
    }

    var i: i32 = 0;
    while (i < @as(i32, @intCast(tris.items.len / 4))) : (i += 1) {
        const t = tris.items[@intCast(i * 4)..][0..4];
        if (t[0] == -1 or t[1] == -1 or t[2] == -1) {
            ctx.log(
                .warning,
                "delaunayHull: Removing dangling face {d} [{d},{d},{d}].",
                .{ i, t[0], t[1], t[2] },
            );
            const len = tris.items.len;
            t[0] = tris.items[len - 4];
            t[1] = tris.items[len - 3];
            t[2] = tris.items[len - 2];
            t[3] = tris.items[len - 1];
            tris.shrinkRetainingCapacity(len - 4);
            i -= 1;
        }
    }
}

/// The polygon's smallest extent: over its edges, the least of the largest
/// distance from an edge to the other vertices.
fn polyMinExtent(verts: []const f32, nverts: i32) f32 {
    var min_dist = flt_max;
    var i: i32 = 0;
    while (i < nverts) : (i += 1) {
        const ni = @rem(i + 1, nverts);
        const p1 = point(verts, i);
        const p2 = point(verts, ni);
        var max_edge_dist: f32 = 0;
        var j: i32 = 0;
        while (j < nverts) : (j += 1) {
            if (j == i or j == ni) continue;
            const d = distancePtSeg2d(point(verts, j), p1, p2);
            max_edge_dist = recast.selectMax(max_edge_dist, d);
        }
        min_dist = recast.selectMin(min_dist, max_edge_dist);
    }
    return @sqrt(min_dist);
}

fn prev(i: i32, n: i32) i32 {
    return if (i - 1 >= 0) i - 1 else n - 1;
}

fn next(i: i32, n: i32) i32 {
    return if (i + 1 < n) i + 1 else 0;
}

/// Triangulates the hull as a fan that moves left or right, whichever
/// gives the shorter perimeter, from the ear with the shortest perimeter.
/// Appends to `tris`.
fn triangulateHull(
    gpa: Allocator,
    verts: []const f32,
    nhull: i32,
    hull: []const i32,
    nin: i32,
    tris: *std.ArrayList(i32),
) Allocator.Error!void {
    var start: i32 = 0;
    var left: i32 = 1;
    var right: i32 = nhull - 1;

    // Start from an ear with shortest perimeter.
    // This tends to favor well formed triangles as starting point.
    var dmin = flt_max;
    var i: i32 = 0;
    while (i < nhull) : (i += 1) {
        // Ears are triangles with original vertices as middle vertex while
        // others are actually line segments on edges.
        if (hull[@intCast(i)] >= nin) continue;
        const pi = prev(i, nhull);
        const ni = next(i, nhull);
        const pv = point(verts, hull[@intCast(pi)]);
        const cv = point(verts, hull[@intCast(i)]);
        const nv = point(verts, hull[@intCast(ni)]);
        const d = vdist2(pv, cv) + vdist2(cv, nv) + vdist2(nv, pv);
        if (d < dmin) {
            start = i;
            left = ni;
            right = pi;
            dmin = d;
        }
    }

    // Add first triangle
    try tris.appendSlice(gpa, &[_]i32{
        hull[@intCast(start)],
        hull[@intCast(left)],
        hull[@intCast(right)],
        0,
    });

    // Triangulate the polygon by moving left or right,
    // depending on which triangle has shorter perimeter.
    // This heuristic was chose empirically, since it seems
    // handle tessellated straight edges well.
    while (next(left, nhull) != right) {
        // Check to see if se should advance left or right.
        const nleft = next(left, nhull);
        const nright = prev(right, nhull);

        const cvleft = point(verts, hull[@intCast(left)]);
        const nvleft = point(verts, hull[@intCast(nleft)]);
        const cvright = point(verts, hull[@intCast(right)]);
        const nvright = point(verts, hull[@intCast(nright)]);
        const dleft = vdist2(cvleft, nvleft) + vdist2(nvleft, cvright);
        const dright = vdist2(cvright, nvright) + vdist2(cvleft, nvright);

        if (dleft < dright) {
            try tris.appendSlice(gpa, &[_]i32{
                hull[@intCast(left)],
                hull[@intCast(nleft)],
                hull[@intCast(right)],
                0,
            });
            left = nleft;
        } else {
            try tris.appendSlice(gpa, &[_]i32{
                hull[@intCast(left)],
                hull[@intCast(nright)],
                hull[@intCast(right)],
                0,
            });
            right = nright;
        }
    }
}

/// A fixed offset in -1 to 1 for sample `i`, from an unsigned wrapping
/// multiply as upstream's.
fn getJitterX(i: i32) f32 {
    const bits = @as(u32, @bitCast(i)) *% 0x8da6b343;
    return @as(f32, @floatFromInt(bits & 0xffff)) / 65535.0 * 2.0 - 1.0;
}

fn getJitterY(i: i32) f32 {
    const bits = @as(u32, @bitCast(i)) *% 0xd8163841;
    return @as(f32, @floatFromInt(bits & 0xffff)) / 65535.0 * 2.0 - 1.0;
}

fn onHull(a: i32, b: i32, nhull: i32, hull: []const i32) bool {
    // All internal sampled points come after the hull so we can early out for those.
    if (a >= nhull or b >= nhull) return false;

    var j = nhull - 1;
    var i: i32 = 0;
    while (i < nhull) : ({
        j = i;
        i += 1;
    }) {
        if (a == hull[@intCast(j)] and b == hull[@intCast(i)]) return true;
    }

    return false;
}

/// Find edges that lie on hull and mark them as such.
fn setTriFlags(tris: []i32, nhull: i32, hull: []const i32) void {
    // Matches DT_DETAIL_EDGE_BOUNDARY
    const detail_edge_boundary: u16 = 0x1;

    var i: usize = 0;
    while (i < tris.len) : (i += 4) {
        const a = tris[i + 0];
        const b = tris[i + 1];
        const c = tris[i + 2];
        var flags: u16 = 0;
        flags |= (if (onHull(a, b, nhull, hull)) detail_edge_boundary else 0) << 0;
        flags |= (if (onHull(b, c, nhull, hull)) detail_edge_boundary else 0) << 2;
        flags |= (if (onHull(c, a, nhull, hull)) detail_edge_boundary else 0) << 4;
        tris[i + 3] = flags;
    }
}

/// Builds one polygon's detail triangles into `verts`, `nverts` and `tris`:
/// samples heights along its edges and inside it, and adds the samples
/// that stray furthest from the surface until all are within
/// `sample_max_error`.
fn buildPolyDetail(
    ctx: Context,
    gpa: Allocator,
    in_verts: []const f32,
    nin: i32,
    sample_dist: f32,
    sample_max_error: f32,
    height_search_radius: i32,
    chf: *const CompactHeightfield,
    hp: *const HeightPatch,
    verts: []f32,
    nverts: *i32,
    tris: *std.ArrayList(i32),
    edges: *std.ArrayList(i32),
    samples: *std.ArrayList(i32),
    search: *SampleSearch,
) Allocator.Error!void {
    const max_verts = max_detail_verts;
    // Max tris for delaunay is 2n-2-k (n=num verts, k=num hull verts).
    const max_tris = 255;
    const max_verts_per_edge = 32;
    var edge: [(max_verts_per_edge + 1) * 3]f32 = undefined;
    var hull: [max_verts]i32 = undefined;
    var nhull: i32 = 0;

    nverts.* = nin;

    @memcpy(verts[0..@intCast(nin * 3)], in_verts[0..@intCast(nin * 3)]);

    edges.clearRetainingCapacity();
    tris.clearRetainingCapacity();

    const cs = chf.cs;
    const ics = 1.0 / cs;

    // Calculate minimum extents of the polygon based on input data.
    const min_extent = polyMinExtent(verts, nverts.*);

    // Tessellate outlines.
    // This is done in separate pass in order to ensure
    // seamless height values across the ply boundaries.
    if (sample_dist > 0) {
        var i: i32 = 0;
        var j: i32 = nin - 1;
        while (i < nin) : ({
            j = i;
            i += 1;
        }) {
            var vj = point(in_verts, j);
            var vi = point(in_verts, i);
            var swapped = false;
            // Make sure the segments are always handled in same order
            // using lexological sort or else there will be seams.
            if (@abs(vj[0] - vi[0]) < 1e-6) {
                if (vj[2] > vi[2]) {
                    std.mem.swap(*const [3]f32, &vj, &vi);
                    swapped = true;
                }
            } else {
                if (vj[0] > vi[0]) {
                    std.mem.swap(*const [3]f32, &vj, &vi);
                    swapped = true;
                }
            }
            // Create samples along the edge.
            const dx = vi[0] - vj[0];
            const dy = vi[1] - vj[1];
            const dz = vi[2] - vj[2];
            const d = @sqrt(dx * dx + dz * dz);
            var nn = 1 + recast.truncateToInt(@floor(d / sample_dist));
            if (nn >= max_verts_per_edge) nn = max_verts_per_edge - 1;
            if (nverts.* + nn >= max_verts) nn = max_verts - 1 - nverts.*;

            var k: i32 = 0;
            while (k <= nn) : (k += 1) {
                const u = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(nn));
                const pos = edge[@intCast(k * 3)..][0..3];
                pos[0] = vj[0] + dx * u;
                pos[1] = vj[1] + dy * u;
                pos[2] = vj[2] + dz * u;
                const h = getHeight(pos[0], pos[1], pos[2], ics, chf.ch, height_search_radius, hp);
                pos[1] = @as(f32, @floatFromInt(h)) * chf.ch;
            }
            // Simplify samples.
            var idx: [max_verts_per_edge]i32 = @splat(0);
            idx[1] = nn;
            var nidx: i32 = 2;
            k = 0;
            while (k < nidx - 1) {
                const a = idx[@intCast(k)];
                const b = idx[@intCast(k + 1)];
                // Find maximum deviation along the segment.
                var maxd: f32 = 0;
                var maxi: i32 = -1;
                var m = a + 1;
                while (m < b) : (m += 1) {
                    const va = point(&edge, a);
                    const vb = point(&edge, b);
                    const dev = distancePtSeg(point(&edge, m), va, vb);
                    if (dev > maxd) {
                        maxd = dev;
                        maxi = m;
                    }
                }
                // If the max deviation is larger than accepted error,
                // add new point, else continue to next segment.
                if (maxi != -1 and maxd > sample_max_error * sample_max_error) {
                    var n = nidx;
                    while (n > k) : (n -= 1) idx[@intCast(n)] = idx[@intCast(n - 1)];
                    idx[@intCast(k + 1)] = maxi;
                    nidx += 1;
                } else {
                    k += 1;
                }
            }

            hull[@intCast(nhull)] = j;
            nhull += 1;
            // Add new vertices.
            if (swapped) {
                k = nidx - 2;
                while (k > 0) : (k -= 1) {
                    verts[@intCast(nverts.* * 3)..][0..3].* = point(&edge, idx[@intCast(k)]).*;
                    hull[@intCast(nhull)] = nverts.*;
                    nhull += 1;
                    nverts.* += 1;
                }
            } else {
                k = 1;
                while (k < nidx - 1) : (k += 1) {
                    verts[@intCast(nverts.* * 3)..][0..3].* = point(&edge, idx[@intCast(k)]).*;
                    hull[@intCast(nhull)] = nverts.*;
                    nhull += 1;
                    nverts.* += 1;
                }
            }
        }
    } else {
        // Without edge samples the hull is the polygon's own vertices, in
        // the order the pass above gives them when it adds none. Upstream
        // leaves the hull empty here, and its triangulation then reads
        // outside it and never ends.
        var j: i32 = nin - 1;
        var i: i32 = 0;
        while (i < nin) : ({
            j = i;
            i += 1;
        }) {
            hull[@intCast(nhull)] = j;
            nhull += 1;
        }
    }

    // If the polygon minimum extent is small (sliver or small triangle), do
    // not try to add internal points.
    if (min_extent < sample_dist * 2) {
        try triangulateHull(gpa, verts, nhull, &hull, nin, tris);
        setTriFlags(tris.items, nhull, &hull);
        return;
    }

    // Tessellate the base mesh.
    // We're using the triangulateHull instead of delaunayHull as it tends to
    // create a bit better triangulation for long thin triangles when there
    // are no internal points.
    try triangulateHull(gpa, verts, nhull, &hull, nin, tris);

    if (tris.items.len == 0) {
        // Could not triangulate the poly, make sure there is some valid data there.
        ctx.log(
            .warning,
            "buildPolyDetail: Could not triangulate polygon ({d} verts).",
            .{nverts.*},
        );
        return;
    }

    if (sample_dist > 0) {
        // Create sample locations in a grid.
        var bmin: [3]f32 = in_verts[0..3].*;
        var bmax: [3]f32 = in_verts[0..3].*;
        var i: i32 = 1;
        while (i < nin) : (i += 1) {
            recast.vmin(&bmin, point(in_verts, i));
            recast.vmax(&bmax, point(in_verts, i));
        }
        const x0 = recast.truncateToInt(@floor(bmin[0] / sample_dist));
        const x1 = recast.truncateToInt(@ceil(bmax[0] / sample_dist));
        const z0 = recast.truncateToInt(@floor(bmin[2] / sample_dist));
        const z1 = recast.truncateToInt(@ceil(bmax[2] / sample_dist));
        samples.clearRetainingCapacity();
        var z = z0;
        while (z < z1) : (z += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                var pt: [3]f32 = undefined;
                pt[0] = @as(f32, @floatFromInt(x)) * sample_dist;
                pt[1] = (bmax[1] + bmin[1]) * 0.5;
                pt[2] = @as(f32, @floatFromInt(z)) * sample_dist;
                // Make sure the samples are not too close to the edges.
                if (distToPoly(nin, in_verts, &pt) > -sample_dist / 2) continue;
                const h = getHeight(pt[0], pt[1], pt[2], ics, chf.ch, height_search_radius, hp);
                // The last value marks the sample as not added yet.
                try samples.appendSlice(gpa, &[_]i32{ x, h, z, 0 });
            }
        }

        // Add the samples starting from the one that has the most
        // error. The procedure stops when all samples are added
        // or when the max error is within treshold.
        const nsamples = samples.items.len / 4;
        try search.place(gpa, samples.items, sample_dist, cs, chf.ch);
        for (0..nsamples) |_| {
            if (nverts.* >= max_verts) break;

            // Find sample with most error.
            search.measure(verts, tris.items);
            var bestd: f32 = 0;
            var besti: ?usize = null;
            for (0..nsamples) |k| {
                if (samples.items[k * 4 + 3] != 0) continue; // skip added.
                const d = search.dmin.items[k];
                if (d == flt_max) continue; // did not hit the mesh.
                if (d > bestd) {
                    bestd = d;
                    besti = k;
                }
            }
            // If the max error is within accepted threshold, stop tesselating.
            if (bestd <= sample_max_error) break;
            const best = besti orelse break;
            // Mark sample as added.
            samples.items[best * 4 + 3] = 1;
            // Add the new sample point.
            verts[@intCast(nverts.* * 3)..][0..3].* = search.position(best);
            nverts.* += 1;

            // Create new triangulation.
            edges.clearRetainingCapacity();
            tris.clearRetainingCapacity();
            try delaunayHull(ctx, gpa, nverts.*, verts, nhull, &hull, tris, edges);
        }
    }

    const ntris: i32 = @intCast(tris.items.len / 4);
    if (ntris > max_tris) {
        tris.shrinkRetainingCapacity(max_tris * 4);
        ctx.log(
            .err,
            "rcBuildPolyMeshDetail: Shrinking triangle count from {d} to max {d}.",
            .{ ntris, max_tris },
        );
    }

    setTriFlags(tris.items, nhull, &hull);
}

/// Seeds `array` with the span at the polygon's center, reached by a
/// depth-first walk from the span closest to one of its vertices, and
/// leaves the patch unset but for that span's height.
fn seedArrayWithPolyCenter(
    ctx: Context,
    gpa: Allocator,
    chf: *const CompactHeightfield,
    poly: []const u16,
    npoly: i32,
    verts: []const u16,
    bs: i32,
    hp: *HeightPatch,
    array: *std.ArrayList(i32),
) Allocator.Error!void {
    // Note: Reads to the compact heightfield are offset by border size (bs)
    // since border size offset is already removed from the polymesh vertices.

    const offset = [9 * 2]i32{ 0, 0, -1, -1, 0, -1, 1, -1, 1, 0, 1, 1, 0, 1, -1, 1, -1, 0 };

    // Find cell closest to a poly vertex
    var start_cell_x: i32 = 0;
    var start_cell_y: i32 = 0;
    var start_span_index: i32 = -1;
    var dmin: i32 = unset_height;
    var j: i32 = 0;
    while (j < npoly and dmin > 0) : (j += 1) {
        const v = verts[@as(usize, poly[@intCast(j)]) * 3 ..][0..3];
        var k: usize = 0;
        while (k < 9 and dmin > 0) : (k += 1) {
            const ax = @as(i32, v[0]) + offset[k * 2 + 0];
            const ay: i32 = v[1];
            const az = @as(i32, v[2]) + offset[k * 2 + 1];
            if (ax < hp.xmin or ax >= hp.xmin + hp.width or
                az < hp.ymin or az >= hp.ymin + hp.height)
            {
                continue;
            }

            const c = chf.cells[@intCast((ax + bs) + (az + bs) * chf.width)];
            var i: i32 = c.index;
            const ni = i + c.count;
            while (i < ni and dmin > 0) : (i += 1) {
                const s = chf.spans[@intCast(i)];
                const d: i32 = @intCast(@abs(ay - @as(i32, s.y)));
                if (d < dmin) {
                    start_cell_x = ax;
                    start_cell_y = az;
                    start_span_index = i;
                    dmin = d;
                }
            }
        }
    }

    // A vertex of the polygon has a span in a cell next to it.
    assert(start_span_index != -1);
    // Find center of the polygon
    var pcx: i32 = 0;
    var pcy: i32 = 0;
    j = 0;
    while (j < npoly) : (j += 1) {
        const v = verts[@as(usize, poly[@intCast(j)]) * 3 ..][0..3];
        pcx += v[0];
        pcy += v[2];
    }
    pcx = @divTrunc(pcx, npoly);
    pcy = @divTrunc(pcy, npoly);

    // Use seeds array as a stack for DFS
    array.clearRetainingCapacity();
    try array.appendSlice(gpa, &[_]i32{ start_cell_x, start_cell_y, start_span_index });

    var dirs = [4]u2{ 0, 1, 2, 3 };
    const patch = hp.data[0..@intCast(hp.width * hp.height)];
    @memset(patch, 0);
    // DFS to move to the center. Note that we need a DFS here and can not just move
    // directly towards the center without recording intermediate nodes, even though the polygons
    // are convex. In very rare we can get stuck due to contour simplification if we do not
    // record nodes.
    var cx: i32 = -1;
    var cy: i32 = -1;
    var ci: i32 = -1;
    while (true) {
        if (array.items.len < 3) {
            ctx.log(.warning, "Walk towards polygon center failed to reach center", .{});
            break;
        }

        ci = array.pop().?;
        cy = array.pop().?;
        cx = array.pop().?;

        if (cx == pcx and cy == pcy) break;

        // If we are already at the correct X-position, prefer direction
        // directly towards the center in the Y-axis; otherwise prefer
        // direction in the X-axis
        const direct_dir: usize = @intCast(if (cx == pcx)
            recast.getDirForOffset(0, if (pcy > cy) 1 else -1)
        else
            recast.getDirForOffset(if (pcx > cx) 1 else -1, 0));

        // Push the direct dir last so we start with this on next iteration
        std.mem.swap(u2, &dirs[direct_dir], &dirs[3]);

        const span = chf.spans[@intCast(ci)];
        for (dirs) |dir| {
            if (recast.getCon(span, dir) == recast.not_connected) continue;

            const new_x = cx + recast.getDirOffsetX(dir);
            const new_y = cy + recast.getDirOffsetY(dir);

            const hpx = new_x - hp.xmin;
            const hpy = new_y - hp.ymin;
            if (hpx < 0 or hpx >= hp.width or hpy < 0 or hpy >= hp.height) continue;

            if (patch[@intCast(hpx + hpy * hp.width)] != 0) continue;

            patch[@intCast(hpx + hpy * hp.width)] = 1;
            const cell = chf.cells[@intCast((new_x + bs) + (new_y + bs) * chf.width)];
            const new_index = @as(i32, cell.index) + recast.getCon(span, dir);
            try array.appendSlice(gpa, &[_]i32{ new_x, new_y, new_index });
        }

        std.mem.swap(u2, &dirs[direct_dir], &dirs[3]);
    }

    array.clearRetainingCapacity();
    // getHeightData seeds are given in coordinates with borders
    try array.appendSlice(gpa, &[_]i32{ cx + bs, cy + bs, ci });

    @memset(patch, unset_height);
    const seed_span = chf.spans[@intCast(ci)];
    patch[@intCast(cx - hp.xmin + (cy - hp.ymin) * hp.width)] = seed_span.y;
}

fn push3(
    gpa: Allocator,
    queue: *std.ArrayList(i32),
    v1: i32,
    v2: i32,
    v3: i32,
) Allocator.Error!void {
    try queue.appendSlice(gpa, &[_]i32{ v1, v2, v3 });
}

/// Whether each span has a neighbor in another region, where the flood of
/// a polygon's heights starts, worked out the first time a polygon asks:
/// the polygons' patches overlap, and a span keeps its answer.
const RegionBorders = struct {
    /// Per span: 0 not known yet, 1 inside its region, 2 on its border.
    known: []u8,

    fn has(
        borders: *RegionBorders,
        chf: *const CompactHeightfield,
        x: i32,
        y: i32,
        i: usize,
    ) bool {
        if (borders.known[i] == 0) {
            const s = chf.spans[i];
            var border = false;
            for ([4]u2{ 0, 1, 2, 3 }) |dir| {
                if (recast.getCon(s, dir) != recast.not_connected) {
                    const ax = x + recast.getDirOffsetX(dir);
                    const ay = y + recast.getDirOffsetY(dir);
                    const neighbor_cell = chf.cells[@intCast(ax + ay * chf.width)];
                    const ai = @as(i32, neighbor_cell.index) + recast.getCon(s, dir);
                    if (chf.spans[@intCast(ai)].reg != s.reg) {
                        border = true;
                        break;
                    }
                }
            }
            borders.known[i] = if (border) 2 else 1;
        }
        return borders.known[i] == 2;
    }
};

/// Fills the patch with the heights of the polygon's region, flooding out
/// from the region's border, or from the polygon's center where the region
/// has no span under the polygon or the polygon joins several regions.
fn getHeightData(
    ctx: Context,
    gpa: Allocator,
    chf: *const CompactHeightfield,
    borders: *RegionBorders,
    poly: []const u16,
    npoly: i32,
    verts: []const u16,
    bs: i32,
    hp: *HeightPatch,
    queue: *std.ArrayList(i32),
    region: i32,
) Allocator.Error!void {
    // Note: Reads to the compact heightfield are offset by border size (bs)
    // since border size offset is already removed from the polymesh vertices.

    queue.clearRetainingCapacity();
    // Set all heights to RC_UNSET_HEIGHT.
    @memset(hp.data[0..@intCast(hp.width * hp.height)], unset_height);

    var empty = true;

    // We cannot sample from this poly if it was created from polys
    // of different regions. If it was then it could potentially be overlapping
    // with polys of that region and the heights sampled here could be wrong.
    if (region != recast.multiple_regs) {
        // Copy the height from the same region, and mark region borders
        // as seed points to fill the rest.
        const cells = chf.cells;
        const spans = chf.spans;
        const data = hp.data;
        var hy: i32 = 0;
        while (hy < hp.height) : (hy += 1) {
            const y = hp.ymin + hy + bs;
            var hx: i32 = 0;
            while (hx < hp.width) : (hx += 1) {
                const x = hp.xmin + hx + bs;
                const c = cells[@intCast(x + y * chf.width)];
                for (c.index..@as(usize, c.index) + c.count) |i| {
                    const s = spans[i];
                    if (s.reg == region) {
                        // Store height
                        data[@intCast(hx + hy * hp.width)] = s.y;
                        empty = false;
                        // If any of the neighbours is not in same region,
                        // add the current location as flood fill start
                        if (borders.has(chf, x, y, i)) try push3(gpa, queue, x, y, @intCast(i));
                        break;
                    }
                }
            }
        }
    }

    // if the polygon does not contain any points from the current region (rare, but happens)
    // or if it could potentially be overlapping polygons of the same region,
    // then use the center as the seed point.
    if (empty) try seedArrayWithPolyCenter(ctx, gpa, chf, poly, npoly, verts, bs, hp, queue);

    const retract_size = 256;
    var head: usize = 0;

    // We assume the seed is centered in the polygon, so a BFS to collect
    // height data will ensure we do not move onto overlapping polygons and
    // sample wrong heights.
    while (head * 3 < queue.items.len) {
        const cx = queue.items[head * 3 + 0];
        const cy = queue.items[head * 3 + 1];
        const ci = queue.items[head * 3 + 2];
        head += 1;
        if (head >= retract_size) {
            head = 0;
            const len = queue.items.len;
            if (len > retract_size * 3) {
                std.mem.copyForwards(i32, queue.items[0..], queue.items[retract_size * 3 ..]);
            }
            queue.shrinkRetainingCapacity(len - retract_size * 3);
        }

        const span = chf.spans[@intCast(ci)];
        for ([4]u2{ 0, 1, 2, 3 }) |dir| {
            if (recast.getCon(span, dir) == recast.not_connected) continue;

            const ax = cx + recast.getDirOffsetX(dir);
            const ay = cy + recast.getDirOffsetY(dir);
            const hx = ax - hp.xmin - bs;
            const hy = ay - hp.ymin - bs;

            // Unsigned, so negative offsets are out of the patch too.
            if (@as(u32, @bitCast(hx)) >= @as(u32, @bitCast(hp.width)) or
                @as(u32, @bitCast(hy)) >= @as(u32, @bitCast(hp.height)))
            {
                continue;
            }

            if (hp.data[@intCast(hx + hy * hp.width)] != unset_height) continue;

            const cell = chf.cells[@intCast(ax + ay * chf.width)];
            const ai = @as(i32, cell.index) + recast.getCon(span, dir);
            const neighbor = chf.spans[@intCast(ai)];

            hp.data[@intCast(hx + hy * hp.width)] = neighbor.y;

            try push3(gpa, queue, ax, ay, ai);
        }
    }
}

/// The low byte of `value`, as C's conversion to unsigned char gives.
fn lowByte(value: i32) u8 {
    return @truncate(@as(u32, @bitCast(value)));
}

/// Builds a detail mesh over each polygon of `pmesh`, with heights from
/// `chf`: samples `sample_dist` apart (0 for none, only the polygons' own
/// vertices) are added where the surface strays more than
/// `sample_max_error` from the triangles. An empty poly mesh gives an
/// empty detail mesh. A polygon of more than 127 vertices, which a poly
/// mesh with an `nvp` past 127 can hold, gives
/// `error.TooManyPolygonVertices` before any work.
pub fn buildPolyMeshDetail(
    ctx: Context,
    gpa: Allocator,
    pmesh: *const PolyMesh,
    chf: *const CompactHeightfield,
    sample_dist: f32,
    sample_max_error: f32,
) BuildPolyMeshDetailError!PolyMeshDetail {
    ctx.startTimer(.build_polymeshdetail);
    defer ctx.stopTimer(.build_polymeshdetail);

    if (pmesh.nverts == 0 or pmesh.npolys == 0) return .empty;

    const nvp: usize = @intCast(pmesh.nvp);
    const npolys: usize = @intCast(pmesh.npolys);
    if (nvp > max_detail_verts) {
        for (0..npolys) |i| {
            const p = pmesh.polys[i * nvp * 2 ..][0..nvp];
            const n = std.mem.findScalar(u16, p, recast.mesh_null_idx) orelse nvp;
            if (n <= max_detail_verts) continue;
            ctx.log(
                .err,
                "rcBuildPolyMeshDetail: Polygon {d} has {d} vertices, more than the {d} a " ++
                    "detail mesh holds.",
                .{ i, n, max_detail_verts },
            );
            return error.TooManyPolygonVertices;
        }
    }
    const cs = pmesh.cs;
    const ch = pmesh.ch;
    const orig = &pmesh.bmin;
    const border_size = pmesh.border_size;
    const height_search_radius = @max(1, recast.truncateToInt(@ceil(pmesh.max_edge_error)));

    var edges: std.ArrayList(i32) = .empty;
    defer edges.deinit(gpa);
    try edges.ensureTotalCapacity(gpa, 64);
    var tris: std.ArrayList(i32) = .empty;
    defer tris.deinit(gpa);
    try tris.ensureTotalCapacity(gpa, 512);
    var arr: std.ArrayList(i32) = .empty;
    defer arr.deinit(gpa);
    try arr.ensureTotalCapacity(gpa, 512);
    var samples: std.ArrayList(i32) = .empty;
    defer samples.deinit(gpa);
    try samples.ensureTotalCapacity(gpa, 512);
    var search: SampleSearch = .{};
    defer search.deinit(gpa);
    var borders: RegionBorders = .{ .known = try gpa.alloc(u8, @intCast(chf.span_count)) };
    defer gpa.free(borders.known);
    @memset(borders.known, 0);
    var verts: [256 * 3]f32 = undefined;
    var n_poly_verts: i32 = 0;
    var maxhw: i32 = 0;
    var maxhh: i32 = 0;

    const bounds = gpa.alloc(i32, npolys * 4) catch |err| {
        ctx.log(
            .err,
            "rcBuildPolyMeshDetail: Out of memory 'bounds' ({d}).",
            .{pmesh.npolys * 4},
        );
        return err;
    };
    defer gpa.free(bounds);
    const poly = gpa.alloc(f32, nvp * 3) catch |err| {
        ctx.log(.err, "rcBuildPolyMeshDetail: Out of memory 'poly' ({d}).", .{pmesh.nvp * 3});
        return err;
    };
    defer gpa.free(poly);

    // Find max size for a polygon area.
    for (0..npolys) |i| {
        const p = pmesh.polys[i * nvp * 2 ..][0 .. nvp * 2];
        var xmin = chf.width;
        var xmax: i32 = 0;
        var ymin = chf.height;
        var ymax: i32 = 0;
        for (p[0..nvp]) |vertex| {
            if (vertex == recast.mesh_null_idx) break;
            const v = pmesh.verts[@as(usize, vertex) * 3 ..][0..3];
            xmin = @min(xmin, @as(i32, v[0]));
            xmax = @max(xmax, @as(i32, v[0]));
            ymin = @min(ymin, @as(i32, v[2]));
            ymax = @max(ymax, @as(i32, v[2]));
            n_poly_verts += 1;
        }
        xmin = @max(0, xmin - 1);
        xmax = @min(chf.width, xmax + 1);
        ymin = @max(0, ymin - 1);
        ymax = @min(chf.height, ymax + 1);
        bounds[i * 4 ..][0..4].* = .{ xmin, xmax, ymin, ymax };
        if (xmin >= xmax or ymin >= ymax) continue;
        maxhw = @max(maxhw, xmax - xmin);
        maxhh = @max(maxhh, ymax - ymin);
    }

    var hp: HeightPatch = .{
        .data = gpa.alloc(u16, @intCast(maxhw * maxhh)) catch |err| {
            ctx.log(
                .err,
                "rcBuildPolyMeshDetail: Out of memory 'hp.data' ({d}).",
                .{maxhw * maxhh},
            );
            return err;
        },
    };
    defer gpa.free(hp.data);

    const nmeshes = pmesh.npolys;
    const meshes = gpa.alloc(u32, @intCast(nmeshes * 4)) catch |err| {
        ctx.log(
            .err,
            "rcBuildPolyMeshDetail: Out of memory 'dmesh.meshes' ({d}).",
            .{nmeshes * 4},
        );
        return err;
    };
    errdefer gpa.free(meshes);

    var vcap = n_poly_verts + @divTrunc(n_poly_verts, 2);
    var tcap = vcap * 2;

    var dverts = gpa.alloc(f32, @intCast(vcap * 3)) catch |err| {
        ctx.log(.err, "rcBuildPolyMeshDetail: Out of memory 'dmesh.verts' ({d}).", .{vcap * 3});
        return err;
    };
    errdefer gpa.free(dverts);
    var dnverts: i32 = 0;
    var dtris = gpa.alloc(u8, @intCast(tcap * 4)) catch |err| {
        ctx.log(.err, "rcBuildPolyMeshDetail: Out of memory 'dmesh.tris' ({d}).", .{tcap * 4});
        return err;
    };
    errdefer gpa.free(dtris);
    var dntris: i32 = 0;

    for (0..npolys) |i| {
        const p = pmesh.polys[i * nvp * 2 ..][0 .. nvp * 2];

        // Store polygon vertices for processing.
        var npoly: i32 = 0;
        for (p[0..nvp], 0..) |vertex, j| {
            if (vertex == recast.mesh_null_idx) break;
            const v = pmesh.verts[@as(usize, vertex) * 3 ..][0..3];
            poly[j * 3 + 0] = @as(f32, @floatFromInt(v[0])) * cs;
            poly[j * 3 + 1] = @as(f32, @floatFromInt(v[1])) * ch;
            poly[j * 3 + 2] = @as(f32, @floatFromInt(v[2])) * cs;
            npoly += 1;
        }

        // Get the height data from the area of the polygon.
        hp.xmin = bounds[i * 4 + 0];
        hp.ymin = bounds[i * 4 + 2];
        hp.width = bounds[i * 4 + 1] - bounds[i * 4 + 0];
        hp.height = bounds[i * 4 + 3] - bounds[i * 4 + 2];
        try getHeightData(
            ctx,
            gpa,
            chf,
            &borders,
            p,
            npoly,
            pmesh.verts,
            border_size,
            &hp,
            &arr,
            pmesh.regs[i],
        );

        // Build detail mesh.
        var nverts: i32 = 0;
        try buildPolyDetail(
            ctx,
            gpa,
            poly,
            npoly,
            sample_dist,
            sample_max_error,
            height_search_radius,
            chf,
            &hp,
            &verts,
            &nverts,
            &tris,
            &edges,
            &samples,
            &search,
        );

        const nverts_used: usize = @intCast(nverts);
        // Move detail verts to world space; their heights sit a cell above
        // the samples'.
        for (0..nverts_used) |j| {
            verts[j * 3 + 0] += orig[0];
            verts[j * 3 + 1] += orig[1] + chf.ch;
            verts[j * 3 + 2] += orig[2];
        }
        // Offset poly too, as upstream does.
        for (0..@intCast(npoly)) |j| {
            poly[j * 3 + 0] += orig[0];
            poly[j * 3 + 1] += orig[1];
            poly[j * 3 + 2] += orig[2];
        }

        // Store detail submesh.
        const ntris: i32 = @intCast(tris.items.len / 4);

        meshes[i * 4 + 0] = @intCast(dnverts);
        meshes[i * 4 + 1] = @intCast(nverts);
        meshes[i * 4 + 2] = @intCast(dntris);
        meshes[i * 4 + 3] = @intCast(ntris);

        // Store vertices, allocate more memory if necessary.
        if (dnverts + nverts > vcap) {
            while (dnverts + nverts > vcap) vcap += 256;

            const newv = gpa.alloc(f32, @intCast(vcap * 3)) catch |err| {
                ctx.log(.err, "rcBuildPolyMeshDetail: Out of memory 'newv' ({d}).", .{vcap * 3});
                return err;
            };
            const used: usize = @intCast(dnverts * 3);
            @memcpy(newv[0..used], dverts[0..used]);
            gpa.free(dverts);
            dverts = newv;
        }
        for (0..nverts_used) |j| {
            dverts[@intCast(dnverts * 3)..][0..3].* = verts[j * 3 ..][0..3].*;
            dnverts += 1;
        }

        // Store triangles, allocate more memory if necessary.
        if (dntris + ntris > tcap) {
            while (dntris + ntris > tcap) tcap += 256;
            const newt = gpa.alloc(u8, @intCast(tcap * 4)) catch |err| {
                ctx.log(.err, "rcBuildPolyMeshDetail: Out of memory 'newt' ({d}).", .{tcap * 4});
                return err;
            };
            const used: usize = @intCast(dntris * 4);
            @memcpy(newt[0..used], dtris[0..used]);
            gpa.free(dtris);
            dtris = newt;
        }
        for (0..@intCast(ntris)) |j| {
            const t = tris.items[j * 4 ..][0..4];
            const dst = dtris[@intCast(dntris * 4)..][0..4];
            dst.* = .{ lowByte(t[0]), lowByte(t[1]), lowByte(t[2]), lowByte(t[3]) };
            dntris += 1;
        }
    }

    return .{
        .meshes = meshes,
        .verts = dverts,
        .tris = dtris,
        .nmeshes = nmeshes,
        .nverts = dnverts,
        .ntris = dntris,
    };
}

/// Joins detail meshes into one, in order, offsetting each sub-mesh's
/// first vertex and triangle.
pub fn mergePolyMeshDetails(
    ctx: Context,
    gpa: Allocator,
    meshes: []const *const PolyMeshDetail,
) Allocator.Error!PolyMeshDetail {
    ctx.startTimer(.merge_polymeshdetail);
    defer ctx.stopTimer(.merge_polymeshdetail);

    var max_verts: i32 = 0;
    var max_tris: i32 = 0;
    var max_meshes: i32 = 0;

    for (meshes) |dm| {
        max_verts += dm.nverts;
        max_tris += dm.ntris;
        max_meshes += dm.nmeshes;
    }

    const out_meshes = gpa.alloc(u32, @intCast(max_meshes * 4)) catch |err| {
        ctx.log(
            .err,
            "rcBuildPolyMeshDetail: Out of memory 'pmdtl.meshes' ({d}).",
            .{max_meshes * 4},
        );
        return err;
    };
    errdefer gpa.free(out_meshes);

    const out_tris = gpa.alloc(u8, @intCast(max_tris * 4)) catch |err| {
        ctx.log(.err, "rcBuildPolyMeshDetail: Out of memory 'dmesh.tris' ({d}).", .{max_tris * 4});
        return err;
    };
    errdefer gpa.free(out_tris);

    const out_verts = gpa.alloc(f32, @intCast(max_verts * 3)) catch |err| {
        ctx.log(
            .err,
            "rcBuildPolyMeshDetail: Out of memory 'dmesh.verts' ({d}).",
            .{max_verts * 3},
        );
        return err;
    };

    var nmeshes: usize = 0;
    var nverts: usize = 0;
    var ntris: usize = 0;

    // Merge datas.
    for (meshes) |dm| {
        for (0..@intCast(dm.nmeshes)) |j| {
            const dst = out_meshes[nmeshes * 4 ..][0..4];
            const src = dm.meshes[j * 4 ..][0..4];
            dst[0] = @as(u32, @intCast(nverts)) +% src[0];
            dst[1] = src[1];
            dst[2] = @as(u32, @intCast(ntris)) +% src[2];
            dst[3] = src[3];
            nmeshes += 1;
        }

        for (0..@intCast(dm.nverts)) |k| {
            out_verts[nverts * 3 ..][0..3].* = dm.verts[k * 3 ..][0..3].*;
            nverts += 1;
        }
        for (0..@intCast(dm.ntris)) |k| {
            out_tris[ntris * 4 ..][0..4].* = dm.tris[k * 4 ..][0..4].*;
            ntris += 1;
        }
    }

    return .{
        .meshes = out_meshes,
        .verts = out_verts,
        .tris = out_tris,
        .nmeshes = @intCast(nmeshes),
        .nverts = @intCast(nverts),
        .ntris = @intCast(ntris),
    };
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "jitter wraps the multiply as unsigned" {
    try testing.expectEqual(-1.0, getJitterX(0));
    const bits: u32 = @as(u32, 7) *% 0x8da6b343;
    const expected = @as(f32, @floatFromInt(bits & 0xffff)) / 65535.0 * 2.0 - 1.0;
    try testing.expectEqual(expected, getJitterX(7));
    try testing.expect(getJitterY(-3) >= -1.0 and getJitterY(-3) <= 1.0);
}

/// Upstream's `distToTriMesh`, one sample and one triangle at a time.
fn distToTriMeshScalar(p: *const [3]f32, verts: []const f32, tris: []const i32) f32 {
    var dmin = flt_max;
    var t: usize = 0;
    while (t < tris.len) : (t += 4) {
        const a = point(verts, tris[t + 0]);
        const b = point(verts, tris[t + 1]);
        const c = point(verts, tris[t + 2]);
        const v0 = recast.vsub(c, a);
        const v1 = recast.vsub(b, a);
        const v2 = recast.vsub(p, a);
        const dot00 = vdot2(&v0, &v0);
        const dot01 = vdot2(&v0, &v1);
        const dot02 = vdot2(&v0, &v2);
        const dot11 = vdot2(&v1, &v1);
        const dot12 = vdot2(&v1, &v2);
        const inv_denom = 1.0 / (dot00 * dot11 - dot01 * dot01);
        const u = (dot11 * dot02 - dot01 * dot12) * inv_denom;
        const v = (dot00 * dot12 - dot01 * dot02) * inv_denom;
        const eps: f32 = 1e-4;
        var d = flt_max;
        if (u >= -eps and v >= -eps and (u + v) <= 1 + eps) {
            const y = a[1] + v0[1] * u + v1[1] * v;
            d = @abs(y - p[1]);
        }
        if (d < dmin) dmin = d;
    }
    return dmin;
}

test "the sample search measures each sample as upstream's distToTriMesh" {
    const gpa = testing.allocator;
    var prng: std.Random.DefaultPrng = .init(0x5a3c);
    const random = prng.random();
    var search: SampleSearch = .{};
    defer search.deinit(gpa);
    var verts: [3 * 48]f32 = undefined;
    var tris: [4 * 16]i32 = undefined;
    var samples: [4 * 301]i32 = undefined;
    for (0..200) |_| {
        for (&verts) |*v| v.* = (random.float(f32) - 0.5) * 100;
        // Some triangles flat or with a vertex twice.
        verts[3..6].* = verts[0..3].*;
        for (verts[6..9], verts[0..3], verts[9..12]) |*v, a, b| v.* = (a + b) * 0.5;
        for (&tris, 0..) |*t, i| t.* = if (i % 4 == 3) 0 else random.intRangeLessThan(i32, 0, 16);
        tris[0..3].* = .{ 0, 1, 2 };
        tris[4..7].* = .{ 0, 2, 3 };
        const nsamples = random.intRangeAtMost(usize, 1, 301);
        for (0..nsamples) |i| {
            samples[i * 4 ..][0..4].* = .{
                random.intRangeAtMost(i32, -30, 30),
                random.intRangeAtMost(i32, 0, 50),
                random.intRangeAtMost(i32, -30, 30),
                0,
            };
        }
        try search.place(gpa, samples[0 .. nsamples * 4], 1.7, 0.3, 0.2);
        // Half the samples moved onto the edges of the tolerance around a
        // triangle: one barycentric coordinate at -1e-4 or their sum at
        // 1 + 1e-4, give or take a little.
        for (0..nsamples / 2) |i| {
            const t = random.uintLessThan(usize, 16) * 4;
            const a = point(&verts, tris[t + 0]);
            const b = point(&verts, tris[t + 1]);
            const c = point(&verts, tris[t + 2]);
            const near = 1e-4 * (1 + (random.float(f32) - 0.5) * 0.2);
            var u = random.float(f32);
            var v = random.float(f32) * (1 - u);
            switch (random.uintLessThan(u8, 3)) {
                0 => u = -near,
                1 => v = -near,
                else => v = 1 + near - u,
            }
            search.xs.items[i] = a[0] + (c[0] - a[0]) * u + (b[0] - a[0]) * v;
            search.zs.items[i] = a[2] + (c[2] - a[2]) * u + (b[2] - a[2]) * v;
        }
        search.measure(&verts, &tris);
        for (0..nsamples) |i| {
            const p = search.position(i);
            const expected = distToTriMeshScalar(&p, &verts, &tris);
            try testing.expectEqual(
                @as(u32, @bitCast(expected)),
                @as(u32, @bitCast(search.dmin.items[i])),
            );
        }
    }
}

test "a polygon with no samples triangulates its own vertices" {
    // A square one cell above a flat patch: with sample_dist 0 the hull is
    // the four corners and the triangulation two triangles.
    var data: [16]u16 = @splat(5);
    const hp: HeightPatch = .{ .data = &data, .width = 4, .height = 4 };
    var chf: CompactHeightfield = undefined;
    chf.cs = 1;
    chf.ch = 1;
    const square = [_]f32{ 0, 5, 0, 0, 5, 3, 3, 5, 3, 3, 5, 0 };
    var verts: [256 * 3]f32 = undefined;
    var nverts: i32 = 0;
    var tris: std.ArrayList(i32) = .empty;
    defer tris.deinit(testing.allocator);
    var edges: std.ArrayList(i32) = .empty;
    defer edges.deinit(testing.allocator);
    var samples: std.ArrayList(i32) = .empty;
    defer samples.deinit(testing.allocator);
    var search: SampleSearch = .{};
    defer search.deinit(testing.allocator);
    try buildPolyDetail(
        .none,
        testing.allocator,
        &square,
        4,
        0,
        1,
        1,
        &chf,
        &hp,
        &verts,
        &nverts,
        &tris,
        &edges,
        &samples,
        &search,
    );
    try testing.expectEqual(4, nverts);
    try testing.expectEqual(8, tris.items.len);
}
