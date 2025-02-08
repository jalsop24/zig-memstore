const std = @import("std");

const types = @import("types.zig");

const HashMap = types.HashMap;

test "hashmap" {
    const alloc = std.testing.allocator;
    var hash_map = try HashMap.init(alloc);
    defer hash_map.deinit();

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();

    const num_ops = 100_000;
    const timestamp = std.time.nanoTimestamp;
    const unit = "ns";

    const start_ts = timestamp();
    for (0..num_ops) |i| {
        try hash_map.put(
            .{ .content = try std.fmt.allocPrint(arena.allocator(), "key {d}", .{i}) },
            .{ .content = try std.fmt.allocPrint(arena.allocator(), "val {d}", .{i}) },
        );
        _ = hash_map.get(.{ .content = "key 1" });
    }
    const end_ts = timestamp();
    const elapsed_time = @as(f64, @floatFromInt(end_ts - start_ts)) / num_ops;
    std.debug.print("Elapsed time per op: {d:.2}{s}\n", .{ elapsed_time, unit });
}
