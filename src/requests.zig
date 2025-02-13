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

pub const GetRequest = struct {
    key: types.String,
};

fn decodeGetRequest(decoder: *Decoder) DecodeError!GetRequest {
    const key = try decoder.decodeString();
    return .{ .key = key };
}

fn encodeGetRequest(get_request: GetRequest, buf: []u8) EncodeError!usize {
    var encoder = Encoder{ .buf = buf };
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

fn encodeSetRequest(set_request: SetRequest, buf: []u8) EncodeError!usize {
    var encoder = Encoder{ .buf = buf };
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

pub const ListRequest = struct {};

fn decodeListRequest() ListRequest {
    return .{};
}

pub const UnknownRequest = struct {
    content: []const u8,
};

pub fn decodeUnknownRequest(decoder: *Decoder) DecodeError!UnknownRequest {
    return .{ .content = decoder.r_buf() };
}

pub fn encodeUnknownRequest(unknown_request: UnknownRequest, buf: []u8) EncodeError!usize {
    @memcpy(buf[0..unknown_request.content.len], unknown_request.content);
    return unknown_request.content.len;
}
