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

pub const Integer = struct {
    content: u64,
    node: Node,
};

pub const Node = struct {
    next: ?*Node = null,
};

pub fn list_size(root_node: *const Node) !usize {
    var current_node: ?*Node = @constCast(root_node);
    var len: usize = 0;

    while (current_node) |node| {
        current_node = node.next;
        len += 1;
        if (current_node == root_node) {
            return error.CircularReference;
        }
    }

    return len;
}

pub fn container(comptime V: type) type {
    return struct {
        pub fn of(
            node: *const V,
            comptime T: type,
            comptime field_name: []const u8,
        ) *T {
            const offset = @offsetOf(T, field_name);
            const raw_node_ptr: [*]u8 = @ptrCast(@constCast(node));
            const ptr: *T = @alignCast(@ptrCast(raw_node_ptr - offset));
            return ptr;
        }
    };
}

test "data from node" {
    const int = Integer{
        .content = 123,
        .node = .{},
    };

    const ptr = container(Node).of(
        &int.node,
        Integer,
        "node",
    );

    try std.testing.expectEqual(ptr, &int);
    try std.testing.expectEqual(int.node.next, null);
}

test "linked list length" {
    var a = Node{};
    var b = Node{
        .next = &a,
    };

    try std.testing.expectEqual(2, list_size(&b));

    a.next = &b;

    try std.testing.expectError(error.CircularReference, list_size(&b));
}
