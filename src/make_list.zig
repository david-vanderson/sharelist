const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var bytes: [8]u8 = undefined;
    init.io.random(&bytes);
    std.log.debug("random u64: {x}\n", .{bytes});

    var buf: [200]u8 = undefined;
    const filename = try std.fmt.bufPrint(&buf, "lists/{x}", .{bytes});
    const file = std.Io.Dir.cwd().createFile(init.io, filename, .{}) catch |err| {
        std.log.err("error creating list {x}: {any}", .{ bytes, err });
        return;
    };
    file.close(init.io);

    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);
    const stdout = &stdout_writer.interface;

    try stdout.print("New list lists/{x}\n", .{bytes});
    try stdout.print("Native test url: http://localhost:3000/sharelist/list?id={x}\n", .{bytes});
    try stdout.print("Web url: http://localhost:3000/sharelist/?id={x}\n", .{bytes});
    try stdout.flush();
}
