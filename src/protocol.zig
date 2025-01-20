const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

const native_endian = builtin.cpu.arch.endian();

pub const MessageLen = u32;
pub const len_header_size: u8 = @sizeOf(MessageLen);
pub const k_max_msg: usize = 4096;

pub const StringLen = u16;
pub const STR_LEN_BYTES = @sizeOf(StringLen);

pub const CommandLen = u8;
pub const COMMAND_LEN_BYTES = @sizeOf(CommandLen);

pub const PayloadCreationError = error{MessageTooLong};

pub const MessageBuffer = [len_header_size + k_max_msg]u8;

pub const EncodeError = error{BufferTooSmall};
pub const DecodeError = error{InvalidString};

pub const Command = enum(CommandLen) {
    Get = 1,
    Set = 2,
    Delete = 3,
    List = 4,
    Unknown = 5,

    pub const GET_LITERAL = "get";
    pub const SET_LITERAL = "set";
    pub const DELETE_LITERAL = "del";
    pub const LIST_LITERAL = "lst";
};

pub fn createPayload(message: []const u8, buf: []u8) PayloadCreationError!MessageLen {
    if (message.len > k_max_msg) {
        return PayloadCreationError.MessageTooLong;
    }

    const len: MessageLen = @intCast(message.len);

    std.mem.writePackedInt(
        MessageLen,
        buf,
        0,
        len,
        native_endian,
    );
    @memcpy(buf[len_header_size..][0..len], message);
    return len_header_size + len;
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

pub fn parseGetResponse(buf: []const u8) !GetResponse {
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

pub const SetResponse = struct {
    key: types.String,
    value: types.String,
};

pub fn parseSetResponse(buf: []const u8) !SetResponse {
    const key = try decodeString(buf);
    const value = try decodeString(buf[STR_LEN_BYTES + key.content.len ..]);
    return .{
        .key = key,
        .value = value,
    };
}

const DeleteResponse = struct {
    key: types.String,
};

pub fn parseDeleteResponse(buf: []const u8) !DeleteResponse {
    const key = try decodeString(buf);
    return .{ .key = key };
}

pub const KeyValuePair = struct {
    key: types.String,
    value: types.String,
};
const ListResponse = struct {
    kv_pairs: []KeyValuePair,
};

pub fn parseListResponse(buf: []const u8, kv_pairs: []KeyValuePair) !ListResponse {
    const buffer_size = kv_pairs.len;
    var cursor: usize = 0;
    var read: usize = 0;

    while (read < buf.len) {
        const key = try decodeString(buf[read..]);
        read += STR_LEN_BYTES + key.content.len;
        const value = try decodeString(buf[read..]);
        read += STR_LEN_BYTES + value.content.len;

        if (cursor < buffer_size) {
            kv_pairs[cursor] = .{
                .key = key,
                .value = value,
            };
        }
        cursor += 1;
    }

    if (cursor > buffer_size) {
        std.log.debug("More kv pairs available: {d}", .{cursor - buffer_size});
        cursor = buffer_size;
    }

    return .{ .kv_pairs = kv_pairs[0..cursor] };
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

pub fn encodeCommand(command: Command, buf: []u8) u8 {
    std.mem.writePackedInt(
        u8,
        buf,
        0,
        @intFromEnum(command),
        native_endian,
    );
    return 1;
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

pub fn encodeString(string: types.String, buf: []u8) EncodeError!StringLen {
    const len: StringLen = @intCast(string.content.len);

    if (buf.len < STR_LEN_BYTES + len) {
        return EncodeError.BufferTooSmall;
    }

    std.mem.writePackedInt(
        StringLen,
        buf,
        0,
        len,
        native_endian,
    );
    @memcpy(buf[STR_LEN_BYTES..][0..len], string.content);
    return STR_LEN_BYTES + len;
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

fn parseWord(buf: []const u8, out_buf: []u8) !struct { StringLen, usize } {
    const start, const end = try readWord(buf);

    std.log.debug(
        "'{s}' start = {d}, end = {d}, buf.len = {d}",
        .{ buf[start..end], start, end, buf.len },
    );
    const total_written = try encodeString(
        .{ .content = buf[start..end] },
        out_buf,
    );
    return .{ total_written, end };
}

pub fn createGetReq(message: []const u8, wbuf: []u8) !MessageLen {
    const out_buf = wbuf[len_header_size..];
    var m_len: MessageLen = 0;
    m_len += encodeCommand(Command.Get, out_buf);

    // Parse the key back into the input buffer
    const key_len, _ = try parseWord(message, out_buf[m_len..]);
    m_len += key_len;
    std.log.debug("Key length {}", .{key_len});

    writeHeader(m_len, wbuf);
    return len_header_size + m_len;
}

pub fn createSetReq(message: []const u8, wbuf: []u8) !MessageLen {
    const out_buf = wbuf[len_header_size..];
    var m_len: MessageLen = 0;
    m_len += encodeCommand(Command.Set, out_buf);

    const key_len, const bytes_read = try parseWord(message, out_buf[m_len..]);
    m_len += key_len;
    std.log.debug("Key length {}", .{key_len});
    std.log.debug("Bytes read {}", .{bytes_read});

    const val_len, _ = try parseWord(message[bytes_read..], out_buf[m_len..]);
    m_len += val_len;
    std.log.debug("Val length {}", .{val_len});

    writeHeader(m_len, wbuf);
    return len_header_size + m_len;
}

pub fn createDelReq(message: []const u8, wbuf: []u8) !MessageLen {
    const out_buf = wbuf[len_header_size..];
    var m_len: MessageLen = 0;
    m_len += encodeCommand(Command.Delete, out_buf);

    // Parse the key back into the input buffer
    const key_len, _ = try parseWord(message, out_buf[m_len..]);
    m_len += key_len;
    std.log.debug("Key length {}", .{key_len});

    writeHeader(m_len, wbuf);
    return len_header_size + m_len;
}

pub fn createListReq(message: []const u8, wbuf: []u8) !MessageLen {
    _ = message;
    const out_buf = wbuf[len_header_size..];
    var m_len: MessageLen = 0;
    m_len += encodeCommand(Command.List, out_buf);

    // Write len_header_size byte total message length header
    writeHeader(m_len, wbuf);
    return len_header_size + m_len;
}

fn writeHeader(message_len: MessageLen, buf: []u8) void {
    std.mem.writePackedInt(
        MessageLen,
        buf[0..len_header_size],
        0,
        message_len,
        native_endian,
    );
}
