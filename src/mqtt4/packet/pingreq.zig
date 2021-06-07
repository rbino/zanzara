const common = @import("./common.zig");
const expect = std.testing.expect;
const std = @import("std");

pub const PingReq = common.EmptyPacket();

test "PingReq payload parsing" {
    const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
    const allocator = std.testing.allocator;

    const buffer = "";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.pingreq,
        .flags = 0,
        .remaining_length = @intCast(u32, buffer.len),
    };

    var pingreq = try PingReq.parse(fixed_header, allocator, stream);
    defer pingreq.deinit(allocator);

    try expect(@TypeOf(pingreq) == PingReq);
}

test "PingReq serialized length" {
    const pingreq = PingReq{};

    try expect(pingreq.serializedLength() == 0);
}

test "serialize/parse roundtrip" {
    const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
    const pingreq = PingReq{};

    var buffer = [_]u8{0} ** 100;

    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try pingreq.serialize(writer);

    const written = try stream.getPos();

    stream.reset();
    const reader = stream.reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.pingreq,
        .flags = 0,
        .remaining_length = @intCast(u32, written),
    };

    const allocator = std.testing.allocator;

    var deser_pingreq = try PingReq.parse(fixed_header, allocator, reader);
    defer deser_pingreq.deinit(allocator);

    try expect(@TypeOf(pingreq) == @TypeOf(deser_pingreq));
}
