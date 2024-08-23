const std = @import("std");

pub fn main() !void {
    const localhost = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 9876);

    const stream = try std.net.tcpConnectToAddress(localhost);
    defer stream.close();
    std.log.info("Connecting to {}\n", .{localhost});

    const data = "Hello zig!";
    var writer = stream.writer();
    const size = try writer.write(data);
    std.log.info("Sending '{s}' to server, total sent: {d} bytes\n", .{ data, size });
}
