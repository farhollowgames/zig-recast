# Status

Every feature of Recast in recastnavigation 1.6.0 and its state:
**not started**, **ported** (translated), **oracle-tested** (the
differential tests in `test/differential.zig` show the same bytes as the
original), **benchmarked** (timed by `zig build bench`).

| upstream file | features | Zig file | state |
| --- | --- | --- | --- |
| Recast.h | constants, `rcConfig`, `rcSpan`/`rcSpanPool`/`rcHeightfield`, `rcCompactCell`/`rcCompactSpan`/`rcCompactHeightfield`, `rcHeightfieldLayer(Set)`, `rcContour(Set)`, `rcPolyMesh`, `rcPolyMeshDetail`, `rcSetCon`/`rcGetCon`/`rcGetDirOffsetX`/`Y`/`rcGetDirForOffset`, vector helpers | `src/recast.zig` | oracle-tested |
| Recast.h, Recast.cpp | `rcContext` (log, timers, enable flags), `rcScopedTimer` | `src/context.zig` | oracle-tested |
| Recast.cpp | `rcCalcBounds`, `rcCalcGridSize`, `rcCreateHeightfield`, `rcMarkWalkableTriangles`, `rcClearUnwalkableTriangles`, `rcGetHeightFieldSpanCount`, `rcBuildCompactHeightfield`, alloc/free of every structure | `src/recast.zig` | benchmarked: marking walkable triangles, the compact heightfield; the rest oracle-tested |
| RecastAlloc.h/.cpp | `rcAllocSetCustom`, `rcAlloc`, `rcFree`, `rcTempVector`, `rcPermVector` | every function takes a `std.mem.Allocator`; vectors are `std.ArrayList` | oracle-tested |
| RecastAssert.h/.cpp | `rcAssert`, `rcAssertFailSetCustom` | `std.debug.assert` and the panic handler | oracle-tested |
| RecastRasterization.cpp | `rcAddSpan`, `rcRasterizeTriangle`, `rcRasterizeTriangles` (int, unsigned short and unindexed) | `src/rasterization.zig` | benchmarked: `int` indices; the rest oracle-tested |
| RecastFilter.cpp | `rcFilterLowHangingWalkableObstacles`, `rcFilterLedgeSpans`, `rcFilterWalkableLowHeightSpans` | `src/filter.zig` | benchmarked |
| RecastArea.cpp | `rcErodeWalkableArea`, `rcMedianFilterWalkableArea`, `rcMarkBoxArea`, `rcMarkConvexPolyArea`, `rcOffsetPoly`, `rcMarkCylinderArea` | `src/area.zig` | benchmarked: erosion; the rest oracle-tested |
| RecastRegion.cpp | `rcBuildDistanceField`, `rcBuildRegions` (watershed), `rcBuildRegionsMonotone`, `rcBuildLayerRegions` | `src/region.zig` | benchmarked: distance field, watershed; monotone and layer partitions oracle-tested |
| RecastContour.cpp | `rcBuildContours` (tessellation flags, hole merging) | `src/contour.zig` | benchmarked |
| RecastMesh.cpp | `rcBuildPolyMesh`, `rcMergePolyMeshes`, `rcCopyPolyMesh` | `src/mesh.zig` | benchmarked: `rcBuildPolyMesh`; merge and copy oracle-tested |
| RecastMeshDetail.cpp | `rcBuildPolyMeshDetail`, `rcMergePolyMeshDetails` | `src/mesh_detail.zig` | benchmarked: `rcBuildPolyMeshDetail`; merge oracle-tested |
| RecastLayers.cpp | `rcBuildHeightfieldLayers` | `src/layers.zig` | oracle-tested |

Every row passes its differential tests (`zig build test`): 16 tests over
RecastDemo's three meshes and a generated terrain, comparing every
structure, log message and timer call after every step.

One upstream behaviour cannot be compared: `rcBuildPolyMeshDetail` with a
sample distance of 0 or less never finishes in the original (its hull stays
empty and `triangulateHull` loops forever). The port triangulates the
polygon's own vertices there, which is what the original's edge pass gives
when it adds no samples.

## Performance

`zig build bench -- 3` times both sides built ReleaseFast, best of three
runs, one thread, in milliseconds (original → port):

| build | total | detail mesh | regions |
| --- | --- | --- | --- |
| dungeon, solo | 13.3 → 12.3 | | |
| nav_test, solo | 18.6 → 13.9 | | |
| undulating, solo | 80.7 → 74.1 | 57.4 → 56.4 | |
| terrain 256 m, solo | 229.5 → 191.6 | 49.6 → 42.0 | 67.3 → 38.4 |
| terrain in 12 m tiles, Loomwork's settings | 239.5 → 203.0 | 31.1 → 24.6 | 42.1 → 27.5 |

The port is slower in three steps: the distance field (1.2 to 1.3 times),
the polygon mesh (1.1 to 1.25 times) and erosion (up to 1.2 times).

## Next

1. Speed up the detail mesh's sampling and the watershed regions without
   changing a byte, and the three slower steps.
