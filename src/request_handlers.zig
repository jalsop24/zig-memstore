const std = @import("std");

const connection = @import("connection.zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");

const ConnState = connection.ConnState;
const Mapping = types.Mapping;
const MessageBuffer = protocol.MessageBuffer;
const String = types.String;

const HandleRequestError = error{InvalidRequest} || protocol.PayloadCreationError;

const Command = protocol.Command;
const DecodeError = protocol.DecodeError;
const EncodeError = protocol.EncodeError;

pub fn parseRequest(conn_state: *ConnState, buf: []u8, mapping: *Mapping) void {
    parseRequestInner(conn_state, buf, mapping) catch |err| switch (err) {
        // Length check has already been completed
        HandleRequestError.MessageTooLong => unreachable,
        HandleRequestError.InvalidRequest => {
            writeResponse(conn_state, "Invalid request") catch unreachable;
        },
    };
}

fn parseRequestInner(conn_state: *ConnState, buf: []u8, mapping: *Mapping) HandleRequestError!void {

    // Support get, set, del

    if (buf.len < protocol.COMMAND_LEN_BYTES) return handleUnknownCommand(conn_state, buf);

    const command = protocol.decodeCommand(buf) catch return HandleRequestError.InvalidRequest;
    switch (command) {
        .Get => try handleGetCommand(conn_state, buf[protocol.COMMAND_LEN_BYTES..], mapping),
        .Set => try handleSetCommand(conn_state, buf[protocol.COMMAND_LEN_BYTES..], mapping),
        .Delete => try handleDeleteCommand(conn_state, buf[protocol.COMMAND_LEN_BYTES..], mapping),
        .List => try handleListCommand(conn_state, buf[protocol.COMMAND_LEN_BYTES..], mapping),
        .Unknown => handleUnknownCommand(conn_state, buf),
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

fn handleGetCommand(conn_state: *ConnState, buf: []u8, mapping: *Mapping) HandleRequestError!void {
    std.log.info("Get command '{0s}' ({0x})", .{buf});

    if (buf.len < protocol.STR_LEN_BYTES) {
        std.log.debug("Invalid request - {s} (len = {})", .{ buf, buf.len });
        return HandleRequestError.InvalidRequest;
    }

    const key = protocol.decodeString(buf) catch |err| switch (err) {
        DecodeError.InvalidString => {
            std.log.debug("Failed to parse key {s}", .{buf});
            return HandleRequestError.InvalidRequest;
        },
    };

    std.log.info("Get key '{s}'", .{key.content});
    const value = mapping.get(key);

    var response_buf: MessageBuffer = undefined;
    const written: protocol.MessageLen = protocol.encodeGetResponse(.{
        .key = key,
        .value = value,
    }, &response_buf) catch |err| switch (err) {
        EncodeError.BufferTooSmall => return HandleRequestError.InvalidRequest,
    };

    try writeResponse(conn_state, response_buf[0..written]);
}

fn handleSetCommand(conn_state: *ConnState, buf: []u8, mapping: *Mapping) HandleRequestError!void {
    std.log.info("Set command '{0s}' ({0x})", .{buf});

    if (buf.len < 2 * protocol.STR_LEN_BYTES) {
        std.log.debug("Invalid request - {s} (len = {})", .{ buf, buf.len });
        return HandleRequestError.InvalidRequest;
    }

    const key = protocol.decodeString(buf) catch |err| switch (err) {
        DecodeError.InvalidString => {
            std.log.debug("Failed to parse key {s}", .{buf});
            return HandleRequestError.InvalidRequest;
        },
    };
    std.log.info("Key {s}", .{key.content});

    const value_buf = buf[key.content.len + protocol.STR_LEN_BYTES ..];
    const value = protocol.decodeString(value_buf) catch |err| switch (err) {
        DecodeError.InvalidString => {
            std.log.debug("Failed to parse value {s}", .{value_buf});
            return HandleRequestError.InvalidRequest;
        },
    };

    mapping.put(key, value) catch {
        std.log.debug("Failed to put into mapping {any}", .{value});
        return HandleRequestError.InvalidRequest;
    };

    var response_buf: MessageBuffer = undefined;
    const written: protocol.MessageLen = protocol.encodeSetResponse(.{
        .key = key,
        .value = value,
    }, &response_buf) catch |err| switch (err) {
        EncodeError.BufferTooSmall => return HandleRequestError.InvalidRequest,
    };

    try writeResponse(conn_state, response_buf[0..written]);
}

fn handleDeleteCommand(conn_state: *ConnState, buf: []const u8, mapping: *Mapping) HandleRequestError!void {
    std.log.info("Delete command '{0s}' (0x)", .{buf});

    if (buf.len < protocol.STR_LEN_BYTES) {
        std.log.debug("Invalid request - {s} (len = {})", .{ buf, buf.len });
        return HandleRequestError.InvalidRequest;
    }

    const key = protocol.decodeString(buf) catch |err| switch (err) {
        DecodeError.InvalidString => return HandleRequestError.InvalidRequest,
    };

    mapping.remove(key);

    var response_buf: MessageBuffer = undefined;
    const written = protocol.encodeDeleteResponse(.{
        .key = key,
    }, &response_buf) catch |err| switch (err) {
        EncodeError.BufferTooSmall => return HandleRequestError.InvalidRequest,
    };

    try writeResponse(conn_state, response_buf[0..written]);
}

fn handleListCommand(conn_state: *ConnState, buf: []const u8, mapping: *Mapping) HandleRequestError!void {
    std.log.info("List command '{0s}' (0x)", .{buf});

    var response_buf: MessageBuffer = undefined;
    const written = protocol.encodeListReponse(
        .{
            .mapping = mapping,
            .len = mapping.size,
        },
        &response_buf,
    ) catch |err| switch (err) {
        EncodeError.BufferTooSmall => return HandleRequestError.InvalidRequest,
    };

    try writeResponse(conn_state, response_buf[0..written]);
}

fn encodeString(string: String, buf: []u8) HandleRequestError!protocol.StringLen {
    return protocol.encodeString(string, buf) catch |err| switch (err) {
        EncodeError.BufferTooSmall => return HandleRequestError.InvalidRequest,
    };
}
