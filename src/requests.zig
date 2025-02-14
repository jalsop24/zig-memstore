const std = @import("std");

const types = @import("types.zig");
const serialization = @import("serialization.zig");

const Command = types.Command;

const Encoder = serialization.Encoder;
const Decoder = serialization.Decoder;

const EncodeError = serialization.EncodeError;
const DecodeError = serialization.DecodeError;

pub const Request = union(Command) {
    Get: GetRequest,
    Set: SetRequest,
    Delete: DeleteRequest,
    List: ListRequest,
    Unknown: UnknownRequest,
};

pub fn decodeRequest(buf: []const u8) DecodeError!Request {
    var decoder = Decoder{ .allocator = undefined, .buf = buf };
    const command = decoder.decodeCommand() catch |err| switch (err) {
        DecodeError.InvalidType => return Request{ .Unknown = .{ .content = buf } },
        else => return err,
    };

    switch (command) {
        .Get => return Request{ .Get = try decodeGetRequest(&decoder) },
        .Set => return Request{ .Set = try decodeSetRequest(&decoder) },
        .Delete => return Request{ .Delete = try decodeDelete(&decoder) },
        .List => return Request{ .List = decodeListRequest() },
        .Unknown => return Request{ .Unknown = try decodeUnknownRequest(&decoder) },
    }
}

pub fn encodeRequest(request: Request, buf: []u8) EncodeError!usize {
    var encoder = Encoder{ .buf = buf };
    _ = try encoder.encodeTag(Request, request);

    switch (request) {
        .Get => |get_req| _ = try encodeGetRequest(get_req, &encoder),
        .Set => |set_req| _ = try encodeSetRequest(set_req, &encoder),
        .Delete => |del_req| _ = try encodeDelete(del_req, &encoder),
        .List => encodeListRequest(),
        .Unknown => |unknown_req| _ = try encodeUnknownRequest(unknown_req, &encoder),
    }

    return encoder.written;
}

pub const GetRequest = struct {
    key: types.String,
};

fn decodeGetRequest(decoder: *Decoder) DecodeError!GetRequest {
    const key = try decoder.decodeString();
    return .{ .key = key };
}

fn encodeGetRequest(get_request: GetRequest, encoder: *Encoder) EncodeError!usize {
    _ = try encoder.encodeString(get_request.key);
    return encoder.written;
}

pub const SetRequest = struct {
    key: types.String,
    value: types.String,
};

fn decodeSetRequest(decoder: *Decoder) DecodeError!SetRequest {
    const key = try decoder.decodeString();
    const value = try decoder.decodeString();
    return .{
        .key = key,
        .value = value,
    };
}

fn encodeSetRequest(set_request: SetRequest, encoder: *Encoder) EncodeError!usize {
    _ = try encoder.encodeString(set_request.key);
    _ = try encoder.encodeString(set_request.value);
    return encoder.written;
}

pub const DeleteRequest = struct {
    key: types.String,
};

fn decodeDelete(decoder: *Decoder) DecodeError!DeleteRequest {
    const key = try decoder.decodeString();
    return .{ .key = key };
}

fn encodeDelete(delete_request: DeleteRequest, encoder: *Encoder) EncodeError!usize {
    _ = try encoder.encodeString(delete_request.key);
    return encoder.written;
}

pub const ListRequest = struct {};

fn decodeListRequest() ListRequest {
    return .{};
}

fn encodeListRequest() void {
    return;
}

pub const UnknownRequest = struct {
    content: []const u8,
};

pub fn decodeUnknownRequest(decoder: *Decoder) DecodeError!UnknownRequest {
    return .{ .content = decoder.r_buf() };
}

pub fn encodeUnknownRequest(unknown_request: UnknownRequest, encoder: *Encoder) EncodeError!usize {
    return encoder.encodeBytes(unknown_request.content);
}
