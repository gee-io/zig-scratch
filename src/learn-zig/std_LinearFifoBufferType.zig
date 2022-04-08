const std = @import("std");

test {
    std.fifo.LinearFifo(u32, .{ .Static = 32 });
}
