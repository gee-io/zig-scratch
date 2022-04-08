const std = @import("../../std.zig");
const builtin = @import("builtin");
const assert = std.debug.assert;
const mem = std.mem;
const net = std.net;
const os = std.os;
const linux = os.linux;
const testing = std.testing;

const Socket = std.x.os.Socket;

const io_uring_params = linux.io_uring_params;
const io_uring_sqe = linux.io_uring_sqe;
const io_uring_cqe = linux.io_uring_cqe;
const IO_Uring = linux.IO_Uring;
const IORING_OP = linux.IORING_OP;

pub const Handle = packed union {
    op: IORING_OP, // u8
    state_type: enum(u8) { fd, fd_and_buf_group },
    state: packed union {
        fd: os.fd_t,
        fd_and_buf_group: packed struct {
            fd: os.fd_t,
            buf_group: u16,
        },

        // for correct size
        bytes: [@sizeOf(u64) - 2]u8,
    },
};

pub const Conn = struct { fd: os.fd_t, rx_buf: std.x.os.Buffer };

pub fn StateType(comptime op: IORING_OP) type {
    switch (op) {
        .ACCEPT => {
            return struct {
                addr: os.sockaddr = undefined,
                addr_size: os.socklen_t = @sizeOf(os.sockaddr),
            };
        },
    }
}

pub fn Ring() type {
    return struct {
        const Self = @This();
        ring: *IO_Uring, // not-owned.

        pub fn init(ring: *IO_Uring) Self {
            return .{
                .ring = ring,
            };
        }

        const AcceptState = struct {
            addr: os.sockaddr = undefined,
            addr_size: os.socklen_t = @sizeOf(os.sockaddr),
        };
        pub fn prep_accept(
            self: Self,
            fd: fd_t,
            flags: u32,
            state: ?*StateType(.ACCEPT),
        ) !*io_uring_sqe {
            var addr_ptr: ?*os.sockaddr = null;
            var addr_size: ?*os.socklen_t = null;
            if (state) |s| {
                addr_ptr = s.addr;
                s.*.addr_size = @sizeOf(os.sockaddr);
                addr_size = s.addr_size;
            }
            return self.ring.accept(0, fd, addr_ptr, addr_size, flags);
        }
    };
}

pub const RingPld = struct {
    const Self = @This();
    ring: *IO_Uring,

    const AcceptOp = struct {
        pub const Flags = std.enums.EnumFieldStruct(Socket.InitFlags, bool, false);
        pub const State = struct {
            sock: os.socket_t,
            addr: ?*os.sockaddr = null,
            addr_size: ?*socklen_t = null,
        };

        pub fn prep(ring: *IO_Uring, sock: fd_t, flags: Flags) !*io_uring_sqe {
            var raw_flags: u32 = 0;
            const set = std.EnumSet(Socket.InitFlags).init(flags);
            if (set.contains(.close_on_exec)) raw_flags |= linux.SOCK.CLOEXEC;
            if (set.contains(.nonblocking)) raw_flags |= linux.SOCK.NONBLOCK;

            // linux.io_uring_prep_recv
            // get_accept_state
            const sqe = try ring.get_sqe();
            linux.io_uring_prep_accept(sqe, fd, null, null, raw_flags);
            sqe.user_data = @bitCast(u64, Handle{
                .op = .ACCEPT,
                .state_type = .fd,
                .state = .{
                    .fd = fd,
                },
            });
            return sqe;
        }
    };
};
