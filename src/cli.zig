const std = @import("std");

pub fn getPortFromArgs(args: *std.process.ArgIterator) !u16 {
    const raw_port = args.next() orelse {
        std.log.info("Expected port as a command line argument", .{});
        return error.NoPort;
    };
    return try std.fmt.parseInt(u16, raw_port, 10);
}

pub fn getAddressFromArgs(args: *std.process.ArgIterator) !std.net.Address {
    const raw_sock_addr = args.next() orelse {
        std.log.info("Expected address / port as a command line argument", .{});
        return error.NoAddress;
    };

    var i: usize = 0;
    for (raw_sock_addr, 0..) |char, j| {
        if (char == ':') {
            i = j;
            break;
        }
    }

    const raw_port = raw_sock_addr[i + 1 ..];
    const port = try std.fmt.parseInt(u16, raw_port, 10);
    return std.net.Address.parseIp4(raw_sock_addr[0..i], port);
}
