const allocator = std.heap.page_allocator;
const std = @import("std");
const zanzara = @import("./src/zanzara.zig");
const Client = zanzara.mqtt4.Client;

pub fn main() !void {
    var client: Client = undefined;
    try client.init("test.mosquitto.org", 1883, allocator);
    try client.connect(.{});
    // You can verify that the client is publishing using mosquitto_sub to subscribe to the topic:
    // mosquitto_sub -h "test.mosquitto.org" -t "zig/zanzara" -d
    try client.publish("zig/zanzara", "henlo ziguanas", .{});
}
