# Status

Every feature of Recast in recastnavigation 1.6.0 and its state:
**not started**, **ported** (translated), **oracle-tested** (the
differential tests in `test/differential.zig` show the same bytes as the
original), **benchmarked** (timed by `zig build bench`).

| upstream file | features | Zig file | state |
| --- | --- | --- | --- |
| Recast.h | constants, `rcConfig`, `rcSpan`/`rcSpanPool`/`rcHeightfield`, `rcCompactCell`/`rcCompactSpan`/`rcCompactHeightfield`, `rcHeightfieldLayer(Set)`, `rcContour(Set)`, `rcPolyMesh`, `rcPolyMeshDetail`, `rcSetCon`/`rcGetCon`/`rcGetDirOffsetX`/`Y`/`rcGetDirForOffset`, vector helpers | `src/recast.zig` | oracle-tested |
| Recast.h, Recast.cpp | `rcContext` (log, timers, enable flags), `rcScopedTimer` | `src/context.zig` | oracle-tested |
| Recast.cpp | `rcCalcBounds`, `rcCalcGridSize`, `rcCreateHeightfield`, `rcMarkWalkableTriangles`, `rcClearUnwalkableTriangles`, `rcGetHeightFieldSpanCount`, `rcBuildCompactHeightfield`, alloc/free of every structure | `src/recast.zig` | oracle-tested |
| RecastAlloc.h/.cpp | `rcAllocSetCustom`, `rcAlloc`, `rcFree`, `rcTempVector`, `rcPermVector` | every function takes a `std.mem.Allocator`; vectors are `std.ArrayList` | oracle-tested |
| RecastAssert.h/.cpp | `rcAssert`, `rcAssertFailSetCustom` | `std.debug.assert` and the panic handler | oracle-tested |
| RecastRasterization.cpp | `rcAddSpan`, `rcRasterizeTriangle`, `rcRasterizeTriangles` (int, unsigned short and unindexed) | `src/rasterization.zig` | oracle-tested |
| RecastFilter.cpp | `rcFilterLowHangingWalkableObstacles`, `rcFilterLedgeSpans`, `rcFilterWalkableLowHeightSpans` | `src/filter.zig` | oracle-tested |
| RecastArea.cpp | `rcErodeWalkableArea`, `rcMedianFilterWalkableArea`, `rcMarkBoxArea`, `rcMarkConvexPolyArea`, `rcOffsetPoly`, `rcMarkCylinderArea` | `src/area.zig` | oracle-tested |
| RecastRegion.cpp | `rcBuildDistanceField`, `rcBuildRegions` (watershed), `rcBuildRegionsMonotone`, `rcBuildLayerRegions` | `src/region.zig` | oracle-tested |
| RecastContour.cpp | `rcBuildContours` (tessellation flags, hole merging) | `src/contour.zig` | oracle-tested |
| RecastMesh.cpp | `rcBuildPolyMesh`, `rcMergePolyMeshes`, `rcCopyPolyMesh` | `src/mesh.zig` | oracle-tested |
| RecastMeshDetail.cpp | `rcBuildPolyMeshDetail`, `rcMergePolyMeshDetails` | `src/mesh_detail.zig` | oracle-tested |
| RecastLayers.cpp | `rcBuildHeightfieldLayers` | `src/layers.zig` | oracle-tested |

Every row passes its differential tests (`zig build test`): 16 tests over
RecastDemo's three meshes and a generated terrain, comparing every
structure, log message and timer call after every step.

One upstream behaviour cannot be compared: `rcBuildPolyMeshDetail` with a
sample distance of 0 or less never finishes in the original (its hull stays
empty and `triangulateHull` loops forever). The port triangulates the
polygon's own vertices there, which is what the original's edge pass gives
when it adds no samples.

## Next

1. Run `zig build bench`; speed up the detail mesh's sampling and the
   watershed regions without changing a byte.
