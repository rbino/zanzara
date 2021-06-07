const common = @import("./common.zig");
const expect = std.testing.expect;
const std = @import("std");

pub const PubComp = common.PacketIdOnly(0b0010);

test "PubComp payload parsing" {
    const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
    const allocator = std.testing.allocator;

    const buffer =
        // Packet id == 42
        "\x00\x2a";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.pubcomp,
        .flags = 0,
        .remaining_length = @intCast(u32, buffer.len),
    };

    var pubcomp = try PubComp.parse(fixed_header, allocator, stream);
    defer pubcomp.deinit(allocator);

    try expect(pubcomp.packet_id == 42);
}

test "PubComp serialized length" {
    const pubcomp = PubComp{
        .packet_id = 31,
    };

    try expect(pubcomp.serializedLength() == 2);
}

test "serialize/parse roundtrip" {
    const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
    const pubcomp = PubComp{
        .packet_id = 1234,
    };

    var buffer = [_]u8{0} ** 100;

    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try pubcomp.serialize(writer);

    const written = try stream.getPos();

    stream.reset();
    const reader = stream.reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.pubcomp,
        .flags = 0,
        .remaining_length = @intCast(u32, written),
    };

    const allocator = std.testing.allocator;

    var deser_pubcomp = try PubComp.parse(fixed_header, allocator, reader);
    defer deser_pubcomp.deinit(allocator);

    try expect(pubcomp.packet_id == deser_pubcomp.packet_id);
}
