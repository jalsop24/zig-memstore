const std = @import("std");

const connection = @import("connection.zig");
const types = @import("types.zig");
const protocol = @import("protocol.zig");
const parseRequest = @import("request_handlers.zig").parseRequest;

const GenericConn = connection.GenericConn;
const MainMapping = types.MainMapping;

pub fn connectionIo(conn: GenericConn, main_mapping: *MainMapping) !void {
    switch (conn.state.state) {
        .REQ => stateReq(conn, main_mapping),
        .RES => stateRes(conn),
        .END => return error.InvalidConnection,
    }
}

fn stateRes(conn: GenericConn) void {
    while (tryFlushBuffer(conn)) {}
}

fn tryFlushBuffer(conn: GenericConn) bool {
    std.log.debug("Try flush buffer\n", .{});
    var conn_state = conn.state;

    _ = conn.write(conn_state.written_slice()) catch |err|
        switch (err) {
        error.WouldBlock => return false,
        else => {
            std.log.debug("write error {s}", .{@errorName(err)});
            conn_state.state = .END;
            return false;
        },
    };

    conn_state.state = .REQ;
    conn_state.wbuf_sent = 0;
    conn_state.wbuf_size = 0;
    return false;
}

fn stateReq(conn: GenericConn, main_mapping: *MainMapping) void {
    while (tryFillBuffer(conn, main_mapping)) {}
}

fn tryFillBuffer(conn: GenericConn, main_mapping: *MainMapping) bool {
    // Reset buffer so that it is filled right from the start
    std.debug.print("Try fill buffer\n", .{});

    var conn_state = conn.state;
    std.mem.copyForwards(
        u8,
        conn_state.rbuf[0..conn_state.rbuf_size],
        conn_state.rbuf[conn_state.rbuf_cursor..][0..conn_state.rbuf_size],
    );
    conn_state.rbuf_cursor = 0;

    std.debug.print("Read connection\n", .{});
    const num_read = conn.read(conn_state.rbuf[conn_state.rbuf_size..]) catch |err|
        switch (err) {
        // WouldBlock corresponds to EAGAIN signal
        error.WouldBlock => return false,
        else => {
            std.log.debug("read error {s}", .{@errorName(err)});
            conn_state.state = .END;
            return false;
        },
    };

    if (num_read == 0) {
        if (conn_state.rbuf_size > 0) {
            std.log.debug("Unexpected EOF", .{});
        } else {
            std.log.debug("EOF", .{});
        }
        conn_state.state = .END;
        return false;
    }

    conn_state.rbuf_size += num_read;
    std.debug.assert(conn_state.rbuf_size < conn_state.rbuf.len);

    // Parse multiple requests as more than one may be sent at a time
    while (tryOneRequest(conn, main_mapping)) {}
    return (conn_state.state == .REQ);
}

fn tryOneRequest(conn: GenericConn, main_mapping: *MainMapping) bool {
    var conn_state = conn.state;
    if (conn_state.rbuf_size < protocol.len_header_size) {
        // Not enough data in the buffer, try after the next poll
        return false;
    }

    const length_header = conn_state.rbuf[conn_state.rbuf_cursor..][0..protocol.len_header_size];
    const len = std.mem.readPackedInt(
        u32,
        length_header,
        0,
        .little,
    );

    if (len > protocol.k_max_msg) {
        std.log.debug("Too long - len = {}", .{len});
        std.log.debug("Message: {x}", .{length_header});
        conn_state.state = .END;
        return false;
    }

    if (conn_state.rbuf_size < protocol.len_header_size + len) {
        // Not enough data in the buffer
        return false;
    }

    const message = conn_state.rbuf[conn_state.rbuf_cursor + protocol.len_header_size ..][0..len];
    parseRequest(conn_state, message, main_mapping);

    // 'Remove' request from read buffer
    const remaining_bytes = conn_state.rbuf_size - protocol.len_header_size - len;
    conn_state.rbuf_size = remaining_bytes;
    // Update read cursor position
    conn_state.rbuf_cursor = conn_state.rbuf_cursor + protocol.len_header_size + len;

    // Trigger response logic
    conn_state.state = .RES;
    stateRes(conn);

    return (conn_state.state == .REQ);
}
