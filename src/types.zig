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

/// For use with intrusive data structures. `node` must be embedded within an instance of the type `T`
pub fn container_of(
    node: anytype,
    comptime T: type,
    comptime field_name: []const u8,
) *T {
    const offset = @offsetOf(T, field_name);
    const raw_node_ptr: [*]u8 = @ptrCast(@constCast(node));
    const ptr: *T = @alignCast(@ptrCast(raw_node_ptr - offset));
    return ptr;
}

test "data from node" {
    const TestNode = struct {
        _: u8 = undefined,
    };

    const Container = struct {
        node: TestNode,
    };

    const container = Container{
        .node = .{},
    };

    const ptr = container_of(
        &container.node,
        Container,
        "node",
    );

    try std.testing.expectEqual(ptr, &container);
}

const Entry = struct {
    key: String,
    value: String,
    node: HashNode,
};

const HashNode = struct {
    next: ?*HashNode = null,
    hash_code: HashTable.HashType,

    pub inline fn entry(
        self: *const HashNode,
    ) *Entry {
        return container_of(self, Entry, "node");
    }
};

const HashTable = struct {
    alloc: std.mem.Allocator,
    slots: []?*HashNode,
    mask: HashType,
    size: u32,
    eq: EqFunc,

    const Self = @This();

    const HashType = u32;
    const EqFunc = *const fn (*const HashNode, *const HashNode) bool;

    const Iterator = struct {
        pos: u32,
        current_node: ?*HashNode,
        h_table: *const HashTable,

        pub fn next(self: *Iterator) ?*Entry {
            if (self.current_node) |node| {
                self.current_node = node.next;
                return node.entry();
            }

            const start = self.pos;
            for (start.., self.h_table.slots[start..]) |i, node| {
                if (node) |head| {
                    self.pos = @intCast(i + 1);
                    self.current_node = head.next;
                    return head.entry();
                }
            }

            return null;
        }
    };

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

    pub fn deinit(self: Self) void {
        var iter = self.entries();
        while (iter.next()) |entry| {
            self.alloc.destroy(entry);
        }
        self.alloc.free(self.slots);
    }

    pub fn put(self: *Self, key: String, value: String) !void {
        const existing_node = self.lookup_node(&.{
            .hash_code = string_hash(key),
        });

        if (existing_node) |node| {
            var entry = node.entry();
            entry.value = value;
            return;
        }

        const new_entry = try self.alloc.create(Entry);
        new_entry.* = .{
            .key = key,
            .value = value,
            .node = .{ .hash_code = string_hash(key) },
        };

        self.insert_node(&new_entry.node);
    }

    pub fn get(self: *Self, key: String) ?String {
        const dummy_entry = Entry{
            .key = key,
            .value = .{ .content = "" },
            .node = .{ .hash_code = string_hash(key) },
        };
        const node = self.lookup_node(&dummy_entry.node);

        if (node) |found_node| {
            const entry = found_node.entry();
            return entry.value;
        }

        return null;
    }

    pub fn entries(self: *const Self) Iterator {
        return .{
            .h_table = self,
            .pos = 0,
            .current_node = null,
        };
    }

    inline fn hash(self: *Self, value: HashType) HashType {
        return self.mask & value;
    }

    pub fn insert_node(self: *Self, node: *HashNode) void {
        const pos = self.hash(node.hash_code);

        node.next = self.slots[pos];
        self.slots[pos] = node;
        self.size += 1;
    }

    pub fn lookup_node(self: *Self, node: *const HashNode) ?*HashNode {
        const parent = self.lookup_parent(node);
        return parent.*;
    }

    pub fn remove_node(self: *Self, node: *HashNode) void {
        const from = self.lookup_parent(node);
        const target = from.*;
        if (target == null) {
            return;
        }

        from.* = target.?.next;
        self.size -= 1;
    }

    fn lookup_parent(self: *Self, node: *const HashNode) *?*HashNode {
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

fn string_hash(string: String) HashTable.HashType {
    var out_buf: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(string.content, &out_buf, .{});
    return std.mem.readPackedInt(HashTable.HashType, out_buf[0..4], 0, .little);
}

fn test_eq(a: *const HashNode, b: *const HashNode) bool {
    return a.hash_code == b.hash_code;
}

fn string_eq(a: *const HashNode, b: *const HashNode) bool {
    const entry_a = a.entry();
    const entry_b = b.entry();
    return std.mem.eql(u8, entry_a.key.content, entry_b.key.content);
}

test "hashtable" {
    const alloc = std.testing.allocator;

    const slots = 16;
    var hash_table = try HashTable.init(alloc, slots, &test_eq);
    defer alloc.free(hash_table.slots);

    var node: HashNode = .{ .hash_code = 0 };
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

test "hashtable string methods" {
    const alloc = std.testing.allocator;

    const slots = 16;
    var hash_table = try HashTable.init(alloc, slots, &string_eq);
    defer hash_table.deinit();

    const key: String = .{ .content = "a" };
    const value: String = .{ .content = "b" };
    try std.testing.expect(hash_table.get(key) == null);

    try hash_table.put(key, value);

    try std.testing.expect(hash_table.size == 1);
    try std.testing.expectEqualStrings("b", hash_table.get(key).?.content);

    var iter = hash_table.entries();
    var count: u32 = 0;
    while (iter.next() != null) {
        count += 1;
    }

    try std.testing.expect(count == 1);
}
