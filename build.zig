const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("recast", .{
        .root_source_file = b.path("src/recast.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests default to ReleaseSafe: the whole meshes take long in Debug, and
    // ReleaseSafe keeps every assert and overflow check on.
    const test_optimize = b.option(
        std.lang.Optimize,
        "test-optimize",
        "Optimize mode for the tests (default ReleaseSafe)",
    ) orelse .safe;
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &.{};

    const recast_test_mod = b.createModule(.{
        .root_source_file = b.path("src/recast.zig"),
        .target = target,
        .optimize = test_optimize,
    });

    const test_step = b.step("test", "Run unit and differential tests");
    const unit_tests = b.addTest(.{ .root_module = recast_test_mod, .filters = test_filters });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const bench_step = b.step("bench", "Time the port against the original (ReleaseFast)");

    // The original is fetched only for the differential tests and the
    // benchmark, and never for a package that depends on this one.
    if (!b.isRoot()) return;
    const upstream = b.lazyDependency("recastnavigation", .{}) orelse return;

    const differential = b.addTest(.{
        .name = "differential",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/differential.zig"),
            .target = target,
            .optimize = test_optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "recast", .module = recast_test_mod }},
        }),
        .filters = test_filters,
    });
    differential.root_module.linkLibrary(upstreamLibrary(b, upstream, target, true));
    addMeshes(b, upstream, differential.root_module);
    test_step.dependOn(&b.addRunArtifact(differential).step);

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .fast,
            .link_libc = true,
            .imports = &.{.{ .name = "recast", .module = b.createModule(.{
                .root_source_file = b.path("src/recast.zig"),
                .target = target,
                .optimize = .fast,
            }) }},
        }),
    });
    bench.root_module.linkLibrary(upstreamLibrary(b, upstream, target, false));
    for ([_][2][]const u8{
        .{ "meshes", "test/meshes.zig" },
        .{ "upstream", "test/upstream.zig" },
    }) |import| {
        bench.root_module.addImport(import[0], b.createModule(.{
            .root_source_file = b.path(import[1]),
            .target = target,
            .optimize = .fast,
        }));
    }
    addMeshes(b, upstream, bench.root_module);
    const run_bench = b.addRunArtifact(bench);
    run_bench.addPassthruArgs();
    bench_step.dependOn(&run_bench.step);
}

const upstream_sources = [_][]const u8{
    "Recast.cpp",
    "RecastAlloc.cpp",
    "RecastArea.cpp",
    "RecastAssert.cpp",
    "RecastContour.cpp",
    "RecastFilter.cpp",
    "RecastLayers.cpp",
    "RecastMesh.cpp",
    "RecastMeshDetail.cpp",
    "RecastRasterization.cpp",
    "RecastRegion.cpp",
};

/// The flags Loomwork builds the original with, and fused multiply-adds
/// off so float steps round as written, as Zig's do.
const cpp_flags = [_][]const u8{
    "-std=c++11",
    "-fno-exceptions",
    "-fno-rtti",
    "-fno-threadsafe-statics",
    "-ffp-contract=off",
    "-fno-fast-math",
    "-fno-sanitize=undefined",
};

/// The original Recast with the tests' C interface. `oracle` adds the
/// stable qsort the tests compare against.
fn upstreamLibrary(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    oracle: bool,
) *std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = if (oracle) "recast_oracle" else "recast_upstream",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .fast,
            .link_libc = true,
        }),
    });
    lib.root_module.addIncludePath(upstream.path("Recast/Include"));
    lib.root_module.addCSourceFiles(.{
        .root = upstream.path("Recast/Source"),
        .files = &upstream_sources,
        .flags = &cpp_flags,
    });
    lib.root_module.addCSourceFile(.{
        .file = b.path("test/shim/recast_shim.cpp"),
        .flags = &cpp_flags,
    });
    if (oracle) {
        lib.root_module.addCSourceFile(.{
            .file = b.path("test/shim/stable_qsort.c"),
            .flags = &.{ "-std=c11", "-ffp-contract=off", "-fno-fast-math" },
        });
    }
    return lib;
}

const mesh_names = [_][]const u8{ "dungeon", "nav_test", "undulating" };

/// RecastDemo's test meshes, embedded by name (`@embedFile("dungeon")`).
fn addMeshes(b: *std.Build, upstream: *std.Build.Dependency, module: *std.Build.Module) void {
    for (mesh_names) |name| {
        module.addAnonymousImport(name, .{
            .root_source_file = upstream.path(b.fmt("RecastDemo/Bin/Meshes/{s}.obj", .{name})),
        });
    }
}
