const Allocator = @import("std").mem.Allocator;

pub fn readMQTTString(allocator: *Allocator, reader: anytype) ![]u8 {
    const length = try reader.readIntBig(u16);
    const string = try allocator.alloc(u8, length);
    errdefer allocator.free(string);
    try reader.readNoEof(string);

    return string;
}
