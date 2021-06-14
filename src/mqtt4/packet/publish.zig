const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const std = @import("std");
const utils = @import("../../utils.zig");
const Allocator = std.mem.Allocator;
const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
const QoS = @import("../../qos.zig").QoS;

pub const Publish = struct {
    duplicate: bool,
    qos: QoS,
    retain: bool,
    topic: []const u8,
    packet_id: ?u16 = null,
    payload: []const u8,

    pub const ParseError = error{
        InvalidQoS,
    };

    pub fn parse(fixed_header: FixedHeader, allocator: *Allocator, inner_reader: anytype) !Publish {
        // Hold this so we can query remaining bytes
        var limited_reader = std.io.limitedReader(inner_reader, fixed_header.remaining_length);
        const reader = limited_reader.reader();

        const retain = (fixed_header.flags & 0b0001) == 1;
        const qos_int: u2 = @intCast(u2, @shrExact(fixed_header.flags & 0b0110, 1));
        if (qos_int > 2) {
            return error.InvalidQoS;
        }
        const qos = @intToEnum(QoS, qos_int);
        const duplicate = @shrExact(fixed_header.flags & 0b1000, 3) == 1;

        const topic = try utils.readMQTTString(allocator, reader);
        errdefer allocator.free(topic);

        const packet_id = switch (qos) {
            QoS.qos0 => null,
            QoS.qos1, QoS.qos2 => try reader.readIntBig(u16),
        };

        const payload_length = limited_reader.bytes_left;
        const payload = try allocator.alloc(u8, payload_length);
        errdefer allocator.free(payload);
        try reader.readNoEof(payload);

        return Publish{
            .retain = retain,
            .qos = qos,
            .duplicate = duplicate,
            .topic = topic,
            .packet_id = packet_id,
            .payload = payload,
        };
    }

    pub fn serialize(self: Publish, writer: anytype) !void {
        try utils.writeMQTTString(self.topic, writer);

        switch (self.qos) {
            QoS.qos0 => {}, // No packet id
            QoS.qos1, QoS.qos2 => try writer.writeIntBig(u16, self.packet_id.?), // Serialize packet_id
            // TODO: handle missing packet_id more gracefully?
        }

        try writer.writeAll(self.payload);
    }

    pub fn serializedLength(self: Publish) u32 {
        var length: u32 = utils.serializedMQTTStringLen(self.topic) + @intCast(u32, self.payload.len);

        switch (self.qos) {
            QoS.qos0 => return length, // No packet id
            QoS.qos1, QoS.qos2 => return length + @sizeOf(u16), // Add space for packet id
        }
    }

    pub fn fixedHeaderFlags(self: Publish) u4 {
        var ret: u4 = @boolToInt(self.retain);
        ret |= @shlExact(@intCast(u4, @enumToInt(self.qos)), 1);
        ret |= @shlExact(@intCast(u4, @boolToInt(self.duplicate)), 3);
        return ret;
    }

    pub fn deinit(self: *Publish, allocator: *Allocator) void {
        allocator.free(self.topic);
        allocator.free(self.payload);
    }
};

test "Publish payload parsing" {
    const allocator = std.testing.allocator;

    const buffer =
        // Topic length, 7
        "\x00\x07" ++
        // Topic
        "foo/bar" ++
        // Packet ID, 42
        "\x00\x2a" ++
        // payload
        "baz";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.publish,
        .flags = 0b1101, // Retain + QoS 2 + DUP
        .remaining_length = @intCast(u32, buffer.len),
    };

    var publish = try Publish.parse(fixed_header, allocator, stream);
    defer publish.deinit(allocator);

    try expect(publish.retain == true);
    try expect(publish.qos == .qos2);
    try expect(publish.duplicate == true);
    try expect(publish.packet_id.? == 42);
    try expectEqualSlices(u8, publish.topic, "foo/bar");
    try expectEqualSlices(u8, publish.payload, "baz");
}

test "QoS 0 and empty payload parsing" {
    const allocator = std.testing.allocator;

    const buffer =
        // Topic length, 7
        "\x00\x07" ++
        // Topic
        "foo/bar";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.publish,
        .flags = 0b0000, // No retain + QoS 0 + No DUP
        .remaining_length = @intCast(u32, buffer.len),
    };

    var publish = try Publish.parse(fixed_header, allocator, stream);
    defer publish.deinit(allocator);

    try expect(publish.retain == false);
    try expect(publish.qos == .qos0);
    try expect(publish.duplicate == false);
    try expect(publish.packet_id == null);
    try expectEqualSlices(u8, publish.topic, "foo/bar");
    try expectEqualSlices(u8, publish.payload, "");
}

test "serialize/parse roundtrip" {
    const publish = Publish{
        .retain = false,
        .qos = .qos1,
        .duplicate = false,
        .topic = "my/topic",
        .packet_id = 12,
        .payload = "henlo",
    };

    var buffer = [_]u8{0} ** 100;

    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try publish.serialize(writer);

    const written = try stream.getPos();

    stream.reset();
    const reader = stream.reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.publish,
        .flags = 0b0010,
        .remaining_length = @intCast(u32, written),
    };

    const allocator = std.testing.allocator;

    var deser_publish = try Publish.parse(fixed_header, allocator, reader);
    defer deser_publish.deinit(allocator);

    try expect(publish.retain == deser_publish.retain);
    try expect(publish.qos == deser_publish.qos);
    try expect(publish.duplicate == deser_publish.duplicate);
    try expect(publish.packet_id.? == deser_publish.packet_id.?);
    try expectEqualSlices(u8, publish.topic, deser_publish.topic);
    try expectEqualSlices(u8, publish.payload, deser_publish.payload);
}
