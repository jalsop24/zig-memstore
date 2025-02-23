const std = @import("std");

const connection = @import("connection.zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");

const ConnState = connection.ConnState;
const Mapping = types.Mapping;

const HandleRequestError = error{InvalidRequest} || protocol.PayloadCreationError;

const EncodeError = protocol.EncodeError;
const Response = protocol.Response;

pub fn parseRequest(conn_state: *ConnState, buf: []u8, mapping: *Mapping) void {
    const request = protocol.decodeRequest(buf) catch {
        writeResponse(conn_state, "Unable to decode request") catch unreachable;
        return;
    };

    handleRequest(conn_state, request, mapping) catch |err| switch (err) {
        HandleRequestError.MessageTooLong => {
            writeResponse(conn_state, "Response too large") catch unreachable;
        },
        HandleRequestError.InvalidRequest => {
            writeResponse(conn_state, "Invalid request") catch unreachable;
        },
    };
}

fn handleRequest(conn_state: *ConnState, request: protocol.Request, mapping: *Mapping) HandleRequestError!void {
    var response: Response = undefined;
    switch (request) {
        .Get => |get_req| handleGetCommand(get_req, mapping, &response),
        .Set => |set_req| try handleSetCommand(set_req, mapping, &response),
        .Delete => |del_req| handleDeleteCommand(del_req, mapping, &response),
        .List => |list_req| handleListCommand(list_req, mapping, &response),
        .Unknown => |unknown_req| handleUnknownCommand(unknown_req, &response),
    }

    var response_buf: protocol.MessageBuffer = undefined;
    const written = protocol.encodeResponse(response, &response_buf) catch {
        return HandleRequestError.MessageTooLong;
    };
    try writeResponse(conn_state, response_buf[0..written]);
}

fn writeResponse(conn_state: *ConnState, response: []const u8) protocol.PayloadCreationError!void {
    conn_state.wbuf_size += try protocol.createPayload(response, conn_state.writeable_slice());
}

fn handleUnknownCommand(
    request: protocol.UnknownRequest,
    response: *Response,
) void {
    std.log.info("Client says '{s}'", .{request.content});

    response.* = Response{
        .Unknown = .{
            .content = request.content,
        },
    };
}

fn handleGetCommand(
    request: protocol.GetRequest,
    mapping: *Mapping,
    response: *Response,
) void {
    std.log.info("Get key '{s}'", .{request.key.content});
    const value = mapping.get(request.key);

    response.* = Response{
        .Get = .{
            .key = request.key,
            .value = value,
        },
    };
}

fn handleSetCommand(
    request: protocol.SetRequest,
    mapping: *Mapping,
    response: *Response,
) HandleRequestError!void {
    std.log.info("Key {s}", .{request.key.content});

    mapping.put(request.key, request.value) catch {
        std.log.debug("Failed to put into mapping {any}", .{request.value});
        return HandleRequestError.InvalidRequest;
    };

    response.* = Response{
        .Set = .{
            .key = request.key,
            .value = request.value,
        },
    };
}

fn handleDeleteCommand(
    request: protocol.DeleteRequest,
    mapping: *Mapping,
    response: *Response,
) void {
    mapping.remove(request.key);

    response.* = Response{
        .Delete = .{
            .key = request.key,
        },
    };
}

fn handleListCommand(
    request: protocol.ListRequest,
    mapping: *Mapping,
    response: *Response,
) void {
    // List request contains no actual data, always list everything in the map
    _ = request;

    response.* = Response{
        .List = .{
            .mapping = mapping,
            .len = mapping.get_size(),
        },
    };
}
