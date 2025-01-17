const std = @import("std");

const EPOLL = std.os.linux.EPOLL;
const POLL = std.posix.POLL;
pub const Event = std.os.linux.epoll_event;

const TIMEOUT_MS = 1000;
const MAX_EVENTS = 10;

pub const EpollEventLoop = struct {
    epoll_fd: i32 = undefined,
    events: [MAX_EVENTS]Event = undefined,

    pub fn init(self: *EpollEventLoop) !void {
        self.epoll_fd = try std.posix.epoll_create1(0);
    }

    pub fn wait_for_events(self: *EpollEventLoop) ![]Event {
        const ready_events = std.posix.epoll_wait(
            self.epoll_fd,
            &self.events,
            TIMEOUT_MS,
        );

        return self.events[0..ready_events];
    }

    pub fn register_client_event(self: *const EpollEventLoop, client_fd: std.posix.socket_t) !void {
        var epoll_event = Event{
            .events = POLL.IN,
            .data = .{
                .fd = client_fd,
            },
        };
        try std.posix.epoll_ctl(
            self.epoll_fd,
            EPOLL.CTL_ADD,
            client_fd,
            &epoll_event,
        );
    }

    pub fn register_server_event(self: *const EpollEventLoop, server_fd: std.posix.socket_t) !void {
        // Add server event to poll state
        var listen_event = Event{
            .events = POLL.IN,
            .data = .{
                .fd = server_fd,
            },
        };
        try std.posix.epoll_ctl(
            self.epoll_fd,
            EPOLL.CTL_ADD,
            server_fd,
            &listen_event,
        );
    }
};

pub fn create_epoll_loop() !EpollEventLoop {
    var new_loop = EpollEventLoop{};
    try new_loop.init();
    return new_loop;
}
