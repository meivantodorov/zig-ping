const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "main",
        .root_source_file = .{ .path = "main.zig" },
    });

    b.installArtifact(exe);
}
