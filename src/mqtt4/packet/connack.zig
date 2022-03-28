const expect = std.testing.expect;
const std = @import("std");
const Allocator = std.mem.Allocator;
const FixedHeader = @import("../packet.zig").Packet.FixedHeader;

pub const ReturnCode = enum(u8) {
    ok = 0,
    unacceptable_protocol_version,
    invalid_client_id,
    server_unavailable,
    malformed_credentials,
    unauthorized,
};

pub const ConnAck = struct {
    session_present: bool,
    return_code: ReturnCode,

    const Flags = packed struct {
        session_present: bool,
        _reserved: u7 = 0,
    };

    pub fn parse(fixed_header: FixedHeader, allocator: Allocator, inner_reader: anytype) !ConnAck {
        _ = allocator;

        const reader = std.io.limitedReader(inner_reader, fixed_header.remaining_length).reader();

        const flags_byte = try reader.readByte();
        const flags = @bitCast(Flags, flags_byte);

        const session_present = flags.session_present;

        const return_code_byte = try reader.readByte();
        const return_code = @intToEnum(ReturnCode, return_code_byte);

        return ConnAck{
            .session_present = session_present,
            .return_code = return_code,
        };
    }

    pub fn serialize(self: ConnAck, writer: anytype) !void {
        const flags = Flags{
            .session_present = self.session_present,
        };
        const flags_byte = @bitCast(u8, flags);
        try writer.writeByte(flags_byte);

        const return_code_byte = @enumToInt(self.return_code);
        try writer.writeByte(return_code_byte);
    }

    pub fn serializedLength(self: ConnAck) u32 {
        _ = self;

        // Fixed
        return comptime @sizeOf(Flags) + @sizeOf(ReturnCode);
    }

    pub fn fixedHeaderFlags(self: ConnAck) u4 {
        _ = self;

        return 0b0000;
    }

    pub fn deinit(self: *ConnAck, allocator: Allocator) void {
        _ = self;
        _ = allocator;
    }
};

test "ConnAck payload parsing" {
    const allocator = std.testing.allocator;

    const buffer =
        // Session present flag to true
        "\x01" ++
        // ok return code
        "\x00";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.connack,
        .flags = 0,
        .remaining_length = @intCast(u32, buffer.len),
    };

    var connack = try ConnAck.parse(fixed_header, allocator, stream);
    defer connack.deinit(allocator);

    try expect(connack.session_present == true);
    try expect(connack.return_code == ReturnCode.ok);
}

test "ConnAck serialized length" {
    const connack = ConnAck{
        .session_present = true,
        .return_code = ReturnCode.ok,
    };

    try expect(connack.serializedLength() == 2);
}

test "serialize/parse roundtrip" {
    const connack = ConnAck{
        .session_present = true,
        .return_code = ReturnCode.unauthorized,
    };

    var buffer = [_]u8{0} ** 100;

    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try connack.serialize(writer);

    const written = try stream.getPos();

    stream.reset();
    const reader = stream.reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.connack,
        .flags = 0,
        .remaining_length = @intCast(u32, written),
    };

    const allocator = std.testing.allocator;

    var deser_connack = try ConnAck.parse(fixed_header, allocator, reader);
    defer deser_connack.deinit(allocator);

    try expect(connack.session_present == deser_connack.session_present);
    try expect(connack.return_code == deser_connack.return_code);
}
