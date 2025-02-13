const std = @import("std");
const connection = @import("./connection.zig");
const protocol = @import("./protocol.zig");
const types = @import("./types.zig");
const server = @import("server.zig");
const client = @import("client.zig");
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

        if (self.client_to_server_stream.pos >= self.client_to_server_stream.buffer.len) {
            return error.WouldBlock;
        }
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
        var test_client = try allocator.create(TestClient);
        errdefer allocator.destroy(test_client);

        test_client.allocator = allocator;

        test_client.conn_state = ConnState{};

        test_client.cs_stream.buffer = test_client.cs_stream_buf[0..];
        test_client.cs_stream.reset();

        test_client.sc_stream.buffer = test_client.sc_stream_buf[0..];
        test_client.sc_stream.reset();

        test_client.test_conn = TestConn{
            .state = &test_client.conn_state,
            .client_to_server_stream = &test_client.cs_stream,
            .server_to_client_stream = &test_client.sc_stream,
        };

        return test_client;
    }

    pub fn deinit(self: *TestClient) void {
        self.allocator.destroy(self);
    }

    pub fn connection(self: *TestClient) GenericConn {
        return self.test_conn.connection();
    }

    pub fn sendRequest(self: *TestClient, buf: []const u8) !protocol.Response {
        std.log.debug("send req", .{});
        self.cs_stream.buffer = self.cs_stream_buf[0..];
        self.cs_stream.reset();
        self.sc_stream.reset();

        _ = try self.cs_stream.write(buf);
        self.cs_stream.buffer.len = buf.len;
        std.log.debug("seek to", .{});
        try self.cs_stream.seekTo(0);
        std.log.debug("finish send req", .{});

        try connectionIo(self.connection(), self.server.mapping);
        return try self.getResponse();
    }

    pub fn sendGetRequest(self: *TestClient, key: []const u8) !protocol.GetResponse {
        var req_buf: [100]u8 = undefined;
        const req_len = try client.createGetReq(key, &req_buf);
        std.log.debug("req_len - {}", .{req_len});

        return (try self.sendRequest(req_buf[0..req_len])).Get;
    }

    pub fn sendSetRequest(self: *TestClient, message: []const u8) !protocol.SetResponse {
        var req_buf: [100]u8 = undefined;
        const req_len = try client.createSetReq(message, &req_buf);
        std.log.debug("req_len - {}", .{req_len});

        return (try self.sendRequest(req_buf[0..req_len])).Set;
    }

    pub fn sendDeleteRequest(self: *TestClient, message: []const u8) !protocol.DeleteResponse {
        var req_buf: [100]u8 = undefined;
        const req_len = try client.createDelReq(message, &req_buf);
        std.log.debug("req_len - {}", .{req_len});

        return (try self.sendRequest(req_buf[0..req_len])).Delete;
    }

    pub fn sendListRequest(self: *TestClient, message: []const u8) !protocol.ListResponse {
        var req_buf: [100]u8 = undefined;
        const req_len = try client.createListReq(message, &req_buf);
        std.log.debug("req_len - {}", .{req_len});

        return (try self.sendRequest(req_buf[0..req_len])).List;
    }

    fn getResponse(self: *TestClient) !protocol.Response {
        try self.sc_stream.seekTo(0);
        const response_len = try protocol.receiveMessage(
            self.sc_stream.reader().any(),
            &self.response_buf,
        );

        return try protocol.decodeResponse(
            self.allocator,
            self.response_buf[0..response_len],
        );
    }
};

pub const TestServer = struct {
    mapping: *types.Mapping,
};
