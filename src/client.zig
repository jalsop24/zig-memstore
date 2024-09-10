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
    const header_len = try std.posix.read(fd, mbuf[0..4]);
    if (header_len < 4) {
        std.log.info("Unable to read full header. {} bytes", .{header_len});
        return error.MessageTooShort;
    }
    const m_len = std.mem.readPackedInt(u32, mbuf[0..4], 0, .little);
    if (m_len > protocol.k_max_msg) {
        std.log.info("Invalid response {}", .{m_len});
        return error.InvalidResponse;
    }
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

    var wbuf: [protocol.k_max_msg]u8 = undefined;

    const messages = [_]*const [9:0]u8{ "Hello ...", "message 2", "message 3" };
    for (messages) |message| {
        const wlen = try protocol.createPayload(message, &wbuf);
        const size = try std.posix.write(stream.handle, wbuf[0..wlen]);
        std.log.info("Sending '{s}' to server, total sent: {d} bytes", .{ wbuf[4..wlen], size });
    }

    for (0..3) |_| {
        var rbuf: [protocol.k_max_msg]u8 = undefined;
        const len = try receiveMessage(stream.handle, &rbuf);
        std.log.info("Received from server '{s}'", .{rbuf[0..len]});
    }
}
