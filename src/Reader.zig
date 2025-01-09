const std = @import("std");
const posix = std.posix;
const net = std.net;
const Action = @import("Connection.zig").Action;

const Self = @This();

// This is what we'll read into and where we'll look for a complete message
buf: []u8,

// This is where in buf that we're read up to, any subsequent reads need
// to start from here
pos: usize = 0,

// This is where our next message starts at
start: usize = 0,

// The socket to read from
socket: posix.socket_t,

pub const Data = struct {
    action: Action,
    segments: std.ArrayList([]u8),

    pub const Owned = struct {
        action: Action,
        segments: [][]u8,
        allocator: std.mem.Allocator,

        pub fn deinit(self: Owned) void {
            self.allocator.free(self.segments);
        }
    };

    pub fn init(allocator: std.mem.Allocator, action: Action) Data {
        return Data{
            .action = action,
            .segments = std.ArrayList([]u8).init(allocator),
        };
    }

    pub fn deinit(self: Data) void {
        self.segments.deinit();
    }

    pub fn toOwned(self: *Data) Owned {
        return Owned{
            .action = self.action,
            .segments = self.segments.toOwnedSlice() catch unreachable,
            .allocator = self.segments.allocator,
        };
    }

    pub fn addSegment(self: *Data, data: []u8) void {
        self.segments.append(data) catch unreachable;
    }
};

pub fn readData(self: *Self, allocator: std.mem.Allocator) !Data {
    var buf = self.buf;

    // loop until we've read a message, or the connection was closed
    while (true) {

        // Check if we already have a message in our buffer
        if (try self.bufferedData(allocator)) |data| {
            return data;
        }

        // read data from the socket, we need to read this into buf from
        // the end of where we have data (aka, self.pos)
        const pos = self.pos;
        const n = try posix.read(self.socket, buf[pos..]);
        if (n == 0) {
            return error.Closed;
        }

        self.pos = pos + n;
    }
}

/// Start reading from the start of the buffer
/// This is useful if we want to re-use the buffer
/// This will reset the position to 0 but not clear the buffer because it is unessesary
pub fn flush(self: Self) void {
    self.pos = 0;
    self.start = 0;
}

// checks if there's a full data in self.buf already
// If there isn't, checks that we have enough spare space in self.buf for
// the next data
fn bufferedData(self: *Self, allocator: std.mem.Allocator) !?Data {
    const buf = self.buf;
    // position up to where we have valid data
    const pos = self.pos;

    // position where the next data start
    const start = self.start;

    // pos - start represents bytes that we've read from the socket
    // but that we haven't yet returned as a "data" - possibly because
    // its incomplete.
    std.debug.assert(pos >= start);
    var unprocessed = buf[start..pos];

    // we always need two bytes, one for the action and one for the amount of data
    if (unprocessed.len < 2) {
        self.ensureSpace(2 - unprocessed.len) catch unreachable;
        return null;
    }

    // The action prefix
    const action = std.mem.readInt(u8, unprocessed[0..1], .little);
    const action_enum: Action = @enumFromInt(action);

    std.log.debug("Action: {s}", .{@tagName(action_enum)});

    // The amount of data we are sending can be zero
    const amount_len = std.mem.readInt(u8, unprocessed[1..2], .little);

    std.log.debug("Amount: {d}", .{amount_len});

    var data = Data.init(allocator, action_enum);

    if (amount_len == 0) {
        return data;
    }

    var i: u8 = 0;
    var total_packet_len: usize = 2; // 2 for header
    while (i < amount_len) : (i += 1) {
        // check if we have 4 bytes for the data len
        std.log.debug("Segment {d}", .{i});
        if (unprocessed.len < 4) {
            self.ensureSpace(4 - unprocessed.len) catch unreachable;
            return null;
        }

        // the length of this data segment
        const data_len = std.mem.readInt(u32, unprocessed[2..6], .little);

        std.log.debug("Data len {d}", .{data_len});

        // the length of our data + the length of our prefix which is 2 bytes (action and amount) + 4 (data seg len)
        const total_len = data_len + 4;

        std.log.debug("Total len {d}", .{total_len});

        if (unprocessed.len < total_len) {
            // We know the length of the data, but we don't have all the
            // bytes yet.
            try self.ensureSpace(total_len);
            return null;
        }

        const segment = unprocessed[total_packet_len + 4 ..][0..data_len];
        total_packet_len += total_len;
        data.addSegment(segment);
        std.log.debug("Added segment: {s}", .{segment});
        std.log.debug("RAW: {any}", .{segment});
    }

    // Position start at the start of the next message. We might not have
    // any data for this next message, but we know that it'll start where
    // our last message ended.
    self.start += total_packet_len;

    return data;
}

// We want to make sure we have enough spare space in our buffer. This can
// mean two things:
//   1 - If we know that length of the next message, we need to make sure
//       that our buffer is large enough for that message. If our buffer
//       isn't large enough, we return an error (as an alternative, we could
//       do something else, like dynamically allocate memory or pull a large
//       buffer froma buffer pool).
//   2 - At any point that we need to read more data, we need to make sure
//       that our "spare" space (self.buf.len - self.start) is large enough
//       for the required data. If it isn't, we need shift our buffer around
//       and move whatever unprocessed data we have back to the start.
fn ensureSpace(self: *Self, space: usize) error{BufferTooSmall}!void {
    const buf = self.buf;
    if (buf.len < space) {
        // Even if we compacted our buffer (moving any unprocessed data back
        // to the start), we wouldn't have enough space for this message in
        // our buffer. Alternatively: dynamically allocate or pull a large
        // buffer from a buffer pool.
        return error.BufferTooSmall;
    }

    const start = self.start;
    const spare = buf.len - start;
    if (spare >= space) {
        // We have enough spare space in our buffer, nothing to do.
        return;
    }

    // At this point, we know that our buffer is larger enough for the data
    // we want to read, but we don't have enough spare space. We need to
    // "compact" our buffer, moving any unprocessed data back to the start
    // of the buffer.
    const unprocessed = buf[start..self.pos];
    std.mem.copyForwards(u8, buf[0..unprocessed.len], unprocessed);
    self.start = 0;
    self.pos = unprocessed.len;
}
