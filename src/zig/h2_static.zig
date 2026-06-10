// HPACK Static Table (RFC 7541 Table B).
//
// The static table contains 61 pre-defined header fields that provide
// common values for HTTP/2. Indices 1-61 are reserved for static table
// entries; 0 is the "never indexed" literal representation.
//
// Layout: each entry is (name, value) as separate inline arrays.
// Lookup by index: static_table[index - 1] gives (name, value).

pub const StaticEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const STATIC_TABLE: [61]StaticEntry = .{
    .{ .name = ":authority",         .value = "" },
    .{ .name = ":method",            .value = "GET" },
    .{ .name = ":method",            .value = "POST" },
    .{ .name = ":path",              .value = "/" },
    .{ .name = ":path",              .value = "/index.html" },
    .{ .name = ":scheme",            .value = "http" },
    .{ .name = ":scheme",            .value = "https" },
    .{ .name = ":status",            .value = "200" },
    .{ .name = ":status",            .value = "204" },
    .{ .name = ":status",            .value = "206" },
    .{ .name = ":status",            .value = "304" },
    .{ .name = ":status",            .value = "400" },
    .{ .name = ":status",            .value = "404" },
    .{ .name = ":status",            .value = "500" },
    .{ .name = "accept-charset",     .value = "" },
    .{ .name = "accept-encoding",    .value = "gzip, deflate" },
    .{ .name = "accept-language",    .value = "" },
    .{ .name = "accept-ranges",      .value = "" },
    .{ .name = "accept",             .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age",                .value = "" },
    .{ .name = "allow",              .value = "" },
    .{ .name = "authorization",      .value = "" },
    .{ .name = "cache-control",      .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding",   .value = "" },
    .{ .name = "content-language",   .value = "" },
    .{ .name = "content-length",     .value = "" },
    .{ .name = "content-location",   .value = "" },
    .{ .name = "content-range",      .value = "" },
    .{ .name = "content-type",       .value = "" },
    .{ .name = "cookie",             .value = "" },
    .{ .name = "date",               .value = "" },
    .{ .name = "etag",               .value = "" },
    .{ .name = "expect",             .value = "" },
    .{ .name = "expires",            .value = "" },
    .{ .name = "from",               .value = "" },
    .{ .name = "host",               .value = "" },
    .{ .name = "if-match",           .value = "" },
    .{ .name = "if-modified-since",  .value = "" },
    .{ .name = "if-none-match",      .value = "" },
    .{ .name = "if-range",           .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified",      .value = "" },
    .{ .name = "link",               .value = "" },
    .{ .name = "location",           .value = "" },
    .{ .name = "max-forwards",       .value = "" },
    .{ .name = "proxy-authenticate",  .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range",              .value = "" },
    .{ .name = "referer",            .value = "" },
    .{ .name = "refresh",            .value = "" },
    .{ .name = "retry-after",        .value = "" },
    .{ .name = "server",             .value = "" },
    .{ .name = "set-cookie",         .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding",  .value = "" },
    .{ .name = "user-agent",         .value = "" },
    .{ .name = "vary",              .value = "" },
    .{ .name = "via",               .value = "" },
    .{ .name = "www-authenticate",   .value = "" },
};

pub inline fn staticEntry(index: u8) ?StaticEntry {
    if (index == 0 or index > 61) return null;
    return STATIC_TABLE[index - 1];
}

pub fn staticIndex(name: []const u8, value: []const u8) ?u8 {
    for (STATIC_TABLE, 1..) |entry, idx| {
        if (std.mem.eql(u8, entry.name, name) and std.mem.eql(u8, entry.value, value)) {
            return @intCast(idx);
        }
    }
    return null;
}

/// First static-table index whose name matches `name` (value ignored).
/// Lets the encoder reference a common header name even when the value
/// isn't in the table.
pub fn staticNameIndex(name: []const u8) ?u8 {
    for (STATIC_TABLE, 1..) |entry, idx| {
        if (std.mem.eql(u8, entry.name, name)) return @intCast(idx);
    }
    return null;
}

const std = @import("std");