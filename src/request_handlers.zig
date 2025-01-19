const std = @import("std");

const connection = @import("connection.zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");

const ConnState = connection.ConnState;
const MainMapping = types.MainMapping;
const MessageBuffer = protocol.MessageBuffer;
const String = types.String;

const HandleRequestError = error{InvalidRequest} || protocol.PayloadCreationError;

const Command = protocol.Command;
const DecodeError = protocol.DecodeError;
const EncodeError = protocol.EncodeError;

pub fn parseRequest(conn_state: *ConnState, buf: []u8, main_mapping: *MainMapping) void {

    // Support get, set, del

    // first 3 bytes are the type of command
    if (buf.len < 3) return handleUnknownCommand(conn_state, buf);

    var err: ?HandleRequestError = null;
    switch (protocol.parseCommand(buf[0..3])) {
        .Get => handleGetCommand(conn_state, buf, main_mapping) catch |e| {
            err = e;
        },
        .Set => handleSetCommand(conn_state, buf, main_mapping) catch |e| {
            err = e;
        },
        .Delete => handleDeleteCommand(conn_state, buf, main_mapping) catch |e| {
            err = e;
        },
        .List => handleListCommand(conn_state, buf, main_mapping) catch |e| {
            err = e;
        },
        .Unknown => handleUnknownCommand(conn_state, buf),
    }

    if (err != null) {
        switch (err.?) {
            // Length check has already been completed
            error.MessageTooLong => unreachable,
            error.InvalidRequest => {
                writeResponse(conn_state, "Invalid request") catch unreachable;
            },
        }
    }
}

fn writeResponse(conn_state: *ConnState, response: []const u8) protocol.PayloadCreationError!void {
    conn_state.wbuf_size += try protocol.createPayload(response, conn_state.writeable_slice());
}

fn handleUnknownCommand(conn_state: *ConnState, bytes: []const u8) void {
    std.log.info("Client says '{s}'", .{bytes});
    // Generate echo response
    @memcpy(
        conn_state.wbuf[0 .. protocol.len_header_size + bytes.len],
        conn_state.rbuf[conn_state.rbuf_cursor..][0 .. protocol.len_header_size + bytes.len],
    );

    conn_state.wbuf_size = protocol.len_header_size + bytes.len;
}

fn handleGetCommand(conn_state: *ConnState, buf: []u8, main_mapping: *MainMapping) HandleRequestError!void {
    std.log.info("Get command '{0s}' ({0x})", .{buf});

    if (buf.len < 5) {
        std.log.debug("Invalid request - {s} (len = {})", .{ buf, buf.len });
        return HandleRequestError.InvalidRequest;
    }

    const key = protocol.decodeString(buf[3..]) catch |err| switch (err) {
        error.InvalidString => {
            std.log.debug("Failed to parse key {s}", .{buf[3..]});
            return HandleRequestError.InvalidRequest;
        },
    };

    std.log.info("Get key '{s}'", .{key.content});
    const raw_value = main_mapping.get(key.content);

    std.log.debug("content", .{});
    const value: []const u8 = if (raw_value) |str|
        str.content
    else
        @constCast(@ptrCast("null"));

    const response_format = "get {s} -> {s}";

    var response_buf: MessageBuffer = undefined;
    const response = std.fmt.bufPrint(&response_buf, response_format, .{ key.content, value }) catch |err|
        switch (err) {
        error.NoSpaceLeft => unreachable,
    };

    try writeResponse(conn_state, response);
}

fn handleSetCommand(conn_state: *ConnState, buf: []u8, main_mapping: *MainMapping) HandleRequestError!void {
    std.log.info("Set command '{0s}' ({0x})", .{buf});

    if (buf.len < 5) {
        std.log.debug("Invalid request - {s} (len = {})", .{ buf, buf.len });
        return HandleRequestError.InvalidRequest;
    }

    const key = protocol.decodeString(buf[3..]) catch |err| switch (err) {
        DecodeError.InvalidString => {
            std.log.debug("Failed to parse key {s}", .{buf[3..]});
            return HandleRequestError.InvalidRequest;
        },
    };
    std.log.info("Key {s}", .{key.content});

    const value_buf = buf[5 + key.content.len ..];
    const value = protocol.decodeString(value_buf) catch |err| switch (err) {
        DecodeError.InvalidString => {
            std.log.debug("Failed to parse value {s}", .{value_buf});
            return HandleRequestError.InvalidRequest;
        },
    };

    const new_key = main_mapping.allocator.alloc(u8, key.content.len) catch return HandleRequestError.InvalidRequest;
    errdefer main_mapping.allocator.free(new_key);
    @memcpy(new_key, key.content);

    const new_val = String.init(main_mapping.allocator, value.content) catch |err| switch (err) {
        error.OutOfMemory => return HandleRequestError.InvalidRequest,
    };
    errdefer new_val.deinit(main_mapping.allocator);

    main_mapping.put(new_key, new_val) catch {
        std.log.debug("Failed to put into mapping {any}", .{new_val});
        return HandleRequestError.InvalidRequest;
    };

    const response = "created";
    writeResponse(conn_state, response) catch unreachable;
}

fn handleDeleteCommand(conn_state: *ConnState, buf: []const u8, main_mapping: *MainMapping) HandleRequestError!void {
    std.log.info("Delete command '{0s}' (0x)", .{buf});

    if (buf.len < 5) {
        std.log.debug("Invalid request - {s} (len = {})", .{ buf, buf.len });
        return HandleRequestError.InvalidRequest;
    }

    const key = protocol.decodeString(buf[3..]) catch |err| switch (err) {
        DecodeError.InvalidString => return HandleRequestError.InvalidRequest,
    };

    _ = main_mapping.swapRemove(key.content);

    var response_buf: MessageBuffer = undefined;
    var response_len: protocol.MessageLen = 0;
    response_len += protocol.encodeCommand(Command.Delete, response_buf[response_len..]);
    response_len += protocol.encodeString(key, response_buf[response_len..]) catch |err| switch (err) {
        EncodeError.String => return HandleRequestError.InvalidRequest,
    };

    try writeResponse(conn_state, response_buf[0..response_len]);
}

fn handleListCommand(conn_state: *ConnState, buf: []const u8, main_mapping: *MainMapping) HandleRequestError!void {
    std.log.info("List command '{0s}' (0x)", .{buf});

    const keys = main_mapping.keys();

    std.debug.print("total keys {d}\n", .{keys.len});

    if (keys.len == 0) {
        try writeResponse(conn_state, "no keys");
        return;
    }

    var response_buf: [1_000]u8 = undefined;
    var cursor: usize = 0;

    for (main_mapping.keys()) |key| {
        std.debug.print("key: {s}\n", .{key});
        const value = main_mapping.get(key).?;
        const slice = std.fmt.bufPrint(response_buf[cursor..], "{s} = {s},", .{ key, value.content }) catch |err|
            switch (err) {
            error.NoSpaceLeft => return HandleRequestError.MessageTooLong,
        };
        cursor += slice.len;
    }

    try writeResponse(conn_state, response_buf[0..cursor]);
}
