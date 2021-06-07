const expect = std.testing.expect;
const std = @import("std");
const Allocator = std.mem.Allocator;
const FixedHeader = @import("../packet.zig").Packet.FixedHeader;

pub const PingResp = struct {
    pub fn parse(fixed_header: FixedHeader, allocator: *Allocator, inner_reader: anytype) !PingResp {
        // Nothing to do here, no variable header and no payload
        return PingResp{};
    }

    pub fn serialize(self: PingResp, writer: anytype) !void {}

    pub fn serializedLength(self: PingResp) u32 {
        // Fixed
        return 0;
    }

    pub fn fixedHeaderFlags(self: PingResp) u4 {
        return 0b0000;
    }

    pub fn deinit(self: *PingResp, allocator: *Allocator) void {}
};

test "PingResp payload parsing" {
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
