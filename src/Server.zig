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

const User = struct {
    const filepath = "users.dat";
    fn insureExists() !void {
        const file = std.fs.cwd().createFile(User.filepath, std.fs.File.CreateFlags{ .truncate = false }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                std.log.debug("user file already exists...", .{});
                return;
            },
            else => return err,
        };
        file.close();
    }
    fn openUsersFile() !std.fs.File {
        try insureExists();
        return std.fs.cwd().openFile(User.filepath, std.fs.File.OpenFlags{ .mode = .read_write });
    }

    username: []const u8,
    password: []const u8,

    pub fn deinit(self: User, allocator: std.mem.Allocator) void {
        allocator.free(self.username);
        allocator.free(self.password);
    }
};

fn translateUserFile(allocator: std.mem.Allocator) ![]const User {
    const file = try User.openUsersFile();

    // each user will have an 8 byte header
    // split into 4 bytes (the username length) and 4 bytes (the password length)
    // followed by the username and password
    // the username and password will not be null terminated since they have a length prefix
    var users = std.ArrayList(User).init(allocator);
    errdefer {
        for (users.items) |user| {
            user.deinit(allocator);
        }
        users.deinit();
    }

    const reader = file.reader();
    while (true) {
        const username_len = reader.readInt(u32, .big) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const password_len = try reader.readInt(u32, .big);

        const username = allocator.alloc(u8, username_len) catch unreachable;
        errdefer allocator.free(username);

        const password = allocator.alloc(u8, password_len) catch unreachable;
        errdefer allocator.free(password);

        var amount = try file.readAll(username);
        if (amount != username_len) return error.EndOfStream; // should never happen but just in case the file is wrong

        amount = try file.readAll(password);
        if (amount != password_len) return error.EndOfStream; // should never happen but just in case the file is wrong

        users.append(.{ .username = username, .password = password }) catch unreachable;
    }

    return users.toOwnedSlice();
}
fn freeUsers(users: []const User, allocator: std.mem.Allocator) void {
    for (users) |user| {
        user.deinit(allocator);
    }
    allocator.free(users);
}
fn addUser(user: User) !void {
    const file = User.openUsersFile() catch |err| {
        std.log.err("failed to open user file: {}", .{err});
        return err;
    };
    defer file.close();

    try file.seekFromEnd(0); // so we can append instead of overwrite

    const writer = file.writer();

    try writer.writeInt(u32, @intCast(user.username.len), .big);
    try writer.writeInt(u32, @intCast(user.password.len), .big);
    try writer.writeAll(user.username);
    try writer.writeAll(user.password);
}

fn handleLogin(allocator: std.mem.Allocator, connection: *Connection, connections: []const Connection, data: Connection.Data) !void {
    if (data.segmentCount() != 2) {
        return error.InvalidData;
    }

    const username = data.segment(0);
    const password = data.segment(1);

    const users = translateUserFile(allocator) catch |err| {
        std.log.err("failed to translate user file: {}", .{err});
        return err;
    };
    defer freeUsers(users, allocator);

    for (users) |user| {
        if (std.mem.eql(u8, username, user.username) and std.mem.eql(u8, password, user.password)) {
            try connection.changeAlias(username);
            const response = Connection.Data.alloc(allocator, .success, &[_][]const u8{"Login successful"});
            defer response.deinit();
            connection.writeAction(response) catch |err| {
                std.log.err("failed to send success: {}", .{err});
                return err;
            };
            clientUpdated(allocator, connections) catch |err| {
                std.log.err("failed to update clients: {}", .{err});
                return err;
            };
            return;
        }
    }

    const response = Connection.Data.alloc(allocator, .err, &[_][]const u8{"Invalid username or password"});
    defer response.deinit();
    connection.writeAction(response) catch |err| {
        std.log.err("failed to send failure: {}", .{err});
        return err;
    };
}

fn handleSignup(allocator: std.mem.Allocator, connection: *Connection, connections: []const Connection, data: Connection.Data) !void {
    if (data.segmentCount() != 2) {
        return error.InvalidData;
    }

    const username = data.segment(0);
    const password = data.segment(1);

    const users = translateUserFile(allocator) catch |err| {
        std.log.err("failed to translate user file: {}", .{err});
        return err;
    };
    defer freeUsers(users, allocator);

    for (users) |user| {
        if (std.mem.eql(u8, username, user.username)) {
            const response = Connection.Data.alloc(allocator, .err, &[_][]const u8{"Username already taken"});
            defer response.deinit();
            connection.writeAction(response) catch |err| {
                std.log.err("failed to send failure: {}", .{err});
                return err;
            };
            return;
        }
    }

    addUser(User{ .username = username, .password = password }) catch |err| {
        std.log.err("failed to add user: {}", .{err});
        return err;
    };

    try connection.changeAlias(username);

    const response = Connection.Data.alloc(allocator, .success, &[_][]const u8{"Signup successful"});
    defer response.deinit();
    connection.writeAction(response) catch |err| {
        std.log.err("failed to send success: {}", .{err});
        return err;
    };
    clientUpdated(allocator, connections) catch |err| {
        std.log.err("failed to update clients: {}", .{err});
        return err;
    };
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
    const message = getList(allocator, connections) catch |err| {
        std.log.err("failed to get list: {}", .{err});
        return err;
    };
    defer allocator.free(message);

    const response = Connection.Data.alloc(allocator, .on_client_update, &[_][]const u8{message});
    defer response.deinit();

    try broadcastData(response, null, connections);
}

fn getList(allocator: std.mem.Allocator, connections: []const Connection) ![]const u8 {
    var message = std.ArrayList(u8).init(allocator);
    for (connections) |connection| {
        message.appendSlice(connection.alias) catch unreachable;
        message.append('\n') catch unreachable;
    }
    return message.toOwnedSlice();
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
        clientUpdated(allocator, list.items) catch |err| {
            std.log.err("failed to update clients: {}", .{err});
        };
    }

    // the first message is the alias
    {
        const alias = ptr.readData() catch |err| {
            std.log.err("failed to read alias: {}", .{err});
            return;
        };
        ptr.alias = ptr.allocator.dupe(u8, alias.segment(0)) catch @panic("out of memory");
        if (std.mem.containsAtLeast(u8, ptr.alias, 1, ":")) {
            connLog("invalid alias", ptr.*, std.log.err);
            return;
        }
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
        defer data.deinit();

        switch (data.action) {
            .message => {
                const full_msg = std.fmt.bufPrint(&tmp_buf, "{s}: {s}", .{ ptr.alias, data.segment(0) }) catch unreachable;
                std.log.info("{s}", .{full_msg});
                broadcast(full_msg, ptr.*, list.items) catch |err| {
                    std.log.err("failed to broadcast message: {}", .{err});
                    return;
                };
            },
            .change_alias => {
                ptr.changeAlias(data.segment(0)) catch |err| {
                    std.log.err("failed to change alias: {}", .{err});
                    return;
                };
                clientUpdated(allocator, list.items) catch |err| {
                    std.log.err("failed to update clients: {}", .{err});
                    return;
                };
            },
            .login => {
                handleLogin(allocator, ptr, list.items, data) catch |err| {
                    std.log.err("failed to login: {}", .{err});

                    // make sure a response is sent back otherwise the client will hang
                    const response = Connection.Data.alloc(allocator, .err, &[_][]const u8{"Error logging in..."});
                    defer response.deinit();
                    ptr.writeAction(response) catch |e| {
                        std.log.err("failed to send error: {}", .{e});
                        return;
                    };
                };
            },
            .signup => {
                handleSignup(allocator, ptr, list.items, data) catch |err| {
                    std.log.err("failed to signup: {}", .{err});

                    // make sure a response is sent back otherwise the client will hang
                    const response = Connection.Data.alloc(allocator, .err, &[_][]const u8{"Error signing up..."});
                    defer response.deinit();
                    ptr.writeAction(response) catch |e| {
                        std.log.err("failed to send error: {}", .{e});
                        return;
                    };
                };
            },

            // alias: PACKET_LIST client side for getting a list of clients
            .on_client_update => {
                const clients = getList(allocator, list.items) catch |err| {
                    std.log.err("failed to get list: {}", .{err});
                    const response = Connection.Data.err(allocator, "Error getting list...");
                    defer response.deinit();
                    ptr.writeAction(response) catch |e| {
                        std.log.err("failed to send error: {}", .{e});
                        return;
                    };
                    continue;
                };
                defer allocator.free(clients);
                const response = Connection.Data.success(allocator, clients);
                defer response.deinit();
                connection.writeAction(response) catch |err| {
                    std.log.err("failed to send success: {}", .{err});
                    return;
                };
            },
            .get_name => {
                std.log.debug("sending name", .{});
                const response = Connection.Data.success(allocator, ptr.alias);
                defer response.deinit();
                connection.writeAction(response) catch |err| {
                    std.log.err("failed to send success: {}", .{err});
                    return;
                };
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
