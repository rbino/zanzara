const std = @import("std");
const Allocator = @import("std").mem.Allocator;
const FixedHeader = @import("../packet.zig").Packet.FixedHeader;

pub fn EmptyPacket() type {
    return struct {
        const Self = @This();

        pub fn parse(fixed_header: FixedHeader, allocator: *Allocator, inner_reader: anytype) !Self {
            // Nothing to do here, no variable header and no payload
            return Self{};
        }

        pub fn serialize(self: Self, writer: anytype) !void {}

        pub fn serializedLength(self: Self) u32 {
            // Fixed
            return 0;
        }

        pub fn fixedHeaderFlags(self: Self) u4 {
            return 0b0000;
        }

        pub fn deinit(self: *Self, allocator: *Allocator) void {}
    };
}

pub fn PacketIdOnly(comptime fixed_header_flags: u4) type {
    return struct {
        const Self = @This();

        packet_id: u16,

        pub fn parse(fixed_header: FixedHeader, allocator: *Allocator, inner_reader: anytype) !Self {
            const reader = std.io.limitedReader(inner_reader, fixed_header.remaining_length).reader();

            const packet_id = try reader.readIntBig(u16);

            return Self{
                .packet_id = packet_id,
            };
        }

        pub fn serialize(self: Self, writer: anytype) !void {
            try writer.writeIntBig(u16, self.packet_id);
        }

        pub fn serializedLength(self: Self) u32 {
            // Fixed
            return comptime @sizeOf(u16);
        }

        pub fn fixedHeaderFlags(self: Self) u4 {
            return fixed_header_flags;
        }

        pub fn deinit(self: *Self, allocator: *Allocator) void {}
    };
}