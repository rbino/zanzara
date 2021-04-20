const expect = std.testing.expect;
const std = @import("std");
const Allocator = std.mem.Allocator;

const Connect = @import("./packet/connect.zig").Connect;
const ConnAck = @import("./packet/connack.zig").ConnAck;

pub const Packet = struct {
    fixed_header: FixedHeader,
    payload: Payload,

    pub const FixedHeader = struct {
        packet_type: PacketType,
        flags: u4,
        remaining_length: u32,
    };

    pub const PacketType = enum(u4) {
        connect = 1,
        connack,
    };

    pub const Payload = union(PacketType) {
        connect: Connect,
        connack: ConnAck,
    };

    pub const ParseError = error{InvalidLength};

    pub fn parse(allocator: *Allocator, reader: anytype) !Packet {
        const type_and_flags: u8 = try reader.readByte();
        const packet_type = @intToEnum(PacketType, @intCast(u4, type_and_flags >> 4));
        const flags = @intCast(u4, type_and_flags & 0b1111);

        const remaining_length = try parseRemainingLength(reader);

        const payload = switch (packet_type) {
            PacketType.connect => Payload{ .connect = try Connect.parse(allocator, reader) },
            PacketType.connack => Payload{ .connack = try ConnAck.parse(allocator, reader) },
        };

        const fixed_header = FixedHeader{
            .packet_type = packet_type,
            .flags = flags,
            .remaining_length = remaining_length,
        };

        return Packet{
            .fixed_header = fixed_header,
            .payload = payload,
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

    pub fn deinit(self: *Packet, allocator: *Allocator) void {
        switch (self.payload) {
            Payload.connect => |*connect| connect.deinit(allocator),
            Payload.connack => |*connack| connack.deinit(allocator),
        }
    }
};

test "minimal Connect packet parsing" {
    const PacketType = Packet.PacketType;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // Check no leaks
    defer expect(!gpa.deinit());

    const allocator = &gpa.allocator;

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

    expect(packet.fixed_header.packet_type == PacketType.connect);
    expect(packet.fixed_header.flags == 0);
    expect(packet.fixed_header.remaining_length == 12);

    const connect = packet.payload.connect;

    expect(connect.keepalive == 60);
    expect(connect.client_id == null);
    expect(connect.will == null);
    expect(connect.username == null);
    expect(connect.password == null);

    const flags = connect.flags;

    expect(flags._reserved == 0);
    expect(flags.clean_session == false);
    expect(flags.password_flag == false);
    expect(flags.username_flag == false);
    expect(flags.will_flag == false);
    expect(flags.will_retain == false);
    expect(flags.will_qos == 0);
}

test "remaining length > 127" {
    const PacketType = Packet.PacketType;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // Check no leaks
    defer expect(!gpa.deinit());

    const allocator = &gpa.allocator;

    const buffer =
        // Type and flags
        [_]u8{0b00010000} ++
        // Remaining length, 212, encoded with the MQTT algorithm
        "\xd4" ++
        "\x01" ++
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
        // Client id length, 200
        "\x00\xc8" ++
        // AAAAA
        "A" ** 200;
    const stream = std.io.fixedBufferStream(buffer).reader();

    var packet = try Packet.parse(allocator, stream);
    defer packet.deinit(allocator);

    expect(packet.fixed_header.packet_type == PacketType.connect);
    expect(packet.fixed_header.flags == 0);
    expect(packet.fixed_header.remaining_length == 212);
}

test "packet" {
    _ = @import("./packet/connect.zig");
    _ = @import("./packet/connack.zig");
}
