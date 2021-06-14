const net = std.net;
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const Connect = @import("./packet/connect.zig").Connect;
const Packet = @import("./packet.zig").Packet;
const Publish = @import("./packet/publish.zig").Publish;
const QoS = @import("../qos.zig").QoS;
const Subscribe = @import("./packet/subscribe.zig").Subscribe;
const Topic = @import("./packet/subscribe.zig").Topic;
pub const Will = @import("./packet/connect.zig").Will;

pub const ConnectOptions = struct {
    clean_session: bool = false,
    client_id: []const u8 = "zanzara", // TODO: this should be randomly generated if it's not passed by the user
    keepalive: u16 = 30,
    will: ?Will = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

pub const PublishOptions = struct {
    duplicate: bool = false,
    qos: QoS = .qos0,
    retain: bool = false,
};

pub const Error = error{
    InvalidClientId,
    MalformedCredentials,
    NotImplemented,
    ServerUnavailable,
    Unauthorized,
    UnexpectedResponse,
};

pub const Client = struct {
    conn: net.Stream,
    reader: net.Stream.Reader,
    writer: net.Stream.Writer,
    allocator: *Allocator,
    packet_id: u16 = 0,

    const Self = @This();

    pub fn init(self: *Self, host: []const u8, port: u16, allocator: *Allocator) !void {
        // Connect
        const conn = try net.tcpConnectToHost(allocator, host, port);

        self.conn = conn;
        self.reader = conn.reader();
        self.writer = conn.writer();
        self.allocator = allocator;
    }

    pub fn connect(self: *Self, opts: ConnectOptions) !void {
        const conn = Connect{
            .clean_session = opts.clean_session,
            .client_id = opts.client_id,
            .keepalive = opts.keepalive,
            .will = opts.will,
            .username = opts.username,
            .password = opts.password,
        };

        const pkt = Packet{ .connect = conn };
        try pkt.serialize(self.writer);

        var response = try Packet.parse(self.allocator, self.reader);
        defer response.deinit(self.allocator);

        if (response == .connack) {
            const connack = response.connack;
            switch (connack.return_code) {
                .ok => return,
                .invalid_client_id => return error.InvalidClientId,
                .server_unavailable => return error.ServerUnavailable,
                .malformed_credentials => return error.MalformedCredentials,
                .unauthorized => return error.Unauthorized,
                .unacceptable_protocol_version => unreachable, //  This is an implementation error
            }
        } else {
            return error.UnexpectedResponse;
        }
    }

    pub fn publish(self: *Self, topic: []const u8, payload: []const u8, opts: PublishOptions) !void {
        const packet_id =
            switch (opts.qos) {
            // TODO: add support for QoS1 and QoS2 and return nextPacketId()
            .qos1, .qos2 => return error.NotImplemented,
            else => null,
        };

        const publ = Publish{
            .duplicate = opts.duplicate,
            .qos = opts.qos,
            .retain = opts.retain,
            .packet_id = packet_id,
            .topic = topic,
            .payload = payload,
        };

        const pkt = Packet{ .publish = publ };
        try pkt.serialize(self.writer);
    }

    pub fn subscribe(self: *Self, topic_filter: []const u8, qos: QoS) !void {
        var topics = [_]Topic{.{
            .topic_filter = topic_filter,
            .qos = qos,
        }};

        const sub = Subscribe{
            .packet_id = self.nextPacketId(),
            .topics = &topics,
        };

        const pkt = Packet{ .subscribe = sub };
        try pkt.serialize(self.writer);
    }

    fn nextPacketId(self: *Self) u16 {
        self.packet_id = self.packet_id +% 1;
        // TODO: mark this as unlikely when language support is there
        if (self.packet_id == 0) {
            self.packet_id = 1;
        }

        return self.packet_id;
    }
};
