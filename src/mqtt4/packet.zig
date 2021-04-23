const expect = std.testing.expect;
const std = @import("std");
const Allocator = std.mem.Allocator;

const Connect = @import("./packet/connect.zig").Connect;
const ConnAck = @import("./packet/connack.zig").ConnAck;

pub const PacketType = enum(u4) {
    connect = 1,
    connack,
};

pub const Packet = union(PacketType) {
    connect: Connect,
    connack: ConnAck,

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
};

test "minimal Connect packet parsing" {
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

    const connect = packet.connect;

    expect(connect.clean_session == false);
    expect(connect.keepalive == 60);
    expect(connect.client_id.len == 0);
    expect(connect.will == null);
    expect(connect.username == null);
    expect(connect.password == null);
}

test "parse remaining length > 127" {
    const buffer =
        // Remaining length, 212, encoded with the MQTT algorithm
        "\xd4" ++
        "\x01";
    const stream = std.io.fixedBufferStream(buffer).reader();

    var remainingLength = try Packet.parseRemainingLength(stream);
    expect(remainingLength == 212);
}

test "packet" {
    _ = @import("./packet/connect.zig");
    _ = @import("./packet/connack.zig");
}
