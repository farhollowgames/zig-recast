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

Measured on 11 November 2026, at commit `c14a021`, on an AMD Ryzen 9
9950X3D (16 cores) under Linux 7.3.3 (CachyOS), pinned to CPU 2, one of the
eight with the stacked cache. The one-minute load average was at most 3.0
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

Earlier figures were taken at commit `0e9beae`. The refusal of polygons of
more than 127 vertices in the detail mesh, added after it, first made
three rows slower; each was traced in the compiled benchmark:

- **Detail mesh on the tiled terrain, from 0.55 to 0.67.** A real change
  in the code: written inside `buildPolyMeshDetail`, the refusal's loop and
  log changed which helpers the compiler inlined, and the row took 51 ms
  instead of 41. The refusal is now a separate function marked cold, the
  port's code in the benchmark is again the same instructions as at
  `0e9beae` but for that one call, and the row is back to 0.55.
- **Grid size, from 1.09 to 1.17**, and **the watershed on the 256 m
  rolling ground, from 0.72 to between 0.78 and 0.94.** Code layout, as is
  the move of the low hanging obstacles filter on the tiled inputs, from
  about 0.65 to 0.86 to 0.90, that came with the fix above; see the code
  layout bias below.

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
- **Code layout.** Where a hot loop falls against the CPU's 32- and
  64-byte fetch blocks moves whenever code before it in the binary
  changes size, and a row can move with it by more than its spread with
  no change to its own instructions. Between `0e9beae` and `c14a021`, the
  port's watershed, low hanging obstacles filter and grid size compile to
  the same instructions in the benchmark, at other offsets. The watershed
  on the 256 m rolling ground took 150 to 155 ms at the one and 161 to
  180 ms at the other, and the original's, whose code is unchanged too,
  208 ms and 188 to 192 ms. The low hanging obstacles filter on the tiled
  inputs took 2.5 to 2.8 ms at the one and 3.4 to 3.7 ms at the other
  (about 0.65 times the original's time then, 0.86 to 0.90 now): the hot
  path of its inner loop now spans three 32-byte blocks, where it spanned
  two.
  In grid size, the port's loop takes 1.2 ns a call at both, and the
  original's went from 1.1 to 1.0 ns. Neither side controls this in the
  benchmark, and a program that inlines the port's functions lays them
  out its own way. These three are the rows where it was seen; others may
  move by a few percent the same way.
- One machine, one core, these inputs.

## Summary

The port's median time divided by the original's, the lowest and the
highest over the inputs a feature runs on (below 1, the port takes less
time).

| feature | port ÷ original |
| --- | ---: |
| Whole build | 0.38 to 0.92 |
| Heightfield | 0.95 to 1.00 |
| Walkable triangles | 0.93 to 1.06 |
| Rasterization, int indices | 0.90 to 0.96 |
| Low hanging obstacles filter | 0.86 to 0.92 |
| Ledge filter | 0.88 to 0.92 |
| Low height filter | 0.79 to 0.95 |
| Compact heightfield | 0.87 to 0.92 |
| Erosion | 0.99 to 1.00 |
| Distance field | 1.09 to 1.30 |
| Watershed regions | 0.58 to 0.93 |
| Contours | 0.88 to 1.05 |
| Polygon mesh | 0.86 to 0.97 |
| Detail mesh | 0.09 to 0.76 |
| Span count | 0.88 to 1.05 |
| Unwalkable triangles | 0.96 to 1.04 |
| Rasterization, unsigned short indices | 0.93 to 0.96 |
| Rasterization, unindexed | 0.90 to 0.96 |
| Rasterization, one triangle at a time | 0.90 to 0.96 |
| Adding spans, the rasterized field's again | 0.57 to 0.74 |
| Polygon mesh copy | 0.89 to 1.06 |
| Heightfield layers | 0.95 to 0.98 |
| Monotone regions | 0.39 to 0.85 |
| Layer regions | 0.91 to 0.99 |
| Median area filter | 1.00 to 1.06 |
| Box area | 0.79 to 0.96 |
| Convex area | 0.83 to 0.86 |
| Cylinder area | 0.75 to 0.84 |
| Polygon mesh merge, every tile | 0.98 to 1.12 |
| Detail mesh merge, every tile | 0.48 to 0.52 |
| Bounds | 0.27 to 0.29 |
| Grid size | 1.17 to 1.19 |
| Polygon offset, a hexagon | 0.76 to 0.77 |

## Where the port is faster

- **Detail mesh, 0.09 to 0.76 times.** Where the original measures each
  sample against each triangle in turn, the port measures a vector of
  samples at a time against a triangle (`@Vector`, as wide as the CPU's),
  with what depends only on the triangle worked out once. It finds a
  triangulation's edges in a table indexed by their two vertices, where the
  original searches every edge, and it works out once per span whether the
  span borders its region, where the original redoes that for every
  polygon whose patch covers the span. The more samples a polygon takes,
  the more this gains: on the rolling ground, whose polygons take up to
  119 detail vertices, the port is nine to eleven times as fast.
- **Compact heightfield, 0.87 to 0.92 times.** The port builds a span's
  four connections in a register and stores the span once.
- **Loops that store to bytes.** Zig has no type-based aliasing, so through
  the heightfield's pointer each store to a distance, flag or area makes a
  loop load the field's slices again, as the original's stores to bytes do
  in C++. Erosion, contours and the box and cylinder marks read the field
  through local slices instead.

## Where the port is slower

- **Distance field, 1.09 to 1.30 times**, the larger the field the slower.
  Each of its four passes (marking the borders, the two sweeps and the
  blur) takes 20 to 30% longer in samples of the rolling ground's build,
  though their loops compile to nearly the original's instructions. The
  one difference found is that the port keeps the four neighbours' cell
  indices on the stack, where the original addresses them from a row
  pointer; whether that is the cause is not known.
- **Grid size, 1.17 to 1.19 times**, about 0.2 ns a call: the port checks
  the range before converting a float to an int, so that out-of-range
  values give x86-64's result on every machine, where the original's
  `(int)` is one instruction.
- **Contours on the rolling ground, 1.04 and 1.05 times**; 0.88 to 0.98
  on the other inputs.
- **Polygon mesh merge on the 256 m rolling ground, 1.12 times**, of 9 µs;
  1.01 and 0.98 on the other two inputs.

Every other feature is within 6% of the original on every input, or
faster; differences of a few percent are within the spread of the runs.

## Every feature

### Whole build

Every step of a navmesh build, in Loomwork's order.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 8.07 ms, 1.3 M/s | 7.42 ms, 1.4 M/s | 0.92 | 0.8% / 1.6% | 0.91 to 0.92 |
| nav_test.obj | 1612 triangles | 10.72 ms, 150.4 k/s | 8.86 ms, 181.9 k/s | 0.83 | 0.8% / 1.3% | 0.83 to 0.83 |
| undulating.obj | 5202 triangles | 57.20 ms, 90.9 k/s | 22.66 ms, 229.6 k/s | 0.40 | 1.0% / 0.7% | 0.39 to 0.40 |
| terrain 256 m | 130.1 k triangles | 142.00 ms, 916.2 k/s | 103.34 ms, 1.3 M/s | 0.73 | 1.5% / 3.0% | 0.72 to 0.73 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 547.33 ms, 249.0 k/s | 426.50 ms, 319.6 k/s | 0.78 | 0.5% / 0.9% | 0.78 to 0.78 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 1027.72 ms, 133.6 k/s | 481.64 ms, 285.0 k/s | 0.47 | 0.8% / 4.5% | 0.46 to 0.47 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 21311.65 ms, 104.3 k/s | 8001.03 ms, 277.7 k/s | 0.38 | 0.4% / 3.7% | 0.38 to 0.39 |

### Heightfield

`rcCreateHeightfield` and `Heightfield.init`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 81.8 k cells | 5.2 µs, 15.62 G/s | 5.2 µs, 15.77 G/s | 0.99 | 64.4% / 17.4% | 0.98 to 0.99 |
| nav_test.obj | 78.7 k cells | 4.4 µs, 17.89 G/s | 4.2 µs, 18.88 G/s | 0.95 | 58.1% / 21.9% | 0.85 to 0.98 |
| undulating.obj | 109.2 k cells | 6.1 µs, 18.05 G/s | 6.0 µs, 18.20 G/s | 0.99 | 4.5% / 7.5% | 0.99 to 1.01 |
| terrain 256 m | 727.6 k cells | 46.9 µs, 15.51 G/s | 46.9 µs, 15.53 G/s | 1.00 | 37.6% / 68.1% | 0.98 to 1.14 |
| terrain 256 m, 64 m tiles | 4.39 M cells | 232.7 µs, 18.88 G/s | 232.6 µs, 18.89 G/s | 1.00 | 5.7% / 23.2% | 0.99 to 1.01 |
| vale 256 m, 64 m tiles | 4.39 M cells | 230.7 µs, 19.05 G/s | 230.1 µs, 19.09 G/s | 1.00 | 5.7% / 13.1% | 0.98 to 1.01 |
| vale 1 km, 64 m tiles | 70.29 M cells | 3.71 ms, 18.95 G/s | 3.72 ms, 18.89 G/s | 1.00 | 18.3% / 18.3% | 1.00 to 1.01 |

### Walkable triangles

`rcMarkWalkableTriangles` and `markWalkableTriangles`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 55.6 µs, 182.4 M/s | 58.7 µs, 172.8 M/s | 1.06 | 13.1% / 8.5% | 1.04 to 1.06 |
| nav_test.obj | 1612 triangles | 3.9 µs, 410.5 M/s | 3.7 µs, 437.2 M/s | 0.94 | 8.7% / 6.5% | 0.94 to 0.98 |
| undulating.obj | 5202 triangles | 8.8 µs, 590.0 M/s | 8.6 µs, 608.0 M/s | 0.97 | 3.1% / 2.0% | 0.96 to 0.97 |
| terrain 256 m | 130.1 k triangles | 225.2 µs, 577.7 M/s | 210.4 µs, 618.3 M/s | 0.93 | 6.7% / 3.0% | 0.92 to 0.94 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 244.5 µs, 557.4 M/s | 237.9 µs, 572.9 M/s | 0.97 | 15.5% / 10.7% | 0.97 to 0.98 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 224.7 µs, 610.9 M/s | 221.2 µs, 620.6 M/s | 0.98 | 8.0% / 10.7% | 0.95 to 1.01 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 3.64 ms, 611.1 M/s | 3.54 ms, 627.8 M/s | 0.97 | 6.8% / 3.7% | 0.96 to 0.98 |

### Rasterization, int indices

`rcRasterizeTriangles` and `rasterizeTriangles`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.56 ms, 2.2 M/s | 4.37 ms, 2.3 M/s | 0.96 | 2.1% / 1.3% | 0.96 to 0.96 |
| nav_test.obj | 1612 triangles | 3.11 ms, 518.6 k/s | 2.86 ms, 562.9 k/s | 0.92 | 1.5% / 1.0% | 0.92 to 0.93 |
| undulating.obj | 5202 triangles | 3.64 ms, 1.4 M/s | 3.48 ms, 1.5 M/s | 0.95 | 0.5% / 0.8% | 0.95 to 0.95 |
| terrain 256 m | 130.1 k triangles | 31.08 ms, 4.2 M/s | 29.42 ms, 4.4 M/s | 0.95 | 0.5% / 1.3% | 0.94 to 0.95 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 90.39 ms, 1.5 M/s | 81.43 ms, 1.7 M/s | 0.90 | 0.3% / 0.5% | 0.90 to 0.90 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 88.21 ms, 1.6 M/s | 79.44 ms, 1.7 M/s | 0.90 | 1.0% / 0.8% | 0.90 to 0.90 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 1423.75 ms, 1.6 M/s | 1279.60 ms, 1.7 M/s | 0.90 | 0.6% / 0.4% | 0.90 to 0.90 |

### Low hanging obstacles filter

`rcFilterLowHangingWalkableObstacles` and `filterLowHangingWalkableObstacles`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 79.8 µs, 652.7 M/s | 70.8 µs, 736.1 M/s | 0.89 | 6.7% / 4.4% | 0.88 to 0.90 |
| nav_test.obj | 120.2 k spans | 133.0 µs, 903.4 M/s | 117.8 µs, 1.02 G/s | 0.89 | 6.0% / 5.8% | 0.89 to 0.91 |
| undulating.obj | 108.7 k spans | 108.1 µs, 1.01 G/s | 98.4 µs, 1.10 G/s | 0.91 | 21.5% / 4.2% | 0.88 to 0.97 |
| terrain 256 m | 741.4 k spans | 640.9 µs, 1.16 G/s | 591.6 µs, 1.25 G/s | 0.92 | 7.1% / 9.3% | 0.91 to 0.94 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 4.09 ms, 1.08 G/s | 3.50 ms, 1.26 G/s | 0.86 | 3.8% / 2.0% | 0.86 to 0.87 |
| vale 256 m, 64 m tiles | 4.34 M spans | 3.93 ms, 1.11 G/s | 3.42 ms, 1.27 G/s | 0.87 | 3.4% / 3.0% | 0.87 to 0.88 |
| vale 1 km, 64 m tiles | 70.09 M spans | 63.14 ms, 1.11 G/s | 56.65 ms, 1.24 G/s | 0.90 | 4.0% / 3.4% | 0.89 to 0.90 |

### Ledge filter

`rcFilterLedgeSpans` and `filterLedgeSpans`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 422.6 µs, 123.3 M/s | 387.8 µs, 134.4 M/s | 0.92 | 1.7% / 1.9% | 0.92 to 0.93 |
| nav_test.obj | 120.2 k spans | 948.6 µs, 126.7 M/s | 854.2 µs, 140.7 M/s | 0.90 | 1.5% / 3.3% | 0.90 to 0.91 |
| undulating.obj | 108.7 k spans | 884.2 µs, 123.0 M/s | 793.7 µs, 137.0 M/s | 0.90 | 0.4% / 1.1% | 0.90 to 0.90 |
| terrain 256 m | 741.4 k spans | 5.55 ms, 133.6 M/s | 4.91 ms, 151.1 M/s | 0.88 | 3.8% / 3.3% | 0.88 to 0.88 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 33.60 ms, 131.2 M/s | 30.36 ms, 145.2 M/s | 0.90 | 1.0% / 2.0% | 0.90 to 0.90 |
| vale 256 m, 64 m tiles | 4.34 M spans | 33.79 ms, 128.5 M/s | 30.57 ms, 142.1 M/s | 0.90 | 0.6% / 0.8% | 0.90 to 0.90 |
| vale 1 km, 64 m tiles | 70.09 M spans | 545.44 ms, 128.5 M/s | 491.24 ms, 142.7 M/s | 0.90 | 0.9% / 1.1% | 0.90 to 0.90 |

### Low height filter

`rcFilterWalkableLowHeightSpans` and `filterWalkableLowHeightSpans`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 82.7 µs, 629.7 M/s | 70.0 µs, 744.4 M/s | 0.85 | 3.4% / 9.3% | 0.85 to 0.88 |
| nav_test.obj | 120.2 k spans | 126.0 µs, 953.8 M/s | 120.1 µs, 1.00 G/s | 0.95 | 4.4% / 6.8% | 0.94 to 0.96 |
| undulating.obj | 108.7 k spans | 96.1 µs, 1.13 G/s | 80.7 µs, 1.35 G/s | 0.84 | 5.1% / 5.4% | 0.82 to 0.86 |
| terrain 256 m | 741.4 k spans | 497.3 µs, 1.49 G/s | 439.2 µs, 1.69 G/s | 0.88 | 19.8% / 18.4% | 0.87 to 0.90 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 3.23 ms, 1.37 G/s | 2.60 ms, 1.69 G/s | 0.81 | 3.8% / 6.3% | 0.80 to 0.83 |
| vale 256 m, 64 m tiles | 4.34 M spans | 3.11 ms, 1.40 G/s | 2.47 ms, 1.76 G/s | 0.79 | 17.6% / 4.0% | 0.78 to 0.79 |
| vale 1 km, 64 m tiles | 70.09 M spans | 52.47 ms, 1.34 G/s | 43.54 ms, 1.61 G/s | 0.83 | 2.3% / 2.8% | 0.79 to 0.83 |

### Compact heightfield

`rcBuildCompactHeightfield` and `buildCompactHeightfield`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 357.8 µs, 145.6 M/s | 330.1 µs, 157.8 M/s | 0.92 | 2.9% / 13.4% | 0.92 to 0.93 |
| nav_test.obj | 120.2 k spans | 699.2 µs, 171.9 M/s | 639.1 µs, 188.1 M/s | 0.91 | 2.3% / 1.8% | 0.90 to 0.91 |
| undulating.obj | 108.7 k spans | 1.02 ms, 106.7 M/s | 897.2 µs, 121.2 M/s | 0.88 | 3.2% / 1.3% | 0.88 to 0.88 |
| terrain 256 m | 741.4 k spans | 6.30 ms, 117.8 M/s | 5.45 ms, 135.9 M/s | 0.87 | 3.5% / 3.1% | 0.86 to 0.87 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 37.48 ms, 117.6 M/s | 32.81 ms, 134.3 M/s | 0.88 | 1.1% / 1.1% | 0.88 to 0.88 |
| vale 256 m, 64 m tiles | 4.34 M spans | 38.23 ms, 113.6 M/s | 33.35 ms, 130.2 M/s | 0.87 | 0.7% / 0.7% | 0.87 to 0.87 |
| vale 1 km, 64 m tiles | 70.09 M spans | 626.69 ms, 111.8 M/s | 546.69 ms, 128.2 M/s | 0.87 | 2.1% / 2.1% | 0.87 to 0.87 |

### Erosion

`rcErodeWalkableArea` and `erodeWalkableArea`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 356.0 µs, 66.2 M/s | 351.1 µs, 67.1 M/s | 0.99 | 4.7% / 2.4% | 0.98 to 1.00 |
| nav_test.obj | 56.8 k compact spans | 683.0 µs, 83.2 M/s | 681.6 µs, 83.3 M/s | 1.00 | 2.4% / 1.4% | 0.99 to 1.01 |
| undulating.obj | 105.8 k compact spans | 1.02 ms, 103.5 M/s | 1.02 ms, 103.7 M/s | 1.00 | 1.5% / 3.1% | 0.99 to 1.00 |
| terrain 256 m | 686.7 k compact spans | 6.63 ms, 103.6 M/s | 6.61 ms, 103.9 M/s | 1.00 | 0.8% / 1.5% | 1.00 to 1.00 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 35.50 ms, 115.3 M/s | 35.15 ms, 116.5 M/s | 0.99 | 0.4% / 0.8% | 0.99 to 0.99 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 32.77 ms, 131.5 M/s | 32.67 ms, 131.9 M/s | 1.00 | 4.7% / 0.8% | 0.98 to 1.00 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 536.52 ms, 129.6 M/s | 528.69 ms, 131.6 M/s | 0.99 | 1.1% / 0.5% | 0.98 to 0.99 |

### Distance field

`rcBuildDistanceField` and `buildDistanceField`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 396.8 µs, 59.4 M/s | 435.8 µs, 54.1 M/s | 1.10 | 4.1% / 4.1% | 1.09 to 1.10 |
| nav_test.obj | 56.8 k compact spans | 760.0 µs, 74.7 M/s | 829.3 µs, 68.5 M/s | 1.09 | 1.8% / 1.1% | 1.09 to 1.10 |
| undulating.obj | 105.8 k compact spans | 1.17 ms, 90.2 M/s | 1.41 ms, 75.3 M/s | 1.20 | 4.2% / 1.9% | 1.19 to 1.20 |
| terrain 256 m | 686.7 k compact spans | 7.62 ms, 90.1 M/s | 9.01 ms, 76.2 M/s | 1.18 | 0.9% / 0.4% | 1.18 to 1.19 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 41.01 ms, 99.9 M/s | 50.94 ms, 80.4 M/s | 1.24 | 0.5% / 0.1% | 1.24 to 1.25 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 39.73 ms, 108.5 M/s | 51.69 ms, 83.4 M/s | 1.30 | 1.7% / 0.7% | 1.30 to 1.30 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 653.77 ms, 106.4 M/s | 844.18 ms, 82.4 M/s | 1.29 | 0.7% / 1.1% | 1.28 to 1.29 |

### Watershed regions

`rcBuildRegions` and `buildRegions`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 1.00 ms, 23.6 M/s | 699.3 µs, 33.7 M/s | 0.70 | 3.2% / 15.9% | 0.69 to 0.71 |
| nav_test.obj | 56.8 k compact spans | 2.50 ms, 22.7 M/s | 1.53 ms, 37.2 M/s | 0.61 | 2.2% / 3.7% | 0.60 to 0.61 |
| undulating.obj | 105.8 k compact spans | 5.02 ms, 21.1 M/s | 2.99 ms, 35.4 M/s | 0.59 | 0.6% / 3.8% | 0.58 to 0.59 |
| terrain 256 m | 686.7 k compact spans | 36.83 ms, 18.6 M/s | 21.23 ms, 32.3 M/s | 0.58 | 0.9% / 2.5% | 0.57 to 0.58 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 194.74 ms, 21.0 M/s | 118.46 ms, 34.6 M/s | 0.61 | 0.5% / 0.7% | 0.61 to 0.62 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 189.34 ms, 22.8 M/s | 165.09 ms, 26.1 M/s | 0.87 | 2.0% / 11.1% | 0.85 to 0.87 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 3085.67 ms, 22.5 M/s | 2874.36 ms, 24.2 M/s | 0.93 | 9.0% / 9.9% | 0.88 to 0.94 |

### Contours

`rcBuildContours` and `buildContours`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 235.8 µs, 100.0 M/s | 208.6 µs, 113.0 M/s | 0.88 | 10.8% / 2.7% | 0.87 to 0.89 |
| nav_test.obj | 56.8 k compact spans | 413.6 µs, 137.3 M/s | 383.4 µs, 148.1 M/s | 0.93 | 1.3% / 2.3% | 0.91 to 0.93 |
| undulating.obj | 105.8 k compact spans | 613.4 µs, 172.5 M/s | 585.8 µs, 180.6 M/s | 0.95 | 3.9% / 2.7% | 0.95 to 0.95 |
| terrain 256 m | 686.7 k compact spans | 4.58 ms, 149.8 M/s | 4.24 ms, 161.8 M/s | 0.93 | 2.6% / 2.1% | 0.92 to 0.93 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 19.47 ms, 210.3 M/s | 19.10 ms, 214.4 M/s | 0.98 | 15.8% / 0.5% | 0.98 to 0.98 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 15.25 ms, 282.6 M/s | 15.89 ms, 271.2 M/s | 1.04 | 4.6% / 4.3% | 1.04 to 1.05 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 244.58 ms, 284.4 M/s | 255.79 ms, 271.9 M/s | 1.05 | 1.0% / 0.6% | 1.05 to 1.05 |

### Polygon mesh

`rcBuildPolyMesh` and `buildPolyMesh`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 118 polygons | 202.3 µs, 583.2 k/s | 177.0 µs, 666.7 k/s | 0.87 | 3.1% / 8.4% | 0.87 to 0.87 |
| nav_test.obj | 155 polygons | 174.9 µs, 886.4 k/s | 157.4 µs, 985.0 k/s | 0.90 | 2.1% / 4.7% | 0.90 to 0.90 |
| undulating.obj | 216 polygons | 347.3 µs, 622.0 k/s | 299.8 µs, 720.6 k/s | 0.86 | 2.0% / 8.2% | 0.86 to 0.87 |
| terrain 256 m | 2580 polygons | 5.84 ms, 441.7 k/s | 5.06 ms, 510.0 k/s | 0.87 | 1.1% / 4.6% | 0.87 to 0.88 |
| terrain 256 m, 64 m tiles | 4098 polygons | 11.44 ms, 358.3 k/s | 9.88 ms, 414.8 k/s | 0.86 | 1.7% / 1.3% | 0.86 to 0.86 |
| vale 256 m, 64 m tiles | 108 polygons | 114.1 µs, 946.3 k/s | 107.4 µs, 1.0 M/s | 0.94 | 13.7% / 26.4% | 0.92 to 0.95 |
| vale 1 km, 64 m tiles | 684 polygons | 682.7 µs, 1.0 M/s | 661.7 µs, 1.0 M/s | 0.97 | 5.0% / 7.9% | 0.96 to 0.99 |

### Detail mesh

`rcBuildPolyMeshDetail` and `buildPolyMeshDetail`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 118 polygons | 375.7 µs, 314.1 k/s | 283.9 µs, 415.6 k/s | 0.76 | 1.6% / 4.6% | 0.76 to 0.77 |
| nav_test.obj | 155 polygons | 1.14 ms, 136.0 k/s | 666.6 µs, 232.5 k/s | 0.59 | 0.7% / 1.8% | 0.58 to 0.59 |
| undulating.obj | 216 polygons | 43.35 ms, 4983/s | 11.05 ms, 19.5 k/s | 0.25 | 2.8% / 1.1% | 0.25 to 0.26 |
| terrain 256 m | 2580 polygons | 35.55 ms, 72.6 k/s | 15.24 ms, 169.3 k/s | 0.43 | 0.4% / 15.3% | 0.43 to 0.43 |
| terrain 256 m, 64 m tiles | 4098 polygons | 75.08 ms, 54.6 k/s | 40.97 ms, 100.0 k/s | 0.55 | 0.6% / 0.9% | 0.55 to 0.55 |
| vale 256 m, 64 m tiles | 108 polygons | 586.30 ms, 184/s | 65.20 ms, 1656/s | 0.11 | 0.9% / 1.6% | 0.11 to 0.11 |
| vale 1 km, 64 m tiles | 684 polygons | 14120.48 ms, 48/s | 1281.96 ms, 534/s | 0.09 | 0.5% / 0.4% | 0.09 to 0.09 |

### Span count

`rcGetHeightFieldSpanCount` and `getHeightFieldSpanCount`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 52.4 µs, 994.6 M/s | 48.3 µs, 1.08 G/s | 0.92 | 14.4% / 10.8% | 0.91 to 0.98 |
| nav_test.obj | 120.2 k spans | 80.3 µs, 1.50 G/s | 80.7 µs, 1.49 G/s | 1.00 | 18.7% / 5.5% | 0.97 to 1.01 |
| undulating.obj | 108.7 k spans | 52.3 µs, 2.08 G/s | 48.2 µs, 2.26 G/s | 0.92 | 24.9% / 3.3% | 0.81 to 0.92 |
| terrain 256 m | 741.4 k spans | 349.7 µs, 2.12 G/s | 306.3 µs, 2.42 G/s | 0.88 | 50.6% / 17.1% | 0.82 to 0.90 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 1.84 ms, 2.40 G/s | 1.80 ms, 2.44 G/s | 0.98 | 5.7% / 1.7% | 0.97 to 1.05 |
| vale 256 m, 64 m tiles | 4.34 M spans | 1.70 ms, 2.56 G/s | 1.73 ms, 2.50 G/s | 1.02 | 37.1% / 1.9% | 1.02 to 1.04 |
| vale 1 km, 64 m tiles | 70.09 M spans | 27.37 ms, 2.56 G/s | 28.77 ms, 2.44 G/s | 1.05 | 13.0% / 15.3% | 1.04 to 1.07 |

### Unwalkable triangles

`rcClearUnwalkableTriangles` and `clearUnwalkableTriangles`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 57.1 µs, 177.5 M/s | 59.3 µs, 171.0 M/s | 1.04 | 4.9% / 2.5% | 1.03 to 1.06 |
| nav_test.obj | 1612 triangles | 4.0 µs, 401.2 M/s | 4.1 µs, 391.5 M/s | 1.02 | 8.2% / 16.6% | 0.99 to 1.10 |
| undulating.obj | 5202 triangles | 8.4 µs, 621.1 M/s | 8.4 µs, 617.4 M/s | 1.01 | 2.9% / 5.5% | 1.00 to 1.01 |
| terrain 256 m | 130.1 k triangles | 218.0 µs, 596.8 M/s | 209.6 µs, 620.6 M/s | 0.96 | 14.0% / 1.8% | 0.96 to 0.97 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 233.6 µs, 583.6 M/s | 230.8 µs, 590.7 M/s | 0.99 | 1.8% / 2.9% | 0.98 to 1.00 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 211.8 µs, 648.3 M/s | 213.2 µs, 644.1 M/s | 1.01 | 5.4% / 4.0% | 1.00 to 1.01 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 3.46 ms, 641.8 M/s | 3.49 ms, 637.2 M/s | 1.01 | 2.9% / 1.4% | 1.01 to 1.01 |

### Rasterization, unsigned short indices

`rcRasterizeTriangles` and `rasterizeTriangles`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.62 ms, 2.2 M/s | 4.43 ms, 2.3 M/s | 0.96 | 2.8% / 0.8% | 0.96 to 0.96 |
| nav_test.obj | 1612 triangles | 3.22 ms, 500.6 k/s | 3.00 ms, 537.9 k/s | 0.93 | 1.1% / 0.7% | 0.93 to 0.93 |
| undulating.obj | 5202 triangles | 3.70 ms, 1.4 M/s | 3.55 ms, 1.5 M/s | 0.96 | 0.4% / 1.4% | 0.96 to 0.96 |

### Rasterization, unindexed

`rcRasterizeTriangles` and `rasterizeUnindexedTriangles`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.48 ms, 2.3 M/s | 4.30 ms, 2.4 M/s | 0.96 | 0.8% / 0.6% | 0.95 to 0.96 |
| nav_test.obj | 1612 triangles | 3.08 ms, 523.1 k/s | 2.85 ms, 565.2 k/s | 0.93 | 1.2% / 4.5% | 0.93 to 0.93 |
| undulating.obj | 5202 triangles | 3.61 ms, 1.4 M/s | 3.44 ms, 1.5 M/s | 0.95 | 0.3% / 0.7% | 0.95 to 0.95 |
| terrain 256 m | 130.1 k triangles | 32.20 ms, 4.0 M/s | 30.59 ms, 4.3 M/s | 0.95 | 1.5% / 2.4% | 0.95 to 0.95 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 90.05 ms, 1.5 M/s | 80.91 ms, 1.7 M/s | 0.90 | 0.6% / 0.5% | 0.90 to 0.90 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 87.26 ms, 1.6 M/s | 78.58 ms, 1.7 M/s | 0.90 | 1.5% / 1.1% | 0.90 to 0.90 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 1406.99 ms, 1.6 M/s | 1266.11 ms, 1.8 M/s | 0.90 | 0.5% / 0.4% | 0.90 to 0.90 |

### Rasterization, one triangle at a time

`rcRasterizeTriangle` and `rasterizeTriangle`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.1 k triangles | 4.54 ms, 2.2 M/s | 4.35 ms, 2.3 M/s | 0.96 | 3.2% / 4.3% | 0.96 to 0.96 |
| nav_test.obj | 1612 triangles | 3.07 ms, 524.5 k/s | 2.85 ms, 566.5 k/s | 0.93 | 0.3% / 0.8% | 0.92 to 0.93 |
| undulating.obj | 5202 triangles | 3.61 ms, 1.4 M/s | 3.43 ms, 1.5 M/s | 0.95 | 0.8% / 0.8% | 0.95 to 0.95 |
| terrain 256 m | 130.1 k triangles | 31.66 ms, 4.1 M/s | 29.85 ms, 4.4 M/s | 0.94 | 2.4% / 1.8% | 0.94 to 0.94 |
| terrain 256 m, 64 m tiles | 136.3 k triangles | 90.28 ms, 1.5 M/s | 80.98 ms, 1.7 M/s | 0.90 | 0.6% / 0.5% | 0.90 to 0.90 |
| vale 256 m, 64 m tiles | 137.3 k triangles | 88.15 ms, 1.6 M/s | 79.03 ms, 1.7 M/s | 0.90 | 0.8% / 0.5% | 0.89 to 0.90 |
| vale 1 km, 64 m tiles | 2.22 M triangles | 1424.51 ms, 1.6 M/s | 1277.06 ms, 1.7 M/s | 0.90 | 1.1% / 0.6% | 0.89 to 0.90 |

### Adding spans, the rasterized field's again

`rcAddSpan` and `addSpan`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 52.1 k spans | 297.2 µs, 175.3 M/s | 219.1 µs, 237.9 M/s | 0.74 | 7.3% / 2.6% | 0.73 to 0.74 |
| nav_test.obj | 120.2 k spans | 662.1 µs, 181.5 M/s | 492.4 µs, 244.1 M/s | 0.74 | 3.7% / 2.7% | 0.73 to 0.74 |
| undulating.obj | 108.7 k spans | 542.5 µs, 200.4 M/s | 356.7 µs, 304.7 M/s | 0.66 | 8.5% / 9.2% | 0.66 to 0.67 |
| terrain 256 m | 741.4 k spans | 3.93 ms, 188.6 M/s | 2.83 ms, 261.6 M/s | 0.72 | 7.5% / 7.3% | 0.69 to 0.74 |
| terrain 256 m, 64 m tiles | 4.41 M spans | 17.05 ms, 258.5 M/s | 9.73 ms, 453.1 M/s | 0.57 | 2.8% / 1.7% | 0.57 to 0.58 |
| vale 256 m, 64 m tiles | 4.34 M spans | 16.52 ms, 262.9 M/s | 9.41 ms, 461.4 M/s | 0.57 | 2.5% / 5.5% | 0.57 to 0.57 |
| vale 1 km, 64 m tiles | 70.09 M spans | 268.75 ms, 260.8 M/s | 153.58 ms, 456.4 M/s | 0.57 | 1.3% / 1.5% | 0.57 to 0.57 |

### Polygon mesh copy

`rcCopyPolyMesh` and `copyPolyMesh`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 118 polygons | 27.3 µs, 4.3 M/s | 27.5 µs, 4.3 M/s | 1.01 | 31.0% / 17.4% | 0.99 to 1.05 |
| nav_test.obj | 155 polygons | 48.9 µs, 3.2 M/s | 50.0 µs, 3.1 M/s | 1.02 | 11.5% / 24.5% | 1.02 to 1.02 |
| undulating.obj | 216 polygons | 46.0 µs, 4.7 M/s | 46.0 µs, 4.7 M/s | 1.00 | 25.0% / 102.7% | 0.99 to 1.00 |
| terrain 256 m | 2580 polygons | 366.6 µs, 7.0 M/s | 389.0 µs, 6.6 M/s | 1.06 | 28.0% / 28.6% | 1.01 to 1.21 |
| terrain 256 m, 64 m tiles | 4098 polygons | 27.3 µs, 150.4 M/s | 25.6 µs, 160.2 M/s | 0.94 | 7.2% / 4.4% | 0.93 to 0.95 |
| vale 256 m, 64 m tiles | 108 polygons | 27.3 µs, 4.0 M/s | 25.6 µs, 4.2 M/s | 0.94 | 14.2% / 11.3% | 0.93 to 0.97 |
| vale 1 km, 64 m tiles | 684 polygons | 431.2 µs, 1.6 M/s | 382.7 µs, 1.8 M/s | 0.89 | 6.2% / 6.3% | 0.89 to 0.91 |

### Heightfield layers

`rcBuildHeightfieldLayers` and `buildHeightfieldLayers`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 592.4 µs, 39.8 M/s | 577.8 µs, 40.8 M/s | 0.98 | 2.3% / 2.5% | 0.96 to 0.99 |
| nav_test.obj | 56.8 k compact spans | 1.08 ms, 52.4 M/s | 1.05 ms, 54.2 M/s | 0.97 | 1.7% / 1.7% | 0.97 to 0.97 |
| undulating.obj | 105.8 k compact spans | 1.54 ms, 68.7 M/s | 1.46 ms, 72.5 M/s | 0.95 | 1.6% / 3.1% | 0.94 to 0.95 |
| terrain 256 m | 686.7 k compact spans | fails | fails | | | |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 55.58 ms, 73.7 M/s | 53.58 ms, 76.4 M/s | 0.96 | 5.6% / 2.6% | 0.96 to 0.96 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 51.05 ms, 84.4 M/s | 49.18 ms, 87.6 M/s | 0.96 | 1.4% / 2.8% | 0.95 to 0.97 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 815.71 ms, 85.3 M/s | 776.35 ms, 89.6 M/s | 0.95 | 1.0% / 0.6% | 0.95 to 0.96 |

### Monotone regions

`rcBuildRegionsMonotone` and `buildRegionsMonotone`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 313.0 µs, 75.3 M/s | 266.2 µs, 88.5 M/s | 0.85 | 2.4% / 3.2% | 0.83 to 0.85 |
| nav_test.obj | 56.8 k compact spans | 654.4 µs, 86.8 M/s | 523.1 µs, 108.6 M/s | 0.80 | 3.7% / 2.4% | 0.79 to 0.81 |
| undulating.obj | 105.8 k compact spans | 960.9 µs, 110.1 M/s | 782.3 µs, 135.2 M/s | 0.81 | 1.8% / 5.6% | 0.81 to 0.82 |
| terrain 256 m | 686.7 k compact spans | 20.14 ms, 34.1 M/s | 7.95 ms, 86.4 M/s | 0.39 | 0.9% / 9.5% | 0.39 to 0.40 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 33.48 ms, 122.3 M/s | 26.08 ms, 157.0 M/s | 0.78 | 0.8% / 3.6% | 0.77 to 0.78 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 28.12 ms, 153.3 M/s | 22.54 ms, 191.2 M/s | 0.80 | 1.7% / 2.1% | 0.79 to 0.81 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 459.89 ms, 151.2 M/s | 367.95 ms, 189.0 M/s | 0.80 | 0.6% / 2.8% | 0.80 to 0.80 |

### Layer regions

`rcBuildLayerRegions` and `buildLayerRegions`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 363.4 µs, 64.9 M/s | 344.7 µs, 68.4 M/s | 0.95 | 2.6% / 5.2% | 0.94 to 0.95 |
| nav_test.obj | 56.8 k compact spans | 791.4 µs, 71.8 M/s | 718.2 µs, 79.1 M/s | 0.91 | 0.9% / 0.7% | 0.90 to 0.91 |
| undulating.obj | 105.8 k compact spans | 1.22 ms, 86.9 M/s | 1.18 ms, 89.5 M/s | 0.97 | 1.7% / 1.4% | 0.97 to 0.98 |
| terrain 256 m | 686.7 k compact spans | 8.61 ms, 79.7 M/s | 7.92 ms, 86.7 M/s | 0.92 | 1.0% / 5.2% | 0.92 to 0.93 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 46.30 ms, 88.4 M/s | 43.63 ms, 93.8 M/s | 0.94 | 0.7% / 1.3% | 0.94 to 0.95 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 45.76 ms, 94.2 M/s | 45.08 ms, 95.6 M/s | 0.99 | 1.4% / 1.6% | 0.95 to 0.99 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 725.82 ms, 95.8 M/s | 721.01 ms, 96.5 M/s | 0.99 | 4.0% / 1.2% | 0.99 to 0.99 |

### Median area filter

`rcMedianFilterWalkableArea` and `medianFilterWalkableArea`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 163.4 µs, 144.2 M/s | 172.5 µs, 136.7 M/s | 1.06 | 2.4% / 0.9% | 1.05 to 1.06 |
| nav_test.obj | 56.8 k compact spans | 358.6 µs, 158.4 M/s | 363.0 µs, 156.5 M/s | 1.01 | 2.8% / 3.1% | 1.01 to 1.02 |
| undulating.obj | 105.8 k compact spans | 660.2 µs, 160.2 M/s | 661.8 µs, 159.9 M/s | 1.00 | 1.2% / 1.3% | 1.00 to 1.00 |
| terrain 256 m | 686.7 k compact spans | 4.29 ms, 160.2 M/s | 4.28 ms, 160.5 M/s | 1.00 | 1.2% / 1.7% | 1.00 to 1.00 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 25.09 ms, 163.2 M/s | 25.18 ms, 162.6 M/s | 1.00 | 0.8% / 0.5% | 1.00 to 1.00 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 26.79 ms, 160.9 M/s | 26.77 ms, 161.0 M/s | 1.00 | 5.1% / 0.6% | 1.00 to 1.00 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 432.45 ms, 160.8 M/s | 432.85 ms, 160.7 M/s | 1.00 | 0.9% / 0.8% | 1.00 to 1.00 |

### Box area

`rcMarkBoxArea` and `markBoxArea`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 16.1 µs, 1.47 G/s | 12.7 µs, 1.85 G/s | 0.79 | 12.3% / 6.7% | 0.79 to 0.82 |
| nav_test.obj | 56.8 k compact spans | 26.3 µs, 2.16 G/s | 25.2 µs, 2.25 G/s | 0.96 | 7.8% / 16.6% | 0.94 to 0.98 |
| undulating.obj | 105.8 k compact spans | 29.7 µs, 3.57 G/s | 24.5 µs, 4.32 G/s | 0.83 | 3.6% / 7.5% | 0.82 to 0.87 |
| terrain 256 m | 686.7 k compact spans | 162.5 µs, 4.23 G/s | 152.3 µs, 4.51 G/s | 0.94 | 2.8% / 17.6% | 0.93 to 0.94 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 904.3 µs, 4.53 G/s | 783.8 µs, 5.22 G/s | 0.87 | 7.5% / 2.9% | 0.84 to 0.87 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 791.3 µs, 5.45 G/s | 674.8 µs, 6.39 G/s | 0.85 | 1.5% / 1.5% | 0.85 to 0.86 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 12.82 ms, 5.43 G/s | 11.05 ms, 6.30 G/s | 0.86 | 1.1% / 0.9% | 0.85 to 0.86 |

### Convex area

`rcMarkConvexPolyArea` and `markConvexPolyArea`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 21.9 µs, 1.08 G/s | 18.9 µs, 1.25 G/s | 0.86 | 13.5% / 3.7% | 0.86 to 0.87 |
| nav_test.obj | 56.8 k compact spans | 57.9 µs, 980.6 M/s | 48.7 µs, 1.17 G/s | 0.84 | 4.7% / 2.1% | 0.84 to 0.85 |
| undulating.obj | 105.8 k compact spans | 97.8 µs, 1.08 G/s | 82.4 µs, 1.28 G/s | 0.84 | 0.6% / 0.9% | 0.84 to 0.84 |
| terrain 256 m | 686.7 k compact spans | 616.5 µs, 1.11 G/s | 516.2 µs, 1.33 G/s | 0.84 | 2.5% / 1.5% | 0.84 to 0.84 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 3.84 ms, 1.07 G/s | 3.19 ms, 1.29 G/s | 0.83 | 1.4% / 0.8% | 0.83 to 0.83 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 3.94 ms, 1.10 G/s | 3.28 ms, 1.31 G/s | 0.83 | 2.1% / 0.8% | 0.83 to 0.83 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 62.73 ms, 1.11 G/s | 52.39 ms, 1.33 G/s | 0.84 | 0.3% / 0.5% | 0.84 to 0.84 |

### Cylinder area

`rcMarkCylinderArea` and `markCylinderArea`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 23.6 k compact spans | 23.0 µs, 1.02 G/s | 18.5 µs, 1.27 G/s | 0.80 | 3.2% / 9.1% | 0.78 to 0.80 |
| nav_test.obj | 56.8 k compact spans | 30.7 µs, 1.85 G/s | 24.4 µs, 2.32 G/s | 0.80 | 4.4% / 4.1% | 0.80 to 0.81 |
| undulating.obj | 105.8 k compact spans | 41.7 µs, 2.54 G/s | 31.1 µs, 3.40 G/s | 0.75 | 12.2% / 2.4% | 0.74 to 0.79 |
| terrain 256 m | 686.7 k compact spans | 241.4 µs, 2.84 G/s | 186.1 µs, 3.69 G/s | 0.77 | 4.9% / 2.8% | 0.76 to 0.79 |
| terrain 256 m, 64 m tiles | 4.09 M compact spans | 1.39 ms, 2.95 G/s | 1.09 ms, 3.75 G/s | 0.79 | 1.9% / 1.6% | 0.78 to 0.79 |
| vale 256 m, 64 m tiles | 4.31 M compact spans | 1.21 ms, 3.55 G/s | 1.03 ms, 4.20 G/s | 0.84 | 3.5% / 1.8% | 0.82 to 0.85 |
| vale 1 km, 64 m tiles | 69.56 M compact spans | 19.44 ms, 3.58 G/s | 16.28 ms, 4.27 G/s | 0.84 | 1.6% / 0.8% | 0.83 to 0.84 |

### Polygon mesh merge, every tile

`rcMergePolyMeshes` and `mergePolyMeshes`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| terrain 256 m, 64 m tiles | 4098 polygons | 257.5 µs, 15.9 M/s | 260.5 µs, 15.7 M/s | 1.01 | 2.3% / 2.3% | 1.01 to 1.02 |
| vale 256 m, 64 m tiles | 108 polygons | 9.0 µs, 12.0 M/s | 10.1 µs, 10.7 M/s | 1.12 | 16.6% / 20.5% | 1.05 to 1.17 |
| vale 1 km, 64 m tiles | 684 polygons | 51.2 µs, 13.4 M/s | 50.0 µs, 13.7 M/s | 0.98 | 28.3% / 40.3% | 0.94 to 1.12 |

### Detail mesh merge, every tile

`rcMergePolyMeshDetails` and `mergePolyMeshDetails`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| terrain 256 m, 64 m tiles | 4098 polygons | 40.6 µs, 100.9 M/s | 20.0 µs, 204.6 M/s | 0.49 | 11.0% / 36.6% | 0.48 to 0.49 |
| vale 256 m, 64 m tiles | 108 polygons | 10.0 µs, 10.8 M/s | 4.8 µs, 22.3 M/s | 0.48 | 21.8% / 65.9% | 0.48 to 0.49 |
| vale 1 km, 64 m tiles | 684 polygons | 147.7 µs, 4.6 M/s | 76.5 µs, 8.9 M/s | 0.52 | 16.1% / 36.9% | 0.52 to 0.54 |

### Bounds

`rcCalcBounds` and `calcBounds`.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 5101 vertices | 10.5 µs, 484.9 M/s | 2.9 µs, 1.77 G/s | 0.27 | 0.7% / 2.8% | 0.27 to 0.28 |
| nav_test.obj | 884 vertices | 1.9 µs, 471.7 M/s | 0.6 µs, 1.60 G/s | 0.29 | 2.1% / 9.1% | 0.29 to 0.30 |
| undulating.obj | 2800 vertices | 5.8 µs, 479.4 M/s | 1.6 µs, 1.74 G/s | 0.28 | 0.5% / 4.4% | 0.27 to 0.28 |
| terrain 256 m | 66.8 k vertices | 139.2 µs, 479.8 M/s | 37.7 µs, 1.77 G/s | 0.27 | 1.7% / 4.1% | 0.27 to 0.27 |
| terrain 256 m, 64 m tiles | 66.8 k vertices | 139.2 µs, 479.8 M/s | 37.7 µs, 1.77 G/s | 0.27 | 2.4% / 3.5% | 0.27 to 0.27 |
| vale 256 m, 64 m tiles | 66.0 k vertices | 137.4 µs, 480.6 M/s | 37.2 µs, 1.78 G/s | 0.27 | 2.6% / 0.9% | 0.27 to 0.27 |
| vale 1 km, 64 m tiles | 1.05 M vertices | 2.16 ms, 485.4 M/s | 596.9 µs, 1.76 G/s | 0.28 | 1.3% / 4.2% | 0.28 to 0.28 |

### Grid size

`rcCalcGridSize` and `calcGridSize`, per call.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.0 k calls | 1.0 ns | 1.2 ns | 1.17 | 0.8% / 2.5% | 1.17 to 1.17 |
| nav_test.obj | 10.0 k calls | 1.0 ns | 1.2 ns | 1.17 | 1.0% / 2.7% | 1.17 to 1.17 |
| undulating.obj | 10.0 k calls | 1.0 ns | 1.2 ns | 1.17 | 28.2% / 3.5% | 1.17 to 1.19 |
| terrain 256 m | 10.0 k calls | 1.0 ns | 1.2 ns | 1.18 | 1.0% / 2.5% | 1.17 to 1.20 |
| terrain 256 m, 64 m tiles | 10.0 k calls | 1.0 ns | 1.2 ns | 1.17 | 0.8% / 3.1% | 1.17 to 1.19 |
| vale 256 m, 64 m tiles | 10.0 k calls | 1.0 ns | 1.2 ns | 1.19 | 0.6% / 18.7% | 1.19 to 1.20 |
| vale 1 km, 64 m tiles | 10.0 k calls | 1.0 ns | 1.2 ns | 1.18 | 1.6% / 30.1% | 1.18 to 1.19 |

### Polygon offset, a hexagon

`rcOffsetPoly` and `offsetPoly`, per call.

| input | work | original | port | port ÷ original | spread, original / port | port ÷ original, 3 runs |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| dungeon.obj | 10.0 k calls | 34.9 ns | 26.6 ns | 0.76 | 9.9% / 1.5% | 0.76 to 0.76 |
| nav_test.obj | 10.0 k calls | 35.2 ns | 26.7 ns | 0.76 | 1.9% / 1.2% | 0.76 to 0.76 |
| undulating.obj | 10.0 k calls | 35.0 ns | 26.9 ns | 0.77 | 0.8% / 1.9% | 0.76 to 0.77 |
| terrain 256 m | 10.0 k calls | 35.3 ns | 26.8 ns | 0.76 | 2.5% / 1.4% | 0.76 to 0.76 |
| terrain 256 m, 64 m tiles | 10.0 k calls | 35.1 ns | 26.7 ns | 0.76 | 0.9% / 0.9% | 0.76 to 0.76 |
| vale 256 m, 64 m tiles | 10.0 k calls | 35.2 ns | 26.8 ns | 0.76 | 1.5% / 1.6% | 0.76 to 0.76 |
| vale 1 km, 64 m tiles | 10.0 k calls | 34.5 ns | 26.7 ns | 0.77 | 1.4% / 3.0% | 0.77 to 0.77 |
