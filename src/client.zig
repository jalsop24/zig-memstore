const std = @import("std");

const protocol = @import("protocol.zig");

fn getPortFromArgs(args: *std.process.ArgIterator) !u16 {
    const raw_port = args.next() orelse {
        std.log.info("Expected port as a command line argument\n", .{});
        return error.NoPort;
    };
    return try std.fmt.parseInt(u16, raw_port, 10);
}

fn receiveMessage(fd: std.posix.socket_t, mbuf: *[protocol.k_max_msg]u8) !usize {
    _ = try std.posix.read(fd, mbuf[0..4]);
    const m_len = std.mem.readPackedInt(u32, mbuf[0..4], 0, .little);
    const m_read = try std.posix.read(fd, mbuf[0..m_len]);
    return m_read;
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
    const localhost = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port);

    std.log.info("Connecting to {}", .{localhost});
    const stream = std.net.tcpConnectToAddress(localhost) catch |err| {
        switch (@TypeOf(err)) {
            std.net.TcpConnectToAddressError => {
                std.log.info("Failed to connect to {}", .{localhost});
                return;
            },
            else => {
                return err;
            },
        }
    };
    defer stream.close();
    std.log.info("Connected!", .{});

    const message = "Hello ...";
    var wbuf: [protocol.k_max_msg]u8 = undefined;
    const wlen = try protocol.createPayload(message, &wbuf);
    const size = try std.posix.write(stream.handle, wbuf[0..wlen]);

    std.log.info("Sending '{s}' to server, total sent: {d} bytes\n", .{ wbuf[4..wlen], size });

    var mbuf: [protocol.k_max_msg]u8 = undefined;

    const len = try receiveMessage(stream.handle, &mbuf);

    std.log.info("Received from server '{s}'", .{mbuf[0..len]});
}
