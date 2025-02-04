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

pub const HashNode = struct {
    next: ?*HashNode = null,
    hash_code: HashTable.HashType = 0,
};

const HashTable = struct {
    alloc: std.mem.Allocator,
    slots: []?*HashNode,
    mask: HashType,
    size: u32,
    eq: EqFunc,

    const HashType = u32;
    const EqFunc = *const fn (*HashNode, *HashNode) bool;

    pub fn init(alloc: std.mem.Allocator, n_slots: u32, eq: EqFunc) !HashTable {
        std.debug.assert(n_slots % 2 == 0);
        const slots = try alloc.alloc(?*HashNode, n_slots);
        for (0..n_slots) |i| {
            slots[i] = null;
        }
        const mask = n_slots - 1;
        return .{
            .alloc = alloc,
            .slots = slots,
            .mask = mask,
            .size = 0,
            .eq = eq,
        };
    }

    pub fn deinit(self: HashTable) void {
        self.alloc.free(self.slots);
    }

    inline fn hash(self: *HashTable, value: HashType) HashType {
        return self.mask & value;
    }

    pub fn insert_node(self: *HashTable, node: *HashNode) void {
        const pos = self.hash(node.hash_code);

        node.next = self.slots[pos];
        self.slots[pos] = node;
        self.size += 1;
    }

    pub fn lookup_node(self: *HashTable, node: *HashNode) ?*HashNode {
        const parent = self.lookup_parent(node);
        return parent.*;
    }

    pub fn remove_node(self: *HashTable, node: *HashNode) void {
        const from = self.lookup_parent(node);
        const target = from.*;
        if (target == null) {
            return;
        }

        from.* = target.?.next;
        self.size -= 1;
    }

    fn lookup_parent(self: *HashTable, node: *HashNode) *?*HashNode {
        const pos = self.hash(node.hash_code);

        var from_node = &self.slots[pos];
        while (from_node.*) |current_node| {
            if (current_node.hash_code == node.hash_code and self.eq(current_node, node)) {
                break;
            }
            from_node = &current_node.next;
        }

        return from_node;
    }
};

fn test_eq(a: *HashNode, b: *HashNode) bool {
    return a.hash_code == b.hash_code;
}

test "hashtable" {
    const alloc = std.testing.allocator;

    const slots = 16;
    var hash_table = try HashTable.init(alloc, slots, &test_eq);
    defer hash_table.deinit();

    var node: HashNode = .{};
    hash_table.insert_node(&node);
    try std.testing.expect(hash_table.size == 1);

    const found = hash_table.lookup_node(&node);
    try std.testing.expect(found.? == &node);

    var node_b: HashNode = .{ .hash_code = slots };
    hash_table.insert_node(&node_b);
    try std.testing.expect(hash_table.size == 2);

    const found_a = hash_table.lookup_node(&node);
    const found_b = hash_table.lookup_node(&node_b);

    try std.testing.expect(found_a.? == &node);
    try std.testing.expect(found_b.? == &node_b);

    hash_table.remove_node(&node);
    try std.testing.expect(hash_table.lookup_node(&node) == null);
    try std.testing.expect(hash_table.size == 1);
}
