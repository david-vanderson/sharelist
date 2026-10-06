const std = @import("std");

list: std.ArrayList(Item) = .empty,

pub const empty: @This() = .{};

pub const Status = enum(u8) {
    want,
    got,
    history,
};

pub const Item = struct {
    const NAME_MAX_LEN = 200;
    id: u32,
    name: [NAME_MAX_LEN]u8,
    status: Status,
    order: f32,

    pub fn array(s: []const u8) [NAME_MAX_LEN:0]u8 {
        var v: [NAME_MAX_LEN:0]u8 = @splat(0);
        @memcpy(v[0..s.len], s);
        return v;
    }
};

pub fn format(self: *const @This(), writer: *std.Io.Writer) !void {
    for (self.list.items) |*li| {
        try writer.print("{d} {d} {d} {s}\n", .{ li.id, @intFromEnum(li.status), li.order, std.mem.sliceTo(&li.name, 0) });
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

    const status_str = try reader.takeDelimiterExclusive(' ');
    const status = try std.fmt.parseInt(u32, status_str, 10);
    reader.toss(1);

    const order_str = try reader.takeDelimiterExclusive(' ');
    const order = try std.fmt.parseFloat(f32, order_str);
    reader.toss(1);

    const name = try reader.takeDelimiterExclusive('\n');
    reader.toss(1);

    std.debug.print("loadItem {d} {d} {d} {s}\n", .{ id, status, order, name });

    return .{
        .id = id,
        .status = @enumFromInt(status),
        .order = order,
        .name = Item.array(name),
    };
}
