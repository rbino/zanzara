const expect = std.testing.expect;
const std = @import("std");
const utils = @import("../../utils.zig");
const Allocator = std.mem.Allocator;
const FixedHeader = Packet.FixedHeader;
const Packet = @import("../packet.zig").Packet;
const QoS = @import("../../qos.zig").QoS;

pub const Connect = struct {
    clean_session: bool,
    keepalive: u16,
    client_id: []const u8,
    will: ?Will,
    username: ?[]const u8,
    password: ?[]const u8,

    pub const Will = struct {
        topic: []const u8,
        message: []const u8,
        retain: bool,
        qos: QoS,
    };

    const Flags = packed struct {
        _reserved: u1 = 0,
        clean_session: bool,
        will_flag: bool,
        will_qos: u2,
        will_retain: bool,
        password_flag: bool,
        username_flag: bool,
    };

    pub const ParseError = error{
        InvalidProtocolName,
        InvalidProtocolLevel,
        InvalidWillQoS,
    };

    pub fn parse(fixed_header: FixedHeader, allocator: *Allocator, inner_reader: anytype) !Connect {
        const reader = std.io.limitedReader(inner_reader, fixed_header.remaining_length).reader();

        const protocol_name_length = try reader.readIntBig(u16);
        var protocol_name: [4]u8 = undefined;
        _ = try reader.read(protocol_name[0..4]);
        if (protocol_name_length != 4 or !std.mem.eql(u8, protocol_name[0..4], "MQTT")) {
            return ParseError.InvalidProtocolName;
        }

        const protocol_level = try reader.readByte();
        if (protocol_level != 4) {
            return ParseError.InvalidProtocolLevel;
        }

        const flags_byte = try reader.readByte();
        const flags = @bitCast(Flags, flags_byte);
        if (flags.will_qos > 2) {
            return ParseError.InvalidWillQoS;
        }

        const clean_session = flags.clean_session;

        const keepalive = try reader.readIntBig(u16);

        const client_id = try utils.readMQTTString(allocator, reader);
        errdefer allocator.free(client_id);

        var will: ?Will = null;
        if (flags.will_flag) {
            var will_topic = try utils.readMQTTString(allocator, reader);
            errdefer allocator.free(will_topic);

            var will_message = try utils.readMQTTString(allocator, reader);
            errdefer allocator.free(will_message);

            const retain = flags.will_retain;
            const qos = @intToEnum(QoS, flags.will_qos);

            will = Will{
                .topic = will_topic,
                .message = will_message,
                .retain = retain,
                .qos = qos,
            };
        }
        errdefer {
            if (will) |w| {
                allocator.free(w.topic);
                allocator.free(w.message);
            }
        }

        var username: ?[]u8 = null;
        if (flags.username_flag) {
            username = try utils.readMQTTString(allocator, reader);
        }
        errdefer {
            if (username) |u| {
                allocator.free(u);
            }
        }

        var password: ?[]u8 = null;
        if (flags.password_flag) {
            password = try utils.readMQTTString(allocator, reader);
        }
        errdefer {
            if (password) |p| {
                allocator.free(p);
            }
        }

        return Connect{
            .clean_session = clean_session,
            .keepalive = keepalive,
            .client_id = client_id,
            .will = will,
            .username = username,
            .password = password,
        };
    }

    pub fn deinit(self: *Connect, allocator: *Allocator) void {
        allocator.free(self.client_id);

        if (self.will) |will| {
            allocator.free(will.topic);
            allocator.free(will.message);
        }

        if (self.username) |username| {
            allocator.free(username);
        }

        if (self.password) |password| {
            allocator.free(password);
        }
    }
};

test "minimal Connect payload parsing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // Check no leaks
    defer expect(!gpa.deinit());

    const allocator = &gpa.allocator;

    const buffer =
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

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.connect,
        .flags = 0,
        .remaining_length = @intCast(u32, buffer.len),
    };

    var connect = try Connect.parse(fixed_header, allocator, stream);
    defer connect.deinit(allocator);

    expect(connect.clean_session == false);
    expect(connect.keepalive == 60);
    expect(connect.client_id.len == 0);
    expect(connect.will == null);
    expect(connect.username == null);
    expect(connect.password == null);
}

test "full Connect payload parsing" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // Check no leaks
    defer expect(!gpa.deinit());

    const allocator = &gpa.allocator;

    const buffer =
        // Protocol name length
        "\x00\x04" ++
        // Protocol name
        "MQTT" ++
        // Protocol version, 4 == 3.1.1
        "\x04" ++
        // Flags all set, will QoS 2, reserved bit 0
        [_]u8{0b11110110} ++
        // Keepalive, 60
        "\x00\x3c" ++
        // Client id length, 6
        "\x00\x06" ++
        // Client id
        "foobar" ++
        // Will topic length, 7
        "\x00\x07" ++
        // Will topic
        "my/will" ++
        // Will message length, 10
        "\x00\x0a" ++
        // Will message
        "kbyethanks" ++
        // Username length, 4
        "\x00\x04" ++
        // Username
        "user" ++
        // Password length, 9
        "\x00\x09" ++
        // Password
        "password1";

    const stream = std.io.fixedBufferStream(buffer).reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.connect,
        .flags = 0,
        .remaining_length = @intCast(u32, buffer.len),
    };

    var connect = try Connect.parse(fixed_header, allocator, stream);
    defer connect.deinit(allocator);

    expect(connect.clean_session == true);
    expect(connect.keepalive == 60);
    expect(std.mem.eql(u8, connect.client_id, "foobar"));
    expect(std.mem.eql(u8, connect.username.?, "user"));
    expect(std.mem.eql(u8, connect.password.?, "password1"));

    const will = connect.will.?;
    expect(will.retain == true);
    expect(std.mem.eql(u8, will.topic, "my/will"));
    expect(std.mem.eql(u8, will.message, "kbyethanks"));
    expect(will.qos == QoS.qos2);
}

test "FixedHeader indicating a smaller remaining length makes parsing fail" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // Check no leaks
    defer expect(!gpa.deinit());

    const allocator = &gpa.allocator;

    const buffer =
        // Protocol name length
        "\x00\x04" ++
        // Protocol name
        "MQTT" ++
        // Protocol version, 4 == 3.1.1
        "\x04" ++
        // Flags all set, will QoS 2, reserved bit 0
        [_]u8{0b11110110} ++
        // Keepalive, 60
        "\x00\x3c" ++
        // Client id length, 6
        "\x00\x06" ++
        // Client id
        "foobar" ++
        // Will topic length, 7
        "\x00\x07" ++
        // Will topic
        "my/will" ++
        // Will message length, 10
        "\x00\x0a" ++
        // Will message
        "kbyethanks" ++
        // Username length, 4
        "\x00\x04" ++
        // Username
        "user" ++
        // Password length, 9
        "\x00\x09" ++
        // Password
        "password1";

    const stream = std.io.fixedBufferStream(buffer).reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.connect,
        .flags = 0,
        .remaining_length = 12,
    };

    _ = Connect.parse(fixed_header, allocator, stream) catch |err| {
        expect(err == error.EndOfStream);
    };
}

test "invalid protocol fails" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // Check no leaks
    defer expect(!gpa.deinit());

    const allocator = &gpa.allocator;

    const buffer =
        // Protocol name length
        "\x00\x04" ++
        // Wrong protocol name
        "WOOT";

    const stream = std.io.fixedBufferStream(buffer).reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.connect,
        .flags = 0,
        .remaining_length = @intCast(u32, buffer.len),
    };

    _ = Connect.parse(fixed_header, allocator, stream) catch |err| {
        expect(err == Connect.ParseError.InvalidProtocolName);
    };
}

test "invalid protocol version fails" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // Check no leaks
    defer expect(!gpa.deinit());

    const allocator = &gpa.allocator;

    const buffer =
        // Protocol name length
        "\x00\x04" ++
        // Protocol name
        "MQTT" ++
        // Protocol version, 42
        "\x2a";

    const stream = std.io.fixedBufferStream(buffer).reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.connect,
        .flags = 0,
        .remaining_length = @intCast(u32, buffer.len),
    };

    _ = Connect.parse(fixed_header, allocator, stream) catch |err| {
        expect(err == Connect.ParseError.InvalidProtocolLevel);
    };
}

test "invalid will QoS fails" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // Check no leaks
    defer expect(!gpa.deinit());

    const allocator = &gpa.allocator;

    const buffer =
        // Protocol name length
        "\x00\x04" ++
        // Protocol name
        "MQTT" ++
        // Protocol version, 4 == 3.1.1
        "\x04" ++
        // Flags all set, will QoS 3 (invalid), reserved bit 0
        [_]u8{0b11111110};

    const stream = std.io.fixedBufferStream(buffer).reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.connect,
        .flags = 0,
        .remaining_length = @intCast(u32, buffer.len),
    };

    _ = Connect.parse(fixed_header, allocator, stream) catch |err| {
        expect(err == Connect.ParseError.InvalidWillQoS);
    };
}
