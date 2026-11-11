# zig-recast

Recast, the navigation mesh builder, in pure Zig.

zig-recast turns triangle meshes into navigation meshes: it voxelizes the
level, finds where an agent of a given size can stand and walk, splits that
into regions and turns them into convex polygons, with a detail mesh that
follows the ground's height. It is a translation of Recast from
[recastnavigation](https://github.com/recastnavigation/recastnavigation)
1.6.0, and tests show it produces **the same bytes as the original**, step
by step. It has no dependencies beyond Zig's standard library, and every
function takes the allocator it uses.

This port was written by Claude (Anthropic's AI model) for Farhollow Games.
How the code was verified can be found
[below](#how-the-tests-prove-equivalence).

Requires Zig 0.17.0.

## Use

Add the package:

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-recast
```

and import its module in `build.zig`:

```zig
const recast = b.dependency("recast", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("recast", recast.module("recast"));
```

Build a navmesh's polygons from a triangle mesh, as RecastDemo does:

```zig
const std = @import("std");
const recast = @import("recast");

pub fn build(gpa: std.mem.Allocator, verts: []const f32, tris: []const i32) !recast.PolyMesh {
    const ctx: recast.Context = .none;
    var cfg: recast.Config = .{
        .cs = 0.3, .ch = 0.2, .walkable_slope_angle = 45,
        .walkable_height = 10, .walkable_climb = 4, .walkable_radius = 2,
        .max_edge_len = 40, .max_simplification_error = 1.3,
        .min_region_area = 64, .merge_region_area = 400, .max_verts_per_poly = 6,
    };
    recast.calcBounds(verts, &cfg.bmin, &cfg.bmax);
    const grid = recast.calcGridSize(&cfg.bmin, &cfg.bmax, cfg.cs);

    var hf = try recast.Heightfield.init(gpa, grid.width, grid.height, &cfg.bmin, &cfg.bmax, cfg.cs, cfg.ch);
    defer hf.deinit(gpa);
    const areas = try gpa.alloc(u8, tris.len / 3);
    defer gpa.free(areas);
    @memset(areas, recast.null_area);
    recast.markWalkableTriangles(ctx, cfg.walkable_slope_angle, verts, tris, areas);
    try recast.rasterizeTriangles(ctx, gpa, verts, i32, tris, areas, &hf, cfg.walkable_climb);
    recast.filterLowHangingWalkableObstacles(ctx, cfg.walkable_climb, &hf);
    recast.filterLedgeSpans(ctx, cfg.walkable_height, cfg.walkable_climb, &hf);
    recast.filterWalkableLowHeightSpans(ctx, cfg.walkable_height, &hf);

    var chf = try recast.buildCompactHeightfield(ctx, gpa, cfg.walkable_height, cfg.walkable_climb, &hf);
    defer chf.deinit(gpa);
    try recast.erodeWalkableArea(ctx, gpa, cfg.walkable_radius, &chf);
    try recast.buildDistanceField(ctx, gpa, &chf);
    try recast.buildRegions(ctx, gpa, &chf, 0, cfg.min_region_area, cfg.merge_region_area);

    var cset = try recast.buildContours(ctx, gpa, &chf, cfg.max_simplification_error, cfg.max_edge_len, .default);
    defer cset.deinit(gpa);
    return recast.buildPolyMesh(ctx, gpa, &cset, cfg.max_verts_per_poly);
}
```

The API follows the original's, function for function (`rcBuildContours`
is `recast.buildContours`), with Zig's conventions:

- every build step takes a `recast.Context` (logging and timers, or
  `.none`) and an allocator;
- a step that fills a new structure returns it, and its `deinit` frees it;
- a step that fails returns an error after logging the original's message:
  `error.OutOfMemory`, or one named after the failure;
- structures keep the original's fields in snake_case, with slices over
  their allocations and the original's counts beside them.

[`doc/parity.md`](doc/parity.md) maps every function and type of the
original to its counterpart.

Each step is a pure function of its inputs, so tiles of a tiled navmesh
can be built on any number of threads; the bytes are the same however the
work is split.

## How the tests prove equivalence

`zig build test` fetches the original at the pinned commit, builds it from
source (test-only code, never part of the package) and runs it and the port
on the same inputs: RecastDemo's three test meshes and a generated terrain
with cliffs, holes, pillars, stairs, stacked floors and a bridge, under
RecastDemo's settings and many others, every partition type, contour flag
and vertex limit, crafted and random triangles and spans, area marks inside,
across and outside the field, and Loomwork's tiled build, merged, on 1 to
8 threads. After every step, the two must agree on every byte of every
structure, every log message and every timer call.

Both sides are built with fused multiply-add off, so float steps round as
written. Where the original's behaviour is undefined (reading memory it
never wrote, out-of-range float conversions), the port does what the
original does on x86-64 with zeroed memory, the same on every machine; see
[`doc/parity.md`](doc/parity.md).

## Licence and credits

zlib licence ([`LICENSE`](LICENSE)), the original's.

Translated from Recast in
[recastnavigation](https://github.com/recastnavigation/recastnavigation)
1.6.0, by Mikko Mononen and the recastnavigation contributors. This is an
altered version: the code is rewritten in Zig with its own interface.

Made by Farhollow Games for the Loomwork Engine.
