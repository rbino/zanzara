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
