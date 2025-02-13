const std = @import("std");

const types = @import("types.zig");
const Object = types.Object;

pub const EncodeError = error{BufferTooSmall};
pub const DecodeError = error{ InvalidType, BufferTooSmall, OutOfMemory };

const StringLen = u16;
const ArrayLen = u16;

const ENDIAN = std.builtin.Endian.little;

pub const Encoder = struct {
    buf: []u8,
    written: usize = 0,

    const Self = @This();

    pub fn encodeObject(self: *Self, object: Object) EncodeError!usize {
        var written = try self.encodeTag(object);

        switch (object) {
            .nil => {}, // No-op for nil
            .integer => |integer| written += try self.encodeInteger(integer),
            .double => |double| written += try self.encodeDouble(double),
            .string => |string| written += try self.encodeString(string),
            .array => |array| written += try self.encodeArray(array),
        }

        return written;
    }

    pub fn encodeTag(self: *Self, object: Object) EncodeError!usize {
        const TagType = @typeInfo(Object).@"union".tag_type.?;
        std.debug.assert(@sizeOf(TagType) == 1);

        const buf = self.w_buf();
        try ensureBufferLength(buf, 1);
        buf[0] = @intFromEnum(object);
        return self.update(1);
    }

    pub fn encodeString(self: *Self, string: types.String) EncodeError!usize {
        const buf = self.w_buf();
        const string_len = string.content.len;

        const header_size = try encodeGenericInteger(
            StringLen,
            @intCast(string_len),
            buf,
        );
        @memcpy(buf[header_size..][0..string_len], string.content);

        return self.update(header_size + string_len);
    }

    pub fn encodeInteger(self: *Self, integer: types.Integer) EncodeError!usize {
        return self.update(try encodeGenericInteger(
            types.Integer,
            integer,
            self.w_buf(),
        ));
    }

    pub fn encodeDouble(self: *Self, double: types.Double) EncodeError!usize {
        return self.update(try encodeGenericInteger(
            u64,
            @bitCast(double),
            self.w_buf(),
        ));
    }

    pub fn encodeArray(self: *Self, array: types.Array) EncodeError!usize {
        var written: usize = 0;
        written += self.update(try encodeGenericInteger(
            ArrayLen,
            @intCast(array.objects.len),
            self.w_buf(),
        ));

        for (array.objects) |object| {
            written += try self.encodeObject(object);
        }

        return written;
    }

    pub fn encodeCommand(self: *Self, command: types.Command) EncodeError!usize {
        return self.update(try encodeGenericInteger(
            @typeInfo(types.Command).@"enum".tag_type,
            @intFromEnum(command),
            self.w_buf(),
        ));
    }

    inline fn w_buf(self: *Self) []u8 {
        return self.buf[self.written..];
    }

    fn update(self: *Self, written: usize) usize {
        self.written += written;
        return written;
    }
};

pub fn serialize(object: Object, buf: []u8) EncodeError![]u8 {
    var encoder = Encoder{ .buf = buf };
    const written = try encoder.encodeObject(object);
    return buf[0..written];
}

pub fn encodeGenericInteger(comptime T: type, integer: T, buf: []u8) EncodeError!usize {
    const int_size = @sizeOf(T);
    try ensureBufferLength(buf, int_size);
    std.mem.writePackedInt(
        T,
        buf,
        0,
        integer,
        ENDIAN,
    );
    return int_size;
}

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    buf: []const u8,
    read: usize = 0,

    const Self = @This();

    pub fn decodeObject(self: *Self) DecodeError!Object {
        const tag = try self.decodeTag();

        switch (tag) {
            .nil => return Object{ .nil = .{} },
            .integer => return Object{ .integer = try self.decodeInteger() },
            .double => return Object{ .double = try self.decodeDouble() },
            .string => return Object{ .string = try self.decodeString() },
            .array => return Object{ .array = try self.decodeArray() },
        }
    }

    pub fn decodeTag(self: *Self) DecodeError!types.Tag {
        const int_type = @typeInfo(types.Tag).@"enum".tag_type;
        const int = try self.decodeGenericInteger(int_type);
        return std.meta.intToEnum(types.Tag, int) catch return DecodeError.InvalidType;
    }

    pub fn decodeCommand(self: *Self) DecodeError!types.Command {
        const int_type = @typeInfo(types.Command).@"enum".tag_type;
        const int = try self.decodeGenericInteger(int_type);
        return std.meta.intToEnum(types.Command, int) catch return DecodeError.InvalidType;
    }

    pub fn decodeInteger(self: *Self) DecodeError!types.Integer {
        return self.decodeGenericInteger(types.Integer);
    }

    pub fn decodeDouble(self: *Self) DecodeError!types.Double {
        const int = try self.decodeGenericInteger(u64);
        return @bitCast(int);
    }

    pub fn decodeString(self: *Self) DecodeError!types.String {
        const string_len = try self.decodeGenericInteger(StringLen);
        try self.ensureBufferLength(string_len);

        const content = self.r_buf()[0..string_len];
        self.read += string_len;

        return types.String{ .content = content };
    }

    pub fn decodeArray(self: *Self) DecodeError!types.Array {
        const array_len = try self.decodeGenericInteger(ArrayLen);
        const objects = self.allocator.alloc(Object, array_len) catch return DecodeError.OutOfMemory;
        for (0..array_len) |i| {
            objects[i] = try self.decodeObject();
        }

        return types.Array{ .objects = objects };
    }

    pub fn decodeGenericInteger(self: *Self, comptime T: type) DecodeError!T {
        try self.ensureBufferLength(@sizeOf(T));

        const int = std.mem.readPackedInt(T, self.r_buf(), 0, ENDIAN);
        self.read += @sizeOf(T);
        return int;
    }

    pub inline fn r_buf(self: *Self) []const u8 {
        return self.buf[self.read..];
    }

    fn ensureBufferLength(self: *Self, len: usize) DecodeError!void {
        if (self.r_buf().len < len) return DecodeError.BufferTooSmall;
    }
};

pub fn deserialize(allocator: std.mem.Allocator, buf: []u8) DecodeError!Object {
    var decoder = Decoder{
        .allocator = allocator,
        .buf = buf,
    };
    return try decoder.decodeObject();
}

fn ensureBufferLength(buf: []u8, len: usize) EncodeError!void {
    if (buf.len < len) return EncodeError.BufferTooSmall;
}

test "serializers" {
    var buf: [30]u8 = undefined;

    var encoder = Encoder{ .buf = &buf };
    _ = try encoder.encodeCommand(.Get);
    _ = try encoder.encodeCommand(.Set);
    _ = try encoder.encodeCommand(.Delete);
    _ = try encoder.encodeCommand(.List);
    const command_output = encoder.buf[0..encoder.written];
    try std.testing.expectEqualStrings(&.{ 1, 2, 3, 4 }, command_output);

    const nil_object = Object{ .nil = undefined };
    const nil_output = try serialize(nil_object, &buf);
    try std.testing.expectEqual(1, nil_output.len);
    try std.testing.expectEqualStrings(&.{0}, nil_output);

    const int_object = Object{ .integer = 20 };
    const int_output = try serialize(int_object, &buf);
    // 1 byte - tag
    // 8 bytes - u64
    try std.testing.expectEqual(9, int_output.len);
    try std.testing.expectEqualStrings(&.{ 1, 20, 0, 0, 0, 0, 0, 0, 0 }, int_output);

    const double_object = Object{ .double = 12.5 };
    const double_output = try serialize(double_object, &buf);
    // 1 byte - tag
    // 8 bytes - f64
    try std.testing.expectEqual(9, int_output.len);
    // 12.5 as an f64 - 0x4029_0000_0000_0000
    try std.testing.expectEqualStrings(&.{ 2, 0, 0, 0, 0, 0, 0, 0x29, 0x40 }, double_output);

    const string_object = Object{ .string = .{ .content = "hello" } };
    const string_output = try serialize(string_object, &buf);
    // 1 byte - tag
    // 2 bytes - string len
    // 5 bytes string
    try std.testing.expectEqual(8, string_output.len);
    try std.testing.expectEqualStrings(&.{ 3, 5, 0, 'h', 'e', 'l', 'l', 'o' }, string_output);

    const objects = [_]Object{ int_object, int_object, int_object };
    const array_object = Object{ .array = .{
        .objects = &objects,
    } };
    const array_output = try serialize(array_object, &buf);
    // 1 byte - tag
    // 2 bytes - array len
    // 27 = 3 * 9 = 3 * int objects
    try std.testing.expectEqual(30, array_output.len);
    try std.testing.expectEqualStrings(&.{
        // tag
        4,
        // Length
        3,
        0,
        // 1st int
        1,
        20,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        // 2nd int
        1,
        20,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        // 3rd int
        1,
        20,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
    }, array_output);
}

test "deserializers" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var buf_array: [100]u8 = undefined;
    const buf = &buf_array;

    var encoder = Encoder{ .buf = buf };
    var decoder = Decoder{ .allocator = allocator, .buf = buf };
    _ = try encoder.encodeCommand(.Get);
    const command = try decoder.decodeCommand();
    try std.testing.expectEqual(.Get, command);

    const objects = [_]Object{
        Object{ .nil = .{} },
        Object{ .integer = 12 },
        Object{ .double = 25.32 },
        Object{ .string = .{ .content = "abcdefg h" } },
        Object{ .array = .{ .objects = &.{
            Object{ .integer = 12 },
            Object{ .double = 25.32 },
            Object{ .double = 34.56 },
        } } },
    };

    for (objects) |object| {
        const encoded_object = try serialize(object, buf);
        const decoded_object = try deserialize(arena.allocator(), encoded_object);
        try expectEqualObjects(object, decoded_object);
    }
}

fn expectEqualObjects(expected: Object, actual: Object) !void {
    try std.testing.expectEqualStrings(@tagName(expected), @tagName(actual));
    switch (expected) {
        .nil => {},
        .integer => |integer| try std.testing.expectEqual(
            integer,
            actual.integer,
        ),
        .double => |double| try std.testing.expectEqual(
            double,
            actual.double,
        ),
        .string => |string| try std.testing.expectEqualStrings(
            string.content,
            actual.string.content,
        ),
        .array => |expected_array| {
            try std.testing.expectEqual(expected_array.objects.len, actual.array.objects.len);
            for (expected_array.objects, actual.array.objects) |expected_element, actual_element| {
                try expectEqualObjects(expected_element, actual_element);
            }
        },
    }
}
