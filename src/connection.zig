const std = @import("std");
const protocol = @import("./protocol.zig");

const MessageBuffer = protocol.MessageBuffer;

pub const ConnState = struct {
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
    rbuf: MessageBuffer = undefined,

    // Write buffer
    wbuf_size: usize = 0,
    wbuf_sent: usize = 0,
    wbuf: MessageBuffer = undefined,

    pub fn w_slice(self: *ConnState) []u8 {
        return self.wbuf[self.wbuf_size..];
    }
};

pub const GenericConn = struct {
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
