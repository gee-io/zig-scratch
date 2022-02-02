const std = @import("std");
const net = std.net;
const os = std.os;
const mem = std.mem;
const assert = std.debug.assert;

const Token = packed struct {
    tag: enum(u32) {
        accept,
        read,
    },
    data: u32,
};

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

    var ring = try std.os.linux.IO_Uring.init(16, 0);
    defer ring.deinit();

    // var cqes: [512]std.os.linux.io_uring_cqe = undefined;
    var accept_addr: os.sockaddr = undefined;
    var accept_addr_len: os.socklen_t = @sizeOf(@TypeOf(accept_addr));
    _ = try ring.accept(@bitCast(u64, Token{
        .tag = .accept,
        .data = 0,
    }), server, &accept_addr, &accept_addr_len, 0);
}
