const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
const expectError = std.testing.expectError;
const std = @import("std");
const utils = @import("../../utils.zig");
const Allocator = std.mem.Allocator;
const FixedHeader = Packet.FixedHeader;
const Packet = @import("../packet.zig").Packet;
const QoS = @import("../../qos.zig").QoS;

pub const Will = struct {
    topic: []const u8,
    message: []const u8,
    retain: bool,
    qos: QoS,
};

pub const Connect = struct {
    clean_session: bool,
    keepalive: u16,
    client_id: []const u8,
    will: ?Will = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,

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
            if (flags.will_qos > 2) {
                return ParseError.InvalidWillQoS;
            }
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

    pub fn serializedLength(self: Connect) u32 {
        // Fixed initial fields: protocol name, protocol level, flags and keepalive
        var length: u32 = comptime utils.serializedMQTTStringLen("MQTT") + @sizeOf(u8) + @sizeOf(Flags) + @sizeOf(@TypeOf(self.keepalive));

        length += utils.serializedMQTTStringLen(self.client_id);

        if (self.will) |will| {
            length += utils.serializedMQTTStringLen(will.message);
            length += utils.serializedMQTTStringLen(will.topic);
            // Will retain and qos go in flags, no space needed
        }

        if (self.username) |username| {
            length += utils.serializedMQTTStringLen(username);
        }

        if (self.password) |password| {
            length += utils.serializedMQTTStringLen(password);
        }

        return length;
    }

    pub fn serialize(self: Connect, writer: anytype) !void {
        try utils.writeMQTTString("MQTT", writer);
        // Protocol version
        try writer.writeByte(4);

        // Extract info from Will, if there's one
        var will_message: ?[]const u8 = null;
        var will_topic: ?[]const u8 = null;
        var will_qos = QoS.qos0;
        var will_retain = false;
        if (self.will) |will| {
            will_topic = will.topic;
            will_message = will.message;
            will_qos = will.qos;
            will_retain = will.retain;
        }

        const flags = Flags{
            .clean_session = self.clean_session,
            .will_flag = self.will != null,
            .will_qos = @enumToInt(will_qos),
            .will_retain = will_retain,
            .password_flag = self.password != null,
            .username_flag = self.username != null,
        };
        const flags_byte = @bitCast(u8, flags);
        try writer.writeByte(flags_byte);

        try writer.writeIntBig(u16, self.keepalive);

        try utils.writeMQTTString(self.client_id, writer);

        if (will_topic) |wt| {
            try utils.writeMQTTString(wt, writer);
        }

        if (will_message) |wm| {
            try utils.writeMQTTString(wm, writer);
        }

        if (self.username) |username| {
            try utils.writeMQTTString(username, writer);
        }

        if (self.password) |password| {
            try utils.writeMQTTString(password, writer);
        }
    }

    pub fn fixedHeaderFlags(self: Connect) u4 {
        return 0b0000;
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
    const allocator = std.testing.allocator;

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

    try expect(connect.clean_session == false);
    try expect(connect.keepalive == 60);
    try expect(connect.client_id.len == 0);
    try expect(connect.will == null);
    try expect(connect.username == null);
    try expect(connect.password == null);
}

test "full Connect payload parsing" {
    const allocator = std.testing.allocator;

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

    try expect(connect.clean_session == true);
    try expect(connect.keepalive == 60);
    try expect(std.mem.eql(u8, connect.client_id, "foobar"));
    try expect(std.mem.eql(u8, connect.username.?, "user"));
    try expect(std.mem.eql(u8, connect.password.?, "password1"));

    const will = connect.will.?;
    try expect(will.retain == true);
    try expect(std.mem.eql(u8, will.topic, "my/will"));
    try expect(std.mem.eql(u8, will.message, "kbyethanks"));
    try expect(will.qos == QoS.qos2);
}

test "FixedHeader indicating a smaller remaining length makes parsing fail" {
    const allocator = std.testing.allocator;

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

    const result = Connect.parse(fixed_header, allocator, stream);
    try expectError(error.EndOfStream, result);
}

test "invalid protocol fails" {
    const allocator = std.testing.allocator;

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

    const result = Connect.parse(fixed_header, allocator, stream);
    try expectError(error.InvalidProtocolName, result);
}

test "invalid protocol version fails" {
    const allocator = std.testing.allocator;

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

    const result = Connect.parse(fixed_header, allocator, stream);
    try expectError(error.InvalidProtocolLevel, result);
}

test "invalid will QoS fails" {
    const allocator = std.testing.allocator;

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

    const result = Connect.parse(fixed_header, allocator, stream);
    try expectError(error.InvalidWillQoS, result);
}

test "serialize/parse roundtrip" {
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

    var buffer = [_]u8{0} ** 100;

    var stream = std.io.fixedBufferStream(&buffer);
    var writer = stream.writer();

    try connect.serialize(writer);

    const written = try stream.getPos();

    stream.reset();
    const reader = stream.reader();

    const PacketType = @import("../packet.zig").PacketType;
    const fixed_header = FixedHeader{
        .packet_type = PacketType.connect,
        .flags = 0,
        .remaining_length = @intCast(u32, written),
    };

    const allocator = std.testing.allocator;

    var deser_connect = try Connect.parse(fixed_header, allocator, reader);
    defer deser_connect.deinit(allocator);

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
