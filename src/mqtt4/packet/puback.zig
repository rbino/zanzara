const common = @import("./common.zig");
const expect = std.testing.expect;
const std = @import("std");

pub const PubAck = common.PacketIdOnly(0b0000);

test "PubAck payload parsing" {
    const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
    const allocator = std.testing.allocator;

    const buffer =
        // Packet id == 42
        "\x00\x2a";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.puback,
        .flags = 0,
        .remaining_length = @intCast(u32, buffer.len),
    };

    var puback = try PubAck.parse(fixed_header, allocator, stream);
    defer puback.deinit(allocator);

    try expect(puback.packet_id == 42);
}

test "PubAck serialized length" {
    const puback = PubAck{
        .packet_id = 31,
    };

    try expect(puback.serializedLength() == 2);
}

test "serialize/parse roundtrip" {
    const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
    const puback = PubAck{
        .packet_id = 1234,
    };

    var buffer = [_]u8{0} ** 100;

    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try puback.serialize(writer);

    const written = try stream.getPos();

    stream.reset();
    const reader = stream.reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.puback,
        .flags = 0,
        .remaining_length = @intCast(u32, written),
    };

    const allocator = std.testing.allocator;

    var deser_puback = try PubAck.parse(fixed_header, allocator, reader);
    defer deser_puback.deinit(allocator);

    try expect(puback.packet_id == deser_puback.packet_id);
}
