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
    _,
};

pub const Data = struct {
    action: Action,
    data: []const u8,

    pub fn ptr(self: Data) [*]const u8 {
        return self.data.ptr;
    }

    pub fn len(self: Data) usize {
        return self.data.len;
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
            .buf = allocator.alloc(u8, 3024) catch unreachable,
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

pub fn writeAll(self: Self, bytes: []const u8) !void {
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
    std.mem.writeInt(u8, &action_buf, @intFromEnum(data.action), .little); // to make it little endian

    var size_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &size_buf, @intCast(data.len()), .little);

    var vec = [_]posix.iovec_const{
        .{ .base = &action_buf, .len = action_buf.len },
        .{ .base = &size_buf, .len = size_buf.len },
        .{ .base = data.ptr(), .len = data.len() },
    };
    try self.writeAllVectored(&vec);
}

pub fn writeMessage(self: Self, message: []const u8) !void {
    try self.writeAction(.{ .data = message, .action = .message });
}

/// Data is guaranteed to be a message or an error
/// returns `error.UnexpectedAction` if the data is not a message
pub fn get(self: Self, name: []const u8) !Data {
    try self.writeAction(.get, name);
    const data = try self.reader.readData();
    if (data.action == .err) {
        return Data{ .err = data.data };
    }
    if (data.action != .message) {
        return error.UnexpectedAction;
    }
    return Data{ .message = data.data };
}

// asserts that the aation is message
pub fn readMessage(self: *Self) ![]u8 {
    const data = try self.reader.readData();
    std.debug.assert(data.action == .message);
    return data.data;
}

pub fn readData(self: *Self) !Data {
    const data = try self.reader.readData();

    return Data{
        .data = data.data,
        .action = data.action,
    };
}

pub fn stream(self: Self) net.Stream {
    return .{
        .handle = self.socket,
    };
}
