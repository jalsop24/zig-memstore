const std = @import("std");
const connection = @import("./connection.zig");
const protocol = @import("./protocol.zig");
const types = @import("./types.zig");
const server = @import("server.zig");
const connectionIo = @import("connection_io.zig").connectionIo;

const ConnState = connection.ConnState;
const GenericConn = connection.GenericConn;

const FixedBufferStream = std.io.FixedBufferStream([]u8);

pub const TestConn = struct {
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

pub const TestClient = struct {
    allocator: std.mem.Allocator,

    cs_stream_buf: [1000]u8,
    cs_stream: FixedBufferStream,

    sc_stream_buf: [1000]u8,
    sc_stream: FixedBufferStream,

    response_buf: [100]u8,

    conn_state: ConnState,
    test_conn: TestConn,

    server: *TestServer,

    pub fn init(allocator: std.mem.Allocator) !*TestClient {
        var client = try allocator.create(TestClient);
        errdefer allocator.destroy(client);

        client.allocator = allocator;

        client.cs_stream_buf = undefined;
        client.sc_stream_buf = undefined;
        client.cs_stream = undefined;
        client.sc_stream = undefined;
        client.response_buf = undefined;
        client.conn_state = ConnState{};

        client.cs_stream.buffer = client.cs_stream_buf[0..];
        client.cs_stream.reset();

        client.sc_stream.buffer = client.sc_stream_buf[0..];
        client.sc_stream.reset();

        client.test_conn = TestConn{
            .state = &client.conn_state,
            .client_to_server_stream = &client.cs_stream,
            .server_to_client_stream = &client.sc_stream,
        };

        return client;
    }

    pub fn deinit(self: *TestClient) void {
        self.allocator.destroy(self);
    }

    pub fn connection(self: *TestClient) GenericConn {
        return self.test_conn.connection();
    }

    pub fn sendRequest(self: *TestClient, buf: []const u8) ![]u8 {
        std.debug.print("send req\n", .{});
        _ = try self.cs_stream.write(buf);
        std.debug.print("seek to\n", .{});
        try self.cs_stream.seekTo(0);
        std.debug.print("finish send req\n", .{});

        try connectionIo(self.connection(), self.server.mapping);
        return try self.getResponse();
    }

    pub fn sendGetRequest(self: *TestClient, key: []const u8) ![]u8 {
        var req_buf: [100]u8 = undefined;
        const req_len = try protocol.createGetReq(key, &req_buf);
        std.debug.print("req_len - {}\n", .{req_len});

        return try self.sendRequest(req_buf[0..req_len]);
    }

    pub fn sendSetRequest(self: *TestClient, message: []const u8) ![]u8 {
        var req_buf: [100]u8 = undefined;
        const req_len = try protocol.createSetReq(message, &req_buf);
        std.debug.print("req_len - {}\n", .{req_len});

        return try self.sendRequest(req_buf[0..req_len]);
    }

    pub fn sendDeleteRequest(self: *TestClient, message: []const u8) ![]u8 {
        var req_buf: [100]u8 = undefined;
        const req_len = try protocol.createDelReq(message, &req_buf);
        std.debug.print("req_len - {}\n", .{req_len});

        return try self.sendRequest(req_buf[0..req_len]);
    }

    pub fn sendListRequest(self: *TestClient, message: []const u8) ![]u8 {
        var req_buf: [100]u8 = undefined;
        const req_len = try protocol.createListReq(message, &req_buf);
        std.debug.print("req_len - {}\n", .{req_len});

        return try self.sendRequest(req_buf[0..req_len]);
    }

    fn getResponse(self: *TestClient) ![]u8 {
        try self.sc_stream.seekTo(0);
        const response_len = try protocol.receiveMessage(
            self.sc_stream.reader().any(),
            &self.response_buf,
        );
        return self.response_buf[0..response_len];
    }
};

pub const TestServer = struct {
    mapping: *types.MainMapping,
};
