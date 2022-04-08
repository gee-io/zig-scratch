const std = @import("std");
const os = std.os;
const tcp = std.x.net.tcp;
const ip = std.x.net.ip;
const net = std.net;
const linux = std.os.linux;
const IPv4 = std.x.os.IPv4;
const Socket = std.x.os.Socket;
const fd_t = linux.fd_t;
const IO_Uring = linux.IO_Uring;
const io_uring_sqe = linux.io_uring_sqe;
const IORING_OP = std.os.linux.IORING_OP;
const assert = std.debug.assert;

const uring = @import("./ring.zig")

const Server = struct {
    const Self = @This();
    ring: IO_Uring,

    fn init(ring: IO_Uring) Server {
        return Server{
            .ring = ring,
        };
    }

    fn deinit(self: *Self) void {
        self.ring.deinit();
    }

    fn prep_accept(self: *Self, socket: fd_t, flags: std.enums.EnumFieldStruct(Socket.InitFlags, bool, false)) !*io_uring_sqe {
        var raw_flags: u32 = 0;
        const set = std.EnumSet(Socket.InitFlags).init(flags);
        if (set.contains(.close_on_exec)) raw_flags |= linux.SOCK.CLOEXEC;
        if (set.contains(.nonblocking)) raw_flags |= linux.SOCK.NONBLOCK;

        return self.ring.accept(@bitCast(u64, Handle.accept()), socket, null, null, raw_flags);
    }

    fn prep_provide_buffers(self: *Self, num_bufs: i32, base_addr: [*]u8, buf_len: usize, group_id: u16, buf_id: u64) !*io_uring_sqe {
        const sqe = try self.ring.get_sqe();
        linux.io_uring_prep_rw(.PROVIDE_BUFFERS, sqe, num_bufs, @ptrToInt(base_addr), buf_len, buf_id);
        sqe.buf_index = group_id; // this is really the buf_group;
        sqe.user_data = @bitCast(u64, Handle{
            .op = .PROVIDE_BUFFERS,
        });

        return sqe;
    }

    const BufOptions = union(enum) {
        select: struct {
            buf_group: u16,
        },
    };

    fn prep_recv(self: *Self, fd: fd_t, len: usize, buf_opts: BufOptions) !*io_uring_sqe {
        const sqe = try self.ring.get_sqe();

        switch (buf_opts) {
            // TODO: handle non-provided buffers.
            .select => |b| {
                linux.io_uring_prep_rw(.RECV, sqe, fd, 0, len, 0);
                sqe.user_data = @bitCast(u64, Handle.recv(fd, b.buf_group));
                sqe.flags = linux.IOSQE_BUFFER_SELECT;
                sqe.buf_index = b.buf_group; // this is really the buf_group;
            },
        }

        return sqe;
    }
};

pub fn BufferGroup(comptime init_num_bufs: usize, comptime each_buf_size: usize) type {
    return struct {
        // bufs: std.ArrayListAlignedUnmanaged(T, [each_buf_size]u8) = .{},
        bufs: [init_num_bufs][each_buf_size]u8 = undefined,
        const Self = @This();
    };
}
///
/// A TCP listener.
pub fn main() !void {
    const address = ip.Address.initIPv4(try IPv4.parse("127.0.0.1"), 3131);
    var listener = try tcp.Listener.init(.ip, .{
        .close_on_exec = true,
        .nonblocking = false,
    });

    defer listener.deinit();
    try listener.bind(address);
    try listener.listen(1);

    var server: Server = .{
        .ring = try linux.IO_Uring.init(256, 0),
    };
    defer server.deinit();
    var need_accept = true;

    const BUF_COUNT = 16;
    const BUF_SIZE = 4096;
    const BUF_GROUP = 36;
    var bufs: [BUF_COUNT][BUF_SIZE]u8 = undefined;
    {
        _ = try server.prep_provide_buffers(bufs.len, &bufs[0], BUF_SIZE, BUF_GROUP, 0);
    }

    while (true) {
        if (need_accept) {
            std.log.info("queue accept", .{});

            _ = try server.prep_accept(listener.socket.fd, .{
                .close_on_exec = true,
                .nonblocking = false,
            });
            need_accept = false;
        }

        const nsqe_submitted = try server.ring.submit_and_wait(1);
        std.log.info("nsqe_submitted: {}", .{nsqe_submitted});

        const cqe = try server.ring.copy_cqe();

        const handle = @bitCast(Handle, cqe.user_data);
        switch (handle.op) {
            .ACCEPT => {
                need_accept = true;
                const client_fd = cqe.res;
                const client_addr = Socket.Address.fromNative(@ptrCast(*os.sockaddr, &server.accept_state.addr));

                // new accepted connection.
                std.log.info("accept: {}", .{client_addr});
                _ = try server.prep_recv(client_fd, BUF_SIZE, .{
                    .select = .{
                        .buf_group = BUF_GROUP,
                    },
                });
            },
            .READ, .RECV => {
                // linux.io_uring_prep_recv
                const bytes_read = cqe.res;
                const is_fixed_buf = cqe.flags & linux.IORING_CQE_F_BUFFER == 1;
                const buf_id = cqe.flags >> 16; // IORING_CQE_BUFFER_SHIFT

                const data = bufs[buf_id][0..@intCast(usize, bytes_read)];
                std.log.info("read {} {s}", .{ bytes_read, data });

                // Give the buf back.
                if (is_fixed_buf) {
                    _ = try server.prep_provide_buffers(1, &bufs[buf_id], BUF_SIZE, BUF_GROUP, buf_id);

                    // const sqe = try ring.get_sqe();
                    // linux.io_uring_prep_rw(.PROVIDE_BUFFERS, sqe, 1, @ptrToInt(&bufs[buf_id][0]), BUF_SIZE, buf_id);
                    // sqe.buf_index = BUF_GROUP; // this is really the buf_group;
                    // sqe.user_data = @bitCast(u64, Handle{
                    //     .op = .PROVIDE_BUFFERS,
                    // });
                }
            },
            // .PROVIDE_BUFFERS =>
            else => {
                std.log.info("state unhandled {}", .{handle});
            },
        }
    }
}
