const expect = std.testing.expect;
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ConnAck = struct {
    session_present: bool,
    return_code: ReturnCode,

    const Flags = packed struct {
        session_present: bool,
        _reserved: u7 = 0,
    };

    pub const ReturnCode = enum(u8) {
        ok = 0,
        unacceptable_protocol_version,
        invalid_client_id,
        server_unavailable,
        malformed_credentials,
        unauthorized,
    };

    // TODO: this doesn't actually need to allocate, do we lean towards a consistent API
    // or just pass an allocator if we need to?
    pub fn parse(allocator: *Allocator, reader: anytype) !ConnAck {
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

    pub fn deinit(self: *ConnAck, allocator: *Allocator) void {}
};

test "ConnAck payload parsing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // Check no leaks
    defer expect(!gpa.deinit());

    const allocator = &gpa.allocator;

    const buffer =
        // Session present flag to true
        "\x01" ++
        // ok return code
        "\x00";
    const stream = std.io.fixedBufferStream(buffer).reader();
    var connack = try ConnAck.parse(allocator, stream);
    defer connack.deinit(allocator);

    expect(connack.session_present == true);
    expect(connack.return_code == ConnAck.ReturnCode.ok);
}
