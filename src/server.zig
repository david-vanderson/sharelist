const std = @import("std");
const List = @import("list.zig");

var gpa: std.mem.Allocator = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    gpa = init.gpa;

    //const arena = init.arena.allocator();
    //const args = try init.minimal.args.toSlice(arena);
    //if (args.len != 1) return error.MissingArguments;

    const addr = comptime std.Io.net.IpAddress.parse("127.0.0.1", 8111) catch unreachable;

    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    var io_group: std.Io.Group = .init;
    defer io_group.cancel(io);

    while (true) {
        const stream = server.accept(io) catch |err| {
            std.log.err("Failed to accept connection: {t}", .{err});
            continue;
        };
        errdefer stream.close(io);
        try io_group.concurrent(io, accept, .{ stream, io });
    }
}

fn accept(stream: std.Io.net.Stream, io: std.Io) std.Io.Cancelable!void {
    acceptInner(stream, io) catch |err| std.log.err("Connection error: {t}", .{err});
}

fn acceptInner(stream: std.Io.net.Stream, io: std.Io) !void {
    defer stream.close(io);

    var recv_buffer: [1024]u8 = undefined;
    var send_buffer: [1024]u8 = undefined;

    var stream_reader = stream.reader(io, &recv_buffer);
    var stream_writer = stream.writer(io, &send_buffer);
    var server: std.http.Server = .init(&stream_reader.interface, &stream_writer.interface);

    while (server.reader.state == .ready) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => |e| return e,
        };
        try serve(&request, io);
    }
}

fn serve(request: *std.http.Server.Request, io: std.Io) !void {
    std.log.debug("target: {s}\n", .{request.head.target});

    if (std.mem.eql(u8, request.head.target, "/list.txt")) {
        if (request.head.method == .GET) {
            const file = try std.Io.Dir.cwd().openFile(io, "list.txt", .{});
            var buf: [1000]u8 = undefined;
            var reader = file.reader(io, &buf);
            const content = try reader.interface.allocRemaining(gpa, .unlimited);
            defer gpa.free(content);

            request.respond(content, .{ .extra_headers = &.{.{ .name = "Access-Control-Allow-Origin", .value = "*" }} }) catch {};
        } else if (request.head.method == .POST) {
            var buf: [1000]u8 = undefined;
            var reader = request.server.reader.bodyReader(&buf, request.head.transfer_encoding, request.head.content_length);
            const payload = try reader.allocRemaining(gpa, .unlimited);
            defer gpa.free(payload);

            std.log.debug("post:\n{s}", .{payload});

            var r: std.Io.Reader = .fixed(payload);
            var posted = List.load(gpa, &r);
            defer posted.deinit(gpa);

            const file = try std.Io.Dir.cwd().openFile(io, "list.txt", .{});
            var file_reader = file.reader(io, &buf);
            const file_content = try file_reader.interface.allocRemaining(gpa, .unlimited);
            file.close(io);
            defer gpa.free(file_content);

            r = .fixed(file_content);
            var saved = List.load(gpa, &r);
            defer saved.deinit(gpa);

            std.log.debug("merge", .{});
            const time = std.Io.Clock.real.now(io).nanoseconds;
            saved.merge(gpa, time, &posted);

            const file2 = try std.Io.Dir.cwd().openFile(io, "list.txt", .{ .mode = .write_only });
            var writer = file2.writer(io, &buf);
            try writer.interface.print("{f}", .{saved});
            try writer.end();
            file2.close(io);

            request.respond(std.http.Status.ok.phrase().?, .{ .extra_headers = &.{.{ .name = "Access-Control-Allow-Origin", .value = "*" }} }) catch {};
        }
    } else {
        request.respond(std.http.Status.not_found.phrase().?, .{ .status = .not_found, .keep_alive = false }) catch {};
    }
}
