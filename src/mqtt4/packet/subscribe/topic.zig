const utils = @import("../../../utils.zig");
const std = @import("std");
const Allocator = @import("std").mem.Allocator;
const ParseError = @import("../subscribe.zig").Subscribe.ParseError;
const QoS = @import("../../../qos.zig").QoS;

pub const Topic = struct {
    topic_filter: []const u8,
    qos: QoS,

    pub fn parse(allocator: *Allocator, reader: anytype) !Topic {
        const topic_filter = try utils.readMQTTString(allocator, reader);
        errdefer allocator.free(topic_filter);

        const qos_int = try reader.readByte();
        if (qos_int > 2) {
            return error.InvalidQoS;
        }
        const qos = @intToEnum(QoS, @intCast(u2, qos_int));

        return Topic{
            .topic_filter = topic_filter,
            .qos = qos,
        };
    }

    pub fn serialize(self: Topic, writer: anytype) !void {
        try utils.writeMQTTString(self.topic_filter, writer);
        try writer.writeIntBig(u8, @enumToInt(self.qos));
    }

    pub fn serializedLength(self: Topic) u32 {
        return utils.serializedMQTTStringLen(self.topic_filter) + @sizeOf(QoS);
    }

    pub fn deinit(self: *Topic, allocator: *Allocator) void {
        allocator.free(self.topic_filter);
    }
};
