const std = @import("std");
const NetConn = @import("NetConn.zig");

pub const MainMapping = std.StringArrayHashMap(String);
pub const ConnMapping = std.AutoArrayHashMap(std.posix.socket_t, *NetConn);

pub const String = struct {
    content: []const u8,

    pub fn init(allocator: std.mem.Allocator, content: []const u8) !String {
        const bytes: []u8 = try allocator.alloc(u8, content.len);
        errdefer allocator.free(bytes);

        @memcpy(bytes, content);
        return .{ .content = bytes };
    }

    pub fn deinit(self: *const String, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};
