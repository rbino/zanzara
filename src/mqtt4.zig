const std = @import("std");
const heap = std.heap;
const mem = std.mem;
const testing = std.testing;

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

pub const Event = struct {
    consumed: usize,
    data: EventData,
};

pub const EventData = union(enum) {
    none,
    incoming_packet: Packet,
    err: anyerror,
};

const ClientState = enum {
    parse_type_and_flags,
    parse_remaining_length,
    accumulate_message,
    discard_message,
};

pub const Client = struct {
    const Self = @This();

    in_fba: heap.FixedBufferAllocator,

    in_buffer: []u8 = undefined,
    out_buffer: []u8 = undefined,

    should_reset_in_fba: bool = false,
    should_reset_out_end_index: bool = false,

    state: ClientState = .parse_type_and_flags,
    packet_type: PacketType = undefined,
    flags: u4 = undefined,
    remaining_length: u32 = 0,
    length_multiplier: u32 = 1,

    const remaining_length_mask: u8 = 127;

    pub fn init(in_buffer: []u8, out_buffer: []u8) Self {
        return Self{
            .in_fba = heap.FixedBufferAllocator.init(in_buffer),
            .out_buffer = out_buffer,
        };
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

        // TODO: perform housekeeping first, e.g. check if we need to send ping, acks etc

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
};

test {
    std.testing.refAllDecls(@This());
}

test "connack gets parsed" {
    var buffers: [2048]u8 = undefined;

    var client = Client.init(buffers[0..1024], buffers[1024..]);

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

    var client = Client.init(buffers[0..1024], buffers[1024..]);

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

    var client = Client.init(buffers[0..1024], buffers[1024..]);

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

    var client = Client.init(buffers[0..8], buffers[8..]);

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
