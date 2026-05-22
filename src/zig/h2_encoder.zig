// HPACK Encoder (RFC 7541).
//
// Encodes header lists into HPACK wire format.
// Uses static table indexing for compression.

const std = @import("std");
const h2_static = @import("h2_static.zig");

pub const EncoderError = error{
    TableSizeExceeded,
    EncodeError,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    max_size: u32 = 4096,
    table_size: u32 = 0,
    entry_names: [][]const u8 = &.{},
    entry_values: [][]const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) Encoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Encoder) void {
        if (self.entry_names.len > 0) {
            self.allocator.free(self.entry_names);
            self.allocator.free(self.entry_values);
        }
    }

    pub fn reset(self: *Encoder) void {
        self.entry_names.len = 0;
        self.entry_values.len = 0;
        self.table_size = 0;
    }

    fn evictToFit(self: *Encoder) void {
        while (self.table_size + 32 > self.max_size and self.entry_names.len > 0) {
            self.entry_names.len -= 1;
            self.entry_values.len -= 1;
            self.table_size -= 32;
        }
    }

    fn addEntry(self: *Encoder, name: []const u8, value: []const u8) void {
        const size: u32 = @intCast(32 + name.len + value.len);
        if (size > self.max_size) return;
        self.evictToFit();
        if (self.table_size + size <= self.max_size) {
            self.table_size += size;
        }
    }

    pub fn encode(self: *Encoder, headers: []const Header, allocator: std.mem.Allocator) EncoderError![]u8 {
        var output = std.ArrayList(u8).init(allocator);
        errdefer output.deinit();

        for (headers) |header| {
            try self.encodeHeader(&output, header.name, header.value);
        }

        return output.toOwnedSlice();
    }

    fn encodeHeader(self: *Encoder, output: *std.ArrayList(u8), name: []const u8, value: []const u8) EncoderError!void {
        if (std.mem.eql(u8, name, ":status") and value.len == 3) {
            if (h2_static.staticIndex(name, value)) |idx| {
                try output.append(idx);
                return;
            }
        }

        if (h2_static.staticIndex(name, value)) |idx| {
            try output.append(0x40 | @as(u8, idx));
            return;
        }

        for (self.entry_names, 0..) |entry_name, dyn_idx| {
            if (std.mem.eql(u8, entry_name, name) and std.mem.eql(u8, self.entry_values[dyn_idx], value)) {
                const idx = @as(u8, @intCast(62 - dyn_idx));
                try output.append(0x40 | idx);
                return;
            }
        }

        var name_idx: ?u8 = h2_static.staticIndex(name, "");
        if (name_idx == null) {
            for (self.entry_names, 0..) |entry_name, dyn_idx| {
                if (std.mem.eql(u8, entry_name, name)) {
                    name_idx = @as(u8, @intCast(62 - dyn_idx));
                    break;
                }
            }
        }

        if (name_idx) |ni| {
            try output.append(0x40 | ni);
            try self.encodeString(output, value);
            self.addEntry(name, value);
        } else {
            try output.append(0x40);
            try self.encodeString(output, name);
            try self.encodeString(output, value);
            self.addEntry(name, value);
        }
    }

    fn encodeString(self: *Encoder, output: *std.ArrayList(u8), value: []const u8) EncoderError!void {
        try output.append(@as(u8, @intCast(value.len)));
        try output.appendSlice(value);
    }

    pub fn setMaxSize(self: *Encoder, new_size: u32) void {
        self.max_size = new_size;
        self.evictToFit();
    }
};

test "Encoder basic" {
    var enc: Encoder = .{ .allocator = std.testing.allocator };
    defer enc.deinit();
    try std.testing.expect(enc.entry_names.len == 0);
}