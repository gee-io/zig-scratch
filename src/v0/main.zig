const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const mem = std.mem;
const net = std.net;
const os = std.os;
const linux = os.linux;
const testing = std.testing;

const io_uring_params = linux.io_uring_params;
const io_uring_sqe = linux.io_uring_sqe;
const io_uring_cqe = linux.io_uring_cqe;

const TT = union {
    accept: void,
    read: os.fd_t,
};

const Token = packed struct {
    tag: enum(u16) {
        accept,
        read,
        read_fixed, // buf_idx
        write_fixed,
        write,
        close,
        shutdown,
    },
    buf_idx: i16 = -1,
    client_fd: os.fd_t = -1,
};

const Ring = struct {
    uring: std.os.linux.IO_Uring,
    client_addr: os.sockaddr,
    client_addr_len: os.socklen_t = @sizeOf(os.sockaddr),

    pub fn init(entries: u13, flags: u32) !Ring {
        return Ring{
            .uring = try std.os.linux.IO_Uring.init(entries, flags),
            .client_addr = undefined,
        };
    }

    fn deinit(self: *Ring) void {
        self.uring.deinit();
    }

    fn queue_close(self: *Ring, fd: os.fd_t) !*io_uring_sqe {
        return try self.uring.close(@bitCast(u64, Token{ .tag = .close }), fd);
    }

    fn queue_shutdown(self: *Ring, fd: os.socket_t, how: u32) !*io_uring_sqe {
        return try self.uring.shutdown(@bitCast(u64, Token{ .tag = .close }), fd, how);
    }

    fn queue_accept(self: *Ring, server: os.socket_t) !*io_uring_sqe {
        return try self.uring.accept(@bitCast(u64, Token{ .tag = .accept }), server, &self.client_addr, &self.client_addr_len, 0);
    }

    fn queue_read(
        self: *Ring,
        client_fd: os.fd_t,
        buffer: []u8,
        offset: u64,
    ) !*io_uring_sqe {
        return try self.uring.read(@bitCast(u64, Token{
            .tag = .read,
            .client_fd = client_fd,
        }), client_fd, buffer, offset);
    }

    fn queue_write_fixed(
        self: *Ring,
        client_fd: os.fd_t,
        buffer: *os.iovec,
        offset: u64,
        buffer_index: u16,
    ) !*io_uring_sqe {
        const udata = Token{
            .tag = .write,
            .client_fd = client_fd,
        };
        return try self.uring.write_fixed(@bitCast(u64, udata), client_fd, buffer, offset, buffer_index);
    }

    fn queue_write(
        self: *Ring,
        client_fd: os.fd_t,
        buffer: []const u8,
        offset: u64,
    ) !*io_uring_sqe {
        const udata = Token{
            .tag = .write,
            .client_fd = client_fd,
        };

        return try self.uring.write(@bitCast(u64, udata), client_fd, buffer, offset);
    }
};

var global_stop = std.atomic.Atomic(bool).init(false);

fn initSignalHandlers() !void {
    // SIGPIPE is ignored, errors need to be handled on read/writes
    os.sigaction(os.SIGPIPE, &.{
        .handler = .{ .sigaction = os.SIG_IGN },
        .mask = os.empty_sigset,
        .flags = 0,
    }, null);

    // SIGTERM/SIGINT set global_stop
    for ([_]os.SIG{
        .INT,
        .TERM,
    }) |sig| {
        os.sigaction(sig, &.{
            .handler = .{
                .handler = struct {
                    fn wrapper(_: c_int) callconv(.C) void {
                        global_stop.store(true, .SeqCst);
                    }
                }.wrapper,
            },
            .mask = os.empty_sigset,
            .flags = 0,
        }, null);
    }
}

pub fn main() !void {
    // TODO: support other tcp-ish socket types
    // - tcp
    // - unix-socket
    // - unix-abstract-socket e.g. \0 prefixed
    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const kernel_backlog = 1;
    const server = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    defer os.close(server);
    try os.setsockopt(server, os.SOL.SOCKET, os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try os.bind(server, &address.any, address.getOsSockLen());
    try os.listen(server, kernel_backlog);
    std.debug.print("net: echo server: io_uring: listening on {}...\n", .{address});

    // TODO: no idea what a reasonable value is for entries, 16 seems nice and low.
    //       smaller is better until benchmarks show otherwise (a big buffer can hide deadlock bugs until prod).
    var ring = try Ring.init(16, 0);
    defer ring.deinit();

    _ = try ring.queue_accept(server);

    const BUF_COUNT = 16;
    const BUF_SIZE = 4096;
    var raw_bufs: [BUF_COUNT][BUF_SIZE]u8 = undefined;
    var buffers: [raw_bufs.len]std.os.iovec = undefined;
    for (buffers) |*iovc, i| {
        iovc.* = .{ .iov_base = &raw_bufs[i], .iov_len = raw_bufs[i].len };
    }
    const READ_BUF_IDX = z0;
    try ring.uring.register_buffers(buffers[0..]);
    var buffer_write = [_]u8{98} ** 3;

    // std.mem.
    // std.mem.copy(u8, &raw_bufs[0], "foobar");

    while (true) {
        // TODO: Write a golang client to fuzz bad behavior from clients (e.g. slow/other).
        //       long running tests that validate checksums to find weird behavior at scale.
        // TODO: benchmark vs batching + peeking vs kernal submit thread
        // TODO: ensure everything else is non-blocking (or attach a timeout?).
        //       otherwise we need to have a background thread for periodic tasks
        //       like updating a dns cache or sending metrics/heartbeats.
        // TODO: install bcc and monitor tcp stuff + other utilization metrics.
        _ = try ring.uring.submit_and_wait(1);

        // TODO: benchmark copy_cqes for a batch of [256] completions at a time.
        const cqe = try ring.uring.copy_cqe();
        switch (cqe.err()) {
            .SUCCESS => {},
            else => |errno| std.debug.panic("unhandled errno: {}", .{errno}),
        }

        const token = @bitCast(Token, cqe.user_data);
        std.log.info("token: {}", .{token});

        // tag indicates what event was completed
        switch (token.tag) {
            // We have a new connection, we need to
            // 1) reject new connections over some limit by skipping queue_accept?
            // 2) dedicate a new "connection" object that has the buffers and other
            //    stuff dedicated to a single long-lived tcp-connection.
            .accept => {
                // TODO: limit number of connections here, by not queing an accept?
                _ = try ring.queue_accept(server);

                // TODO: I think this has a race condition, if we accept again
                // before this read has finished the two reads could write to the
                // buffer concurrently?
                // We don't control what order the events are completed here.
                // I think this is solved by using a pool (or dedicated per client)
                // buffers + readv.

                const buf_idx = READ_BUF_IDX;
                const offset = 0;
                _ = try ring.uring.read_fixed(@bitCast(u64, Token{
                    .tag = .read_fixed,
                    .client_fd = cqe.res,
                    .buf_idx = buf_idx,
                }), cqe.res, &buffers[buf_idx], offset, buf_idx);
            },
            .read_fixed => {
                // TODO: we are done with the buffer.
                const data_read = raw_bufs[@intCast(usize, token.buf_idx)][0..@intCast(usize, cqe.res)];
                std.debug.print("complete.read_fixed: {s}\n", .{data_read});
                _ = try ring.uring.write(
                    @bitCast(u64, Token{
                        .tag = .write,
                        .client_fd = token.client_fd,
                    }),
                    token.client_fd,
                    buffer_write[0..],
                    0,
                );
            },
            .write_fixed, .write => {
                // TODO: another ordering bug I think, we need to ensure that no sqe is
                // still in progress for the given client_fd (I think this can be a flush/nop,
                // or maybe just a per fd ref count)
                std.debug.print("complete.write: nbytes={}\n", .{cqe.res});
                _ = try ring.queue_close(token.client_fd);
            },
            .read => unreachable,
            .close, .shutdown => {
                std.debug.print("complete.close\n", .{});
            },
        }
    }
}
