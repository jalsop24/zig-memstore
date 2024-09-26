const std = @import("std");

pub const k_max_msg: usize = 4096;

pub const PayloadCreationError = error{MessageTooLong};

pub const Command = enum {
    Get,
    Set,
    Unknown,
};

pub fn createPayload(message: []const u8, buf: []u8) PayloadCreationError!u32 {
    if (message.len > k_max_msg) {
        return PayloadCreationError.MessageTooLong;
    }

    const len: u32 = @intCast(message.len);

    std.mem.writePackedInt(
        u32,
        buf,
        0,
        len,
        .little,
    );
    @memcpy(buf[4 .. 4 + len], message);
    return 4 + len;
}

fn commandIs(buf: []const u8, command: []const u8) bool {
    return std.mem.eql(u8, buf, command);
}

pub fn parseCommand(buf: []u8) Command {
    if (commandIs(buf, "get")) return Command.Get;
    if (commandIs(buf, "set")) return Command.Set;

    return Command.Unknown;
}

pub fn parseString(buf: []u8) error{InvalidString}![]u8 {
    if (buf.len < 2) {
        return error.InvalidString;
    }

    const key_len = std.mem.readPackedInt(
        u16,
        buf[0..2],
        0,
        .little,
    );

    if (buf.len - 2 < key_len) {
        return error.InvalidString;
    }

    return buf[2 .. 2 + key_len];
}
