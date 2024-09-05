const std = @import("std");

const protocol = @import("protocol.zig");

const State = enum {
    REQ,
    RES,
    END,
};

const Conn = struct {
    stream: std.net.Stream,
    state: State = .REQ,
    // Read buffer
    rbuf_size: usize = 0,
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

fn getPortFromArgs(args: *std.process.ArgIterator) !u16 {
    const raw_port = args.next() orelse {
        std.log.info("Expected port as a command line argument\n", .{});
        return error.NoPort;
    };
    return try std.fmt.parseInt(u16, raw_port, 10);
}

fn tryOneRequest(conn: *Conn) bool {
    if (conn.rbuf_size < 4) {
        // Not enough data in the buffer, try after the next poll
        return false;
    }

    const len = std.mem.readPackedInt(
        u32,
        conn.rbuf[0..4],
        0,
        .little,
    );

    if (len > protocol.k_max_msg) {
        std.log.debug("Too long - len = {}", .{len});
        std.log.debug("Message: {x}", .{conn.rbuf[0..4]});
        conn.state = .END;
        return false;
    }

    if (conn.rbuf_size < 4 + len) {
        // Not enough data in the buffer
        return false;
    }

    const message = conn.rbuf[4 .. 4 + len];
    std.log.info("Client says '{s}'", .{message});

    // Generate echo response
    @memcpy(conn.wbuf[0 .. 4 + len], conn.rbuf[0 .. 4 + len]);
    conn.wbuf_size = 4 + len;

    // Remove request from read buffer
    const remaining_bytes = conn.rbuf_size - 4 - len;
    if (remaining_bytes != 0) {
        std.mem.copyForwards(
            u8,
            conn.rbuf[0..remaining_bytes],
            conn.rbuf[4 + len .. conn.rbuf.len],
        );
    }
    conn.rbuf_size = remaining_bytes;
    conn.state = .RES;
    stateRes(conn);

    return (conn.state == .REQ);
}

fn tryFillBuffer(conn: *Conn) bool {
    const num_read = conn.stream.readAll(conn.rbuf[conn.rbuf_size..]) catch |err|
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
    while (tryOneRequest(conn)) {}
    return (conn.state == .REQ);
}

fn stateReq(conn: *Conn) void {
    while (tryFillBuffer(conn)) {}
}

fn tryFlushBuffer(conn: *Conn) bool {
    conn.stream.writeAll(&conn.wbuf) catch |err|
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

fn connectionIo(conn: *Conn) !void {
    switch (conn.state) {
        .REQ => stateReq(conn),
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
        for (fd2conn.values()) |conn| {
            conn.stream.close();
            allocator.destroy(conn);
        }
        fd2conn.deinit();
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
            try connectionIo(conn);

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
