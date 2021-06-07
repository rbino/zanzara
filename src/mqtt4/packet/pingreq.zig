const expect = std.testing.expect;
const std = @import("std");
const Allocator = std.mem.Allocator;
const FixedHeader = @import("../packet.zig").Packet.FixedHeader;

pub const PingReq = struct {
    pub fn parse(fixed_header: FixedHeader, allocator: *Allocator, inner_reader: anytype) !PingReq {
        // Nothing to do here, no variable header and no payload
        return PingReq{};
    }

    pub fn serialize(self: PingReq, writer: anytype) !void {}

    pub fn serializedLength(self: PingReq) u32 {
        // Fixed
        return 0;
    }

    pub fn fixedHeaderFlags(self: PingReq) u4 {
        return 0b0000;
    }

    pub fn deinit(self: *PingReq, allocator: *Allocator) void {}
};

test "PingReq payload parsing" {
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
