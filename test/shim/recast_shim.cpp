// The C interface the differential tests call upstream Recast through, and
// the dumps they compare with the port's. Test-only code: the library itself
// is pure Zig.
#include <stdlib.h>
#include <math.h>
#include <string.h>

#include "Recast.h"
#include "RecastAlloc.h"

// No C++ runtime is linked: these give the context's virtual destructor and
// any stray allocation malloc and free.
void* operator new(size_t size) { return malloc(size ? size : 1); }
void* operator new[](size_t size) { return malloc(size ? size : 1); }
void operator delete(void* p) noexcept { free(p); }
void operator delete[](void* p) noexcept { free(p); }
void operator delete(void* p, size_t) noexcept { free(p); }
void operator delete[](void* p, size_t) noexcept { free(p); }

namespace {

// Recast reads a few buffers it never wrote; zero-filled memory makes those
// reads the same on every run, as the port's zeroed buffers are.
void* zeroAlloc(size_t size, rcAllocHint) { return calloc(size ? size : 1, 1); }
void zeroFree(void* ptr) { free(ptr); }

struct Text {
    char* bytes = 0;
    size_t len = 0;
    size_t cap = 0;

    void append(const char* s, size_t n) {
        if (len + n > cap) {
            size_t next = cap ? cap * 2 : 4096;
            while (next < len + n) next *= 2;
            bytes = (char*)realloc(bytes, next);
            cap = next;
        }
        memcpy(bytes + len, s, n);
        len += n;
    }

    void appendInt(int value) {
        char digits[16];
        int n = 0;
        unsigned int v = value < 0 ? 0u - (unsigned int)value : (unsigned int)value;
        do {
            digits[n++] = (char)('0' + v % 10);
            v /= 10;
        } while (v);
        if (value < 0) append("-", 1);
        while (n) append(&digits[--n], 1);
    }
};

// Records every log message and timer call as a line of text, in the same
// format as the tests' sink for the port.
class RecordingContext : public rcContext {
public:
    Text text;

protected:
    void doResetLog() override { text.append("R\n", 2); }
    void doLog(const rcLogCategory category, const char* msg, const int len) override {
        text.append("L", 1);
        text.appendInt((int)category);
        text.append(" ", 1);
        text.append(msg, (size_t)len);
        text.append("\n", 1);
    }
    void doResetTimers() override { text.append("T\n", 2); }
    void doStartTimer(const rcTimerLabel label) override {
        text.append("S", 1);
        text.appendInt((int)label);
        text.append("\n", 1);
    }
    void doStopTimer(const rcTimerLabel label) override {
        text.append("E", 1);
        text.appendInt((int)label);
        text.append("\n", 1);
    }
    int doGetAccumulatedTime(const rcTimerLabel) const override { return -1; }
};

typedef void (*Write)(void* user, const void* bytes, size_t len);

struct Dump {
    Write write;
    void* user;

    void i32(int v) { write(user, &v, 4); }
    void f32(float v) { write(user, &v, 4); }
    void f32s(const float* v, int n) { write(user, v, (size_t)n * 4); }
    void bytes(const void* v, size_t n) { write(user, v, n); }
};

} // namespace

extern "C" {

void shim_init(void) { rcAllocSetCustom(zeroAlloc, zeroFree); }

void* shim_log_create(void) {
    void* mem = malloc(sizeof(RecordingContext));
    return new (rcNewTag(), mem) RecordingContext();
}

void shim_log_destroy(void* ctx) {
    RecordingContext* rec = (RecordingContext*)ctx;
    free(rec->text.bytes);
    rec->~RecordingContext();
    free(rec);
}

void shim_log_enable(void* ctx, int log, int timer) {
    ((rcContext*)ctx)->enableLog(log != 0);
    ((rcContext*)ctx)->enableTimer(timer != 0);
}

const char* shim_log_text(void* ctx, size_t* len) {
    RecordingContext* rec = (RecordingContext*)ctx;
    *len = rec->text.len;
    return rec->text.bytes ? rec->text.bytes : "";
}

void shim_log_clear(void* ctx) { ((RecordingContext*)ctx)->text.len = 0; }

void shim_log_message(void* ctx, int category, const char* text) {
    ((rcContext*)ctx)->log((rcLogCategory)category, "%s", text);
}

void shim_log_reset(void* ctx) {
    ((rcContext*)ctx)->resetLog();
    ((rcContext*)ctx)->resetTimers();
}

float shim_cosf(float x) { return cosf(x); }

void shim_calc_bounds(const float* verts, int nv, float* bmin, float* bmax) {
    rcCalcBounds(verts, nv, bmin, bmax);
}

void shim_calc_grid_size(const float* bmin, const float* bmax, float cs, int* w, int* h) {
    rcCalcGridSize(bmin, bmax, cs, w, h);
}

void shim_mark_walkable(void* ctx, float slope, const float* verts, int nv, const int* tris,
                        int nt, unsigned char* areas) {
    rcMarkWalkableTriangles((rcContext*)ctx, slope, verts, nv, tris, nt, areas);
}

void shim_clear_unwalkable(void* ctx, float slope, const float* verts, int nv, const int* tris,
                           int nt, unsigned char* areas) {
    rcClearUnwalkableTriangles((rcContext*)ctx, slope, verts, nv, tris, nt, areas);
}

void* shim_hf_create(void* ctx, int w, int h, const float* bmin, const float* bmax, float cs,
                     float ch) {
    rcHeightfield* hf = rcAllocHeightfield();
    if (!hf) return 0;
    if (!rcCreateHeightfield((rcContext*)ctx, *hf, w, h, bmin, bmax, cs, ch)) {
        rcFreeHeightField(hf);
        return 0;
    }
    return hf;
}

void shim_hf_free(void* hf) { rcFreeHeightField((rcHeightfield*)hf); }

int shim_add_span(void* ctx, void* hf, int x, int z, unsigned short smin, unsigned short smax,
                  unsigned char area, int merge) {
    return rcAddSpan((rcContext*)ctx, *(rcHeightfield*)hf, x, z, smin, smax, area, merge);
}

int shim_rasterize_triangle(void* ctx, const float* v0, const float* v1, const float* v2,
                            unsigned char area, void* hf, int merge) {
    return rcRasterizeTriangle((rcContext*)ctx, v0, v1, v2, area, *(rcHeightfield*)hf, merge);
}

int shim_rasterize_triangles(void* ctx, const float* verts, int nv, const int* tris,
                             const unsigned char* areas, int nt, void* hf, int merge) {
    return rcRasterizeTriangles((rcContext*)ctx, verts, nv, tris, areas, nt,
                                *(rcHeightfield*)hf, merge);
}

int shim_rasterize_triangles_u16(void* ctx, const float* verts, int nv,
                                 const unsigned short* tris, const unsigned char* areas, int nt,
                                 void* hf, int merge) {
    return rcRasterizeTriangles((rcContext*)ctx, verts, nv, tris, areas, nt,
                                *(rcHeightfield*)hf, merge);
}

int shim_rasterize_unindexed(void* ctx, const float* verts, const unsigned char* areas, int nt,
                             void* hf, int merge) {
    return rcRasterizeTriangles((rcContext*)ctx, verts, areas, nt, *(rcHeightfield*)hf, merge);
}

void shim_filter_low_hanging(void* ctx, int climb, void* hf) {
    rcFilterLowHangingWalkableObstacles((rcContext*)ctx, climb, *(rcHeightfield*)hf);
}

void shim_filter_ledge(void* ctx, int height, int climb, void* hf) {
    rcFilterLedgeSpans((rcContext*)ctx, height, climb, *(rcHeightfield*)hf);
}

void shim_filter_low_height(void* ctx, int height, void* hf) {
    rcFilterWalkableLowHeightSpans((rcContext*)ctx, height, *(rcHeightfield*)hf);
}

int shim_hf_span_count(void* ctx, void* hf) {
    return rcGetHeightFieldSpanCount((rcContext*)ctx, *(rcHeightfield*)hf);
}

void* shim_chf_build(void* ctx, int walkable_height, int walkable_climb, void* hf) {
    rcCompactHeightfield* chf = rcAllocCompactHeightfield();
    if (!chf) return 0;
    if (!rcBuildCompactHeightfield((rcContext*)ctx, walkable_height, walkable_climb,
                                   *(rcHeightfield*)hf, *chf)) {
        rcFreeCompactHeightfield(chf);
        return 0;
    }
    return chf;
}

void shim_chf_free(void* chf) { rcFreeCompactHeightfield((rcCompactHeightfield*)chf); }

int shim_erode(void* ctx, int radius, void* chf) {
    return rcErodeWalkableArea((rcContext*)ctx, radius, *(rcCompactHeightfield*)chf);
}

int shim_median(void* ctx, void* chf) {
    return rcMedianFilterWalkableArea((rcContext*)ctx, *(rcCompactHeightfield*)chf);
}

void shim_mark_box(void* ctx, const float* bmin, const float* bmax, unsigned char area,
                   void* chf) {
    rcMarkBoxArea((rcContext*)ctx, bmin, bmax, area, *(rcCompactHeightfield*)chf);
}

void shim_mark_convex(void* ctx, const float* verts, int nv, float miny, float maxy,
                      unsigned char area, void* chf) {
    rcMarkConvexPolyArea((rcContext*)ctx, verts, nv, miny, maxy, area,
                         *(rcCompactHeightfield*)chf);
}

int shim_offset_poly(const float* verts, int nv, float offset, float* out, int max_out) {
    return rcOffsetPoly(verts, nv, offset, out, max_out);
}

void shim_mark_cylinder(void* ctx, const float* pos, float radius, float height,
                        unsigned char area, void* chf) {
    rcMarkCylinderArea((rcContext*)ctx, pos, radius, height, area, *(rcCompactHeightfield*)chf);
}

int shim_distance_field(void* ctx, void* chf) {
    return rcBuildDistanceField((rcContext*)ctx, *(rcCompactHeightfield*)chf);
}

int shim_regions(void* ctx, void* chf, int border, int min_area, int merge_area) {
    return rcBuildRegions((rcContext*)ctx, *(rcCompactHeightfield*)chf, border, min_area,
                          merge_area);
}

int shim_regions_monotone(void* ctx, void* chf, int border, int min_area, int merge_area) {
    return rcBuildRegionsMonotone((rcContext*)ctx, *(rcCompactHeightfield*)chf, border, min_area,
                                  merge_area);
}

int shim_layer_regions(void* ctx, void* chf, int border, int min_area) {
    return rcBuildLayerRegions((rcContext*)ctx, *(rcCompactHeightfield*)chf, border, min_area);
}

void* shim_layers_build(void* ctx, void* chf, int border, int walkable_height) {
    rcHeightfieldLayerSet* lset = rcAllocHeightfieldLayerSet();
    if (!lset) return 0;
    if (!rcBuildHeightfieldLayers((rcContext*)ctx, *(rcCompactHeightfield*)chf, border,
                                  walkable_height, *lset)) {
        rcFreeHeightfieldLayerSet(lset);
        return 0;
    }
    return lset;
}

void shim_layers_free(void* lset) { rcFreeHeightfieldLayerSet((rcHeightfieldLayerSet*)lset); }

void* shim_contours_build(void* ctx, void* chf, float max_error, int max_edge_len, int flags) {
    rcContourSet* cset = rcAllocContourSet();
    if (!cset) return 0;
    if (!rcBuildContours((rcContext*)ctx, *(rcCompactHeightfield*)chf, max_error, max_edge_len,
                         *cset, flags)) {
        rcFreeContourSet(cset);
        return 0;
    }
    return cset;
}

void shim_contours_free(void* cset) { rcFreeContourSet((rcContourSet*)cset); }

void* shim_polymesh_build(void* ctx, void* cset, int nvp) {
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    if (!pmesh) return 0;
    if (!rcBuildPolyMesh((rcContext*)ctx, *(rcContourSet*)cset, nvp, *pmesh)) {
        rcFreePolyMesh(pmesh);
        return 0;
    }
    return pmesh;
}

void* shim_polymesh_merge(void* ctx, void** meshes, int n) {
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    if (!pmesh) return 0;
    if (!rcMergePolyMeshes((rcContext*)ctx, (rcPolyMesh**)meshes, n, *pmesh)) {
        rcFreePolyMesh(pmesh);
        return 0;
    }
    return pmesh;
}

void* shim_polymesh_copy(void* ctx, void* src) {
    rcPolyMesh* pmesh = rcAllocPolyMesh();
    if (!pmesh) return 0;
    if (!rcCopyPolyMesh((rcContext*)ctx, *(rcPolyMesh*)src, *pmesh)) {
        rcFreePolyMesh(pmesh);
        return 0;
    }
    return pmesh;
}

void shim_polymesh_free(void* pmesh) { rcFreePolyMesh((rcPolyMesh*)pmesh); }

void* shim_detail_build(void* ctx, void* pmesh, void* chf, float sample_dist,
                        float sample_max_error) {
    rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
    if (!dmesh) return 0;
    if (!rcBuildPolyMeshDetail((rcContext*)ctx, *(rcPolyMesh*)pmesh, *(rcCompactHeightfield*)chf,
                               sample_dist, sample_max_error, *dmesh)) {
        rcFreePolyMeshDetail(dmesh);
        return 0;
    }
    return dmesh;
}

void* shim_detail_merge(void* ctx, void** meshes, int n) {
    rcPolyMeshDetail* dmesh = rcAllocPolyMeshDetail();
    if (!dmesh) return 0;
    if (!rcMergePolyMeshDetails((rcContext*)ctx, (rcPolyMeshDetail**)meshes, n, *dmesh)) {
        rcFreePolyMeshDetail(dmesh);
        return 0;
    }
    return dmesh;
}

void shim_detail_free(void* dmesh) { rcFreePolyMeshDetail((rcPolyMeshDetail*)dmesh); }

// The dumps. Each writes a structure's every field in a fixed order, ints and
// floats as 4 native bytes, byte and short arrays as they are; the tests
// write the port's structures the same way and compare the bytes.

void shim_dump_hf(void* hf_ptr, Write write, void* user) {
    const rcHeightfield& hf = *(rcHeightfield*)hf_ptr;
    Dump d = {write, user};
    d.i32(hf.width);
    d.i32(hf.height);
    d.f32s(hf.bmin, 3);
    d.f32s(hf.bmax, 3);
    d.f32(hf.cs);
    d.f32(hf.ch);
    for (int i = 0; i < hf.width * hf.height; ++i) {
        int n = 0;
        for (const rcSpan* s = hf.spans[i]; s; s = s->next) n++;
        d.i32(n);
        for (const rcSpan* s = hf.spans[i]; s; s = s->next) {
            d.i32((int)s->smin);
            d.i32((int)s->smax);
            d.i32((int)s->area);
        }
    }
}

void shim_dump_chf(void* chf_ptr, Write write, void* user) {
    const rcCompactHeightfield& chf = *(rcCompactHeightfield*)chf_ptr;
    Dump d = {write, user};
    d.i32(chf.width);
    d.i32(chf.height);
    d.i32(chf.spanCount);
    d.i32(chf.walkableHeight);
    d.i32(chf.walkableClimb);
    d.i32(chf.borderSize);
    d.i32(chf.maxDistance);
    d.i32(chf.maxRegions);
    d.f32s(chf.bmin, 3);
    d.f32s(chf.bmax, 3);
    d.f32(chf.cs);
    d.f32(chf.ch);
    for (int i = 0; i < chf.width * chf.height; ++i) {
        d.i32((int)chf.cells[i].index);
        d.i32((int)chf.cells[i].count);
    }
    for (int i = 0; i < chf.spanCount; ++i) {
        const rcCompactSpan& s = chf.spans[i];
        d.i32(s.y);
        d.i32(s.reg);
        d.i32((int)s.con);
        d.i32((int)s.h);
    }
    // An empty field's distances are empty whether built or not.
    const bool has_dist = chf.dist && chf.spanCount > 0;
    d.i32(has_dist ? 1 : 0);
    if (has_dist) d.bytes(chf.dist, (size_t)chf.spanCount * 2);
    d.bytes(chf.areas, (size_t)chf.spanCount);
}

void shim_dump_layers(void* lset_ptr, Write write, void* user) {
    const rcHeightfieldLayerSet& lset = *(rcHeightfieldLayerSet*)lset_ptr;
    Dump d = {write, user};
    d.i32(lset.nlayers);
    for (int i = 0; i < lset.nlayers; ++i) {
        const rcHeightfieldLayer& layer = lset.layers[i];
        d.f32s(layer.bmin, 3);
        d.f32s(layer.bmax, 3);
        d.f32(layer.cs);
        d.f32(layer.ch);
        d.i32(layer.width);
        d.i32(layer.height);
        d.i32(layer.minx);
        d.i32(layer.maxx);
        d.i32(layer.miny);
        d.i32(layer.maxy);
        d.i32(layer.hmin);
        d.i32(layer.hmax);
        const size_t cells = (size_t)layer.width * (size_t)layer.height;
        d.bytes(layer.heights, cells);
        d.bytes(layer.areas, cells);
        d.bytes(layer.cons, cells);
    }
}

void shim_dump_contours(void* cset_ptr, Write write, void* user) {
    const rcContourSet& cset = *(rcContourSet*)cset_ptr;
    Dump d = {write, user};
    d.i32(cset.nconts);
    d.f32s(cset.bmin, 3);
    d.f32s(cset.bmax, 3);
    d.f32(cset.cs);
    d.f32(cset.ch);
    d.i32(cset.width);
    d.i32(cset.height);
    d.i32(cset.borderSize);
    d.f32(cset.maxError);
    for (int i = 0; i < cset.nconts; ++i) {
        const rcContour& c = cset.conts[i];
        d.i32(c.nverts);
        d.bytes(c.verts, (size_t)c.nverts * 16);
        d.i32(c.nrverts);
        d.bytes(c.rverts, (size_t)c.nrverts * 16);
        d.i32(c.reg);
        d.i32(c.area);
    }
}

void shim_dump_polymesh(void* pmesh_ptr, Write write, void* user) {
    const rcPolyMesh& m = *(rcPolyMesh*)pmesh_ptr;
    Dump d = {write, user};
    d.i32(m.nverts);
    d.i32(m.npolys);
    d.i32(m.maxpolys);
    d.i32(m.nvp);
    d.f32s(m.bmin, 3);
    d.f32s(m.bmax, 3);
    d.f32(m.cs);
    d.f32(m.ch);
    d.i32(m.borderSize);
    d.f32(m.maxEdgeError);
    d.bytes(m.verts, (size_t)m.nverts * 6);
    const int polys = m.maxpolys > m.npolys ? m.maxpolys : m.npolys;
    d.bytes(m.polys, (size_t)polys * (size_t)m.nvp * 4);
    d.bytes(m.regs, (size_t)polys * 2);
    // Flags are allocated for the polygons in use only.
    d.bytes(m.flags, (size_t)m.npolys * 2);
    d.bytes(m.areas, (size_t)polys);
}

void shim_dump_detail(void* dmesh_ptr, Write write, void* user) {
    const rcPolyMeshDetail& m = *(rcPolyMeshDetail*)dmesh_ptr;
    Dump d = {write, user};
    d.i32(m.nmeshes);
    d.i32(m.nverts);
    d.i32(m.ntris);
    d.bytes(m.meshes, (size_t)m.nmeshes * 16);
    d.bytes(m.verts, (size_t)m.nverts * 12);
    d.bytes(m.tris, (size_t)m.ntris * 4);
}

} // extern "C"
