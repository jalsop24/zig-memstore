const std = @import("std");

const protocol = @import("protocol.zig");
const cli = @import("cli.zig");

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_alloc.deinit() == .ok);
    const allocator = gpa_alloc.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip first argument (path to program)
    _ = args.skip();
    const addr = try cli.getAddressFromArgs(&args);

    std.log.info("Connecting to {}", .{addr});
    const stream = std.net.tcpConnectToAddress(addr) catch |err| {
        switch (@TypeOf(err)) {
            std.net.TcpConnectToAddressError => {
                std.log.info("Failed to connect to {}", .{addr});
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

        switch (protocol.parseCommand(message)) {
            .Get => {
                wlen = try protocol.createGetReq(message[3..], &wbuf);
            },
            .Set => {
                wlen = try protocol.createSetReq(message[3..], &wbuf);
            },
            .Delete => {
                wlen = try protocol.createDelReq(message[3..], &wbuf);
            },
            .Unknown => {
                if (std.mem.eql(u8, message, "exit")) {
                    break;
                }

                std.log.info("Unknown command", .{});
                wlen = try protocol.createPayload(message, &wbuf);
            },
        }

        // Send contents of write buffer
        const size = try std.posix.write(stream.handle, wbuf[0..wlen]);
        std.log.info("Sending '{0s}' ({0x}) to server, total sent: {1d} bytes", .{ wbuf[4..wlen], size });

        var rbuf: [protocol.k_max_msg]u8 = undefined;
        const len = try protocol.receiveMessage(stream.reader().any(), &rbuf);
        std.log.info("Received from server '{s}'", .{rbuf[0..len]});
    }
}
