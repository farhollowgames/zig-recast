// An altered version of Recast from recastnavigation 1.6.0, translated to
// Zig. Copyright (c) 2009-2010 Mikko Mononen memon@inside.org; zlib licence,
// see LICENSE.

//! Polygon mesh building: triangulates each contour, merges the triangles
//! into convex polygons, removes the tile-border vertices the contours
//! marked, and links each polygon to its neighbors. Translated from
//! RecastMesh.cpp.

const std = @import("std");
const Allocator = std.mem.Allocator;

const recast = @import("recast.zig");
const Context = recast.Context;
const ContourSet = recast.ContourSet;
const PolyMesh = recast.PolyMesh;
const mesh_null_idx = recast.mesh_null_idx;

pub const BuildPolyMeshError = Allocator.Error || error{
    /// The contours have more vertices than a mesh can index.
    TooManyVertices,
    /// More polygons than the contours have triangles; contours from
    /// `buildContours` never give it.
    TooManyPolygons,
};

pub const MergePolyMeshesError = Allocator.Error;

const Edge = struct {
    vert: [2]u16,
    poly_edge: [2]u16,
    poly: [2]u16,
};

/// Sets each polygon's neighbor across each edge another polygon shares.
fn buildMeshAdjacency(
    gpa: Allocator,
    polys: []u16,
    npolys: i32,
    nverts: i32,
    verts_per_poly: i32,
) Allocator.Error!void {
    // Based on code by Eric Lengyel from:
    // https://web.archive.org/web/20080704083314/http://www.terathon.com/code/edges.php
    const nvp: usize = @intCast(verts_per_poly);
    const poly_count: usize = @intCast(npolys);
    const vert_count: usize = @intCast(nverts);
    const max_edge_count = poly_count * nvp;
    const first_edge = try gpa.alloc(u16, vert_count + max_edge_count);
    defer gpa.free(first_edge);
    const next_edge = first_edge[vert_count..];
    var edge_count: usize = 0;

    const edges = try gpa.alloc(Edge, max_edge_count);
    defer gpa.free(edges);

    @memset(first_edge[0..vert_count], mesh_null_idx);

    for (0..poly_count) |i| {
        const t = polys[i * nvp * 2 ..][0..nvp];
        for (0..nvp) |j| {
            if (t[j] == mesh_null_idx) break;
            const v0 = t[j];
            const v1 = if (j + 1 >= nvp or t[j + 1] == mesh_null_idx) t[0] else t[j + 1];
            if (v0 < v1) {
                const edge = &edges[edge_count];
                edge.vert = .{ v0, v1 };
                edge.poly = .{ @truncate(i), @truncate(i) };
                edge.poly_edge = .{ @intCast(j), 0 };
                // Insert edge. Like upstream, an edge index above 0xffff is
                // stored truncated.
                next_edge[edge_count] = first_edge[v0];
                first_edge[v0] = @truncate(edge_count);
                edge_count += 1;
            }
        }
    }

    for (0..poly_count) |i| {
        const t = polys[i * nvp * 2 ..][0..nvp];
        for (0..nvp) |j| {
            if (t[j] == mesh_null_idx) break;
            const v0 = t[j];
            const v1 = if (j + 1 >= nvp or t[j + 1] == mesh_null_idx) t[0] else t[j + 1];
            if (v0 > v1) {
                var e = first_edge[v1];
                while (e != mesh_null_idx) : (e = next_edge[e]) {
                    const edge = &edges[e];
                    if (edge.vert[1] == v0 and edge.poly[0] == edge.poly[1]) {
                        edge.poly[1] = @truncate(i);
                        edge.poly_edge[1] = @intCast(j);
                        break;
                    }
                }
            }
        }
    }

    // Store adjacency
    for (edges[0..edge_count]) |e| {
        if (e.poly[0] != e.poly[1]) {
            const p0 = polys[@as(usize, e.poly[0]) * nvp * 2 ..];
            const p1 = polys[@as(usize, e.poly[1]) * nvp * 2 ..];
            p0[nvp + e.poly_edge[0]] = e.poly[1];
            p1[nvp + e.poly_edge[1]] = e.poly[0];
        }
    }
}

const vertex_bucket_count = 1 << 12;

fn computeVertexHash(x: u32, y: u32, z: u32) usize {
    const h1: u32 = 0x8da6b343; // Large multiplicative constants;
    const h2: u32 = 0xd8163841; // here arbitrarily chosen primes
    const h3: u32 = 0xcb1ab31f;
    const n = h1 *% x +% h2 *% y +% h3 *% z;
    return n & (vertex_bucket_count - 1);
}

/// The index of the vertex at x and z whose height is within 2 of y,
/// adding it if there is none. Like upstream, an index above 0xffff is
/// returned truncated.
fn addVertex(
    x: u16,
    y: u16,
    z: u16,
    verts: []u16,
    first_vert: []i32,
    next_vert: []i32,
    nv: *i32,
) u16 {
    const bucket = computeVertexHash(x, 0, z);
    var i = first_vert[bucket];

    while (i != -1) {
        const v = verts[@as(usize, @intCast(i)) * 3 ..][0..3];
        if (v[0] == x and @abs(@as(i32, v[1]) - @as(i32, y)) <= 2 and v[2] == z) {
            return @truncate(@as(u32, @intCast(i)));
        }
        i = next_vert[@intCast(i)]; // next
    }

    // Could not find, create new.
    i = nv.*;
    nv.* += 1;
    const v = verts[@as(usize, @intCast(i)) * 3 ..][0..3];
    v.* = .{ x, y, z };
    next_vert[@intCast(i)] = first_vert[bucket];
    first_vert[bucket] = i;

    return @truncate(@as(u32, @intCast(i)));
}

fn prev(i: usize, n: usize) usize {
    return if (i >= 1) i - 1 else n - 1;
}

fn next(i: usize, n: usize) usize {
    return if (i + 1 < n) i + 1 else 0;
}

// The vertex tests below work on contour vertices: x, y, z and flags. Their
// products wrap, as upstream's int arithmetic does when compiled without
// optimizations, for coordinates more than 46340 cells apart, where
// upstream's behaviour is undefined.

fn area2(a: *const [4]i32, b: *const [4]i32, c: *const [4]i32) i32 {
    return (b[0] -% a[0]) *% (c[2] -% a[2]) -% (c[0] -% a[0]) *% (b[2] -% a[2]);
}

/// Whether c is strictly to the left of the directed line through a to b.
fn left(a: *const [4]i32, b: *const [4]i32, c: *const [4]i32) bool {
    return area2(a, b, c) < 0;
}

fn leftOn(a: *const [4]i32, b: *const [4]i32, c: *const [4]i32) bool {
    return area2(a, b, c) <= 0;
}

fn collinear(a: *const [4]i32, b: *const [4]i32, c: *const [4]i32) bool {
    return area2(a, b, c) == 0;
}

/// Whether ab properly intersects cd: they share a point interior to both
/// segments. Strict leftness ensures the properness.
fn intersectProp(a: *const [4]i32, b: *const [4]i32, c: *const [4]i32, d: *const [4]i32) bool {
    // Eliminate improper cases.
    if (collinear(a, b, c) or collinear(a, b, d) or
        collinear(c, d, a) or collinear(c, d, b))
    {
        return false;
    }
    return (left(a, b, c) != left(a, b, d)) and (left(c, d, a) != left(c, d, b));
}

/// Whether a, b and c are collinear and c lies on the closed segment ab.
fn between(a: *const [4]i32, b: *const [4]i32, c: *const [4]i32) bool {
    if (!collinear(a, b, c)) return false;
    // If ab not vertical, check betweenness on x; else on y.
    if (a[0] != b[0]) {
        return (a[0] <= c[0] and c[0] <= b[0]) or (a[0] >= c[0] and c[0] >= b[0]);
    }
    return (a[2] <= c[2] and c[2] <= b[2]) or (a[2] >= c[2] and c[2] >= b[2]);
}

/// Whether segments ab and cd intersect, properly or improperly.
fn intersect(a: *const [4]i32, b: *const [4]i32, c: *const [4]i32, d: *const [4]i32) bool {
    if (intersectProp(a, b, c, d)) return true;
    if (between(a, b, c) or between(a, b, d) or
        between(c, d, a) or between(c, d, b))
    {
        return true;
    }
    return false;
}

fn vequal(a: *const [4]i32, b: *const [4]i32) bool {
    return a[0] == b[0] and a[2] == b[2];
}

/// The vertex a triangulation index names, ignoring the index's flag bit.
fn indexedVertex(verts: []const i32, index: u32) *const [4]i32 {
    return verts[@as(usize, index & 0x0fffffff) * 4 ..][0..4];
}

/// Whether (v_i, v_j) is a proper internal or external diagonal of the
/// polygon, ignoring edges incident to v_i and v_j.
fn diagonalie(i: usize, j: usize, n: usize, verts: []const i32, indices: []const u32) bool {
    const d0 = indexedVertex(verts, indices[i]);
    const d1 = indexedVertex(verts, indices[j]);

    // For each edge (k,k+1) of P
    for (0..n) |k| {
        const k1 = next(k, n);
        // Skip edges incident to i or j
        if (!(k == i or k1 == i or k == j or k1 == j)) {
            const p0 = indexedVertex(verts, indices[k]);
            const p1 = indexedVertex(verts, indices[k1]);

            if (vequal(d0, p0) or vequal(d1, p0) or vequal(d0, p1) or vequal(d1, p1)) continue;

            if (intersect(d0, d1, p0, p1)) return false;
        }
    }
    return true;
}

/// Whether the diagonal (i,j) is strictly internal to the polygon in the
/// neighborhood of the i endpoint.
fn inCone(i: usize, j: usize, n: usize, verts: []const i32, indices: []const u32) bool {
    const pi = indexedVertex(verts, indices[i]);
    const pj = indexedVertex(verts, indices[j]);
    const pi1 = indexedVertex(verts, indices[next(i, n)]);
    const pin1 = indexedVertex(verts, indices[prev(i, n)]);

    // If P[i] is a convex vertex [ i+1 left or on (i-1,i) ].
    if (leftOn(pin1, pi, pi1)) return left(pi, pj, pin1) and left(pj, pi, pi1);
    // Assume (i-1,i,i+1) not collinear.
    // else P[i] is reflex.
    return !(leftOn(pi, pj, pi1) and leftOn(pj, pi, pin1));
}

/// Whether (v_i, v_j) is a proper internal diagonal of the polygon.
fn diagonal(i: usize, j: usize, n: usize, verts: []const i32, indices: []const u32) bool {
    return inCone(i, j, n, verts, indices) and diagonalie(i, j, n, verts, indices);
}

fn diagonalieLoose(i: usize, j: usize, n: usize, verts: []const i32, indices: []const u32) bool {
    const d0 = indexedVertex(verts, indices[i]);
    const d1 = indexedVertex(verts, indices[j]);

    // For each edge (k,k+1) of P
    for (0..n) |k| {
        const k1 = next(k, n);
        // Skip edges incident to i or j
        if (!(k == i or k1 == i or k == j or k1 == j)) {
            const p0 = indexedVertex(verts, indices[k]);
            const p1 = indexedVertex(verts, indices[k1]);

            if (vequal(d0, p0) or vequal(d1, p0) or vequal(d0, p1) or vequal(d1, p1)) continue;

            if (intersectProp(d0, d1, p0, p1)) return false;
        }
    }
    return true;
}

fn inConeLoose(i: usize, j: usize, n: usize, verts: []const i32, indices: []const u32) bool {
    const pi = indexedVertex(verts, indices[i]);
    const pj = indexedVertex(verts, indices[j]);
    const pi1 = indexedVertex(verts, indices[next(i, n)]);
    const pin1 = indexedVertex(verts, indices[prev(i, n)]);

    // If P[i] is a convex vertex [ i+1 left or on (i-1,i) ].
    if (leftOn(pin1, pi, pi1)) return leftOn(pi, pj, pin1) and leftOn(pj, pi, pi1);
    // Assume (i-1,i,i+1) not collinear.
    // else P[i] is reflex.
    return !(leftOn(pi, pj, pi1) and leftOn(pj, pi, pin1));
}

fn diagonalLoose(i: usize, j: usize, n: usize, verts: []const i32, indices: []const u32) bool {
    return inConeLoose(i, j, n, verts, indices) and diagonalieLoose(i, j, n, verts, indices);
}

/// Ear-clips the polygon of the `n` vertices `indices` names into `tris`,
/// three indices per triangle, and returns the triangle count, negated if
/// the polygon could not be fully triangulated. Bit 31 of each index marks
/// a vertex whose ear can be cut. With fewer than 3 vertices it reads
/// indices up to the third, so `indices` must hold at least 3 entries,
/// zero past `n`.
fn triangulate(n_start: usize, verts: []const i32, indices: []u32, tris: []u32) i32 {
    var n = n_start;
    var ntris: i32 = 0;
    var dst: usize = 0;

    // The last bit of the index is used to indicate if the vertex can be removed.
    for (0..n) |i| {
        const i_1 = next(i, n);
        const i_2 = next(i_1, n);
        if (diagonal(i, i_2, n, verts, indices)) indices[i_1] |= 0x80000000;
    }

    while (n > 3) {
        var min_len: i32 = -1;
        var mini: ?usize = null;
        for (0..n) |i| {
            const i_1 = next(i, n);
            if (indices[i_1] & 0x80000000 != 0) {
                const p0 = indexedVertex(verts, indices[i]);
                const p2 = indexedVertex(verts, indices[next(i_1, n)]);

                const dx = p2[0] -% p0[0];
                const dy = p2[2] -% p0[2];
                const len = dx *% dx +% dy *% dy;

                if (min_len < 0 or len < min_len) {
                    min_len = len;
                    mini = i;
                }
            }
        }

        if (mini == null) {
            // We might get here because the contour has overlapping segments, like this:
            //
            //  A o-o=====o---o B
            //   /  |C   D|    \.
            //  o   o     o     o
            //  :   :     :     :
            // We'll try to recover by loosing up the inCone test a bit so that a diagonal
            // like A-B or C-D can be found and we can continue.
            min_len = -1;
            for (0..n) |i| {
                const i_1 = next(i, n);
                const i_2 = next(i_1, n);
                if (diagonalLoose(i, i_2, n, verts, indices)) {
                    // As upstream, the length is to the vertex after i_2.
                    const p0 = indexedVertex(verts, indices[i]);
                    const p2 = indexedVertex(verts, indices[next(i_2, n)]);
                    const dx = p2[0] -% p0[0];
                    const dy = p2[2] -% p0[2];
                    const len = dx *% dx +% dy *% dy;

                    if (min_len < 0 or len < min_len) {
                        min_len = len;
                        mini = i;
                    }
                }
            }
            if (mini == null) {
                // The contour is messed up. This sometimes happens
                // if the contour simplification is too aggressive.
                return -ntris;
            }
        }

        var i = mini.?;
        var i_1 = next(i, n);
        const i_2 = next(i_1, n);

        tris[dst + 0] = indices[i] & 0x0fffffff;
        tris[dst + 1] = indices[i_1] & 0x0fffffff;
        tris[dst + 2] = indices[i_2] & 0x0fffffff;
        dst += 3;
        ntris += 1;

        // Removes P[i_1] by copying P[i+1]...P[n-1] left one index.
        n -= 1;
        for (i_1..n) |k| indices[k] = indices[k + 1];

        if (i_1 >= n) i_1 = 0;
        i = prev(i_1, n);
        // Update diagonal flags.
        if (diagonal(prev(i, n), i_1, n, verts, indices)) {
            indices[i] |= 0x80000000;
        } else {
            indices[i] &= 0x0fffffff;
        }

        if (diagonal(i, next(i_1, n), n, verts, indices)) {
            indices[i_1] |= 0x80000000;
        } else {
            indices[i_1] &= 0x0fffffff;
        }
    }

    // Append the remaining triangle.
    tris[dst + 0] = indices[0] & 0x0fffffff;
    tris[dst + 1] = indices[1] & 0x0fffffff;
    tris[dst + 2] = indices[2] & 0x0fffffff;
    ntris += 1;

    return ntris;
}

fn countPolyVerts(p: []const u16, nvp: usize) usize {
    for (p[0..nvp], 0..) |v, i| {
        if (v == mesh_null_idx) return i;
    }
    return nvp;
}

fn uleft(a: *const [3]u16, b: *const [3]u16, c: *const [3]u16) bool {
    const abx = @as(i32, b[0]) - @as(i32, a[0]);
    const acz = @as(i32, c[2]) - @as(i32, a[2]);
    const acx = @as(i32, c[0]) - @as(i32, a[0]);
    const abz = @as(i32, b[2]) - @as(i32, a[2]);
    return (abx *% acz) -% (acx *% abz) < 0;
}

fn meshVertex(verts: []const u16, index: u16) *const [3]u16 {
    return verts[@as(usize, index) * 3 ..][0..3];
}

/// How good a merge of two polygons is, and the edge they share.
const PolyMerge = struct {
    /// The squared length of the shared edge, or -1 if the polygons cannot
    /// merge.
    value: i32,
    /// The shared edge's index in each polygon.
    ea: usize = 0,
    eb: usize = 0,
};

fn getPolyMergeValue(pa: []const u16, pb: []const u16, verts: []const u16, nvp: usize) PolyMerge {
    const na = countPolyVerts(pa, nvp);
    const nb = countPolyVerts(pb, nvp);

    // If the merged polygon would be too big, do not merge.
    if (na + nb > nvp + 2) return .{ .value = -1 };

    // Check if the polygons share an edge.
    var ea: ?usize = null;
    var eb: ?usize = null;

    for (0..na) |i| {
        // Each edge with its lower vertex first.
        const va0 = @min(pa[i], pa[(i + 1) % na]);
        const va1 = @max(pa[i], pa[(i + 1) % na]);
        for (0..nb) |j| {
            const vb0 = @min(pb[j], pb[(j + 1) % nb]);
            const vb1 = @max(pb[j], pb[(j + 1) % nb]);
            if (va0 == vb0 and va1 == vb1) {
                ea = i;
                eb = j;
                break;
            }
        }
    }

    // No common edge, cannot merge.
    const edge_a = ea orelse return .{ .value = -1 };
    const edge_b = eb orelse return .{ .value = -1 };

    // Check to see if the merged polygon would be convex.
    var va = pa[(edge_a + na - 1) % na];
    var vb = pa[edge_a];
    var vc = pb[(edge_b + 2) % nb];
    if (!uleft(meshVertex(verts, va), meshVertex(verts, vb), meshVertex(verts, vc))) {
        return .{ .value = -1 };
    }

    va = pb[(edge_b + nb - 1) % nb];
    vb = pb[edge_b];
    vc = pa[(edge_a + 2) % na];
    if (!uleft(meshVertex(verts, va), meshVertex(verts, vb), meshVertex(verts, vc))) {
        return .{ .value = -1 };
    }

    va = pa[edge_a];
    vb = pa[(edge_a + 1) % na];

    const dx = @as(i32, verts[@as(usize, va) * 3 + 0]) - @as(i32, verts[@as(usize, vb) * 3 + 0]);
    const dy = @as(i32, verts[@as(usize, va) * 3 + 2]) - @as(i32, verts[@as(usize, vb) * 3 + 2]);

    return .{ .value = dx *% dx +% dy *% dy, .ea = edge_a, .eb = edge_b };
}

/// Replaces `pa` with the merge of `pa` and `pb` across their shared edges
/// `ea` and `eb`, using `tmp` as scratch.
fn mergePolyVerts(pa: []u16, pb: []const u16, ea: usize, eb: usize, tmp: []u16, nvp: usize) void {
    const na = countPolyVerts(pa, nvp);
    const nb = countPolyVerts(pb, nvp);

    // Merge polygons.
    @memset(tmp[0..nvp], 0xffff);
    var n: usize = 0;
    // Add pa
    for (0..na - 1) |i| {
        tmp[n] = pa[(ea + 1 + i) % na];
        n += 1;
    }
    // Add pb
    for (0..nb - 1) |i| {
        tmp[n] = pb[(eb + 1 + i) % nb];
        n += 1;
    }

    @memcpy(pa[0..nvp], tmp[0..nvp]);
}

fn pushFront(v: i32, arr: []i32, an: *usize) void {
    an.* += 1;
    var i = an.* - 1;
    while (i > 0) : (i -= 1) arr[i] = arr[i - 1];
    arr[0] = v;
}

fn pushBack(v: i32, arr: []i32, an: *usize) void {
    arr[an.*] = v;
    an.* += 1;
}

/// Merges the polygons in `polys` (`nvp` entries each, the first `npolys`
/// in use) while a merge keeps them convex, the longest shared edge first,
/// and returns the new count. `tmp` is scratch for `nvp` entries. When
/// `pregs` is given, each polygon's region follows it, and a merge of two
/// regions becomes `multiple_regs`; `pareas` then follows too.
fn mergePolygons(
    polys: []u16,
    npolys_start: usize,
    verts: []const u16,
    tmp: []u16,
    nvp: usize,
    pregs: ?[]u16,
    pareas: ?[]u8,
) usize {
    var npolys = npolys_start;
    while (true) {
        // Find best polygons to merge.
        var best_merge_val: i32 = 0;
        var best_pa: usize = 0;
        var best_pb: usize = 0;
        var best_ea: usize = 0;
        var best_eb: usize = 0;

        for (0..npolys - 1) |j| {
            const pj = polys[j * nvp ..][0..nvp];
            for (j + 1..npolys) |k| {
                const pk = polys[k * nvp ..][0..nvp];
                const merge = getPolyMergeValue(pj, pk, verts, nvp);
                if (merge.value > best_merge_val) {
                    best_merge_val = merge.value;
                    best_pa = j;
                    best_pb = k;
                    best_ea = merge.ea;
                    best_eb = merge.eb;
                }
            }
        }

        if (best_merge_val <= 0) {
            // Could not merge any polygons, stop.
            return npolys;
        }

        // Found best, merge.
        const pa = polys[best_pa * nvp ..][0..nvp];
        const pb = polys[best_pb * nvp ..][0..nvp];
        mergePolyVerts(pa, pb, best_ea, best_eb, tmp, nvp);
        if (pregs) |regs| {
            if (regs[best_pa] != regs[best_pb]) regs[best_pa] = recast.multiple_regs;
        }
        const last = npolys - 1;
        if (best_pb != last) @memcpy(pb, polys[last * nvp ..][0..nvp]);
        if (pregs) |regs| regs[best_pb] = regs[last];
        if (pareas) |areas| areas[best_pb] = areas[last];
        npolys -= 1;
    }
}

fn canRemoveVertex(
    ctx: Context,
    gpa: Allocator,
    mesh: *const PolyMesh,
    rem: u16,
) Allocator.Error!bool {
    const nvp: usize = @intCast(mesh.nvp);
    const npolys: usize = @intCast(mesh.npolys);

    // Count number of polygons to remove.
    var num_touched_verts: i32 = 0;
    var num_remaining_edges: i32 = 0;
    for (0..npolys) |i| {
        const p = mesh.polys[i * nvp * 2 ..];
        const nv = countPolyVerts(p, nvp);
        var num_removed: i32 = 0;
        var num_verts: i32 = 0;
        for (p[0..nv]) |v| {
            if (v == rem) {
                num_touched_verts += 1;
                num_removed += 1;
            }
            num_verts += 1;
        }
        if (num_removed != 0) {
            num_remaining_edges += num_verts - (num_removed + 1);
        }
    }

    // There would be too few edges remaining to create a polygon.
    // This can happen for example when a tip of a triangle is marked
    // as deletion, but there are no other polys that share the vertex.
    // In this case, the vertex should not be removed.
    if (num_remaining_edges <= 2) return false;

    // Find edges which share the removed vertex.
    const max_edges = num_touched_verts * 2;
    var nedges: usize = 0;
    const edges = gpa.alloc(i32, @intCast(max_edges * 3)) catch |err| {
        ctx.log(.warning, "canRemoveVertex: Out of memory 'edges' ({d}).", .{max_edges * 3});
        return err;
    };
    defer gpa.free(edges);

    for (0..npolys) |i| {
        const p = mesh.polys[i * nvp * 2 ..];
        const nv = countPolyVerts(p, nvp);

        // Collect edges which touches the removed vertex.
        for (0..nv) |j| {
            const k = if (j == 0) nv - 1 else j - 1;
            if (p[j] == rem or p[k] == rem) {
                // Arrange edge so that a=rem.
                var a: i32 = p[j];
                var b: i32 = p[k];
                if (b == rem) std.mem.swap(i32, &a, &b);

                // Check if the edge exists
                var exists = false;
                for (0..nedges) |m| {
                    const e = edges[m * 3 ..][0..3];
                    if (e[1] == b) {
                        // Exists, increment vertex share count.
                        e[2] += 1;
                        exists = true;
                    }
                }
                // Add new edge.
                if (!exists) {
                    const e = edges[nedges * 3 ..][0..3];
                    e[0] = a;
                    e[1] = b;
                    e[2] = 1;
                    nedges += 1;
                }
            }
        }
    }

    // There should be no more than 2 open edges.
    // This catches the case that two non-adjacent polygons
    // share the removed vertex. In that case, do not remove the vertex.
    var num_open_edges: i32 = 0;
    for (0..nedges) |i| {
        if (edges[i * 3 + 2] < 2) num_open_edges += 1;
    }
    if (num_open_edges > 2) return false;

    return true;
}

fn removeVertex(
    ctx: Context,
    gpa: Allocator,
    mesh: *PolyMesh,
    rem: u16,
    max_tris: i32,
) BuildPolyMeshError!void {
    const nvp: usize = @intCast(mesh.nvp);

    // Count number of polygons to remove.
    var num_removed_verts: i32 = 0;
    for (0..@intCast(mesh.npolys)) |i| {
        const p = mesh.polys[i * nvp * 2 ..];
        const nv = countPolyVerts(p, nvp);
        for (p[0..nv]) |v| {
            if (v == rem) num_removed_verts += 1;
        }
    }

    var nedges: usize = 0;
    const edges_len = num_removed_verts * mesh.nvp * 4;
    const edges = gpa.alloc(i32, @intCast(edges_len)) catch |err| {
        ctx.log(.warning, "removeVertex: Out of memory 'edges' ({d}).", .{edges_len});
        return err;
    };
    defer gpa.free(edges);

    const hole_len = num_removed_verts * mesh.nvp;
    var nhole: usize = 0;
    const hole = gpa.alloc(i32, @intCast(hole_len)) catch |err| {
        ctx.log(.warning, "removeVertex: Out of memory 'hole' ({d}).", .{hole_len});
        return err;
    };
    defer gpa.free(hole);

    var nhreg: usize = 0;
    const hreg = gpa.alloc(i32, @intCast(hole_len)) catch |err| {
        ctx.log(.warning, "removeVertex: Out of memory 'hreg' ({d}).", .{hole_len});
        return err;
    };
    defer gpa.free(hreg);

    var nharea: usize = 0;
    const harea = gpa.alloc(i32, @intCast(hole_len)) catch |err| {
        ctx.log(.warning, "removeVertex: Out of memory 'harea' ({d}).", .{hole_len});
        return err;
    };
    defer gpa.free(harea);

    var i: usize = 0;
    while (i < @as(usize, @intCast(mesh.npolys))) {
        const p = mesh.polys[i * nvp * 2 ..][0 .. nvp * 2];
        const nv = countPolyVerts(p, nvp);
        var has_rem = false;
        for (p[0..nv]) |v| {
            if (v == rem) has_rem = true;
        }
        if (!has_rem) {
            i += 1;
            continue;
        }
        // Collect edges which does not touch the removed vertex.
        for (0..nv) |j| {
            const k = if (j == 0) nv - 1 else j - 1;
            if (p[j] != rem and p[k] != rem) {
                const e = edges[nedges * 4 ..][0..4];
                e[0] = p[k];
                e[1] = p[j];
                e[2] = mesh.regs[i];
                e[3] = mesh.areas[i];
                nedges += 1;
            }
        }
        // Remove the polygon. The last polygon's entries stay behind it,
        // as upstream leaves them.
        const last: usize = @intCast(mesh.npolys - 1);
        if (i != last) @memcpy(p[0..nvp], mesh.polys[last * nvp * 2 ..][0..nvp]);
        @memset(p[nvp..], 0xffff);
        mesh.regs[i] = mesh.regs[last];
        mesh.areas[i] = mesh.areas[last];
        mesh.npolys -= 1;
        // Look at the polygon now at `i`.
    }

    // Remove vertex.
    var vi: usize = rem;
    while (vi + 1 < @as(usize, @intCast(mesh.nverts))) : (vi += 1) {
        mesh.verts[vi * 3 + 0] = mesh.verts[(vi + 1) * 3 + 0];
        mesh.verts[vi * 3 + 1] = mesh.verts[(vi + 1) * 3 + 1];
        mesh.verts[vi * 3 + 2] = mesh.verts[(vi + 1) * 3 + 2];
    }
    mesh.nverts -= 1;

    // Adjust indices to match the removed vertex layout.
    for (0..@intCast(mesh.npolys)) |pi| {
        const p = mesh.polys[pi * nvp * 2 ..];
        const nv = countPolyVerts(p, nvp);
        for (p[0..nv]) |*v| {
            if (v.* > rem) v.* -= 1;
        }
    }
    for (0..nedges) |ei| {
        if (edges[ei * 4 + 0] > rem) edges[ei * 4 + 0] -= 1;
        if (edges[ei * 4 + 1] > rem) edges[ei * 4 + 1] -= 1;
    }

    if (nedges == 0) return;

    // Start with one vertex, keep appending connected
    // segments to the start and end of the hole.
    pushBack(edges[0], hole, &nhole);
    pushBack(edges[2], hreg, &nhreg);
    pushBack(edges[3], harea, &nharea);

    while (nedges != 0) {
        var match = false;

        var ei: usize = 0;
        while (ei < nedges) {
            const ea = edges[ei * 4 + 0];
            const eb = edges[ei * 4 + 1];
            const r = edges[ei * 4 + 2];
            const a = edges[ei * 4 + 3];
            var add = false;
            if (hole[0] == eb) {
                // The segment matches the beginning of the hole boundary.
                pushFront(ea, hole, &nhole);
                pushFront(r, hreg, &nhreg);
                pushFront(a, harea, &nharea);
                add = true;
            } else if (hole[nhole - 1] == ea) {
                // The segment matches the end of the hole boundary.
                pushBack(eb, hole, &nhole);
                pushBack(r, hreg, &nhreg);
                pushBack(a, harea, &nharea);
                add = true;
            }
            if (add) {
                // The edge segment was added, remove it, and look at the
                // edge moved into its place.
                edges[ei * 4 + 0] = edges[(nedges - 1) * 4 + 0];
                edges[ei * 4 + 1] = edges[(nedges - 1) * 4 + 1];
                edges[ei * 4 + 2] = edges[(nedges - 1) * 4 + 2];
                edges[ei * 4 + 3] = edges[(nedges - 1) * 4 + 3];
                nedges -= 1;
                match = true;
            } else {
                ei += 1;
            }
        }

        if (!match) break;
    }

    const tris = gpa.alloc(u32, nhole * 3) catch |err| {
        ctx.log(.warning, "removeVertex: Out of memory 'tris' ({d}).", .{nhole * 3});
        return err;
    };
    defer gpa.free(tris);

    const tverts = gpa.alloc(i32, nhole * 4) catch |err| {
        ctx.log(.warning, "removeVertex: Out of memory 'tverts' ({d}).", .{nhole * 4});
        return err;
    };
    defer gpa.free(tverts);

    // A hole of fewer than 3 vertices makes `triangulate` read indices up
    // to the third; they are zero, as the oracle's zero-filled memory past
    // upstream's buffer is.
    const thole = gpa.alloc(u32, @max(nhole, 3)) catch |err| {
        ctx.log(.warning, "removeVertex: Out of memory 'thole' ({d}).", .{nhole});
        return err;
    };
    defer gpa.free(thole);
    @memset(thole[nhole..], 0);

    // Generate temp vertex array for triangulation.
    for (0..nhole) |hi| {
        const pi: usize = @intCast(hole[hi]);
        tverts[hi * 4 + 0] = mesh.verts[pi * 3 + 0];
        tverts[hi * 4 + 1] = mesh.verts[pi * 3 + 1];
        tverts[hi * 4 + 2] = mesh.verts[pi * 3 + 2];
        tverts[hi * 4 + 3] = 0;
        thole[hi] = @intCast(hi);
    }

    // Triangulate the hole.
    var ntris = triangulate(nhole, tverts, thole, tris);
    if (ntris < 0) {
        ntris = -ntris;
        ctx.log(.warning, "removeVertex: triangulate() returned bad results.", .{});
    }
    const tri_count: usize = @intCast(ntris);

    // Merge the hole triangles back to polygons.
    const polys = gpa.alloc(u16, (tri_count + 1) * nvp) catch |err| {
        ctx.log(.err, "removeVertex: Out of memory 'polys' ({d}).", .{(ntris + 1) * mesh.nvp});
        return err;
    };
    defer gpa.free(polys);
    const pregs = gpa.alloc(u16, tri_count) catch |err| {
        ctx.log(.err, "removeVertex: Out of memory 'pregs' ({d}).", .{ntris});
        return err;
    };
    defer gpa.free(pregs);
    const pareas = gpa.alloc(u8, tri_count) catch |err| {
        ctx.log(.err, "removeVertex: Out of memory 'pareas' ({d}).", .{ntris});
        return err;
    };
    defer gpa.free(pareas);

    const tmp_poly = polys[tri_count * nvp ..];

    // Build initial polygons.
    var npolys: usize = 0;
    @memset(polys[0 .. tri_count * nvp], 0xffff);
    for (0..tri_count) |j| {
        const t = tris[j * 3 ..][0..3];
        if (t[0] != t[1] and t[0] != t[2] and t[1] != t[2]) {
            polys[npolys * nvp + 0] = @intCast(hole[t[0]]);
            polys[npolys * nvp + 1] = @intCast(hole[t[1]]);
            polys[npolys * nvp + 2] = @intCast(hole[t[2]]);

            // If this polygon covers multiple region types then
            // mark it as such
            if (hreg[t[0]] != hreg[t[1]] or hreg[t[1]] != hreg[t[2]]) {
                pregs[npolys] = recast.multiple_regs;
            } else {
                pregs[npolys] = @intCast(hreg[t[0]]);
            }

            pareas[npolys] = @intCast(harea[t[0]]);
            npolys += 1;
        }
    }
    if (npolys == 0) return;

    // Merge polygons.
    if (nvp > 3) npolys = mergePolygons(polys, npolys, mesh.verts, tmp_poly, nvp, pregs, pareas);

    // Store polygons.
    for (0..npolys) |pi| {
        if (mesh.npolys >= max_tris) break;
        const p = mesh.polys[@as(usize, @intCast(mesh.npolys)) * nvp * 2 ..][0 .. nvp * 2];
        @memset(p, 0xffff);
        for (0..nvp) |j| p[j] = polys[pi * nvp + j];
        mesh.regs[@intCast(mesh.npolys)] = pregs[pi];
        mesh.areas[@intCast(mesh.npolys)] = pareas[pi];
        mesh.npolys += 1;
        if (mesh.npolys > max_tris) {
            ctx.log(
                .err,
                "removeVertex: Too many polygons {d} (max:{d}).",
                .{ mesh.npolys, max_tris },
            );
            return error.TooManyPolygons;
        }
    }
}

/// C's conversion of an int to unsigned short: the low 16 bits.
fn lowU16(x: i32) u16 {
    return @truncate(@as(u32, @bitCast(x)));
}

/// C's `(unsigned short)x` of a float as x86-64 computes it: through a
/// 32-bit int conversion, keeping the low 16 bits.
fn floatToU16(x: f32) u16 {
    return lowU16(recast.truncateToInt(x));
}

/// Builds convex polygons of at most `nvp` vertices from the contours. Each
/// contour is triangulated and its triangles merged while they stay convex,
/// the longest shared edge first; vertices the contours marked with
/// `border_vertex` are then removed where the polygons around them can be
/// rebuilt without them, and each polygon is linked to its neighbors. With
/// a border size, an edge on the tile's border gets 0x8000 plus the
/// border's direction as its neighbor. `flags` holds `npolys` entries,
/// `regs` and `areas` `maxpolys`.
pub fn buildPolyMesh(
    ctx: Context,
    gpa: Allocator,
    cset: *const ContourSet,
    nvp: i32,
) BuildPolyMeshError!PolyMesh {
    ctx.startTimer(.build_polymesh);
    defer ctx.stopTimer(.build_polymesh);

    var mesh: PolyMesh = .empty;
    mesh.bmin = cset.bmin;
    mesh.bmax = cset.bmax;
    mesh.cs = cset.cs;
    mesh.ch = cset.ch;
    mesh.border_size = cset.border_size;
    mesh.max_edge_error = cset.max_error;

    const conts = cset.conts[0..@intCast(cset.nconts)];

    var max_vertices: i32 = 0;
    var max_tris: i32 = 0;
    var max_verts_per_cont: i32 = 0;
    for (conts) |*cont| {
        // Skip null contours.
        if (cont.nverts < 3) continue;
        max_vertices += cont.nverts;
        max_tris += cont.nverts - 2;
        max_verts_per_cont = @max(max_verts_per_cont, cont.nverts);
    }

    if (max_vertices >= 0xfffe) {
        ctx.log(.err, "rcBuildPolyMesh: Too many vertices {d}.", .{max_vertices});
        return error.TooManyVertices;
    }

    const vertex_count: usize = @intCast(max_vertices);
    const tri_count: usize = @intCast(max_tris);
    const cont_vert_count: usize = @intCast(max_verts_per_cont);
    const verts_per_poly: usize = @intCast(nvp);

    const vflags = gpa.alloc(u8, vertex_count) catch |err| {
        ctx.log(.err, "rcBuildPolyMesh: Out of memory 'vflags' ({d}).", .{max_vertices});
        return err;
    };
    defer gpa.free(vflags);
    @memset(vflags, 0);

    mesh.verts = gpa.alloc(u16, vertex_count * 3) catch |err| {
        ctx.log(.err, "rcBuildPolyMesh: Out of memory 'mesh.verts' ({d}).", .{max_vertices});
        return err;
    };
    errdefer gpa.free(mesh.verts);
    mesh.polys = gpa.alloc(u16, tri_count * verts_per_poly * 2) catch |err| {
        ctx.log(
            .err,
            "rcBuildPolyMesh: Out of memory 'mesh.polys' ({d}).",
            .{max_tris * nvp * 2},
        );
        return err;
    };
    errdefer gpa.free(mesh.polys);
    mesh.regs = gpa.alloc(u16, tri_count) catch |err| {
        ctx.log(.err, "rcBuildPolyMesh: Out of memory 'mesh.regs' ({d}).", .{max_tris});
        return err;
    };
    errdefer gpa.free(mesh.regs);
    mesh.areas = gpa.alloc(u8, tri_count) catch |err| {
        ctx.log(.err, "rcBuildPolyMesh: Out of memory 'mesh.areas' ({d}).", .{max_tris});
        return err;
    };
    errdefer gpa.free(mesh.areas);

    mesh.nverts = 0;
    mesh.npolys = 0;
    mesh.nvp = nvp;
    mesh.maxpolys = max_tris;

    @memset(mesh.verts, 0);
    @memset(mesh.polys, 0xffff);
    @memset(mesh.regs, 0);
    @memset(mesh.areas, 0);

    const next_vert = gpa.alloc(i32, vertex_count) catch |err| {
        ctx.log(.err, "rcBuildPolyMesh: Out of memory 'nextVert' ({d}).", .{max_vertices});
        return err;
    };
    defer gpa.free(next_vert);
    @memset(next_vert, 0);

    const first_vert = gpa.alloc(i32, vertex_bucket_count) catch |err| {
        ctx.log(
            .err,
            "rcBuildPolyMesh: Out of memory 'firstVert' ({d}).",
            .{vertex_bucket_count},
        );
        return err;
    };
    defer gpa.free(first_vert);
    @memset(first_vert, -1);

    const indices = gpa.alloc(u32, cont_vert_count) catch |err| {
        ctx.log(.err, "rcBuildPolyMesh: Out of memory 'indices' ({d}).", .{max_verts_per_cont});
        return err;
    };
    defer gpa.free(indices);
    const tris = gpa.alloc(u32, cont_vert_count * 3) catch |err| {
        ctx.log(
            .err,
            "rcBuildPolyMesh: Out of memory 'tris' ({d}).",
            .{max_verts_per_cont * 3},
        );
        return err;
    };
    defer gpa.free(tris);
    const polys = gpa.alloc(u16, (cont_vert_count + 1) * verts_per_poly) catch |err| {
        ctx.log(
            .err,
            "rcBuildPolyMesh: Out of memory 'polys' ({d}).",
            .{max_verts_per_cont * nvp},
        );
        return err;
    };
    defer gpa.free(polys);
    const tmp_poly = polys[cont_vert_count * verts_per_poly ..];

    for (conts, 0..) |*cont, i| {
        // Skip null contours.
        if (cont.nverts < 3) continue;
        const cont_nverts: usize = @intCast(cont.nverts);

        // Triangulate contour
        for (0..cont_nverts) |j| indices[j] = @intCast(j);

        var ntris = triangulate(cont_nverts, cont.verts, indices, tris);
        if (ntris <= 0) {
            // Bad triangulation, should not happen.
            ctx.log(.warning, "rcBuildPolyMesh: Bad triangulation Contour {d}.", .{i});
            ntris = -ntris;
        }

        // Add and merge vertices.
        for (0..cont_nverts) |j| {
            const v = cont.verts[j * 4 ..][0..4];
            indices[j] = addVertex(
                lowU16(v[0]),
                lowU16(v[1]),
                lowU16(v[2]),
                mesh.verts,
                first_vert,
                next_vert,
                &mesh.nverts,
            );
            if ((v[3] & recast.border_vertex) != 0) {
                // This vertex should be removed.
                vflags[indices[j]] = 1;
            }
        }

        // Build initial polygons.
        var npolys: usize = 0;
        @memset(polys[0 .. cont_vert_count * verts_per_poly], 0xffff);
        for (0..@intCast(ntris)) |j| {
            const t = tris[j * 3 ..][0..3];
            if (t[0] != t[1] and t[0] != t[2] and t[1] != t[2]) {
                polys[npolys * verts_per_poly + 0] = @intCast(indices[t[0]]);
                polys[npolys * verts_per_poly + 1] = @intCast(indices[t[1]]);
                polys[npolys * verts_per_poly + 2] = @intCast(indices[t[2]]);
                npolys += 1;
            }
        }
        if (npolys == 0) continue;

        // Merge polygons.
        if (nvp > 3) {
            npolys = mergePolygons(polys, npolys, mesh.verts, tmp_poly, verts_per_poly, null, null);
        }

        // Store polygons.
        for (0..npolys) |j| {
            // A contour has at most nverts - 2 polygons, so this is never
            // reached; upstream would write past the arrays first.
            if (mesh.npolys >= max_tris) {
                ctx.log(
                    .err,
                    "rcBuildPolyMesh: Too many polygons {d} (max:{d}).",
                    .{ mesh.npolys + 1, max_tris },
                );
                return error.TooManyPolygons;
            }
            const index: usize = @intCast(mesh.npolys);
            const p = mesh.polys[index * verts_per_poly * 2 ..][0..verts_per_poly];
            @memcpy(p, polys[j * verts_per_poly ..][0..verts_per_poly]);
            mesh.regs[index] = cont.reg;
            mesh.areas[index] = cont.area;
            mesh.npolys += 1;
        }
    }

    // Remove edge vertices.
    var i: i32 = 0;
    while (i < mesh.nverts) : (i += 1) {
        if (vflags[@intCast(i)] != 0) {
            if (!try canRemoveVertex(ctx, gpa, &mesh, @intCast(i))) continue;
            removeVertex(ctx, gpa, &mesh, @intCast(i), max_tris) catch |err| {
                // Failed to remove vertex
                ctx.log(.err, "rcBuildPolyMesh: Failed to remove edge vertex {d}.", .{i});
                return err;
            };
            // Remove vertex
            // Note: mesh.nverts is already decremented inside removeVertex()!
            // Fixup vertex flags
            var j = i;
            while (j < mesh.nverts) : (j += 1) vflags[@intCast(j)] = vflags[@intCast(j + 1)];
            i -= 1;
        }
    }

    // Calculate adjacency.
    buildMeshAdjacency(gpa, mesh.polys, mesh.npolys, mesh.nverts, nvp) catch |err| {
        ctx.log(.err, "rcBuildPolyMesh: Adjacency failed.", .{});
        return err;
    };

    // Find portal edges
    if (mesh.border_size > 0) {
        const w = cset.width;
        const h = cset.height;
        for (0..@intCast(mesh.npolys)) |pi| {
            const p = mesh.polys[pi * 2 * verts_per_poly ..][0 .. 2 * verts_per_poly];
            for (0..verts_per_poly) |j| {
                if (p[j] == mesh_null_idx) break;
                // Skip connected edges.
                if (p[verts_per_poly + j] != mesh_null_idx) continue;
                var nj = j + 1;
                if (nj >= verts_per_poly or p[nj] == mesh_null_idx) nj = 0;
                const va = meshVertex(mesh.verts, p[j]);
                const vb = meshVertex(mesh.verts, p[nj]);

                if (va[0] == 0 and vb[0] == 0) {
                    p[verts_per_poly + j] = 0x8000 | 0;
                } else if (va[2] == h and vb[2] == h) {
                    p[verts_per_poly + j] = 0x8000 | 1;
                } else if (va[0] == w and vb[0] == w) {
                    p[verts_per_poly + j] = 0x8000 | 2;
                } else if (va[2] == 0 and vb[2] == 0) {
                    p[verts_per_poly + j] = 0x8000 | 3;
                }
            }
        }
    }

    // Just allocate the mesh flags array. The user is resposible to fill it.
    mesh.flags = gpa.alloc(u16, @intCast(mesh.npolys)) catch |err| {
        ctx.log(.err, "rcBuildPolyMesh: Out of memory 'mesh.flags' ({d}).", .{mesh.npolys});
        return err;
    };
    @memset(mesh.flags, 0);

    if (mesh.nverts > 0xffff) {
        ctx.log(
            .err,
            "rcBuildPolyMesh: The resulting mesh has too many vertices {d} (max {d}). " ++
                "Data can be corrupted.",
            .{ mesh.nverts, 0xffff },
        );
    }
    if (mesh.npolys > 0xffff) {
        ctx.log(
            .err,
            "rcBuildPolyMesh: The resulting mesh has too many polygons {d} (max {d}). " ++
                "Data can be corrupted.",
            .{ mesh.npolys, 0xffff },
        );
    }

    return mesh;
}

/// Merges poly meshes, such as a build's tiles, into one mesh: vertices at
/// the same cell whose heights are within 2 become one, and a portal edge
/// keeps its portal mark only on the merged mesh's outer border. All
/// meshes must have the same `nvp`. As upstream, the result's `maxpolys`,
/// `border_size` and `max_edge_error` are 0. No meshes give an empty mesh.
pub fn mergePolyMeshes(
    ctx: Context,
    gpa: Allocator,
    meshes: []const *const PolyMesh,
) MergePolyMeshesError!PolyMesh {
    if (meshes.len == 0) return .empty;

    ctx.startTimer(.merge_polymesh);
    defer ctx.stopTimer(.merge_polymesh);

    var mesh: PolyMesh = .empty;
    mesh.nvp = meshes[0].nvp;
    mesh.cs = meshes[0].cs;
    mesh.ch = meshes[0].ch;
    mesh.bmin = meshes[0].bmin;
    mesh.bmax = meshes[0].bmax;

    var max_verts: i32 = 0;
    var max_polys: i32 = 0;
    var max_verts_per_mesh: i32 = 0;
    for (meshes) |pmesh| {
        recast.vmin(&mesh.bmin, &pmesh.bmin);
        recast.vmax(&mesh.bmax, &pmesh.bmax);
        max_verts_per_mesh = @max(max_verts_per_mesh, pmesh.nverts);
        max_verts += pmesh.nverts;
        max_polys += pmesh.npolys;
    }

    const nvp: usize = @intCast(mesh.nvp);
    const vertex_count: usize = @intCast(max_verts);
    const poly_count: usize = @intCast(max_polys);

    mesh.nverts = 0;
    mesh.verts = gpa.alloc(u16, vertex_count * 3) catch |err| {
        ctx.log(.err, "rcMergePolyMeshes: Out of memory 'mesh.verts' ({d}).", .{max_verts * 3});
        return err;
    };
    errdefer gpa.free(mesh.verts);
    // Upstream leaves the unused vertices unwritten; they are zero, as the
    // oracle's zero-filled memory is.
    @memset(mesh.verts, 0);

    mesh.npolys = 0;
    mesh.polys = gpa.alloc(u16, poly_count * 2 * nvp) catch |err| {
        ctx.log(
            .err,
            "rcMergePolyMeshes: Out of memory 'mesh.polys' ({d}).",
            .{max_polys * 2 * mesh.nvp},
        );
        return err;
    };
    errdefer gpa.free(mesh.polys);
    @memset(mesh.polys, 0xffff);

    mesh.regs = gpa.alloc(u16, poly_count) catch |err| {
        ctx.log(.err, "rcMergePolyMeshes: Out of memory 'mesh.regs' ({d}).", .{max_polys});
        return err;
    };
    errdefer gpa.free(mesh.regs);
    @memset(mesh.regs, 0);

    mesh.areas = gpa.alloc(u8, poly_count) catch |err| {
        ctx.log(.err, "rcMergePolyMeshes: Out of memory 'mesh.areas' ({d}).", .{max_polys});
        return err;
    };
    errdefer gpa.free(mesh.areas);
    @memset(mesh.areas, 0);

    mesh.flags = gpa.alloc(u16, poly_count) catch |err| {
        ctx.log(.err, "rcMergePolyMeshes: Out of memory 'mesh.flags' ({d}).", .{max_polys});
        return err;
    };
    errdefer gpa.free(mesh.flags);
    @memset(mesh.flags, 0);

    const next_vert = gpa.alloc(i32, vertex_count) catch |err| {
        ctx.log(.err, "rcMergePolyMeshes: Out of memory 'nextVert' ({d}).", .{max_verts});
        return err;
    };
    defer gpa.free(next_vert);
    @memset(next_vert, 0);

    const first_vert = gpa.alloc(i32, vertex_bucket_count) catch |err| {
        ctx.log(
            .err,
            "rcMergePolyMeshes: Out of memory 'firstVert' ({d}).",
            .{vertex_bucket_count},
        );
        return err;
    };
    defer gpa.free(first_vert);
    @memset(first_vert, -1);

    const vremap = gpa.alloc(u16, @intCast(max_verts_per_mesh)) catch |err| {
        ctx.log(
            .err,
            "rcMergePolyMeshes: Out of memory 'vremap' ({d}).",
            .{max_verts_per_mesh},
        );
        return err;
    };
    defer gpa.free(vremap);
    @memset(vremap, 0);

    for (meshes) |pmesh| {
        const ox = floatToU16(@floor((pmesh.bmin[0] - mesh.bmin[0]) / mesh.cs + 0.5));
        const oz = floatToU16(@floor((pmesh.bmin[2] - mesh.bmin[2]) / mesh.cs + 0.5));

        const is_min_x = ox == 0;
        const is_min_z = oz == 0;
        const is_max_x = floatToU16(@floor((mesh.bmax[0] - pmesh.bmax[0]) / mesh.cs + 0.5)) == 0;
        const is_max_z = floatToU16(@floor((mesh.bmax[2] - pmesh.bmax[2]) / mesh.cs + 0.5)) == 0;
        const is_on_border = is_min_x or is_min_z or is_max_x or is_max_z;

        for (0..@intCast(pmesh.nverts)) |j| {
            const v = pmesh.verts[j * 3 ..][0..3];
            // The offset coordinates wrap at 16 bits, as upstream's do.
            vremap[j] = addVertex(
                v[0] +% ox,
                v[1],
                v[2] +% oz,
                mesh.verts,
                first_vert,
                next_vert,
                &mesh.nverts,
            );
        }

        for (0..@intCast(pmesh.npolys)) |j| {
            const index: usize = @intCast(mesh.npolys);
            const tgt = mesh.polys[index * 2 * nvp ..][0 .. 2 * nvp];
            // As upstream, the source polygons are read with the first
            // mesh's `nvp`.
            const src = pmesh.polys[j * 2 * nvp ..][0 .. 2 * nvp];
            mesh.regs[index] = pmesh.regs[j];
            mesh.areas[index] = pmesh.areas[j];
            mesh.flags[index] = pmesh.flags[j];
            mesh.npolys += 1;
            for (0..nvp) |k| {
                if (src[k] == mesh_null_idx) break;
                tgt[k] = vremap[src[k]];
            }

            if (is_on_border) {
                for (nvp..nvp * 2) |k| {
                    if ((src[k] & 0x8000) != 0 and src[k] != 0xffff) {
                        const dir = src[k] & 0xf;
                        switch (dir) {
                            // Portal x-
                            0 => if (is_min_x) {
                                tgt[k] = src[k];
                            },
                            // Portal z+
                            1 => if (is_max_z) {
                                tgt[k] = src[k];
                            },
                            // Portal x+
                            2 => if (is_max_x) {
                                tgt[k] = src[k];
                            },
                            // Portal z-
                            3 => if (is_min_z) {
                                tgt[k] = src[k];
                            },
                            else => {},
                        }
                    }
                }
            }
        }
    }

    // Calculate adjacency.
    buildMeshAdjacency(gpa, mesh.polys, mesh.npolys, mesh.nverts, mesh.nvp) catch |err| {
        ctx.log(.err, "rcMergePolyMeshes: Adjacency failed.", .{});
        return err;
    };

    if (mesh.nverts > 0xffff) {
        ctx.log(
            .err,
            "rcMergePolyMeshes: The resulting mesh has too many vertices {d} (max {d}). " ++
                "Data can be corrupted.",
            .{ mesh.nverts, 0xffff },
        );
    }
    if (mesh.npolys > 0xffff) {
        ctx.log(
            .err,
            "rcMergePolyMeshes: The resulting mesh has too many polygons {d} (max {d}). " ++
                "Data can be corrupted.",
            .{ mesh.npolys, 0xffff },
        );
    }

    return mesh;
}

/// A copy of `src` holding exactly its vertices and polygons: `maxpolys` is
/// `npolys`.
pub fn copyPolyMesh(ctx: Context, gpa: Allocator, src: *const PolyMesh) Allocator.Error!PolyMesh {
    var dst: PolyMesh = .empty;
    dst.nverts = src.nverts;
    dst.npolys = src.npolys;
    dst.maxpolys = src.npolys;
    dst.nvp = src.nvp;
    dst.bmin = src.bmin;
    dst.bmax = src.bmax;
    dst.cs = src.cs;
    dst.ch = src.ch;
    dst.border_size = src.border_size;
    dst.max_edge_error = src.max_edge_error;

    const nverts: usize = @intCast(src.nverts);
    const npolys: usize = @intCast(src.npolys);
    const nvp: usize = @intCast(src.nvp);

    dst.verts = gpa.alloc(u16, nverts * 3) catch |err| {
        ctx.log(.err, "rcCopyPolyMesh: Out of memory 'dst.verts' ({d}).", .{src.nverts * 3});
        return err;
    };
    errdefer gpa.free(dst.verts);
    @memcpy(dst.verts, src.verts[0 .. nverts * 3]);

    dst.polys = gpa.alloc(u16, npolys * 2 * nvp) catch |err| {
        ctx.log(
            .err,
            "rcCopyPolyMesh: Out of memory 'dst.polys' ({d}).",
            .{src.npolys * 2 * src.nvp},
        );
        return err;
    };
    errdefer gpa.free(dst.polys);
    @memcpy(dst.polys, src.polys[0 .. npolys * 2 * nvp]);

    dst.regs = gpa.alloc(u16, npolys) catch |err| {
        ctx.log(.err, "rcCopyPolyMesh: Out of memory 'dst.regs' ({d}).", .{src.npolys});
        return err;
    };
    errdefer gpa.free(dst.regs);
    @memcpy(dst.regs, src.regs[0..npolys]);

    dst.areas = gpa.alloc(u8, npolys) catch |err| {
        ctx.log(.err, "rcCopyPolyMesh: Out of memory 'dst.areas' ({d}).", .{src.npolys});
        return err;
    };
    errdefer gpa.free(dst.areas);
    @memcpy(dst.areas, src.areas[0..npolys]);

    dst.flags = gpa.alloc(u16, npolys) catch |err| {
        ctx.log(.err, "rcCopyPolyMesh: Out of memory 'dst.flags' ({d}).", .{src.npolys});
        return err;
    };
    @memcpy(dst.flags, src.flags[0..npolys]);

    return dst;
}

// --------------------------------------------------------
// Tests
// --------------------------------------------------------

const testing = std.testing;

test "vertex hashes wrap at 32 bits" {
    // 0x8da6b343 + 0xcb1ab31f overflows; its low 12 bits are 0x662.
    try testing.expectEqual(0x662, computeVertexHash(1, 0, 1));
}

test "a hole of two vertices triangulates to a degenerate triangle" {
    const verts = [_]i32{ 0, 0, 0, 0, 5, 0, 5, 0 };
    var indices = [_]u32{ 0, 1, 0 };
    var tris: [3]u32 = undefined;
    try testing.expectEqual(1, triangulate(2, &verts, &indices, &tris));
    try testing.expectEqualSlices(u32, &.{ 0, 1, 0 }, &tris);
}

test "a square contour becomes one quad" {
    var verts = [_]i32{ 0, 0, 0, 0, 0, 0, 10, 0, 10, 0, 10, 0, 10, 0, 0, 0 };
    var conts = [_]recast.Contour{.{
        .verts = &verts,
        .nverts = 4,
        .rverts = &.{},
        .nrverts = 0,
        .reg = 1,
        .area = recast.walkable_area,
    }};
    const cset: ContourSet = .{
        .conts = &conts,
        .nconts = 1,
        .bmin = .{ 0, 0, 0 },
        .bmax = .{ 3, 1, 3 },
        .cs = 0.3,
        .ch = 0.2,
        .width = 10,
        .height = 10,
        .border_size = 0,
        .max_error = 1.3,
    };
    var pmesh = try buildPolyMesh(.none, testing.allocator, &cset, 6);
    defer pmesh.deinit(testing.allocator);

    try testing.expectEqual(4, pmesh.nverts);
    try testing.expectEqual(1, pmesh.npolys);
    try testing.expectEqual(2, pmesh.maxpolys);
    try testing.expectEqualSlices(u16, &.{ 0, 0, 0, 0, 0, 10, 10, 0, 10, 10, 0, 0 }, pmesh.verts);
    const unused: [8]u16 = @splat(mesh_null_idx);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3 }, pmesh.polys[0..4]);
    try testing.expectEqualSlices(u16, &unused, pmesh.polys[4..12]);
    try testing.expectEqual(1, pmesh.regs[0]);
    try testing.expectEqual(recast.walkable_area, pmesh.areas[0]);
    try testing.expectEqual(1, pmesh.flags.len);

    var copy = try copyPolyMesh(.none, testing.allocator, &pmesh);
    defer copy.deinit(testing.allocator);
    try testing.expectEqual(1, copy.maxpolys);
    try testing.expectEqualSlices(u16, pmesh.polys[0..12], copy.polys);
}
