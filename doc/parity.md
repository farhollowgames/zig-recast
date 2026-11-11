# Feature parity with the original

zig-recast aims to do everything Recast 1.6.0 does, with identical output.
This file lists every public function and type of the original, what
corresponds to it in zig-recast, and the test that shows they give the same
bytes. The tests are in `test/differential.zig` and run with
`zig build test`: each builds the original from source (test-only code)
and the port on the same input, and requires every structure, every log
message and every timer call to be identical.

## Conventions

- Every build function takes a `recast.Context` first, then a
  `std.mem.Allocator`, then the original's parameters in its order; counts
  that slices carry are dropped.
- Functions that fill a structure the caller allocated (`rcBuildContours`
  into an `rcContourSet&`) return it instead, and its `deinit` frees it.
- Where the original logs an error and returns false, the port logs the
  same message and returns an error: `error.OutOfMemory`, or one named
  after the message (`error.RegionIdOverflow`, `error.LayerOverflow`, ...).
  Where the original ignores a failed allocation, the port logs what it
  logs and fails.
- Structures keep the original's fields and allocation sizes, in
  snake_case; counted arrays are slices of the whole allocation, with the
  original's counts beside them.

## Recast.h and Recast.cpp

| original | zig-recast | test |
| --- | --- | --- |
| `rcContext`, `log`, `resetLog`, `enableLog`, `startTimer`, `stopTimer`, `resetTimers`, `enableTimer`, `getAccumulatedTime`, the virtual `do…` methods | `Context` with an optional `Sink` (pointer and vtable) | every test compares the logs; "log messages are cut as the original cuts them" |
| `rcScopedTimer` | `ctx.startTimer` with `defer ctx.stopTimer` | every test compares the timer calls |
| `rcLogCategory`, `rcTimerLabel` | `LogCategory`, `TimerLabel` (same values) | as above |
| `rcConfig` | `Config` | the pipeline tests build one as RecastDemo and Loomwork do |
| `rcSpan`, `rcSpanPool`, `rcHeightfield`, `rcAllocHeightfield`, `rcCreateHeightfield`, `rcFreeHeightField` | `Span`, `SpanPool`, `Heightfield.init`, `Heightfield.deinit` | every heightfield dump |
| `rcCompactCell`, `rcCompactSpan`, `rcCompactHeightfield` and its alloc/free | `CompactCell`, `CompactSpan` (packed), `CompactHeightfield` | every compact heightfield dump |
| `rcHeightfieldLayer`, `rcHeightfieldLayerSet` and alloc/free | `HeightfieldLayer`, `HeightfieldLayerSet` | "heightfield layers build the same with borders" |
| `rcContour`, `rcContourSet` and alloc/free | `Contour`, `ContourSet` | contour dumps |
| `rcPolyMesh`, `rcPolyMeshDetail` and alloc/free | `PolyMesh`, `PolyMeshDetail` | poly mesh and detail dumps |
| `RC_*` constants, `rcBuildContoursFlags` | snake_case constants, `ContourBuildFlags` | contour and mesh tests |
| `rcSetCon`, `rcGetCon`, `rcGetDirOffsetX`, `rcGetDirOffsetY`, `rcGetDirForOffset` | `setCon`, `getCon`, `getDirOffsetX`, `getDirOffsetY`, `getDirForOffset` | unit test; every compact heightfield |
| `rcMin`, `rcMax`, `rcClamp`, `rcSqr`, `rcAbs`, `rcSwap`, `rcSqrt`, `rcVcross`, `rcVdot`, `rcVmad`, `rcVadd`, `rcVsub`, `rcVmin`, `rcVmax`, `rcVcopy`, `rcVdist`, `rcVdistSqr`, `rcVnormalize` | `selectMin`, `selectMax`, `clamp`, `@abs`, `std.mem.swap`, `@sqrt`, `vcross`, `vdot`, `vmad`, `vadd`, `vsub`, `vmin`, `vmax`, assignment, `vdist`, `vdistSqr`, `vnormalize` | through every test |
| `rcCalcBounds`, `rcCalcGridSize` | `calcBounds`, `calcGridSize` | pipeline tests compare both |
| `rcMarkWalkableTriangles`, `rcClearUnwalkableTriangles` | `markWalkableTriangles`, `clearUnwalkableTriangles` | "walkable triangles match at every slope", "slope thresholds round as the original's cosf" |
| `rcGetHeightFieldSpanCount` | `getHeightFieldSpanCount` | pipeline tests |
| `rcBuildCompactHeightfield` | `buildCompactHeightfield` | pipeline tests; "a column of more than 63 floors logs too many layers as the original" |

## RecastAlloc and RecastAssert

| original | zig-recast | test |
| --- | --- | --- |
| `rcAllocSetCustom`, `rcAlloc`, `rcFree`, `rcAllocHint` | a `std.mem.Allocator` per call | the tests run on `std.testing.allocator`, which finds leaks and double frees |
| `rcTempVector`, `rcPermVector`, `rcNew`, `rcDelete` | `std.ArrayList`, `create`/`destroy` | as above |
| `rcAssert`, `rcAssertFailSetCustom` | `std.debug.assert` and the panic handler | |

## RecastRasterization.cpp

| original | zig-recast | test |
| --- | --- | --- |
| `rcAddSpan` | `addSpan` | "spans added directly merge, wrap and filter as the original's" |
| `rcRasterizeTriangle` | `rasterizeTriangle` | "every rasterization entry point matches on crafted triangles" |
| `rcRasterizeTriangles` (int indices, unsigned short indices, unindexed) | `rasterizeTriangles(…, i32, …)`, `rasterizeTriangles(…, u16, …)`, `rasterizeUnindexedTriangles` | as above, and every pipeline test |

## RecastFilter.cpp

| original | zig-recast | test |
| --- | --- | --- |
| `rcFilterLowHangingWalkableObstacles`, `rcFilterLedgeSpans`, `rcFilterWalkableLowHeightSpans` | same names without `rc` | pipeline tests; the direct span test |

## RecastArea.cpp

| original | zig-recast | test |
| --- | --- | --- |
| `rcErodeWalkableArea` | `erodeWalkableArea` | "erosion of every radius matches" |
| `rcMedianFilterWalkableArea` | `medianFilterWalkableArea` | "area marks match inside, across and outside the field" |
| `rcMarkBoxArea`, `rcMarkConvexPolyArea`, `rcMarkCylinderArea` | `markBoxArea`, `markConvexPolyArea`, `markCylinderArea` | as above, and the pipeline tests with marked areas |
| `rcOffsetPoly` | `offsetPoly` | "offsetPoly matches on both windings, degenerate corners and short buffers" |

## RecastRegion.cpp

| original | zig-recast | test |
| --- | --- | --- |
| `rcBuildDistanceField` | `buildDistanceField` | pipeline tests |
| `rcBuildRegions`, `rcBuildRegionsMonotone`, `rcBuildLayerRegions` | `buildRegions`, `buildRegionsMonotone`, `buildLayerRegions` | "regions build the same with borders and area limits", pipeline tests for every partition |

## RecastContour.cpp

| original | zig-recast | test |
| --- | --- | --- |
| `rcBuildContours` | `buildContours` | "contours and polygons match for every contour flag and vertex limit" |

## RecastMesh.cpp

| original | zig-recast | test |
| --- | --- | --- |
| `rcBuildPolyMesh` | `buildPolyMesh` | as above, and the pipeline tests |
| `rcMergePolyMeshes` | `mergePolyMeshes` | "tiles build the same on every thread count, as the original builds them" |
| `rcCopyPolyMesh` | `copyPolyMesh` | pipeline tests |

## RecastMeshDetail.cpp

| original | zig-recast | test |
| --- | --- | --- |
| `rcBuildPolyMeshDetail` | `buildPolyMeshDetail` | "detail meshes match for every sample distance and error", pipeline tests |
| `rcMergePolyMeshDetails` | `mergePolyMeshDetails` | the tiled test |

## RecastLayers.cpp

| original | zig-recast | test |
| --- | --- | --- |
| `rcBuildHeightfieldLayers` | `buildHeightfieldLayers` | "heightfield layers build the same with borders", pipeline tests |

## Where the port differs

- **Out of memory.** The original ignores some failed allocations and
  carries on with less work; the port fails the build. The original also
  dereferences null where its vectors fail to grow; the port fails.
- **Undefined behaviour.** Where the original reads memory it never wrote,
  the port reads zeros, and the tests run the original with a zero-filling
  allocator. Where it writes past a buffer (a row with more sweeps than
  columns in the monotone and layer partitions, more merged hole vertices
  than it allocated for), the port's buffer is large enough; the output is
  the same wherever the original's is defined.
- **Float to int.** C's `(int)` of a float out of range is undefined; the
  port gives what x86-64 gives (the most negative int), on every machine.
- **Sorting.** Contour holes and diagonals are sorted with a stable sort.
  glibc's `qsort` is stable too, so the original matches on Linux; the
  tests give the original a stable `qsort` on every platform.
- **Log addresses.** Two contour warnings print object addresses (`%p`);
  the tests compare logs with the addresses taken out.
