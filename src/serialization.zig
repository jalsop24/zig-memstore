const std = @import("std");

const types = @import("types.zig");
const Object = types.Object;

pub const EncodeError = error{BufferTooSmall};

const StringLen = u16;
const ArrayLen = u16;

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
        .little,
    );
    return int_size;
}

fn ensureBufferLength(buf: []u8, len: usize) EncodeError!void {
    if (buf.len < len) return EncodeError.BufferTooSmall;
}

test "serializers" {
    var buf: [30]u8 = undefined;

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
