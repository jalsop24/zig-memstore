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

pub fn receiveMessage(stream: *const std.net.Stream, m_buf: *[k_max_msg]u8) !usize {
    var r_buf: [4 + k_max_msg]u8 = undefined;

    const num_read = try stream.readAtLeast(&r_buf, 4);
    if (num_read < 4) {
        std.log.debug(
            "Failed to read full message length. Read {} bytes",
            .{num_read},
        );
        return error.EOF;
    }
    const len = std.mem.readPackedInt(
        u32,
        r_buf[0..4],
        0,
        .little,
    );

    if (len > k_max_msg) {
        std.log.debug("Len {}", .{len});
        std.log.debug("Message: {x}", .{r_buf[0..4]});
        return error.MessageTooLong;
    }

    if (num_read < 4 + len) {
        const num_left = 4 + len - num_read;
        const num_read_body = try stream.readAtLeast(r_buf[4..], num_left);
        if (num_read_body != len) {
            std.log.debug("Connection closed before reading full message - {s}", .{r_buf});
            return error.EOF;
        }
    }

    std.log.info("Received {} bytes", .{4 + len});
    @memcpy(m_buf[0..len], r_buf[4 .. 4 + len]);
    return len;
}
