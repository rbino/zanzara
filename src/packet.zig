const std = @import("std");
const mem = std.mem;
const io = std.io;
const testing = std.testing;

pub const QoS = enum(u2) {
    qos0 = 0,
    qos1,
    qos2,
};

pub const PacketType = enum(u4) {
    connect = 1,
    connack,
    publish,
    puback,
    pubrec,
    pubrel,
    pubcomp,
    subscribe,
    suback,
    unsubscribe,
    unsuback,
    pingreq,
    pingresp,
    disconnect,
};

pub const Packet = union(PacketType) {
    connect: Connect,
    connack: ConnAck,
    publish: Publish,
    puback: PubAck,
    pubrec: PubRec,
    pubrel: PubRel,
    pubcomp: PubComp,
    subscribe: Subscribe,
    suback: SubAck,
    unsubscribe: Unsubscribe,
    unsuback: UnsubAck,
    // Empty packets, no need for backing struct
    pingreq,
    pingresp,
    disconnect,
};

pub const Connect = struct {
    clean_session: bool,
    keepalive: u16,
    client_id: []const u8,
    will: ?Will = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,

    pub const Will = struct {
        topic: []const u8,
        message: []const u8,
        retain: bool,
        qos: QoS,
    };
};

pub const ConnAck = struct {
    session_present: bool,
    return_code: ReturnCode,

    pub const ReturnCode = enum(u8) {
        ok = 0,
        unacceptable_protocol_version,
        invalid_client_id,
        server_unavailable,
        malformed_credentials,
        unauthorized,
    };
};

pub const Publish = struct {
    duplicate: bool,
    qos: QoS,
    retain: bool,
    topic: []const u8,
    packet_id: ?u16 = null,
    payload: []const u8,
};

pub const PubAck = struct {
    packet_id: u16,
};

pub const PubRec = struct {
    packet_id: u16,
};

pub const PubRel = struct {
    packet_id: u16,
};

pub const PubComp = struct {
    packet_id: u16,
};

pub const Subscribe = struct {
    packet_id: u16,
    topics: []const Topic,

    pub const Topic = struct {
        topic_filter: []const u8,
        qos: QoS,
    };
};

pub const SubAck = struct {
    packet_id: u16,
    return_codes: []const ReturnCode,

    pub const ReturnCode = enum(u8) {
        success_qos0 = 0,
        success_qos1,
        success_qos2,
        failure = 0x80,
    };
};

pub const Unsubscribe = struct {
    packet_id: u16,
    topic_filters: [][]const u8,
};

pub const UnsubAck = struct {
    packet_id: u16,
};

pub fn parse(packet_type: PacketType, buffer: []const u8, flags: u4) !Packet {
    var fis = std.io.fixedBufferStream(buffer);
    const reader = fis.reader();

    switch (packet_type) {
        .connack => {
            const ack_flags = try reader.readByte();
            const session_present = if ((ack_flags & 1) != 0) true else false;
            const return_code = @intToEnum(ConnAck.ReturnCode, try reader.readByte());
            const connack = .{ .session_present = session_present, .return_code = return_code };
            return Packet{ .connack = connack };
        },
        .publish => {
            const retain = (flags & 0b0001) == 1;
            const qos_int: u2 = @intCast(u2, @shrExact(flags & 0b0110, 1));
            if (qos_int > 2) {
                return error.InvalidQoS;
            }
            const qos = @intToEnum(QoS, qos_int);
            const duplicate = @shrExact(flags & 0b1000, 3) == 1;

            const topic_length = try reader.readIntBig(u16);
            const topic_start = try fis.getPos();
            const topic_end = topic_start + topic_length;
            const topic = buffer[topic_start..topic_end];
            try fis.seekBy(topic_length);

            const packet_id = switch (qos) {
                QoS.qos0 => null,
                QoS.qos1, QoS.qos2 => try reader.readIntBig(u16),
            };

            const payload_start = try fis.getPos();
            const payload = buffer[payload_start..];

            const publish = .{
                .retain = retain,
                .qos = qos,
                .duplicate = duplicate,
                .topic = topic,
                .packet_id = packet_id,
                .payload = payload,
            };
            return Packet{ .publish = publish };
        },
        .puback => {
            const packet_id = try reader.readByte();
            const puback = .{ .packet_id = packet_id };
            return Packet{ .puback = puback };
        },
        .pubrec => {
            const packet_id = try reader.readByte();
            const pubrec = .{ .packet_id = packet_id };
            return Packet{ .pubrec = pubrec };
        },
        .pubcomp => {
            const packet_id = try reader.readByte();
            const pubcomp = .{ .packet_id = packet_id };
            return Packet{ .pubcomp = pubcomp };
        },
        .suback => {
            const packet_id = try reader.readIntBig(u16);
            const return_codes_start = try fis.getPos();
            const return_codes = mem.bytesAsSlice(SubAck.ReturnCode, buffer[return_codes_start..]);

            const suback = .{
                .packet_id = packet_id,
                .return_codes = return_codes,
            };
            return Packet{ .suback = suback };
        },
        .unsuback => {
            const packet_id = try reader.readByte();
            const unsuback = .{ .packet_id = packet_id };
            return Packet{ .unsuback = unsuback };
        },
        .pingresp => return Packet{ .pingresp = .{} },
        // We only handle server -> client packets
        else => return error.UnhandledPacket,
    }
}

pub const ParseError = error{
    InvalidQoS,
    UnhandledPacket,
};

test {
    testing.refAllDecls(@This());
}
