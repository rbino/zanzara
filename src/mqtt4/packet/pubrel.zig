const common = @import("./common.zig");
const expect = std.testing.expect;
const std = @import("std");

pub const PubRel = common.PacketIdOnly(0b0010);

test "PubRel payload parsing" {
    const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
    const allocator = std.testing.allocator;

    const buffer =
        // Packet id == 42
        "\x00\x2a";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.pubrel,
        .flags = 0,
        .remaining_length = @intCast(u32, buffer.len),
    };

    var pubrel = try PubRel.parse(fixed_header, allocator, stream);
    defer pubrel.deinit(allocator);

    try expect(pubrel.packet_id == 42);
}

test "PubRel serialized length" {
    const pubrel = PubRel{
        .packet_id = 31,
    };

    try expect(pubrel.serializedLength() == 2);
}

test "serialize/parse roundtrip" {
    const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
    const pubrel = PubRel{
        .packet_id = 1234,
    };

    var buffer = [_]u8{0} ** 100;

    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try pubrel.serialize(writer);

    const written = try stream.getPos();

    stream.reset();
    const reader = stream.reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.pubrel,
        .flags = 0,
        .remaining_length = @intCast(u32, written),
    };

    const allocator = std.testing.allocator;

    var deser_pubrel = try PubRel.parse(fixed_header, allocator, reader);
    defer deser_pubrel.deinit(allocator);

    try expect(pubrel.packet_id == deser_pubrel.packet_id);
}
