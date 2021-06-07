const expect = std.testing.expect;
const std = @import("std");
const Allocator = std.mem.Allocator;
const FixedHeader = @import("../packet.zig").Packet.FixedHeader;

pub const Disconnect = struct {
    pub fn parse(fixed_header: FixedHeader, allocator: *Allocator, inner_reader: anytype) !Disconnect {
        // Nothing to do here, no variable header and no payload
        return Disconnect{};
    }

    pub fn serialize(self: Disconnect, writer: anytype) !void {}

    pub fn serializedLength(self: Disconnect) u32 {
        // Fixed
        return 0;
    }

    pub fn fixedHeaderFlags(self: Disconnect) u4 {
        return 0b0000;
    }

    pub fn deinit(self: *Disconnect, allocator: *Allocator) void {}
};

test "Disconnect payload parsing" {
    const allocator = std.testing.allocator;

    const buffer = "";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.disconnect,
        .flags = 0,
        .remaining_length = @intCast(u32, buffer.len),
    };

    var disconnect = try Disconnect.parse(fixed_header, allocator, stream);
    defer disconnect.deinit(allocator);

    try expect(@TypeOf(disconnect) == Disconnect);
}

test "Disconnect serialized length" {
    const disconnect = Disconnect{};

    try expect(disconnect.serializedLength() == 0);
}

test "serialize/parse roundtrip" {
    const disconnect = Disconnect{};

    var buffer = [_]u8{0} ** 100;

    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try disconnect.serialize(writer);

    const written = try stream.getPos();

    stream.reset();
    const reader = stream.reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.disconnect,
        .flags = 0,
        .remaining_length = @intCast(u32, written),
    };

    const allocator = std.testing.allocator;

    var deser_disconnect = try Disconnect.parse(fixed_header, allocator, reader);
    defer deser_disconnect.deinit(allocator);

    try expect(@TypeOf(disconnect) == @TypeOf(deser_disconnect));
}
