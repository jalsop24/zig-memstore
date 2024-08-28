const std = @import("std");

const protocol = @import("protocol.zig");

fn getPortFromArgs(args: *std.process.ArgIterator) !u16 {
    const raw_port = args.next() orelse {
        std.log.info("Expected port as a command line argument\n", .{});
        return error.NoPort;
    };
    return try std.fmt.parseInt(u16, raw_port, 10);
}

fn oneRequest(connection: *std.net.Stream) !void {
    var r_buf: [4 + protocol.k_max_msg]u8 = undefined;

    const num_read = try connection.readAtLeast(&r_buf, 4);
    if (num_read < 4) {
        std.log.debug(
            "Failed to read full message length. Read {} bytes",
            .{num_read},
        );
        return error.EOF;
    }
    const len = std.mem.readPackedInt(
        u32,
        r_buf[0..4],
        0,
        .little,
    );

    if (len > protocol.k_max_msg) {
        std.log.debug("Len {}", .{len});
        std.log.debug("Message: {x}", .{r_buf[0..4]});
        return error.MessageTooLong;
    }

    if (num_read < 4 + len) {
        const num_left = 4 + len - num_read;
        const num_read_body = try connection.readAtLeast(r_buf[4..], num_left);
        if (num_read_body != len) {
            std.log.debug("Connection closed before reading full message - {s}", .{r_buf});
            return error.EOF;
        }
    }

    const message = r_buf[4 .. 4 + len];

    std.log.debug("Full message {x}", .{r_buf[0 .. 4 + len]});
    std.log.info("Received {} bytes from client", .{4 + len});
    std.log.info("Client says '{s}'", .{message});
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
        var client = try server.accept();
        defer client.stream.close();
        std.log.info("Connection received! {} is sending data...", .{client.address});

        while (true) {
            oneRequest(&client.stream) catch |err| switch (err) {
                error.EOF => break,
                else => return err,
            };
        }
    }
}
