stream: std.net.Stream,
state: ConnState,

const std = @import("std");

const _connection = @import("connection.zig");
const ConnState = _connection.ConnState;
const GenericConn = _connection.GenericConn;

const NetConn = @This();

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
