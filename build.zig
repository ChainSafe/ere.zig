const std = @import("std");
const builtin = @import("builtin");

/// ere publishes `libere_verifier_c` for aarch64 macOS and for x86_64 and
/// aarch64 glibc Linux. Every other target gets the module with
/// `available = false` and no `c`, so consumers gate on `available`.
///
/// Linux links the archive statically. Rust's unwinder needs `-lunwind`, and
/// Zig's self-hosted x86_64 ELF linker cannot read the archive, so consumers
/// building x86_64 Debug binaries must set `use_llvm` and `use_lld`.
///
/// macOS cannot link the archive statically: Zig's Mach-O linker rejects the
/// debug stabs of the `ld -r` merged object and, once those are stripped,
/// mislays its thread-local offsets. Native macOS builds instead turn the
/// archive into a dylib with Apple's ld. Consumers install it beside their
/// binary from the named lazy path `libere_verifier_c.dylib`; the module
/// carries an `@loader_path` rpath for that and an rpath into the cache for
/// test binaries.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dylib_option = b.option(
        bool,
        "dylib",
        "On macOS, link through a dylib built with Apple's ld. Defaults to true for native macOS builds.",
    );

    const t = target.result;
    const native = target.query.isNativeOs() and target.query.isNativeCpu();
    const darwin_dylib = dylib_option orelse (t.os.tag == .macos and native and builtin.os.tag == .macos);

    const package: ?*std.Build.Dependency = switch (t.os.tag) {
        .macos => if (t.cpu.arch == .aarch64 and darwin_dylib) b.lazyDependency("darwin_arm64", .{}) else null,
        .linux => if (t.abi != .gnu) null else switch (t.cpu.arch) {
            .x86_64 => b.lazyDependency("linux_amd64", .{}),
            .aarch64 => b.lazyDependency("linux_arm64", .{}),
            else => null,
        },
        else => null,
    };

    const options = b.addOptions();
    options.addOption(bool, "available", package != null);

    const module = b.addModule("ere_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addOptions("build_options", options);

    if (package) |pkg| {
        const translated = b.addTranslateC(.{
            .root_source_file = pkg.path("ere_verifier.h"),
            .target = target,
            .optimize = optimize,
        });
        module.addImport("c", translated.createModule());

        const archive = pkg.path("libere_verifier_c.a");
        switch (t.os.tag) {
            .linux => {
                module.addObjectFile(archive);
                module.linkSystemLibrary("m", .{});
                module.linkSystemLibrary("pthread", .{});
                module.linkSystemLibrary("dl", .{});
                module.linkSystemLibrary("unwind", .{});
            },
            .macos => linkDarwinDylib(b, module, target, optimize, archive),
            else => unreachable,
        }
    }

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ere_zig", .module = module }},
        }),
    });
    if (t.os.tag == .linux and t.cpu.arch == .x86_64) {
        tests.use_llvm = true;
        tests.use_lld = true;
    }
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);

    const download = b.addExecutable(.{
        .name = "download_fixtures",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/download_fixtures.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    b.step("download-fixtures", "Download ere's verifier fixtures into test/fixtures").dependOn(&b.addRunArtifact(download).step);
}

fn linkDarwinDylib(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    archive: std.Build.LazyPath,
) void {
    const min_os = target.result.os.version_range.semver.min;
    const sdk_path = std.mem.trim(u8, b.run(&.{ "xcrun", "--show-sdk-path" }), &std.ascii.whitespace);
    const sdk_version = std.mem.trim(u8, b.run(&.{ "xcrun", "--show-sdk-version" }), &std.ascii.whitespace);

    const strip = b.addSystemCommand(&.{ "strip", "-S", "-o" });
    const stripped = strip.addOutputFileArg("libere_verifier_c.a");
    strip.addFileArg(archive);

    // The archive localizes `_rust_eh_personality` but still references it, so
    // the dylib needs a definition. Unwinding reaches it only on a panic inside
    // the verifier, which then traps instead of unwinding into a hidden routine.
    const stub_source = b.addWriteFiles().add("rust_eh_personality_stub.zig",
        \\export fn rust_eh_personality() callconv(.c) noreturn {
        \\    @trap();
        \\}
        \\
    );
    const stub = b.addObject(.{
        .name = "rust_eh_personality_stub",
        .root_module = b.createModule(.{
            .root_source_file = stub_source,
            .target = target,
            .optimize = optimize,
        }),
    });

    const ld = b.addSystemCommand(&.{
        "ld",                                              "-dylib",
        "-arch",                                           "arm64",
        "-platform_version",                               "macos",
        b.fmt("{d}.{d}", .{ min_os.major, min_os.minor }), sdk_version,
        "-syslibroot",                                     sdk_path,
        "-lSystem",                                        "-all_load",
        "-install_name",                                   "@rpath/libere_verifier_c.dylib",
    });
    ld.addFileArg(stripped);
    ld.addFileArg(stub.getEmittedBin());
    ld.addArg("-o");
    const dylib = ld.addOutputFileArg("libere_verifier_c.dylib");

    module.addObjectFile(dylib);
    module.addRPath(dylib.dirname());
    module.addRPathSpecial("@loader_path");
    b.addNamedLazyPath("libere_verifier_c.dylib", dylib);
}
