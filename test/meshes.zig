//! Inputs for the differential tests and the benchmark: RecastDemo's OBJ
//! meshes, read as RecastDemo reads them, a generated terrain with slopes,
//! cliffs, holes, pillars, stairs and a bridge over walkable ground, and
//! rolling ground as Loomwork's terrain makes it.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Triangles over shared vertices: x, y and z per vertex, three vertex
/// indices per triangle.
pub const Mesh = struct {
    verts: []f32,
    tris: []i32,

    pub fn deinit(mesh: *Mesh, gpa: Allocator) void {
        gpa.free(mesh.verts);
        gpa.free(mesh.tris);
        mesh.* = undefined;
    }

    pub fn vertCount(mesh: *const Mesh) i32 {
        return @intCast(mesh.verts.len / 3);
    }

    pub fn triCount(mesh: *const Mesh) i32 {
        return @intCast(mesh.tris.len / 3);
    }
};

/// Reads an OBJ file as RecastDemo's `Mesh::readFromObj` does: `v` rows are
/// vertices, `f` rows faces split into a fan of triangles from their first
/// vertex, with negative indices counted from the end; triangles with an
/// index out of range are skipped.
pub fn loadObj(gpa: Allocator, text: []const u8) !Mesh {
    var verts: std.ArrayList(f32) = .empty;
    errdefer verts.deinit(gpa);
    var tris: std.ArrayList(i32) = .empty;
    errdefer tris.deinit(gpa);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var row_buffer: [511]u8 = undefined;
        const row = readRow(line, &row_buffer);
        if (row.len == 0 or row[0] == '#') continue;
        if (row[0] == 'v' and (row.len < 2 or (row[1] != 'n' and row[1] != 't'))) {
            var fields = std.mem.tokenizeAny(u8, row[1..], " \t");
            var v: [3]f32 = .{ 0, 0, 0 };
            for (&v) |*c| c.* = try std.fmt.parseFloat(f32, fields.next() orelse break);
            try verts.appendSlice(gpa, &v);
        }
        if (row[0] == 'f') {
            const vert_count: i32 = @intCast(verts.items.len / 3);
            var face: [32]i32 = undefined;
            var n: usize = 0;
            var fields = std.mem.tokenizeAny(u8, row[1..], " \t");
            while (fields.next()) |field| {
                const end = std.mem.findScalar(u8, field, '/') orelse field.len;
                const index = atoi(field[0..end]);
                face[n] = if (index < 0) index + vert_count else index - 1;
                n += 1;
                if (n >= face.len) break;
            }
            var i: usize = 2;
            while (i < n) : (i += 1) {
                const tri = [3]i32{ face[0], face[i - 1], face[i] };
                const valid = for (tri) |t| {
                    if (t < 0 or t >= vert_count) break false;
                } else true;
                if (valid) try tris.appendSlice(gpa, &tri);
            }
        }
    }
    const owned_verts = try verts.toOwnedSlice(gpa);
    errdefer gpa.free(owned_verts);
    return .{ .verts = owned_verts, .tris = try tris.toOwnedSlice(gpa) };
}

/// The row as RecastDemo's `readRow` gives it: leading whitespace skipped,
/// carriage returns and backslashes dropped, at most 511 characters.
fn readRow(line: []const u8, buffer: *[511]u8) []const u8 {
    var start: usize = 0;
    while (start < line.len) : (start += 1) {
        switch (line[start]) {
            '\\', '\r', '\t', ' ' => {},
            else => break,
        }
    }
    var n: usize = 0;
    for (line[start..]) |c| {
        if (c == '\\' or c == '\r') continue;
        buffer[n] = c;
        n += 1;
        if (n >= buffer.len) break;
    }
    return buffer[0..n];
}

/// C's `atoi`: an optional sign and the digits after it, 0 for none.
fn atoi(text: []const u8) i32 {
    var i: usize = 0;
    var negative = false;
    if (i < text.len and (text[i] == '-' or text[i] == '+')) {
        negative = text[i] == '-';
        i += 1;
    }
    var value: i32 = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        value = value *% 10 +% (text[i] - '0');
    }
    return if (negative) -%value else value;
}

/// A builder of meshes from quads and boxes.
pub const Builder = struct {
    gpa: Allocator,
    verts: std.ArrayList(f32) = .empty,
    tris: std.ArrayList(i32) = .empty,

    pub fn vertex(b: *Builder, x: f32, y: f32, z: f32) !i32 {
        const index: i32 = @intCast(b.verts.items.len / 3);
        try b.verts.appendSlice(b.gpa, &.{ x, y, z });
        return index;
    }

    pub fn tri(b: *Builder, v0: i32, v1: i32, v2: i32) !void {
        try b.tris.appendSlice(b.gpa, &.{ v0, v1, v2 });
    }

    /// A quad whose normal points up when its corners go around
    /// (x0, z0), (x0, z1), (x1, z1), (x1, z0), as RecastDemo's meshes wind.
    pub fn quad(b: *Builder, c: [4][3]f32) !void {
        var v: [4]i32 = undefined;
        for (&v, c) |*index, p| index.* = try b.vertex(p[0], p[1], p[2]);
        try b.tri(v[0], v[1], v[3]);
        try b.tri(v[3], v[1], v[2]);
    }

    /// A closed axis-aligned box, its top walkable.
    pub fn box(b: *Builder, min: [3]f32, max: [3]f32) !void {
        const x0 = min[0];
        const y0 = min[1];
        const z0 = min[2];
        const x1 = max[0];
        const y1 = max[1];
        const z1 = max[2];
        try b.quad(.{ .{ x0, y1, z0 }, .{ x0, y1, z1 }, .{ x1, y1, z1 }, .{ x1, y1, z0 } });
        try b.quad(.{ .{ x0, y0, z0 }, .{ x1, y0, z0 }, .{ x1, y0, z1 }, .{ x0, y0, z1 } });
        try b.quad(.{ .{ x0, y0, z0 }, .{ x0, y1, z0 }, .{ x1, y1, z0 }, .{ x1, y0, z0 } });
        try b.quad(.{ .{ x0, y0, z1 }, .{ x1, y0, z1 }, .{ x1, y1, z1 }, .{ x0, y1, z1 } });
        try b.quad(.{ .{ x0, y0, z0 }, .{ x0, y0, z1 }, .{ x0, y1, z1 }, .{ x0, y1, z0 } });
        try b.quad(.{ .{ x1, y0, z0 }, .{ x1, y1, z0 }, .{ x1, y1, z1 }, .{ x1, y0, z1 } });
    }

    pub fn finish(b: *Builder) !Mesh {
        const verts = try b.verts.toOwnedSlice(b.gpa);
        errdefer b.gpa.free(verts);
        return .{ .verts = verts, .tris = try b.tris.toOwnedSlice(b.gpa) };
    }

    pub fn deinit(b: *Builder) void {
        b.verts.deinit(b.gpa);
        b.tris.deinit(b.gpa);
    }
};

/// A value in [0, 1) from a grid point, the same on every machine.
fn hash(x: i32, z: i32, seed: u32) f32 {
    var h: u32 = @bitCast(x *% 374761393 +% z *% 668265263);
    h +%= seed *% 2246822519;
    h = (h ^ (h >> 13)) *% 1274126177;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h >> 8)) / 16777216.0;
}

/// The terrain's height at grid point (x, z), in world units.
fn terrainHeight(x: i32, z: i32, size: i32, seed: u32) f32 {
    const fx: f32 = @floatFromInt(x);
    const fz: f32 = @floatFromInt(z);
    var y = 4.0 * @sin(fx * 0.05) * @cos(fz * 0.07) + 1.5 * @sin(fx * 0.23 + fz * 0.11);
    y += 0.4 * hash(x, z, seed);
    // A cliff along a third of the way across, and a plateau beyond it.
    if (x > @divTrunc(size, 3) and z < @divTrunc(size, 2)) y += 3.0;
    // A steep bowl.
    const dx = fx - @as(f32, @floatFromInt(@divTrunc(size * 3, 4)));
    const dz = fz - @as(f32, @floatFromInt(@divTrunc(size * 3, 4)));
    const r2 = dx * dx + dz * dz;
    const bowl: f32 = @floatFromInt(@divTrunc(size, 8));
    if (r2 < bowl * bowl) y -= (bowl * bowl - r2) * 0.05;
    return y;
}

/// Rolling ground of `size` by `size` unit quads, as Loomwork's terrain
/// generates it: three octaves of integer value noise, 32 m hills of 4 m,
/// 12 m bumps of 1.2 m and 5 m ripples of 0.3 m, in steps of 8 mm.
pub fn vale(gpa: Allocator, size: i32) !Mesh {
    var b: Builder = .{ .gpa = gpa };
    errdefer b.deinit();

    const row: usize = @intCast(size + 1);
    const grid = try gpa.alloc(i32, row * row);
    defer gpa.free(grid);
    const base_mm = -10_000;
    const step_mm = 8;
    var z: i32 = 0;
    while (z <= size) : (z += 1) {
        var x: i32 = 0;
        while (x <= size) : (x += 1) {
            var mm: i64 = 0;
            mm += valeNoise(x, z, 32, 4_000, 1);
            mm += valeNoise(x, z, 12, 1_200, 2);
            mm += valeNoise(x, z, 5, 300, 3);
            const raw = @divFloor(mm - base_mm, step_mm);
            const y: f32 = @floatFromInt(base_mm + raw * step_mm);
            grid[@as(usize, @intCast(z)) * row + @as(usize, @intCast(x))] =
                try b.vertex(@floatFromInt(x), y / 1000.0, @floatFromInt(z));
        }
    }
    z = 0;
    while (z < size) : (z += 1) {
        var x: i32 = 0;
        while (x < size) : (x += 1) {
            const ux: usize = @intCast(x);
            const uz: usize = @intCast(z);
            const v00 = grid[uz * row + ux];
            const v10 = grid[uz * row + ux + 1];
            const v01 = grid[(uz + 1) * row + ux];
            const v11 = grid[(uz + 1) * row + ux + 1];
            try b.tri(v00, v01, v10);
            try b.tri(v10, v01, v11);
        }
    }
    return b.finish();
}

/// Value noise: hashed heights on a `spacing` lattice in [-amplitude,
/// amplitude], blended by an integer smoothstep.
fn valeNoise(gx: i32, gz: i32, spacing: i32, amplitude: i64, seed: u64) i64 {
    const lx = @divFloor(gx, spacing);
    const lz = @divFloor(gz, spacing);
    const one: i64 = 1 << 12;
    const tx = smoothstep(@divFloor(@as(i64, gx - lx * spacing) * one, spacing), one);
    const tz = smoothstep(@divFloor(@as(i64, gz - lz * spacing) * one, spacing), one);
    const a = lattice(lx, lz, amplitude, seed);
    const b = lattice(lx + 1, lz, amplitude, seed);
    const c = lattice(lx, lz + 1, amplitude, seed);
    const d = lattice(lx + 1, lz + 1, amplitude, seed);
    const top = a * one + (b - a) * tx;
    const bottom = c * one + (d - c) * tx;
    return @divFloor(top * one + (bottom - top) * tz, one * one);
}

fn smoothstep(t: i64, one: i64) i64 {
    return @divFloor(t * t * (3 * one - 2 * t), one * one);
}

fn lattice(x: i32, z: i32, amplitude: i64, seed: u64) i64 {
    const key = [2]i32{ x, z };
    const h = std.hash.Wyhash.hash(seed, std.mem.asBytes(&key));
    return @as(i64, @intCast(h % @as(u64, @intCast(2 * amplitude + 1)))) - amplitude;
}

/// A heightmap of `size` by `size` unit quads with holes, then pillars,
/// stairs, a stack of floors and a bridge on it. `seed` changes the noise.
pub fn terrain(gpa: Allocator, size: i32, seed: u32) !Mesh {
    var b: Builder = .{ .gpa = gpa };
    errdefer b.deinit();

    const row: usize = @intCast(size + 1);
    const grid = try gpa.alloc(i32, row * row);
    defer gpa.free(grid);
    var z: i32 = 0;
    while (z <= size) : (z += 1) {
        var x: i32 = 0;
        while (x <= size) : (x += 1) {
            const y = terrainHeight(x, z, size, seed);
            grid[@as(usize, @intCast(z)) * row + @as(usize, @intCast(x))] =
                try b.vertex(@floatFromInt(x), y, @floatFromInt(z));
        }
    }
    z = 0;
    while (z < size) : (z += 1) {
        var x: i32 = 0;
        while (x < size) : (x += 1) {
            // Holes: a few random quads, and a square well.
            if (hash(x, z, seed +% 1) < 0.01) continue;
            const well = @divTrunc(size, 5);
            if (x >= well and x < well + 4 and z >= well and z < well + 4) continue;
            const ux: usize = @intCast(x);
            const uz: usize = @intCast(z);
            const v00 = grid[uz * row + ux];
            const v10 = grid[uz * row + ux + 1];
            const v01 = grid[(uz + 1) * row + ux];
            const v11 = grid[(uz + 1) * row + ux + 1];
            try b.tri(v00, v01, v10);
            try b.tri(v10, v01, v11);
        }
    }

    const s: f32 = @floatFromInt(size);
    // Pillars.
    var i: i32 = 0;
    while (i < 12) : (i += 1) {
        const px = 4.0 + hash(i, 0, seed +% 2) * (s - 8.0);
        const pz = 4.0 + hash(i, 1, seed +% 2) * (s - 8.0);
        const base = terrainHeight(@intFromFloat(px), @intFromFloat(pz), size, seed) - 2.0;
        try b.box(.{ px, base, pz }, .{ px + 1.3, base + 6.0, pz + 0.9 });
    }
    // Stairs: steps of 0.3 m, climbable, then of 1.2 m, not.
    const stairs_x = s * 0.55;
    const stairs_z = s * 0.6;
    const stairs_y = terrainHeight(@intFromFloat(stairs_x), @intFromFloat(stairs_z), size, seed);
    i = 0;
    while (i < 10) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const rise: f32 = if (i < 6) 0.3 else 1.2;
        const top = stairs_y + 0.3 * @min(fi, 6.0) + rise * @max(fi - 5.0, 0.0) + rise;
        try b.box(
            .{ stairs_x + fi * 0.8, stairs_y - 1.0, stairs_z },
            .{ stairs_x + fi * 0.8 + 0.8, top, stairs_z + 3.0 },
        );
    }
    // A stack of thin floors, for columns with many spans.
    const stack_x = s * 0.15;
    const stack_z = s * 0.8;
    const stack_y = terrainHeight(@intFromFloat(stack_x), @intFromFloat(stack_z), size, seed);
    i = 0;
    while (i < 8) : (i += 1) {
        const fi: f32 = @floatFromInt(i);
        const y = stack_y + 2.5 + fi * 2.3;
        try b.box(.{ stack_x, y, stack_z }, .{ stack_x + 6.0, y + 0.2, stack_z + 6.0 });
    }
    // A bridge over walkable ground, with ramps up to it.
    const bridge_x = s * 0.4;
    const bridge_z0 = s * 0.1;
    const bridge_z1 = s * 0.9;
    const bridge_y = 9.0;
    try b.box(.{ bridge_x, bridge_y - 0.4, bridge_z0 }, .{ bridge_x + 3.0, bridge_y, bridge_z1 });
    for ([2]f32{ bridge_z0, bridge_z1 }, [2]f32{ -1.0, 1.0 }) |end, dir| {
        const ground = terrainHeight(@intFromFloat(bridge_x), @intFromFloat(end), size, seed);
        const foot = end + dir * 14.0;
        try b.quad(.{
            .{ bridge_x, if (dir < 0) ground else bridge_y, if (dir < 0) foot else end },
            .{ bridge_x, if (dir < 0) bridge_y else ground, if (dir < 0) end else foot },
            .{ bridge_x + 3.0, if (dir < 0) bridge_y else ground, if (dir < 0) end else foot },
            .{ bridge_x + 3.0, if (dir < 0) ground else bridge_y, if (dir < 0) foot else end },
        });
    }
    return b.finish();
}

/// Test meshes by name: RecastDemo's three, and the terrain.
pub const Source = enum { dungeon, nav_test, undulating, terrain };
