const common = @import("./common.zig");
const expect = std.testing.expect;
const std = @import("std");

pub const PingResp = common.EmptyPacket();

test "PingResp payload parsing" {
    const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
    const allocator = std.testing.allocator;

    const buffer = "";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.pingresp,
        .flags = 0,
        .remaining_length = @intCast(u32, buffer.len),
    };

    var pingresp = try PingResp.parse(fixed_header, allocator, stream);
    defer pingresp.deinit(allocator);

    try expect(@TypeOf(pingresp) == PingResp);
}

test "PingResp serialized length" {
    const pingresp = PingResp{};

    try expect(pingresp.serializedLength() == 0);
}

test "serialize/parse roundtrip" {
    const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
    const pingresp = PingResp{};

    var buffer = [_]u8{0} ** 100;

    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try pingresp.serialize(writer);

    const written = try stream.getPos();

    stream.reset();
    const reader = stream.reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.pingresp,
        .flags = 0,
        .remaining_length = @intCast(u32, written),
    };

    const allocator = std.testing.allocator;

    var deser_pingresp = try PingResp.parse(fixed_header, allocator, reader);
    defer deser_pingresp.deinit(allocator);

    try expect(@TypeOf(pingresp) == @TypeOf(deser_pingresp));
}
