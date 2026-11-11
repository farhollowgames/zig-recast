# Testing

The sections up to "In this repository" are the same in every Farhollow
Games port of a C or C++ library to Zig. The last section says how this
repository applies them.

## Oracle tests

The original is pinned to one upstream commit and kept in `reference/` (or
fetched as a lazy dependency), byte for byte as upstream has it. It is built
only for the tests and the benchmark, and is never part of the package.

An oracle test runs the original and the port on the same inputs and
compares the results. Where the original is exact, the test compares every
output byte and every returned value, not a summary such as a hash or one
field of the result. The inputs are:

- the original's own test data and demo assets, where it has them;
- hand-made edge cases: empty input, one element, the largest size, and
  degenerate cases;
- seeded random inputs (see Fuzzing).

`STATUS.md` lists every public function, option and mode of the original,
and names the tests that check each one. Code coverage is not the measure:
a feature counts as checked when a test compares it, not when a line is
reached.

## What "the same output" means

- Bytes and integers are equal.
- Floats are compared by their bit patterns, so `-0.0` differs from `0.0`,
  and a NaN matches only a NaN with the same bits.
- Where the original's output depends on how it is compiled (fused
  multiply-add, fast-math, signed overflow), the reference is built with
  flags that fix one result, and the port computes that result. The last
  section names the flags.
- Where a port deliberately computes differently from the original, a
  written design gives the units, scales, overflow bounds and tolerances.
  The port is then checked against an exact port within those tolerances,
  and against itself exactly.

## Fuzzing

Each fuzz test draws its inputs from a seeded generator and runs at least
1,000 cases. The seeds are recorded in the tests, so every run checks the
same inputs. A failure prints its seed, and the configuration where there is
one, so that it can be repeated. Where a repository has the option,
`zig build test -Dfuzz-seed=N` changes every fuzz test's seed, to explore
other inputs.

## Malformed input

Decoders and parsers are given truncated, corrupted and random bytes, and
must give the original's result: the same output, the same error, or the
same rejection. Where the port asserts a condition that the original
reports as an error code, or that the original does not check, `STATUS.md`
says so. Where a repository has contract tests, a program breaks one
contract per run, and the test expects the abort and its message in the safe
build modes.

## Determinism

The same inputs give the same output on every run. Where the library splits
work over threads, the tests compare the output on 1, 2 and more threads
with the output of one.

## Build modes

`zig build test` runs the tests in ReleaseSafe unless
`-Dtest-optimize=<mode>` says otherwise. ReleaseSafe keeps every assert and
integer overflow check on and runs the slow cases in reasonable time. The
last section says which modes have been run.

## Review

After a port passes its oracle tests, a separate AI agent profiles it
against the original and tunes the hot paths; each change is kept only if
the oracle tests still pass and the benchmark shows a gain. Another AI agent
then tries to break the claims: features left untested, comparisons that
check too little, fuzzing too narrow, benchmarks that favour the port,
undefined behaviour, integer overflow, and references that can outlive what
they point to. Each confirmed finding is fixed with a test that failed
before the fix. No person has yet reviewed the code or the tests.

## In this repository

### The original

`build.zig.zon` pins recastnavigation 1.6.0, commit
`9f4ce64458dfae86e1239c525ddc219c4e9e06f1`, as a lazy dependency. It is
fetched only when zig-recast is the root package, so a package that depends
on zig-recast never fetches it. `zig build test` builds Recast from it with
the clang that Zig carries, at `-O3 -std=c++11 -fno-exceptions -fno-rtti
-fno-threadsafe-statics -ffp-contract=off -fno-fast-math
-fno-sanitize=undefined`. With fused multiply-adds off, float steps round as
written, as Zig's do.

Two files in `test/shim/` are built with it, as test-only code:

- `recast_shim.cpp` gives the original a C interface. It runs each step,
  writes each structure out in a fixed byte format (every field in order,
  ints and floats as 4 native bytes, byte and short arrays as they are),
  and records every log message and timer call as text, as `Recorder` in
  `test/oracle.zig` does for the port. It also gives the original an
  allocator that zero-fills: Recast reads a few buffers it never wrote, and
  zeroed memory makes those reads the same on every run, as the port's
  zeroed buffers are.
- `stable_qsort.c` is a stable `qsort` for the original. Recast sorts
  contour holes and diagonals with `qsort`, and equal keys are common.
  glibc's `qsort` is stable, others are not; the port sorts stably.

On glibc, the original is built as a shared library without compiler_rt,
so that its `cosf` is glibc's, as in an original built on Linux; linked
into a binary that Zig links, it would bind to compiler_rt's, which rounds
differently. Elsewhere it is linked statically, and the two tests that
compare with glibc's `cosf` are skipped.

### What the tests compare

- **Structures**: the port's dump (`test/dump.zig`) and the original's must
  be equal byte for byte, so floats are compared by their bits. The
  pipeline tests compare the structure of every step. The tile tests
  compare each tile's polygon mesh and detail mesh, and their merges, but
  not the steps between.
- **Logs and timers**: every message and every timer call, in order, as
  text. Two contour warnings print object addresses (`%p`), which are taken
  out before the logs are compared.
- **Outcomes**: where the original logs an error and returns false, the
  port must return an error after the same log.
- **Floats returned by the helpers** (vectors, scalars, polygon offsets):
  compared by their bits, except that any two NaNs match, since neither C++
  nor Zig defines which NaN an operation on several NaNs gives. The test of
  the cosine against glibc's does the same. This is looser than the rule
  above, and only these results use it: NaNs in structures and in bounds
  are compared by their bits.

### Tests and counts

`zig build test` runs 81 tests: 25 unit tests in `src/`, on the port alone,
and 56 tests in `test/` that run the original beside the port. The test
runner counts 83, with the two blocks that pull the test files in.

| file | tests | what they run |
| --- | ---: | --- |
| `test/differential.zig` | 20 | the meshes through every step under many settings; named cases for each step; the context and the constants; the cosine against glibc's; Loomwork's tiles; the thread test |
| `test/fuzz.zig` | 11 | the ten fuzz tests (named "fuzz: …") and every direction of the direction helpers |
| `test/edges.zig` | 12 | hand-made edge cases, each through the whole build |
| `test/upstream_tests.zig` | 13 | upstream's own `Tests/Recast` cases, section by section, on both sides; the port must also give what each upstream test requires |
| `src/*.zig` | 25 | the port alone: helpers, the two refusals, the cosine, and every allocation of a build failed in turn |

[`STATUS.md`](../STATUS.md) names the tests of every function, and
[`parity.md`](parity.md) maps each function of the original to the port's.

### Inputs

- RecastDemo's `dungeon.obj`, `nav_test.obj` and `undulating.obj`, from the
  pinned commit, and two meshes generated by `test/meshes.zig`: a terrain
  with cliffs, holes, pillars, stairs, stacked floors and a bridge, and a
  rolling ground (`vale`) as Loomwork's terrain makes it.
- RecastDemo's settings and many others: every partition (watershed,
  monotone and layers), each combination of the two contour flags, vertex
  limits from 3 to 12, detail sample distances and errors, borders, area
  limits, and area marks inside, across and outside the field.
- Loomwork's tiled build, on tiles of other cell sizes and off the cell
  grid too, merged as RecastDemo merges a tiled build.
- Hand-made edge cases (`test/edges.zig`): an empty scene, one triangle,
  one span, borders as wide as the field, tiles off the cell grid, the
  limit of every counter (region ids, mesh vertices, layer regions, layers,
  span heights, spans in a column) and degenerate triangles. Each test
  checks that its case reaches the limit it is about.

### Fuzzing

| fuzz test | cases |
| --- | ---: |
| random scenes through every step, tile by tile and merged | 1,200 |
| spans added directly, filtered and compacted | 1,000 |
| triangles through every rasterization entry point | 1,000 |
| triangles out to the vertex range, and past it | 1,000 |
| polygon offsets, including into short buffers | 2,000 |
| slopes marked and cleared | 1,000 |
| bounds and grid sizes, with odd floats | 2,000 |
| the vector helpers | 2,000 |
| min, max, clamp, square root and float to int | 4,000 |
| span connections | 4,000 |

Case `i` of a fuzz test takes its seed from SplitMix64 of
`(salt ^ N) + i`, where `salt` is recorded in the test and `N` is set by
`-Dfuzz-seed=N` (0 by default, which gives the recorded cases). A failing
case prints its seed, and `-Dfuzz-replay=<seed>` runs only that case in
each fuzz test. The random floats include NaN, infinities, denormals, huge
and tiny values and signed zeros. Heights take any float; x and z stay
inside the vertex range for the original (see below). One scene in eight,
by seed, is built twice by the port, which must give the same bytes both
times.

### Malformed input

Recast reads no files or bytes, so there is no decoder to feed corrupted
bytes. Its inputs are numbers and arrays, and the tests give it odd ones:
the floats above, degenerate and zero-area triangles, output buffers too
short, and every counter at its limit. Both sides must give the same bytes.

Where the original writes past its buffers on input a caller can pass, the
port refuses it with an error of its own, the same in every build mode, and
the tests never give the original that input:

- `error.NonFiniteVertex`, for a triangle with an x or z that is not finite
  or is 2^22 cells or more from the origin. The tests compare the two sides
  out to the edge of that range, and check the refusal on every
  rasterization entry point.
- `error.TooManyPolygonVertices`, from `buildPolyMeshDetail`, for a polygon
  of more than 127 vertices. The tests compare polygons of 125, 126 and 127
  vertices, and check the refusal and its log at 128 and 200.

Inputs that a caller cannot validly pass, which `STATUS.md` lists, are not
compared with the original: the port refuses some and stops on the others
in Debug and ReleaseSafe. There are no contract tests for them.

### Determinism

"tiles build the same on every thread count, as the original builds them"
builds a tiled terrain on pools of 1, 2, 4 and 8 threads, a task per tile,
and compares every tile's polygon mesh and detail mesh with the original's.
Recast has no threads of its own. The scene fuzzing builds one scene in
eight twice, as above.

### Failed allocations

"a failed allocation fails each step of a build and leaks nothing" runs a
whole build on the port alone, merges and copy included, under
`std.testing.checkAllAllocationFailures`: each of the build's 142
allocations fails in turn, and each time the build must return
`error.OutOfMemory` and free everything it made. Every test runs on
`std.testing.allocator`, which fails on leaks and double frees.

### The slope's cosine

The port carries its own copy of glibc's `cosf`; [`parity.md`](parity.md)
says why. On glibc, one test compares it with the system's on each of the
113,840,092 floats from 2^-12 to pi and on every 4,099th of all 2^32
floats, and another builds a triangle whose normal lies between glibc's
threshold and the correctly rounded one at 49 degrees, and checks that the
port marks it as the original does. Unit tests check landmarks, a sweep
against the rounded double cosine, and the 25 tenths of a degree where
glibc's cosine is a float step from the rounded one. A separate run, not
part of the tests, compared all 2^32 floats with glibc 2.44 on x86-64 and
found no difference.

### Build modes

The tests run in ReleaseSafe by default, as CI does (`ubuntu-latest`,
x86-64, Zig 0.17.0); `-Dtest-optimize` selects another mode. The original
is always built at `-O3`. On 11 November 2026, every test passed in
ReleaseSafe, Debug and ReleaseFast, on x86-64 Linux with glibc 2.44.

### State

`STATUS.md` marks each feature oracle-tested or benchmarked. None is marked
reviewed yet: the review above has been done, and the rows become reviewed
once the author has read its findings.
