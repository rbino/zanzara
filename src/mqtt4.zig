const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const testing = std.testing;
const time = std.time;

pub const packet = @import("packet.zig");
const Packet = packet.Packet;
const PacketType = packet.PacketType;
const Connect = packet.Connect;
const ConnAck = packet.ConnAck;
const Publish = packet.Publish;
const PubAck = packet.PubAck;
const PubRec = packet.PubRec;
const PubRel = packet.PubRel;
const PubComp = packet.PubComp;
const Subscribe = packet.Subscribe;
const SubAck = packet.SubAck;
const Unsubscribe = packet.Unsubscribe;
const UnsubAck = packet.UnsubAck;
const QoS = packet.QoS;

pub const Event = struct {
    consumed: usize,
    data: EventData,
};

pub const EventData = union(enum) {
    none,
    incoming_packet: Packet,
    outgoing_buf: []const u8,
    err: anyerror,
};

const ClientState = enum {
    parse_type_and_flags,
    parse_remaining_length,
    accumulate_message,
    discard_message,
};

pub const ConnectOptions = struct {
    client_id: []const u8,
    clean_session: bool = false,
    keepalive: u16 = 30,
    will: ?Connect.Will = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

pub const PublishOptions = struct {
    qos: QoS = .qos0,
    retain: bool = false,
};

pub const Client = struct {
    const Self = @This();

    in_fba: heap.FixedBufferAllocator,

    in_buffer: []u8 = undefined,
    out_buffer: []u8 = undefined,

    should_reset_in_fba: bool = false,
    should_reset_out_end_index: bool = false,

    out_end_index: usize = 0,

    last_outgoing_instant: time.Instant,
    keepalive: ?u16 = null,

    packet_id: u16 = 1,

    state: ClientState = .parse_type_and_flags,
    packet_type: PacketType = undefined,
    flags: u4 = undefined,
    remaining_length: u32 = 0,
    length_multiplier: u32 = 1,

    const remaining_length_mask: u8 = 127;

    pub fn init(in_buffer: []u8, out_buffer: []u8) !Self {
        return Self{
            .in_fba = heap.FixedBufferAllocator.init(in_buffer),
            .out_buffer = out_buffer,
            .last_outgoing_instant = time.Instant.now() catch return error.NoClock,
        };
    }

    pub fn connect(self: *Self, opts: ConnectOptions) !void {
        const pkt = Connect{
            .client_id = opts.client_id,
            .clean_session = opts.clean_session,
            .keepalive = opts.keepalive,
            .will = opts.will,
            .username = opts.username,
            .password = opts.password,
        };

        try self.serializePacket(.{ .connect = pkt });
        self.keepalive = opts.keepalive;
    }

    pub fn subscribe(self: *Self, topics: []const Subscribe.Topic) !void {
        const pkt = Subscribe{
            .packet_id = self.getPacketId(),
            .topics = topics,
        };

        try self.serializePacket(.{ .subscribe = pkt });
    }

    pub fn publish(self: *Self, topic: []const u8, payload: []const u8, opts: PublishOptions) !void {
        // TODO: support qos1 and qos2
        if (opts.qos != .qos0) return error.UnsupportedQoS;

        const pkt = Publish{
            .topic = topic,
            .payload = payload,
            .qos = opts.qos,
            .packet_id = if (opts.qos == .qos0) null else self.getPacketId(),
            .retain = opts.retain,
        };

        try self.serializePacket(.{ .publish = pkt });
    }

    pub fn feed(self: *Self, in: []const u8) Event {
        // Check if we need to free up memory after emitting an event
        if (self.should_reset_in_fba) {
            self.in_fba.reset();
            self.should_reset_in_fba = false;
        }
        if (self.should_reset_out_end_index) {
            self.out_end_index = 0;
            self.should_reset_out_end_index = false;
        }

        if (self.out_end_index > 0) {
            // We have some data in the out buffer, emit an event
            self.should_reset_out_end_index = true;
            self.last_outgoing_instant = time.Instant.now() catch unreachable;
            return Event{
                .consumed = 0,
                .data = .{ .outgoing_buf = self.out_buffer[0..self.out_end_index] },
            };
        }

        if (self.keepalive) |keepalive| {
            const now = time.Instant.now() catch unreachable;
            if (now.since(self.last_outgoing_instant) > @intCast(u64, keepalive) * time.ns_per_s) {
                self.pingReq() catch |err|
                    return Event{ .consumed = 0, .data = .{ .err = err } };
            }
        }

        var consumed: usize = 0;
        var rest = in;
        while (rest.len > 0) : (rest = in[consumed..]) {
            switch (self.state) {
                .parse_type_and_flags => {
                    // Reinitialize variable length variables
                    self.remaining_length = 0;
                    self.length_multiplier = 1;

                    const type_and_flags: u8 = rest[0];
                    consumed += 1;
                    self.packet_type = @intToEnum(PacketType, @intCast(u4, type_and_flags >> 4));
                    self.flags = @intCast(u4, type_and_flags & 0b1111);
                    self.state = .parse_remaining_length;
                },

                .parse_remaining_length => {
                    const byte = rest[0];
                    consumed += 1;
                    self.remaining_length += (byte & remaining_length_mask) * self.length_multiplier;
                    if (byte & 128 != 0) {
                        // Stay in same state and increase the multiplier
                        self.length_multiplier *= 128;
                        if (self.length_multiplier > 128 * 128 * 128)
                            // TODO: this actually will leave the client in an invalid state, should we panic?
                            return Event{
                                .consumed = consumed,
                                .data = .{ .err = error.InvalidLength },
                            };
                    } else {
                        const allocator = self.in_fba.allocator();
                        self.in_buffer = allocator.alloc(u8, self.remaining_length) catch |err| {
                            self.state = .discard_message;
                            return Event{
                                .consumed = consumed,
                                .data = .{ .err = err },
                            };
                        };
                        self.state = .accumulate_message;
                    }
                },

                .accumulate_message => {
                    if (rest.len >= self.remaining_length) {
                        // We completed the message
                        mem.copy(u8, self.in_buffer, rest[0..self.remaining_length]);
                        consumed += self.remaining_length;

                        // Reset the in memory at the next round
                        self.should_reset_in_fba = true;
                        self.state = .parse_type_and_flags;

                        const pkt = packet.parse(self.packet_type, self.in_buffer, self.flags) catch |err| {
                            return Event{
                                .consumed = consumed,
                                .data = .{ .err = err },
                            };
                        };

                        return Event{
                            .consumed = consumed,
                            .data = .{ .incoming_packet = pkt },
                        };
                    } else {
                        // Not enough data for us, take what it's there and stay in this state
                        mem.copy(u8, self.in_buffer, rest);
                        consumed += rest.len;
                        self.remaining_length -= @intCast(u32, rest.len);
                    }
                },

                .discard_message => {
                    // We're here because the message doesn't fit in our in_buffer
                    // Just mark as consumed until we arrive to remaining length
                    if (rest.len >= self.remaining_length) {
                        consumed += self.remaining_length;
                        self.state = .parse_type_and_flags;
                    } else {
                        consumed += rest.len;
                        self.remaining_length -= @intCast(u32, rest.len);
                    }
                },
            }
        }

        // If we didn't return an event yet, mark all data as consumed with no event
        return Event{ .consumed = consumed, .data = .none };
    }

    fn pingReq(self: *Self) !void {
        try self.serializePacket(.pingreq);
    }

    fn serializePacket(self: *Self, pkt: Packet) !void {
        // TODO: we probably need a lock here since that's called both by the internal logic
        // and by external callers
        const length = try pkt.serializedLength();
        const out_begin = self.out_end_index;
        const out_end = out_begin + length;
        if (out_end > self.out_buffer.len) return error.OutOfMemory;
        try pkt.serialize(self.out_buffer[out_begin..out_end]);
        self.out_end_index += length;
    }

    fn getPacketId(self: *Self) u16 {
        // TODO: this currently doesn't handle the fact that the client id is not allowed
        // to be 0 by the spec
        return @atomicRmw(u16, &self.packet_id, .Add, 1, .Monotonic);
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "connack gets parsed" {
    var buffers: [2048]u8 = undefined;

    var client = try Client.init(buffers[0..1024], buffers[1024..]);

    const input =
        // Type (connack) and flags (0)
        "\x20" ++
        // Remaining length (2)
        "\x02" ++
        // Session present flag to true
        "\x01" ++
        // ok return code
        "\x00";

    const event = client.feed(input);

    try testing.expect(event.consumed == input.len);
    try testing.expect(event.data.incoming_packet == .connack);
    const connack = event.data.incoming_packet.connack;
    try testing.expect(connack.session_present == true);
    try testing.expect(connack.return_code == .ok);
}

test "connack gets parsed chunked" {
    var buffers: [2048]u8 = undefined;

    var client = try Client.init(buffers[0..1024], buffers[1024..]);

    const input_1 =
        // Type (connack) and flags (0)
        "\x20" ++
        // Remaining length (2)
        "\x02";

    const event_1 = client.feed(input_1);

    try testing.expect(event_1.consumed == 2);
    try testing.expect(event_1.data == .none);

    const input_2 =
        // Session present flag to false
        "\x00" ++
        // invalid client id return code
        "\x02";

    const event_2 = client.feed(input_2);

    try testing.expect(event_2.consumed == 2);
    try testing.expect(event_2.data.incoming_packet == .connack);
    const connack = event_2.data.incoming_packet.connack;
    try testing.expect(connack.session_present == false);
    try testing.expect(connack.return_code == .invalid_client_id);
}

test "publish gets parsed" {
    var buffers: [2048]u8 = undefined;

    var client = try Client.init(buffers[0..1024], buffers[1024..]);

    const input =
        // Type (publish) and flags (qos 1, retain true)
        "\x33" ++
        // Remaining length (14)
        "\x0e" ++
        // Topic length, 7
        "\x00\x07" ++
        // Topic
        "foo/bar" ++
        // Packet ID, 42
        "\x00\x2a" ++
        // payload
        "baz";

    const event = client.feed(input);

    try testing.expect(event.consumed == input.len);
    try testing.expect(event.data.incoming_packet == .publish);
    const publish = event.data.incoming_packet.publish;
    try testing.expect(publish.qos == .qos1);
    try testing.expect(publish.duplicate == false);
    try testing.expect(publish.retain == true);
    try testing.expect(publish.packet_id.? == 42);
    try testing.expectEqualSlices(u8, publish.topic, "foo/bar");
    try testing.expectEqualSlices(u8, publish.payload, "baz");
}

test "publish longer than the input buffer returns OutOfMemory and gets discarded" {
    var buffers: [16]u8 = undefined;

    var client = try Client.init(buffers[0..8], buffers[8..]);

    const input =
        // Type (publish) and flags (qos 1, retain true)
        "\x33" ++
        // Remaining length (14)
        "\x0e" ++
        // Topic length, 7
        "\x00\x07" ++
        // Topic
        "foo/bar" ++
        // Packet ID, 42
        "\x00\x2a" ++
        // payload
        "baz";

    const event_1 = client.feed(input);

    try testing.expect(event_1.data.err == error.OutOfMemory);
    try testing.expect(event_1.consumed == 2);
    const event_2 = client.feed(input[event_1.consumed..]);
    try testing.expect(event_2.data == .none);
    try testing.expect(event_2.consumed == input.len - 2);
}

test "connect gets serialized" {
    var buffers: [2048]u8 = undefined;

    var client = try Client.init(buffers[0..1024], buffers[1024..]);
    const opts = .{ .client_id = "foobar" };
    try client.connect(opts);

    const event = client.feed("");

    try testing.expect(event.data == .outgoing_buf);
    const buf = event.data.outgoing_buf;
    const expected =
        // Type (connect) and flags (0)
        "\x10" ++
        // Remaining length (18)
        "\x12" ++
        // Protocol name length (4)
        "\x00\x04" ++
        // Protocol name
        "MQTT" ++
        // Protocol level (4)
        "\x04" ++
        // Flags (all 0)
        "\x00" ++
        // Keepalive (30)
        "\x00\x1e" ++
        // Client id length (6)
        "\x00\x06" ++
        // Client id
        "foobar";

    try testing.expectEqualSlices(u8, expected, buf);
}
