const std = @import("std");

const protocol = @import("protocol.zig");
const cli = @import("cli.zig");
const String = @import("types.zig").String;
const connection = @import("connection.zig");
const event_loop = @import("event_loop.zig");
const testing = @import("testing.zig");

const ConnState = connection.ConnState;
const GenericConn = connection.GenericConn;
const MessageBuffer = protocol.MessageBuffer;

const NetConn = struct {
    stream: std.net.Stream,
    state: ConnState,

    pub fn close(ptr: *anyopaque) void {
        var self: *NetConn = @ptrCast(@alignCast(ptr));
        self.stream.close();
    }

    pub fn writeFn(ptr: *anyopaque, bytes: []const u8) !usize {
        var self: *NetConn = @ptrCast(@alignCast(ptr));
        return self.stream.writer().write(bytes);
    }

    pub fn readFn(ptr: *anyopaque, buffer: []u8) !usize {
        var self: *NetConn = @ptrCast(@alignCast(ptr));
        return self.stream.reader().read(buffer);
    }

    pub fn connection(self: *NetConn) GenericConn {
        return .{
            .ptr = self,
            .state = &self.state,
            .closeFn = NetConn.close,
            .writeFn = NetConn.writeFn,
            .readFn = NetConn.readFn,
        };
    }

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream) !*NetConn {
        var net_conn = try allocator.create(NetConn);
        net_conn.stream = stream;
        net_conn.state = ConnState{};

        return net_conn;
    }

    pub fn deinit(self: *NetConn, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

const MainMapping = std.StringArrayHashMap(*String);

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
    const raw_value = (main_mapping.get(key));

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

    const written = try protocol.createPayload(response, conn_state.wbuf[conn_state.wbuf_size..]);
    conn_state.wbuf_size += written;
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
    const written = protocol.createPayload(response, conn_state.wbuf[conn_state.wbuf_size..]) catch unreachable;
    conn_state.wbuf_size += written;
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

    const written = try protocol.createPayload(response, conn_state.wbuf[conn_state.wbuf_size..]);
    conn_state.wbuf_size += written;
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
        .Unknown => handleUnknownCommand(conn_state, buf),
    }

    if (err != null) {
        switch (err.?) {
            // Length check has already been completed
            error.MessageTooLong => unreachable,
            error.InvalidRequest => {
                const written = protocol.createPayload("Invalid request", conn_state.wbuf[conn_state.wbuf_size..]) catch unreachable;
                conn_state.wbuf_size += written;
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
        conn_state.rbuf[conn_state.rbuf_cursor .. conn_state.rbuf_cursor + conn_state.rbuf_size],
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
    std.debug.print("Try flush buffer\n", .{});
    var conn_state = conn.state;

    _ = conn.write(conn_state.wbuf[0..conn_state.wbuf_size]) catch |err|
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

fn acceptNewConnection(fd2conn: *std.AutoArrayHashMap(std.posix.socket_t, *NetConn), server: *std.net.Server) !std.posix.socket_t {
    // Built in server.accept method doesn't allow for non-blocking connections
    var accepted_addr: std.net.Address = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.net.Address);
    const fd = try std.posix.accept(
        server.stream.handle,
        &accepted_addr.any,
        &addr_len,
        std.posix.SOCK.NONBLOCK,
    );
    const client = std.net.Server.Connection{
        .stream = .{ .handle = fd },
        .address = accepted_addr,
    };
    errdefer client.stream.close();
    std.log.info("Connection received! {}", .{client.address});

    const conn = try NetConn.init(
        fd2conn.allocator,
        client.stream,
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

    std.log.info("Server listening on port {}", .{address.getPort()});

    const act = std.os.linux.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.os.linux.empty_sigset,
        .flags = 0,
    };
    if (std.os.linux.sigaction(std.os.linux.SIG.INT, &act, null) != 0) {
        return error.SignalHandlerError;
    }

    var fd2conn = std.AutoArrayHashMap(std.posix.socket_t, *NetConn).init(allocator);
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

    var epoll_loop = try event_loop.create_epoll_loop(&server);
    std.debug.print("Server fd {}\n", .{server.stream.handle});
    while (true) {

        // poll for active fds
        std.debug.print("wait for events\n", .{});
        const ready_events = try epoll_loop.wait_for_events();
        if (ready_events <= 0) {
            continue;
        }

        for (epoll_loop.events[0..ready_events]) |event| {
            std.debug.print("Handling event {}\n", .{event});
            std.debug.print("fd - {}\n", .{event.data.fd});

            if (event.data.fd == server.stream.handle) {
                // Handle server fd
                std.debug.print("accept new connection\n", .{});
                const client_fd = try acceptNewConnection(&fd2conn, &server);
                try epoll_loop.register_client_event(client_fd);
                continue;
            }

            // Process active client connections
            const conn = fd2conn.get(event.data.fd).?;
            try connectionIo(conn.connection(), &main_mapping);

            if (conn.state.state == .END) {
                std.log.info("Remove connection", .{});
                conn.connection().close();
                _ = fd2conn.swapRemove(event.data.fd);
                conn.deinit(allocator);
            }
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
