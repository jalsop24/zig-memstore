const std = @import("std");

const protocol = @import("protocol.zig");

/// The different states that a connection can be in
const State = enum {
    /// Request
    REQ,
    /// Response
    RES,
    /// End of connection
    END,
};

const Conn = struct {
    stream: std.net.Stream,
    state: State = .REQ,
    // Read buffer
    rbuf_size: usize = 0,
    rbuf_cursor: usize = 0,
    rbuf: [4 + protocol.k_max_msg]u8,
    // Write buffer
    wbuf_size: usize = 0,
    wbuf_sent: usize = 0,
    wbuf: [4 + protocol.k_max_msg]u8,

    pub fn create(allocator: std.mem.Allocator, stream: std.net.Stream) !*Conn {
        const conn = try allocator.create(Conn);

        conn.* = Conn{
            .stream = stream,
            .rbuf = conn.rbuf,
            .wbuf = conn.wbuf,
        };
        return conn;
    }
};

const String = struct {
    content: []u8,

    pub fn init(allocator: std.mem.Allocator, content: []u8) !*String {
        var new = try allocator.create(String);
        errdefer allocator.destroy(new);

        const bytes = try allocator.alloc(u8, content.len);
        new.content = bytes;

        @memcpy(new.content, content);
        return new;
    }

    pub fn deinit(self: *String, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        allocator.destroy(self);
    }
};

const MainMapping = std.StringArrayHashMap(*String);

fn getPortFromArgs(args: *std.process.ArgIterator) !u16 {
    const raw_port = args.next() orelse {
        std.log.info("Expected port as a command line argument\n", .{});
        return error.NoPort;
    };
    return try std.fmt.parseInt(u16, raw_port, 10);
}

const HandleRequestError = error{InvalidRequest} || protocol.PayloadCreationError;

fn handleUnknownCommand(conn: *Conn, buf: []u8) void {
    std.log.info("Client says '{s}'", .{buf});
    // Generate echo response
    @memcpy(conn.wbuf[0 .. 4 + buf.len], conn.rbuf[conn.rbuf_cursor .. conn.rbuf_cursor + 4 + buf.len]);
    conn.wbuf_size = 4 + buf.len;
}

fn handleGetCommand(conn: *Conn, buf: []u8, main_mapping: *MainMapping) HandleRequestError!void {
    std.log.info("Get command '{0s}' ({0x})", .{buf});

    if (buf.len < 5) {
        std.log.debug("Invalid request - {s} (len = {})", .{ buf, buf.len });
        return HandleRequestError.InvalidRequest;
    }

    const key_len = std.mem.readPackedInt(u16, buf[3..5], 0, .little);
    if (key_len != buf.len - 5) {
        return HandleRequestError.InvalidRequest;
    }
    const key = buf[5 .. 5 + key_len];

    std.log.info("Get key '{s}'", .{key});
    const raw_value = (main_mapping.get(key));

    std.log.debug("content", .{});
    const value: []u8 = if (raw_value) |str|
        str.content
    else
        @constCast(@ptrCast("null"));

    const response_format = "get {s} -> {s}";

    var response_buf: [protocol.k_max_msg]u8 = undefined;
    const response = std.fmt.bufPrint(&response_buf, response_format, .{ key, value }) catch |err|
        switch (err) {
        error.NoSpaceLeft => unreachable,
    };

    const written = try protocol.createPayload(response, conn.wbuf[conn.wbuf_size..]);
    conn.wbuf_size += written;
}

fn handleSetCommand(conn: *Conn, buf: []u8, main_mapping: *MainMapping) HandleRequestError!void {
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
    @memcpy(new_key, key);

    const new_val = String.init(main_mapping.allocator, value) catch |err| switch (err) {
        error.OutOfMemory => return HandleRequestError.InvalidRequest,
    };

    main_mapping.put(new_key, new_val) catch {
        std.log.debug("Failed to put into mapping {any}", .{new_val});
        return HandleRequestError.InvalidRequest;
    };

    const response = "created";
    const written = protocol.createPayload(response, conn.wbuf[conn.wbuf_size..]) catch unreachable;
    conn.wbuf_size += written;
}

fn handleDeleteCommand(conn: *Conn, buf: []u8, main_mapping: *MainMapping) HandleRequestError!void {
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

    var response_buf: [protocol.k_max_msg]u8 = undefined;
    const response = std.fmt.bufPrint(&response_buf, response_format, .{ key, removed }) catch |err|
        switch (err) {
        error.NoSpaceLeft => unreachable,
    };

    const written = try protocol.createPayload(response, conn.wbuf[conn.wbuf_size..]);
    conn.wbuf_size += written;
}

fn parseRequest(conn: *Conn, buf: []u8, main_mapping: *MainMapping) void {

    // Support get, set, del

    // first 3 bytes are the type of command
    if (buf.len < 3) return handleUnknownCommand(conn, buf);

    var err: ?HandleRequestError = null;
    switch (protocol.parseCommand(buf[0..3])) {
        .Get => handleGetCommand(conn, buf, main_mapping) catch |e| {
            err = e;
        },
        .Set => handleSetCommand(conn, buf, main_mapping) catch |e| {
            err = e;
        },
        .Delete => handleDeleteCommand(conn, buf, main_mapping) catch |e| {
            err = e;
        },
        .Unknown => handleUnknownCommand(conn, buf),
    }

    if (err != null) {
        switch (err.?) {
            // Length check has already been completed
            error.MessageTooLong => unreachable,
            error.InvalidRequest => {
                const written = protocol.createPayload("Invalid request", conn.wbuf[conn.wbuf_size..]) catch unreachable;
                conn.wbuf_size += written;
            },
        }
    }
}

fn tryOneRequest(conn: *Conn, main_mapping: *MainMapping) bool {
    if (conn.rbuf_size < 4) {
        // Not enough data in the buffer, try after the next poll
        return false;
    }

    const length_header = conn.rbuf[conn.rbuf_cursor .. conn.rbuf_cursor + 4];
    const len = std.mem.readPackedInt(
        u32,
        length_header,
        0,
        .little,
    );

    if (len > protocol.k_max_msg) {
        std.log.debug("Too long - len = {}", .{len});
        std.log.debug("Message: {x}", .{length_header});
        conn.state = .END;
        return false;
    }

    if (conn.rbuf_size < 4 + len) {
        // Not enough data in the buffer
        return false;
    }

    const message = conn.rbuf[conn.rbuf_cursor + 4 .. conn.rbuf_cursor + 4 + len];
    parseRequest(conn, message, main_mapping);

    // 'Remove' request from read buffer
    const remaining_bytes = conn.rbuf_size - 4 - len;
    conn.rbuf_size = remaining_bytes;
    // Update read cursor position
    conn.rbuf_cursor = conn.rbuf_cursor + 4 + len;

    // Trigger response logic
    conn.state = .RES;
    stateRes(conn);

    return (conn.state == .REQ);
}

fn tryFillBuffer(conn: *Conn, main_mapping: *MainMapping) bool {
    // Reset buffer so that it is filled right from the start
    std.mem.copyForwards(
        u8,
        conn.rbuf[0..conn.rbuf_size],
        conn.rbuf[conn.rbuf_cursor .. conn.rbuf_cursor + conn.rbuf_size],
    );
    conn.rbuf_cursor = 0;

    const num_read = conn.stream.read(conn.rbuf[conn.rbuf_size..]) catch |err|
        switch (err) {
        // WouldBlock corresponds to EAGAIN signal
        error.WouldBlock => return false,
        else => {
            std.log.debug("read error {s}", .{@errorName(err)});
            conn.state = .END;
            return false;
        },
    };

    if (num_read == 0) {
        if (conn.rbuf_size > 0) {
            std.log.debug("Unexpected EOF", .{});
        } else {
            std.log.debug("EOF", .{});
        }
        conn.state = .END;
        return false;
    }

    conn.rbuf_size += num_read;
    std.debug.assert(conn.rbuf_size < conn.rbuf.len);

    // Parse multiple requests as more than one may be sent at a time
    while (tryOneRequest(conn, main_mapping)) {}
    return (conn.state == .REQ);
}

fn stateReq(conn: *Conn, main_mapping: *MainMapping) void {
    while (tryFillBuffer(conn, main_mapping)) {}
}

fn tryFlushBuffer(conn: *Conn) bool {
    conn.stream.writeAll(conn.wbuf[0..conn.wbuf_size]) catch |err|
        switch (err) {
        error.WouldBlock => return false,
        else => {
            std.log.debug("write error {s}", .{@errorName(err)});
            conn.state = .END;
            return false;
        },
    };

    conn.state = .REQ;
    conn.wbuf_sent = 0;
    conn.wbuf_size = 0;
    return false;
}

fn stateRes(conn: *Conn) void {
    while (tryFlushBuffer(conn)) {}
}

fn connectionIo(conn: *Conn, main_mapping: *MainMapping) !void {
    switch (conn.state) {
        .REQ => stateReq(conn, main_mapping),
        .RES => stateRes(conn),
        .END => return error.InvalidConnection,
    }
}

fn acceptNewConnection(fd2conn: *std.AutoArrayHashMap(std.posix.socket_t, *Conn), server: *std.net.Server) !std.net.Server.Connection {
    const client = try server.accept();
    errdefer client.stream.close();
    std.log.info("Connection received! {}", .{client.address});

    const conn = try Conn.create(fd2conn.allocator, client.stream);
    errdefer fd2conn.allocator.destroy(conn);

    try fd2conn.put(conn.stream.handle, conn);

    return client;
}

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_alloc.deinit() == .ok);
    const allocator = gpa_alloc.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip first argument (path to program)
    _ = args.skip();
    const port = try getPortFromArgs(&args);

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    var server = try address.listen(.{
        .force_nonblocking = true,
    });
    defer server.deinit();
    std.log.info("Server listening on port {}", .{address.getPort()});

    var poll_args = std.ArrayList(std.posix.pollfd).init(allocator);
    defer poll_args.deinit();

    var fd2conn = std.AutoArrayHashMap(std.posix.socket_t, *Conn).init(allocator);
    defer {
        // Make sure to clean up any lasting connections before
        // deiniting the hashmap
        std.log.info("Clean up connections", .{});
        for (fd2conn.values()) |conn| {
            conn.stream.close();
            allocator.destroy(conn);
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
            if (conn.state == .REQ) {
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
            try connectionIo(conn, &main_mapping);

            if (conn.state == .END) {
                std.log.info("Remove connection", .{});
                conn.stream.close();
                _ = fd2conn.swapRemove(pfd.fd);
                allocator.destroy(conn);
            }
        }

        // Handle server fd
        if (poll_args.items[0].revents != 0) {
            std.log.info("server fd revents {}", .{poll_args.items[0].revents});
            _ = try acceptNewConnection(&fd2conn, &server);
        }
    }
}
