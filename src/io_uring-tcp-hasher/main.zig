const std = @import("std");
const net = std.net;
const os = std.os;
const linux = os.linux;
const io_uring_sqe = linux.io_uring_sqe;
const io_uring_cqe = linux.io_uring_cqe;
const assert = std.debug.assert;

const Server = struct {
    ring: linux.IO_Uring,

    fn q_accept(
        self: *Server,
        user_data: u64,
        /// This argument is a socket that has been created with `socket`, bound to a local address
        /// with `bind`, and is listening for connections after a `listen`.
        sock: os.socket_t,
        /// This argument is a pointer to a sockaddr structure.  This structure is filled in with  the
        /// address  of  the  peer  socket, as known to the communications layer.  The exact format of the
        /// address returned addr is determined by the socket's address  family  (see  `socket`  and  the
        /// respective  protocol  man  pages).
        addr: *os.sockaddr,
        /// This argument is a value-result argument: the caller must initialize it to contain  the
        /// size (in bytes) of the structure pointed to by addr; on return it will contain the actual size
        /// of the peer address.
        ///
        /// The returned address is truncated if the buffer provided is too small; in this  case,  `addr_size`
        /// will return a value greater than was supplied to the call.
        addr_size: *os.socklen_t,
        /// The following values can be bitwise ORed in flags to obtain different behavior:
        /// * `SOCK.NONBLOCK` - Set the `O.NONBLOCK` file status flag on the open file description (see `open`)
        ///   referred  to by the new file descriptor.  Using this flag saves extra calls to `fcntl` to achieve
        ///   the same result.
        /// * `SOCK.CLOEXEC`  - Set the close-on-exec (`FD_CLOEXEC`) flag on the new file descriptor.   See  the
        ///   description  of the `O.CLOEXEC` flag in `open` for reasons why this may be useful.
        flags: u32,
    ) !*io_uring_sqe {
        return try self.ring.accept(user_data, sock, addr, addr_size, flags);
    }

    fn q_tick(self: *Server) !*io_uring_sqe {
        const sqe_tick = try self.ring.nop(33);
        sqe_tick.flags |= linux.IOSQE_IO_LINK;
        const ts = os.linux.kernel_timespec{ .tv_sec = 0, .tv_nsec = 1000000 };
        return try self.ring.link_timeout(66, &ts, 0);
    }
};

const Op = union(enum) {
    accept: struct {
        sock: os.socket_t,
        flags: u32 = os.SOCK.CLOEXEC | os.SOCK.NONBLOCK,
        addr: os.sockaddr = undefined,
        addr_size: os.socklen_t = @sizeOf(os.sockaddr),
    },

    fn prep(self: Op, ring: linux.IO_Uring, user_data: u64) !*io_uring_sqe {
        switch (self) {
            .accept => |*c| {
                return try ring.accept(user_data, c.sock, c.addr, c.addr_size, c.flags);
            },
        }
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

    // // var cqes: [128]io_uring_cqe = undefined;
    // std.time.Timer
    // linux.timerfd_create(linux.CLOCK.MONOTONIC, flags: u32);

    var cqes: [16]io_uring_cqe = undefined;
    var pending = try std.BoundedArray(Op, 256).init(0);

    {
        const idx_accept = pending.len;
        try pending.append(Op{ .accept = .{ .sock = listen_socket } });
        try pending.get(idx_accept).prep(ring, idx_accept);
    }
    // _ = try ring.accept(accept_competion_idx, listen_socket, &peer_addr.any, &peer_addr_size, os.SOCK.CLOEXEC | os.SOCK.NONBLOCK);

    // completions.addOne()
    while (true) {
        const nsubmit = try ring.submit();
        const ncqe = try ring.copy_cqes(&cqes, 1);

        std.log.info("loop: nsubmit={} ncqe={}\n", .{ nsubmit, ncqe });

        for (cqes[0..ncqe]) |cqe| {
            const op_idx = cqe.user_data;
            const op = pending.get(op_idx);
            switch (op) {
                .accept => |accept| {
                    std.log.info("{}", .{accept});
                    try op.prep(ring, op_idx);
                },
            }

            //  switch (cqe.err()) {
            //         .SUCCESS => {},
            //         else => |errno| std.debug.panic("unhandled errno: {}", .{errno}),
            //     }
            std.log.info("cqe: {}", .{cqe});
        }
    }

    // submit: non-blocking

}
