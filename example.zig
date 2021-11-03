const std = @import("std");
const Client = @import("./src/zanzara.zig").mqtt4.Client;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var alloc = &gpa.allocator;

    var client: Client = undefined;
    try client.init(alloc, "test.mosquitto.org", 1883);
    try client.connect(.{});
    // You can verify that the client is publishing using mosquitto_sub to subscribe to the topic:
    // mosquitto_sub -h "test.mosquitto.org" -t "zig/zanzara" -d
    try client.publish("zig/zanzara", "henlo ziguanas", .{});
}
