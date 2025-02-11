const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const serialization = @import("serialization.zig");

const Command = types.Command;
const Encoder = serialization.Encoder;

const encodeGenericInteger = serialization.encodeGenericInteger;

const native_endian = builtin.cpu.arch.endian();

pub const k_max_msg: usize = 4096;

pub const MessageLen = u32;
pub const len_header_size: u8 = @sizeOf(MessageLen);

pub const StringLen = u16;
pub const STR_LEN_BYTES = @sizeOf(StringLen);

pub const PayloadCreationError = error{MessageTooLong};

pub const MessageBuffer = [len_header_size + k_max_msg]u8;

pub const EncodeError = error{BufferTooSmall};
pub const DecodeError = error{InvalidString};

pub fn createPayload(message: []const u8, buf: []u8) PayloadCreationError!usize {
    const len = message.len;

    if (len > k_max_msg) {
        return PayloadCreationError.MessageTooLong;
    }

    const header_size = writeHeader(@intCast(len), buf) catch {
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
    const key = try decodeString(buf);
    const value: ?types.String = decodeString(buf[STR_LEN_BYTES + key.content.len ..]) catch |err| blk: {
        switch (err) {
            DecodeError.InvalidString => break :blk null,
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
    const key = try decodeString(buf);
    const value = try decodeString(buf[STR_LEN_BYTES + key.content.len ..]);
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
    const key = try decodeString(buf);
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

    var read: usize = 0;
    while (read < buf.len) {
        const key = try decodeString(buf[read..]);
        read += STR_LEN_BYTES + key.content.len;
        const value = try decodeString(buf[read..]);
        read += STR_LEN_BYTES + value.content.len;

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

fn commandIs(buf: []const u8, command: []const u8) bool {
    return std.mem.eql(u8, buf, command);
}

pub fn parseCommand(buf: []const u8) Command {
    if (buf.len < 3) return Command.Unknown;

    if (commandIs(buf[0..3], Command.GET_LITERAL)) return Command.Get;
    if (commandIs(buf[0..3], Command.SET_LITERAL)) return Command.Set;
    if (commandIs(buf[0..3], Command.DELETE_LITERAL)) return Command.Delete;
    if (commandIs(buf[0..3], Command.LIST_LITERAL)) return Command.List;

    return Command.Unknown;
}

pub fn decodeCommand(buf: []const u8) !Command {
    return try std.meta.intToEnum(Command, buf[0]);
}

/// Parses the given buffer by assuming the first two bytes are the
/// length of the string as a u16, then reads the next 'length' bytes
/// from the buffer
pub fn decodeString(buf: []const u8) DecodeError!types.String {
    if (buf.len < 2) {
        return DecodeError.InvalidString;
    }

    const str_len = std.mem.readPackedInt(
        StringLen,
        buf[0..2],
        0,
        native_endian,
    );

    if (buf.len < STR_LEN_BYTES + str_len) {
        return DecodeError.InvalidString;
    }

    return types.String{ .content = buf[2..][0..str_len] };
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

    m_len += try writeHeader(m_len, wbuf);
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

    m_len += try writeHeader(m_len, wbuf);
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

    m_len += try writeHeader(m_len, wbuf);
    return m_len;
}

pub fn createListReq(message: []const u8, wbuf: []u8) !usize {
    _ = message;
    const out_buf = wbuf[len_header_size..];
    var m_len: usize = 0;
    m_len += try encodeCommand(Command.List, out_buf);
    m_len += try writeHeader(m_len, wbuf);
    return m_len;
}

fn encodeCommand(command: Command, buf: []u8) !usize {
    var encoder = Encoder{ .buf = buf };
    return try encoder.encodeCommand(command);
}

fn writeHeader(message_len: usize, buf: []u8) serialization.EncodeError!usize {
    return try encodeGenericInteger(MessageLen, @intCast(message_len), buf);
}
