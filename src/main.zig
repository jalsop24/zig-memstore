const std = @import("std");
const cli = @import("cli.zig");
const event_loop = @import("event_loop.zig");
const Server = @import("server.zig").Server;
const types = @import("types.zig");

pub const std_options: std.Options = .{
    .log_level = .info,
};

// Function to manage CTRL + C
fn sigintHandler(sig: c_int) callconv(.C) void {
    _ = sig;
    std.debug.print("\nSIGINT received\n", .{});
    std.debug.panic("sigint panic", .{});
}

pub fn main() !void {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa_alloc.deinit() == .ok);
    const allocator = gpa_alloc.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip first argument (path to program)
    _ = args.skip();
    const port = try cli.getPortFromArgs(&args);

    const address = std.net.Address.initIp4(.{ 0, 0, 0, 0 }, port);
    var tcp_server = try address.listen(.{
        .force_nonblocking = true,
        .reuse_port = true,
    });
    defer tcp_server.deinit();

    std.log.info("Server v0.1 listening on port {}", .{address.getPort()});

    const act = std.os.linux.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = std.os.linux.empty_sigset,
        .flags = 0,
    };
    if (std.os.linux.sigaction(std.os.linux.SIG.INT, &act, null) != 0) {
        return error.SignalHandlerError;
    }

    var fd2conn = types.ConnMapping.init(allocator);
    defer {
        // Make sure to clean up any lasting connections before
        // deiniting the hashmap
        std.log.info("Clean up connections", .{});
        for (fd2conn.values()) |conn| {
            conn.connection().close();
            conn.deinit(allocator);
        }
        fd2conn.deinit();
    }

    var main_mapping = types.MainMapping.init(allocator);
    defer {
        for (main_mapping.keys(), main_mapping.values()) |key, val| {
            allocator.free(key);
            val.deinit(allocator);
        }
        main_mapping.deinit();
    }

    const server = Server{
        .handle = tcp_server.stream.handle,
        .conn_mapping = &fd2conn,
        .mapping = &main_mapping,
    };

    std.log.debug("Server fd {}\n", .{server.handle});
    try server.run();
}
