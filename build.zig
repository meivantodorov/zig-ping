const std = @import("std");

pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "zig-ping",
        .root_source_file = .{ .path = "main.zig" },
    });

    b.installArtifact(exe);
}
