const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const testing = std.testing;
const time = std.time;
const BoundedArray = std.BoundedArray;

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

pub const ClientConfig = struct {
    max_pending_pubrec: usize = 128,
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

pub const DefaultClient = Client(.{});
pub fn Client(config: ClientConfig) type {
    return struct {
        const Self = @This();
        const max_pending_pubrec = config.max_pending_pubrec;

        in_fba: heap.FixedBufferAllocator,

        in_buffer: []u8 = undefined,
        out_buffer: []u8 = undefined,

        should_reset_in_fba: bool = false,
        should_reset_out_end_index: bool = false,

        out_end_index: usize = 0,

        last_outgoing_instant: time.Instant,
        keepalive: ?u16 = null,

        packet_id: u16 = 1,

        pending_pubrecs: BoundedArray(u16, max_pending_pubrec),

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
                .pending_pubrecs = BoundedArray(u16, max_pending_pubrec).init(0) catch unreachable,
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

        pub fn disconnect(self: *Self) !void {
            try self.serializePacket(.disconnect);
        }

        pub fn subscribe(self: *Self, topics: []const Subscribe.Topic) !u16 {
            const pkt = Subscribe{
                .packet_id = self.getPacketId(),
                .topics = topics,
            };

            try self.serializePacket(.{ .subscribe = pkt });

            return pkt.packet_id;
        }

        pub fn unsubscribe(self: *Self, topic_filters: []const []const u8) !u16 {
            const pkt = Unsubscribe{
                .packet_id = self.getPacketId(),
                .topic_filters = topic_filters,
            };

            try self.serializePacket(.{ .unsubscribe = pkt });

            return pkt.packet_id;
        }

        pub fn publish(self: *Self, topic: []const u8, payload: []const u8, opts: PublishOptions) !?u16 {
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

            return pkt.packet_id;
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

                            const pkt = Packet.parse(self.packet_type, self.in_buffer, self.flags) catch |err| {
                                return Event{
                                    .consumed = consumed,
                                    .data = .{ .err = err },
                                };
                            };

                            const data = self.handlePacket(pkt);

                            return Event{
                                .consumed = consumed,
                                .data = data,
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

        // We don't fail here if we can't serialize in pubAck, pubRec and pubComp
        // The server will resend us the payload if it doesn't see the ack,
        // and we'll have another chance to ack it
        fn pubAck(self: *Self, packet_id: u16) !void {
            const pkt = .{ .packet_id = packet_id };
            try self.serializePacket(.{ .puback = pkt });
        }

        fn pubRec(self: *Self, packet_id: u16) !void {
            var ptrToLast = try self.pending_pubrecs.addOne();
            ptrToLast.* = packet_id;

            const pkt = .{ .packet_id = packet_id };
            try self.serializePacket(.{ .pubrec = pkt });
        }

        fn pubComp(self: *Self, packet_id: u16) !void {
            if (self.pendingPubRecIndex(packet_id)) |idx|
                _ = self.pending_pubrecs.swapRemove(idx);

            const pkt = .{ .packet_id = packet_id };
            try self.serializePacket(.{ .pubcomp = pkt });
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

        fn handlePacket(self: *Self, pkt: Packet) EventData {
            // Process acks and deduplicate QoS 2 messages
            // For QoS 2 we're using Method B illustrated in Figure 4.3 in the MQTT 3.1.1 spec
            switch (pkt) {
                .publish => |p| switch (p.qos) {
                    .qos0 => {},
                    .qos1 => {
                        // Ignore failure: a failed PubAck will just lead the sender to resend its
                        // Publish. The application will receive a duplicate message, but this is
                        // allowed with QoS 1
                        self.pubAck(p.packet_id.?) catch {};
                    },
                    .qos2 => {
                        const packet_id = p.packet_id.?;
                        // Check if it's a duplicate, if it is don't deliver the publish to the
                        // application
                        // TODO: mark as @cold when there's language support
                        if (self.pendingPubRecIndex(packet_id) != null) return .none;

                        // Here we have two possible failures: either we can't store the packet id or
                        // we can't send the PubRec
                        self.pubRec(p.packet_id.?) catch |err| {
                            if (err == error.Overflow) {
                                // If we can't store the packet id, we return .none as data, because
                                // delivering the Publish to the application would cause a duplicate
                                // delivery later on
                                return .none;
                            }
                            // Otherwise, we just ignore failure. If we fail to deliver PubRec the
                            // sender will resend the Publish, but we won't deliver it to the
                            // application because we already check for duplicates above.
                        };
                    },
                },
                .pubrel => |p| {
                    // Ignore failure: a failed PubAck will just lead the sender to resend its
                    // Publish. The application will not see anything strange.
                    self.pubComp(p.packet_id) catch {};
                },
                else => {},
            }

            return .{ .incoming_packet = pkt };
        }

        fn pendingPubRecIndex(self: Self, packet_id: u16) ?usize {
            for (self.pending_pubrecs.constSlice()) |id, i| {
                if (id == packet_id) return i;
            }

            return null;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "connack gets parsed" {
    var buffers: [2048]u8 = undefined;

    var client = try DefaultClient.init(buffers[0..1024], buffers[1024..]);

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

    var client = try DefaultClient.init(buffers[0..1024], buffers[1024..]);

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

    var client = try DefaultClient.init(buffers[0..1024], buffers[1024..]);

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

    var client = try DefaultClient.init(buffers[0..8], buffers[8..]);

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

    var client = try DefaultClient.init(buffers[0..1024], buffers[1024..]);
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

test "disconnect gets serialized" {
    var buffers: [2048]u8 = undefined;

    var client = try DefaultClient.init(buffers[0..1024], buffers[1024..]);
    try client.disconnect();

    const event = client.feed("");

    try testing.expect(event.data == .outgoing_buf);
    const buf = event.data.outgoing_buf;
    const expected =
        // Type (disconnect) and flags (0)
        "\xe0" ++
        // Remaining length (0)
        "\x00";

    try testing.expectEqualSlices(u8, expected, buf);
}

test "qos0 incoming publish" {
    var buffers: [2048]u8 = undefined;

    var client = try DefaultClient.init(buffers[0..1024], buffers[1024..]);

    const input =
        // Type (publish) and flags (qos 0)
        "\x30" ++
        // Remaining length (12)
        "\x0c" ++
        // Topic length, 7
        "\x00\x07" ++
        // Topic
        "foo/bar" ++
        // payload
        "baz";

    const event_1 = client.feed(input);

    try testing.expect(event_1.consumed == input.len);
    try testing.expect(event_1.data.incoming_packet == .publish);
    const publish = event_1.data.incoming_packet.publish;
    try testing.expect(publish.qos == .qos0);
    try testing.expect(publish.duplicate == false);
    try testing.expect(publish.retain == false);
    try testing.expect(publish.packet_id == null);
    try testing.expectEqualSlices(u8, publish.topic, "foo/bar");
    try testing.expectEqualSlices(u8, publish.payload, "baz");

    // No acks sent
    const event_2 = client.feed("");
    try testing.expectEqual(event_2.data, .none);
}

test "qos1 incoming publish" {
    var buffers: [2048]u8 = undefined;

    var client = try DefaultClient.init(buffers[0..1024], buffers[1024..]);

    const input =
        // Type (publish) and flags (qos 1)
        "\x32" ++
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
    try testing.expect(publish.retain == false);
    try testing.expect(publish.packet_id.? == 42);
    try testing.expectEqualSlices(u8, publish.topic, "foo/bar");
    try testing.expectEqualSlices(u8, publish.payload, "baz");

    // PubAck sent
    const event_2 = client.feed("");
    try testing.expect(event_2.data == .outgoing_buf);
    const expected =
        // Type (puback) and flags (0)
        "\x40" ++
        // Remaining length (2)
        "\x02" ++
        // Packet ID, 42
        "\x00\x2a";
    try testing.expectEqualSlices(u8, expected, event_2.data.outgoing_buf);
}

test "qos2 incoming publish" {
    var buffers: [2048]u8 = undefined;

    var client = try DefaultClient.init(buffers[0..1024], buffers[1024..]);

    const input =
        // Type (publish) and flags (qos 2)
        "\x34" ++
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
    try testing.expect(publish.qos == .qos2);
    try testing.expect(publish.duplicate == false);
    try testing.expect(publish.retain == false);
    try testing.expect(publish.packet_id.? == 42);
    try testing.expectEqualSlices(u8, publish.topic, "foo/bar");
    try testing.expectEqualSlices(u8, publish.payload, "baz");

    // PubRec sent
    const event_2 = client.feed("");
    try testing.expect(event_2.data == .outgoing_buf);
    const expected_2 =
        // Type (pubrec) and flags (0)
        "\x50" ++
        // Remaining length (2)
        "\x02" ++
        // Packet ID, 42
        "\x00\x2a";
    try testing.expectEqualSlices(u8, expected_2, event_2.data.outgoing_buf);
    try testing.expect(client.pending_pubrecs.len == 1);
    try testing.expect(client.pending_pubrecs.get(0) == 42);

    const input_2 =
        // Type (pubrel) and flags (qos 1)
        "\x64" ++
        // Remaining length (14)
        "\x02" ++
        // Packet ID, 42
        "\x00\x2a";

    const event_3 = client.feed(input_2);

    try testing.expect(event_3.consumed == input_2.len);
    try testing.expect(event_3.data.incoming_packet == .pubrel);
    const pubrel = event_3.data.incoming_packet.pubrel;
    try testing.expect(pubrel.packet_id == 42);

    // PubComp sent
    const event_4 = client.feed("");
    try testing.expect(event_4.data == .outgoing_buf);
    const expected_4 =
        // Type (pubcomp) and flags (0)
        "\x70" ++
        // Remaining length (2)
        "\x02" ++
        // Packet ID, 42
        "\x00\x2a";
    try testing.expectEqualSlices(u8, expected_4, event_4.data.outgoing_buf);
    try testing.expect(client.pending_pubrecs.len == 0);
}

test "qos2 duplicate incoming publish and pubrel" {
    var buffers: [2048]u8 = undefined;

    var client = try DefaultClient.init(buffers[0..1024], buffers[1024..]);

    const input =
        // Type (publish) and flags (qos 2)
        "\x34" ++
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
    try testing.expect(publish.qos == .qos2);
    try testing.expect(publish.duplicate == false);
    try testing.expect(publish.retain == false);
    try testing.expect(publish.packet_id.? == 42);
    try testing.expectEqualSlices(u8, publish.topic, "foo/bar");
    try testing.expectEqualSlices(u8, publish.payload, "baz");

    const input_dup =
        // Type (publish) and flags (duplicate, qos 2)
        "\x3c" ++
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

    // PubRec sent
    const event_2 = client.feed("");
    try testing.expect(event_2.data == .outgoing_buf);
    const expected_2 =
        // Type (pubrec) and flags (0)
        "\x50" ++
        // Remaining length (2)
        "\x02" ++
        // Packet ID, 42
        "\x00\x2a";
    try testing.expectEqualSlices(u8, expected_2, event_2.data.outgoing_buf);
    try testing.expect(client.pending_pubrecs.len == 1);
    try testing.expect(client.pending_pubrecs.get(0) == 42);

    const event_3 = client.feed(input_dup);
    // The input should get consumed, but the publish should not be emitted to the application
    try testing.expect(event_3.consumed == input_dup.len);
    try testing.expect(event_3.data == .none);

    const input_2 =
        // Type (pubrel) and flags (qos 1)
        "\x64" ++
        // Remaining length (14)
        "\x02" ++
        // Packet ID, 42
        "\x00\x2a";

    const event_4 = client.feed(input_2);

    try testing.expect(event_4.consumed == input_2.len);
    try testing.expect(event_4.data.incoming_packet == .pubrel);
    const pubrel = event_4.data.incoming_packet.pubrel;
    try testing.expect(pubrel.packet_id == 42);

    // PubComp sent
    const event_5 = client.feed("");
    try testing.expect(event_5.data == .outgoing_buf);
    const expected_5 =
        // Type (pubcomp) and flags (0)
        "\x70" ++
        // Remaining length (2)
        "\x02" ++
        // Packet ID, 42
        "\x00\x2a";
    try testing.expectEqualSlices(u8, expected_5, event_5.data.outgoing_buf);
    try testing.expect(client.pending_pubrecs.len == 0);

    // If we receive another duplicate PubRel, we just answer again with a PubComp
    const event_6 = client.feed(input_2);
    try testing.expect(event_6.consumed == input_2.len);
    try testing.expect(event_6.data.incoming_packet == .pubrel);
    const pubrel_dup = event_6.data.incoming_packet.pubrel;
    try testing.expect(pubrel_dup.packet_id == 42);

    const event_7 = client.feed("");
    try testing.expect(event_7.data == .outgoing_buf);
    const expected_7 =
        // Type (pubcomp) and flags (0)
        "\x70" ++
        // Remaining length (2)
        "\x02" ++
        // Packet ID, 42
        "\x00\x2a";
    try testing.expectEqualSlices(u8, expected_7, event_7.data.outgoing_buf);
    try testing.expect(client.pending_pubrecs.len == 0);
}
