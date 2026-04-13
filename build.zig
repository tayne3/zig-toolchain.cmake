const std = @import("std");

const Target = struct {
    target: []const u8,
    os: std.Target.Os.Tag,
    arch: std.Target.Cpu.Arch,
};

const targets = [_]Target{
    .{ .target = "x86_64-linux-gnu", .os = .linux, .arch = .x86_64 },
    .{ .target = "aarch64-linux-gnu", .os = .linux, .arch = .aarch64 },
    .{ .target = "x86_64-linux-musl", .os = .linux, .arch = .x86_64 },
    .{ .target = "aarch64-linux-musl", .os = .linux, .arch = .aarch64 },
    .{ .target = "x86_64-windows-gnu", .os = .windows, .arch = .x86_64 },
    .{ .target = "aarch64-windows-gnu", .os = .windows, .arch = .aarch64 },
    .{ .target = "x86_64-macos", .os = .macos, .arch = .x86_64 },
    .{ .target = "aarch64-macos", .os = .macos, .arch = .aarch64 },
};

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Run all cross-compilation tests");

    var prev_step: ?*std.Build.Step = null;
    var count: usize = 0;

    std.debug.print("\n" ++ "=" ** 60 ++ "\n", .{});
    std.debug.print("[INFO] Total configurations: {d}\n", .{targets.len * 2});
    std.debug.print("=" ** 60 ++ "\n\n", .{});

    for ([_]bool{ false, true }) |use_ccache| {
        for (targets) |t| {
            const step = TestStep.create(b, t, use_ccache);
            if (prev_step) |prev| {
                step.dependOn(prev);
            }
            test_step.dependOn(step);
            prev_step = step;
            count += 1;
        }
    }

    std.debug.print("[INFO] {d} test steps scheduled\n\n", .{count});
}

const TestStep = struct {
    step: std.Build.Step,
    target: Target,
    use_ccache: bool,

    pub fn create(b: *std.Build, t: Target, use_ccache: bool) *std.Build.Step {
        const self = b.allocator.create(TestStep) catch @panic("OOM");
        const ccache_str = if (use_ccache) "ccache" else "no-ccache";
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("test-{s}-{s}", .{ t.target, ccache_str }),
                .owner = b,
                .makeFn = make,
            }),
            .target = t,
            .use_ccache = use_ccache,
        };
        return &self.step;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const self: *TestStep = @fieldParentPtr("step", step);
        try run_test(step.owner, self.target, self.use_ccache);
    }
};

fn run_test(b: *std.Build, t: Target, use_ccache: bool) !void {
    var timer = try std.time.Timer.start();
    const allocator = b.allocator;
    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const toolchain_path = try std.fs.path.join(allocator, &.{ cwd, "zig-toolchain.cmake" });
    const dir_suffix = if (use_ccache) "-with-ccache" else "";
    const dir_name = b.fmt("{s}{s}", .{ t.target, dir_suffix });
    const build_dir = try std.fs.path.join(allocator, &.{ cwd, "build", dir_name });
    const source_dir = try std.fs.path.join(allocator, &.{ cwd, "test" });
    const ccache_status = if (use_ccache) "ON" else "OFF";

    std.debug.print("\n[TEST] {s} | Ccache: {s}\n", .{ t.target, ccache_status });

    // Configure
    try run_command(allocator, &[_][]const u8{
        "cmake",
        "-B",
        build_dir,
        "-S",
        source_dir,
        "-G",
        "Ninja",
        b.fmt("-DCMAKE_TOOLCHAIN_FILE={s}", .{toolchain_path}),
        b.fmt("-DZIG_TARGET={s}", .{t.target}),
        b.fmt("-DZIG_USE_CCACHE={s}", .{ccache_status}),
    });

    // Build
    try run_command(allocator, &[_][]const u8{
        "cmake",
        "--build",
        build_dir,
        "--parallel",
        b.fmt("{d}", .{(std.Thread.getCpuCount() catch 0) + 1}),
    });

    // Verify artifacts
    const artifacts = [_][]const u8{ "c_app", "cxx_app" };
    const exe_suffix = if (t.os == .windows) ".exe" else "";

    for (artifacts) |name| {
        const bin_name = b.fmt("{s}{s}", .{ name, exe_suffix });
        const bin_path = try std.fs.path.join(allocator, &.{ build_dir, bin_name });
        defer allocator.free(bin_path);

        try verify_binary_header(bin_path, t.os, t.arch);
        std.debug.print("  [OK] {s}\n", .{name});
    }

    const duration = timer.read() / std.time.ns_per_ms;
    std.debug.print("[PASS] All checks passed for {s} ({d}ms)\n", .{ t.target, duration });
}

fn verify_binary_header(path: []const u8, os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) !void {
    const ELF_MAGIC = "\x7fELF";
    const PE_MAGIC = "MZ";
    const PE_SIGNATURE = "PE\x00\x00";
    const MACHO_MAGIC_64 = 0xFEEDFACF;
    const MACHO_CPU_TYPE_X86_64 = 0x01000007;
    const MACHO_CPU_TYPE_ARM64 = 0x0100000C;

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Could not open binary file: {s}\n", .{path});
        return err;
    };
    defer file.close();

    var buffer: [1024]u8 = undefined;
    const bytes_read = try file.read(&buffer);
    if (bytes_read < 64) {
        return error.FileTooSmall;
    }
    switch (os) {
        .linux => {
            if (!std.mem.eql(u8, buffer[0..4], ELF_MAGIC)) {
                return error.InvalidElfMagic;
            }
            const machine = std.mem.readInt(u16, buffer[0x12..][0..2], .little);
            switch (arch) {
                .x86_64 => if (machine != 0x3E) return error.ArchMismatch,
                .aarch64 => if (machine != 0xB7) return error.ArchMismatch,
                else => {},
            }
        },
        .windows => {
            if (!std.mem.eql(u8, buffer[0..2], PE_MAGIC)) {
                return error.InvalidDosHeader;
            }
            const pe_offset = std.mem.readInt(u32, buffer[0x3C..][0..4], .little);
            if (pe_offset + 6 > bytes_read) {
                return error.HeaderOutOfBounds;
            }
            const pe_sig = buffer[pe_offset .. pe_offset + 4];
            if (!std.mem.eql(u8, pe_sig, PE_SIGNATURE)) {
                return error.InvalidPeSignature;
            }
            const machine_offset = pe_offset + 4;
            const machine = std.mem.readInt(u16, buffer[machine_offset..][0..2], .little);
            switch (arch) {
                .x86_64 => if (machine != 0x8664) return error.ArchMismatch,
                .aarch64 => if (machine != 0xAA64) return error.ArchMismatch,
                else => {},
            }
        },
        .macos => {
            const magic = std.mem.readInt(u32, buffer[0..][0..4], .little);
            if (magic != MACHO_MAGIC_64) {
                return error.InvalidMachOMagic;
            }
            const cpu_type = std.mem.readInt(u32, buffer[4..][0..4], .little);

            switch (arch) {
                .x86_64 => if (cpu_type != MACHO_CPU_TYPE_X86_64) return error.ArchMismatch,
                .aarch64 => if (cpu_type != MACHO_CPU_TYPE_ARM64) return error.ArchMismatch,
                else => {},
            }
        },
        else => return error.UnsupportedOsForVerification,
    }
}

fn run_command(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 10 * 1024 * 1024,
    }) catch |err| {
        std.debug.print("\n[CRITICAL] Failed to spawn command: {any}\n", .{err});
        return err;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("\n" ++ "!" ** 60 ++ "\n", .{});
                std.debug.print("[ERROR] Command failed with exit code {d}\n", .{code});

                std.debug.print("COMMAND: ", .{});
                for (argv) |arg| {
                    std.debug.print("{s} ", .{arg});
                }
                std.debug.print("\n\n", .{});

                if (result.stdout.len > 0) {
                    std.debug.print("=== STDOUT ===\n{s}\n", .{result.stdout});
                }
                if (result.stderr.len > 0) {
                    std.debug.print("=== STDERR ===\n{s}\n", .{result.stderr});
                }
                std.debug.print("!" ** 60 ++ "\n\n", .{});
                return error.CommandFailed;
            }
        },
        else => {
            std.debug.print("\n[CRASH] Command terminated unexpectedly (Signal/Crash)\n", .{});
            return error.CommandCrashed;
        },
    }
}
