const std = @import("std");

const connection = @import("connection.zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");

const ConnState = connection.ConnState;
const Mapping = types.Mapping;
const MessageBuffer = protocol.MessageBuffer;
const String = types.String;

const HandleRequestError = error{InvalidRequest} || protocol.PayloadCreationError;

const Command = types.Command;
const COMMAND_LEN_BYTES = types.COMMAND_LEN_BYTES;

const EncodeError = protocol.EncodeError;

pub fn parseRequest(conn_state: *ConnState, buf: []u8, mapping: *Mapping) void {
    const request = protocol.decodeRequest(buf) catch {
        writeResponse(conn_state, "Unable to decode request") catch unreachable;
        return;
    };

    handleRequest(conn_state, request, mapping) catch |err| switch (err) {
        // Length check has already been completed
        HandleRequestError.MessageTooLong => unreachable,
        HandleRequestError.InvalidRequest => {
            writeResponse(conn_state, "Invalid request") catch unreachable;
        },
    };
}

fn handleRequest(conn_state: *ConnState, request: protocol.Request, mapping: *Mapping) HandleRequestError!void {
    switch (request) {
        .Get => |get_req| try handleGetCommand(conn_state, get_req, mapping),
        .Set => |set_req| try handleSetCommand(conn_state, set_req, mapping),
        .Delete => |del_req| try handleDeleteCommand(conn_state, del_req, mapping),
        .List => |list_req| try handleListCommand(conn_state, list_req, mapping),
        .Unknown => |unknown_req| try handleUnknownCommand(conn_state, unknown_req),
    }
}

fn writeResponse(conn_state: *ConnState, response: []const u8) protocol.PayloadCreationError!void {
    conn_state.wbuf_size += try protocol.createPayload(response, conn_state.writeable_slice());
}

fn handleUnknownCommand(conn_state: *ConnState, request: protocol.UnknownRequest) HandleRequestError!void {
    std.log.info("Client says '{s}'", .{request.content});

    var response_buf: MessageBuffer = undefined;
    const written = protocol.encodeUnknownResponse(
        .{ .content = request.content },
        &response_buf,
    );

    try writeResponse(conn_state, response_buf[0..written]);
}

fn handleGetCommand(conn_state: *ConnState, request: protocol.GetRequest, mapping: *Mapping) HandleRequestError!void {
    std.log.info("Get key '{s}'", .{request.key.content});
    const value = mapping.get(request.key);

    var response_buf: MessageBuffer = undefined;
    const written = protocol.encodeGetResponse(.{
        .key = request.key,
        .value = value,
    }, &response_buf) catch |err| switch (err) {
        EncodeError.BufferTooSmall => return HandleRequestError.InvalidRequest,
    };

    try writeResponse(conn_state, response_buf[0..written]);
}

fn handleSetCommand(conn_state: *ConnState, request: protocol.SetRequest, mapping: *Mapping) HandleRequestError!void {
    std.log.info("Key {s}", .{request.key.content});

    mapping.put(request.key, request.value) catch {
        std.log.debug("Failed to put into mapping {any}", .{request.value});
        return HandleRequestError.InvalidRequest;
    };

    var response_buf: MessageBuffer = undefined;
    const written = protocol.encodeSetResponse(.{
        .key = request.key,
        .value = request.value,
    }, &response_buf) catch |err| switch (err) {
        EncodeError.BufferTooSmall => return HandleRequestError.InvalidRequest,
    };

    try writeResponse(conn_state, response_buf[0..written]);
}

fn handleDeleteCommand(conn_state: *ConnState, request: protocol.DeleteRequest, mapping: *Mapping) HandleRequestError!void {
    mapping.remove(request.key);

    var response_buf: MessageBuffer = undefined;
    const written = protocol.encodeDeleteResponse(.{
        .key = request.key,
    }, &response_buf) catch |err| switch (err) {
        EncodeError.BufferTooSmall => return HandleRequestError.InvalidRequest,
    };

    try writeResponse(conn_state, response_buf[0..written]);
}

fn handleListCommand(conn_state: *ConnState, request: protocol.ListRequest, mapping: *Mapping) HandleRequestError!void {
    // List request contains no actual data, always list everything in the map
    _ = request;
    var response_buf: MessageBuffer = undefined;
    const written = protocol.encodeListReponse(
        .{
            .mapping = mapping,
            .len = mapping.get_size(),
        },
        &response_buf,
    ) catch |err| switch (err) {
        EncodeError.BufferTooSmall => return HandleRequestError.InvalidRequest,
    };

    try writeResponse(conn_state, response_buf[0..written]);
}
