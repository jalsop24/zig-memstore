const std = @import("std");

pub const k_max_msg: usize = 4096;

pub fn createPayload(message: []const u8, buf: []u8) !u32 {
    if (message.len > k_max_msg) {
        return error.MessageTooLong;
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

pub fn sendMessage(stream: *const std.net.Stream, message: []const u8) !void {
    var w_buf: [4 + k_max_msg]u8 = undefined;
    const m_size = try createPayload(message, &w_buf);
    const payload = w_buf[0..m_size];

    _ = try stream.write(payload);
}
