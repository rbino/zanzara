const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const std = @import("std");
const Allocator = std.mem.Allocator;

const Connect = @import("./packet/connect.zig").Connect;
const ConnAck = @import("./packet/connack.zig").ConnAck;
const Publish = @import("./packet/publish.zig").Publish;
const PubAck = @import("./packet/puback.zig").PubAck;
const PubRec = @import("./packet/pubrec.zig").PubRec;
const PubRel = @import("./packet/pubrel.zig").PubRel;
const PubComp = @import("./packet/pubcomp.zig").PubComp;
const Subscribe = @import("./packet/subscribe.zig").Subscribe;
const SubAck = @import("./packet/suback.zig").SubAck;
const Unsubscribe = @import("./packet/unsubscribe.zig").Unsubscribe;
const UnsubAck = @import("./packet/unsuback.zig").UnsubAck;
const PingReq = @import("./packet/pingreq.zig").PingReq;
const PingResp = @import("./packet/pingresp.zig").PingResp;
const Disconnect = @import("./packet/disconnect.zig").Disconnect;

pub const PacketType = enum(u4) {
    connect = 1,
    connack,
    publish,
    puback,
    pubrec,
    pubrel,
    pubcomp,
    subscribe,
    suback,
    unsubscribe,
    unsuback,
    pingreq,
    pingresp,
    disconnect,
};

pub const Packet = union(PacketType) {
    connect: Connect,
    connack: ConnAck,
    publish: Publish,
    puback: PubAck,
    pubrec: PubRec,
    pubrel: PubRel,
    pubcomp: PubComp,
    subscribe: Subscribe,
    suback: SubAck,
    unsubscribe: Unsubscribe,
    unsuback: UnsubAck,
    pingreq: PingReq,
    pingresp: PingResp,
    disconnect: Disconnect,

    pub const FixedHeader = struct {
        packet_type: PacketType,
        flags: u4,
        remaining_length: u32,
    };

    pub const ParseError = error{InvalidLength};

    pub fn deinit(self: *Packet, allocator: *Allocator) void {
        inline for (@typeInfo(PacketType).Enum.fields) |field| {
            const packet_type_name = field.name;
            const packet_type = @intToEnum(PacketType, field.value);
            if (self.* == packet_type) {
                @field(self, packet_type_name).deinit(allocator);
                return;
            }
        }
        unreachable;
    }

    pub fn parse(allocator: *Allocator, reader: anytype) !Packet {
        const type_and_flags: u8 = try reader.readByte();
        const parsed_packet_type = @intToEnum(PacketType, @intCast(u4, type_and_flags >> 4));
        const flags = @intCast(u4, type_and_flags & 0b1111);

        const remaining_length = try parseRemainingLength(reader);

        const fixed_header = FixedHeader{
            .packet_type = parsed_packet_type,
            .flags = flags,
            .remaining_length = remaining_length,
        };

        inline for (@typeInfo(PacketType).Enum.fields) |field| {
            const packet_type_name = field.name;
            const packet_type = @intToEnum(PacketType, field.value);
            const packet_struct = comptime brk: inline for (@typeInfo(Packet).Union.fields) |union_field| {
                if (std.mem.eql(u8, union_field.name, packet_type_name)) {
                    break :brk union_field.field_type;
                }
            };

            if (parsed_packet_type == packet_type) {
                const parsed = try packet_struct.parse(fixed_header, allocator, reader);
                return @unionInit(Packet, packet_type_name, parsed);
            }
        }
        unreachable;
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
        inline for (@typeInfo(PacketType).Enum.fields) |field| {
            const packet_type_name = field.name;
            const packet_type_value: u8 = field.value;
            const packet_type = @intToEnum(PacketType, field.value);
            if (self.* == packet_type) {
                const inner_packet = @field(self, packet_type_name);

                const type_and_flags: u8 = @shlExact(packet_type_value, 4) | inner_packet.fixedHeaderFlags();
                try writer.writeByte(type_and_flags);

                const remaining_length = inner_packet.serializedLength();
                try serializeRemainingLength(remaining_length, writer);

                try inner_packet.serialize(writer);
                return;
            }
        }
        unreachable;
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
    const Will = @import("./packet/connect.zig").Will;
    const connect = Connect{
        .clean_session = true,
        .keepalive = 60,
        .client_id = "",
        .will = Will{
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
