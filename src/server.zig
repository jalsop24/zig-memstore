const std = @import("std");

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_alloc.deinit() == .ok);
    const allocator = gpa_alloc.allocator();

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, 9876);
    var server = try address.listen(.{
        .reuse_port = true,
    });
    defer server.deinit();
    std.log.info("Server listening on port {}\n", .{address.getPort()});

    var client = try server.accept();
    defer client.stream.close();
    std.log.info("Connection received! {} is sending data...\n", .{client.address});

    const message = try client.stream.reader().readAllAlloc(allocator, 1024);
    defer allocator.free(message);

    std.log.info("{} says {s}\n", .{ client.address, message });
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // Try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
    const input_bytes = std.testing.fuzzInput(.{});
    try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input_bytes));
}
