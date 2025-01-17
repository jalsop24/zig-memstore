const std = @import("std");
const NetConn = @import("NetConn.zig");

pub const MainMapping = std.StringArrayHashMap(*String);
pub const ConnMapping = std.AutoArrayHashMap(std.posix.socket_t, *NetConn);

pub const String = struct {
    content: []u8,

    pub fn init(allocator: std.mem.Allocator, content: []const u8) !*String {
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
