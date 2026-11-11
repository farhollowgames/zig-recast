# Status

Every public function, type, constant and mode of Recast in
recastnavigation 1.6.0 (commit `9f4ce64`, pinned in `build.zig.zon` for the
tests and the benchmark only), from `Recast.h`, `RecastAlloc.h` and
`RecastAssert.h`, and its state:

- **not started**;
- **ported**: translated;
- **oracle-tested**: tests run the original and the port on the same
  inputs and compare every output byte, return value, log message and timer
  call;
- **benchmarked**: timed against the original by `zig build bench`, with
  its own table in the README;
- **reviewed**: a reviewer that did not write the port has tried to break
  it.

Nothing is reviewed yet. Every feature below is at least oracle-tested,
except the allocation functions, which have no output to compare.

## The tests

The pipeline tests (meshes, scenes, edges) compare each structure field by
field after every step. The tile tests compare the logs and each tile's
poly mesh and detail mesh, and the merges of them, but not the steps
between. The named tests are in `test/`; these sets run many of them:

- **meshes**: RecastDemo's three meshes (`dungeon`, `nav_test`,
  `undulating`) and a generated terrain with cliffs, holes, pillars, stairs,
  stacked floors and a bridge, through every step, under RecastDemo's
  settings and many others, every partition, contour flag and vertex limit
  (`differential.zig`).
- **scenes**: seeded fuzzing of whole builds: 1,200 random scenes of
  triangles, added spans, filters, area marks, partitions, settings and
  tiles, every eighth built twice by the port (`fuzz.zig`).
- **edges**: hand-made cases through the whole build: empty, one triangle,
  one span, the limit of every counter, degenerate triangles (`edges.zig`).
- **upstream**: upstream's own `Tests/Recast` cases, section by section,
  run on both sides (`upstream_tests.zig`).

Each fuzz test runs at least 1,000 cases and prints its seed on a failure;
setting `replay` in `fuzz.zig` reruns that case alone. Recast has no
threads of its own; "tiles build the same on every thread count, as the
original builds them" builds a tiled navmesh on 1, 2 and 8 threads.

## Recast.h and Recast.cpp

| upstream | zig-recast | tests | state |
| --- | --- | --- | --- |
| `rcContext`: `log`, `resetLog`, `enableLog`, `startTimer`, `stopTimer`, `resetTimers`, `enableTimer`, `getAccumulatedTime`, the `do…` virtual methods | `Context`, with a `Sink` for the virtual methods | "the context logs, cuts messages and times as the original's"; every oracle test compares log and timer calls | oracle-tested |
| `rcContext(bool state = true)` | `Context`'s `log_enabled` and `timer_enabled`, both true unless set | as above | oracle-tested |
| default arguments: `flagMergeThreshold = 1` on the three rasterize functions, `buildFlags = RC_CONTOUR_TESS_WALL_EDGES` on `rcBuildContours` | Zig has no default arguments: callers pass the threshold, and `ContourBuildFlags.default` is the wall-edge flag | the rasterization and contour rows | oracle-tested |
| `rcScopedTimer` | `startTimer` with `defer stopTimer` | every oracle test compares timer calls | oracle-tested |
| `rcLogCategory`, `rcTimerLabel`, `RC_MAX_TIMERS` | `LogCategory`, `TimerLabel`, `max_timers` | "constants, log categories and timer labels have the original's values" | oracle-tested |
| `RC_PI`, `RC_SPAN_HEIGHT_BITS`, `RC_SPAN_MAX_HEIGHT`, `RC_SPANS_PER_POOL`, `RC_BORDER_REG`, `RC_MULTIPLE_REGS`, `RC_BORDER_VERTEX`, `RC_AREA_BORDER`, `RC_CONTOUR_REG_MASK`, `RC_MESH_NULL_IDX`, `RC_NULL_AREA`, `RC_WALKABLE_AREA`, `RC_NOT_CONNECTED` | the same in snake case (`span_max_height`) | as above | oracle-tested |
| `rcBuildContoursFlags`: `RC_CONTOUR_TESS_WALL_EDGES`, `RC_CONTOUR_TESS_AREA_EDGES` | `ContourBuildFlags` | as above; "contours and polygons match for every contour flag and vertex limit" | oracle-tested |
| `rcConfig`, all 19 fields | `Config` | meshes; scenes | oracle-tested |
| `rcSpan`, `rcSpanPool`, `rcHeightfield` | `Span`, `SpanPool`, `Heightfield` | every heightfield compared column by column | oracle-tested |
| `rcCompactCell`, `rcCompactSpan`, `rcCompactHeightfield` | `CompactCell`, `CompactSpan`, `CompactHeightfield` | every compact heightfield compared | oracle-tested |
| `rcHeightfieldLayer`, `rcHeightfieldLayerSet` | `HeightfieldLayer`, `HeightfieldLayerSet` | every layer set compared | oracle-tested |
| `rcContour`, `rcContourSet`, `rcPolyMesh`, `rcPolyMeshDetail` | `Contour`, `ContourSet`, `PolyMesh`, `PolyMeshDetail` | every contour set and mesh compared | oracle-tested |
| `rcAllocHeightfield`, `rcFreeHeightField`, `rcAllocCompactHeightfield`, `rcFreeCompactHeightfield`, `rcAllocHeightfieldLayerSet`, `rcFreeHeightfieldLayerSet`, `rcAllocContourSet`, `rcFreeContourSet`, `rcAllocPolyMesh`, `rcFreePolyMesh`, `rcAllocPolyMeshDetail`, `rcFreePolyMeshDetail` | the functions that build a structure return it, and its `deinit` frees it | every test runs on `std.testing.allocator`, which fails on leaks and double frees | ported |
| `rcCreateHeightfield` | `Heightfield.init` | upstream; meshes; scenes | benchmarked |
| `rcCalcBounds`, `rcCalcGridSize` | `calcBounds`, `calcGridSize` | "fuzz: bounds and grid sizes match, with odd floats"; upstream; scenes | benchmarked |
| `rcMarkWalkableTriangles`, `rcClearUnwalkableTriangles` | `markWalkableTriangles`, `clearUnwalkableTriangles` | "fuzz: triangles are marked and cleared the same at any slope"; "walkable triangles match at every slope"; "slope thresholds are cosines correctly rounded, as the original's linked cosf gives"; upstream | benchmarked |
| `rcGetHeightFieldSpanCount` | `getHeightFieldSpanCount` | meshes; scenes | benchmarked |
| `rcBuildCompactHeightfield` | `buildCompactHeightfield` | meshes; scenes; "fuzz: spans added directly merge, filter and compact as the original's"; "a column of more than 63 floors logs too many layers as the original"; "a column of more walkable spans than a compact cell counts wraps as the original's" | benchmarked |
| `rcSetCon`, `rcGetCon` | `setCon`, `getCon` | "fuzz: span connections set and get the same bits" | oracle-tested |
| `rcGetDirOffsetX`, `rcGetDirOffsetY`, `rcGetDirForOffset` | `getDirOffsetX`, `getDirOffsetY`, `getDirForOffset` | "directions and their offsets match for every direction", over every input | oracle-tested |
| `rcMin`, `rcMax`, `rcClamp`, `rcSqrt` | `selectMin`, `selectMax`, `clamp`, `@sqrt` | "fuzz: min, max, clamp, square root and float to int match C++"; upstream | oracle-tested |
| `rcVcross`, `rcVdot`, `rcVmad`, `rcVadd`, `rcVsub`, `rcVmin`, `rcVmax`, `rcVdist`, `rcVdistSqr`, `rcVnormalize` | `vcross`, `vdot`, `vmad`, `vadd`, `vsub`, `vmin`, `vmax`, `vdist`, `vdistSqr`, `vnormalize` | "fuzz: vector helpers give the same floats"; upstream | oracle-tested |
| C's `(int)` of a float | `truncateToInt` | "fuzz: min, max, clamp, square root and float to int match C++" | oracle-tested |

The connection, direction, scalar and vector helpers are timed only inside
the benchmarked steps that call them: on their own, each is a few
instructions.

## RecastRasterization.cpp

| upstream | zig-recast | tests | state |
| --- | --- | --- | --- |
| `rcAddSpan`, with its span pools | `addSpan` | "fuzz: spans added directly merge, filter and compact as the original's"; "spans added directly merge, wrap and filter as the original's"; "spans at the top of the height range build as the original"; upstream, with "allocSpan: more spans than a pool holds take another pool, as upstream's" | benchmarked |
| `rcRasterizeTriangle` | `rasterizeTriangle` | "fuzz: random triangles rasterize the same through every entry point"; "fuzz: triangles out to the vertex range rasterize as the original's, and past it fail"; "every rasterization entry point matches on crafted triangles"; "degenerate triangles build as the original"; "triangles with an x or z out of range fail, the same in every build"; "a field farther out than the vertex range fails instead of overrunning the clipper"; upstream | benchmarked |
| `rcRasterizeTriangles`, `int` indices | `rasterizeTriangles(…, i32, …)` | as above; meshes; scenes | benchmarked |
| `rcRasterizeTriangles`, `unsigned short` indices | `rasterizeTriangles(…, u16, …)` | as above | benchmarked |
| `rcRasterizeTriangles`, unindexed | `rasterizeUnindexedTriangles` | as above | benchmarked |

## RecastFilter.cpp

| upstream | zig-recast | tests | state |
| --- | --- | --- | --- |
| `rcFilterLowHangingWalkableObstacles` | `filterLowHangingWalkableObstacles` | upstream; "fuzz: spans added directly merge, filter and compact as the original's"; meshes; scenes | benchmarked |
| `rcFilterLedgeSpans` | `filterLedgeSpans` | as above | benchmarked |
| `rcFilterWalkableLowHeightSpans` | `filterWalkableLowHeightSpans` | as above | benchmarked |

## RecastArea.cpp

| upstream | zig-recast | tests | state |
| --- | --- | --- | --- |
| `rcErodeWalkableArea` | `erodeWalkableArea` | "erosion of every radius matches"; meshes; scenes | benchmarked |
| `rcMedianFilterWalkableArea` | `medianFilterWalkableArea` | "area marks match inside, across and outside the field"; scenes | benchmarked |
| `rcMarkBoxArea`, `rcMarkConvexPolyArea`, `rcMarkCylinderArea` | `markBoxArea`, `markConvexPolyArea`, `markCylinderArea` | "area marks match inside, across and outside the field"; scenes | benchmarked |
| `rcOffsetPoly` | `offsetPoly` | "fuzz: polygons offset the same, including into short buffers"; "offsetPoly matches on both windings, degenerate corners and short buffers" | benchmarked |

## RecastRegion.cpp

| upstream | zig-recast | tests | state |
| --- | --- | --- | --- |
| `rcBuildDistanceField` | `buildDistanceField` | meshes; scenes | benchmarked |
| `rcBuildRegions` (watershed) | `buildRegions` | "regions build the same with borders and area limits"; "more regions than 16 bits hold fail the watershed as the original"; meshes; scenes | benchmarked |
| `rcBuildRegionsMonotone` | `buildRegionsMonotone` | "regions build the same with borders and area limits"; edges; meshes; scenes | benchmarked |
| `rcBuildLayerRegions` | `buildLayerRegions` | as above | benchmarked |

## RecastContour.cpp

| upstream | zig-recast | tests | state |
| --- | --- | --- | --- |
| `rcBuildContours`, with each combination of its two flags | `buildContours` | "contours and polygons match for every contour flag and vertex limit"; meshes; scenes | benchmarked |

## RecastMesh.cpp

| upstream | zig-recast | tests | state |
| --- | --- | --- | --- |
| `rcBuildPolyMesh`, at vertex limits from 3 to 12 | `buildPolyMesh` | "contours and polygons match for every contour flag and vertex limit"; "more contour vertices than a mesh indexes fail the polygon mesh as the original"; meshes; scenes | benchmarked |
| `rcMergePolyMeshes` | `mergePolyMeshes` | "tiles build the same on every thread count, as the original builds them"; scenes | benchmarked |
| `rcCopyPolyMesh` | `copyPolyMesh` | scenes | benchmarked |

## RecastMeshDetail.cpp

| upstream | zig-recast | tests | state |
| --- | --- | --- | --- |
| `rcBuildPolyMeshDetail` | `buildPolyMeshDetail` | "detail meshes match for every sample distance and error"; meshes; scenes | benchmarked |
| `rcMergePolyMeshDetails` | `mergePolyMeshDetails` | "tiles build the same on every thread count, as the original builds them"; scenes | benchmarked |

## RecastLayers.cpp

| upstream | zig-recast | tests | state |
| --- | --- | --- | --- |
| `rcBuildHeightfieldLayers` | `buildHeightfieldLayers` | "heightfield layers build the same with borders"; "more than 255 layer regions fail the heightfield layers as the original"; "a floor under more platforms than a layer holds fails the layers as the original"; meshes; scenes | benchmarked |

## Left out, for the author's approval

| upstream | why | in its place |
| --- | --- | --- |
| `rcSwap`, `rcAbs`, `rcSqr`, `rcVcopy`, `rcIgnoreUnused` | Zig has them built in | `std.mem.swap`, `@abs` (upstream calls `rcAbs` only on integers and `fabsf` on floats, which `@abs` matches), `x * x`, assignment, `_ =` |
| `rcAllocSetCustom`, `rcAlloc`, `rcFree`, `rcAllocHint` with `RC_ALLOC_PERM` and `RC_ALLOC_TEMP`, `rcAllocFunc`, `rcFreeFunc`, `rcNewTag`, `rcScopedDelete`, `rcSizeType`, `RC_SIZE_MAX` | Zig passes allocators, and sizes are `usize` | a `std.mem.Allocator` parameter on every function that allocates; `defer` |
| `rcVectorBase`, `rcTempVector`, `rcPermVector`, and their tests (`Tests_Alloc.cpp`, `Bench_rcVector.cpp`) | a container std already has | `std.ArrayList` |
| `rcLikely`, `rcUnlikely` | compiler hints, with no behaviour | none |
| `rcAssert`, `rcAssertFailFunc`, `rcAssertFailSetCustom`, `rcAssertFailGetCustom` | Zig has assertions and a replaceable panic handler | `std.debug.assert`; the panic handler |
| DebugUtils (`RecastDebugDraw`, `RecastDump`) | not part of Recast's library: debug drawing and text dumps for RecastDemo | none |

## Malformed input, and where upstream is undefined

Recast reads no files or bytes, so it has no decoder or parser to feed
corrupted input. Its inputs are numbers and arrays, and the tests feed it
odd ones: NaN, infinite, denormal and huge heights, degenerate and
zero-area triangles, output buffers too short, and every counter at its
limit. Both sides give the same bytes on all of them.

Inputs a caller cannot validly pass are caller errors, which upstream
leaves undefined: cells of size 0 or less, a width and height whose
product overflows, triangle indices out of range, `addSpan` columns outside
the field and the bounds of no vertices. The port does not promise the
original's result on them. Rasterization refuses every triangle on cells
of size 0 or less (`error.NonFiniteVertex`); in Debug and ReleaseSafe the
port stops on the last four, with an integer overflow, an index out of
bounds or an assertion. It stops the same way on these, where the original
reads past its buffers, truncates, returns an empty mesh or fails to
allocate:

- poly meshes of different `nvp` merged: both sides read each mesh with the
  first mesh's `nvp`, and where that runs past a mesh's polygons, the port
  stops;
- a negative contour, vertex or polygon count, or an `nvp` of 0;
- `buildRegions` on a field with no distance field;
- an `nvp` past 65536, or sizes whose product passes 2^31 (the original
  truncates the first and computes the second in `size_t`).

`rcMergePolyMeshDetails` skips null entries in its array; the port takes a
slice of pointers, which holds none.

Upstream also writes past its buffers on some inputs a caller could pass.
The tests keep the original away from them, and `doc/parity.md` says what
the port does:

- **Far triangles.** Where a cell is only a few float steps wide, rounding
  while the rasterizer clips a triangle to the cells makes polygons of more
  vertices than its buffers hold, and the original writes past them on its
  stack. That starts at about 2^23.5 cells from the origin for a field that
  far out, about 2^26.5 for triangles reaching that far over a field near
  the origin, and with an x or z that is not finite. The port refuses, in
  every build, a triangle with an x or z that is not finite or is
  `vertex_cells_max` (2^22) cells or more from the origin: it logs it and
  returns `error.NonFiniteVertex` before clipping it.
- **Long rows.** A row with more sweeps than the field is wide (the
  heightfield layers), or than its longer side less one (the monotone and
  layer partitions), overruns the original's sweep buffer. The port's
  buffers hold every row.
- **Polygons of more than 127 vertices** (a poly mesh's `nvp` of 128 or
  more) overrun the original's hull buffer in the detail mesh, and past 256
  its vertex buffer. The port stops on them in Debug and ReleaseSafe; in
  ReleaseFast it overruns its own hull buffer.
- **A detail sample distance of 0 or less.** The original never returns;
  the port triangulates the polygon's own vertices.
- **Out of memory.** The original carries on after some failed
  allocations; the port fails the build.

## Next

1. A performance pass by a fresh agent, against the README's tables.
2. A skeptic's review, then fixes, then a release.
