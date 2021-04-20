const expect = std.testing.expect;
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Connect = struct {
    flags: Flags,
    keepalive: u16,
    client_id: ?[]const u8,
    will: ?Will,
    username: ?[]const u8,
    password: ?[]const u8,

    pub const Will = struct {
        topic: []const u8,
        message: []const u8,
    };

    pub const Flags = packed struct {
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

    pub fn parse(allocator: *Allocator, reader: anytype) !Connect {
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

        const keepalive = try reader.readIntBig(u16);

        const client_id_length = try reader.readIntBig(u16);
        var client_id: ?[]u8 = null;
        if (client_id_length > 0) {
            client_id = try allocator.alloc(u8, client_id_length);
            errdefer allocator.free(client_id);
            _ = try reader.read(client_id.?);
        }

        var will: ?Will = null;
        if (flags.will_flag) {
            const will_topic_length = try reader.readIntBig(u16);
            var will_topic = try allocator.alloc(u8, will_topic_length);
            errdefer allocator.free(will_topic);
            _ = try reader.read(will_topic);

            const will_message_length = try reader.readIntBig(u16);
            var will_message = try allocator.alloc(u8, will_message_length);
            errdefer allocator.free(will_message);
            _ = try reader.read(will_message);

            will = Will{
                .topic = will_topic,
                .message = will_message,
            };
        }

        var username: ?[]u8 = null;
        if (flags.username_flag) {
            const username_length = try reader.readIntBig(u16);
            username = try allocator.alloc(u8, username_length);
            errdefer allocator.free(username);
            _ = try reader.read(username.?);
        }

        var password: ?[]u8 = null;
        if (flags.password_flag) {
            const password_length = try reader.readIntBig(u16);
            password = try allocator.alloc(u8, password_length);
            errdefer allocator.free(password);
            _ = try reader.read(password.?);
        }

        return Connect{
            .flags = flags,
            .keepalive = keepalive,
            .client_id = client_id,
            .will = will,
            .username = username,
            .password = password,
        };
    }

    pub fn deinit(self: *Connect, allocator: *Allocator) void {
        if (self.client_id) |client_id| {
            allocator.free(client_id);
        }

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
    var connect = try Connect.parse(allocator, stream);
    defer connect.deinit(allocator);

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
    var connect = try Connect.parse(allocator, stream);
    defer connect.deinit(allocator);

    expect(connect.keepalive == 60);
    expect(std.mem.eql(u8, connect.client_id.?, "foobar"));
    expect(std.mem.eql(u8, connect.username.?, "user"));
    expect(std.mem.eql(u8, connect.password.?, "password1"));

    const will = connect.will.?;
    expect(std.mem.eql(u8, will.topic, "my/will"));
    expect(std.mem.eql(u8, will.message, "kbyethanks"));

    const flags = connect.flags;

    expect(flags._reserved == 0);
    expect(flags.clean_session == true);
    expect(flags.password_flag == true);
    expect(flags.username_flag == true);
    expect(flags.will_flag == true);
    expect(flags.will_retain == true);
    expect(flags.will_qos == 2);
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
    _ = Connect.parse(allocator, stream) catch |err| {
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
    _ = Connect.parse(allocator, stream) catch |err| {
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
    _ = Connect.parse(allocator, stream) catch |err| {
        expect(err == Connect.ParseError.InvalidWillQoS);
    };
}
