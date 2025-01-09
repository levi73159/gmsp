const std = @import("std");
const posix = std.posix;
const net = std.net;

const Reader = @import("Reader.zig");
const Self = @This();

alias: []u8,
address: std.net.Address,
socket: std.posix.socket_t,
reader: Reader,
allocator: std.mem.Allocator,

pub const Action = enum(u8) {
    // client and server actions
    message = 0,
    change_alias = 1,
    on_client_update = 2, // anything from changing alias to joining a room
    user_info = 3, // the user is sending his info, username and password
    _,
};

// every data is temporary, because it will point to data in the reader which is a buffer, if you want to keep
// it around, you need to copy it somewhere else
// operates as segments, like a matrix kinda, where each segment will hold a message
pub const Data = struct {
    action: Action,
    segments: []const []const u8,
    allocator: ?std.mem.Allocator,

    // assumes that segments are already allocated with the allocaotr
    pub fn init(allocator: ?std.mem.Allocator, action: Action, segments: []const []const u8) Data {
        return .{
            .action = action,
            .segments = segments,
            .allocator = allocator,
        };
    }

    /// # careful, this will copy the data and this won't allocate any memory so never call deinit
    pub fn single(action: Action, data: []const u8) Data {
        return .{
            .action = action,
            .segments = &[_][]const u8{data},
            .allocator = null,
        };
    }

    pub fn deinit(self: Data) void {
        if (self.allocator == null) return;
        self.allocator.?.free(self.segments);
    }

    pub fn segment(self: Data, index: usize) []const u8 {
        return self.segments[index];
    }

    /// returns the number of segments
    pub fn segmentCount(self: Data) usize {
        return self.segments.len;
    }

    /// gets the length of the data all combined, not counting any header or padding we may have
    pub fn len(self: Data) usize {
        var _len: usize = 0;
        for (self.segments) |seg| {
            _len += seg.len;
        }
        return _len;
    }
};

pub fn init(allocator: std.mem.Allocator, address: std.net.Address, socket: std.posix.socket_t) Self {
    return Self{
        .allocator = allocator,
        .alias = std.fmt.allocPrint(allocator, "{}", .{address}) catch unreachable,
        .address = address,
        .socket = socket,
        .reader = .{
            .socket = socket,
            .buf = allocator.alloc(u8, 30240) catch unreachable,
        },
    };
}

pub fn deinit(self: Self) void {
    self.allocator.free(self.alias);
    self.allocator.free(self.reader.buf);
}

pub fn close(self: Self) void {
    posix.close(self.socket);
}

/// not that this copies the `alias` to the new one so any changes after changing will not be displayed
pub fn changeAlias(self: *Self, alias: []const u8) !void {
    self.alias = self.allocator.realloc(self.alias, alias.len) catch unreachable;
    @memcpy(self.alias, alias);
}

/// DEPRECATED
fn writeAll(self: Self, bytes: []const u8) !void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const written = try posix.write(self.socket, bytes[pos..]);
        if (written == 0) return error.ConnectionClosed;
        pos += written;
    }
}

fn writeAllVectored(self: Self, vec: []posix.iovec_const) !void {
    var i: usize = 0;
    while (true) {
        var n = try posix.writev(self.socket, vec[i..]);
        while (n >= vec[i].len) {
            n -= vec[i].len;
            i += 1;
            if (i >= vec.len) return;
        }
        vec[i].base += n;
        vec[i].len -= n;
    }
}

pub fn read(self: Self, buf: []u8) ![]u8 {
    const amount_read = try posix.read(self.socket, buf);
    return buf[0..amount_read];
}

pub fn readAll(self: Self, buf: []u8) !void {
    var into = buf;
    while (into.len > 0) {
        const n = try posix.read(self.socket, into);
        if (n == 0) {
            return error.Closed;
        }
        into = into[n..];
    }
}

pub fn writeAction(self: Self, data: Data) !void {
    var action_buf: [1]u8 = undefined;
    std.mem.writeInt(std.meta.Tag(Action), &action_buf, @intFromEnum(data.action), .little); // to make it little endian

    var amount_buf: [1]u8 = undefined;
    std.mem.writeInt(u8, &amount_buf, @intCast(data.segmentCount()), .little);

    var iovev_const_buf: [500]posix.iovec_const = undefined;

    iovev_const_buf[0] = .{ .base = &action_buf, .len = action_buf.len };
    iovev_const_buf[1] = .{ .base = &amount_buf, .len = amount_buf.len };

    var count: usize = 2;
    for (data.segments, 2..) |segment, i| {
        iovev_const_buf[i] = .{ .base = segment.ptr, .len = segment.len };
        count = i + 1;
    }

    try self.writeAllVectored(iovev_const_buf[0..count]);
}

pub fn writeMessage(self: Self, message: []const u8) !void {
    try self.writeAction(Data.single(.message, message));
}

// asserts that the aation is message
pub fn readMessage(self: *Self) ![]u8 {
    const data = try self.readData();
    defer data.deinit(); // only deinitlize the data, not the segments
    std.debug.assert(data.action == .message);
    std.debug.assert(data.segments.len == 1);

    return data.segment(0);
}

pub fn readData(self: *Self) !Data {
    var data = try self.reader.readData(self.allocator);
    const owned = data.toOwned();
    return Data{
        .segments = owned.segments,
        .action = owned.action,
        .allocator = owned.allocator,
    };
}

pub fn stream(self: Self) net.Stream {
    return .{
        .handle = self.socket,
    };
}
