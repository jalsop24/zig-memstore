const std = @import("std");
const builtin = @import("builtin");
const native_endian = builtin.cpu.arch.endian();

pub const MessageLen = u32;
pub const len_header_size: u8 = @sizeOf(MessageLen);
pub const k_max_msg: usize = 4096;

pub const PayloadCreationError = error{MessageTooLong};

pub const Command = enum {
    Get,
    Set,
    Delete,
    Unknown,
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

fn commandIs(buf: []const u8, command: []const u8) bool {
    return std.mem.eql(u8, buf, command);
}

pub fn parseCommand(buf: []const u8) Command {
    if (buf.len < 3) return Command.Unknown;

    if (commandIs(buf[0..3], "get")) return Command.Get;
    if (commandIs(buf[0..3], "set")) return Command.Set;
    if (commandIs(buf[0..3], "del")) return Command.Delete;

    return Command.Unknown;
}

/// Parses the given buffer by assuming the first two bytes are the
/// length of the string as a u16, then reads the next 'length' bytes
/// from the buffer
pub fn parseString(buf: []const u8) error{InvalidString}![]const u8 {
    if (buf.len < 2) {
        return error.InvalidString;
    }

    const str_len = std.mem.readPackedInt(
        u16,
        buf[0..2],
        0,
        native_endian,
    );

    if (buf.len - 2 < str_len) {
        return error.InvalidString;
    }

    return buf[2 .. 2 + str_len];
}

fn readWord(buf: []const u8, out_buf: []u8) !struct { u16, u32 } {
    std.log.debug("Read word from buf '{s}'", .{buf});

    var start: u32 = 0;
    // Consume all leading whitespace
    for (0..buf.len) |i| {
        if (buf[i] != ' ') {
            start = @intCast(i);
            break;
        }
    }
    // What if that loop gets all the way to the end of the buffer?
    var end: u32 = 0;
    for (start..buf.len) |i| {
        std.log.debug("char {c}", .{buf[i]});
        end = @intCast(i);
        if (buf[i] == ' ' or buf[i] == '\n') {
            end -= 1;
            break;
        }

        if (i - start > out_buf.len or i - start > 2 ^ 16 - 1) return error.WordTooLong;

        // Copy key char into output buffer
        out_buf[i - start] = buf[i];
    }

    return .{ @intCast(end + 1 - start), end + 1 };
}

fn parseWord(buf: []const u8, out_buf: []u8) !struct { u16, u32 } {
    const w_len, const bytes_read = try readWord(buf, out_buf[2..]);

    std.mem.writePackedInt(
        u16,
        out_buf[0..2],
        0,
        w_len,
        native_endian,
    );

    return .{ w_len, bytes_read };
}

pub fn createGetReq(message: []const u8, wbuf: []u8) !MessageLen {
    const out_buf = wbuf[len_header_size..];

    @memcpy(out_buf[0..3], "get");

    // Parse the key back into the input buffer
    const key_len, _ = try parseWord(message, out_buf[3..]);
    std.log.info("Key length {}", .{key_len});

    // 3 Bytes for command
    // 2 bytes for key length
    // key_len bytes for key content
    const m_len: MessageLen = 3 + 2 + key_len;

    // Write 4 byte total message length header
    std.mem.writePackedInt(
        MessageLen,
        wbuf[0..len_header_size],
        0,
        m_len,
        native_endian,
    );
    return len_header_size + m_len;
}

pub fn createSetReq(message: []const u8, wbuf: []u8) !MessageLen {
    const out_buf = wbuf[len_header_size..];
    @memcpy(out_buf[0..3], "set");

    const key_len, const bytes_read = try parseWord(message, out_buf[3..]);
    std.log.info("Key length {}", .{key_len});
    std.log.info("Bytes read {}", .{bytes_read});

    // Parse value into out_buffer at 5 + key_len position:
    // 3 bytes for "set"
    // 2 bytes for key_len
    // key_len bytes for key
    const val_len, _ = try parseWord(message[bytes_read..], out_buf[5 + key_len ..]);
    std.log.info("Val length {}", .{val_len});

    // 3 Bytes for command
    // 2 bytes for key length
    // key_len bytes for key content
    // 2 bytes for val length
    // val_len bytes for val content
    const m_len: MessageLen = 3 + 2 + key_len + 2 + val_len;

    // Write len_header_size byte total message length header
    std.mem.writePackedInt(
        MessageLen,
        wbuf[0..len_header_size],
        0,
        m_len,
        native_endian,
    );
    return len_header_size + m_len;
}

pub fn createDelReq(message: []const u8, wbuf: []u8) !MessageLen {
    const out_buf = wbuf[len_header_size..];
    @memcpy(out_buf[0..3], "del");

    // Parse the key back into the input buffer
    const key_len, _ = try parseWord(message, out_buf[3..]);
    std.log.info("Key length {}", .{key_len});

    // 3 Bytes for command
    // 2 bytes for key length
    // key_len bytes for key content
    const m_len: MessageLen = 3 + 2 + key_len;

    // Write len_header_size byte total message length header
    std.mem.writePackedInt(
        MessageLen,
        wbuf[0..len_header_size],
        0,
        m_len,
        native_endian,
    );
    return len_header_size + m_len;
}
