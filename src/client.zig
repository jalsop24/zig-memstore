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

fn readWord(buf: []u8, out_buf: []u8) !struct { u16, u32 } {
    std.log.debug("Read word from buf '{s}'", .{buf});

    var start: u32 = 0;
    // Consume all leading whitespace
    for (0..buf.len) |i| {
        if (buf[i] != ' ') {
            start = @intCast(i);
            break;
        }
    }
    // What if that loop gets all the way to the end of the buffer?
    var end: u32 = 0;
    for (start..buf.len) |i| {
        std.log.debug("char {c}", .{buf[i]});
        end = @intCast(i);
        if (buf[i] == ' ' or buf[i] == '\n') {
            end -= 1;
            break;
        }

        if (i - start > out_buf.len or i - start > 2 ^ 16 - 1) return error.WordTooLong;

        // Copy key char into output buffer
        out_buf[i - start] = buf[i];
    }

    return .{ @intCast(end + 1 - start), end + 1 };
}

fn parseWord(buf: []u8, out_buf: []u8) !struct { u16, u32 } {
    const w_len, const bytes_read = try readWord(buf, out_buf[2..]);

    std.mem.writePackedInt(
        u16,
        out_buf[0..2],
        0,
        w_len,
        .little,
    );

    return .{ w_len, bytes_read };
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
    errdefer |err| {
        std.log.info("Err - {}", .{err});
        stream.close();
    }
    std.log.info("Connected!", .{});

    var wbuf: [protocol.k_max_msg]u8 = undefined;
    var input_buf: [1000]u8 = undefined;
    var cli_reader = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();
    const DELIMITER: u8 = '\n';

    while (true) {
        _ = try stdout.write(">>> ");
        var message = try cli_reader.readUntilDelimiterOrEof(&input_buf, DELIMITER) orelse return;
        var wlen: u32 = 0;

        switch (protocol.parseCommand(message[0..3])) {
            .Get => {
                const out_buf = wbuf[4..];
                @memcpy(out_buf[0..3], "get");

                // Parse the key back into the input buffer
                const key_len, _ = try parseWord(message[3..], out_buf[3..]);
                std.log.info("Key length {}", .{key_len});

                // 3 Bytes for command
                // 2 bytes for key length
                // key_len bytes for key content
                const m_len: u32 = 3 + 2 + key_len;

                std.mem.writePackedInt(
                    u32,
                    wbuf[0..4],
                    0,
                    m_len,
                    .little,
                );
                wlen = 4 + m_len;
            },
            .Set => {
                const out_buf = wbuf[4..];
                @memcpy(out_buf[0..3], "set");

                const key_len, const bytes_read = try parseWord(message[3..], out_buf[3..]);
                std.log.info("Key length {}", .{key_len});
                std.log.info("Bytes read {}", .{bytes_read});

                // Parse value into out_buffer at 5 + key_len position:
                // 3 bytes for "set"
                // 2 bytes for key_len
                // key_len bytes for key
                const val_len, _ = try parseWord(message[3 + bytes_read ..], out_buf[5 + key_len ..]);
                std.log.info("Val length {}", .{val_len});

                // 3 Bytes for command
                // 2 bytes for key length
                // key_len bytes for key content
                // 2 bytes for val length
                // val_len bytes for val content
                const m_len: u32 = 3 + 2 + key_len + 2 + val_len;

                std.mem.writePackedInt(
                    u32,
                    wbuf[0..4],
                    0,
                    m_len,
                    .little,
                );

                wlen = 4 + m_len;
            },
            .Delete => {
                const out_buf = wbuf[4..];
                @memcpy(out_buf[0..3], "del");

                // Parse the key back into the input buffer
                const key_len, _ = try parseWord(message[3..], out_buf[3..]);
                std.log.info("Key length {}", .{key_len});

                // 3 Bytes for command
                // 2 bytes for key length
                // key_len bytes for key content
                const m_len: u32 = 3 + 2 + key_len;

                std.mem.writePackedInt(
                    u32,
                    wbuf[0..4],
                    0,
                    m_len,
                    .little,
                );
                wlen = 4 + m_len;
            },
            .Unknown => {
                std.log.info("Unknown command", .{});
                wlen = try protocol.createPayload(message, &wbuf);
            },
        }

        // Send contents of write buffer
        const size = try std.posix.write(stream.handle, wbuf[0..wlen]);
        std.log.info("Sending '{0s}' ({0x}) to server, total sent: {1d} bytes", .{ wbuf[4..wlen], size });

        var rbuf: [protocol.k_max_msg]u8 = undefined;
        const len = try receiveMessage(stream.handle, &rbuf);
        std.log.info("Received from server '{s}'", .{rbuf[0..len]});
    }
}
