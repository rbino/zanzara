const common = @import("./common.zig");
const expect = std.testing.expect;
const std = @import("std");

pub const Disconnect = common.EmptyPacket();

test "Disconnect payload parsing" {
    const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
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
    const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
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
