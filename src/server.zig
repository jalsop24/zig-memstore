const std = @import("std");

const protocol = @import("protocol.zig");

fn getPortFromArgs(args: *std.process.ArgIterator) !u16 {
    const raw_port = args.next() orelse {
        std.log.info("Expected port as a command line argument\n", .{});
        return error.NoPort;
    };
    return try std.fmt.parseInt(u16, raw_port, 10);
}

fn oneRequest(stream: *const std.net.Stream) !void {
    var m_buf: [protocol.k_max_msg]u8 = undefined;
    const len = try protocol.receiveMessage(stream, &m_buf);
    std.log.info("Client says '{s}'", .{m_buf[0..len]});

    const reply = "world!";
    try protocol.sendMessage(stream, reply);
}

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_alloc.deinit() == .ok);
    const allocator = gpa_alloc.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip first argument (path to program)
    _ = args.skip();
    const port = try getPortFromArgs(&args);

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    var server = try address.listen(.{
        .reuse_port = true,
    });
    defer server.deinit();
    std.log.info("Server listening on port {}", .{address.getPort()});

    while (true) {
        const client = try server.accept();
        defer client.stream.close();
        std.log.info("Connection received! {} is sending data...", .{client.address});

        const stream = client.stream;
        while (true) {
            oneRequest(&stream) catch |err| switch (err) {
                error.EOF => break,
                else => return err,
            };
        }
    }
}
