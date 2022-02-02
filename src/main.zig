const std = @import("std");
const net = std.net;
const os = std.os;
const mem = std.mem;

pub const log_level = .debug;

pub fn main() !void {
    var ring = std.os.linux.IO_Uring.init(16, 0) catch |err| switch (err) {
        error.SystemOutdated => return error.SkipZigTest,
        error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();

    const address = try net.Address.parseIp4("127.0.0.1", 3131);
    const kernel_backlog = 1;
    const server = try os.socket(address.any.family, os.SOCK.STREAM | os.SOCK.CLOEXEC, 0);
    defer os.close(server);
    try os.setsockopt(server, os.SOL.SOCKET, os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));
    try os.bind(server, &address.any, address.getOsSockLen());
    try os.listen(server, kernel_backlog);

    // const buffer_send = [_]u8{ 1, 0, 1, 0, 1, 0, 1, 0, 1, 0 };
    // var buffer_recv = [_]u8{ 0, 1, 0, 1, 0 };

    var accept_addr: os.sockaddr = undefined;
    var accept_addr_len: os.socklen_t = @sizeOf(@TypeOf(accept_addr));
    _ = try ring.accept(0xaaaaaaaa, server, &accept_addr, &accept_addr_len, 0);

    const n = try ring.submit();

    std.debug.assert(@as(u32, 2) == n);
    std.log.info("done", .{});
}
