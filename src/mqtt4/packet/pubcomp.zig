const expect = std.testing.expect;
const std = @import("std");
const Allocator = std.mem.Allocator;
const FixedHeader = @import("../packet.zig").Packet.FixedHeader;

pub const PubComp = struct {
    packet_id: u16,

    pub fn parse(fixed_header: FixedHeader, allocator: *Allocator, inner_reader: anytype) !PubComp {
        const reader = std.io.limitedReader(inner_reader, fixed_header.remaining_length).reader();

        const packet_id = try reader.readIntBig(u16);

        return PubComp{
            .packet_id = packet_id,
        };
    }

    pub fn serialize(self: PubComp, writer: anytype) !void {
        try writer.writeIntBig(u16, self.packet_id);
    }

    pub fn serializedLength(self: PubComp) u32 {
        // Fixed
        return comptime @sizeOf(u16);
    }

    pub fn fixedHeaderFlags(self: PubComp) u4 {
        return 0b0010;
    }

    pub fn deinit(self: *PubComp, allocator: *Allocator) void {}
};

test "PubComp payload parsing" {
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
