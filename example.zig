const std = @import("std");
const net = std.net;
const os = std.os;
const zanzara = @import("src/zanzara.zig");
const Client = zanzara.mqtt4.Client;
const Subscribe = zanzara.mqtt4.packet.Subscribe;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const stream = try net.tcpConnectToHost(allocator, "mqtt.eclipseprojects.io", 1883);
    const socket = stream.handle;
    const writer = stream.writer();

    var mqtt_buf: [2048]u8 = undefined;

    var client = try Client.init(mqtt_buf[0..1024], mqtt_buf[1024..]);
    // See ConnectOpts for additional options
    try client.connect(.{ .client_id = "zanzara" });

    var read_buf: [2048]u8 = undefined;

    while (true) {
        // We use os.MSG.DONTWAIT so the socket returns WouldBlock if no data is present
        const bytes = os.recv(socket, &read_buf, os.MSG.DONTWAIT) catch |err|
            if (err == error.WouldBlock) 0 else return err;
        var rest = read_buf[0..bytes];
        while (true) {
            // The driving force of the client is the client.feed() function
            // This must be called periodically, either passing some data coming from the network
            // or with an empty slice (if no incoming data is present) to allow the client to handle
            // its periodic tasks, like pings etc.
            const event = client.feed(rest);
            switch (event.data) {
                .incoming_packet => |p| {
                    switch (p) {
                        .connack => {
                            std.debug.print("Connected, sending subscriptions\n", .{});
                            // Subscribe to the topic we're publishing on
                            const topics = [_]Subscribe.Topic{
                                .{ .topic_filter = "zig/zanzara_in", .qos = .qos2 },
                            };

                            _ = try client.subscribe(&topics);
                            _ = try client.publish("zig/zanzara_out", "Howdy!", .{});
                        },
                        .publish => |pb| {
                            std.debug.print("Received publish on topic {s} with payload {s}\n", .{ pb.topic, pb.payload });
                        },
                        else => std.debug.print("Received packet: {}\n", .{p}),
                    }
                },
                .outgoing_buf => |b| try writer.writeAll(b), // Write pending stuff to the socket
                .err => |e| std.debug.print("Error event: {}\n", .{e}),
                .none => {},
            }
            rest = rest[event.consumed..];
            if (rest.len == 0) break;
        }
    }
}
