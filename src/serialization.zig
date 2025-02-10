const std = @import("std");

const types = @import("types.zig");
const Object = types.Object;

pub const EncodeError = error{BufferTooSmall};

const StringLen = u16;
const ArrayLen = u16;

pub fn serialize(buf: []u8, object: Object) EncodeError![]u8 {
    var written: usize = 0;
    written += try encodeTag(object, buf[written..]);
    written += try encodeObject(object, buf[written..]);
    return buf[0..written];
}

fn encodeObject(object: Object, buf: []u8) EncodeError!usize {
    // Encode specific type
    switch (object) {
        .nil => return 0, // No-op for nil
        .integer => |integer| return try encodeInteger(integer, buf),
        .double => |double| return try encodeDouble(double, buf),
        .string => |string| return try encodeString(string, buf),
        .array => |array| return try encodeArray(array, buf),
    }
}

fn encodeTag(object: Object, buf: []u8) EncodeError!usize {
    const TagType = @typeInfo(Object).@"union".tag_type.?;
    std.debug.assert(@sizeOf(TagType) == 1);

    try ensureBufferLength(buf, 1);
    buf[0] = @intFromEnum(object);
    return 1;
}

fn encodeInteger(integer: types.Integer, buf: []u8) EncodeError!usize {
    return try encodeIntegerUntagged(types.Integer, integer, buf);
}

fn encodeDouble(double: types.Double, buf: []u8) EncodeError!usize {
    return try encodeIntegerUntagged(u64, @bitCast(double), buf);
}

fn encodeString(string: types.String, buf: []u8) EncodeError!usize {
    const string_len = string.content.len;
    const header_size = try encodeIntegerUntagged(StringLen, @intCast(string_len), buf);

    @memcpy(buf[header_size..][0..string_len], string.content);
    return header_size + string_len;
}

fn encodeArray(array: types.Array, buf: []u8) EncodeError!usize {
    var written: usize = 0;
    written += try encodeIntegerUntagged(ArrayLen, @intCast(array.objects.len), buf);

    for (array.objects) |object| {
        const output = try serialize(buf[written..], object);
        written += output.len;
    }
    return written;
}

fn encodeIntegerUntagged(comptime T: type, integer: T, buf: []u8) EncodeError!usize {
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
    const nil_output = try serialize(&buf, nil_object);
    try std.testing.expectEqual(1, nil_output.len);
    try std.testing.expectEqualStrings(&.{0}, nil_output);

    const int_object = Object{ .integer = 20 };
    const int_output = try serialize(&buf, int_object);
    // 1 byte - tag
    // 8 bytes - u64
    try std.testing.expectEqual(9, int_output.len);
    try std.testing.expectEqualStrings(&.{ 1, 20, 0, 0, 0, 0, 0, 0, 0 }, int_output);

    const double_object = Object{ .double = 12.5 };
    const double_output = try serialize(&buf, double_object);
    // 1 byte - tag
    // 8 bytes - f64
    try std.testing.expectEqual(9, int_output.len);
    // 12.5 as an f64 - 0x4029_0000_0000_0000
    try std.testing.expectEqualStrings(&.{ 2, 0, 0, 0, 0, 0, 0, 0x29, 0x40 }, double_output);

    const string_object = Object{ .string = .{ .content = "hello" } };
    const string_output = try serialize(&buf, string_object);
    // 1 byte - tag
    // 2 bytes - string len
    // 5 bytes string
    try std.testing.expectEqual(8, string_output.len);
    try std.testing.expectEqualStrings(&.{ 3, 5, 0, 'h', 'e', 'l', 'l', 'o' }, string_output);

    const objects = [_]Object{ int_object, int_object, int_object };
    const array_object = Object{ .array = .{
        .objects = &objects,
    } };
    const array_output = try serialize(&buf, array_object);
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
