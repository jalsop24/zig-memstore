const std = @import("std");

const protocol = @import("protocol.zig");
const cli = @import("cli.zig");
const String = @import("types.zig").String;
const connection = @import("connection.zig");
const event_loop = @import("event_loop.zig");
const testing = @import("testing.zig");

const NetConn = @import("NetConn.zig");

const ConnState = connection.ConnState;
const GenericConn = connection.GenericConn;
const MessageBuffer = protocol.MessageBuffer;

const MainMapping = std.StringArrayHashMap(*String);

const ConnMapping = std.AutoArrayHashMap(std.posix.socket_t, *NetConn);

const HandleRequestError = error{InvalidRequest} || protocol.PayloadCreationError;

fn handleUnknownCommand(conn_state: *ConnState, bytes: []const u8) void {
    std.log.info("Client says '{s}'", .{bytes});
    // Generate echo response
    @memcpy(
        conn_state.wbuf[0 .. protocol.len_header_size + bytes.len],
        conn_state.rbuf[conn_state.rbuf_cursor..][0 .. protocol.len_header_size + bytes.len],
    );

    conn_state.wbuf_size = protocol.len_header_size + bytes.len;
}

fn handleGetCommand(conn_state: *ConnState, buf: []u8, main_mapping: *MainMapping) HandleRequestError!void {
    std.log.info("Get command '{0s}' ({0x})", .{buf});

    if (buf.len < 5) {
        std.log.debug("Invalid request - {s} (len = {})", .{ buf, buf.len });
        return HandleRequestError.InvalidRequest;
    }

    const key = protocol.parseString(buf[3..]) catch |err| switch (err) {
        error.InvalidString => {
            std.log.debug("Failed to parse key {s}", .{buf[3..]});
            return HandleRequestError.InvalidRequest;
        },
    };

    std.log.info("Get key '{s}'", .{key});
    const raw_value = main_mapping.get(key);

    std.log.debug("content", .{});
    const value: []u8 = if (raw_value) |str|
        str.content
    else
        @constCast(@ptrCast("null"));

    const response_format = "get {s} -> {s}";

    var response_buf: MessageBuffer = undefined;
    const response = std.fmt.bufPrint(&response_buf, response_format, .{ key, value }) catch |err|
        switch (err) {
        error.NoSpaceLeft => unreachable,
    };

    conn_state.wbuf_size += try protocol.createPayload(response, conn_state.writeable_slice());
}

fn handleSetCommand(conn_state: *ConnState, buf: []u8, main_mapping: *MainMapping) HandleRequestError!void {
    std.log.info("Set command '{0s}' ({0x})", .{buf});

    if (buf.len < 5) {
        std.log.debug("Invalid request - {s} (len = {})", .{ buf, buf.len });
        return HandleRequestError.InvalidRequest;
    }

    const key = protocol.parseString(buf[3..]) catch |err| switch (err) {
        error.InvalidString => {
            std.log.debug("Failed to parse key {s}", .{buf[3..]});
            return HandleRequestError.InvalidRequest;
        },
    };
    std.log.info("Key {s}", .{key});

    const value = protocol.parseString(buf[5 + key.len ..]) catch |err| switch (err) {
        error.InvalidString => {
            std.log.debug("Failed to parse value {s}", .{buf[5 + key.len ..]});
            return HandleRequestError.InvalidRequest;
        },
    };

    const new_key = main_mapping.allocator.alloc(u8, key.len) catch return HandleRequestError.InvalidRequest;
    errdefer main_mapping.allocator.free(new_key);
    @memcpy(new_key, key);

    const new_val = String.init(main_mapping.allocator, value) catch |err| switch (err) {
        error.OutOfMemory => return HandleRequestError.InvalidRequest,
    };
    errdefer new_val.deinit(main_mapping.allocator);

    main_mapping.put(new_key, new_val) catch {
        std.log.debug("Failed to put into mapping {any}", .{new_val});
        return HandleRequestError.InvalidRequest;
    };

    const response = "created";
    conn_state.wbuf_size += protocol.createPayload(response, conn_state.writeable_slice()) catch unreachable;
}

fn handleDeleteCommand(conn_state: *ConnState, buf: []const u8, main_mapping: *MainMapping) HandleRequestError!void {
    std.log.info("Delete command '{0s}' (0x)", .{buf});

    if (buf.len < 5) {
        std.log.debug("Invalid request - {s} (len = {})", .{ buf, buf.len });
        return HandleRequestError.InvalidRequest;
    }

    const key = protocol.parseString(buf[3..]) catch |err| switch (err) {
        error.InvalidString => return HandleRequestError.InvalidRequest,
    };

    const removed = main_mapping.swapRemove(key);

    const response_format = "del {s} -> {}";

    var response_buf: MessageBuffer = undefined;
    const response = std.fmt.bufPrint(
        &response_buf,
        response_format,
        .{ key, removed },
    ) catch |err|
        switch (err) {
        error.NoSpaceLeft => unreachable,
    };

    conn_state.wbuf_size += try protocol.createPayload(response, conn_state.writeable_slice());
}

fn handleListCommand(conn_state: *ConnState, buf: []const u8, main_mapping: *MainMapping) HandleRequestError!void {
    std.log.info("List command '{0s}' (0x)", .{buf});

    const keys = main_mapping.keys();

    std.debug.print("total keys {d}\n", .{keys.len});

    if (keys.len == 0) {
        conn_state.wbuf_size += try protocol.createPayload("no keys", conn_state.writeable_slice());
        return;
    }

    var response_buf: [1_000]u8 = undefined;
    var cursor: usize = 0;

    for (main_mapping.keys()) |key| {
        std.debug.print("key: {s}\n", .{key});
        const value = main_mapping.get(key).?;
        const slice = std.fmt.bufPrint(response_buf[cursor..], "{s} = {s},", .{ key, value.content }) catch |err|
            switch (err) {
            error.NoSpaceLeft => return HandleRequestError.MessageTooLong,
        };
        cursor += slice.len;
    }

    conn_state.wbuf_size += try protocol.createPayload(response_buf[0..cursor], conn_state.writeable_slice());
}

fn parseRequest(conn_state: *ConnState, buf: []u8, main_mapping: *MainMapping) void {

    // Support get, set, del

    // first 3 bytes are the type of command
    if (buf.len < 3) return handleUnknownCommand(conn_state, buf);

    var err: ?HandleRequestError = null;
    switch (protocol.parseCommand(buf[0..3])) {
        .Get => handleGetCommand(conn_state, buf, main_mapping) catch |e| {
            err = e;
        },
        .Set => handleSetCommand(conn_state, buf, main_mapping) catch |e| {
            err = e;
        },
        .Delete => handleDeleteCommand(conn_state, buf, main_mapping) catch |e| {
            err = e;
        },
        .List => handleListCommand(conn_state, buf, main_mapping) catch |e| {
            err = e;
        },
        .Unknown => handleUnknownCommand(conn_state, buf),
    }

    if (err != null) {
        switch (err.?) {
            // Length check has already been completed
            error.MessageTooLong => unreachable,
            error.InvalidRequest => {
                conn_state.wbuf_size += protocol.createPayload("Invalid request", conn_state.writeable_slice()) catch unreachable;
            },
        }
    }
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

fn stateReq(conn: GenericConn, main_mapping: *MainMapping) void {
    while (tryFillBuffer(conn, main_mapping)) {}
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

fn stateRes(conn: GenericConn) void {
    while (tryFlushBuffer(conn)) {}
}

fn connectionIo(conn: GenericConn, main_mapping: *MainMapping) !void {
    switch (conn.state.state) {
        .REQ => stateReq(conn, main_mapping),
        .RES => stateRes(conn),
        .END => return error.InvalidConnection,
    }
}

fn acceptNewConnection(fd2conn: *ConnMapping, server_handle: std.posix.socket_t) !std.posix.socket_t {
    // Built in server.accept method doesn't allow for non-blocking connections
    var accepted_addr: std.net.Address = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.net.Address);
    const fd = try std.posix.accept(
        server_handle,
        &accepted_addr.any,
        &addr_len,
        std.posix.SOCK.NONBLOCK,
    );
    const stream = std.net.Stream{
        .handle = fd,
    };

    errdefer stream.close();
    std.log.info("Connection received! {} (fd={})", .{ accepted_addr, fd });

    const conn = try NetConn.init(
        fd2conn.allocator,
        stream,
    );
    errdefer {
        conn.deinit(fd2conn.allocator);
        fd2conn.allocator.destroy(conn);
    }

    try fd2conn.put(conn.stream.handle, conn);
    return conn.stream.handle;
}

// Function to manage CTRL + C
fn sigintHandler(sig: c_int) callconv(.C) void {
    _ = sig;
    std.debug.print("\nSIGINT received\n", .{});
    std.debug.panic("sigint panic", .{});
}

fn handleEvent(
    event: *const event_loop.Event,
    epoll_loop: *event_loop.EpollEventLoop,
    server_handle: std.posix.socket_t,
    conn_mapping: *ConnMapping,
    main_mapping: *MainMapping,
) !void {
    std.debug.print("Handling event {}\n", .{event});
    std.debug.print("fd - {}\n", .{event.data.fd});

    if (event.data.fd == server_handle) {
        // Handle server fd
        std.debug.print("accept new connection\n", .{});
        const client_fd = try acceptNewConnection(conn_mapping, server_handle);
        try epoll_loop.register_client_event(client_fd);
        return;
    }

    // Process active client connections
    const conn = conn_mapping.get(event.data.fd).?;
    try connectionIo(conn.connection(), main_mapping);

    if (conn.state.state == .END) {
        std.log.info("Remove connection (fd={})\n", .{conn.stream.handle});
        conn.connection().close();
        _ = conn_mapping.swapRemove(event.data.fd);
        conn.deinit(conn_mapping.allocator);
    }
}

pub const std_options = .{
    .log_level = .info,
};

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_alloc.deinit() == .ok);
    const allocator = gpa_alloc.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip first argument (path to program)
    _ = args.skip();
    const port = try cli.getPortFromArgs(&args);

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    var server = try address.listen(.{
        .force_nonblocking = true,
        .reuse_port = true,
    });
    defer server.deinit();
    const server_handle = server.stream.handle;

    std.log.info("Server v0.1 listening on port {}", .{address.getPort()});

    const act = std.os.linux.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.os.linux.empty_sigset,
        .flags = 0,
    };
    if (std.os.linux.sigaction(std.os.linux.SIG.INT, &act, null) != 0) {
        return error.SignalHandlerError;
    }

    var fd2conn = ConnMapping.init(allocator);
    defer {
        // Make sure to clean up any lasting connections before
        // deiniting the hashmap
        std.log.info("Clean up connections", .{});
        for (fd2conn.values()) |conn| {
            conn.connection().close();
            conn.deinit(allocator);
        }
        fd2conn.deinit();
    }

    var main_mapping = MainMapping.init(allocator);
    defer {
        for (main_mapping.keys(), main_mapping.values()) |key, val| {
            allocator.free(key);
            val.deinit(allocator);
        }
        main_mapping.deinit();
    }

    var epoll_loop = try event_loop.create_epoll_loop(server_handle);
    std.log.debug("Server fd {}\n", .{server_handle});
    while (true) {

        // poll for active fds
        const ready_events = try epoll_loop.wait_for_events();
        if (ready_events.len <= 0) {
            continue;
        }

        for (ready_events) |event| {
            try handleEvent(
                &event,
                &epoll_loop,
                server_handle,
                &fd2conn,
                &main_mapping,
            );
        }
    }
}

test "simple get req" {
    const allocator = std.testing.allocator;
    var mapping = MainMapping.init(allocator);
    defer mapping.deinit();

    const client = try testing.TestClient.init(allocator);
    defer client.deinit();

    // Create request
    var req_buf: [100]u8 = undefined;
    const test_message: []const u8 = "key";
    const req_len = try protocol.createGetReq(test_message, &req_buf);

    std.debug.print("req_len - {}\n", .{req_len});
    // "Send" the request from the client to server
    try client.send_req(req_buf[0..req_len]);

    const conn = client.connection();
    std.debug.print("connection io\n", .{});
    try connectionIo(conn, &mapping);

    // "Receive" the response from the server to the client
    var res_buf: [100]u8 = undefined;
    const res_len = try client.get_res(&res_buf);

    // TODO: Parse response properly as it contains length header
    try std.testing.expectEqualStrings("get key -> null", res_buf[0..res_len]);
}
