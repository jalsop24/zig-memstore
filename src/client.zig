const std = @import("std");

const protocol = @import("protocol.zig");
const cli = @import("cli.zig");

const LogLevel = std.log.Level;
const Command = protocol.Command;

pub const std_options = .{
    .log_level = LogLevel.debug,
};

fn handleResponse(buf: []const u8) !void {
    const command = protocol.decodeCommand(buf) catch |err| switch (err) {
        std.meta.IntToEnumError.InvalidEnumTag => {
            std.log.info("{s}", .{buf});
            return;
        },
    };

    switch (command) {
        Command.Get => try handleGetResponse(buf[protocol.COMMAND_LEN_BYTES..]),
        else => std.log.info("{s}", .{buf}),
    }
}

fn handleGetResponse(buf: []const u8) !void {
    const get_response = try protocol.parseGetResponse(buf);
    const key = get_response.key;

    if (get_response.value) |value| {
        std.log.info("Get response '{0s}' -> '{1s}'", .{ key.content, value.content });
        return;
    }

    std.log.info("Get response '{0s}' -> null", .{key.content});
}

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

        std.log.debug("received message '{s}'", .{message});

        if (std.mem.eql(u8, message, "exit")) {
            break;
        }

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
            .List => {
                wlen = try protocol.createListReq(message[3..], &wbuf);
            },
            .Unknown => {
                std.log.info("Unknown command", .{});
                wlen = try protocol.createPayload(message, &wbuf);
            },
        }

        // Send contents of write buffer
        const size = try std.posix.write(stream.handle, wbuf[0..wlen]);
        std.log.debug(
            "Sending '{0s}' ({0x}) to server, request size: {1d}, total sent: {2d} bytes",
            .{ wbuf[4..wlen], wlen, size },
        );

        var rbuf: [protocol.k_max_msg]u8 = undefined;
        const len = try protocol.receiveMessage(stream.reader().any(), &rbuf);
        const response = rbuf[0..len];

        std.log.info("Received from server '{0s}' ({0x})", .{response});
        try handleResponse(response);
    }
}
