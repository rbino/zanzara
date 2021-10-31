const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const FixedHeader = @import("../packet.zig").Packet.FixedHeader;
const QoS = @import("../../qos.zig").QoS;

pub const ReturnCode = union(enum) {
    success: QoS,
    failure: void,
};

pub const SubAck = struct {
    packet_id: u16,
    return_codes: []ReturnCode,

    pub const ParseError = error{
        InvalidReturnCode,
    };

    pub fn parse(fixed_header: FixedHeader, allocator: *Allocator, inner_reader: anytype) !SubAck {
        // Hold this so we can query remaining bytes
        var limited_reader = std.io.limitedReader(inner_reader, fixed_header.remaining_length);
        const reader = limited_reader.reader();

        const packet_id = try reader.readIntBig(u16);
        var return_codes = ArrayList(ReturnCode).init(allocator);
        errdefer return_codes.deinit();

        while (limited_reader.bytes_left > 0) {
            const rc_byte = try reader.readByte();
            const rc = switch (rc_byte) {
                0, 1, 2 => ReturnCode{ .success = @intToEnum(QoS, @intCast(u2, rc_byte)) },
                0x80 => ReturnCode{ .failure = {} },
                else => return error.InvalidReturnCode,
            };
            try return_codes.append(rc);
        }

        return SubAck{
            .packet_id = packet_id,
            .return_codes = return_codes.toOwnedSlice(),
        };
    }

    pub fn serialize(self: SubAck, writer: anytype) !void {
        try writer.writeIntBig(u16, self.packet_id);
        for (self.return_codes) |return_code| {
            switch (return_code) {
                .success => |qos| try writer.writeByte(@enumToInt(qos)),
                .failure => try writer.writeByte(0x80),
            }
        }
    }

    pub fn serializedLength(self: SubAck) u32 {
        return comptime @sizeOf(@TypeOf(self.packet_id)) + @intCast(u32, self.return_codes.len);
    }

    pub fn fixedHeaderFlags(self: SubAck) u4 {
        _ = self;

        return 0b0000;
    }

    pub fn deinit(self: *SubAck, allocator: *Allocator) void {
        allocator.free(self.return_codes);
    }
};

test "SubAck payload parsing" {
    const allocator = std.testing.allocator;

    const buffer =
        // Packet id == 42
        "\x00\x2a" ++
        // Success return code with QoS 1
        "\x01" ++
        // Failure return code
        "\x80";
    const stream = std.io.fixedBufferStream(buffer).reader();
    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.suback,
        .flags = 0,
        .remaining_length = @intCast(u32, buffer.len),
    };

    var suback = try SubAck.parse(fixed_header, allocator, stream);
    defer suback.deinit(allocator);

    try expect(suback.packet_id == 42);
    try expect(suback.return_codes.len == 2);
    try expect(suback.return_codes[0] == .success);
    try expect(suback.return_codes[0].success == .qos1);
    try expect(suback.return_codes[1] == .failure);
}

test "serialize/parse roundtrip" {
    const allocator = std.testing.allocator;

    var return_codes = ArrayList(ReturnCode).init(allocator);
    try return_codes.append(ReturnCode{ .failure = {} });
    try return_codes.append(ReturnCode{ .success = .qos0 });

    var return_codes_slice = return_codes.toOwnedSlice();
    defer allocator.free(return_codes_slice);

    const suback = SubAck{
        .packet_id = 1234,
        .return_codes = return_codes_slice,
    };

    var buffer = [_]u8{0} ** 100;

    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try suback.serialize(writer);

    const written = try stream.getPos();

    stream.reset();
    const reader = stream.reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.suback,
        .flags = 0,
        .remaining_length = @intCast(u32, written),
    };

    var deser_suback = try SubAck.parse(fixed_header, allocator, reader);
    defer deser_suback.deinit(allocator);

    try expect(suback.packet_id == deser_suback.packet_id);
    try expectEqualSlices(ReturnCode, suback.return_codes, deser_suback.return_codes);
}
