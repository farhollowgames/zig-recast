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
on the same inputs. In the pipeline tests, after every step, the two must
agree on every byte of every structure, every log message and every timer
call; the tile tests compare the logs and each tile's meshes. The inputs
are:

- RecastDemo's three test meshes and a generated terrain with cliffs,
  holes, pillars, stairs, stacked floors and a bridge, under RecastDemo's
  settings and many others, with every partition type, contour flag and
  vertex limit, and Loomwork's tiled build, merged, on 1 to 8 threads;
- seeded fuzzing, at least 1,000 cases a test: whole builds of random
  scenes, spans added directly, every rasterization entry point, polygon
  offsets into short buffers, slopes, bounds, and the vector, scalar and
  connection helpers, with NaN, infinite and huge heights among the
  inputs; a failure prints its seed, and the port builds every eighth
  scene twice;
- hand-made edge cases: empty scenes, one triangle, one span, borders as
  wide as the field, tiles off the cell grid, the limit of every counter
  (region ids, mesh vertices, layer regions, layers, span heights, spans in
  a column) and degenerate triangles;
- upstream's own unit tests, run on both sides;
- on the port alone, every allocation of a whole build failed in turn:
  each step must return `OutOfMemory` and free all it made.

Both sides are built with fused multiply-add off, so float steps round as
written. Where the original's behaviour is undefined (reading memory it
never wrote, out-of-range float conversions), the port does what the
original does on x86-64 with zeroed memory, the same on every machine. A
triangle with an x or z that is not finite, or 2^22 cells or more from the
origin, where the original's clipping writes past its buffers, gives
`error.NonFiniteVertex`; see [`doc/parity.md`](doc/parity.md).
[`STATUS.md`](STATUS.md) lists every feature with its tests and its state.

## Performance

`zig build bench` times the port against the original on the same inputs,
one feature at a time, on one thread. Zig 0.17.0 builds both for the
native CPU (`znver5`), with frame pointers: the port in ReleaseFast, and
the original with its clang 22.1.8 at `-O3 -std=c++11 -fno-exceptions
-fno-rtti -fno-threadsafe-statics -ffp-contract=off -fno-fast-math
-fno-sanitize=undefined` and `NDEBUG`. Fused multiply-adds are off on both
sides, as the tests need for equal outputs.

These figures are from an AMD Ryzen 9 9950X3D (16 cores, the run pinned to
CPU 2, one of the eight with the stacked cache) on Linux 7.3.3 (CachyOS):

```sh
zig build bench -- --runs 7 --warmup 1 --cpu 2
```

Each time is the median of 7 runs after 1 warm-up. The spread is the
range of the runs, slowest less fastest, as a share of the median. The two
sides take turns tile by tile, the side that goes first changes every run,
and every result is kept alive, so the compiler cannot drop the work.

The figures were taken on a busy machine, with other builds running. The
benchmark ran twice, and each row is from the run where the two sides'
medians add up to less. Short, memory-bound features (the span count, the
span filters, creating the heightfield) move the most from run to run, so
theirs are the least certain figures.

The inputs are RecastDemo's three meshes and a 256 m generated terrain,
each built whole with RecastDemo's defaults, and that terrain and a
rolling ground (`vale`) of 256 m and of 1 km, built in 64 m tiles with
Loomwork's navmesh settings (125 mm cells, an agent 1.8 m tall and 0.35 m
wide).

### Summary

The port's median time divided by the original's, from the fastest to
the slowest of the inputs (below 1 is faster). Most features run on all
seven inputs; 16-bit indices fit only RecastDemo's meshes, and the merges
run on the tiled inputs.

| feature | port ÷ original |
| --- | ---: |
| Whole build | 0.35 to 0.91 |
| Heightfield | 0.97 to 1.02 |
| Walkable triangles | 0.90 to 1.04 |
| Rasterization, int indices | 0.89 to 0.95 |
| Low hanging obstacles filter | 0.67 to 0.87 |
| Ledge filter | 0.88 to 0.94 |
| Low height filter | 0.73 to 0.88 |
| Compact heightfield | 0.87 to 0.93 |
| Erosion | 0.96 to 0.99 |
| Distance field | 1.09 to 1.33 |
| Watershed regions | 0.53 to 0.72 |
| Contours | 0.88 to 1.06 |
| Polygon mesh | 0.86 to 0.99 |
| Detail mesh | 0.09 to 0.76 |
| Span count | 0.82 to 1.00 |
| Unwalkable triangles | 0.97 to 1.09 |
| Rasterization, unsigned short indices | 0.92 to 0.95 |
| Rasterization, unindexed | 0.89 to 0.94 |
| Rasterization, one triangle at a time | 0.89 to 0.94 |
| Adding spans, the rasterized field's again | 0.58 to 0.73 |
| Polygon mesh copy | 0.90 to 1.02 |
| Heightfield layers | 0.92 to 0.97 |
| Monotone regions | 0.38 to 0.84 |
| Layer regions | 0.92 to 1.01 |
| Median area filter | 1.01 to 1.05 |
| Box area | 0.80 to 0.97 |
| Convex area | 0.83 to 0.87 |
| Cylinder area | 0.81 to 0.92 |
| Polygon mesh merge, every tile | 1.02 to 1.06 |
| Detail mesh merge, every tile | 0.49 to 0.54 |
| Bounds | 0.27 to 0.29 |
| Grid size | 1.07 to 1.10 |
| Polygon offset, a hexagon | 0.76 to 0.77 |

The heightfield layers fail on both sides on the whole 256 m terrain, as
its regions overflow their 8-bit ids, so that row has six inputs.

### Where the port is faster

- **Detail mesh, 0.09 to 0.76 times.** Where the original measures each
  sample against each triangle in turn, the port measures a vector of
  samples at a time against a triangle (`@Vector`, as wide as the CPU's),
  with what depends only on the triangle worked out once. It finds a
  triangulation's edges in a table indexed by their two vertices, where the
  original searches every edge, and it works out once per span whether the
  span borders its region, where the original redoes that for every
  polygon whose patch covers the span. The more samples a polygon takes,
  the more this gains: on the rolling ground, whose polygons take up to
  119 detail vertices, the port is about nine times as fast.
- **Compact heightfield, 0.87 to 0.93 times.** The port builds a span's
  four connections in a register and stores the span once.
- **Loops that store to bytes.** Zig has no type-based aliasing, so through
  the heightfield's pointer each store to a distance, flag or area makes a
  loop load the field's slices again, as the original's stores to bytes do
  in C++. Erosion, contours and the box and cylinder marks read the field
  through local slices instead.

### Where the port is slower

- **Distance field, 1.09 to 1.33 times**, the larger the field the slower.
  Each of its four passes (marking the borders, the two sweeps and the
  blur) takes 20 to 30% longer in samples of the rolling ground's build,
  though their loops compile to nearly the original's instructions: the
  port keeps the four neighbours' cell indices on the stack, where the
  original addresses them from a row pointer.
- **Grid size, 1.07 to 1.10 times**, about 0.1 ns a call: the port checks
  the range before converting a float to an int, so that out-of-range
  values give x86-64's result on every machine, where the original's
  `(int)` is one instruction.
- **Contours on the rolling ground, 1.06 times**; 0.88 to 0.99 on the
  other inputs.
- **Unwalkable triangles on `dungeon.obj` and `nav_test.obj`, 1.07 and
  1.09 times**, of 58 and 4 µs; 0.97 to 1.01 on the others.

Every other feature is within 6% of the original on every input, or
faster; differences of a few percent are within the spread of the runs.

### Every feature

#### Whole build

Every step of a navmesh build, in Loomwork's order.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 8.08 ms, 1.3 M/s | 7.35 ms, 1.4 M/s | 0.91 | 1.2% / 1.9% |
| nav_test.obj | 1612 triangles | 10.70 ms, 150.6 k/s | 8.75 ms, 184.2 k/s | 0.82 | 0.3% / 2.2% |
| undulating.obj | 5202 triangles | 57.46 ms, 90.5 k/s | 22.45 ms, 231.7 k/s | 0.39 | 1.3% / 0.5% |
| terrain 256 m | 130.1 k triangles | 143.11 ms, 909.1 k/s | 101.21 ms, 1.3 M/s | 0.71 | 0.7% / 1.3% |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 553.73 ms, 246.2 k/s | 417.80 ms, 326.3 k/s | 0.75 | 0.6% / 0.2% |
| vale 256 m, 64 m tiles | 137.3 k triangles | 1057.77 ms, 129.8 k/s | 462.42 ms, 296.9 k/s | 0.44 | 0.7% / 4.1% |
| vale 1 km, 64 m tiles | 2.22 M triangles | 21964.36 ms, 101.2 k/s | 7787.28 ms, 285.3 k/s | 0.35 | 2.8% / 4.4% |

#### Heightfield

`rcCreateHeightfield` and `Heightfield.init`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 81.8 k cells | 4.5 µs, 18.15 G/s | 4.4 µs, 18.56 G/s | 0.98 | 4.7% / 6.1% |
| nav_test.obj | 78.7 k cells | 4.3 µs, 18.31 G/s | 4.2 µs, 18.88 G/s | 0.97 | 4.2% / 1.7% |
| undulating.obj | 109.2 k cells | 5.8 µs, 18.83 G/s | 5.7 µs, 19.30 G/s | 0.98 | 142.7% / 1.4% |
| terrain 256 m | 727.6 k cells | 52.3 µs, 13.90 G/s | 53.0 µs, 13.72 G/s | 1.01 | 48.3% / 78.0% |
| terrain 256 m, 64 m tiles | 4.39 M cells | 228.1 µs, 19.26 G/s | 230.8 µs, 19.04 G/s | 1.01 | 3.8% / 5.4% |
| vale 256 m, 64 m tiles | 4.39 M cells | 228.3 µs, 19.24 G/s | 233.8 µs, 18.79 G/s | 1.02 | 11.3% / 17.5% |
| vale 1 km, 64 m tiles | 70.29 M cells | 3.65 ms, 19.26 G/s | 3.67 ms, 19.15 G/s | 1.01 | 35.4% / 36.0% |

#### Walkable triangles

`rcMarkWalkableTriangles` and `markWalkableTriangles`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 54.7 µs, 185.4 M/s | 57.0 µs, 177.8 M/s | 1.04 | 4.9% / 1.1% |
| nav_test.obj | 1612 triangles | 3.9 µs, 412.6 M/s | 3.6 µs, 447.0 M/s | 0.92 | 6.4% / 10.3% |
| undulating.obj | 5202 triangles | 8.7 µs, 594.8 M/s | 8.5 µs, 615.2 M/s | 0.97 | 7.7% / 3.6% |
| terrain 256 m | 130.1 k triangles | 234.9 µs, 553.8 M/s | 211.3 µs, 615.8 M/s | 0.90 | 8.1% / 5.9% |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 241.5 µs, 564.3 M/s | 234.2 µs, 582.1 M/s | 0.97 | 4.9% / 4.0% |
| vale 256 m, 64 m tiles | 137.3 k triangles | 232.4 µs, 590.8 M/s | 223.1 µs, 615.4 M/s | 0.96 | 7.8% / 6.2% |
| vale 1 km, 64 m tiles | 2.22 M triangles | 3.70 ms, 600.6 M/s | 3.56 ms, 623.9 M/s | 0.96 | 15.7% / 10.5% |

#### Rasterization, int indices

`rcRasterizeTriangles` and `rasterizeTriangles`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.48 ms, 2.3 M/s | 4.26 ms, 2.4 M/s | 0.95 | 0.7% / 0.7% |
| nav_test.obj | 1612 triangles | 3.09 ms, 522.3 k/s | 2.83 ms, 569.9 k/s | 0.92 | 0.5% / 1.4% |
| undulating.obj | 5202 triangles | 3.64 ms, 1.4 M/s | 3.42 ms, 1.5 M/s | 0.94 | 0.6% / 1.4% |
| terrain 256 m | 130.1 k triangles | 31.56 ms, 4.1 M/s | 29.16 ms, 4.5 M/s | 0.92 | 0.8% / 0.8% |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 90.72 ms, 1.5 M/s | 80.91 ms, 1.7 M/s | 0.89 | 0.2% / 0.2% |
| vale 256 m, 64 m tiles | 137.3 k triangles | 88.81 ms, 1.5 M/s | 79.18 ms, 1.7 M/s | 0.89 | 1.0% / 1.8% |
| vale 1 km, 64 m tiles | 2.22 M triangles | 1436.40 ms, 1.5 M/s | 1280.83 ms, 1.7 M/s | 0.89 | 4.0% / 4.1% |

#### Low hanging obstacles filter

`rcFilterLowHangingWalkableObstacles` and `filterLowHangingWalkableObstacles`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 80.5 µs, 647.5 M/s | 68.1 µs, 764.8 M/s | 0.85 | 4.6% / 5.2% |
| nav_test.obj | 120.2 k spans | 119.5 µs, 1.01 G/s | 103.8 µs, 1.16 G/s | 0.87 | 3.6% / 1.5% |
| undulating.obj | 108.7 k spans | 96.3 µs, 1.13 G/s | 79.2 µs, 1.37 G/s | 0.82 | 15.9% / 2.4% |
| terrain 256 m | 741.4 k spans | 606.4 µs, 1.22 G/s | 506.9 µs, 1.46 G/s | 0.84 | 9.9% / 22.2% |
| terrain 256 m, 64 m tiles | 4.41 M spans | 3.85 ms, 1.14 G/s | 2.58 ms, 1.71 G/s | 0.67 | 6.6% / 2.2% |
| vale 256 m, 64 m tiles | 4.34 M spans | 3.71 ms, 1.17 G/s | 2.48 ms, 1.75 G/s | 0.67 | 3.0% / 7.8% |
| vale 1 km, 64 m tiles | 70.09 M spans | 59.20 ms, 1.18 G/s | 39.70 ms, 1.77 G/s | 0.67 | 5.6% / 15.4% |

#### Ledge filter

`rcFilterLedgeSpans` and `filterLedgeSpans`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 411.6 µs, 126.6 M/s | 385.3 µs, 135.2 M/s | 0.94 | 1.2% / 2.6% |
| nav_test.obj | 120.2 k spans | 938.3 µs, 128.1 M/s | 850.2 µs, 141.4 M/s | 0.91 | 1.8% / 1.8% |
| undulating.obj | 108.7 k spans | 880.8 µs, 123.4 M/s | 783.7 µs, 138.7 M/s | 0.89 | 0.7% / 0.3% |
| terrain 256 m | 741.4 k spans | 5.50 ms, 134.8 M/s | 4.86 ms, 152.6 M/s | 0.88 | 1.3% / 1.2% |
| terrain 256 m, 64 m tiles | 4.41 M spans | 33.39 ms, 132.0 M/s | 30.14 ms, 146.2 M/s | 0.90 | 0.8% / 0.5% |
| vale 256 m, 64 m tiles | 4.34 M spans | 33.51 ms, 129.6 M/s | 30.28 ms, 143.4 M/s | 0.90 | 0.3% / 3.2% |
| vale 1 km, 64 m tiles | 70.09 M spans | 542.52 ms, 129.2 M/s | 489.82 ms, 143.1 M/s | 0.90 | 3.6% / 4.2% |

#### Low height filter

`rcFilterWalkableLowHeightSpans` and `filterWalkableLowHeightSpans`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 85.3 µs, 610.7 M/s | 67.2 µs, 775.6 M/s | 0.79 | 6.3% / 6.4% |
| nav_test.obj | 120.2 k spans | 134.1 µs, 896.6 M/s | 118.1 µs, 1.02 G/s | 0.88 | 14.3% / 6.7% |
| undulating.obj | 108.7 k spans | 96.6 µs, 1.13 G/s | 80.9 µs, 1.34 G/s | 0.84 | 5.2% / 7.7% |
| terrain 256 m | 741.4 k spans | 543.4 µs, 1.36 G/s | 434.6 µs, 1.71 G/s | 0.80 | 14.5% / 15.3% |
| terrain 256 m, 64 m tiles | 4.41 M spans | 3.42 ms, 1.29 G/s | 2.54 ms, 1.73 G/s | 0.74 | 4.5% / 7.2% |
| vale 256 m, 64 m tiles | 4.34 M spans | 3.27 ms, 1.33 G/s | 2.44 ms, 1.78 G/s | 0.75 | 7.4% / 3.6% |
| vale 1 km, 64 m tiles | 70.09 M spans | 52.46 ms, 1.34 G/s | 38.33 ms, 1.83 G/s | 0.73 | 6.9% / 12.4% |

#### Compact heightfield

`rcBuildCompactHeightfield` and `buildCompactHeightfield`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 361.9 µs, 144.0 M/s | 335.0 µs, 155.5 M/s | 0.93 | 3.0% / 12.0% |
| nav_test.obj | 120.2 k spans | 699.7 µs, 171.8 M/s | 639.4 µs, 188.0 M/s | 0.91 | 1.6% / 0.9% |
| undulating.obj | 108.7 k spans | 1.01 ms, 107.2 M/s | 894.6 µs, 121.5 M/s | 0.88 | 1.6% / 3.1% |
| terrain 256 m | 741.4 k spans | 6.30 ms, 117.6 M/s | 5.49 ms, 135.0 M/s | 0.87 | 0.7% / 1.6% |
| terrain 256 m, 64 m tiles | 4.41 M spans | 37.41 ms, 117.8 M/s | 32.79 ms, 134.4 M/s | 0.88 | 0.4% / 0.3% |
| vale 256 m, 64 m tiles | 4.34 M spans | 38.31 ms, 113.4 M/s | 33.42 ms, 129.9 M/s | 0.87 | 1.2% / 3.4% |
| vale 1 km, 64 m tiles | 70.09 M spans | 620.77 ms, 112.9 M/s | 540.41 ms, 129.7 M/s | 0.87 | 2.1% / 3.0% |

#### Erosion

`rcErodeWalkableArea` and `erodeWalkableArea`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 360.3 µs, 65.4 M/s | 346.2 µs, 68.1 M/s | 0.96 | 6.1% / 2.3% |
| nav_test.obj | 56.8 k compact spans | 680.6 µs, 83.4 M/s | 673.2 µs, 84.4 M/s | 0.99 | 1.7% / 1.6% |
| undulating.obj | 105.8 k compact spans | 1.03 ms, 103.1 M/s | 993.1 µs, 106.5 M/s | 0.97 | 1.1% / 1.9% |
| terrain 256 m | 686.7 k compact spans | 6.64 ms, 103.3 M/s | 6.46 ms, 106.2 M/s | 0.97 | 2.4% / 0.9% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 35.53 ms, 115.3 M/s | 34.14 ms, 119.9 M/s | 0.96 | 0.3% / 0.5% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 32.68 ms, 131.9 M/s | 31.30 ms, 137.7 M/s | 0.96 | 0.6% / 4.5% |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 529.92 ms, 131.3 M/s | 508.13 ms, 136.9 M/s | 0.96 | 1.3% / 1.7% |

#### Distance field

`rcBuildDistanceField` and `buildDistanceField`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 399.1 µs, 59.1 M/s | 435.1 µs, 54.2 M/s | 1.09 | 3.7% / 3.2% |
| nav_test.obj | 56.8 k compact spans | 749.5 µs, 75.8 M/s | 832.6 µs, 68.2 M/s | 1.11 | 2.0% / 1.9% |
| undulating.obj | 105.8 k compact spans | 1.17 ms, 90.4 M/s | 1.41 ms, 74.9 M/s | 1.21 | 2.7% / 2.9% |
| terrain 256 m | 686.7 k compact spans | 7.61 ms, 90.3 M/s | 9.19 ms, 74.7 M/s | 1.21 | 0.6% / 0.4% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 40.95 ms, 100.0 M/s | 51.72 ms, 79.2 M/s | 1.26 | 0.2% / 0.3% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 39.44 ms, 109.3 M/s | 52.40 ms, 82.3 M/s | 1.33 | 0.9% / 4.5% |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 639.70 ms, 108.7 M/s | 849.56 ms, 81.9 M/s | 1.33 | 2.0% / 2.0% |

#### Watershed regions

`rcBuildRegions` and `buildRegions`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 1.03 ms, 22.9 M/s | 696.3 µs, 33.8 M/s | 0.68 | 4.0% / 12.3% |
| nav_test.obj | 56.8 k compact spans | 2.55 ms, 22.3 M/s | 1.47 ms, 38.7 M/s | 0.58 | 1.1% / 2.8% |
| undulating.obj | 105.8 k compact spans | 5.20 ms, 20.3 M/s | 2.77 ms, 38.1 M/s | 0.53 | 1.2% / 2.2% |
| terrain 256 m | 686.7 k compact spans | 38.04 ms, 18.1 M/s | 20.42 ms, 33.6 M/s | 0.54 | 1.4% / 3.4% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 202.64 ms, 20.2 M/s | 112.49 ms, 36.4 M/s | 0.56 | 1.6% / 0.8% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 208.41 ms, 20.7 M/s | 149.49 ms, 28.8 M/s | 0.72 | 3.7% / 6.9% |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 3413.18 ms, 20.4 M/s | 2448.02 ms, 28.4 M/s | 0.72 | 2.7% / 3.9% |

#### Contours

`rcBuildContours` and `buildContours`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 237.6 µs, 99.2 M/s | 209.5 µs, 112.5 M/s | 0.88 | 10.6% / 2.6% |
| nav_test.obj | 56.8 k compact spans | 431.4 µs, 131.7 M/s | 379.5 µs, 149.7 M/s | 0.88 | 3.8% / 2.1% |
| undulating.obj | 105.8 k compact spans | 611.4 µs, 173.0 M/s | 584.1 µs, 181.1 M/s | 0.96 | 8.2% / 1.5% |
| terrain 256 m | 686.7 k compact spans | 4.57 ms, 150.4 M/s | 4.21 ms, 163.0 M/s | 0.92 | 1.3% / 1.0% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 19.33 ms, 211.8 M/s | 19.06 ms, 214.9 M/s | 0.99 | 0.2% / 0.4% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 15.15 ms, 284.4 M/s | 16.06 ms, 268.3 M/s | 1.06 | 1.3% / 3.2% |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 243.78 ms, 285.3 M/s | 258.93 ms, 268.6 M/s | 1.06 | 2.2% / 1.7% |

#### Polygon mesh

`rcBuildPolyMesh` and `buildPolyMesh`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 118 polygons | 200.4 µs, 588.8 k/s | 174.1 µs, 677.9 k/s | 0.87 | 1.7% / 4.2% |
| nav_test.obj | 155 polygons | 172.2 µs, 900.3 k/s | 159.9 µs, 969.3 k/s | 0.93 | 2.3% / 4.6% |
| undulating.obj | 216 polygons | 345.4 µs, 625.3 k/s | 306.8 µs, 704.0 k/s | 0.89 | 1.8% / 3.4% |
| terrain 256 m | 2580 polygons | 5.85 ms, 440.7 k/s | 5.04 ms, 511.8 k/s | 0.86 | 1.3% / 0.8% |
| terrain 256 m, 64 m tiles | 4098 polygons | 11.39 ms, 359.9 k/s | 9.91 ms, 413.4 k/s | 0.87 | 0.3% / 0.8% |
| vale 256 m, 64 m tiles | 108 polygons | 114.7 µs, 941.5 k/s | 110.4 µs, 978.4 k/s | 0.96 | 5.5% / 10.3% |
| vale 1 km, 64 m tiles | 684 polygons | 730.9 µs, 935.9 k/s | 721.8 µs, 947.6 k/s | 0.99 | 20.9% / 35.9% |

#### Detail mesh

`rcBuildPolyMeshDetail` and `buildPolyMeshDetail`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 118 polygons | 370.9 µs, 318.1 k/s | 283.6 µs, 416.1 k/s | 0.76 | 1.5% / 2.4% |
| nav_test.obj | 155 polygons | 1.13 ms, 136.8 k/s | 668.3 µs, 231.9 k/s | 0.59 | 2.3% / 21.7% |
| undulating.obj | 216 polygons | 43.35 ms, 4983/s | 11.10 ms, 19.5 k/s | 0.26 | 1.6% / 0.9% |
| terrain 256 m | 2580 polygons | 35.64 ms, 72.4 k/s | 15.20 ms, 169.8 k/s | 0.43 | 0.9% / 1.0% |
| terrain 256 m, 64 m tiles | 4098 polygons | 74.48 ms, 55.0 k/s | 41.03 ms, 99.9 k/s | 0.55 | 0.5% / 0.2% |
| vale 256 m, 64 m tiles | 108 polygons | 594.26 ms, 182/s | 65.15 ms, 1658/s | 0.11 | 0.4% / 3.1% |
| vale 1 km, 64 m tiles | 684 polygons | 14415.68 ms, 47/s | 1274.20 ms, 537/s | 0.09 | 2.6% / 2.6% |

#### Span count

`rcGetHeightFieldSpanCount` and `getHeightFieldSpanCount`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 52.3 µs, 995.6 M/s | 48.4 µs, 1.08 G/s | 0.93 | 7.2% / 7.7% |
| nav_test.obj | 120.2 k spans | 82.2 µs, 1.46 G/s | 81.2 µs, 1.48 G/s | 0.99 | 5.1% / 4.6% |
| undulating.obj | 108.7 k spans | 49.9 µs, 2.18 G/s | 47.7 µs, 2.28 G/s | 0.96 | 12.4% / 15.2% |
| terrain 256 m | 741.4 k spans | 383.8 µs, 1.93 G/s | 313.7 µs, 2.36 G/s | 0.82 | 42.3% / 19.8% |
| terrain 256 m, 64 m tiles | 4.41 M spans | 1.82 ms, 2.42 G/s | 1.80 ms, 2.45 G/s | 0.99 | 3.7% / 4.1% |
| vale 256 m, 64 m tiles | 4.34 M spans | 2.08 ms, 2.08 G/s | 1.72 ms, 2.52 G/s | 0.83 | 61.3% / 6.1% |
| vale 1 km, 64 m tiles | 70.09 M spans | 28.17 ms, 2.49 G/s | 28.04 ms, 2.50 G/s | 1.00 | 56.1% / 16.5% |

#### Unwalkable triangles

`rcClearUnwalkableTriangles` and `clearUnwalkableTriangles`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 54.0 µs, 187.8 M/s | 57.7 µs, 175.5 M/s | 1.07 | 3.6% / 3.3% |
| nav_test.obj | 1612 triangles | 3.7 µs, 431.4 M/s | 4.1 µs, 394.4 M/s | 1.09 | 12.3% / 13.7% |
| undulating.obj | 5202 triangles | 8.4 µs, 619.7 M/s | 8.5 µs, 613.0 M/s | 1.01 | 3.8% / 7.2% |
| terrain 256 m | 130.1 k triangles | 216.9 µs, 599.9 M/s | 210.0 µs, 619.6 M/s | 0.97 | 11.7% / 3.2% |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 233.5 µs, 583.7 M/s | 231.0 µs, 590.0 M/s | 0.99 | 2.7% / 3.7% |
| vale 256 m, 64 m tiles | 137.3 k triangles | 212.9 µs, 644.9 M/s | 214.1 µs, 641.2 M/s | 1.01 | 7.1% / 12.5% |
| vale 1 km, 64 m tiles | 2.22 M triangles | 3.45 ms, 644.1 M/s | 3.48 ms, 638.4 M/s | 1.01 | 19.0% / 12.4% |

#### Rasterization, unsigned short indices

`rcRasterizeTriangles` and `rasterizeTriangles`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.54 ms, 2.2 M/s | 4.31 ms, 2.3 M/s | 0.95 | 0.5% / 0.6% |
| nav_test.obj | 1612 triangles | 3.21 ms, 502.7 k/s | 2.95 ms, 546.7 k/s | 0.92 | 0.8% / 0.8% |
| undulating.obj | 5202 triangles | 3.70 ms, 1.4 M/s | 3.50 ms, 1.5 M/s | 0.95 | 1.6% / 1.0% |

#### Rasterization, unindexed

`rcRasterizeTriangles` and `rasterizeUnindexedTriangles`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.47 ms, 2.3 M/s | 4.22 ms, 2.4 M/s | 0.94 | 0.7% / 0.4% |
| nav_test.obj | 1612 triangles | 3.08 ms, 523.4 k/s | 2.81 ms, 574.1 k/s | 0.91 | 0.3% / 0.5% |
| undulating.obj | 5202 triangles | 3.61 ms, 1.4 M/s | 3.39 ms, 1.5 M/s | 0.94 | 0.8% / 0.4% |
| terrain 256 m | 130.1 k triangles | 32.42 ms, 4.0 M/s | 30.14 ms, 4.3 M/s | 0.93 | 0.9% / 1.8% |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 90.31 ms, 1.5 M/s | 80.59 ms, 1.7 M/s | 0.89 | 0.2% / 0.3% |
| vale 256 m, 64 m tiles | 137.3 k triangles | 87.62 ms, 1.6 M/s | 78.32 ms, 1.8 M/s | 0.89 | 1.3% / 4.2% |
| vale 1 km, 64 m tiles | 2.22 M triangles | 1420.03 ms, 1.6 M/s | 1268.32 ms, 1.8 M/s | 0.89 | 5.4% / 4.1% |

#### Rasterization, one triangle at a time

`rcRasterizeTriangle` and `rasterizeTriangle`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.49 ms, 2.3 M/s | 4.23 ms, 2.4 M/s | 0.94 | 0.7% / 0.3% |
| nav_test.obj | 1612 triangles | 3.07 ms, 524.5 k/s | 2.81 ms, 573.8 k/s | 0.91 | 0.5% / 0.5% |
| undulating.obj | 5202 triangles | 3.62 ms, 1.4 M/s | 3.39 ms, 1.5 M/s | 0.94 | 0.6% / 0.9% |
| terrain 256 m | 130.1 k triangles | 31.76 ms, 4.1 M/s | 29.26 ms, 4.4 M/s | 0.92 | 1.3% / 0.8% |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 90.57 ms, 1.5 M/s | 80.65 ms, 1.7 M/s | 0.89 | 0.2% / 0.3% |
| vale 256 m, 64 m tiles | 137.3 k triangles | 88.55 ms, 1.6 M/s | 78.74 ms, 1.7 M/s | 0.89 | 3.7% / 0.6% |
| vale 1 km, 64 m tiles | 2.22 M triangles | 1431.81 ms, 1.6 M/s | 1276.50 ms, 1.7 M/s | 0.89 | 4.6% / 3.8% |

#### Adding spans, the rasterized field's again

`rcAddSpan` and `addSpan`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 292.5 µs, 178.1 M/s | 214.2 µs, 243.3 M/s | 0.73 | 2.1% / 5.1% |
| nav_test.obj | 120.2 k spans | 659.5 µs, 182.2 M/s | 476.4 µs, 252.3 M/s | 0.72 | 2.2% / 4.8% |
| undulating.obj | 108.7 k spans | 529.7 µs, 205.2 M/s | 355.5 µs, 305.8 M/s | 0.67 | 7.9% / 3.2% |
| terrain 256 m | 741.4 k spans | 4.12 ms, 180.0 M/s | 2.81 ms, 264.1 M/s | 0.68 | 6.0% / 12.5% |
| terrain 256 m, 64 m tiles | 4.41 M spans | 16.82 ms, 262.1 M/s | 9.94 ms, 443.6 M/s | 0.59 | 1.9% / 0.8% |
| vale 256 m, 64 m tiles | 4.34 M spans | 16.60 ms, 261.6 M/s | 9.64 ms, 450.4 M/s | 0.58 | 2.9% / 0.6% |
| vale 1 km, 64 m tiles | 70.09 M spans | 266.80 ms, 262.7 M/s | 156.27 ms, 448.5 M/s | 0.59 | 3.3% / 4.3% |

#### Polygon mesh copy

`rcCopyPolyMesh` and `copyPolyMesh`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 118 polygons | 26.4 µs, 4.5 M/s | 27.0 µs, 4.4 M/s | 1.02 | 5.2% / 4.7% |
| nav_test.obj | 155 polygons | 48.4 µs, 3.2 M/s | 49.3 µs, 3.1 M/s | 1.02 | 9.0% / 3.8% |
| undulating.obj | 216 polygons | 45.8 µs, 4.7 M/s | 45.9 µs, 4.7 M/s | 1.00 | 100.8% / 3.4% |
| terrain 256 m | 2580 polygons | 404.9 µs, 6.4 M/s | 388.4 µs, 6.6 M/s | 0.96 | 26.9% / 40.4% |
| terrain 256 m, 64 m tiles | 4098 polygons | 27.9 µs, 146.9 M/s | 26.0 µs, 157.9 M/s | 0.93 | 5.2% / 7.8% |
| vale 256 m, 64 m tiles | 108 polygons | 25.0 µs, 4.3 M/s | 22.8 µs, 4.7 M/s | 0.91 | 3.1% / 10.2% |
| vale 1 km, 64 m tiles | 684 polygons | 451.9 µs, 1.5 M/s | 404.6 µs, 1.7 M/s | 0.90 | 14.9% / 13.8% |

#### Heightfield layers

`rcBuildHeightfieldLayers` and `buildHeightfieldLayers`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 602.9 µs, 39.1 M/s | 558.8 µs, 42.2 M/s | 0.93 | 6.8% / 3.5% |
| nav_test.obj | 56.8 k compact spans | 1.08 ms, 52.8 M/s | 1.03 ms, 55.0 M/s | 0.96 | 5.4% / 1.8% |
| undulating.obj | 105.8 k compact spans | 1.52 ms, 69.8 M/s | 1.43 ms, 73.9 M/s | 0.94 | 3.8% / 1.8% |
| terrain 256 m | 686.7 k compact spans | fails | fails | | |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 54.51 ms, 75.1 M/s | 52.65 ms, 77.8 M/s | 0.97 | 2.0% / 1.6% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 51.53 ms, 83.6 M/s | 47.44 ms, 90.9 M/s | 0.92 | 2.2% / 1.2% |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 817.27 ms, 85.1 M/s | 773.83 ms, 89.9 M/s | 0.95 | 4.4% / 4.3% |

#### Monotone regions

`rcBuildRegionsMonotone` and `buildRegionsMonotone`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 316.9 µs, 74.4 M/s | 265.0 µs, 88.9 M/s | 0.84 | 3.3% / 6.7% |
| nav_test.obj | 56.8 k compact spans | 652.1 µs, 87.1 M/s | 524.7 µs, 108.3 M/s | 0.80 | 2.0% / 4.4% |
| undulating.obj | 105.8 k compact spans | 979.2 µs, 108.0 M/s | 779.9 µs, 135.7 M/s | 0.80 | 2.7% / 2.4% |
| terrain 256 m | 686.7 k compact spans | 20.82 ms, 33.0 M/s | 7.94 ms, 86.4 M/s | 0.38 | 2.7% / 10.5% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 33.75 ms, 121.3 M/s | 25.83 ms, 158.5 M/s | 0.77 | 1.2% / 0.6% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 28.51 ms, 151.2 M/s | 22.56 ms, 191.1 M/s | 0.79 | 1.0% / 1.0% |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 461.30 ms, 150.8 M/s | 362.18 ms, 192.0 M/s | 0.79 | 1.9% / 2.6% |

#### Layer regions

`rcBuildLayerRegions` and `buildLayerRegions`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 366.3 µs, 64.3 M/s | 344.9 µs, 68.3 M/s | 0.94 | 3.9% / 7.4% |
| nav_test.obj | 56.8 k compact spans | 787.2 µs, 72.1 M/s | 725.5 µs, 78.3 M/s | 0.92 | 1.2% / 5.0% |
| undulating.obj | 105.8 k compact spans | 1.21 ms, 87.1 M/s | 1.20 ms, 88.4 M/s | 0.98 | 1.3% / 1.2% |
| terrain 256 m | 686.7 k compact spans | 8.65 ms, 79.3 M/s | 7.95 ms, 86.4 M/s | 0.92 | 3.7% / 1.2% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 45.58 ms, 89.8 M/s | 43.92 ms, 93.2 M/s | 0.96 | 0.5% / 0.2% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 44.77 ms, 96.3 M/s | 45.23 ms, 95.3 M/s | 1.01 | 0.8% / 0.5% |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 723.06 ms, 96.2 M/s | 728.29 ms, 95.5 M/s | 1.01 | 4.3% / 3.7% |

#### Median area filter

`rcMedianFilterWalkableArea` and `medianFilterWalkableArea`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 163.3 µs, 144.3 M/s | 171.8 µs, 137.2 M/s | 1.05 | 2.1% / 2.1% |
| nav_test.obj | 56.8 k compact spans | 353.8 µs, 160.5 M/s | 358.8 µs, 158.3 M/s | 1.01 | 4.6% / 1.3% |
| undulating.obj | 105.8 k compact spans | 651.0 µs, 162.5 M/s | 660.0 µs, 160.3 M/s | 1.01 | 0.8% / 1.0% |
| terrain 256 m | 686.7 k compact spans | 4.21 ms, 163.0 M/s | 4.27 ms, 160.7 M/s | 1.01 | 0.9% / 1.2% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 24.85 ms, 164.8 M/s | 25.14 ms, 162.9 M/s | 1.01 | 0.5% / 0.4% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 26.56 ms, 162.3 M/s | 26.80 ms, 160.8 M/s | 1.01 | 1.4% / 0.5% |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 429.18 ms, 162.1 M/s | 433.43 ms, 160.5 M/s | 1.01 | 3.7% / 4.5% |

#### Box area

`rcMarkBoxArea` and `markBoxArea`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 15.2 µs, 1.55 G/s | 12.5 µs, 1.89 G/s | 0.82 | 8.8% / 2.8% |
| nav_test.obj | 56.8 k compact spans | 27.2 µs, 2.09 G/s | 25.1 µs, 2.26 G/s | 0.92 | 2.7% / 2.5% |
| undulating.obj | 105.8 k compact spans | 26.0 µs, 4.07 G/s | 25.1 µs, 4.21 G/s | 0.97 | 15.4% / 19.5% |
| terrain 256 m | 686.7 k compact spans | 188.0 µs, 3.65 G/s | 151.0 µs, 4.55 G/s | 0.80 | 3.9% / 10.3% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 921.5 µs, 4.44 G/s | 798.7 µs, 5.13 G/s | 0.87 | 6.6% / 1.8% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 775.9 µs, 5.55 G/s | 684.2 µs, 6.30 G/s | 0.88 | 9.2% / 3.5% |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 12.60 ms, 5.52 G/s | 10.97 ms, 6.34 G/s | 0.87 | 4.4% / 3.2% |

#### Convex area

`rcMarkConvexPolyArea` and `markConvexPolyArea`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 21.7 µs, 1.09 G/s | 18.8 µs, 1.26 G/s | 0.87 | 15.9% / 20.8% |
| nav_test.obj | 56.8 k compact spans | 57.6 µs, 985.5 M/s | 48.2 µs, 1.18 G/s | 0.84 | 8.6% / 6.8% |
| undulating.obj | 105.8 k compact spans | 97.8 µs, 1.08 G/s | 82.0 µs, 1.29 G/s | 0.84 | 3.1% / 3.9% |
| terrain 256 m | 686.7 k compact spans | 610.6 µs, 1.12 G/s | 513.9 µs, 1.34 G/s | 0.84 | 2.4% / 2.0% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 3.84 ms, 1.07 G/s | 3.18 ms, 1.29 G/s | 0.83 | 0.7% / 0.7% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 3.95 ms, 1.09 G/s | 3.29 ms, 1.31 G/s | 0.83 | 1.1% / 1.1% |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 63.02 ms, 1.10 G/s | 52.57 ms, 1.32 G/s | 0.83 | 4.4% / 3.8% |

#### Cylinder area

`rcMarkCylinderArea` and `markCylinderArea`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 22.9 µs, 1.03 G/s | 18.7 µs, 1.26 G/s | 0.82 | 6.8% / 13.3% |
| nav_test.obj | 56.8 k compact spans | 29.0 µs, 1.96 G/s | 26.7 µs, 2.12 G/s | 0.92 | 10.0% / 8.9% |
| undulating.obj | 105.8 k compact spans | 37.4 µs, 2.83 G/s | 32.2 µs, 3.29 G/s | 0.86 | 8.0% / 6.4% |
| terrain 256 m | 686.7 k compact spans | 235.4 µs, 2.92 G/s | 191.4 µs, 3.59 G/s | 0.81 | 5.9% / 7.8% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 1.32 ms, 3.11 G/s | 1.10 ms, 3.72 G/s | 0.84 | 2.2% / 1.5% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 1.22 ms, 3.53 G/s | 1.04 ms, 4.14 G/s | 0.85 | 0.9% / 1.6% |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 19.85 ms, 3.50 G/s | 16.59 ms, 4.19 G/s | 0.84 | 4.8% / 4.1% |

#### Polygon mesh merge, every tile

`rcMergePolyMeshes` and `mergePolyMeshes`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| terrain 256 m, 64 m tiles | 4098 polygons | 258.4 µs, 15.9 M/s | 263.4 µs, 15.6 M/s | 1.02 | 2.7% / 2.8% |
| vale 256 m, 64 m tiles | 108 polygons | 9.1 µs, 11.9 M/s | 9.5 µs, 11.4 M/s | 1.04 | 14.4% / 15.0% |
| vale 1 km, 64 m tiles | 684 polygons | 46.7 µs, 14.6 M/s | 49.6 µs, 13.8 M/s | 1.06 | 36.2% / 33.1% |

#### Detail mesh merge, every tile

`rcMergePolyMeshDetails` and `mergePolyMeshDetails`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| terrain 256 m, 64 m tiles | 4098 polygons | 41.3 µs, 99.1 M/s | 20.2 µs, 202.5 M/s | 0.49 | 26.6% / 50.5% |
| vale 256 m, 64 m tiles | 108 polygons | 11.8 µs, 9.2 M/s | 5.8 µs, 18.6 M/s | 0.49 | 66.3% / 82.9% |
| vale 1 km, 64 m tiles | 684 polygons | 147.3 µs, 4.6 M/s | 79.6 µs, 8.6 M/s | 0.54 | 18.6% / 21.4% |

#### Bounds

`rcCalcBounds` and `calcBounds`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 5101 vertices | 10.5 µs, 485.3 M/s | 2.9 µs, 1.79 G/s | 0.27 | 1.0% / 5.6% |
| nav_test.obj | 884 vertices | 1.9 µs, 474.5 M/s | 0.5 µs, 1.63 G/s | 0.29 | 3.3% / 11.1% |
| undulating.obj | 2800 vertices | 5.9 µs, 474.5 M/s | 1.6 µs, 1.74 G/s | 0.27 | 1.4% / 1.9% |
| terrain 256 m | 66.8 k vertices | 138.8 µs, 481.2 M/s | 37.5 µs, 1.78 G/s | 0.27 | 3.3% / 4.5% |
| terrain 256 m, 64 m tiles | 66.8 k vertices | 138.8 µs, 481.3 M/s | 37.5 µs, 1.78 G/s | 0.27 | 0.7% / 10.4% |
| vale 256 m, 64 m tiles | 66.0 k vertices | 137.3 µs, 481.0 M/s | 37.0 µs, 1.78 G/s | 0.27 | 4.7% / 11.5% |
| vale 1 km, 64 m tiles | 1.05 M vertices | 2.17 ms, 484.1 M/s | 601.4 µs, 1.75 G/s | 0.28 | 12.0% / 7.9% |

#### Grid size

`rcCalcGridSize` and `calcGridSize`, per call.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.0 k calls | 1.1 ns | 1.2 ns | 1.10 | 0.5% / 5.9% |
| nav_test.obj | 10.0 k calls | 1.1 ns | 1.2 ns | 1.07 | 0.7% / 2.9% |
| undulating.obj | 10.0 k calls | 1.1 ns | 1.2 ns | 1.09 | 0.8% / 2.7% |
| terrain 256 m | 10.0 k calls | 1.1 ns | 1.2 ns | 1.09 | 0.9% / 3.6% |
| terrain 256 m, 64 m tiles | 10.0 k calls | 1.1 ns | 1.2 ns | 1.08 | 4.7% / 2.7% |
| vale 256 m, 64 m tiles | 10.0 k calls | 1.1 ns | 1.2 ns | 1.09 | 1.0% / 5.6% |
| vale 1 km, 64 m tiles | 10.0 k calls | 1.1 ns | 1.2 ns | 1.08 | 8.5% / 5.1% |

#### Polygon offset, a hexagon

`rcOffsetPoly` and `offsetPoly`, per call.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.0 k calls | 34.6 ns | 26.4 ns | 0.76 | 1.4% / 5.3% |
| nav_test.obj | 10.0 k calls | 34.9 ns | 26.5 ns | 0.76 | 1.5% / 0.8% |
| undulating.obj | 10.0 k calls | 35.0 ns | 26.7 ns | 0.76 | 1.5% / 1.9% |
| terrain 256 m | 10.0 k calls | 34.8 ns | 26.7 ns | 0.77 | 2.1% / 0.8% |
| terrain 256 m, 64 m tiles | 10.0 k calls | 35.0 ns | 26.7 ns | 0.76 | 1.3% / 6.3% |
| vale 256 m, 64 m tiles | 10.0 k calls | 35.3 ns | 26.8 ns | 0.76 | 2.3% / 2.2% |
| vale 1 km, 64 m tiles | 10.0 k calls | 34.6 ns | 26.7 ns | 0.77 | 6.4% / 6.1% |

## Licence and credits

zlib licence ([`LICENSE`](LICENSE)), the original's.

Translated from Recast in
[recastnavigation](https://github.com/recastnavigation/recastnavigation)
1.6.0, by Mikko Mononen and the recastnavigation contributors. This is an
altered version: the code is rewritten in Zig with its own interface.

Made by Farhollow Games for the Loomwork Engine.
