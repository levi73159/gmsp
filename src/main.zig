const std = @import("std");
const net = std.net;
const posix = std.posix;
const Thread = std.Thread;

const Server = @import("Server.zig");
const Client = @import("Client.zig");
const Connection = @import("Connection.zig");

fn getInput(prompt: []const u8, buffer: []u8) !?[]const u8 {
    std.io.getStdOut().writeAll(prompt) catch |err| {
        std.log.err("failed to write prompt: {}", .{err});
        return err;
    };

    return std.io.getStdIn().reader().readUntilDelimiterOrEof(buffer, '\n');
}

fn getInputAlloc(allocator: std.mem.Allocator, prompt: []const u8) !?[]const u8 {
    std.io.getStdOut().writeAll(prompt) catch |err| {
        std.log.err("failed to write prompt: {}", .{err});
        return err;
    };
    return std.io.getStdIn().reader().readUntilDelimiterOrEofAlloc(allocator, '\n', 4096);
}

fn messageThread(connection: *Connection) void {
    while (true) {
        const data = connection.readData() catch |err| {
            std.log.err("failed to read message: {}", .{err});
            break;
        };

        switch (data) {
            .err => |err| std.log.err("SERVER: {s}", .{err}),
            .message => |msg| {
                std.io.getStdOut().writeAll(msg) catch |err| {
                    std.log.err("failed to write message: {}", .{err});
                    break;
                };
                std.io.getStdOut().writeAll("\n") catch unreachable;
            },
            else => {
                connection.writeError("INVALID ACTION") catch unreachable;
            },
        }
    }
}

fn runClient(addr: net.Address) !void {
    var areana = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer areana.deinit();

    var input_buffer: [4096]u8 = undefined;
    var client = try Client.connect(areana.allocator(), addr);
    defer client.deinit();
    defer client.close();

    const connection = client.connection();

    const thread = try Thread.spawn(.{}, messageThread, .{connection});
    thread.detach();

    {
        const name = try getInput("Enter name: ", &input_buffer) orelse return error.NameNotProvided;
        try connection.writeAction(.{ .change_name = name });
    }

    while (true) {
        const input = try getInput("", &input_buffer) orelse continue;
        if (input[0] == ':') {
            const name = input[1..];
            if (name.len == 0) {
                continue;
            } else if (std.mem.eql(u8, name, "name")) {
                try connection.writeAction(.{ .get = "alias" });
                continue;
            }

            // we want to get a thing
            try connection.writeAction(.{ .get = input[1..] });
            continue;
        }

        if (std.mem.eql(u8, input, "exit")) {
            break;
        }
        try connection.writeMessage(input);
    }
}

pub fn main() !void {
    const addr = try net.Address.parseIp("127.0.0.1", 8080);
    try Server.run(addr);
}
