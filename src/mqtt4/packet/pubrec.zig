const common = @import("./common.zig");
const expect = std.testing.expect;
const std = @import("std");

pub const PubRec = common.PacketIdOnly(0b0000);

test "PubRec payload parsing" {
    const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
    const allocator = std.testing.allocator;

    const buffer =
        // Packet id == 42
        "\x00\x2a";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.pubrec,
        .flags = 0,
        .remaining_length = @intCast(u32, buffer.len),
    };

    var pubrec = try PubRec.parse(fixed_header, allocator, stream);
    defer pubrec.deinit(allocator);

    try expect(pubrec.packet_id == 42);
}

test "PubRec serialized length" {
    const pubrec = PubRec{
        .packet_id = 31,
    };

    try expect(pubrec.serializedLength() == 2);
}

test "serialize/parse roundtrip" {
    const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
    const pubrec = PubRec{
        .packet_id = 1234,
    };

    var buffer = [_]u8{0} ** 100;

    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try pubrec.serialize(writer);

    const written = try stream.getPos();

    stream.reset();
    const reader = stream.reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.pubrec,
        .flags = 0,
        .remaining_length = @intCast(u32, written),
    };

    const allocator = std.testing.allocator;

    var deser_pubrec = try PubRec.parse(fixed_header, allocator, reader);
    defer deser_pubrec.deinit(allocator);

    try expect(pubrec.packet_id == deser_pubrec.packet_id);
}
