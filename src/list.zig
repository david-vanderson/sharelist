const std = @import("std");

version: u8,
name: [NAME_MAX_LEN]u8,
last_write: i128, // nanos since posix epoch
stuff: std.ArrayList(Item),

pub const empty: @This() = .{
    .version = 0,
    .name = Item.array("List"),
    .last_write = 0,
    .stuff = .empty,
};

pub const NAME_MAX_LEN = 200;

pub const Status = enum(u8) {
    tag,
    want,
    got,
    history,
};

pub fn updateName(self: *@This(), time: i128, name: []const u8) void {
    self.name = Item.array(name);
    self.last_write = time;
}

pub const Item = struct {
    id: u32,
    tag: u32, // id of a .tag Item
    last_write: i128, // nanos since posix epoch
    status: Status,
    order: f64,
    name: [NAME_MAX_LEN]u8,

    pub fn array(s: []const u8) [NAME_MAX_LEN:0]u8 {
        var v: [NAME_MAX_LEN:0]u8 = @splat(0);
        @memcpy(v[0..s.len], s);
        return v;
    }

    pub fn new(time: i128, status: Status, tag_id: u32, name: []const u8) Item {
        var hash = std.hash.XxHash32.init(0);
        hash.update(std.mem.asBytes(&time));
        return .{
            .id = hash.final(),
            .tag = tag_id,
            .last_write = time,
            .status = status,
            .order = 0,
            .name = array(name),
        };
    }

    pub fn updateStatus(self: *Item, time: i128, s: Status) void {
        self.status = s;
        self.last_write = time;
    }

    pub fn updateTag(self: *Item, time: i128, t: u32) void {
        self.tag = t;
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

pub fn reorder(self: *@This(), time: i128, from: usize, to: usize) void {
    std.log.debug("reoder {d} {d}", .{ from, to });

    var item = self.stuff.items[from];
    if (from < to) {
        // shift up
        for (from..to) |i| {
            self.stuff.items[i] = self.stuff.items[i + 1];
        }
    } else {
        // shift down
        // from == to might be true during merge
        var i: usize = from;
        while (i > to) : (i -= 1) {
            self.stuff.items[i] = self.stuff.items[i - 1];
        }
    }

    const before: f64 = if (to == 0) 0 else self.stuff.items[to - 1].order;
    if (self.stuff.items.len > to + 1) {
        const after = self.stuff.items[to + 1].order;
        const between = (before + after) / 2;
        item.updateOrder(time, between);
        self.stuff.items[to] = item;
        if (between == before or between == after) {
            self.reorderAll(time);
        }
    } else {
        const space = 1.0 - before;
        if (space < 0.000001) {
            item.updateOrder(time, before + space / 2);
            self.stuff.items[to] = item;
            self.reorderAll(time);
        } else {
            item.updateOrder(time, before + 0.000001);
            self.stuff.items[to] = item;
        }
    }
}

pub fn append(self: *@This(), gpa: std.mem.Allocator, time: i128, item: Item) void {
    var it = item;
    it.last_write = time;

    var last_order: f64 = 0;
    if (self.stuff.items.len > 0) {
        last_order = self.stuff.items[self.stuff.items.len - 1].order;
    }

    const space = 1.0 - last_order;
    if (space < 0.000001) {
        it.updateOrder(time, last_order + space / 2);
        self.stuff.append(gpa, it) catch @panic("OOM");
        self.reorderAll(time);
    } else {
        it.updateOrder(time, last_order + 0.000001);
        self.stuff.append(gpa, it) catch @panic("OOM");
    }
}

// We ran into some limit, need to reorder all elements
fn reorderAll(self: *@This(), time: i128) void {
    std.log.warn("reordering stuff", .{});
    for (self.stuff.items, 1..) |*li, i| {
        li.updateOrder(time, 0.000001 * @as(f64, @floatFromInt(i)));
    }
}

pub fn merge(self: *@This(), gpa: std.mem.Allocator, time: i128, other: *const @This()) void {
    if (other.last_write > self.last_write) {
        self.name = other.name;
        self.last_write = other.last_write;
    }

    // for each item in other:
    // * if we have that one (same id), update ours if other's time is later
    // * if we don't, shove it in the stuff (not updating order)
    // sort our stuff (by order, then id)
    // * if any duplicate orders:
    //   * there will only be 2
    //   * take the second and reorder it

    outer: for (other.stuff.items) |*oi| {
        for (self.stuff.items) |*li| {
            if (li.id == oi.id) {
                if (oi.last_write > li.last_write) {
                    li.* = oi.*;
                }
                continue :outer;
            }
        }

        // didn't find a match
        self.stuff.append(gpa, oi.*) catch @panic("OOM");
    }

    std.mem.sortUnstable(Item, self.stuff.items, {}, (struct {
        fn lessThan(_: void, lhs: Item, rhs: Item) bool {
            if (lhs.order < rhs.order) return true;
            if (lhs.order > rhs.order) return false;
            if (lhs.id < rhs.id) return true;
            return false;
        }
    }).lessThan);

    // we might have duplicate order numbers (only ever 2)
    for (0..self.stuff.items.len -| 1) |i| {
        const item = &self.stuff.items[i];
        const next = &self.stuff.items[i + 1];

        if (item.order == next.order) {
            std.log.debug("duplicate order at {d} {d}", .{ i, i + 1 });
            self.reorder(time, i + 1, i + 1);
        }
    }

    // discard really old history items (more than 60 weeks)
    var i: usize = 0;
    while (i < self.stuff.items.len) {
        const li = &self.stuff.items[i];
        if (li.status == .history and (time - li.last_write) > 60 * std.time.ns_per_week) {
            std.log.debug("removing item {d} {s}", .{ i, std.mem.sliceTo(&li.name, 0) });
            _ = self.stuff.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn format(self: *const @This(), writer: *std.Io.Writer) !void {
    try writer.print("{d} {d} {s}\n", .{ self.version, self.last_write, std.mem.sliceTo(&self.name, 0) });
    for (self.stuff.items) |*li| {
        try writer.print("{x} {x} {d} {d} {d} {s}\n", .{ li.id, li.tag, li.last_write, @backingInt(li.status), li.order, std.mem.sliceTo(&li.name, 0) });
    }
}

pub fn load(gpa: std.mem.Allocator, reader: *std.Io.Reader) !@This() {
    var ret: @This() = .empty;

    const version_str = reader.takeDelimiterExclusive(' ') catch null;
    if (version_str) |vs| {
        ret.version = try std.fmt.parseInt(u8, vs, 16);
        reader.toss(1);

        if (ret.version != 0) return error.Version;

        const time_str = try reader.takeDelimiterExclusive(' ');
        ret.last_write = try std.fmt.parseInt(i128, time_str, 10);
        reader.toss(1);

        ret.name = Item.array(try reader.takeDelimiterExclusive('\n'));
        reader.toss(1);
    }

    while (true) {
        const item = loadItem(reader) catch |err| {
            std.log.debug("loadItem got {any}", .{err});
            return ret;
        };
        ret.stuff.append(gpa, item) catch |err| {
            std.log.debug("couldn't append item {any}", .{err});
            return ret;
        };
    }

    return ret;
}

fn loadItem(reader: *std.Io.Reader) !Item {
    const id_str = try reader.takeDelimiterExclusive(' ');
    const id = try std.fmt.parseInt(u32, id_str, 16);
    reader.toss(1);

    const tag_id_str = try reader.takeDelimiterExclusive(' ');
    const tag_id = try std.fmt.parseInt(u32, tag_id_str, 16);
    reader.toss(1);

    const time_str = try reader.takeDelimiterExclusive(' ');
    const time = try std.fmt.parseInt(i128, time_str, 10);
    reader.toss(1);

    const status_str = try reader.takeDelimiterExclusive(' ');
    const status = try std.fmt.parseInt(u8, status_str, 10);
    reader.toss(1);

    const order_str = try reader.takeDelimiterExclusive(' ');
    const order = try std.fmt.parseFloat(f64, order_str);
    reader.toss(1);

    const name = try reader.takeDelimiterExclusive('\n');
    reader.toss(1);

    std.log.debug("loadItem {x} {x} {d} {d} {s}\n", .{ id, tag_id, status, order, name });

    return .{
        .id = id,
        .tag = tag_id,
        .last_write = time,
        .status = @fromBackingInt(@intCast(status)),
        .order = order,
        .name = Item.array(name),
    };
}

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    self.stuff.clearAndFree(gpa);
}
