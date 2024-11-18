const std = @import("std");

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
