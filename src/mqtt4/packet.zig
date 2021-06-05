const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const std = @import("std");
const Allocator = std.mem.Allocator;

const Connect = @import("./packet/connect.zig").Connect;
const ConnAck = @import("./packet/connack.zig").ConnAck;
const Publish = @import("./packet/publish.zig").Publish;

pub const PacketType = enum(u4) {
    connect = 1,
    connack,
    publish,
};

pub const Packet = union(PacketType) {
    connect: Connect,
    connack: ConnAck,
    publish: Publish,

    pub const FixedHeader = struct {
        packet_type: PacketType,
        flags: u4,
        remaining_length: u32,
    };

    pub const ParseError = error{InvalidLength};

    pub fn deinit(self: *Packet, allocator: *Allocator) void {
        switch (self.*) {
            Packet.connect => |*connect| connect.deinit(allocator),
            Packet.connack => |*connack| connack.deinit(allocator),
            Packet.publish => |*publish| publish.deinit(allocator),
        }
    }

    pub fn parse(allocator: *Allocator, reader: anytype) !Packet {
        const type_and_flags: u8 = try reader.readByte();
        const packet_type = @intToEnum(PacketType, @intCast(u4, type_and_flags >> 4));
        const flags = @intCast(u4, type_and_flags & 0b1111);

        const remaining_length = try parseRemainingLength(reader);

        const fixed_header = FixedHeader{
            .packet_type = packet_type,
            .flags = flags,
            .remaining_length = remaining_length,
        };

        return switch (packet_type) {
            PacketType.connect => Packet{ .connect = try Connect.parse(fixed_header, allocator, reader) },
            PacketType.connack => Packet{ .connack = try ConnAck.parse(fixed_header, allocator, reader) },
            PacketType.publish => Packet{ .publish = try Publish.parse(fixed_header, allocator, reader) },
        };
    }

    fn parseRemainingLength(reader: anytype) !u32 {
        var byte = try reader.readByte();
        var multiplier: u32 = 1;
        var value: u32 = 0;
        // Decode variable remaining length
        while (byte & 128 != 0) : (byte = try reader.readByte()) {
            value += (byte & 127) * multiplier;
            multiplier *= 128;
            if (multiplier > 128 * 128 * 128) {
                return ParseError.InvalidLength;
            }
        }
        value += (byte & 127) * multiplier;

        return value;
    }

    fn serializeRemainingLength(remaining_length: u32, writer: anytype) !void {
        var value: u32 = remaining_length;
        while (value != 0) {
            var byte: u8 = @intCast(u8, value % 128);
            value /= 128;
            if (value > 0) {
                byte |= 128;
            }
            try writer.writeByte(byte);
        }
    }

    pub fn serialize(self: *const Packet, writer: anytype) !void {
        return switch (self.*) {
            Packet.connect => |connect| {
                const packet_type: u8 = @enumToInt(PacketType.connect);
                const type_and_flags: u8 = @shlExact(packet_type, 4) | connect.fixedHeaderFlags();
                try writer.writeByte(type_and_flags);

                const remaining_length = connect.serializedLength();
                try serializeRemainingLength(remaining_length, writer);

                try connect.serialize(writer);
            },
            Packet.connack => |connack| {
                const packet_type: u8 = @enumToInt(PacketType.connack);
                const type_and_flags: u8 = @shlExact(packet_type, 4) | connack.fixedHeaderFlags();
                try writer.writeByte(type_and_flags);

                const remaining_length = connack.serializedLength();
                try serializeRemainingLength(remaining_length, writer);

                try connack.serialize(writer);
            },
            Packet.publish => |publish| {
                const packet_type: u8 = @enumToInt(PacketType.publish);
                const type_and_flags: u8 = @shlExact(packet_type, 4) | publish.fixedHeaderFlags();
                try writer.writeByte(type_and_flags);

                const remaining_length = publish.serializedLength();
                try serializeRemainingLength(remaining_length, writer);

                try publish.serialize(writer);
            },
        };
    }
};

test "minimal Connect packet parsing" {
    const allocator = std.testing.allocator;

    const buffer =
        // Type and flags
        [_]u8{0b00010000} ++
        // Remaining length, 12
        "\x0c" ++
        // Protocol name length
        "\x00\x04" ++
        // Protocol name
        "MQTT" ++
        // Protocol version, 4 == 3.1.1
        "\x04" ++
        // Flags, empty
        "\x00" ++
        // Keepalive, 60
        "\x00\x3c" ++
        // Client id length, 0
        "\x00\x00";
    const stream = std.io.fixedBufferStream(buffer).reader();

    var packet = try Packet.parse(allocator, stream);
    defer packet.deinit(allocator);

    const connect = packet.connect;

    try expect(connect.clean_session == false);
    try expect(connect.keepalive == 60);
    try expect(connect.client_id.len == 0);
    try expect(connect.will == null);
    try expect(connect.username == null);
    try expect(connect.password == null);
}

test "minimal Connect packet serialization roundtrip" {
    const QoS = @import("../qos.zig").QoS;
    const connect = Connect{
        .clean_session = true,
        .keepalive = 60,
        .client_id = "",
        .will = Connect.Will{
            .topic = "foo/bar",
            .message = "bye",
            .qos = QoS.qos1,
            .retain = false,
        },
        .username = "user",
        .password = "pass",
    };

    const packet = Packet{
        .connect = connect,
    };

    var buffer = [_]u8{0} ** 100;

    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try packet.serialize(writer);

    const written = try stream.getPos();

    stream.reset();
    const reader = stream.reader();

    const allocator = std.testing.allocator;

    var deser_packet = try Packet.parse(allocator, reader);
    defer deser_packet.deinit(allocator);
    var deser_connect = deser_packet.connect;

    try expect(connect.clean_session == deser_connect.clean_session);
    try expect(connect.keepalive == deser_connect.keepalive);
    try expectEqualSlices(u8, connect.client_id, deser_connect.client_id);
    try expectEqualSlices(u8, connect.will.?.topic, deser_connect.will.?.topic);
    try expectEqualSlices(u8, connect.will.?.message, deser_connect.will.?.message);
    try expect(connect.will.?.qos == deser_connect.will.?.qos);
    try expect(connect.will.?.retain == deser_connect.will.?.retain);
    try expectEqualSlices(u8, connect.username.?, deser_connect.username.?);
    try expectEqualSlices(u8, connect.password.?, deser_connect.password.?);
}

test "parse remaining length > 127" {
    const buffer =
        // Remaining length, 212, encoded with the MQTT algorithm
        "\xd4" ++
        "\x01";
    const stream = std.io.fixedBufferStream(buffer).reader();

    var remainingLength = try Packet.parseRemainingLength(stream);
    try expect(remainingLength == 212);
}

test "packet" {
    _ = @import("./packet/connect.zig");
    _ = @import("./packet/connack.zig");
}
