const std = @import("std");

const types = @import("types.zig");
const serialization = @import("serialization.zig");
const requests = @import("requests.zig");

const Command = types.Command;

const Encoder = serialization.Encoder;
const Decoder = serialization.Decoder;

pub const ENDIAN = serialization.ENDIAN;

pub const k_max_msg: usize = 4096;

pub const MessageLen = serialization.MessageLen;
pub const len_header_size: u8 = @sizeOf(MessageLen);

pub const PayloadCreationError = error{MessageTooLong};

pub const MessageBuffer = [len_header_size + k_max_msg]u8;

pub const EncodeError = serialization.EncodeError;
pub const DecodeError = serialization.DecodeError;

pub const decodeRequest = requests.decodeRequest;
pub const encodeRequest = requests.encodeRequest;
pub const Request = requests.Request;

pub const GetRequest = requests.GetRequest;
pub const SetRequest = requests.SetRequest;
pub const DeleteRequest = requests.DeleteRequest;
pub const ListRequest = requests.ListRequest;
pub const UnknownRequest = requests.UnknownRequest;

pub const Response = union(Command) {
    Get: GetResponse,
    Set: SetResponse,
    Delete: DeleteResponse,
    List: ListResponse,
    Unknown: UnknownResponse,
};

pub fn createPayload(message: []const u8, buf: []u8) PayloadCreationError!usize {
    const len = message.len;

    if (len > k_max_msg) {
        return PayloadCreationError.MessageTooLong;
    }

    var encoder = Encoder{ .buf = buf };
    _ = encoder.encodeGenericInteger(MessageLen, @intCast(len)) catch {
        return PayloadCreationError.MessageTooLong;
    };
    _ = encoder.encodeBytes(message) catch {
        return PayloadCreationError.MessageTooLong;
    };

    return encoder.written;
}

pub fn receiveMessage(reader: std.io.AnyReader, buf: []u8) !usize {
    const m_header = buf[0..len_header_size];
    const bytes_read = try reader.read(m_header);
    if (bytes_read < len_header_size) {
        std.log.info("Unable to read full header. {} bytes", .{bytes_read});
        return error.MessageTooShort;
    }
    const m_len = std.mem.readPackedInt(
        MessageLen,
        m_header,
        0,
        ENDIAN,
    );
    if (m_len > k_max_msg) {
        std.log.info("Invalid response {}", .{m_len});
        return error.InvalidResponse;
    }
    const m_read = try reader.read(buf[0..m_len]);
    return m_read;
}

pub fn decodeResponse(allocator: std.mem.Allocator, buf: []const u8) DecodeError!Response {
    var decoder = Decoder{ .allocator = undefined, .buf = buf };
    const command = try decoder.decodeCommand();

    switch (command) {
        .Get => return Response{ .Get = try decodeGetResponse(decoder.r_buf()) },
        .Set => return Response{ .Set = try decodeSetResponse(decoder.r_buf()) },
        .Delete => return Response{ .Delete = try decodeDeleteResponse(decoder.r_buf()) },
        .List => return Response{ .List = try decodeListResponse(decoder.r_buf(), allocator) },
        .Unknown => return Response{ .Unknown = try decodeUnknownResponse(decoder.r_buf()) },
    }
}

pub const GetResponse = struct {
    key: types.String,
    value: ?types.String,
};

pub fn decodeGetResponse(buf: []const u8) !GetResponse {
    var decoder = Decoder{
        .allocator = undefined,
        .buf = buf,
    };
    const key = try decoder.decodeString();
    const value: ?types.String = decoder.decodeString() catch |err| blk: {
        switch (err) {
            // Expect the raw response buffer to be too small in the case where there is no value returned
            // In the future this should be replaced with decodeObject and using the Nil object to signal
            // no value
            DecodeError.BufferTooSmall => break :blk null,
            else => return err,
        }
    };
    return .{
        .key = key,
        .value = value,
    };
}

pub fn encodeGetResponse(get_response: GetResponse, buf: []u8) EncodeError!usize {
    var encoder = Encoder{ .buf = buf };

    _ = try encoder.encodeCommand(Command.Get);
    _ = try encoder.encodeString(get_response.key);
    if (get_response.value) |value_string| {
        _ = try encoder.encodeString(value_string);
    }
    return encoder.written;
}

pub const SetResponse = struct {
    key: types.String,
    value: types.String,
};

pub fn decodeSetResponse(buf: []const u8) !SetResponse {
    var decoder = Decoder{ .allocator = undefined, .buf = buf };
    const key = try decoder.decodeString();
    const value = try decoder.decodeString();
    return .{
        .key = key,
        .value = value,
    };
}

pub fn encodeSetResponse(set_response: SetResponse, buf: []u8) EncodeError!usize {
    var encoder = Encoder{ .buf = buf };
    _ = try encoder.encodeCommand(Command.Set);
    _ = try encoder.encodeString(set_response.key);
    _ = try encoder.encodeString(set_response.value);

    return encoder.written;
}

pub const DeleteResponse = struct {
    key: types.String,
};

pub fn decodeDeleteResponse(buf: []const u8) !DeleteResponse {
    var decoder = Decoder{ .allocator = undefined, .buf = buf };
    const key = try decoder.decodeString();
    return .{ .key = key };
}

pub fn encodeDeleteResponse(delete_response: DeleteResponse, buf: []u8) EncodeError!usize {
    var encoder = Encoder{ .buf = buf };
    _ = try encoder.encodeCommand(Command.Delete);
    _ = try encoder.encodeString(delete_response.key);
    return encoder.written;
}

pub const ListResponse = struct {
    len: usize = 0,
    mapping: *types.Mapping,

    pub fn iterator(self: *const ListResponse) types.Mapping.Iterator {
        return self.mapping.iterator();
    }
};

pub fn decodeListResponse(buf: []const u8, allocator: std.mem.Allocator) !ListResponse {
    var mapping = try types.Mapping.init(allocator);
    var decoder = Decoder{ .allocator = undefined, .buf = buf };

    while (decoder.read < buf.len) {
        const key = try decoder.decodeString();
        const value = try decoder.decodeString();

        mapping.put(key, value) catch |err| switch (err) {
            error.OutOfMemory => {
                std.log.debug("More kv pairs available", .{});
                break;
            },
        };
    }

    return .{
        .mapping = mapping,
        .len = mapping.get_size(),
    };
}

pub fn encodeListReponse(list_response: ListResponse, buf: []u8) EncodeError!usize {
    var encoder = Encoder{ .buf = buf };

    _ = try encoder.encodeCommand(Command.List);

    var iterator = list_response.iterator();
    while (iterator.next()) |kv_pair| {
        std.log.debug("key: {s}", .{kv_pair.key.content});
        _ = try encoder.encodeString(kv_pair.key);
        _ = try encoder.encodeString(kv_pair.value);
    }

    return encoder.written;
}

pub const UnknownResponse = struct {
    content: []const u8,
};

pub fn decodeUnknownResponse(buf: []const u8) DecodeError!UnknownResponse {
    return .{ .content = buf };
}

pub fn encodeUnknownResponse(unknown_response: UnknownResponse, buf: []u8) usize {
    @memcpy(buf[0..unknown_response.content.len], unknown_response.content);
    return unknown_response.content.len;
}

pub fn encodeHeader(message_len: usize, buf: []u8) EncodeError!usize {
    var encoder = Encoder{ .buf = buf };
    return try encoder.encodeGenericInteger(MessageLen, @intCast(message_len));
}
