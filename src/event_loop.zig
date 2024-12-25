const std = @import("std");

const EPOLL = std.os.linux.EPOLL;
const POLL = std.posix.POLL;

const TIMEOUT_MS = 1000;
const MAX_EVENTS = 10;

const EpollEventLoop = struct {
    epoll_fd: i32 = undefined,
    events: [MAX_EVENTS]std.os.linux.epoll_event = undefined,

    pub fn init(self: *EpollEventLoop) !void {
        self.epoll_fd = try std.posix.epoll_create1(0);
    }

    pub fn wait_for_events(self: *EpollEventLoop) !usize {
        const ready_events = std.posix.epoll_wait(
            self.epoll_fd,
            &self.events,
            TIMEOUT_MS,
        );

        return ready_events;
    }

    pub fn register_client_event(self: *const EpollEventLoop, client_fd: std.posix.socket_t) !void {
        var epoll_event = std.os.linux.epoll_event{
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
        var listen_event = std.os.linux.epoll_event{
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

pub fn create_epoll_loop(server: *std.net.Server) !EpollEventLoop {
    var new_loop = EpollEventLoop{};
    try new_loop.init();
    try new_loop.register_server_event(server.stream.handle);
    return new_loop;
}

const KqueueEventLoop = struct {
    kqueue_fd: i32,

    pub fn init(self: *KqueueEventLoop) !void {
        self.kqueue_fd = try std.posix.kqueue();
    }

    pub fn wait_for_events(self: *KqueueEventLoop) !usize {

        
        const ready_events = std.posix.epoll_wait(
            self.epoll_fd,
            &self.events,
            TIMEOUT_MS,
        );

        return ready_events;
    }

    pub fn register_client_event(self: *const KqueueEventLoop, client_fd: std.posix.socket_t) !void {
        var epoll_event = std.os.linux.epoll_event{
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

    pub fn register_server_event(self: *const KqueueEventLoop, server_fd: std.posix.socket_t) !void {
        // Add server event to poll state

        std.posix.kevent(self.kqueue_fd, changelist: []const Kevent, eventlist: []Kevent, TIMEOUT_MS)

        var listen_event = std.posix.Kevent{
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
