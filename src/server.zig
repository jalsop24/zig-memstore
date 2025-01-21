const std = @import("std");

const protocol = @import("protocol.zig");
const cli = @import("cli.zig");
const types = @import("types.zig");
const connection = @import("connection.zig");
const event_loop = @import("event_loop.zig");
const testing = @import("testing.zig");
const connectionIo = @import("connection_io.zig").connectionIo;

const NetConn = @import("NetConn.zig");

const MainMapping = types.MainMapping;
const ConnMapping = types.ConnMapping;

const Command = protocol.Command;

pub const Server = struct {
    handle: std.posix.socket_t,
    mapping: *MainMapping,
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
        std.log.debug("Handling event {}\n", .{event});
        std.log.debug("fd - {}\n", .{event.data.fd});

        if (event.data.fd == self.handle) {
            // Handle server fd
            std.log.debug("accept new connection\n", .{});
            const client_fd = try self.acceptNewConnection();
            try epoll_loop.register_client_event(client_fd);
            return;
        }

        // Process active client connections
        const conn = self.conn_mapping.get(event.data.fd).?;
        try connectionIo(conn.connection(), self.mapping);

        if (conn.state.state == .END) {
            std.log.info("Remove connection (fd={})\n", .{conn.stream.handle});
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

test "simple get req" {
    const allocator = std.testing.allocator;
    var mapping = MainMapping.init(allocator);
    defer mapping.deinit();

    var server = testing.TestServer{
        .mapping = &mapping,
    };

    const client = try testing.TestClient.init(allocator);
    defer client.deinit();
    client.server = &server;

    const response = try client.sendGetRequest("key");

    std.debug.print("response = {x}\n", .{response});

    const command = protocol.decodeCommand(response);
    try std.testing.expectEqual(command, Command.Get);

    const get_reponse = try protocol.decodeGetResponse(response[protocol.COMMAND_LEN_BYTES..]);
    try std.testing.expectEqualStrings(get_reponse.key.content, "key");
    try std.testing.expectEqual(get_reponse.value, null);
}

test "set req" {
    const allocator = std.testing.allocator;
    var mapping = MainMapping.init(allocator);
    defer {
        for (mapping.keys(), mapping.values()) |key, val| {
            allocator.free(key);
            val.deinit(allocator);
        }
        mapping.deinit();
    }

    var server = testing.TestServer{
        .mapping = &mapping,
    };

    const client = try testing.TestClient.init(allocator);
    defer client.deinit();
    client.server = &server;

    const response = try client.sendSetRequest("a 1");

    std.debug.print("response = {x}\n", .{response});

    const command = protocol.decodeCommand(response);
    try std.testing.expectEqual(command, Command.Set);

    const set_reponse = try protocol.decodeSetResponse(response[protocol.COMMAND_LEN_BYTES..]);
    try std.testing.expectEqualStrings(set_reponse.key.content, "a");
    try std.testing.expectEqualStrings(set_reponse.value.content, "1");
}

test "del req" {
    const allocator = std.testing.allocator;
    var mapping = MainMapping.init(allocator);
    defer {
        for (mapping.keys(), mapping.values()) |key, val| {
            allocator.free(key);
            val.deinit(allocator);
        }
        mapping.deinit();
    }

    var server = testing.TestServer{
        .mapping = &mapping,
    };

    const client = try testing.TestClient.init(allocator);
    defer client.deinit();
    client.server = &server;

    const response = try client.sendDeleteRequest("a");

    std.debug.print("response = {x}\n", .{response});

    const command = protocol.decodeCommand(response);
    try std.testing.expectEqual(command, Command.Delete);

    const delete_reponse = try protocol.decodeDeleteResponse(response[protocol.COMMAND_LEN_BYTES..]);
    try std.testing.expectEqualStrings(delete_reponse.key.content, "a");
}

test "lst req" {
    const allocator = std.testing.allocator;
    var mapping = MainMapping.init(allocator);
    defer mapping.deinit();

    var server = testing.TestServer{
        .mapping = &mapping,
    };

    const client = try testing.TestClient.init(allocator);
    defer client.deinit();
    client.server = &server;

    try mapping.put("a", types.String{ .content = "1" });

    const response = try client.sendListRequest("");

    std.debug.print("list response = {x}\n", .{response});

    const command = protocol.decodeCommand(response);
    try std.testing.expectEqual(command, Command.List);

    var buf: [10]protocol.KeyValuePair = undefined;
    const list_response = try protocol.decodeListResponse(
        response[protocol.COMMAND_LEN_BYTES..],
        &buf,
    );
    try std.testing.expect(list_response.len == 1);
    var iter = list_response.iterator();
    const kv_pair = iter.next().?;
    try std.testing.expectEqualStrings(kv_pair.key.content, "a");
    try std.testing.expectEqualStrings(kv_pair.value.content, "1");
}
