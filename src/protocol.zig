const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const serialization = @import("serialization.zig");

const Command = types.Command;

const Encoder = serialization.Encoder;
const Decoder = serialization.Decoder;

const encodeGenericInteger = serialization.encodeGenericInteger;

const native_endian = builtin.cpu.arch.endian();

pub const k_max_msg: usize = 4096;

pub const MessageLen = u32;
pub const len_header_size: u8 = @sizeOf(MessageLen);

pub const StringLen = u16;
pub const STR_LEN_BYTES = @sizeOf(StringLen);

pub const PayloadCreationError = error{MessageTooLong};

pub const MessageBuffer = [len_header_size + k_max_msg]u8;

pub const EncodeError = serialization.EncodeError;
pub const DecodeError = serialization.DecodeError;

pub fn createPayload(message: []const u8, buf: []u8) PayloadCreationError!usize {
    const len = message.len;

    if (len > k_max_msg) {
        return PayloadCreationError.MessageTooLong;
    }

    const header_size = encodeHeader(@intCast(len), buf) catch {
        return PayloadCreationError.MessageTooLong;
    };

    @memcpy(buf[header_size..][0..len], message);
    return @intCast(header_size + len);
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
        native_endian,
    );
    if (m_len > k_max_msg) {
        std.log.info("Invalid response {}", .{m_len});
        return error.InvalidResponse;
    }
    const m_read = try reader.read(buf[0..m_len]);
    return m_read;
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

const DeleteResponse = struct {
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

const ListResponse = struct {
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

pub fn decodeCommand(buf: []const u8) !Command {
    return try std.meta.intToEnum(Command, buf[0]);
}

/// Parses the given buffer by assuming the first two bytes are the
/// length of the string as a u16, then reads the next 'length' bytes
/// from the buffer
pub fn decodeString(buf: []const u8) DecodeError!types.String {
    if (buf.len < 2) {
        return DecodeError.BufferTooSmall;
    }

    const str_len = std.mem.readPackedInt(
        StringLen,
        buf[0..2],
        0,
        native_endian,
    );

    if (buf.len < STR_LEN_BYTES + str_len) {
        return DecodeError.BufferTooSmall;
    }

    return types.String{ .content = buf[2..][0..str_len] };
}

pub fn encodeHeader(message_len: usize, buf: []u8) EncodeError!usize {
    return try encodeGenericInteger(MessageLen, @intCast(message_len), buf);
}
