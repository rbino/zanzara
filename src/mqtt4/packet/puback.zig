const expect = std.testing.expect;
const std = @import("std");
const Allocator = std.mem.Allocator;
const FixedHeader = @import("../packet.zig").Packet.FixedHeader;

pub const PubAck = struct {
    packet_id: u16,

    pub fn parse(fixed_header: FixedHeader, allocator: *Allocator, inner_reader: anytype) !PubAck {
        const reader = std.io.limitedReader(inner_reader, fixed_header.remaining_length).reader();

        const packet_id = try reader.readIntBig(u16);

        return PubAck{
            .packet_id = packet_id,
        };
    }

    pub fn serialize(self: PubAck, writer: anytype) !void {
        try writer.writeIntBig(u16, self.packet_id);
    }

    pub fn serializedLength(self: PubAck) u32 {
        // Fixed
        return comptime @sizeOf(u16);
    }

    pub fn fixedHeaderFlags(self: PubAck) u4 {
        return 0b0000;
    }

    pub fn deinit(self: *PubAck, allocator: *Allocator) void {}
};

test "PubAck payload parsing" {
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
