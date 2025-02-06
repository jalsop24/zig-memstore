const std = @import("std");
const NetConn = @import("NetConn.zig");

const Allocator = std.mem.Allocator;

pub const Mapping = HashTable;
pub const ConnMapping = std.AutoArrayHashMap(std.posix.socket_t, *NetConn);

pub const String = struct {
    content: []const u8,

    pub fn init(allocator: Allocator, content: []const u8) Allocator.Error!String {
        const bytes: []u8 = try allocator.alloc(u8, content.len);
        errdefer allocator.free(bytes);

        @memcpy(bytes, content);
        return .{ .content = bytes };
    }

    pub fn deinit(self: *const String, allocator: Allocator) void {
        allocator.free(self.content);
    }

    pub fn clone(self: *const String, allocator: Allocator) Allocator.Error!String {
        return String.init(allocator, self.content);
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

pub const KVPair = struct {
    key: String,
    value: String,
};

const Entry = struct {
    key: String,
    value: String,
    node: HashNode,

    pub fn kv_pair(self: *Entry) KVPair {
        return .{
            .key = self.key,
            .value = self.value,
        };
    }
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
    allocator: Allocator,
    slots: []?*HashNode,
    mask: HashType,
    size: u32,

    const Self = @This();

    const HashType = u32;
    const EqFunc = *const fn (*const HashNode, *const HashNode) bool;

    pub const Iterator = struct {
        pos: u32,
        current_node: ?*HashNode,
        h_table: *const HashTable,

        pub fn next_entry(self: *Iterator) ?*Entry {
            if (self.current_node) |node| {
                self.current_node = node.next;
                return node.entry();
            }

            const start = self.pos;
            if (start >= self.h_table.slots.len) {
                return null;
            }

            for (start..self.h_table.slots.len) |i| {
                const node = self.h_table.slots[i];
                if (node) |head| {
                    self.pos = @intCast(i + 1);
                    self.current_node = head.next;
                    return head.entry();
                }
            }

            return null;
        }

        pub fn next(self: *Iterator) ?KVPair {
            if (self.next_entry()) |entry| {
                return entry.kv_pair();
            }

            return null;
        }
    };

    pub fn init(alloc: Allocator) !*HashTable {
        const n_slots = 8;

        std.debug.assert(n_slots % 2 == 0);
        const slots = try alloc.alloc(?*HashNode, n_slots);
        errdefer alloc.free(slots);

        for (0..n_slots) |i| {
            slots[i] = null;
        }

        const h_table = try alloc.create(HashTable);
        h_table.* = .{
            .allocator = alloc,
            .slots = slots,
            .mask = n_slots - 1,
            .size = 0,
        };

        return h_table;
    }

    pub fn deinit(self: *Self) void {
        var iter = self.iterator();
        while (iter.next_entry()) |entry| {
            entry.key.deinit(self.allocator);
            entry.value.deinit(self.allocator);
            self.allocator.destroy(entry);
        }
        self.allocator.free(self.slots);
        self.allocator.destroy(self);
    }

    pub fn put(self: *Self, key: String, value: String) Allocator.Error!void {
        const existing_node = self.lookup_node(&.{
            .hash_code = string_hash(key),
        });

        if (existing_node) |node| {
            var entry = node.entry();
            entry.value.deinit(self.allocator);
            entry.value = try value.clone(self.allocator);
            return;
        }

        const new_entry = try self.allocator.create(Entry);
        new_entry.* = .{
            .key = try key.clone(self.allocator),
            .value = try value.clone(self.allocator),
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

    pub fn remove(self: *Self, key: String) void {
        const dummy_entry = Entry{
            .key = key,
            .value = .{ .content = "" },
            .node = .{ .hash_code = string_hash(key) },
        };
        const node = self.lookup_node(&dummy_entry.node);

        if (node == null) return;
        const found_node = node.?;

        const entry = found_node.entry();
        entry.key.deinit(self.allocator);
        entry.value.deinit(self.allocator);

        self.remove_node(found_node);

        self.allocator.destroy(entry);
    }

    pub fn iterator(self: *const Self) Iterator {
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
            if (current_node.hash_code == node.hash_code and string_eq(current_node, node)) {
                break;
            }
            from_node = &current_node.next;
        }

        return from_node;
    }
};

/// Simple FNV hash function
/// see https://en.wikipedia.org/wiki/Fowler%E2%80%93Noll%E2%80%93Vo_hash_function#FNV-1a_hash
fn string_hash(string: String) HashTable.HashType {
    return std.hash.Fnv1a_32.hash(string.content);
}

fn string_eq(a: *const HashNode, b: *const HashNode) bool {
    const entry_a = a.entry();
    const entry_b = b.entry();
    return std.mem.eql(u8, entry_a.key.content, entry_b.key.content);
}

test "hashtable" {
    const alloc = std.testing.allocator;

    var hash_table = try HashTable.init(alloc);
    defer {
        alloc.free(hash_table.slots);
        alloc.destroy(hash_table);
    }

    var node: HashNode = .{ .hash_code = 0 };
    hash_table.insert_node(&node);
    try std.testing.expect(hash_table.size == 1);

    const found = hash_table.lookup_node(&node);
    try std.testing.expect(found.? == &node);

    var node_b: HashNode = .{ .hash_code = 16 };
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

test "string methods" {
    const alloc = std.testing.allocator;

    var hash_table = try HashTable.init(alloc);
    defer hash_table.deinit();

    const key: String = .{ .content = "a" };
    const value: String = .{ .content = "b" };
    try std.testing.expect(hash_table.get(key) == null);

    try hash_table.put(key, value);

    try std.testing.expect(hash_table.size == 1);
    try std.testing.expectEqualStrings("b", hash_table.get(key).?.content);

    var iter = hash_table.iterator();
    var count: u32 = 0;
    while (iter.next() != null) {
        count += 1;
    }

    try std.testing.expect(count == 1);

    hash_table.remove(key);

    try std.testing.expect(hash_table.size == 0);
}
