const std = @import("std");
const testing = std.testing;

pub const mqtt4 = @import("./mqtt4.zig");

test "zanzara" {
    testing.refAllDecls(@This());
}
