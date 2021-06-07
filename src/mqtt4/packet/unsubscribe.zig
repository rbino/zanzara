const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const std = @import("std");
const utils = @import("../../utils.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
const QoS = @import("../../qos.zig").QoS;

pub const Unsubscribe = struct {
    packet_id: u16,
    topic_filters: ArrayList([]const u8),

    pub const ParseError = error{
        EmptyTopicFilters,
    };

    pub fn parse(fixed_header: FixedHeader, allocator: *Allocator, inner_reader: anytype) !Unsubscribe {
        // Hold this so we can query remaining bytes
        var limited_reader = std.io.limitedReader(inner_reader, fixed_header.remaining_length);
        const reader = limited_reader.reader();

        const packet_id = try reader.readIntBig(u16);
        var topic_filters = ArrayList([]const u8).init(allocator);
        errdefer topic_filters.deinit();

        while (limited_reader.bytes_left > 0) {
            // If we fail at any step, cleanup all that was allocated until now
            errdefer {
                for (topic_filters.items) |t| {
                    allocator.free(t);
                }
            }

            var topic_filter = try utils.readMQTTString(allocator, reader);
            errdefer allocator.free(topic_filter);

            try topic_filters.append(topic_filter);
        }

        if (topic_filters.items.len == 0) {
            return ParseError.EmptyTopicFilters;
        }

        return Unsubscribe{
            .packet_id = packet_id,
            .topic_filters = topic_filters,
        };
    }

    pub fn serialize(self: Unsubscribe, writer: anytype) !void {
        try writer.writeIntBig(u16, self.packet_id);
        for (self.topic_filters.items) |topic_filter| {
            try utils.writeMQTTString(topic_filter, writer);
        }
    }

    pub fn serializedLength(self: Unsubscribe) u32 {
        var length: u32 = comptime @sizeOf(@TypeOf(self.packet_id));

        for (self.topic_filters.items) |topic_filter| {
            length += utils.serializedMQTTStringLen(topic_filter);
        }

        return length;
    }

    pub fn fixedHeaderFlags(self: Unsubscribe) u4 {
        return 0b0000;
    }

    pub fn deinit(self: *Unsubscribe, allocator: *Allocator) void {
        for (self.topic_filters.items) |topic_filter| {
            allocator.free(topic_filter);
        }
        self.topic_filters.deinit();
    }
};

test "Unsubscribe payload parsing" {
    const allocator = std.testing.allocator;

    const buffer =
        // Packet id, 3
        "\x00\x03" ++
        // Topic filter length, 7
        "\x00\x07" ++
        // Topic filter
        "foo/bar" ++
        // Topic filter length, 5
        "\x00\x05" ++
        // Topic filter
        "baz/#";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.unsubscribe,
        .flags = 0b0010,
        .remaining_length = @intCast(u32, buffer.len),
    };

    var unsubscribe = try Unsubscribe.parse(fixed_header, allocator, stream);
    defer unsubscribe.deinit(allocator);

    try expect(unsubscribe.packet_id == 3);
    try expect(unsubscribe.topic_filters.items.len == 2);
    try expectEqualSlices(u8, unsubscribe.topic_filters.items[0], "foo/bar");
    try expectEqualSlices(u8, unsubscribe.topic_filters.items[1], "baz/#");
}

test "Unsubscribe parsing fails with no topic_filters" {
    const allocator = std.testing.allocator;

    const buffer =
        // Packet id, 3
        "\x00\x03";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.unsubscribe,
        .flags = 0b0010,
        .remaining_length = @intCast(u32, buffer.len),
    };

    const result = Unsubscribe.parse(fixed_header, allocator, stream);
    try expectError(error.EmptyTopicFilters, result);
}

test "Unsubscribe parsing with error doesn't leak" {
    const allocator = std.testing.allocator;

    const buffer =
        // Packet id, 3
        "\x00\x03" ++
        // Topic filter length, 7
        "\x00\x07" ++
        // Topic filter
        "foo/bar" ++
        // Topic filter length, 9
        "\x00\x09" ++
        // Topic filter, shorter
        "a/b";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.unsubscribe,
        .flags = 0b0010,
        .remaining_length = @intCast(u32, buffer.len),
    };

    const result = Unsubscribe.parse(fixed_header, allocator, stream);
    try expectError(error.EndOfStream, result);
}

test "serialize/parse roundtrip" {
    const allocator = std.testing.allocator;

    var topic_filters = ArrayList([]const u8).init(allocator);
    defer topic_filters.deinit();
    try topic_filters.append("foo/#");
    try topic_filters.append("bar/baz/+");

    var unsubscribe = Unsubscribe{
        .packet_id = 42,
        .topic_filters = topic_filters,
    };

    var buffer = [_]u8{0} ** 100;

    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try unsubscribe.serialize(writer);

    const written = try stream.getPos();

    stream.reset();
    const reader = stream.reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.unsubscribe,
        .flags = 0b0010,
        .remaining_length = @intCast(u32, written),
    };

    var deser_unsubscribe = try Unsubscribe.parse(fixed_header, allocator, reader);
    defer deser_unsubscribe.deinit(allocator);

    try expect(unsubscribe.packet_id == deser_unsubscribe.packet_id);
    try expect(unsubscribe.topic_filters.items.len == deser_unsubscribe.topic_filters.items.len);
    try expectEqualSlices(u8, unsubscribe.topic_filters.items[0], deser_unsubscribe.topic_filters.items[0]);
    try expectEqualSlices(u8, unsubscribe.topic_filters.items[1], deser_unsubscribe.topic_filters.items[1]);
}
