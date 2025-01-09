const std = @import("std");
const Thread = std.Thread;
const posix = std.posix;
const net = std.net;

const Connection = @import("Connection.zig");

const Self = @This();

address: net.Address,
socket: posix.socket_t,

const ConnectOptions = struct {
    timeout: posix.timeval = .{ .sec = 2, .usec = 500_000 },
    allocator: std.mem.Allocator,
};

pub fn run(addr: net.Address) !void {
    const server = Self.listen(addr) catch |err| {
        std.log.err("failed to listen: {}", .{err});
        return err;
    };
    defer server.close();

    std.log.info("Listening on {}", .{addr});

    // for short term use memory
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // for long term use memory
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    var connections: std.ArrayList(Connection) = std.ArrayList(Connection).init(allocator);
    defer connections.deinit();

    var pool: std.Thread.Pool = undefined;
    pool.init(.{ .allocator = allocator, .n_jobs = 64 }) catch |err| {
        std.log.err("failed to create thread pool: {}", .{err});
        return err;
    };
    defer pool.deinit();

    while (true) {
        const connection = server.accept(.{ .allocator = allocator, .timeout = .{ .sec = 0, .usec = 0 } }) catch |err| {
            std.log.err("failed to connect: {}", .{err});
            continue;
        };

        pool.spawn(handleConnection, .{ gpa.allocator(), connection, &connections }) catch |err| {
            std.log.err("failed to spawn thread: {}", .{err});
            connection.close();
            continue;
        };
    }
}

fn broadcast(message: []const u8, exclude: ?Connection, connections: []const Connection) !void {
    for (connections) |connection| {
        if (exclude) |e| {
            if (e.address.eql(connection.address)) {
                continue;
            }
        }
        try connection.writeMessage(message);
    }
}

fn broadcastData(data: Connection.Data, exclude: ?Connection, connections: []const Connection) !void {
    for (connections) |connection| {
        if (exclude) |e| {
            if (e.address.eql(connection.address)) {
                continue;
            }
        }
        try connection.writeAction(data);
    }
}

/// the memory allocated will be freed before this function returns
fn clientUpdated(allocator: std.mem.Allocator, connections: []const Connection) !void {
    // loop over connections and format them like alias\n followed by another connection alias
    // then broadcast
    var message = std.ArrayList(u8).init(allocator);
    defer message.deinit();
    for (connections) |connection| {
        message.appendSlice(connection.alias) catch unreachable;
        message.append('\n') catch unreachable;
    }

    try broadcastData(.{ .action = .on_client_update, .data = message.items }, null, connections);
}

fn connPrint(message: []const u8, connection: Connection) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print("[{s}]: {s}\n", .{ connection.alias, message }) catch unreachable;
}

fn connLog(message: []const u8, connection: Connection, log_func: fn (comptime fmt: []const u8, args: anytype) void) void {
    log_func("[{s}]: {s}", .{ connection.alias, message });
}

fn handleConnection(allocator: std.mem.Allocator, connection: Connection, list: *std.ArrayList(Connection)) void {
    defer {
        connection.close();
        connection.deinit();
    }
    const ptr = list.addOne() catch |err| {
        std.log.err("failed to add connection: {}", .{err});
        return;
    };
    ptr.* = connection;
    defer blk: {
        std.log.info("{} disconnected", .{connection.address});
        const index = loop: for (list.items, 0..) |item, i| {
            if (connection.address.eql(item.address)) {
                break :loop i;
            }
        } else {
            std.debug.assert(false);
            break :blk;
        };
        _ = list.swapRemove(index);
    }

    // the first message is the alias
    const alias = ptr.readData() catch |err| {
        std.log.err("failed to read alias: {}", .{err});
        return;
    };
    ptr.alias = ptr.allocator.dupe(u8, alias.data) catch @panic("out of memory");
    if (std.mem.containsAtLeast(u8, ptr.alias, 1, ":")) {
        connLog("invalid alias", ptr.*, std.log.err);
        return;
    }

    var tmp_buf: [2024]u8 = undefined;
    while (true) {
        const data = ptr.readData() catch |err| {
            if (err == error.Closed) {
                var buf: [2024]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{s} disconnected", .{ptr.alias}) catch unreachable;
                broadcast(msg, ptr.*, list.items) catch unreachable;
                return;
            }
            std.log.err("failed to read message: {}", .{err});
            return;
        };

        switch (data.action) {
            .message => {
                const full_msg = std.fmt.bufPrint(&tmp_buf, "{s}: {s}", .{ ptr.alias, data.data }) catch unreachable;
                std.log.info("{s}", .{full_msg});
                broadcast(full_msg, ptr.*, list.items) catch |err| {
                    std.log.err("failed to broadcast message: {}", .{err});
                    return;
                };
            },
            .change_alias => {
                ptr.changeAlias(data.data) catch |err| {
                    std.log.err("failed to change alias: {}", .{err});
                    return;
                };
                clientUpdated(allocator, list.items) catch |err| {
                    std.log.err("failed to update clients: {}", .{err});
                    return;
                };
            },

            .on_client_update => {
                connLog("invalid permissions... server only", ptr.*, std.log.err);
            },
            else => {
                connLog("Invalid action", ptr.*, std.log.err);
            },
        }
    }
}

pub fn listen(addr: net.Address) !Self {
    const tpe: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;
    const socket = try posix.socket(addr.any.family, tpe, protocol);

    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(socket, &addr.any, addr.getOsSockLen());
    try posix.listen(socket, 128);

    return Self{
        .address = addr,
        .socket = socket,
    };
}

/// get the connection
pub fn accept(self: Self, options: ConnectOptions) !Connection {
    var address: net.Address = undefined;
    var len: posix.socklen_t = @sizeOf(net.Address);

    const socket = try posix.accept(self.socket, &address.any, &len, 0);
    std.log.info("{} connected", .{address});

    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(options.timeout));
    try posix.setsockopt(socket, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(options.timeout));

    return Connection.init(options.allocator, address, socket);
}

pub fn close(self: Self) void {
    posix.close(self.socket);
}
