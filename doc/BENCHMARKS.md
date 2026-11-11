# Benchmarks

These are measurements on one machine, under the conditions below. They
are not a verdict on either side.

`zig build bench` times the port against the original on the same inputs,
one feature at a time, on one thread, and prints a table for each feature.
The tables below are its output, from this command:

```sh
zig build bench -- --runs 7 --warmup 1 --cpu 2
```

`--runs` sets the number of timed runs (7 by default) and `--warmup` the
runs before them (1). `--cpu` pins the benchmark to one CPU, and
`--only <text>` keeps the inputs whose name holds the text.

## Machine and flags

Measured on 11 November 2026, at commit `0c37e46`, on an AMD Ryzen 9
9950X3D (16 cores) under Linux 7.3.3 (CachyOS), pinned to CPU 2, one of the
eight with the stacked cache. The one-minute load average was 1.4 to 3.2
during the runs, on 32 hardware threads.

- **The port:** Zig 0.17.0, ReleaseFast, for the machine's own CPU
  (`znver5`).
- **The original:** recastnavigation 1.6.0 (`9f4ce64`), built from source
  by the clang that Zig 0.17.0 carries (22.1.8), for the same CPU, at `-O3
  -std=c++11 -fno-exceptions -fno-rtti -fno-threadsafe-statics
  -ffp-contract=off -fno-fast-math -fno-sanitize=undefined`, with `NDEBUG`,
  and linked statically. Zig's own flags for the build put `-O2` first; the
  `-O3` after them is the one that applies, as `--verbose-cc` shows.
- **Both:** frame pointers kept, and no fused multiply-adds, which the
  tests need for equal outputs.

Earlier figures were taken at commit `0e9beae`. Run beside it on the same
quiet machine, `0c37e46` is slower on some rows, and the change is the one
that refuses polygons of more than 127 vertices in the detail mesh: the
detail mesh on the tiled terrain went from 0.55 to 0.67, the watershed on
the 256 m rolling ground from 0.72 to between 0.78 and 0.89, and grid size
from 1.09 to 1.17. The check that change adds runs only when `nvp` is past
127, which no input here has, and the watershed and grid size code did not
change, so the cost is in how the benchmark compiles since then (code
layout), not in work added to a timed loop.

## Method

- Each run builds every input on both sides. The two sides take turns tile
  by tile, and the side that goes first changes every run.
- Each step is timed by the monotonic clock, as wall time. A feature's time
  in a run is its sum over the input's tiles.
- Each figure is the median of 7 timed runs after 1 warm-up. The spread is
  the range of the runs, slowest less fastest, as a share of the median.
- Every result goes through `std.mem.doNotOptimizeAway`, so the compiler
  cannot drop the work.
- Neither side logs or times: the port's context is `.none`, and the
  original's has its log and timers switched off.
- The benchmark ran three times. Each row is from the run with the median
  ratio, and the last column gives the three runs' ratios, lowest to
  highest.
- The ratio is the port's median divided by the original's: below 1, the
  port takes less time.

The work column counts what a feature goes through (triangles, cells,
spans, polygons or calls), and each time is followed by that count per
second.

## Inputs

RecastDemo's three meshes (`dungeon.obj`, `nav_test.obj` and
`undulating.obj`) and a 256 m generated terrain, each built whole with
RecastDemo's defaults; and that terrain and a rolling ground (`vale`) of
256 m and of 1 km, built in 64 m tiles with Loomwork's navmesh settings
(125 mm cells, an agent 1.8 m tall and 0.35 m wide).

Most features run on all seven inputs. 16-bit indices fit only RecastDemo's
meshes, and the merges run on the tiled inputs. The heightfield layers fail
on both sides on the whole 256 m terrain, as its regions overflow their
8-bit ids, so that row has six inputs.

## Known biases

- **Inlining.** The port is compiled into the benchmark, so the compiler
  can inline its functions into the timing code. The original is a library
  built on its own and reached through the shim's C functions, one call
  more per step. Calling the distance field out of line
  (`@call(.never_inline, …)`) gave the same time. On the two rows timed
  per call (grid size, polygon offset), that call is a sizeable part of
  the original's time.
- **The slope's cosine.** Linked statically, the original's `cosf` binds to
  compiler_rt's, not to glibc's as in the tests. It runs once per call of
  the slope functions, and at the benchmark's slopes (45 and 50 degrees)
  the two give the same threshold.
- **Allocation.** Both sides allocate through the C library's `malloc`:
  the original through its default allocator, the port through
  `std.heap.c_allocator`.
- **No fused multiply-adds.** Clang's default would fuse a multiply and an
  add within an expression on this CPU. That changes the original's output,
  and its speed by an amount not measured here.
- **Wall time.** Time that another process takes from the CPU counts for
  whichever side is running; the turns tile by tile spread it over both.
  Short, memory-bound features (the span count, the span filters, creating
  the heightfield) move the most from run to run, so theirs are the least
  certain figures, as their spreads show.
- One machine, one core, these inputs.

## Summary

The port's median time divided by the original's, the lowest and the
highest over the inputs a feature runs on (below 1, the port takes less
time).

| feature | port ÷ original |
| --- | ---: |
| Whole build | 0.37 to 0.91 |
| Heightfield | 0.97 to 1.00 |
| Walkable triangles | 0.92 to 1.04 |
| Rasterization, int indices | 0.90 to 0.95 |
| Low hanging obstacles filter | 0.63 to 0.86 |
| Ledge filter | 0.87 to 0.92 |
| Low height filter | 0.76 to 0.89 |
| Compact heightfield | 0.87 to 0.91 |
| Erosion | 0.96 to 0.99 |
| Distance field | 1.09 to 1.31 |
| Watershed regions | 0.58 to 0.89 |
| Contours | 0.85 to 1.06 |
| Polygon mesh | 0.87 to 0.97 |
| Detail mesh | 0.09 to 0.83 |
| Span count | 0.84 to 1.05 |
| Unwalkable triangles | 0.88 to 1.01 |
| Rasterization, unsigned short indices | 0.92 to 0.95 |
| Rasterization, unindexed | 0.90 to 0.95 |
| Rasterization, one triangle at a time | 0.89 to 0.94 |
| Adding spans, the rasterized field's again | 0.59 to 0.74 |
| Polygon mesh copy | 0.85 to 1.02 |
| Heightfield layers | 0.94 to 0.98 |
| Monotone regions | 0.39 to 0.89 |
| Layer regions | 0.91 to 0.98 |
| Median area filter | 1.00 to 1.02 |
| Box area | 0.81 to 0.94 |
| Convex area | 0.83 to 0.87 |
| Cylinder area | 0.79 to 0.85 |
| Polygon mesh merge, every tile | 1.03 to 1.09 |
| Detail mesh merge, every tile | 0.44 to 0.55 |
| Bounds | 0.27 to 0.29 |
| Grid size | 1.16 to 1.20 |
| Polygon offset, a hexagon | 0.76 to 0.77 |

## Where the port is faster

- **Detail mesh, 0.09 to 0.83 times.** Where the original measures each
  sample against each triangle in turn, the port measures a vector of
  samples at a time against a triangle (`@Vector`, as wide as the CPU's),
  with what depends only on the triangle worked out once. It finds a
  triangulation's edges in a table indexed by their two vertices, where the
  original searches every edge, and it works out once per span whether the
  span borders its region, where the original redoes that for every
  polygon whose patch covers the span. The more samples a polygon takes,
  the more this gains: on the rolling ground, whose polygons take up to
  119 detail vertices, the port is eight to eleven times as fast.
- **Compact heightfield, 0.87 to 0.91 times.** The port builds a span's
  four connections in a register and stores the span once.
- **Loops that store to bytes.** Zig has no type-based aliasing, so through
  the heightfield's pointer each store to a distance, flag or area makes a
  loop load the field's slices again, as the original's stores to bytes do
  in C++. Erosion, contours and the box and cylinder marks read the field
  through local slices instead.

## Where the port is slower

- **Distance field, 1.09 to 1.31 times**, the larger the field the slower.
  Each of its four passes (marking the borders, the two sweeps and the
  blur) takes 20 to 30% longer in samples of the rolling ground's build,
  though their loops compile to nearly the original's instructions. The
  one difference found is that the port keeps the four neighbours' cell
  indices on the stack, where the original addresses them from a row
  pointer; whether that is the cause is not known.
- **Grid size, 1.16 to 1.20 times**, about 0.2 ns a call: the port checks
  the range before converting a float to an int, so that out-of-range
  values give x86-64's result on every machine, where the original's
  `(int)` is one instruction.
- **Contours on the rolling ground, 1.05 and 1.06 times**; 0.85 to 0.99
  on the other inputs.
- **Polygon mesh merge on the 256 m rolling ground, 1.09 times**, of 9 µs;
  1.03 on the other two inputs.

Every other feature is within 6% of the original on every input, or
faster; differences of a few percent are within the spread of the runs.

## Every feature

### Whole build

Every step of a navmesh build, in Loomwork's order.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 8.12 ms, 1.2 M/s | 7.42 ms, 1.4 M/s | 0.91 | 1.1% / 1.5% | 0.91 to 0.92 |
| nav_test.obj | 1612 triangles | 10.67 ms, 151.0 k/s | 8.82 ms, 182.8 k/s | 0.83 | 0.4% / 0.9% | 0.83 to 0.83 |
| undulating.obj | 5202 triangles | 57.68 ms, 90.2 k/s | 22.82 ms, 228.0 k/s | 0.40 | 1.1% / 2.6% | 0.40 to 0.40 |
| terrain 256 m | 130.1 k triangles | 141.72 ms, 918.0 k/s | 103.93 ms, 1.3 M/s | 0.73 | 0.5% / 0.9% | 0.73 to 0.73 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 546.42 ms, 249.5 k/s | 437.08 ms, 311.9 k/s | 0.80 | 0.2% / 1.1% | 0.80 to 0.80 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 1032.74 ms, 132.9 k/s | 480.27 ms, 285.9 k/s | 0.47 | 0.6% / 1.5% | 0.47 to 0.47 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 22100.61 ms, 100.5 k/s | 8281.00 ms, 268.3 k/s | 0.37 | 1.9% / 2.4% | 0.37 to 0.38 |

### Heightfield

`rcCreateHeightfield` and `Heightfield.init`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 81.8 k cells | 4.5 µs, 18.36 G/s | 4.4 µs, 18.56 G/s | 0.99 | 3.4% / 15.2% | 0.98 to 1.00 |
| nav_test.obj | 78.7 k cells | 4.4 µs, 17.89 G/s | 4.3 µs, 18.35 G/s | 0.97 | 13.2% / 25.5% | 0.97 to 0.99 |
| undulating.obj | 109.2 k cells | 5.8 µs, 18.89 G/s | 5.7 µs, 19.13 G/s | 0.99 | 3.3% / 6.8% | 0.98 to 1.05 |
| terrain 256 m | 727.6 k cells | 43.7 µs, 16.65 G/s | 42.3 µs, 17.20 G/s | 0.97 | 28.3% / 102.0% | 0.96 to 1.02 |
| terrain 256 m, 64 m tiles | 4.39 M cells | 270.6 µs, 16.23 G/s | 265.9 µs, 16.52 G/s | 0.98 | 14.3% / 15.6% | 0.93 to 0.99 |
| vale 256 m, 64 m tiles | 4.39 M cells | 278.7 µs, 15.76 G/s | 277.9 µs, 15.81 G/s | 1.00 | 5.9% / 4.7% | 0.95 to 1.00 |
| vale 1 km, 64 m tiles | 70.29 M cells | 4.43 ms, 15.85 G/s | 4.43 ms, 15.88 G/s | 1.00 | 17.3% / 15.5% | 0.92 to 1.01 |

### Walkable triangles

`rcMarkWalkableTriangles` and `markWalkableTriangles`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 55.8 µs, 181.6 M/s | 58.2 µs, 174.1 M/s | 1.04 | 4.0% / 9.7% | 0.99 to 1.07 |
| nav_test.obj | 1612 triangles | 3.8 µs, 422.3 M/s | 3.7 µs, 430.2 M/s | 0.98 | 18.6% / 10.7% | 0.97 to 0.99 |
| undulating.obj | 5202 triangles | 8.8 µs, 590.7 M/s | 8.6 µs, 603.8 M/s | 0.98 | 2.0% / 5.3% | 0.97 to 0.98 |
| terrain 256 m | 130.1 k triangles | 229.8 µs, 566.1 M/s | 210.9 µs, 616.9 M/s | 0.92 | 9.4% / 3.5% | 0.92 to 0.92 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 236.8 µs, 575.6 M/s | 229.6 µs, 593.8 M/s | 0.97 | 5.6% / 7.3% | 0.92 to 0.98 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 226.3 µs, 606.8 M/s | 216.2 µs, 635.0 M/s | 0.96 | 8.6% / 46.3% | 0.96 to 1.00 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 3.66 ms, 606.7 M/s | 3.62 ms, 614.1 M/s | 0.99 | 4.4% / 6.6% | 0.97 to 0.99 |

### Rasterization, int indices

`rcRasterizeTriangles` and `rasterizeTriangles`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.53 ms, 2.2 M/s | 4.28 ms, 2.4 M/s | 0.95 | 0.8% / 0.5% | 0.95 to 0.95 |
| nav_test.obj | 1612 triangles | 3.09 ms, 522.3 k/s | 2.83 ms, 569.9 k/s | 0.92 | 0.7% / 0.7% | 0.92 to 0.92 |
| undulating.obj | 5202 triangles | 3.64 ms, 1.4 M/s | 3.45 ms, 1.5 M/s | 0.95 | 0.7% / 0.9% | 0.95 to 0.95 |
| terrain 256 m | 130.1 k triangles | 31.97 ms, 4.1 M/s | 30.08 ms, 4.3 M/s | 0.94 | 1.2% / 1.2% | 0.94 to 0.95 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 90.17 ms, 1.5 M/s | 81.03 ms, 1.7 M/s | 0.90 | 0.3% / 0.2% | 0.90 to 0.90 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 88.08 ms, 1.6 M/s | 78.94 ms, 1.7 M/s | 0.90 | 0.5% / 0.2% | 0.90 to 0.90 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 1457.09 ms, 1.5 M/s | 1307.72 ms, 1.7 M/s | 0.90 | 2.8% / 2.8% | 0.90 to 0.90 |

### Low hanging obstacles filter

`rcFilterLowHangingWalkableObstacles` and `filterLowHangingWalkableObstacles`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 81.5 µs, 639.5 M/s | 70.5 µs, 739.3 M/s | 0.86 | 11.1% / 4.9% | 0.84 to 0.89 |
| nav_test.obj | 120.2 k spans | 136.8 µs, 878.2 M/s | 108.1 µs, 1.11 G/s | 0.79 | 9.2% / 6.9% | 0.79 to 0.83 |
| undulating.obj | 108.7 k spans | 113.6 µs, 957.2 M/s | 85.2 µs, 1.28 G/s | 0.75 | 15.6% / 6.3% | 0.71 to 0.85 |
| terrain 256 m | 741.4 k spans | 643.2 µs, 1.15 G/s | 455.9 µs, 1.63 G/s | 0.71 | 9.5% / 26.9% | 0.65 to 0.74 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 4.30 ms, 1.03 G/s | 2.72 ms, 1.62 G/s | 0.63 | 3.6% / 6.6% | 0.63 to 0.66 |
| vale 256 m, 64 m tiles | 4.34 M spans | 4.03 ms, 1.08 G/s | 2.62 ms, 1.65 G/s | 0.65 | 6.3% / 17.6% | 0.63 to 0.66 |
| vale 1 km, 64 m tiles | 70.09 M spans | 65.89 ms, 1.06 G/s | 42.17 ms, 1.66 G/s | 0.64 | 4.7% / 9.8% | 0.63 to 0.67 |

### Ledge filter

`rcFilterLedgeSpans` and `filterLedgeSpans`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 419.2 µs, 124.3 M/s | 386.2 µs, 134.9 M/s | 0.92 | 1.6% / 5.0% | 0.92 to 0.92 |
| nav_test.obj | 120.2 k spans | 950.3 µs, 126.5 M/s | 858.8 µs, 139.9 M/s | 0.90 | 12.2% / 14.9% | 0.90 to 0.91 |
| undulating.obj | 108.7 k spans | 881.1 µs, 123.4 M/s | 783.7 µs, 138.7 M/s | 0.89 | 0.7% / 0.8% | 0.89 to 0.91 |
| terrain 256 m | 741.4 k spans | 5.73 ms, 129.5 M/s | 4.99 ms, 148.5 M/s | 0.87 | 2.4% / 2.5% | 0.87 to 0.88 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 33.64 ms, 131.0 M/s | 30.01 ms, 146.9 M/s | 0.89 | 0.2% / 0.3% | 0.89 to 0.90 |
| vale 256 m, 64 m tiles | 4.34 M spans | 33.97 ms, 127.8 M/s | 30.31 ms, 143.3 M/s | 0.89 | 0.3% / 0.3% | 0.88 to 0.89 |
| vale 1 km, 64 m tiles | 70.09 M spans | 558.14 ms, 125.6 M/s | 496.39 ms, 141.2 M/s | 0.89 | 2.7% / 2.7% | 0.89 to 0.89 |

### Low height filter

`rcFilterWalkableLowHeightSpans` and `filterWalkableLowHeightSpans`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 78.5 µs, 663.7 M/s | 65.9 µs, 790.4 M/s | 0.84 | 1.8% / 10.8% | 0.84 to 0.87 |
| nav_test.obj | 120.2 k spans | 127.1 µs, 945.3 M/s | 113.3 µs, 1.06 G/s | 0.89 | 7.0% / 4.5% | 0.87 to 0.90 |
| undulating.obj | 108.7 k spans | 96.1 µs, 1.13 G/s | 79.5 µs, 1.37 G/s | 0.83 | 15.4% / 13.8% | 0.79 to 0.84 |
| terrain 256 m | 741.4 k spans | 500.9 µs, 1.48 G/s | 416.3 µs, 1.78 G/s | 0.83 | 4.6% / 17.0% | 0.82 to 0.84 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 3.23 ms, 1.36 G/s | 2.48 ms, 1.78 G/s | 0.77 | 1.7% / 1.8% | 0.75 to 0.80 |
| vale 256 m, 64 m tiles | 4.34 M spans | 3.18 ms, 1.37 G/s | 2.47 ms, 1.76 G/s | 0.78 | 7.6% / 11.7% | 0.75 to 0.83 |
| vale 1 km, 64 m tiles | 70.09 M spans | 53.05 ms, 1.32 G/s | 40.06 ms, 1.75 G/s | 0.76 | 7.7% / 11.0% | 0.74 to 0.81 |

### Compact heightfield

`rcBuildCompactHeightfield` and `buildCompactHeightfield`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 359.6 µs, 144.9 M/s | 328.3 µs, 158.7 M/s | 0.91 | 2.3% / 8.9% | 0.91 to 0.92 |
| nav_test.obj | 120.2 k spans | 700.8 µs, 171.5 M/s | 639.4 µs, 188.0 M/s | 0.91 | 1.4% / 1.6% | 0.91 to 0.91 |
| undulating.obj | 108.7 k spans | 1.02 ms, 106.7 M/s | 898.4 µs, 121.0 M/s | 0.88 | 2.3% / 0.8% | 0.87 to 0.89 |
| terrain 256 m | 741.4 k spans | 6.27 ms, 118.2 M/s | 5.49 ms, 135.1 M/s | 0.87 | 2.9% / 1.3% | 0.87 to 0.88 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 37.42 ms, 117.8 M/s | 32.95 ms, 133.8 M/s | 0.88 | 0.3% / 0.4% | 0.88 to 0.88 |
| vale 256 m, 64 m tiles | 4.34 M spans | 38.18 ms, 113.8 M/s | 33.55 ms, 129.4 M/s | 0.88 | 0.3% / 0.4% | 0.88 to 0.88 |
| vale 1 km, 64 m tiles | 70.09 M spans | 630.29 ms, 111.2 M/s | 553.42 ms, 126.6 M/s | 0.88 | 2.7% / 2.9% | 0.88 to 0.88 |

### Erosion

`rcErodeWalkableArea` and `erodeWalkableArea`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 351.1 µs, 67.1 M/s | 349.0 µs, 67.5 M/s | 0.99 | 5.1% / 4.4% | 0.98 to 1.00 |
| nav_test.obj | 56.8 k compact spans | 683.4 µs, 83.1 M/s | 673.0 µs, 84.4 M/s | 0.98 | 16.7% / 19.2% | 0.98 to 0.99 |
| undulating.obj | 105.8 k compact spans | 1.02 ms, 103.6 M/s | 992.7 µs, 106.6 M/s | 0.97 | 2.6% / 1.3% | 0.97 to 0.97 |
| terrain 256 m | 686.7 k compact spans | 6.60 ms, 104.0 M/s | 6.45 ms, 106.5 M/s | 0.98 | 0.3% / 0.8% | 0.98 to 0.98 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 35.40 ms, 115.7 M/s | 34.00 ms, 120.4 M/s | 0.96 | 0.4% / 0.4% | 0.96 to 0.96 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 32.78 ms, 131.5 M/s | 31.38 ms, 137.3 M/s | 0.96 | 0.8% / 0.6% | 0.96 to 0.96 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 537.47 ms, 129.4 M/s | 518.24 ms, 134.2 M/s | 0.96 | 2.5% / 2.6% | 0.96 to 0.96 |

### Distance field

`rcBuildDistanceField` and `buildDistanceField`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 399.0 µs, 59.1 M/s | 434.5 µs, 54.2 M/s | 1.09 | 2.2% / 4.8% | 1.08 to 1.09 |
| nav_test.obj | 56.8 k compact spans | 749.5 µs, 75.8 M/s | 824.0 µs, 68.9 M/s | 1.10 | 2.6% / 0.6% | 1.05 to 1.10 |
| undulating.obj | 105.8 k compact spans | 1.18 ms, 90.0 M/s | 1.40 ms, 75.4 M/s | 1.19 | 2.9% / 0.7% | 1.19 to 1.19 |
| terrain 256 m | 686.7 k compact spans | 7.62 ms, 90.2 M/s | 9.07 ms, 75.7 M/s | 1.19 | 1.0% / 0.3% | 1.18 to 1.19 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 41.03 ms, 99.8 M/s | 51.13 ms, 80.1 M/s | 1.25 | 1.2% / 0.2% | 1.25 to 1.25 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 39.44 ms, 109.3 M/s | 51.60 ms, 83.5 M/s | 1.31 | 0.7% / 0.2% | 1.30 to 1.31 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 659.52 ms, 105.5 M/s | 860.33 ms, 80.8 M/s | 1.30 | 2.4% / 2.2% | 1.30 to 1.31 |

### Watershed regions

`rcBuildRegions` and `buildRegions`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 1.02 ms, 23.0 M/s | 712.2 µs, 33.1 M/s | 0.70 | 13.9% / 25.2% | 0.70 to 0.73 |
| nav_test.obj | 56.8 k compact spans | 2.50 ms, 22.8 M/s | 1.52 ms, 37.4 M/s | 0.61 | 1.2% / 2.0% | 0.60 to 0.61 |
| undulating.obj | 105.8 k compact spans | 5.04 ms, 21.0 M/s | 2.92 ms, 36.2 M/s | 0.58 | 0.5% / 3.5% | 0.58 to 0.59 |
| terrain 256 m | 686.7 k compact spans | 37.03 ms, 18.5 M/s | 21.48 ms, 32.0 M/s | 0.58 | 0.7% / 2.9% | 0.58 to 0.58 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 194.89 ms, 21.0 M/s | 122.26 ms, 33.5 M/s | 0.63 | 0.2% / 3.7% | 0.63 to 0.64 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 191.16 ms, 22.5 M/s | 170.61 ms, 25.3 M/s | 0.89 | 2.2% / 5.1% | 0.88 to 0.91 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 3167.34 ms, 22.0 M/s | 2773.99 ms, 25.1 M/s | 0.88 | 2.2% / 3.7% | 0.87 to 0.89 |

### Contours

`rcBuildContours` and `buildContours`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 241.7 µs, 97.5 M/s | 206.5 µs, 114.2 M/s | 0.85 | 7.2% / 1.5% | 0.83 to 0.85 |
| nav_test.obj | 56.8 k compact spans | 421.5 µs, 134.7 M/s | 382.8 µs, 148.4 M/s | 0.91 | 4.2% / 3.6% | 0.90 to 0.91 |
| undulating.obj | 105.8 k compact spans | 617.7 µs, 171.3 M/s | 592.2 µs, 178.6 M/s | 0.96 | 1.4% / 5.6% | 0.95 to 0.96 |
| terrain 256 m | 686.7 k compact spans | 4.55 ms, 151.0 M/s | 4.25 ms, 161.7 M/s | 0.93 | 0.7% / 1.1% | 0.93 to 0.94 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 19.45 ms, 210.5 M/s | 19.28 ms, 212.4 M/s | 0.99 | 0.5% / 0.4% | 0.99 to 0.99 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 15.76 ms, 273.5 M/s | 16.55 ms, 260.4 M/s | 1.05 | 2.7% / 3.0% | 1.05 to 1.06 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 245.92 ms, 282.8 M/s | 260.28 ms, 267.2 M/s | 1.06 | 0.7% / 0.4% | 1.05 to 1.06 |

### Polygon mesh

`rcBuildPolyMesh` and `buildPolyMesh`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 118 polygons | 200.3 µs, 589.1 k/s | 181.1 µs, 651.6 k/s | 0.90 | 3.0% / 5.2% | 0.89 to 0.91 |
| nav_test.obj | 155 polygons | 174.2 µs, 889.8 k/s | 163.1 µs, 950.5 k/s | 0.94 | 3.1% / 3.2% | 0.92 to 0.94 |
| undulating.obj | 216 polygons | 344.5 µs, 627.1 k/s | 309.7 µs, 697.3 k/s | 0.90 | 2.0% / 1.9% | 0.89 to 0.90 |
| terrain 256 m | 2580 polygons | 5.87 ms, 439.2 k/s | 5.11 ms, 505.2 k/s | 0.87 | 0.4% / 1.5% | 0.86 to 0.87 |
| terrain 256 m, 64 m tiles | 4098 polygons | 11.44 ms, 358.3 k/s | 9.99 ms, 410.2 k/s | 0.87 | 0.3% / 0.7% | 0.86 to 0.88 |
| vale 256 m, 64 m tiles | 108 polygons | 111.3 µs, 970.2 k/s | 106.2 µs, 1.0 M/s | 0.95 | 4.6% / 5.7% | 0.95 to 0.96 |
| vale 1 km, 64 m tiles | 684 polygons | 838.7 µs, 815.6 k/s | 811.4 µs, 843.0 k/s | 0.97 | 26.3% / 28.8% | 0.97 to 1.00 |

### Detail mesh

`rcBuildPolyMeshDetail` and `buildPolyMeshDetail`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 118 polygons | 374.0 µs, 315.5 k/s | 310.0 µs, 380.6 k/s | 0.83 | 3.0% / 2.3% | 0.82 to 0.83 |
| nav_test.obj | 155 polygons | 1.14 ms, 136.0 k/s | 723.4 µs, 214.3 k/s | 0.63 | 1.8% / 2.1% | 0.58 to 0.64 |
| undulating.obj | 216 polygons | 43.72 ms, 4941/s | 11.30 ms, 19.1 k/s | 0.26 | 1.4% / 4.6% | 0.26 to 0.26 |
| terrain 256 m | 2580 polygons | 35.58 ms, 72.5 k/s | 16.60 ms, 155.4 k/s | 0.47 | 0.6% / 2.6% | 0.46 to 0.47 |
| terrain 256 m, 64 m tiles | 4098 polygons | 75.02 ms, 54.6 k/s | 50.37 ms, 81.4 k/s | 0.67 | 0.9% / 0.3% | 0.67 to 0.67 |
| vale 256 m, 64 m tiles | 108 polygons | 588.23 ms, 184/s | 68.08 ms, 1586/s | 0.12 | 0.6% / 0.6% | 0.12 to 0.12 |
| vale 1 km, 64 m tiles | 684 polygons | 14591.56 ms, 47/s | 1384.57 ms, 494/s | 0.09 | 2.6% / 3.8% | 0.09 to 0.09 |

### Span count

`rcGetHeightFieldSpanCount` and `getHeightFieldSpanCount`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 53.7 µs, 970.0 M/s | 48.8 µs, 1.07 G/s | 0.91 | 14.9% / 2.3% | 0.90 to 0.94 |
| nav_test.obj | 120.2 k spans | 81.8 µs, 1.47 G/s | 79.9 µs, 1.50 G/s | 0.98 | 6.5% / 5.0% | 0.98 to 0.98 |
| undulating.obj | 108.7 k spans | 52.1 µs, 2.09 G/s | 47.4 µs, 2.29 G/s | 0.91 | 25.4% / 2.5% | 0.89 to 0.93 |
| terrain 256 m | 741.4 k spans | 355.2 µs, 2.09 G/s | 299.8 µs, 2.47 G/s | 0.84 | 36.9% / 4.8% | 0.81 to 0.91 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 1.81 ms, 2.44 G/s | 1.83 ms, 2.41 G/s | 1.01 | 10.4% / 3.4% | 0.94 to 1.06 |
| vale 256 m, 64 m tiles | 4.34 M spans | 1.68 ms, 2.59 G/s | 1.75 ms, 2.48 G/s | 1.04 | 2.3% / 1.4% | 1.03 to 1.11 |
| vale 1 km, 64 m tiles | 70.09 M spans | 27.46 ms, 2.55 G/s | 28.81 ms, 2.43 G/s | 1.05 | 8.6% / 3.7% | 0.99 to 1.11 |

### Unwalkable triangles

`rcClearUnwalkableTriangles` and `clearUnwalkableTriangles`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 56.8 µs, 178.4 M/s | 57.1 µs, 177.4 M/s | 1.01 | 4.2% / 7.6% | 1.00 to 1.01 |
| nav_test.obj | 1612 triangles | 4.0 µs, 398.3 M/s | 3.6 µs, 450.7 M/s | 0.88 | 15.8% / 9.8% | 0.84 to 0.89 |
| undulating.obj | 5202 triangles | 8.4 µs, 617.4 M/s | 8.4 µs, 620.3 M/s | 1.00 | 2.4% / 2.1% | 0.97 to 1.00 |
| terrain 256 m | 130.1 k triangles | 216.1 µs, 602.1 M/s | 210.2 µs, 618.9 M/s | 0.97 | 40.7% / 12.3% | 0.96 to 0.98 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 236.8 µs, 575.5 M/s | 231.6 µs, 588.6 M/s | 0.98 | 3.2% / 9.4% | 0.97 to 0.98 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 213.3 µs, 643.6 M/s | 211.6 µs, 648.9 M/s | 0.99 | 9.8% / 36.8% | 0.99 to 1.01 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 3.46 ms, 643.0 M/s | 3.49 ms, 636.4 M/s | 1.01 | 6.2% / 6.6% | 1.00 to 1.02 |

### Rasterization, unsigned short indices

`rcRasterizeTriangles` and `rasterizeTriangles`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.59 ms, 2.2 M/s | 4.35 ms, 2.3 M/s | 0.95 | 1.2% / 0.8% | 0.94 to 0.95 |
| nav_test.obj | 1612 triangles | 3.20 ms, 503.4 k/s | 2.96 ms, 545.0 k/s | 0.92 | 0.8% / 0.6% | 0.92 to 0.94 |
| undulating.obj | 5202 triangles | 3.69 ms, 1.4 M/s | 3.51 ms, 1.5 M/s | 0.95 | 0.9% / 0.8% | 0.95 to 0.96 |

### Rasterization, unindexed

`rcRasterizeTriangles` and `rasterizeUnindexedTriangles`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.51 ms, 2.2 M/s | 4.25 ms, 2.4 M/s | 0.94 | 0.9% / 0.2% | 0.94 to 0.94 |
| nav_test.obj | 1612 triangles | 3.06 ms, 526.2 k/s | 2.82 ms, 572.5 k/s | 0.92 | 0.3% / 0.3% | 0.92 to 0.92 |
| undulating.obj | 5202 triangles | 3.60 ms, 1.4 M/s | 3.41 ms, 1.5 M/s | 0.95 | 0.7% / 0.4% | 0.94 to 0.96 |
| terrain 256 m | 130.1 k triangles | 32.03 ms, 4.1 M/s | 30.33 ms, 4.3 M/s | 0.95 | 0.6% / 2.0% | 0.94 to 0.95 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 89.77 ms, 1.5 M/s | 80.56 ms, 1.7 M/s | 0.90 | 0.6% / 0.4% | 0.90 to 0.90 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 86.96 ms, 1.6 M/s | 78.14 ms, 1.8 M/s | 0.90 | 0.3% / 0.3% | 0.90 to 0.90 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 1441.40 ms, 1.5 M/s | 1294.81 ms, 1.7 M/s | 0.90 | 2.9% / 2.9% | 0.90 to 0.90 |

### Rasterization, one triangle at a time

`rcRasterizeTriangle` and `rasterizeTriangle`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.53 ms, 2.2 M/s | 4.26 ms, 2.4 M/s | 0.94 | 0.8% / 0.5% | 0.94 to 0.94 |
| nav_test.obj | 1612 triangles | 3.07 ms, 524.6 k/s | 2.82 ms, 571.8 k/s | 0.92 | 0.4% / 0.3% | 0.92 to 0.92 |
| undulating.obj | 5202 triangles | 3.61 ms, 1.4 M/s | 3.40 ms, 1.5 M/s | 0.94 | 0.9% / 0.5% | 0.94 to 0.94 |
| terrain 256 m | 130.1 k triangles | 31.50 ms, 4.1 M/s | 29.47 ms, 4.4 M/s | 0.94 | 0.8% / 1.6% | 0.93 to 0.94 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 90.07 ms, 1.5 M/s | 80.70 ms, 1.7 M/s | 0.90 | 0.2% / 0.3% | 0.89 to 0.90 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 87.90 ms, 1.6 M/s | 78.73 ms, 1.7 M/s | 0.90 | 0.4% / 0.4% | 0.89 to 0.90 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 1453.47 ms, 1.5 M/s | 1299.62 ms, 1.7 M/s | 0.89 | 2.7% / 2.7% | 0.89 to 0.89 |

### Adding spans, the rasterized field's again

`rcAddSpan` and `addSpan`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 296.4 µs, 175.8 M/s | 216.4 µs, 240.8 M/s | 0.73 | 1.3% / 6.9% | 0.73 to 0.73 |
| nav_test.obj | 120.2 k spans | 665.1 µs, 180.7 M/s | 489.2 µs, 245.7 M/s | 0.74 | 1.7% / 2.5% | 0.73 to 0.75 |
| undulating.obj | 108.7 k spans | 528.1 µs, 205.8 M/s | 357.1 µs, 304.4 M/s | 0.68 | 3.4% / 6.2% | 0.67 to 0.68 |
| terrain 256 m | 741.4 k spans | 4.04 ms, 183.4 M/s | 2.85 ms, 260.4 M/s | 0.70 | 8.7% / 19.5% | 0.70 to 0.74 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 16.81 ms, 262.3 M/s | 10.07 ms, 437.6 M/s | 0.60 | 1.3% / 2.1% | 0.60 to 0.60 |
| vale 256 m, 64 m tiles | 4.34 M spans | 16.40 ms, 264.8 M/s | 9.73 ms, 446.3 M/s | 0.59 | 0.7% / 1.2% | 0.59 to 0.61 |
| vale 1 km, 64 m tiles | 70.09 M spans | 272.60 ms, 257.1 M/s | 163.32 ms, 429.2 M/s | 0.60 | 3.7% / 5.0% | 0.59 to 0.60 |

### Polygon mesh copy

`rcCopyPolyMesh` and `copyPolyMesh`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 118 polygons | 28.8 µs, 4.1 M/s | 29.4 µs, 4.0 M/s | 1.02 | 4.7% / 17.9% | 1.01 to 1.03 |
| nav_test.obj | 155 polygons | 49.9 µs, 3.1 M/s | 50.1 µs, 3.1 M/s | 1.00 | 7.6% / 2.3% | 1.00 to 1.02 |
| undulating.obj | 216 polygons | 49.1 µs, 4.4 M/s | 48.8 µs, 4.4 M/s | 1.00 | 86.7% / 19.6% | 1.00 to 1.01 |
| terrain 256 m | 2580 polygons | 347.4 µs, 7.4 M/s | 352.0 µs, 7.3 M/s | 1.01 | 42.7% / 50.3% | 0.96 to 1.08 |
| terrain 256 m, 64 m tiles | 4098 polygons | 27.8 µs, 147.4 M/s | 25.7 µs, 159.5 M/s | 0.92 | 4.3% / 5.0% | 0.90 to 0.92 |
| vale 256 m, 64 m tiles | 108 polygons | 27.1 µs, 4.0 M/s | 23.7 µs, 4.6 M/s | 0.87 | 8.8% / 7.4% | 0.86 to 0.88 |
| vale 1 km, 64 m tiles | 684 polygons | 534.6 µs, 1.3 M/s | 453.7 µs, 1.5 M/s | 0.85 | 15.3% / 23.7% | 0.83 to 0.90 |

### Heightfield layers

`rcBuildHeightfieldLayers` and `buildHeightfieldLayers`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 609.0 µs, 38.7 M/s | 592.1 µs, 39.8 M/s | 0.97 | 18.5% / 28.6% | 0.97 to 0.98 |
| nav_test.obj | 56.8 k compact spans | 1.08 ms, 52.6 M/s | 1.06 ms, 53.7 M/s | 0.98 | 1.2% / 2.1% | 0.97 to 0.98 |
| undulating.obj | 105.8 k compact spans | 1.52 ms, 69.6 M/s | 1.45 ms, 72.8 M/s | 0.96 | 2.0% / 3.1% | 0.95 to 0.99 |
| terrain 256 m | 686.7 k compact spans | fails | fails | | | |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 55.31 ms, 74.0 M/s | 53.18 ms, 77.0 M/s | 0.96 | 1.2% / 2.3% | 0.96 to 0.96 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 52.51 ms, 82.1 M/s | 49.32 ms, 87.4 M/s | 0.94 | 4.3% / 0.7% | 0.93 to 0.95 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 822.34 ms, 84.6 M/s | 774.27 ms, 89.8 M/s | 0.94 | 0.6% / 1.4% | 0.84 to 0.95 |

### Monotone regions

`rcBuildRegionsMonotone` and `buildRegionsMonotone`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 319.3 µs, 73.8 M/s | 284.1 µs, 83.0 M/s | 0.89 | 6.9% / 40.0% | 0.88 to 0.90 |
| nav_test.obj | 56.8 k compact spans | 660.9 µs, 85.9 M/s | 520.4 µs, 109.1 M/s | 0.79 | 21.7% / 14.4% | 0.79 to 0.80 |
| undulating.obj | 105.8 k compact spans | 955.4 µs, 110.7 M/s | 767.6 µs, 137.8 M/s | 0.80 | 1.1% / 2.3% | 0.72 to 0.81 |
| terrain 256 m | 686.7 k compact spans | 20.22 ms, 34.0 M/s | 7.92 ms, 86.7 M/s | 0.39 | 1.0% / 4.9% | 0.39 to 0.39 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 33.38 ms, 122.7 M/s | 25.50 ms, 160.6 M/s | 0.76 | 1.3% / 0.9% | 0.76 to 0.77 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 28.02 ms, 153.8 M/s | 22.11 ms, 194.9 M/s | 0.79 | 1.2% / 1.0% | 0.77 to 0.80 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 463.52 ms, 150.1 M/s | 364.64 ms, 190.8 M/s | 0.79 | 2.4% / 3.0% | 0.78 to 0.80 |

### Layer regions

`rcBuildLayerRegions` and `buildLayerRegions`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 363.4 µs, 64.9 M/s | 355.1 µs, 66.4 M/s | 0.98 | 3.2% / 4.2% | 0.98 to 0.98 |
| nav_test.obj | 56.8 k compact spans | 788.9 µs, 72.0 M/s | 716.2 µs, 79.3 M/s | 0.91 | 1.5% / 7.2% | 0.90 to 0.92 |
| undulating.obj | 105.8 k compact spans | 1.21 ms, 87.3 M/s | 1.18 ms, 89.5 M/s | 0.98 | 1.3% / 2.3% | 0.97 to 1.04 |
| terrain 256 m | 686.7 k compact spans | 8.82 ms, 77.9 M/s | 8.13 ms, 84.4 M/s | 0.92 | 7.3% / 1.3% | 0.92 to 0.93 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 46.22 ms, 88.6 M/s | 43.63 ms, 93.9 M/s | 0.94 | 0.7% / 0.5% | 0.94 to 0.94 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 45.67 ms, 94.4 M/s | 44.94 ms, 95.9 M/s | 0.98 | 0.9% / 0.8% | 0.97 to 0.98 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 754.09 ms, 92.2 M/s | 735.64 ms, 94.6 M/s | 0.98 | 4.8% / 2.8% | 0.97 to 0.99 |

### Median area filter

`rcMedianFilterWalkableArea` and `medianFilterWalkableArea`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 164.3 µs, 143.4 M/s | 167.4 µs, 140.8 M/s | 1.02 | 11.2% / 2.7% | 1.01 to 1.03 |
| nav_test.obj | 56.8 k compact spans | 360.0 µs, 157.8 M/s | 359.7 µs, 157.9 M/s | 1.00 | 0.9% / 2.1% | 0.99 to 1.00 |
| undulating.obj | 105.8 k compact spans | 659.9 µs, 160.3 M/s | 659.8 µs, 160.3 M/s | 1.00 | 0.8% / 1.2% | 1.00 to 1.00 |
| terrain 256 m | 686.7 k compact spans | 4.25 ms, 161.6 M/s | 4.27 ms, 161.0 M/s | 1.00 | 1.4% / 0.4% | 1.00 to 1.01 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 25.08 ms, 163.3 M/s | 25.10 ms, 163.1 M/s | 1.00 | 0.3% / 0.3% | 1.00 to 1.00 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 26.72 ms, 161.3 M/s | 26.75 ms, 161.1 M/s | 1.00 | 0.3% / 0.3% | 1.00 to 1.01 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 441.45 ms, 157.6 M/s | 442.31 ms, 157.3 M/s | 1.00 | 2.8% / 2.6% | 1.00 to 1.00 |

### Box area

`rcMarkBoxArea` and `markBoxArea`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 15.5 µs, 1.52 G/s | 12.5 µs, 1.88 G/s | 0.81 | 5.9% / 5.0% | 0.79 to 0.82 |
| nav_test.obj | 56.8 k compact spans | 27.2 µs, 2.09 G/s | 25.5 µs, 2.22 G/s | 0.94 | 2.6% / 3.0% | 0.92 to 0.94 |
| undulating.obj | 105.8 k compact spans | 27.9 µs, 3.79 G/s | 25.1 µs, 4.21 G/s | 0.90 | 7.0% / 13.8% | 0.90 to 0.90 |
| terrain 256 m | 686.7 k compact spans | 173.6 µs, 3.96 G/s | 153.4 µs, 4.48 G/s | 0.88 | 14.5% / 2.1% | 0.84 to 0.94 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 909.4 µs, 4.50 G/s | 789.0 µs, 5.19 G/s | 0.87 | 6.1% / 2.1% | 0.86 to 0.88 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 795.7 µs, 5.42 G/s | 674.6 µs, 6.39 G/s | 0.85 | 1.4% / 2.0% | 0.79 to 0.86 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 12.86 ms, 5.41 G/s | 11.16 ms, 6.23 G/s | 0.87 | 0.6% / 2.5% | 0.85 to 0.87 |

### Convex area

`rcMarkConvexPolyArea` and `markConvexPolyArea`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 21.4 µs, 1.10 G/s | 18.7 µs, 1.26 G/s | 0.87 | 1.8% / 0.7% | 0.87 to 0.88 |
| nav_test.obj | 56.8 k compact spans | 56.9 µs, 997.3 M/s | 48.2 µs, 1.18 G/s | 0.85 | 2.8% / 7.7% | 0.84 to 0.85 |
| undulating.obj | 105.8 k compact spans | 97.5 µs, 1.09 G/s | 82.0 µs, 1.29 G/s | 0.84 | 3.5% / 0.4% | 0.84 to 0.84 |
| terrain 256 m | 686.7 k compact spans | 613.2 µs, 1.12 G/s | 516.8 µs, 1.33 G/s | 0.84 | 0.6% / 1.1% | 0.83 to 0.85 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 3.83 ms, 1.07 G/s | 3.19 ms, 1.28 G/s | 0.83 | 0.8% / 0.7% | 0.83 to 0.85 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 3.93 ms, 1.10 G/s | 3.28 ms, 1.31 G/s | 0.84 | 0.3% / 0.7% | 0.82 to 0.84 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 64.70 ms, 1.08 G/s | 53.92 ms, 1.29 G/s | 0.83 | 2.3% / 2.5% | 0.83 to 0.84 |

### Cylinder area

`rcMarkCylinderArea` and `markCylinderArea`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 23.3 µs, 1.01 G/s | 18.7 µs, 1.26 G/s | 0.80 | 3.2% / 5.5% | 0.78 to 0.80 |
| nav_test.obj | 56.8 k compact spans | 30.5 µs, 1.86 G/s | 25.6 µs, 2.22 G/s | 0.84 | 18.5% / 20.8% | 0.84 to 0.88 |
| undulating.obj | 105.8 k compact spans | 39.8 µs, 2.66 G/s | 31.9 µs, 3.32 G/s | 0.80 | 15.9% / 8.8% | 0.79 to 0.81 |
| terrain 256 m | 686.7 k compact spans | 240.4 µs, 2.86 G/s | 189.3 µs, 3.63 G/s | 0.79 | 1.2% / 7.9% | 0.78 to 0.79 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 1.40 ms, 2.92 G/s | 1.10 ms, 3.72 G/s | 0.79 | 1.4% / 2.0% | 0.78 to 0.80 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 1.23 ms, 3.50 G/s | 1.04 ms, 4.15 G/s | 0.84 | 7.5% / 13.7% | 0.84 to 0.85 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 19.52 ms, 3.56 G/s | 16.53 ms, 4.21 G/s | 0.85 | 1.1% / 0.7% | 0.84 to 0.86 |

### Polygon mesh merge, every tile

`rcMergePolyMeshes` and `mergePolyMeshes`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| terrain 256 m, 64 m tiles | 4098 polygons | 257.1 µs, 15.9 M/s | 264.3 µs, 15.5 M/s | 1.03 | 2.9% / 2.9% | 1.02 to 1.03 |
| vale 256 m, 64 m tiles | 108 polygons | 8.9 µs, 12.2 M/s | 9.7 µs, 11.2 M/s | 1.09 | 20.7% / 21.9% | 1.09 to 1.11 |
| vale 1 km, 64 m tiles | 684 polygons | 46.2 µs, 14.8 M/s | 47.4 µs, 14.4 M/s | 1.03 | 36.5% / 59.9% | 0.98 to 1.18 |

### Detail mesh merge, every tile

`rcMergePolyMeshDetails` and `mergePolyMeshDetails`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| terrain 256 m, 64 m tiles | 4098 polygons | 39.3 µs, 104.2 M/s | 18.1 µs, 227.0 M/s | 0.46 | 14.9% / 50.6% | 0.45 to 0.49 |
| vale 256 m, 64 m tiles | 108 polygons | 8.7 µs, 12.3 M/s | 3.8 µs, 28.2 M/s | 0.44 | 69.7% / 54.5% | 0.42 to 0.49 |
| vale 1 km, 64 m tiles | 684 polygons | 146.2 µs, 4.7 M/s | 80.3 µs, 8.5 M/s | 0.55 | 12.5% / 17.7% | 0.53 to 0.55 |

### Bounds

`rcCalcBounds` and `calcBounds`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 5101 vertices | 10.5 µs, 485.8 M/s | 2.9 µs, 1.78 G/s | 0.27 | 0.5% / 2.1% | 0.27 to 0.27 |
| nav_test.obj | 884 vertices | 1.9 µs, 466.7 M/s | 0.6 µs, 1.60 G/s | 0.29 | 4.2% / 7.3% | 0.29 to 0.30 |
| undulating.obj | 2800 vertices | 5.9 µs, 478.6 M/s | 1.6 µs, 1.74 G/s | 0.28 | 0.7% / 3.1% | 0.28 to 0.28 |
| terrain 256 m | 66.8 k vertices | 139.1 µs, 480.3 M/s | 37.5 µs, 1.78 G/s | 0.27 | 4.8% / 30.4% | 0.27 to 0.27 |
| terrain 256 m, 64 m tiles | 66.8 k vertices | 138.5 µs, 482.2 M/s | 37.4 µs, 1.79 G/s | 0.27 | 0.7% / 2.4% | 0.27 to 0.27 |
| vale 256 m, 64 m tiles | 66.0 k vertices | 137.0 µs, 481.9 M/s | 36.9 µs, 1.79 G/s | 0.27 | 0.9% / 11.8% | 0.27 to 0.28 |
| vale 1 km, 64 m tiles | 1.05 M vertices | 2.18 ms, 482.3 M/s | 606.5 µs, 1.73 G/s | 0.28 | 5.2% / 23.2% | 0.28 to 0.29 |

### Grid size

`rcCalcGridSize` and `calcGridSize`, per call.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.0 k calls | 1.0 ns | 1.2 ns | 1.19 | 0.5% / 2.8% | 1.17 to 1.19 |
| nav_test.obj | 10.0 k calls | 1.0 ns | 1.2 ns | 1.16 | 0.6% / 2.2% | 1.16 to 1.19 |
| undulating.obj | 10.0 k calls | 1.0 ns | 1.2 ns | 1.16 | 6.5% / 5.4% | 1.16 to 1.19 |
| terrain 256 m | 10.0 k calls | 1.0 ns | 1.2 ns | 1.20 | 1.8% / 5.2% | 1.19 to 1.20 |
| terrain 256 m, 64 m tiles | 10.0 k calls | 1.0 ns | 1.2 ns | 1.19 | 0.7% / 3.2% | 1.17 to 1.20 |
| vale 256 m, 64 m tiles | 10.0 k calls | 1.0 ns | 1.2 ns | 1.17 | 9.2% / 2.6% | 1.17 to 1.19 |
| vale 1 km, 64 m tiles | 10.0 k calls | 1.0 ns | 1.2 ns | 1.18 | 5.2% / 4.7% | 1.18 to 1.19 |

### Polygon offset, a hexagon

`rcOffsetPoly` and `offsetPoly`, per call.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.0 k calls | 34.7 ns | 26.5 ns | 0.76 | 4.9% / 1.3% | 0.76 to 0.77 |
| nav_test.obj | 10.0 k calls | 34.9 ns | 26.6 ns | 0.76 | 1.4% / 1.8% | 0.76 to 0.76 |
| undulating.obj | 10.0 k calls | 35.2 ns | 26.9 ns | 0.76 | 8.1% / 1.3% | 0.76 to 0.77 |
| terrain 256 m | 10.0 k calls | 35.1 ns | 26.7 ns | 0.76 | 1.7% / 2.1% | 0.76 to 0.76 |
| terrain 256 m, 64 m tiles | 10.0 k calls | 35.3 ns | 26.8 ns | 0.76 | 29.9% / 2.1% | 0.76 to 0.77 |
| vale 256 m, 64 m tiles | 10.0 k calls | 35.0 ns | 26.7 ns | 0.76 | 4.7% / 1.6% | 0.76 to 0.77 |
| vale 1 km, 64 m tiles | 10.0 k calls | 34.5 ns | 26.5 ns | 0.77 | 25.5% / 1.9% | 0.77 to 0.77 |
