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
    const filter_target = b.option([]const u8, "target", "Only run tests for this target (e.g. x86_64-windows-gnu)");
    const filter_ccache = b.option(bool, "use-ccache", "Only run tests with ccache enabled/disabled");

    const test_step = b.step("test", "Run all cross-compilation tests");

    const source_dir = b.path("test");
    const toolchain_file = b.path("zig-toolchain.cmake");

    for ([_]bool{ false, true }) |use_ccache| {
        if (filter_ccache) |f| if (f != use_ccache) continue;

        for (targets) |t| {
            if (filter_target) |f| if (!std.mem.eql(u8, f, t.target)) continue;

            const dir_suffix = if (use_ccache) "-with-ccache" else "";
            const dir_name = b.fmt("{s}{s}", .{ t.target, dir_suffix });
            const ccache_status = if (use_ccache) "ON" else "OFF";

            const cfg_cmd = b.addSystemCommand(&.{ "cmake", "-G", "Ninja" });
            cfg_cmd.setName(b.fmt("cmake config {s}", .{dir_name}));
            cfg_cmd.addArgs(&.{ "-S", source_dir.getPath(b), "-B" });
            const build_dir = cfg_cmd.addOutputDirectoryArg(dir_name);
            cfg_cmd.addArgs(&.{
                b.fmt("-DCMAKE_TOOLCHAIN_FILE={s}", .{toolchain_file.getPath(b)}),
                b.fmt("-DZIG_TARGET={s}", .{t.target}),
                b.fmt("-DZIG_USE_CCACHE={s}", .{ccache_status}),
            });

            const build_cmd = b.addSystemCommand(&.{ "cmake", "--build" });
            build_cmd.setName(b.fmt("cmake build {s}", .{dir_name}));
            build_cmd.addDirectoryArg(build_dir);

            const verify_step = VerifyStep.create(b, t, build_dir);
            verify_step.step.dependOn(&build_cmd.step);

            test_step.dependOn(&verify_step.step);
        }
    }
}

const VerifyStep = struct {
    step: std.Build.Step,
    target: Target,
    build_dir: std.Build.LazyPath,

    pub fn create(b: *std.Build, target: Target, build_dir: std.Build.LazyPath) *VerifyStep {
        const self = b.allocator.create(VerifyStep) catch @panic("OOM");

        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("verify {s}", .{target.target}),
                .owner = b,
                .makeFn = make,
            }),
            .target = target,
            .build_dir = build_dir,
        };
        return self;
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
        const self: *VerifyStep = @fieldParentPtr("step", step);
        const b = step.owner;

        const artifacts = [_][]const u8{ "c_app", "cxx_app" };
        const exe_suffix = if (self.target.os == .windows) ".exe" else "";

        const build_dir_path = self.build_dir.getPath(b);

        for (artifacts) |name| {
            const bin_name = b.fmt("{s}{s}", .{ name, exe_suffix });
            const bin_path = try std.fs.path.join(b.allocator, &.{ build_dir_path, bin_name });
            defer b.allocator.free(bin_path);

            try verify_binary_header(b.graph.io, bin_path, self.target.os, self.target.arch);
            std.debug.print("  [OK] {s} ({s})\n", .{ bin_name, self.target.target });
        }
    }
};

fn verify_binary_header(io: std.Io, path: []const u8, os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) !void {
    const ELF_MAGIC = "\x7fELF";
    const PE_MAGIC = "MZ";
    const PE_SIGNATURE = "PE\x00\x00";
    const MACHO_MAGIC_64: u32 = 0xFEEDFACF;
    const MACHO_CPU_TYPE_X86_64: u32 = 0x01000007;
    const MACHO_CPU_TYPE_ARM64: u32 = 0x0100000C;

    var buffer: [1024]u8 = undefined;
    const contents = try std.Io.Dir.cwd().readFile(io, path, &buffer);

    if (contents.len < 64) {
        return error.FileTooSmall;
    }

    switch (os) {
        .linux => {
            if (!std.mem.eql(u8, contents[0..4], ELF_MAGIC)) {
                return error.InvalidElfMagic;
            }
            const machine = std.mem.readInt(u16, contents[0x12..][0..2], .little);
            switch (arch) {
                .x86_64 => if (machine != 0x3E) return error.ArchMismatch,
                .aarch64 => if (machine != 0xB7) return error.ArchMismatch,
                else => {},
            }
        },
        .windows => {
            if (!std.mem.eql(u8, contents[0..2], PE_MAGIC)) {
                return error.InvalidDosHeader;
            }
            const pe_offset = std.mem.readInt(u32, contents[0x3C..][0..4], .little);
            if (pe_offset + 6 > contents.len) {
                return error.HeaderOutOfBounds;
            }
            const pe_sig = contents[pe_offset .. pe_offset + 4];
            if (!std.mem.eql(u8, pe_sig, PE_SIGNATURE)) {
                return error.InvalidPeSignature;
            }
            const machine_offset = pe_offset + 4;
            const machine = std.mem.readInt(u16, contents[machine_offset..][0..2], .little);
            switch (arch) {
                .x86_64 => if (machine != 0x8664) return error.ArchMismatch,
                .aarch64 => if (machine != 0xAA64) return error.ArchMismatch,
                else => {},
            }
        },
        .macos => {
            const magic = std.mem.readInt(u32, contents[0..][0..4], .little);
            if (magic != MACHO_MAGIC_64) {
                return error.InvalidMachOMagic;
            }
            const cpu_type = std.mem.readInt(u32, contents[4..][0..4], .little);

            switch (arch) {
                .x86_64 => if (cpu_type != MACHO_CPU_TYPE_X86_64) return error.ArchMismatch,
                .aarch64 => if (cpu_type != MACHO_CPU_TYPE_ARM64) return error.ArchMismatch,
                else => {},
            }
        },
        else => return error.UnsupportedOsForVerification,
    }
}
