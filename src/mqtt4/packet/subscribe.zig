const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const std = @import("std");
const mqtt_string = @import("../../mqtt_string.zig");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
const QoS = @import("../../qos.zig").QoS;
pub const Topic = @import("./subscribe/topic.zig").Topic;

pub const Subscribe = struct {
    packet_id: u16,
    topics: []Topic,

    pub const ParseError = error{
        InvalidQoS,
        EmptyTopics,
    };

    pub fn parse(fixed_header: FixedHeader, allocator: *Allocator, inner_reader: anytype) !Subscribe {
        // Hold this so we can query remaining bytes
        var limited_reader = std.io.limitedReader(inner_reader, fixed_header.remaining_length);
        const reader = limited_reader.reader();

        const packet_id = try reader.readIntBig(u16);
        var topics = ArrayList(Topic).init(allocator);
        errdefer topics.deinit();

        while (limited_reader.bytes_left > 0) {
            // If we fail at any step, cleanup all that was allocated until now
            errdefer {
                for (topics.items) |*t| {
                    t.deinit(allocator);
                }
            }

            var topic = try Topic.parse(allocator, reader);
            errdefer topic.deinit(allocator);

            try topics.append(topic);
        }

        if (topics.items.len == 0) {
            return error.EmptyTopics;
        }

        return Subscribe{
            .packet_id = packet_id,
            .topics = topics.toOwnedSlice(),
        };
    }

    pub fn serialize(self: Subscribe, writer: anytype) !void {
        try writer.writeIntBig(u16, self.packet_id);
        for (self.topics) |topic| {
            try topic.serialize(writer);
        }
    }

    pub fn serializedLength(self: Subscribe) u32 {
        var length: u32 = comptime @sizeOf(@TypeOf(self.packet_id));

        for (self.topics) |topic| {
            length += topic.serializedLength();
        }

        return length;
    }

    pub fn fixedHeaderFlags(self: Subscribe) u4 {
        _ = self;

        return 0b0010;
    }

    pub fn deinit(self: *Subscribe, allocator: *Allocator) void {
        for (self.topics) |*topic| {
            topic.deinit(allocator);
        }
        allocator.free(self.topics);
    }
};

test "Subscribe payload parsing" {
    const allocator = std.testing.allocator;

    const buffer =
        // Packet id, 3
        "\x00\x03" ++
        // Topic filter length, 7
        "\x00\x07" ++
        // Topic filter
        "foo/bar" ++
        // QoS, 1
        "\x01" ++
        // Topic filter length, 5
        "\x00\x05" ++
        // Topic filter
        "baz/#" ++
        // QoS, 2
        "\x02";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.subscribe,
        .flags = 0b0010,
        .remaining_length = @intCast(u32, buffer.len),
    };

    var subscribe = try Subscribe.parse(fixed_header, allocator, stream);
    defer subscribe.deinit(allocator);

    try expect(subscribe.packet_id == 3);
    try expect(subscribe.topics.len == 2);
    try expectEqualSlices(u8, subscribe.topics[0].topic_filter, "foo/bar");
    try expect(subscribe.topics[0].qos == .qos1);
    try expectEqualSlices(u8, subscribe.topics[1].topic_filter, "baz/#");
    try expect(subscribe.topics[1].qos == .qos2);
}

test "Subscribe parsing fails with no topics" {
    const allocator = std.testing.allocator;

    const buffer =
        // Packet id, 3
        "\x00\x03";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.subscribe,
        .flags = 0b0010,
        .remaining_length = @intCast(u32, buffer.len),
    };

    const result = Subscribe.parse(fixed_header, allocator, stream);
    try expectError(error.EmptyTopics, result);
}

test "Subscribe parsing with error doesn't leak" {
    const allocator = std.testing.allocator;

    const buffer =
        // Packet id, 3
        "\x00\x03" ++
        // Topic filter length, 7
        "\x00\x07" ++
        // Topic filter
        "foo/bar" ++
        // QoS, 1
        "\x01" ++
        // Topic filter length, 9
        "\x00\x09" ++
        // Topic filter, shorter
        "a/b" ++
        // QoS, 2
        "\x02";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.subscribe,
        .flags = 0b0010,
        .remaining_length = @intCast(u32, buffer.len),
    };

    const result = Subscribe.parse(fixed_header, allocator, stream);
    try expectError(error.EndOfStream, result);
}

test "serialize/parse roundtrip" {
    const allocator = std.testing.allocator;

    var topics = ArrayList(Topic).init(allocator);
    try topics.append(Topic{ .topic_filter = "foo/#", .qos = .qos2 });
    try topics.append(Topic{ .topic_filter = "bar/baz/+", .qos = .qos0 });

    var topics_slice = topics.toOwnedSlice();
    defer allocator.free(topics_slice);

    const subscribe = Subscribe{
        .packet_id = 42,
        .topics = topics_slice,
    };

    var buffer = [_]u8{0} ** 100;

    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try subscribe.serialize(writer);

    const written = try stream.getPos();

    stream.reset();
    const reader = stream.reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.subscribe,
        .flags = 0b0010,
        .remaining_length = @intCast(u32, written),
    };

    var deser_subscribe = try Subscribe.parse(fixed_header, allocator, reader);
    defer deser_subscribe.deinit(allocator);

    try expect(subscribe.packet_id == deser_subscribe.packet_id);
    try expect(subscribe.topics.len == deser_subscribe.topics.len);
    try expect(subscribe.topics[0].qos == deser_subscribe.topics[0].qos);
    try expectEqualSlices(u8, subscribe.topics[0].topic_filter, deser_subscribe.topics[0].topic_filter);
    try expect(subscribe.topics[1].qos == deser_subscribe.topics[1].qos);
    try expectEqualSlices(u8, subscribe.topics[1].topic_filter, deser_subscribe.topics[1].topic_filter);
}
