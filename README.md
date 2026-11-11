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
on the same inputs. After every step, the two must agree on every byte of
every structure, every log message and every timer call. The inputs are:

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
- hand-made edge cases: empty scenes, one triangle, one span, the limit of
  every counter (region ids, mesh vertices, layer regions, layers, span
  heights, spans in a column) and degenerate triangles;
- upstream's own unit tests, run on both sides.

Both sides are built with fused multiply-add off, so float steps round as
written. Where the original's behaviour is undefined (reading memory it
never wrote, out-of-range float conversions), the port does what the
original does on x86-64 with zeroed memory, the same on every machine; see
[`doc/parity.md`](doc/parity.md). [`STATUS.md`](STATUS.md) lists every
feature with its tests and its state.

## Performance

`zig build bench` times the port against the original on the same inputs,
one feature at a time, on one thread. Zig 0.17.0 builds both for the
native CPU (`znver5`): the port in ReleaseFast, and the original with its
clang 22.1.8 at `-O3 -std=c++11 -fno-exceptions -fno-rtti
-fno-threadsafe-statics -ffp-contract=off -fno-fast-math`. Fused
multiply-adds are off on both sides, as the tests need for equal outputs.

These figures are from an AMD Ryzen 9 9950X3D (16 cores, the run pinned to
CPU 2, one of the eight with the stacked cache) on Linux 7.3.3 (CachyOS):

```sh
zig build bench -- --runs 15 --warmup 2 --cpu 2
```

Each time is the median of 15 runs after 2 warm-ups. The spread is the
range of the runs, slowest less fastest, as a share of the median. The two
sides take turns tile by tile, and every result is kept alive, so the
compiler cannot drop the work. Other work ran on the machine at the same
time. Half the spreads are under 6%; the large ones come from runs that
other processes interrupted. Between this session and an earlier, noisier
one of 7 runs, the typical row's ratio moved by 0.02, but those of short,
memory-bound features (the span count, the span filters, creating the
heightfield) moved by up to 0.7, so theirs are the least certain figures.

The inputs are RecastDemo's three meshes and a 256 m generated terrain,
each built whole with RecastDemo's defaults, and that terrain and a 256 m
rolling ground (`vale`), built in 64 m tiles with Loomwork's navmesh
settings (125 mm cells, an agent 1.8 m tall and 0.35 m wide).

### Summary

The port's median time divided by the original's, from the fastest to
the slowest of the inputs (below 1 is faster). Most features run on all
six inputs; 16-bit indices fit only RecastDemo's meshes, and the merges
run on the tiled inputs.

| feature | port ÷ original |
| --- | ---: |
| Whole build | 0.87 to 0.96 |
| Heightfield | 0.95 to 1.02 |
| Walkable triangles | 0.83 to 1.05 |
| Rasterization, int indices | 0.89 to 0.96 |
| Low hanging obstacles filter | 0.70 to 0.85 |
| Ledge filter | 0.88 to 0.95 |
| Low height filter | 0.64 to 0.86 |
| Compact heightfield | 1.36 to 1.68 |
| Erosion | 1.00 to 1.04 |
| Distance field | 1.29 to 1.41 |
| Watershed regions | 0.58 to 0.78 |
| Contours | 0.95 to 1.18 |
| Polygon mesh | 1.07 to 1.13 |
| Detail mesh | 0.75 to 0.97 |
| Span count | 0.62 to 0.99 |
| Unwalkable triangles | 0.96 to 1.05 |
| Rasterization, unsigned short indices | 0.92 to 0.95 |
| Rasterization, unindexed | 0.88 to 0.95 |
| Rasterization, one triangle at a time | 0.88 to 0.95 |
| Adding spans, the rasterized field's again | 0.59 to 0.74 |
| Polygon mesh copy | 0.91 to 1.06 |
| Heightfield layers | 0.94 to 1.08 |
| Monotone regions | 0.37 to 0.83 |
| Layer regions | 0.97 to 1.11 |
| Median area filter | 1.00 to 1.04 |
| Box area | 0.99 to 1.13 |
| Convex area | 0.78 to 0.84 |
| Cylinder area | 0.92 to 1.09 |
| Polygon mesh merge, every tile | 0.96 to 1.01 |
| Detail mesh merge, every tile | 0.49 to 0.51 |
| Bounds | 0.26 to 0.28 |
| Grid size | 1.12 to 1.14 |
| Polygon offset, a hexagon | 0.76 to 0.77 |

The heightfield layers fail on both sides on the whole 256 m terrain, as
its regions overflow their 8-bit ids, so that row has five inputs.

### Where the port is slower

- **Compact heightfield, 1.36 to 1.68 times.** The port runs about 1.5
  times the original's instructions (`perf`, on the tiled terrain). Its
  loop over a span's four neighbours stays a loop that loads each
  direction's offsets from a table, and each connection it sets rewrites
  the whole packed 64-bit span; clang unrolls the original's loop into
  constant offsets. Keeping the function out of line in the benchmark
  gives the same figure, so it is not the caller's inlining.
- **Distance field, 1.29 to 1.41 times.** About 1.35 times the
  instructions: the port multiplies out each neighbour's cell index
  (`imul` per neighbour) where the original keeps row offsets, and it
  spills more registers to the stack.
- **Polygon mesh, 1.07 to 1.13 times.** More instructions in merging
  polygons; not yet traced to a line.
- **On the rolling ground**, contours (1.18), box area (1.13) and layer
  regions (1.11), each with spreads under 6%; not yet traced.
- **Grid size, 1.12 to 1.14 times**, about 0.15 ns a call: the port checks
  the range before converting a float to an int, so that out-of-range
  values give x86-64's result on every machine, where the original's
  `(int)` is one instruction.

Every other feature is within 10% of the original on every input, or
faster; differences of a few percent are within the spread of the runs.
A performance pass will work on these without changing a byte of output.

### Every feature

#### Whole build

Every step of a navmesh build, in Loomwork's order.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 8.08 ms, 1.3 M/s | 7.73 ms, 1.3 M/s | 0.96 | 1.6% / 1.4% |
| nav_test.obj | 1612 triangles | 10.70 ms, 150.6 k/s | 9.80 ms, 164.5 k/s | 0.92 | 2.6% / 4.3% |
| undulating.obj | 5202 triangles | 57.24 ms, 90.9 k/s | 54.58 ms, 95.3 k/s | 0.95 | 2.6% / 4.3% |
| terrain 256 m | 130.1 k triangles | 143.38 ms, 907.4 k/s | 129.52 ms, 1.0 M/s | 0.90 | 2.3% / 2.3% |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 556.68 ms, 244.9 k/s | 483.64 ms, 281.8 k/s | 0.87 | 1.4% / 3.6% |
| vale 256 m, 64 m tiles | 137.3 k triangles | 1062.99 ms, 129.2 k/s | 1021.81 ms, 134.4 k/s | 0.96 | 2.3% / 3.0% |

#### Heightfield

`rcCreateHeightfield` and `Heightfield.init`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 81.8 k cells | 4.6 µs, 17.95 G/s | 4.4 µs, 18.48 G/s | 0.97 | 11.4% / 18.8% |
| nav_test.obj | 78.7 k cells | 4.5 µs, 17.49 G/s | 4.3 µs, 18.48 G/s | 0.95 | 29.2% / 21.2% |
| undulating.obj | 109.2 k cells | 7.1 µs, 15.40 G/s | 7.0 µs, 15.62 G/s | 0.99 | 30.8% / 25.8% |
| terrain 256 m | 727.6 k cells | 52.7 µs, 13.81 G/s | 50.0 µs, 14.55 G/s | 0.95 | 119.4% / 100.7% |
| terrain 256 m, 64 m tiles | 4.39 M cells | 242.7 µs, 18.10 G/s | 239.3 µs, 18.36 G/s | 0.99 | 24.7% / 29.7% |
| vale 256 m, 64 m tiles | 4.39 M cells | 287.8 µs, 15.26 G/s | 293.2 µs, 14.98 G/s | 1.02 | 32.2% / 52.1% |

#### Walkable triangles

`rcMarkWalkableTriangles` and `markWalkableTriangles`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 55.6 µs, 182.3 M/s | 58.2 µs, 174.1 M/s | 1.05 | 6.8% / 3.5% |
| nav_test.obj | 1612 triangles | 3.9 µs, 410.4 M/s | 4.1 µs, 395.3 M/s | 1.04 | 8.2% / 4.7% |
| undulating.obj | 5202 triangles | 9.1 µs, 568.7 M/s | 9.0 µs, 577.0 M/s | 0.99 | 6.3% / 10.3% |
| terrain 256 m | 130.1 k triangles | 224.6 µs, 579.3 M/s | 216.1 µs, 602.0 M/s | 0.96 | 4.2% / 9.5% |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 251.9 µs, 541.2 M/s | 232.5 µs, 586.2 M/s | 0.92 | 9.9% / 5.5% |
| vale 256 m, 64 m tiles | 137.3 k triangles | 263.9 µs, 520.3 M/s | 218.3 µs, 629.0 M/s | 0.83 | 15.5% / 10.8% |

#### Rasterization, int indices

`rcRasterizeTriangles` and `rasterizeTriangles`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.48 ms, 2.3 M/s | 4.28 ms, 2.4 M/s | 0.96 | 1.3% / 0.6% |
| nav_test.obj | 1612 triangles | 3.07 ms, 525.6 k/s | 2.86 ms, 563.8 k/s | 0.93 | 3.6% / 4.9% |
| undulating.obj | 5202 triangles | 3.64 ms, 1.4 M/s | 3.46 ms, 1.5 M/s | 0.95 | 8.7% / 4.3% |
| terrain 256 m | 130.1 k triangles | 31.56 ms, 4.1 M/s | 29.66 ms, 4.4 M/s | 0.94 | 2.4% / 2.0% |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 90.70 ms, 1.5 M/s | 81.14 ms, 1.7 M/s | 0.89 | 2.2% / 1.3% |
| vale 256 m, 64 m tiles | 137.3 k triangles | 89.48 ms, 1.5 M/s | 79.30 ms, 1.7 M/s | 0.89 | 2.9% / 2.1% |

#### Low hanging obstacles filter

`rcFilterLowHangingWalkableObstacles` and `filterLowHangingWalkableObstacles`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 88.2 µs, 590.9 M/s | 69.6 µs, 748.8 M/s | 0.79 | 10.8% / 8.3% |
| nav_test.obj | 120.2 k spans | 127.6 µs, 942.0 M/s | 108.7 µs, 1.11 G/s | 0.85 | 5.1% / 10.7% |
| undulating.obj | 108.7 k spans | 102.7 µs, 1.06 G/s | 87.4 µs, 1.24 G/s | 0.85 | 6.8% / 21.9% |
| terrain 256 m | 741.4 k spans | 604.1 µs, 1.23 G/s | 513.4 µs, 1.44 G/s | 0.85 | 35.6% / 42.3% |
| terrain 256 m, 64 m tiles | 4.41 M spans | 3.92 ms, 1.12 G/s | 2.75 ms, 1.60 G/s | 0.70 | 3.7% / 14.0% |
| vale 256 m, 64 m tiles | 4.34 M spans | 3.88 ms, 1.12 G/s | 2.81 ms, 1.55 G/s | 0.72 | 7.6% / 15.4% |

#### Ledge filter

`rcFilterLedgeSpans` and `filterLedgeSpans`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 420.7 µs, 123.8 M/s | 398.9 µs, 130.6 M/s | 0.95 | 5.0% / 4.6% |
| nav_test.obj | 120.2 k spans | 954.5 µs, 125.9 M/s | 864.3 µs, 139.0 M/s | 0.91 | 3.8% / 3.4% |
| undulating.obj | 108.7 k spans | 889.6 µs, 122.2 M/s | 796.2 µs, 136.5 M/s | 0.90 | 5.9% / 13.5% |
| terrain 256 m | 741.4 k spans | 5.58 ms, 132.9 M/s | 4.91 ms, 151.1 M/s | 0.88 | 1.8% / 2.5% |
| terrain 256 m, 64 m tiles | 4.41 M spans | 33.78 ms, 130.5 M/s | 30.40 ms, 145.0 M/s | 0.90 | 0.7% / 4.0% |
| vale 256 m, 64 m tiles | 4.34 M spans | 34.12 ms, 127.3 M/s | 30.59 ms, 142.0 M/s | 0.90 | 2.6% / 1.8% |

#### Low height filter

`rcFilterWalkableLowHeightSpans` and `filterWalkableLowHeightSpans`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 92.0 µs, 566.2 M/s | 68.8 µs, 757.8 M/s | 0.75 | 16.0% / 15.9% |
| nav_test.obj | 120.2 k spans | 137.8 µs, 872.4 M/s | 118.1 µs, 1.02 G/s | 0.86 | 9.7% / 10.6% |
| undulating.obj | 108.7 k spans | 124.1 µs, 875.8 M/s | 84.9 µs, 1.28 G/s | 0.68 | 3.5% / 15.5% |
| terrain 256 m | 741.4 k spans | 628.8 µs, 1.18 G/s | 431.0 µs, 1.72 G/s | 0.69 | 4.6% / 19.3% |
| terrain 256 m, 64 m tiles | 4.41 M spans | 4.05 ms, 1.09 G/s | 2.61 ms, 1.69 G/s | 0.64 | 6.3% / 13.6% |
| vale 256 m, 64 m tiles | 4.34 M spans | 4.06 ms, 1.07 G/s | 2.73 ms, 1.59 G/s | 0.67 | 6.9% / 65.8% |

#### Compact heightfield

`rcBuildCompactHeightfield` and `buildCompactHeightfield`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 363.1 µs, 143.5 M/s | 495.0 µs, 105.3 M/s | 1.36 | 5.2% / 3.1% |
| nav_test.obj | 120.2 k spans | 701.5 µs, 171.3 M/s | 1.05 ms, 114.1 M/s | 1.50 | 2.2% / 2.6% |
| undulating.obj | 108.7 k spans | 1.03 ms, 105.4 M/s | 1.69 ms, 64.2 M/s | 1.64 | 4.3% / 6.7% |
| terrain 256 m | 741.4 k spans | 6.38 ms, 116.3 M/s | 10.60 ms, 69.9 M/s | 1.66 | 2.9% / 2.7% |
| terrain 256 m, 64 m tiles | 4.41 M spans | 37.83 ms, 116.5 M/s | 63.49 ms, 69.4 M/s | 1.68 | 2.0% / 4.2% |
| vale 256 m, 64 m tiles | 4.34 M spans | 39.30 ms, 110.5 M/s | 66.14 ms, 65.7 M/s | 1.68 | 3.4% / 1.9% |

#### Erosion

`rcErodeWalkableArea` and `erodeWalkableArea`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 364.5 µs, 64.7 M/s | 364.6 µs, 64.6 M/s | 1.00 | 8.5% / 5.9% |
| nav_test.obj | 56.8 k compact spans | 688.6 µs, 82.5 M/s | 708.1 µs, 80.2 M/s | 1.03 | 9.5% / 4.2% |
| undulating.obj | 105.8 k compact spans | 1.04 ms, 102.2 M/s | 1.06 ms, 99.9 M/s | 1.02 | 7.8% / 5.6% |
| terrain 256 m | 686.7 k compact spans | 6.70 ms, 102.5 M/s | 6.88 ms, 99.8 M/s | 1.03 | 2.2% / 1.8% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 35.85 ms, 114.2 M/s | 36.29 ms, 112.8 M/s | 1.01 | 1.4% / 4.5% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 33.16 ms, 130.0 M/s | 34.36 ms, 125.4 M/s | 1.04 | 3.5% / 2.1% |

#### Distance field

`rcBuildDistanceField` and `buildDistanceField`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 393.2 µs, 59.9 M/s | 507.0 µs, 46.5 M/s | 1.29 | 3.4% / 5.6% |
| nav_test.obj | 56.8 k compact spans | 743.2 µs, 76.4 M/s | 959.1 µs, 59.2 M/s | 1.29 | 25.6% / 9.1% |
| undulating.obj | 105.8 k compact spans | 1.18 ms, 90.0 M/s | 1.59 ms, 66.4 M/s | 1.36 | 2.8% / 4.8% |
| terrain 256 m | 686.7 k compact spans | 7.62 ms, 90.1 M/s | 10.32 ms, 66.5 M/s | 1.36 | 1.6% / 1.8% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 40.99 ms, 99.9 M/s | 56.84 ms, 72.0 M/s | 1.39 | 2.3% / 4.8% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 40.36 ms, 106.8 M/s | 56.96 ms, 75.7 M/s | 1.41 | 6.7% / 2.6% |

#### Watershed regions

`rcBuildRegions` and `buildRegions`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 1.01 ms, 23.3 M/s | 716.1 µs, 32.9 M/s | 0.71 | 3.1% / 10.0% |
| nav_test.obj | 56.8 k compact spans | 2.53 ms, 22.4 M/s | 1.52 ms, 37.4 M/s | 0.60 | 2.6% / 10.3% |
| undulating.obj | 105.8 k compact spans | 5.12 ms, 20.7 M/s | 2.96 ms, 35.7 M/s | 0.58 | 6.9% / 6.8% |
| terrain 256 m | 686.7 k compact spans | 38.04 ms, 18.1 M/s | 21.90 ms, 31.4 M/s | 0.58 | 3.2% / 4.2% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 202.20 ms, 20.3 M/s | 120.20 ms, 34.1 M/s | 0.59 | 2.7% / 6.3% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 212.37 ms, 20.3 M/s | 166.54 ms, 25.9 M/s | 0.78 | 6.1% / 8.8% |

#### Contours

`rcBuildContours` and `buildContours`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 229.9 µs, 102.5 M/s | 219.0 µs, 107.6 M/s | 0.95 | 2.4% / 11.9% |
| nav_test.obj | 56.8 k compact spans | 420.4 µs, 135.1 M/s | 406.8 µs, 139.6 M/s | 0.97 | 5.3% / 5.6% |
| undulating.obj | 105.8 k compact spans | 622.1 µs, 170.1 M/s | 627.6 µs, 168.6 M/s | 1.01 | 4.2% / 12.6% |
| terrain 256 m | 686.7 k compact spans | 4.67 ms, 147.1 M/s | 4.52 ms, 151.8 M/s | 0.97 | 2.9% / 2.0% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 19.57 ms, 209.2 M/s | 20.76 ms, 197.3 M/s | 1.06 | 1.1% / 1.0% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 15.39 ms, 280.1 M/s | 18.12 ms, 237.9 M/s | 1.18 | 2.6% / 2.4% |

#### Polygon mesh

`rcBuildPolyMesh` and `buildPolyMesh`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 118 polygons | 200.9 µs, 587.4 k/s | 217.2 µs, 543.3 k/s | 1.08 | 2.0% / 2.8% |
| nav_test.obj | 155 polygons | 174.1 µs, 890.5 k/s | 196.3 µs, 789.5 k/s | 1.13 | 4.2% / 24.9% |
| undulating.obj | 216 polygons | 348.1 µs, 620.5 k/s | 390.1 µs, 553.7 k/s | 1.12 | 9.2% / 26.9% |
| terrain 256 m | 2580 polygons | 5.90 ms, 437.3 k/s | 6.49 ms, 397.8 k/s | 1.10 | 2.3% / 3.8% |
| terrain 256 m, 64 m tiles | 4098 polygons | 11.46 ms, 357.7 k/s | 12.25 ms, 334.4 k/s | 1.07 | 0.9% / 1.1% |
| vale 256 m, 64 m tiles | 108 polygons | 122.9 µs, 878.8 k/s | 138.3 µs, 780.8 k/s | 1.13 | 17.2% / 32.0% |

#### Detail mesh

`rcBuildPolyMeshDetail` and `buildPolyMeshDetail`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 118 polygons | 374.2 µs, 315.3 k/s | 316.5 µs, 372.8 k/s | 0.85 | 3.0% / 3.2% |
| nav_test.obj | 155 polygons | 1.14 ms, 135.7 k/s | 1.02 ms, 152.6 k/s | 0.89 | 2.3% / 4.2% |
| undulating.obj | 216 polygons | 43.19 ms, 5.0 k/s | 41.86 ms, 5.2 k/s | 0.97 | 3.2% / 4.3% |
| terrain 256 m | 2580 polygons | 35.93 ms, 71.8 k/s | 32.88 ms, 78.5 k/s | 0.91 | 2.1% / 2.9% |
| terrain 256 m, 64 m tiles | 4098 polygons | 75.54 ms, 54.3 k/s | 56.78 ms, 72.2 k/s | 0.75 | 1.3% / 1.1% |
| vale 256 m, 64 m tiles | 108 polygons | 590.93 ms, 0.2 k/s | 560.06 ms, 0.2 k/s | 0.95 | 1.9% / 2.9% |

#### Span count

`rcGetHeightFieldSpanCount` and `getHeightFieldSpanCount`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 54.3 µs, 959.0 M/s | 49.2 µs, 1.06 G/s | 0.91 | 14.9% / 3.7% |
| nav_test.obj | 120.2 k spans | 82.7 µs, 1.45 G/s | 82.2 µs, 1.46 G/s | 0.99 | 6.8% / 11.5% |
| undulating.obj | 108.7 k spans | 57.0 µs, 1.91 G/s | 50.5 µs, 2.15 G/s | 0.89 | 307.3% / 8.5% |
| terrain 256 m | 741.4 k spans | 580.7 µs, 1.28 G/s | 358.9 µs, 2.07 G/s | 0.62 | 90.6% / 114.1% |
| terrain 256 m, 64 m tiles | 4.41 M spans | 1.87 ms, 2.36 G/s | 1.85 ms, 2.38 G/s | 0.99 | 31.6% / 16.6% |
| vale 256 m, 64 m tiles | 4.34 M spans | 2.16 ms, 2.01 G/s | 2.07 ms, 2.10 G/s | 0.96 | 143.8% / 41.5% |

#### Unwalkable triangles

`rcClearUnwalkableTriangles` and `clearUnwalkableTriangles`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 56.3 µs, 180.0 M/s | 58.9 µs, 172.2 M/s | 1.05 | 5.7% / 6.8% |
| nav_test.obj | 1612 triangles | 3.7 µs, 439.6 M/s | 3.7 µs, 437.2 M/s | 1.01 | 14.5% / 8.4% |
| undulating.obj | 5202 triangles | 8.9 µs, 583.4 M/s | 9.0 µs, 575.6 M/s | 1.01 | 5.0% / 9.7% |
| terrain 256 m | 130.1 k triangles | 220.3 µs, 590.7 M/s | 212.0 µs, 613.7 M/s | 0.96 | 16.9% / 4.5% |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 234.1 µs, 582.4 M/s | 230.4 µs, 591.5 M/s | 0.98 | 4.0% / 12.5% |
| vale 256 m, 64 m tiles | 137.3 k triangles | 225.2 µs, 609.6 M/s | 217.8 µs, 630.4 M/s | 0.97 | 21.8% / 17.4% |

#### Rasterization, unsigned short indices

`rcRasterizeTriangles` and `rasterizeTriangles`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.54 ms, 2.2 M/s | 4.34 ms, 2.3 M/s | 0.95 | 0.8% / 0.6% |
| nav_test.obj | 1612 triangles | 3.20 ms, 503.5 k/s | 2.96 ms, 544.9 k/s | 0.92 | 4.7% / 5.2% |
| undulating.obj | 5202 triangles | 3.74 ms, 1.4 M/s | 3.56 ms, 1.5 M/s | 0.95 | 4.8% / 9.1% |

#### Rasterization, unindexed

`rcRasterizeTriangles` and `rasterizeUnindexedTriangles`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.46 ms, 2.3 M/s | 4.24 ms, 2.4 M/s | 0.95 | 0.6% / 1.0% |
| nav_test.obj | 1612 triangles | 3.07 ms, 525.7 k/s | 2.83 ms, 569.2 k/s | 0.92 | 57.3% / 8.7% |
| undulating.obj | 5202 triangles | 3.62 ms, 1.4 M/s | 3.42 ms, 1.5 M/s | 0.94 | 3.3% / 5.9% |
| terrain 256 m | 130.1 k triangles | 32.69 ms, 4.0 M/s | 30.65 ms, 4.2 M/s | 0.94 | 3.6% / 2.7% |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 90.50 ms, 1.5 M/s | 80.61 ms, 1.7 M/s | 0.89 | 2.4% / 1.1% |
| vale 256 m, 64 m tiles | 137.3 k triangles | 88.81 ms, 1.5 M/s | 78.34 ms, 1.8 M/s | 0.88 | 4.8% / 7.1% |

#### Rasterization, one triangle at a time

`rcRasterizeTriangle` and `rasterizeTriangle`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.48 ms, 2.3 M/s | 4.26 ms, 2.4 M/s | 0.95 | 0.9% / 1.8% |
| nav_test.obj | 1612 triangles | 3.07 ms, 525.7 k/s | 2.83 ms, 570.0 k/s | 0.92 | 67.4% / 7.1% |
| undulating.obj | 5202 triangles | 3.62 ms, 1.4 M/s | 3.43 ms, 1.5 M/s | 0.95 | 4.0% / 3.4% |
| terrain 256 m | 130.1 k triangles | 32.08 ms, 4.1 M/s | 29.71 ms, 4.4 M/s | 0.93 | 3.2% / 2.0% |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 90.59 ms, 1.5 M/s | 80.70 ms, 1.7 M/s | 0.89 | 1.0% / 1.7% |
| vale 256 m, 64 m tiles | 137.3 k triangles | 89.68 ms, 1.5 M/s | 78.92 ms, 1.7 M/s | 0.88 | 4.1% / 7.8% |

#### Adding spans, the rasterized field's again

`rcAddSpan` and `addSpan`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 297.2 µs, 175.3 M/s | 219.6 µs, 237.3 M/s | 0.74 | 5.4% / 55.0% |
| nav_test.obj | 120.2 k spans | 666.4 µs, 180.3 M/s | 492.9 µs, 243.8 M/s | 0.74 | 80.8% / 15.7% |
| undulating.obj | 108.7 k spans | 551.4 µs, 197.2 M/s | 376.4 µs, 288.8 M/s | 0.68 | 19.9% / 21.5% |
| terrain 256 m | 741.4 k spans | 4.12 ms, 179.8 M/s | 3.02 ms, 245.3 M/s | 0.73 | 10.2% / 15.4% |
| terrain 256 m, 64 m tiles | 4.41 M spans | 17.09 ms, 257.9 M/s | 10.09 ms, 437.0 M/s | 0.59 | 2.5% / 3.9% |
| vale 256 m, 64 m tiles | 4.34 M spans | 16.95 ms, 256.3 M/s | 10.08 ms, 431.0 M/s | 0.59 | 10.1% / 15.0% |

#### Polygon mesh copy

`rcCopyPolyMesh` and `copyPolyMesh`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 118 polygons | 27.8 µs, 4.3 M/s | 27.9 µs, 4.2 M/s | 1.00 | 22.7% / 61.5% |
| nav_test.obj | 155 polygons | 49.9 µs, 3.1 M/s | 49.9 µs, 3.1 M/s | 1.00 | 75.6% / 18.4% |
| undulating.obj | 216 polygons | 50.1 µs, 4.3 M/s | 49.3 µs, 4.4 M/s | 0.98 | 141.7% / 103.5% |
| terrain 256 m | 2580 polygons | 472.1 µs, 5.5 M/s | 502.1 µs, 5.1 M/s | 1.06 | 113.8% / 113.8% |
| terrain 256 m, 64 m tiles | 4098 polygons | 30.2 µs, 135.8 M/s | 27.4 µs, 149.4 M/s | 0.91 | 21.0% / 16.1% |
| vale 256 m, 64 m tiles | 108 polygons | 28.3 µs, 3.8 M/s | 26.9 µs, 4.0 M/s | 0.95 | 40.5% / 26.1% |

#### Heightfield layers

`rcBuildHeightfieldLayers` and `buildHeightfieldLayers`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 582.7 µs, 40.5 M/s | 550.4 µs, 42.8 M/s | 0.94 | 5.2% / 34.5% |
| nav_test.obj | 56.8 k compact spans | 1.07 ms, 53.3 M/s | 1.04 ms, 54.6 M/s | 0.98 | 64.9% / 20.7% |
| undulating.obj | 105.8 k compact spans | 1.54 ms, 68.8 M/s | 1.49 ms, 71.0 M/s | 0.97 | 16.0% / 5.1% |
| terrain 256 m | 686.7 k compact spans | fails | fails | | |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 54.81 ms, 74.7 M/s | 53.43 ms, 76.6 M/s | 0.97 | 3.3% / 2.5% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 51.41 ms, 83.8 M/s | 55.32 ms, 77.9 M/s | 1.08 | 1.8% / 11.7% |

#### Monotone regions

`rcBuildRegionsMonotone` and `buildRegionsMonotone`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 323.5 µs, 72.9 M/s | 269.2 µs, 87.6 M/s | 0.83 | 6.0% / 19.0% |
| nav_test.obj | 56.8 k compact spans | 660.1 µs, 86.0 M/s | 528.5 µs, 107.5 M/s | 0.80 | 59.9% / 20.9% |
| undulating.obj | 105.8 k compact spans | 978.6 µs, 108.1 M/s | 790.7 µs, 133.8 M/s | 0.81 | 13.3% / 2.7% |
| terrain 256 m | 686.7 k compact spans | 21.46 ms, 32.0 M/s | 8.03 ms, 85.5 M/s | 0.37 | 2.4% / 17.7% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 33.27 ms, 123.1 M/s | 26.41 ms, 155.0 M/s | 0.79 | 3.4% / 3.0% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 28.43 ms, 151.6 M/s | 23.65 ms, 182.3 M/s | 0.83 | 2.1% / 5.5% |

#### Layer regions

`rcBuildLayerRegions` and `buildLayerRegions`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 376.7 µs, 62.6 M/s | 367.7 µs, 64.1 M/s | 0.98 | 4.0% / 5.4% |
| nav_test.obj | 56.8 k compact spans | 798.7 µs, 71.1 M/s | 771.2 µs, 73.6 M/s | 0.97 | 8.8% / 8.5% |
| undulating.obj | 105.8 k compact spans | 1.22 ms, 86.7 M/s | 1.29 ms, 82.1 M/s | 1.06 | 3.9% / 2.3% |
| terrain 256 m | 686.7 k compact spans | 8.68 ms, 79.1 M/s | 8.66 ms, 79.3 M/s | 1.00 | 2.5% / 2.7% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 45.95 ms, 89.1 M/s | 48.10 ms, 85.1 M/s | 1.05 | 5.0% / 0.8% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 45.09 ms, 95.6 M/s | 49.85 ms, 86.5 M/s | 1.11 | 2.1% / 3.3% |

#### Median area filter

`rcMedianFilterWalkableArea` and `medianFilterWalkableArea`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 162.4 µs, 145.1 M/s | 169.1 µs, 139.3 M/s | 1.04 | 11.2% / 2.4% |
| nav_test.obj | 56.8 k compact spans | 357.1 µs, 159.0 M/s | 360.3 µs, 157.7 M/s | 1.01 | 16.4% / 6.1% |
| undulating.obj | 105.8 k compact spans | 660.3 µs, 160.2 M/s | 658.1 µs, 160.8 M/s | 1.00 | 10.1% / 42.4% |
| terrain 256 m | 686.7 k compact spans | 4.25 ms, 161.4 M/s | 4.27 ms, 160.8 M/s | 1.00 | 3.0% / 2.7% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 25.05 ms, 163.5 M/s | 24.96 ms, 164.0 M/s | 1.00 | 5.5% / 0.6% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 26.88 ms, 160.3 M/s | 26.76 ms, 161.1 M/s | 1.00 | 1.9% / 3.1% |

#### Box area

`rcMarkBoxArea` and `markBoxArea`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 14.1 µs, 1.67 G/s | 13.9 µs, 1.70 G/s | 0.99 | 11.8% / 3.8% |
| nav_test.obj | 56.8 k compact spans | 27.1 µs, 2.10 G/s | 27.4 µs, 2.08 G/s | 1.01 | 10.8% / 19.5% |
| undulating.obj | 105.8 k compact spans | 26.9 µs, 3.93 G/s | 28.6 µs, 3.69 G/s | 1.06 | 11.4% / 77.2% |
| terrain 256 m | 686.7 k compact spans | 169.1 µs, 4.06 G/s | 175.5 µs, 3.91 G/s | 1.04 | 16.6% / 9.9% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 879.8 µs, 4.65 G/s | 947.3 µs, 4.32 G/s | 1.08 | 6.4% / 3.8% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 789.2 µs, 5.46 G/s | 889.8 µs, 4.84 G/s | 1.13 | 5.4% / 5.9% |

#### Convex area

`rcMarkConvexPolyArea` and `markConvexPolyArea`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 23.9 µs, 985.9 M/s | 20.0 µs, 1.18 G/s | 0.84 | 8.5% / 5.3% |
| nav_test.obj | 56.8 k compact spans | 61.6 µs, 922.2 M/s | 48.7 µs, 1.17 G/s | 0.79 | 27.6% / 6.5% |
| undulating.obj | 105.8 k compact spans | 103.1 µs, 1.03 G/s | 83.3 µs, 1.27 G/s | 0.81 | 9.5% / 48.8% |
| terrain 256 m | 686.7 k compact spans | 664.4 µs, 1.03 G/s | 520.4 µs, 1.32 G/s | 0.78 | 8.4% / 2.8% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 4.04 ms, 1.01 G/s | 3.22 ms, 1.27 G/s | 0.80 | 4.8% / 1.3% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 4.20 ms, 1.03 G/s | 3.32 ms, 1.30 G/s | 0.79 | 5.0% / 2.2% |

#### Cylinder area

`rcMarkCylinderArea` and `markCylinderArea`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 23.0 µs, 1.02 G/s | 23.2 µs, 1.02 G/s | 1.01 | 24.0% / 3.5% |
| nav_test.obj | 56.8 k compact spans | 28.2 µs, 2.01 G/s | 30.6 µs, 1.86 G/s | 1.09 | 7.0% / 9.0% |
| undulating.obj | 105.8 k compact spans | 42.4 µs, 2.49 G/s | 39.2 µs, 2.70 G/s | 0.92 | 50.1% / 52.3% |
| terrain 256 m | 686.7 k compact spans | 222.4 µs, 3.09 G/s | 235.6 µs, 2.91 G/s | 1.06 | 5.6% / 6.2% |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 1.29 ms, 3.16 G/s | 1.36 ms, 3.02 G/s | 1.05 | 5.6% / 1.6% |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 1.20 ms, 3.59 G/s | 1.28 ms, 3.36 G/s | 1.07 | 2.8% / 2.8% |

#### Polygon mesh merge, every tile

`rcMergePolyMeshes` and `mergePolyMeshes`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| terrain 256 m, 64 m tiles | 4098 polygons | 261.3 µs, 15.7 M/s | 264.7 µs, 15.5 M/s | 1.01 | 5.5% / 4.1% |
| vale 256 m, 64 m tiles | 108 polygons | 11.2 µs, 9.6 M/s | 10.8 µs, 10.0 M/s | 0.96 | 36.7% / 31.1% |

#### Detail mesh merge, every tile

`rcMergePolyMeshDetails` and `mergePolyMeshDetails`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| terrain 256 m, 64 m tiles | 4098 polygons | 50.0 µs, 82.0 M/s | 24.4 µs, 168.2 M/s | 0.49 | 65.0% / 70.7% |
| vale 256 m, 64 m tiles | 108 polygons | 13.5 µs, 8.0 M/s | 6.9 µs, 15.7 M/s | 0.51 | 31.3% / 72.2% |

#### Bounds

`rcCalcBounds` and `calcBounds`.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 5101 vertices | 10.5 µs, 484.4 M/s | 2.9 µs, 1.79 G/s | 0.27 | 1.7% / 1.4% |
| nav_test.obj | 884 vertices | 1.9 µs, 466.7 M/s | 0.5 µs, 1.70 G/s | 0.28 | 31.7% / 19.4% |
| undulating.obj | 2800 vertices | 6.0 µs, 468.9 M/s | 1.6 µs, 1.76 G/s | 0.27 | 43.1% / 3.1% |
| terrain 256 m | 66.8 k vertices | 141.4 µs, 472.6 M/s | 37.4 µs, 1.79 G/s | 0.26 | 3.7% / 2.2% |
| terrain 256 m, 64 m tiles | 66.8 k vertices | 140.5 µs, 475.5 M/s | 37.5 µs, 1.78 G/s | 0.27 | 4.4% / 8.5% |
| vale 256 m, 64 m tiles | 66.0 k vertices | 138.0 µs, 478.6 M/s | 37.1 µs, 1.78 G/s | 0.27 | 2.7% / 7.4% |

#### Grid size

`rcCalcGridSize` and `calcGridSize`, per call.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.0 k calls | 1.1 ns | 1.3 ns | 1.13 | 1.2% / 14.4% |
| nav_test.obj | 10.0 k calls | 1.1 ns | 1.3 ns | 1.12 | 21.3% / 1.7% |
| undulating.obj | 10.0 k calls | 1.1 ns | 1.3 ns | 1.13 | 4.7% / 7.3% |
| terrain 256 m | 10.0 k calls | 1.2 ns | 1.3 ns | 1.12 | 4.2% / 2.6% |
| terrain 256 m, 64 m tiles | 10.0 k calls | 1.1 ns | 1.3 ns | 1.13 | 14.1% / 18.7% |
| vale 256 m, 64 m tiles | 10.0 k calls | 1.1 ns | 1.3 ns | 1.14 | 4.1% / 85.6% |

#### Polygon offset, a hexagon

`rcOffsetPoly` and `offsetPoly`, per call.

| input | work | original | port | port ÷ original | spread, original / port |
| --- | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.0 k calls | 34.8 ns | 26.5 ns | 0.76 | 2.4% / 5.6% |
| nav_test.obj | 10.0 k calls | 34.8 ns | 26.7 ns | 0.77 | 1.8% / 6.3% |
| undulating.obj | 10.0 k calls | 35.0 ns | 27.0 ns | 0.77 | 7.5% / 1.8% |
| terrain 256 m | 10.0 k calls | 35.3 ns | 26.9 ns | 0.76 | 4.7% / 2.5% |
| terrain 256 m, 64 m tiles | 10.0 k calls | 35.2 ns | 26.9 ns | 0.77 | 3.1% / 2.5% |
| vale 256 m, 64 m tiles | 10.0 k calls | 35.4 ns | 27.0 ns | 0.76 | 2.8% / 5.6% |
exit 0

## Licence and credits

zlib licence ([`LICENSE`](LICENSE)), the original's.

Translated from Recast in
[recastnavigation](https://github.com/recastnavigation/recastnavigation)
1.6.0, by Mikko Mononen and the recastnavigation contributors. This is an
altered version: the code is rewritten in Zig with its own interface.

Made by Farhollow Games for the Loomwork Engine.
