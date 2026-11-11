// A stable qsort for the upstream build in the tests. Recast sorts contour
// holes and diagonals with qsort, and equal keys are common; glibc's qsort is
// a stable merge sort, others are not. This one makes the oracle's order the
// same on every platform, and the port sorts stably to match.
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

void qsort(void* base, size_t n, size_t size, int (*cmp)(const void*, const void*)) {
    if (n < 2) return;
    unsigned char* items = (unsigned char*)base;
    unsigned char* tmp = (unsigned char*)malloc(size);
    for (size_t i = 1; i < n; ++i) {
        size_t j = i;
        while (j > 0 && cmp(items + (j - 1) * size, items + i * size) > 0) j--;
        if (j == i) continue;
        memcpy(tmp, items + i * size, size);
        memmove(items + (j + 1) * size, items + j * size, (i - j) * size);
        memcpy(items + j * size, tmp, size);
    }
    free(tmp);
}
