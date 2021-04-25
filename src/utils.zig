const Allocator = @import("std").mem.Allocator;

pub fn readMQTTString(allocator: *Allocator, reader: anytype) ![]u8 {
    const length = try reader.readIntBig(u16);
    const string = try allocator.alloc(u8, length);
    errdefer allocator.free(string);
    try reader.readNoEof(string);

    return string;
}

pub fn serializedMQTTStringLen(s: []const u8) u16 {
    return 2 + @intCast(u16, s.len);
}

pub fn writeMQTTString(s: []const u8, writer: anytype) !void {
    const length = @intCast(u16, s.len);
    try writer.writeIntBig(u16, length);
    try writer.writeAll(s);
}
