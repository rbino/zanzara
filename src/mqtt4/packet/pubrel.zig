const expect = std.testing.expect;
const std = @import("std");
const Allocator = std.mem.Allocator;
const FixedHeader = @import("../packet.zig").Packet.FixedHeader;

pub const PubRel = struct {
    packet_id: u16,

    pub fn parse(fixed_header: FixedHeader, allocator: *Allocator, inner_reader: anytype) !PubRel {
        const reader = std.io.limitedReader(inner_reader, fixed_header.remaining_length).reader();

        const packet_id = try reader.readIntBig(u16);

        return PubRel{
            .packet_id = packet_id,
        };
    }

    pub fn serialize(self: PubRel, writer: anytype) !void {
        try writer.writeIntBig(u16, self.packet_id);
    }

    pub fn serializedLength(self: PubRel) u32 {
        // Fixed
        return comptime @sizeOf(u16);
    }

    pub fn fixedHeaderFlags(self: PubRel) u4 {
        return 0b0010;
    }

    pub fn deinit(self: *PubRel, allocator: *Allocator) void {}
};

test "PubRel payload parsing" {
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
