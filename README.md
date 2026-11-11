# zig-recast

Tracks recastnavigation 1.6.0 (Recast) · Zig 0.17 · [status](STATUS.md)

## What it is

A Zig port of Recast, the navigation mesh builder of
[recastnavigation](#licence-and-references). It turns triangle meshes into
navigation meshes: it voxelizes the level, finds where an agent of a given
size can stand and walk, splits that into regions and turns them into
convex polygons, with a detail mesh that follows the ground's height. It is
pure Zig, with no dependencies beyond the standard library.

This port is not affiliated with or reviewed by the recastnavigation
authors. Its code was written with AI assistance (Claude, Anthropic's
model) for Farhollow Games, and has not yet been reviewed by a person.

## Features

- Every step of Recast's build: the heightfield and its rasterization
  (int, 16-bit and unindexed triangles, or one at a time), the three span
  filters, the compact heightfield, erosion, the median area filter, area
  marks (box, convex polygon, cylinder) and polygon offsets, the distance
  field, watershed, monotone and layer regions, contours, polygon meshes
  and detail meshes.
- Tiled builds: polygon and detail meshes merged from tiles, polygon mesh
  copies, and heightfield layers for a tile cache.
- The original's logging and timers, through a sink of the caller's own or
  `.none`.
- Every function that allocates takes a `std.mem.Allocator`, and the port
  keeps no global state, so tiles can be built on several threads at once;
  the tests build them on up to 8.

## Install

```sh
zig fetch --save git+https://github.com/farhollowgames/zig-recast#v0.1.0
```

`v0.1.0` is the latest release. Then, in `build.zig`:

```zig
const recast = b.dependency("recast", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("recast", recast.module("recast"));
```

## Use

Build a navmesh's polygons from a triangle mesh, as RecastDemo does:

```zig
const std = @import("std");
const recast = @import("recast");

/// Builds the polygons of a navmesh from a triangle mesh with RecastDemo's
/// default settings. `buildPolyMeshDetail` then adds the detail mesh.
pub fn buildPolygons(
    gpa: std.mem.Allocator,
    verts: []const f32,
    tris: []const i32,
) !recast.PolyMesh {
    const ctx: recast.Context = .none;
    var cfg: recast.Config = .{
        .cs = 0.3,
        .ch = 0.2,
        .walkable_slope_angle = 45,
        .walkable_height = 10,
        .walkable_climb = 4,
        .walkable_radius = 2,
        .max_edge_len = 40,
        .max_simplification_error = 1.3,
        .min_region_area = 64,
        .merge_region_area = 400,
        .max_verts_per_poly = 6,
    };
    recast.calcBounds(verts, &cfg.bmin, &cfg.bmax);
    const grid = recast.calcGridSize(&cfg.bmin, &cfg.bmax, cfg.cs);

    var hf: recast.Heightfield = try .init(
        gpa,
        grid.width,
        grid.height,
        &cfg.bmin,
        &cfg.bmax,
        cfg.cs,
        cfg.ch,
    );
    defer hf.deinit(gpa);
    const areas = try gpa.alloc(u8, tris.len / 3);
    defer gpa.free(areas);
    @memset(areas, recast.null_area);
    recast.markWalkableTriangles(ctx, cfg.walkable_slope_angle, verts, tris, areas);
    try recast.rasterizeTriangles(ctx, gpa, verts, i32, tris, areas, &hf, cfg.walkable_climb);
    recast.filterLowHangingWalkableObstacles(ctx, cfg.walkable_climb, &hf);
    recast.filterLedgeSpans(ctx, cfg.walkable_height, cfg.walkable_climb, &hf);
    recast.filterWalkableLowHeightSpans(ctx, cfg.walkable_height, &hf);

    var chf = try recast.buildCompactHeightfield(
        ctx,
        gpa,
        cfg.walkable_height,
        cfg.walkable_climb,
        &hf,
    );
    defer chf.deinit(gpa);
    try recast.erodeWalkableArea(ctx, gpa, cfg.walkable_radius, &chf);
    try recast.buildDistanceField(ctx, gpa, &chf);
    try recast.buildRegions(ctx, gpa, &chf, 0, cfg.min_region_area, cfg.merge_region_area);

    var cset = try recast.buildContours(
        ctx,
        gpa,
        &chf,
        cfg.max_simplification_error,
        cfg.max_edge_len,
        .default,
    );
    defer cset.deinit(gpa);
    return recast.buildPolyMesh(ctx, gpa, &cset, cfg.max_verts_per_poly);
}
```

The API follows the original's, function for function (`rcBuildContours`
is `recast.buildContours`). [`doc/parity.md`](doc/parity.md) maps every
function and type of the original to its counterpart, and the doc comments
in [`src/`](src) describe each one.

## Differences from the original

[`doc/parity.md`](doc/parity.md#where-the-port-differs) gives the reasons.

*Additions*
- `recast.cosf`, the port's copy of glibc's single-precision cosine, which
  the slope functions use.
- `cosf` is computed in Zig with fused multiply-adds, so it gives the same
  bits on every machine, where the original's depends on the C library.
- `recast.truncateToInt`, C's `(int)` of a float, with x86-64's result
  where C leaves it undefined.
- `recast.vertex_cells_max`, the limit of the vertex range that
  rasterization accepts.

*Changes to expect*
- A step that fails logs the original's message and returns an error,
  `error.OutOfMemory` or one named after the failure, where the original
  returns `false`.
- Every function that allocates takes a `std.mem.Allocator`, in place of
  the `rcAlloc` hooks.
- A step that fills a structure returns it, and its `deinit` frees it, in
  place of `rcAlloc*` and `rcFree*`.
- Fields are in snake_case, arrays are slices with the original's counts
  beside them, and there are no default arguments.
- Logging and timers go to a `Context.Sink`, a pointer and a table of
  functions, in place of `rcContext`'s virtual methods.
- A triangle with an x or z that is not finite, or 2^22 cells or more from
  the origin, gives `error.NonFiniteVertex`, where the original writes past
  a buffer on its stack.
- A polygon of more than 127 vertices gives
  `error.TooManyPolygonVertices` in `buildPolyMeshDetail`, where the
  original writes past its hull buffer.
- A detail sample distance of 0 or less triangulates the polygon's own
  vertices, where the original never returns.
- A failed allocation fails the build, where the original carries on after
  some.
- A `max_edge_len` of 65536 or more splits no edge, where the original
  squares it in an int, which overflows.
- Float to int conversions out of range give x86-64's result on every
  machine.
- The slope thresholds use glibc's cosine on every platform.
- Sorting is stable, as glibc's `qsort` is.

## Not included

The allocator and assert hooks, `rcVector`, the branch hints, the helpers
Zig has built in, and DebugUtils (debug drawing and dumps);
[`STATUS.md`](STATUS.md#left-out) lists each left-out item and what takes
its place.

## Testing and benchmarks

81 tests. 56 run the original beside the port on the same inputs and
compare their results: the structures each step builds, byte for byte, and
every log message, timer call and returned value. The other 25 test the
port alone. The inputs are RecastDemo's meshes, generated terrains,
hand-made edge cases, upstream's own tests and seeded fuzzing.

Port time divided by original time, the lowest and the highest over seven
inputs from RecastDemo's meshes to a 1 km tiled terrain (below 1, the port
takes less time):

| feature | port ÷ original |
| --- | ---: |
| Whole build | 0.37 to 0.91 |
| Rasterization, int indices | 0.90 to 0.95 |
| Distance field | 1.09 to 1.31 |
| Watershed regions | 0.58 to 0.89 |
| Detail mesh | 0.09 to 0.83 |

AMD Ryzen 9 9950X3D, one core, Linux 7.3.3, Zig 0.17.0 ReleaseFast against
clang 22.1.8 `-O3`, at commit `0c37e46`, with a load average of 1.4 to 3.2
on 32 hardware threads; the median of three runs.

- [`doc/TESTING.md`](doc/TESTING.md): how the tests compare the port with
  the original, and what this repository's tests cover.
- [`doc/BENCHMARKS.md`](doc/BENCHMARKS.md): every feature's table, the
  flags on both sides, the biases and the command.

## Licence and references

zlib licence, the original's ([`LICENSE`](LICENSE)). zig-recast is an
altered version of Recast: the code is rewritten in Zig, with its own
interface. The original's licence and copyright notice are kept in
`LICENSE` as they are: "Copyright (c) 2009 Mikko Mononen memon@inside.org".
`src/cosf.zig` is translated from Arm's optimized-routines and is used
under the MIT licence; its text and Arm's copyright notice are in `LICENSE`
too.

- [recastnavigation](https://github.com/recastnavigation/recastnavigation),
  the original, by [Mikko Mononen](https://github.com/memononen) and the
  recastnavigation contributors.
- [recastnav.com](https://recastnav.com), its documentation.
- Eric Lengyel's
  [edge list for an arbitrary mesh](https://web.archive.org/web/20080704083314/http://www.terathon.com/code/edges.php),
  which the polygon mesh's adjacency is built from.
- [optimized-routines](https://github.com/ARM-software/optimized-routines),
  Arm's maths routines, which glibc's `cosf` and the port's are built from.

Made by Farhollow Games for the Loomwork Engine.
