const std = @import("std");
const Connection = @import("Connection.zig");
const Reader = @import("Reader.zig");
const posix = std.posix;
const net = std.net;

const Self = @This();

socket: posix.socket_t,
_connection: Connection,

pub fn connect(allocator: std.mem.Allocator, address: net.Address) !Self {
    const socket = try posix.socket(address.any.family, posix.SOCK.STREAM, posix.IPPROTO.TCP);
    errdefer posix.close(socket);

    try posix.connect(socket, &address.any, address.getOsSockLen());
    return Self{
        .socket = socket,
        ._connection = Connection.init(allocator, address, socket),
    };
}

pub fn deinit(self: Self) void {
    self._connection.deinit();
}

pub fn close(self: Self) void {
    self._connection.close();
}

pub fn stream(self: Self) net.Stream {
    return .{
        .handle = self.socket,
    };
}

pub fn reader(self: Self) Reader {
    return self._connection.reader;
}

pub fn connection(self: *Self) *Connection {
    return &self._connection;
}

pub fn connectionConst(self: Self) Connection {
    return self._connection;
}
