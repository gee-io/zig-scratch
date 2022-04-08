const std = @import("std");
const net = std.net;
const os = std.os;
const linux = os.linux;
const io_uring_sqe = linux.io_uring_sqe;
const io_uring_cqe = linux.io_uring_cqe;
const assert = std.debug.assert;

const Conn = struct {
    // TODO std.x.os.Socket
    addr: os.sockaddr = undefined,
    addr_len: os.socklen_t = @sizeOf(os.sockaddr),
};

const Op = union(enum) {
    accept: struct {
        addr: os.sockaddr = undefined,
        addr_len: os.socklen_t = @sizeOf(os.sockaddr),
    },
    epoll: struct { fd: os.fd_t },

    close: struct {
        fd: os.fd_t,
    },
    connect: struct {
        sock: os.socket_t,
        address: std.net.Address,
    },
    fsync: struct {
        fd: os.fd_t,
    },
    read: struct {
        fd: os.fd_t,
        buffer: []u8,
        offset: u64,
    },
    recv: struct {
        sock: os.socket_t,
        buffer: []u8,
    },
    send: struct {
        sock: os.socket_t,
        buffer: []const u8,
    },
    timeout: struct {
        timespec: os.linux.kernel_timespec,
    },
    write: struct {
        fd: os.fd_t,
        buffer: []const u8,
        offset: u64,
    },
};

const Completion = struct {
    op: Op,
};

const Server = struct {
    ring: linux.IO_Uring,
    listen_fd: os.socket_t,
    epoll_fd: os.fd_t,

    fn q_accept(self: *Server, completion: *Completion) !*io_uring_sqe {
        completion.op = .{ .accept = .{ .sock = self.listen_fd } };
        return try self.ring.accept(@ptrToInt(completion), self.listen_fd, &completion.op.accept.addr, &completion.op.accept.addr_len, os.SOCK.NONBLOCK | os.SOCK.CLOEXEC);
    }
};

pub fn main() !void {
    const LISTEN_BACKLOG = 1;
    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const listen_socket = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    defer os.closeSocket(listen_socket);
    // try os.setsockopt(listen_socket, os.SOL.SOCKET, os.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try os.bind(listen_socket, &address.any, address.getOsSockLen());
    try os.listen(listen_socket, LISTEN_BACKLOG);

    var ring = try std.os.linux.IO_Uring.init(256, 0);
    defer ring.deinit();

    var epoll_fd = try os.epoll_create1(os.linux.EPOLL.CLOEXEC);
    defer os.close(epoll_fd);

    // var server = Server{
    //     .ring = ring,
    //     .listen_fd = listen_socket,
    //     .epoll_fd = epoll_fd,
    // };

    var completions = [_]Completion{
        .{ .op = .{ .accept = .{} } },
        .{ .op = .{ .epoll = .{ .fd = epoll_fd } } },
    };

    var accept_completion = &completions[0];
    var epoll_completion = &completions[1];

    // // notify when we need accept.
    var epoll_event = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.ONESHOT,
        .data = linux.epoll_data{ .ptr = 0 },
    };

    // os.epoll_ctl(epfd: i32, op: u32, fd: i32, event: ?*linux.epoll_event)

    _ = try ring.epoll_ctl(@ptrToInt(epoll_completion), epoll_fd, listen_socket, os.linux.EPOLL.CTL_ADD, &epoll_event);

    var events: [128]linux.epoll_event = undefined;
    var cqes: [128]io_uring_cqe = undefined;

    while (true) {
        const nsubmit = try ring.submit_and_wait(1);

        // consume epoll events: non-blocking
        const nevents = os.epoll_wait(epoll_fd, &events, 10);
        for (events[0..nevents]) |ev| {
            const is_error = ev.events & linux.EPOLL.ERR != 0;
            const is_hup = ev.events & (linux.EPOLL.HUP | linux.EPOLL.RDHUP) != 0;
            const is_readable = ev.events & linux.EPOLL.IN != 0;
            const is_writable = ev.events & linux.EPOLL.OUT != 0;

            std.log.info("is_error={} is_readable={} is_writable={} is_hup={} \n", .{ is_error, is_readable, is_writable, is_hup });

            // accept new connections.
            if (ev.data.fd == listen_socket) {
                // CTL_MOD to re-arm the listen_socket for new accepts.
                // _ = try ring.epoll_ctl(@ptrToInt(epoll_completion), epoll_fd, listen_socket, os.linux.EPOLL.CTL_MOD, &epoll_event);

                _ = try ring.accept(
                    @ptrToInt(accept_completion),
                    listen_socket,
                    &accept_completion.op.accept.addr,
                    &accept_completion.op.accept.addr_len,
                    os.SOCK.NONBLOCK | os.SOCK.CLOEXEC,
                );
            }
        }

        // submit: non-blocking

        std.log.info("loop: nsubmit={} nevents={}\n", .{ nsubmit, nevents });

        const nr = try ring.copy_cqes(&cqes, 0);
        for (cqes[0..nr]) |cqe, i| {
            switch (cqe.err()) {
                .SUCCESS => {},
                else => |errno| std.debug.panic("unhandled errno: {}", .{errno}),
            }

            const c = @intToPtr(*Completion, cqe.user_data);
            switch (c.op) {
                .epoll => {},
                .accept => {
                    std.log.info("accept: {}", .{c.op.accept.addr});
                },
                else => |op| std.log.warn("unhandled op: {}", .{op}),
            }
            std.log.info("cqe: {} {} {}\n", .{ cqe, c.op, i });

            // on_epoll: oneshot re-arm
            // on_accept: add fd to epoll, on epoll read everything.
        }
    }
}
