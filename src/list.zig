const std = @import("std");

list: std.ArrayList(Item) = .empty,

pub const empty: @This() = .{};

pub const NAME_MAX_LEN = 200;

pub const Status = enum(u8) {
    want,
    got,
    history,
};

pub const Item = struct {
    id: u32,
    last_write: i128, // nanos since posix epoch
    status: Status,
    order: f64,
    name: [NAME_MAX_LEN]u8,

    pub fn array(s: []const u8) [NAME_MAX_LEN:0]u8 {
        var v: [NAME_MAX_LEN:0]u8 = @splat(0);
        @memcpy(v[0..s.len], s);
        return v;
    }

    pub fn new(time: i128, name: []const u8) Item {
        var hash = std.hash.XxHash32.init(0);
        hash.update(std.mem.asBytes(&time));
        return .{
            .id = hash.final(),
            .last_write = time,
            .status = .want,
            .order = 0,
            .name = array(name),
        };
    }

    pub fn updateStatus(self: *Item, time: i128, s: Status) void {
        self.status = s;
        self.last_write = time;
    }

    pub fn updateName(self: *Item, time: i128, name: []const u8) void {
        self.name = array(name);
        self.last_write = time;
    }

    pub fn updateOrder(self: *Item, time: i128, order: f64) void {
        self.order = order;
        self.last_write = time;
    }
};

pub fn reorder(self: *@This(), time: i128, from: usize, to_in: usize) void {
    var to = to_in;
    std.log.debug("reoder {d} {d}", .{ from, to });

    if (from < to) {
        to -|= 1;
        if (from == to) {
            std.log.debug("reoder nothing", .{});
            return;
        }
        var item = self.list.items[from];
        for (from..to) |i| {
            self.list.items[i] = self.list.items[i + 1];
        }
        const before = self.list.items[to - 1].order;
        if (self.list.items.len > to + 1) {
            const after = self.list.items[to + 1].order;
            const between = (before + after) / 2;
            item.updateOrder(time, between);
            self.list.items[to] = item;
            if (between == before or between == after) {
                self.reorderAll(time);
            }
        } else {
            const space = 1.0 - before;
            if (space < 0.000001) {
                item.updateOrder(time, before + space / 2);
                self.list.items[to] = item;
                self.reorderAll(time);
            } else {
                item.updateOrder(time, before + 0.000001);
                self.list.items[to] = item;
            }
        }
    } else {
        var item = self.list.items[from];
        var i: usize = from;
        while (i > to) : (i -= 1) {
            self.list.items[i] = self.list.items[i - 1];
        }
        const before: f64 = if (to == 0) 0 else self.list.items[to - 1].order;
        const after = self.list.items[to + 1].order;
        const between = (before + after) / 2;
        item.updateOrder(time, between);
        self.list.items[to] = item;
        if (between == before or between == after) {
            self.reorderAll(time);
        }
    }
}

pub fn append(self: *@This(), gpa: std.mem.Allocator, time: i128, item: Item) void {
    var it = item;
    it.last_write = time;

    var last_order: f64 = 0;
    if (self.list.items.len > 0) {
        last_order = self.list.items[self.list.items.len - 1].order;
    }

    const space = 1.0 - last_order;
    if (space < 0.000001) {
        it.updateOrder(time, last_order + space / 2);
        self.list.append(gpa, it) catch @panic("OOM");
        self.reorderAll(time);
    } else {
        it.updateOrder(time, last_order + 0.000001);
        self.list.append(gpa, it) catch @panic("OOM");
    }
}

// We ran into some limit, need to reorder all elements
fn reorderAll(self: *@This(), time: i128) void {
    std.log.warn("reordering list", .{});
    for (self.list.items, 1..) |*li, i| {
        li.updateOrder(time, 0.000001 * @as(f64, @floatFromInt(i)));
    }
}

pub fn format(self: *const @This(), writer: *std.Io.Writer) !void {
    for (self.list.items) |*li| {
        try writer.print("{d} {d} {d} {d} {s}\n", .{ li.id, li.last_write, @intFromEnum(li.status), li.order, std.mem.sliceTo(&li.name, 0) });
    }
}

pub fn load(gpa: std.mem.Allocator, reader: *std.Io.Reader) @This() {
    var ret: @This() = .empty;
    while (true) {
        const item = loadItem(reader) catch |err| {
            std.log.debug("loadItem got {any}", .{err});
            return ret;
        };
        ret.list.append(gpa, item) catch |err| {
            std.log.debug("couldn't append item {any}", .{err});
            return ret;
        };
    }

    return ret;
}

fn loadItem(reader: *std.Io.Reader) !Item {
    const id_str = try reader.takeDelimiterExclusive(' ');
    const id = try std.fmt.parseInt(u32, id_str, 10);
    reader.toss(1);

    const time_str = try reader.takeDelimiterExclusive(' ');
    const time = try std.fmt.parseInt(i128, time_str, 10);
    reader.toss(1);

    const status_str = try reader.takeDelimiterExclusive(' ');
    const status = try std.fmt.parseInt(u32, status_str, 10);
    reader.toss(1);

    const order_str = try reader.takeDelimiterExclusive(' ');
    const order = try std.fmt.parseFloat(f64, order_str);
    reader.toss(1);

    const name = try reader.takeDelimiterExclusive('\n');
    reader.toss(1);

    std.debug.print("loadItem {d} {d} {d} {s}\n", .{ id, status, order, name });

    return .{
        .id = id,
        .last_write = time,
        .status = @enumFromInt(status),
        .order = order,
        .name = Item.array(name),
    };
}
