const std = @import("std");
const List = @import("list.zig");

var gpa: std.mem.Allocator = undefined;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    gpa = init.gpa;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    for (args) |a| std.debug.print("arg: {s}\n", .{a});
    if (args.len == 4) try readFiles(io, arena, args);

    const addr = comptime std.Io.net.IpAddress.parse("127.0.0.1", 3000) catch unreachable;

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

const Response = struct {
    mime: []const u8,
    location: []const u8,
    content: []const u8,
    etag: []const u8,
};

var html: Response = .{ .mime = "text/html", .location = undefined, .content = "", .etag = undefined };
var js: Response = .{ .mime = "text/javascript", .location = undefined, .content = "", .etag = undefined };
var wasm: Response = .{ .mime = "application/wasm", .location = undefined, .content = "", .etag = undefined };

fn readFiles(io: std.Io, arena: std.mem.Allocator, args: []const [:0]const u8) !void {
    const cwd: std.Io.Dir = .cwd();
    var read_buf: [1024]u8 = undefined;
    for (args[1..4], [_]*Response{ &html, &js, &wasm }) |path, response| {
        const file = try cwd.openFile(io, path, .{});
        defer file.close(io);

        response.location = try std.fmt.allocPrint(arena, "/{s}", .{std.fs.path.basename(path)});

        var file_reader = file.reader(io, &read_buf);
        const reader = &file_reader.interface;
        const content = try reader.allocRemaining(arena, .unlimited);
        response.content = content;

        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(content, &hash, .{});
        const etag = try arena.create([2 + std.base64.url_safe.Encoder.calcSize(hash.len)]u8);
        etag[0] = '"';
        etag[etag.len - 1] = '"';
        _ = std.base64.url_safe.Encoder.encode(etag[1 .. etag.len - 1], &hash);
        response.etag = etag;
    }
}

fn accept(stream: std.Io.net.Stream, io: std.Io) std.Io.Cancelable!void {
    defer stream.close(io);

    acceptInner(stream, io) catch |err| {
        std.log.err("Connection error: {t}", .{err});
        _ = try io.sleep(.fromSeconds(2), .awake);
    };
}

fn acceptInner(stream: std.Io.net.Stream, io: std.Io) !void {
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
    std.log.debug("target: {s}", .{request.head.target});

    const uri = std.Uri.parseAfterScheme("http", request.head.target) catch return error.uri_parse;
    var path_buf: [100]u8 = undefined;
    const path = uri.path.toRaw(&path_buf) catch return error.path_to_raw;

    if (std.mem.eql(u8, path, "/")) {
        if (html.content.len > 0) {
            try request.respond(html.content, .{ .extra_headers = &.{.{ .name = "content-type", .value = html.mime }} });
        } else {
            _ = try io.sleep(.fromSeconds(2), .awake);
            try request.respond(std.http.Status.not_found.phrase().?, .{ .status = .not_found, .keep_alive = false });
        }
        return;
    }

    if (std.mem.eql(u8, path, "/web.js")) {
        try request.respond(js.content, .{ .extra_headers = &.{.{ .name = "content-type", .value = js.mime }} });
        return;
    }

    if (std.mem.eql(u8, path, "/web.wasm")) {
        try request.respond(wasm.content, .{ .extra_headers = &.{.{ .name = "content-type", .value = wasm.mime }} });
        return;
    }

    if (std.mem.eql(u8, path, "/list")) {
        if (uri.query == null) return error.query_null;

        var query_buf: [100]u8 = undefined;
        const query = uri.query.?.toRaw(&query_buf) catch return error.query_to_raw;

        var file_buf: [100]u8 = undefined;
        var filename: ?[]u8 = null;

        var it = std.mem.tokenizeScalar(u8, query, '&');
        while (it.next()) |q| {
            if (std.mem.startsWith(u8, q, "id")) {
                if (q.len != 11) return error.query;
                const id = try std.fmt.parseInt(u32, q[3..], 16);
                filename = try std.fmt.bufPrint(&file_buf, "lists/{x}", .{id});
            }
        }

        if (filename == null) return error.filename_null;
        std.log.debug("filename: {s}", .{filename.?});

        if (request.head.method == .GET) {
            const file = try std.Io.Dir.cwd().openFile(io, filename.?, .{});
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
            var posted = try List.load(gpa, &r);
            defer posted.deinit(gpa);

            const file = try std.Io.Dir.cwd().openFile(io, filename.?, .{});
            var file_reader = file.reader(io, &buf);
            const file_content = try file_reader.interface.allocRemaining(gpa, .unlimited);
            file.close(io);
            defer gpa.free(file_content);

            r = .fixed(file_content);
            var saved = try List.load(gpa, &r);
            defer saved.deinit(gpa);

            std.log.debug("merge", .{});
            const time = std.Io.Clock.real.now(io).nanoseconds;
            saved.merge(gpa, time, &posted);

            const file2 = try std.Io.Dir.cwd().openFile(io, filename.?, .{ .mode = .write_only });
            var writer = file2.writer(io, &buf);
            try writer.interface.print("{f}", .{saved});
            try writer.end();
            file2.close(io);

            const content = try std.fmt.allocPrint(gpa, "{f}", .{saved});
            defer gpa.free(content);

            request.respond(content, .{ .extra_headers = &.{.{ .name = "Access-Control-Allow-Origin", .value = "*" }} }) catch {};
        }
    } else {
        request.respond(std.http.Status.not_found.phrase().?, .{ .status = .not_found, .keep_alive = false }) catch {};
    }
}
