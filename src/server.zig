const std = @import("std");

const protocol = @import("protocol.zig");
const cli = @import("cli.zig");
const String = @import("types.zig").String;

const MessageBuffer = [protocol.len_header_size + protocol.k_max_msg]u8;

const ConnState = struct {
    /// The different states that a connection can be in
    state: enum {
        /// Request
        REQ,
        /// Response
        RES,
        /// End of connection
        END,
    } = .REQ,

    // Read buffer
    rbuf_size: usize = 0,
    rbuf_cursor: usize = 0,
    rbuf: MessageBuffer,

    // Write buffer
    wbuf_size: usize = 0,
    wbuf_sent: usize = 0,
    wbuf: MessageBuffer,

    pub fn init(allocator: std.mem.Allocator) !*ConnState {
        const conn_state = try allocator.create(ConnState);
        errdefer allocator.destroy(conn_state);

        conn_state.state = .REQ;

        conn_state.rbuf_size = 0;
        conn_state.rbuf_cursor = 0;

        conn_state.wbuf_size = 0;
        conn_state.wbuf_sent = 0;

        return conn_state;
    }

    pub fn deinit(self: *ConnState, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

const GenericConn = struct {
    ptr: *anyopaque,
    state: *ConnState,

    closeFn: *const fn (*anyopaque) void,
    writeFn: *const fn (*anyopaque, []const u8) WriteError!usize,
    readFn: *const fn (*anyopaque, []u8) ReadError!usize,

    const Self = @This();

    pub const WriteError = anyerror;
    pub const Writer = std.io.Writer(*Self, WriteError, write);

    pub const ReadError = anyerror;
    pub const Reader = std.io.Reader(*Self, ReadError, read);

    pub fn close(self: *const Self) void {
        return self.closeFn(self.ptr);
    }

    pub fn write(self: *const Self, bytes: []const u8) WriteError!usize {
        return self.writeFn(self.ptr, bytes);
    }

    pub fn read(self: *const Self, buffer: []u8) ReadError!usize {
        return self.readFn(self.ptr, buffer);
    }
};

const NetConn = struct {
    stream: std.net.Stream,
    state: *ConnState,

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
            .state = self.state,
            .closeFn = NetConn.close,
            .writeFn = NetConn.writeFn,
            .readFn = NetConn.readFn,
        };
    }

    pub fn init(allocator: std.mem.Allocator, stream: std.net.Stream) !*NetConn {
        const conn_state = try ConnState.init(allocator);
        errdefer conn_state.deinit(allocator);

        var net_conn = try allocator.create(NetConn);
        net_conn.stream = stream;
        net_conn.state = conn_state;

        return net_conn;
    }

    pub fn deinit(self: *NetConn, allocator: std.mem.Allocator) void {
        self.state.deinit(allocator);
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

    var conn_state = conn.state;
    std.mem.copyForwards(
        u8,
        conn_state.rbuf[0..conn_state.rbuf_size],
        conn_state.rbuf[conn_state.rbuf_cursor .. conn_state.rbuf_cursor + conn_state.rbuf_size],
    );
    conn_state.rbuf_cursor = 0;

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

fn acceptNewConnection(fd2conn: *std.AutoArrayHashMap(std.posix.socket_t, *NetConn), server: *std.net.Server) !void {
    const client = try server.accept();
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
    });
    defer server.deinit();
    std.log.info("Server listening on port {}", .{address.getPort()});

    var poll_args = std.ArrayList(std.posix.pollfd).init(allocator);
    defer poll_args.deinit();

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

    while (true) {
        poll_args.clearAndFree();

        // Create poll args for listening server fd
        const server_pfd: std.posix.pollfd = .{
            .fd = server.stream.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        try poll_args.append(server_pfd);

        // Create poll args for all client connections
        for (fd2conn.values()) |conn| {
            var events: i16 = undefined;
            if (conn.state.state == .REQ) {
                events = std.posix.POLL.IN; //| std.posix.POLL.ERR;
            } else {
                events = std.posix.POLL.OUT; //| std.posix.POLL.ERR;
            }

            const client_pfd = std.posix.pollfd{
                .fd = conn.stream.handle,
                .events = events,
                .revents = 0,
            };
            try poll_args.append(client_pfd);
        }

        // poll for active fds
        const rv = try std.posix.poll(poll_args.items, 1000);
        if (rv < 0) {
            std.log.debug("Poll rv {}", .{rv});
            return error.PollError;
        }

        // Skip the first arg as that corresponds to the server and needs handling
        // separately
        // Process active client connections
        for (poll_args.items[1..]) |pfd| {
            if (pfd.revents == 0) continue;

            const conn = fd2conn.get(pfd.fd).?;
            try connectionIo(conn.connection(), &main_mapping);

            if (conn.state.state == .END) {
                std.log.info("Remove connection", .{});
                conn.connection().close();
                _ = fd2conn.swapRemove(pfd.fd);
                conn.deinit(allocator);
            }
        }

        // Handle server fd
        if (poll_args.items[0].revents != 0) {
            std.log.info("server fd revents {}", .{poll_args.items[0].revents});
            _ = try acceptNewConnection(&fd2conn, &server);
        }
    }
}

const TestConn = struct {
    const FixedBufferStream = std.io.FixedBufferStream([]u8);

    client_to_server_stream: *FixedBufferStream,
    server_to_client_stream: *FixedBufferStream,

    state: *ConnState,

    pub fn close(ptr: *anyopaque) void {
        _ = ptr;
    }

    pub fn writeFn(ptr: *anyopaque, bytes: []const u8) !usize {
        var self: *TestConn = @ptrCast(@alignCast(ptr));
        const writer = self.server_to_client_stream.writer();
        return writer.write(bytes);
    }

    pub fn readFn(ptr: *anyopaque, buffer: []u8) !usize {
        var self: *TestConn = @ptrCast(@alignCast(ptr));
        const reader = self.client_to_server_stream.reader();
        return reader.read(buffer);
    }

    pub fn connection(self: *TestConn) GenericConn {
        return .{
            .ptr = self,
            .state = self.state,
            .closeFn = TestConn.close,
            .writeFn = TestConn.writeFn,
            .readFn = TestConn.readFn,
        };
    }
};

test "simple get req" {
    const allocator = std.testing.allocator;
    var mapping = MainMapping.init(allocator);
    defer mapping.deinit();

    const rbuf: MessageBuffer = undefined;
    const wbuf: MessageBuffer = undefined;
    var conn_state: ConnState = .{
        .rbuf = rbuf,
        .wbuf = wbuf,
    };

    var cs_stream_buf: [1000]u8 = undefined;
    var cs_stream = std.io.fixedBufferStream(&cs_stream_buf);

    var sc_stream_buf: [1000]u8 = undefined;
    var sc_stream = std.io.fixedBufferStream(&sc_stream_buf);

    var test_conn: TestConn = .{
        .state = &conn_state,
        .client_to_server_stream = &cs_stream,
        .server_to_client_stream = &sc_stream,
    };

    // Create request
    var req_buf: [100]u8 = undefined;
    const test_message: []const u8 = "key";
    const req_len = try protocol.createGetReq(test_message, &req_buf);

    std.debug.print("req_len - {}\n", .{req_len});
    // "Send" the request from the client to server
    _ = try cs_stream.write(req_buf[0..req_len]);
    try cs_stream.seekTo(0);

    const conn = test_conn.connection();
    try connectionIo(conn, &mapping);

    // "Receive" the response from the server to the client
    try sc_stream.seekTo(0);
    var res_buf: [100]u8 = undefined;
    const res_len = try protocol.receiveMessage(sc_stream.reader().any(), &res_buf);

    // TODO: Parse response properly as it contains length header
    try std.testing.expectEqualStrings("get key -> null", res_buf[0..res_len]);
}
