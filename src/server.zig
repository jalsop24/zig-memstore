const std = @import("std");

const protocol = @import("protocol.zig");
const cli = @import("cli.zig");
const types = @import("types.zig");
const connection = @import("connection.zig");
const event_loop = @import("event_loop.zig");
const testing = @import("testing.zig");
const connectionIo = @import("connection_io.zig").connectionIo;

const NetConn = @import("NetConn.zig");

const Command = types.Command;
const ConnMapping = types.ConnMapping;
const Mapping = types.Mapping;

const COMMAND_LEN_BYTES = types.COMMAND_LEN_BYTES;

pub const Server = struct {
    handle: std.posix.socket_t,
    mapping: *Mapping,
    conn_mapping: *ConnMapping,

    pub fn run(self: Server) !void {
        var epoll_loop = try event_loop.create_epoll_loop();
        try epoll_loop.register_server_event(self.handle);

        while (true) {

            // poll for active fds
            const ready_events = try epoll_loop.wait_for_events();
            if (ready_events.len <= 0) {
                continue;
            }

            for (ready_events) |event| {
                try self.handleEvent(&event, &epoll_loop);
            }
        }
    }

    fn handleEvent(
        self: Server,
        event: *const event_loop.Event,
        epoll_loop: *event_loop.EpollEventLoop,
    ) !void {
        std.log.debug("Handling event {}", .{event});
        std.log.debug("fd - {}", .{event.data.fd});

        if (event.data.fd == self.handle) {
            // Handle server fd
            std.log.debug("accept new connection", .{});
            const client_fd = try self.acceptNewConnection();
            try epoll_loop.register_client_event(client_fd);
            return;
        }

        // Process active client connections
        const conn = self.conn_mapping.get(event.data.fd).?;
        try connectionIo(conn.connection(), self.mapping);

        if (conn.state.state == .END) {
            std.log.info("Remove connection (fd={})", .{conn.stream.handle});
            conn.connection().close();
            _ = self.conn_mapping.swapRemove(event.data.fd);
            conn.deinit(self.conn_mapping.allocator);
        }
    }

    fn acceptNewConnection(self: Server) !std.posix.socket_t {
        // Built in server.accept method doesn't allow for non-blocking connections
        var accepted_addr: std.net.Address = undefined;
        var addr_len: std.posix.socklen_t = @sizeOf(std.net.Address);
        const fd = try std.posix.accept(
            self.handle,
            &accepted_addr.any,
            &addr_len,
            std.posix.SOCK.NONBLOCK,
        );
        const stream = std.net.Stream{
            .handle = fd,
        };

        errdefer stream.close();
        std.log.info("Connection received! {} (fd={})", .{ accepted_addr, fd });

        const allocator = self.conn_mapping.allocator;

        const conn = try NetConn.init(allocator, stream);
        errdefer {
            conn.deinit(allocator);
            allocator.destroy(conn);
        }

        try self.conn_mapping.put(conn.stream.handle, conn);
        return conn.stream.handle;
    }
};

test "req get" {
    const allocator = std.testing.allocator;
    var mapping = try Mapping.init(allocator);
    defer mapping.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var server = testing.TestServer{
        .mapping = mapping,
    };

    const client = try testing.TestClient.init(arena.allocator());
    defer client.deinit();
    client.server = &server;

    const response = (try client.sendRequest(
        .{ .Get = .{
            .key = .{ .content = "a_key" },
        } },
    )).Get;

    std.log.debug("response = {any}", .{response});

    try std.testing.expectEqualStrings(response.key.content, "a_key");
    try std.testing.expectEqual(response.value, null);
}

test "req set" {
    const allocator = std.testing.allocator;
    var mapping = try Mapping.init(allocator);
    defer mapping.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var server = testing.TestServer{
        .mapping = mapping,
    };

    const client = try testing.TestClient.init(arena.allocator());
    defer client.deinit();
    client.server = &server;

    const response = (try client.sendRequest(.{
        .Set = .{
            .key = .{ .content = "a" },
            .value = .{ .content = "1" },
        },
    })).Set;

    try std.testing.expectEqualStrings(response.key.content, "a");
    try std.testing.expectEqualStrings(response.value.content, "1");
}

test "req del" {
    const allocator = std.testing.allocator;
    var mapping = try Mapping.init(allocator);
    defer mapping.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var server = testing.TestServer{
        .mapping = mapping,
    };

    const client = try testing.TestClient.init(arena.allocator());
    defer client.deinit();
    client.server = &server;

    const response = (try client.sendRequest(.{
        .Delete = .{
            .key = .{ .content = "a" },
        },
    })).Delete;

    try std.testing.expectEqualStrings(response.key.content, "a");
}

test "req lst" {
    const allocator = std.testing.allocator;
    var mapping = try Mapping.init(allocator);
    defer mapping.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var server = testing.TestServer{
        .mapping = mapping,
    };

    const client = try testing.TestClient.init(arena.allocator());
    defer client.deinit();
    client.server = &server;
    {
        const response = (try client.sendRequest(.{ .List = .{} })).List;
        try std.testing.expect(response.len == 0);
    }

    // Insert actual data into the mapping
    try mapping.put(.{ .content = "a" }, .{ .content = "1" });

    const response = (try client.sendRequest(.{ .List = .{} })).List;

    try std.testing.expect(response.len == 1);
    var iter = response.iterator();
    const kv_pair = iter.next().?;
    try std.testing.expectEqualStrings(kv_pair.key.content, "a");
    try std.testing.expectEqualStrings(kv_pair.value.content, "1");
}
