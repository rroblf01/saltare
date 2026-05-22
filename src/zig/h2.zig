// HTTP/2 protocol implementation (RFC 7540 + RFC 7541).
//
// RAM-optimized: minimal allocations, uses shared pool for buffers.
// v1.9: HTTP/2 support with HPACK compression.

const std = @import("std");
const h2_static = @import("h2_static.zig");

pub const HTTP2_FRAME_TYPE_DATA: u8 = 0x0;
pub const HTTP2_FRAME_TYPE_HEADERS: u8 = 0x1;
pub const HTTP2_FRAME_TYPE_PRIORITY: u8 = 0x2;
pub const HTTP2_FRAME_TYPE_RST_STREAM: u8 = 0x3;
pub const HTTP2_FRAME_TYPE_SETTINGS: u8 = 0x4;
pub const HTTP2_FRAME_TYPE_PING: u8 = 0x6;
pub const HTTP2_FRAME_TYPE_GOAWAY: u8 = 0x7;
pub const HTTP2_FRAME_TYPE_WINDOW_UPDATE: u8 = 0x8;
pub const HTTP2_FRAME_TYPE_CONTINUATION: u8 = 0x9;

pub const HTTP2_SETTINGS_MAX_CONCURRENT_STREAMS: u32 = 100;
pub const HTTP2_SETTINGS_INITIAL_WINDOW_SIZE: u32 = 65535;
pub const HTTP2_SETTINGS_MAX_FRAME_SIZE: u32 = 16777215;
pub const HTTP2_SETTINGS_MAX_HEADER_TABLE_SIZE: u32 = 4096;

pub const HTTP2_SETTINGS_ID_HEADER_TABLE_SIZE: u16 = 0x1;
pub const HTTP2_SETTINGS_ID_ENABLE_PUSH: u16 = 0x2;
pub const HTTP2_SETTINGS_ID_MAX_CONCURRENT_STREAMS: u16 = 0x3;
pub const HTTP2_SETTINGS_ID_INITIAL_WINDOW_SIZE: u16 = 0x4;
pub const HTTP2_SETTINGS_ID_MAX_FRAME_SIZE: u16 = 0x5;
pub const HTTP2_SETTINGS_ID_MAX_HEADER_LIST_SIZE: u16 = 0x6;

pub const HTTP2_FLAG_END_STREAM: u8 = 0x1;
pub const HTTP2_FLAG_END_HEADERS: u8 = 0x4;
pub const HTTP2_FLAG_ACK: u8 = 0x1;
pub const HTTP2_FLAG_PADDED: u8 = 0x8;
pub const HTTP2_FLAG_PRIORITY: u8 = 0x20;

pub const HTTP2_MAGIC = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
pub const HTTP2_SETTINGS_ACK = [_]u8{ 0x0, 0x0, 0x0, HTTP2_FRAME_TYPE_SETTINGS, HTTP2_FLAG_ACK, 0x0, 0x0, 0x0, 0x0 };

pub const H2Error = error{
    CompressionError,
    ProtocolError,
    FlowControlError,
    FrameSizeError,
    IncompleteFrame,
    InvalidStreamState,
    StreamClosed,
    SettingsRejected,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const StreamState = enum {
    Idle,
    Open,
    ReservedLocal,
    ReservedRemote,
    HalfClosedLocal,
    HalfClosedRemote,
    Closed,
};

pub const Frame = struct {
    length: u24,
    frame_type: u8,
    flags: u8,
    stream_id: u31,

    pub fn parse(data: []const u8) ?Frame {
        if (data.len < 9) return null;
        const length = (@as(u24, data[0]) << 16) | (@as(u24, data[1]) << 8) | @as(u24, data[2]);
        return Frame{
            .length = length,
            .frame_type = data[3],
            .flags = data[4],
            .stream_id = @as(u31, @truncate(std.mem.readInt(u32, data[5..9], .big) & 0x7FFFFFFF)),
        };
    }

    pub fn build(allocator: std.mem.Allocator, frame_type: u8, flags: u8, stream_id: u31, payload: []const u8) ![]u8 {
        if (payload.len > HTTP2_SETTINGS_MAX_FRAME_SIZE) return error.FrameSizeError;
        var frame = try allocator.alloc(u8, 9 + payload.len);
        frame[0] = @as(u8, @truncate(payload.len >> 16));
        frame[1] = @as(u8, @truncate(payload.len >> 8));
        frame[2] = @as(u8, @truncate(payload.len));
        frame[3] = frame_type;
        frame[4] = flags;
        std.mem.writeInt(u32, frame[5..9], @as(u32, stream_id), .big);
        @memcpy(frame[9..], payload);
        return frame;
    }
};

pub const StreamContext = struct {
    id: u31,
    state: StreamState = .Idle,
    window_size: u32 = HTTP2_SETTINGS_INITIAL_WINDOW_SIZE,
    end_stream: bool = false,
    header_list: []Header = &.{},
};

pub const Settings = struct {
    header_table_size: u32 = HTTP2_SETTINGS_MAX_HEADER_TABLE_SIZE,
    enable_push: u32 = 1,
    max_concurrent_streams: u32 = HTTP2_SETTINGS_MAX_CONCURRENT_STREAMS,
    initial_window_size: u32 = HTTP2_SETTINGS_INITIAL_WINDOW_SIZE,
    max_frame_size: u32 = HTTP2_SETTINGS_MAX_FRAME_SIZE,
    max_header_list_size: u32 = 16777215,
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    max_size: u32 = HTTP2_SETTINGS_MAX_HEADER_TABLE_SIZE,
    table_size: u32 = 0,
    entry_names: [][]const u8 = &.{},
    entry_values: [][]const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) Decoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Decoder) void {
        if (self.entry_names.len > 0) {
            self.allocator.free(self.entry_names);
            self.allocator.free(self.entry_values);
        }
    }

    fn evictToFit(self: *Decoder) void {
        while (self.table_size + 32 > self.max_size and self.entry_names.len > 0) {
            _ = self.entry_names[self.entry_names.len - 1];
            self.entry_names.len -= 1;
            self.entry_values.len -= 1;
            self.table_size -= 32;
        }
    }

    fn addEntry(self: *Decoder, name: []const u8, value: []const u8) void {
        const size: u32 = @intCast(32 + name.len + value.len);
        if (size > self.max_size) return;
        self.evictToFit();
        if (self.table_size + size <= self.max_size) {
            self.table_size += size;
        }
    }

    pub fn decode(self: *Decoder, input: []const u8, out: *std.ArrayList(Header)) H2Error!void {
        var i: usize = 0;

        while (i < input.len) {
            const first = input[i];
            i += 1;

            if (first & 0x80 != 0) {
                const index = first & 0x7F;
                if (index == 0) return error.CompressionError;
                if (index < 62) {
                    if (h2_static.staticEntry(@intCast(index))) |entry| {
                        out.append(self.allocator, .{ .name = entry.name, .value = entry.value }) catch return;
                    }
                } else {
                    const dyn_idx = @as(usize, 62 - index);
                    if (dyn_idx < self.entry_names.len) {
                        out.append(self.allocator, .{ .name = self.entry_names[dyn_idx], .value = self.entry_values[dyn_idx] }) catch return;
                    }
                }
            } else if (first & 0x40 != 0) {
                const index = first & 0x3F;
                const name = if (index > 0) blk: {
                    if (index < 62) {
                        if (h2_static.staticEntry(@intCast(index))) |entry| break :blk entry.name;
                    }
                    break :blk try self.decodeString(input, &i);
                } else blk: {
                    break :blk try self.decodeString(input, &i);
                };
                const value = try self.decodeString(input, &i);
                self.addEntry(name, value);
                out.append(self.allocator, .{ .name = name, .value = value }) catch return;
            } else if (first & 0x20 != 0) {
                if (i + 2 > input.len) return error.CompressionError;
                const size = (@as(u32, first & 0x1F) << 16) | (@as(u32, input[i]) << 8) | @as(u32, input[i + 1]);
                i += 2;
                self.max_size = size;
                self.evictToFit();
            } else {
                const name = if ((first & 0x0F) > 0) blk: {
                    const idx = first & 0x0F;
                    if (idx < 62) {
                        if (h2_static.staticEntry(@intCast(idx))) |entry| break :blk entry.name;
                    }
                    break :blk try self.decodeString(input, &i);
                } else blk: {
                    break :blk try self.decodeString(input, &i);
                };
                const value = try self.decodeString(input, &i);
                out.append(self.allocator, .{ .name = name, .value = value }) catch return;
            }
        }
    }

    fn decodeString(_: *Decoder, input: []const u8, offset: *usize) H2Error![]const u8 {
        if (offset.* >= input.len) return error.CompressionError;
        offset.* += 1;
        if (offset.* >= input.len) return error.CompressionError;
        var length: usize = input[offset.*];
        offset.* += 1;
        if (length >= 128 and offset.* + 1 < input.len) {
            length = ((length & 0x7F) << 8) | input[offset.*];
            offset.* += 1;
        }
        if (offset.* + length > input.len) return error.CompressionError;
        const slice = input[offset.*..offset.* + length];
        offset.* += length;
        return slice;
    }
};

pub const FrameResult = struct {
    headers: ?std.ArrayList(Header) = null,
    data: ?[]const u8 = null,
    stream_id: u31 = 0,
    end_stream: bool = false,
    settings_ack: bool = false,
    ping: ?[]const u8 = null,
    ping_ack: bool = false,
    goaway: bool = false,
    goaway_stream_id: u31 = 0,
    stream_closed: u31 = 0,
    need_window_update: bool = false,
};

pub const Connection = struct {
    streams: std.AutoHashMap(u31, StreamContext),
    decoder: Decoder,
    settings: Settings = .{},
    preface_received: bool = false,
    settings_acked: bool = false,
    active_stream_count: u32 = 0,
    connection_window: u32 = HTTP2_SETTINGS_INITIAL_WINDOW_SIZE,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Connection {
        return Connection{
            .streams = std.AutoHashMap(u31, StreamContext).init(allocator),
            .decoder = .{ .allocator = allocator },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Connection) void {
        self.streams.deinit();
    }

    pub fn expectPreface(self: *Connection, data: []const u8) H2Error!bool {
        if (self.preface_received) return true;
        if (data.len < HTTP2_MAGIC.len) return error.IncompleteFrame;
        if (!std.mem.startsWith(u8, data, HTTP2_MAGIC)) {
            return error.ProtocolError;
        }
        self.preface_received = true;
        return true;
    }

    pub fn processFrame(self: *Connection, data: []const u8) H2Error!?FrameResult {
        const frame = Frame.parse(data) orelse return error.IncompleteFrame;
        if (data.len < 9 + frame.length) return error.IncompleteFrame;
        const payload = data[9..][0..frame.length];

        return switch (frame.frame_type) {
            HTTP2_FRAME_TYPE_SETTINGS => self.handleSettings(frame, payload),
            HTTP2_FRAME_TYPE_HEADERS => self.handleHeaders(frame, payload),
            HTTP2_FRAME_TYPE_DATA => self.handleData(frame, payload),
            HTTP2_FRAME_TYPE_WINDOW_UPDATE => self.handleWindowUpdate(frame, payload),
            HTTP2_FRAME_TYPE_PING => self.handlePing(frame, payload),
            HTTP2_FRAME_TYPE_RST_STREAM => self.handleRstStream(frame, payload),
            HTTP2_FRAME_TYPE_GOAWAY => self.handleGoAway(frame, payload),
            HTTP2_FRAME_TYPE_PRIORITY => self.handlePriority(frame, payload),
            HTTP2_FRAME_TYPE_CONTINUATION => self.handleContinuation(frame, payload),
            else => null,
        };
    }

    fn handleSettings(_: *Connection, frame: Frame, _: []const u8) H2Error!?FrameResult {
        if (frame.stream_id != 0) return error.ProtocolError;
        if (frame.flags & HTTP2_FLAG_ACK != 0) {
            return FrameResult{ .settings_ack = true };
        }
        return FrameResult{ .settings_ack = true };
    }

    fn handleHeaders(self: *Connection, frame: Frame, payload: []const u8) H2Error!?FrameResult {
        if (frame.stream_id == 0) return error.ProtocolError;
        if (frame.stream_id & 1 == 0) return error.ProtocolError;

        var offset: usize = 0;
        if (frame.flags & HTTP2_FLAG_PADDED != 0) {
            if (offset >= payload.len) return error.ProtocolError;
            offset += 1;
            if (offset + payload[offset - 1] >= payload.len) return error.ProtocolError;
        }
        if (frame.flags & HTTP2_FLAG_PRIORITY != 0) {
            offset += 5;
        }
        const headers_data = payload[offset..];

        var headers: std.ArrayList(Header) = .empty;
        try self.decoder.decode(headers_data, &headers);
        const end_stream = frame.flags & HTTP2_FLAG_END_STREAM != 0;

        const stream_id = frame.stream_id;
        if (self.streams.getPtr(stream_id)) |stream| {
            stream.header_list = headers.items;
            stream.end_stream = end_stream;
            stream.state = if (end_stream) .HalfClosedRemote else .Open;
        } else {
            var sc = StreamContext{ .id = stream_id, .state = if (end_stream) .HalfClosedRemote else .Open };
            sc.header_list = headers.items;
            sc.end_stream = end_stream;
            self.streams.put(stream_id, sc) catch return null;
            self.active_stream_count += 1;
        }

        return FrameResult{
            .headers = headers,
            .stream_id = stream_id,
            .end_stream = end_stream,
        };
    }

    fn handleData(self: *Connection, frame: Frame, payload: []const u8) H2Error!?FrameResult {
        if (frame.stream_id == 0) return error.ProtocolError;
        if (self.streams.getPtr(frame.stream_id)) |stream| {
            if (stream.window_size < payload.len) return error.FlowControlError;
            stream.window_size -= @as(u32, @intCast(payload.len));
            const end_stream = frame.flags & HTTP2_FLAG_END_STREAM != 0;
            if (end_stream) {
                stream.state = .HalfClosedRemote;
                stream.end_stream = true;
            }
            return FrameResult{ .data = payload, .stream_id = frame.stream_id, .end_stream = end_stream };
        }
        return error.StreamClosed;
    }

    fn handleWindowUpdate(self: *Connection, frame: Frame, payload: []const u8) H2Error!?FrameResult {
        if (payload.len < 4) return error.ProtocolError;
        const increment = std.mem.readInt(u32, payload[0..4], .big) & 0x7FFFFFFF;
        if (increment == 0) return error.ProtocolError;
        if (frame.stream_id == 0) {
            self.connection_window += increment;
        } else if (self.streams.getPtr(frame.stream_id)) |stream| {
            stream.window_size += increment;
        }
        return null;
    }

    fn handlePing(_: *Connection, frame: Frame, payload: []const u8) H2Error!?FrameResult {
        if (frame.stream_id != 0) return error.ProtocolError;
        if (payload.len != 8) return error.FrameSizeError;
        if (frame.flags & HTTP2_FLAG_ACK == 0) {
            return FrameResult{ .ping = payload, .ping_ack = true };
        }
        return null;
    }

    fn handleRstStream(self: *Connection, frame: Frame, _: []const u8) H2Error!?FrameResult {
        if (frame.stream_id == 0) return error.ProtocolError;
        _ = self.streams.remove(frame.stream_id);
        return FrameResult{ .stream_closed = frame.stream_id };
    }

    fn handleGoAway(_: *Connection, frame: Frame, _: []const u8) H2Error!?FrameResult {
        return FrameResult{ .goaway = true, .goaway_stream_id = frame.stream_id };
    }

    fn handlePriority(_: *Connection, frame: Frame, _: []const u8) H2Error!?FrameResult {
        if (frame.stream_id == 0) return error.ProtocolError;
        return null;
    }

    fn handleContinuation(_: *Connection, frame: Frame, _: []const u8) H2Error!?FrameResult {
        if (frame.stream_id == 0) return error.ProtocolError;
        return null;
    }

    pub fn buildSettingsAck(_: *Connection) []const u8 {
        return &HTTP2_SETTINGS_ACK;
    }

    pub fn buildWindowUpdate(self: *Connection, stream_id: u31, increment: u31) (H2Error || error{OutOfMemory})![]u8 {
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, increment, .big);
        return Frame.build(self.allocator, HTTP2_FRAME_TYPE_WINDOW_UPDATE, 0, stream_id, &payload);
    }

    pub fn buildGoAway(self: *Connection, last_stream_id: u31, error_code: u32) (H2Error || error{OutOfMemory})![]u8 {
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u32, payload[0..4], last_stream_id, .big);
        std.mem.writeInt(u32, payload[4..8], error_code, .big);
        return Frame.build(self.allocator, HTTP2_FRAME_TYPE_GOAWAY, 0, 0, &payload);
    }
};

test "HPACK static table" {
    for (1..62) |i| {
        try std.testing.expect(h2_static.staticEntry(@intCast(i)) != null);
    }
    try std.testing.expect(h2_static.staticEntry(0) == null);
}

test "Frame parse" {
    const data = [_]u8{ 0, 0, 0, HTTP2_FRAME_TYPE_SETTINGS, 0, 0, 0, 0, 0 };
    const frame = Frame.parse(&data);
    try std.testing.expect(frame != null);
    try std.testing.expect(frame.?.frame_type == HTTP2_FRAME_TYPE_SETTINGS);
    try std.testing.expect(frame.?.stream_id == 0);
}

test "Connection init" {
    var conn = Connection.init(std.testing.allocator);
    defer conn.deinit();
    try std.testing.expect(!conn.preface_received);
    try std.testing.expect(conn.streams.count() == 0);
}