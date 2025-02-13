const std = @import("std");

const protocol = @import("protocol.zig");
const cli = @import("cli.zig");
const types = @import("types.zig");
const serialization = @import("serialization.zig");

const LogLevel = std.log.Level;

const Command = types.Command;
const COMMAND_LEN_BYTES = types.COMMAND_LEN_BYTES;

const len_header_size = protocol.len_header_size;
const encodeHeader = protocol.encodeHeader;

const Encoder = serialization.Encoder;

pub const std_options: std.Options = .{
    .log_level = LogLevel.debug,
};

fn handleResponse(response: protocol.Response) !void {
    switch (response) {
        .Get => |get_response| try handleGetResponse(get_response),
        .Set => |set_response| try handleSetResponse(set_response),
        .Delete => |delete_response| try handleDeleteResponse(delete_response),
        .List => |list_response| try handleListResponse(list_response),
        .Unknown => |unknown_response| handleUnknownResponse(unknown_response),
    }
}

fn handleGetResponse(get_response: protocol.GetResponse) !void {
    const key = get_response.key;

    if (get_response.value) |value| {
        std.log.info("Get response '{0s}' -> '{1s}'", .{ key.content, value.content });
        return;
    }

    std.log.info("Get response '{0s}' -> null", .{key.content});
}

fn handleSetResponse(set_response: protocol.SetResponse) !void {
    const key = set_response.key;
    const value = set_response.value;
    std.log.info("Set response '{0s}' = '{1s}'", .{ key.content, value.content });
}

fn handleDeleteResponse(delete_response: protocol.DeleteResponse) !void {
    const key = delete_response.key;
    std.log.info("Deleted '{s}'", .{key.content});
}

fn handleListResponse(list_response: protocol.ListResponse) !void {
    if (list_response.len == 0) {
        std.log.info("no keys", .{});
        return;
    }

    var iter = list_response.iterator();
    while (iter.next()) |kv_pair| {
        std.log.info("'{0s}' = '{1s}'", .{ kv_pair.key.content, kv_pair.value.content });
    }
}

fn handleUnknownResponse(response: protocol.UnknownResponse) void {
    std.log.info("{s}", .{response.content});
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
        var wlen: usize = 0;

        std.log.debug("received message '{s}'", .{message});

        if (std.mem.eql(u8, message, "exit")) {
            break;
        }

        switch (parseCommand(message)) {
            .Get => {
                wlen = try createGetReq(message[3..], &wbuf);
            },
            .Set => {
                wlen = try createSetReq(message[3..], &wbuf);
            },
            .Delete => {
                wlen = try createDelReq(message[3..], &wbuf);
            },
            .List => {
                wlen = try createListReq(message[3..], &wbuf);
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

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const response = try protocol.decodeResponse(arena.allocator(), rbuf[0..len]);

        std.log.info("Received from server '{any}'", .{response});
        try handleResponse(response);
    }
}

fn parseCommand(buf: []const u8) Command {
    if (buf.len < 3) return Command.Unknown;

    if (commandIs(buf[0..3], Command.GET_LITERAL)) return Command.Get;
    if (commandIs(buf[0..3], Command.SET_LITERAL)) return Command.Set;
    if (commandIs(buf[0..3], Command.DELETE_LITERAL)) return Command.Delete;
    if (commandIs(buf[0..3], Command.LIST_LITERAL)) return Command.List;

    return Command.Unknown;
}

fn commandIs(buf: []const u8, command: []const u8) bool {
    return std.mem.eql(u8, buf, command);
}

fn readWord(buf: []const u8) !struct { u16, usize } {
    std.log.debug("Read word from buf '{s}'", .{buf});

    if (buf.len == 0) {
        return .{ 0, 0 };
    }

    var start: usize = 0;
    // Consume all leading whitespace
    for (0..buf.len) |i| {
        std.log.debug("buf[{1d}] '{0c}' ({0x})", .{ buf[i], i });
        if (buf[i] != ' ') {
            start = @intCast(i);
            break;
        }
    }
    // What if that loop gets all the way to the end of the buffer?
    var end: usize = start;
    for (start..buf.len) |i| {
        std.log.debug("buf[{1d}] '{0c}' ({0x})", .{ buf[i], i });
        end = i;
        if (buf[i] == ' ' or buf[i] == '\n') {
            end -= 1;
            break;
        }

        if (i - start > 2 ^ 16 - 1) return error.WordTooLong;
    }

    return .{ @intCast(start), end + 1 };
}

fn parseWord(buf: []const u8, out_buf: []u8) !struct { usize, usize } {
    const start, const end = try readWord(buf);

    std.log.debug(
        "'{s}' start = {d}, end = {d}, buf.len = {d}",
        .{ buf[start..end], start, end, buf.len },
    );
    var encoder = Encoder{ .buf = out_buf };
    const total_written = try encoder.encodeString(
        .{ .content = buf[start..end] },
    );
    return .{ total_written, end };
}

pub fn createGetReq(message: []const u8, wbuf: []u8) !usize {
    const out_buf = wbuf[len_header_size..];
    var m_len: usize = 0;
    m_len += try encodeCommand(Command.Get, out_buf);

    // Parse the key back into the input buffer
    const key_len, _ = try parseWord(message, out_buf[m_len..]);
    m_len += key_len;
    std.log.debug("Key length {}", .{key_len});

    m_len += try encodeHeader(m_len, wbuf);
    return m_len;
}

pub fn createSetReq(message: []const u8, wbuf: []u8) !usize {
    const out_buf = wbuf[len_header_size..];
    var m_len: usize = 0;
    m_len += try encodeCommand(Command.Set, out_buf);

    const key_len, const bytes_read = try parseWord(message, out_buf[m_len..]);
    m_len += key_len;
    std.log.debug("Key length {}", .{key_len});
    std.log.debug("Bytes read {}", .{bytes_read});

    const val_len, _ = try parseWord(message[bytes_read..], out_buf[m_len..]);
    m_len += val_len;
    std.log.debug("Val length {}", .{val_len});

    m_len += try encodeHeader(m_len, wbuf);
    return m_len;
}

pub fn createDelReq(message: []const u8, wbuf: []u8) !usize {
    const out_buf = wbuf[len_header_size..];
    var m_len: usize = 0;
    m_len += try encodeCommand(Command.Delete, out_buf);

    // Parse the key back into the input buffer
    const key_len, _ = try parseWord(message, out_buf[m_len..]);
    m_len += key_len;
    std.log.debug("Key length {}", .{key_len});

    m_len += try encodeHeader(m_len, wbuf);
    return m_len;
}

pub fn createListReq(message: []const u8, wbuf: []u8) !usize {
    _ = message;
    const out_buf = wbuf[len_header_size..];
    var m_len: usize = 0;
    m_len += try encodeCommand(Command.List, out_buf);
    m_len += try encodeHeader(m_len, wbuf);
    return m_len;
}

fn encodeCommand(command: Command, buf: []u8) !usize {
    var encoder = Encoder{ .buf = buf };
    return try encoder.encodeCommand(command);
}
