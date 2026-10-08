const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const List = @import("list.zig");

var list: List = .empty;

// To be a dvui App:
// * declare "dvui_app"
// * expose the backend's main function
// * use the backend's log function
pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 800.0, .h = 600.0 },
            .min_size = .{ .w = 250.0, .h = 350.0 },
            .title = "ShareList",
            .window_init_options = .{
                // Could set a default theme here
                // .theme = dvui.Theme.builtin.dracula,
            },
        },
    },
    .frameFn = appFrame,
    .initFn = appInit,
    .deinitFn = appDeinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

var orig_content_scale: f32 = 1.0;
var gpa: std.mem.Allocator = undefined;

// Runs before the first frame, after backend and dvui.Window.init()
// - runs between win.begin()/win.end()
pub fn appInit(win: *dvui.Window) !void {
    orig_content_scale = win.content_scale;
    gpa = win.gpa;

    //for (0..20) |i| {
    //    const txt = std.fmt.allocPrint(dvui.currentWindow().arena(), "Item {d}", .{i}) catch "OOM";
    //    list.list.append(win.gpa, .{ .id = @intCast(i), .order = @floatFromInt(i), .name = List.Item.array(txt), .status = .want }) catch @panic("OOM");
    //}
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn appDeinit(win: *dvui.Window) void {
    // good place to free anything you've allocated with win.gpa
    list.list.clearAndFree(win.gpa);
}

// Run each frame to do normal UI
pub fn appFrame() !dvui.App.Result {
    {
        var scaler = dvui.scale(@src(), .{ .scale = &dvui.currentWindow().content_scale, .pinch_zoom = .global }, .{ .rect = .cast(dvui.windowRect()) });
        scaler.deinit();

        var new_item = false;
        var refresh_items = false;

        {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hbox.deinit();

            if (dvui.button(@src(), "Debug", .{}, .{})) {
                dvui.toggleDebugWindow();
            }

            if (dvui.button(@src(), "Load", .{}, .{})) blk: {
                var client: std.http.Client = .{
                    .allocator = gpa,
                    .io = dvui.io,
                };
                defer client.deinit();

                var result_body = std.Io.Writer.Allocating.init(gpa);
                defer result_body.deinit();

                const response = client.fetch(.{ .location = .{ .url = "http://localhost:8111/list.txt" }, .response_writer = &result_body.writer }) catch |err| {
                    std.log.err("Failed to fetch list: {any}", .{err});
                    break :blk;
                };

                _ = response;

                var r: std.Io.Reader = .fixed(result_body.written());
                var loaded = List.load(gpa, &r);
                defer loaded.list.clearAndFree(gpa);

                const time = std.Io.Clock.real.now(dvui.io).nanoseconds;
                list.merge(gpa, time, &loaded);
                refresh_items = true;
            }

            if (dvui.button(@src(), "Save", .{}, .{})) {
                std.debug.print("List:\n{f}", .{list});

                const payload = try std.fmt.allocPrint(gpa, "{f}", .{list});
                defer gpa.free(payload);

                var client: std.http.Client = .{
                    .allocator = gpa,
                    .io = dvui.io,
                };
                defer client.deinit();

                _ = client.fetch(.{ .location = .{ .url = "http://localhost:8111/list.txt" }, .payload = payload }) catch |err| {
                    std.log.err("Failed to post list: {any}", .{err});
                };
            }

            if (dvui.button(@src(), "Test", .{}, .{})) {
                for (0..100) |i| {
                    std.debug.print("reoder {d}\n", .{i});
                    const time = std.Io.Clock.real.now(dvui.io).nanoseconds;
                    list.reorder(time, 0, 1);
                }
            }

            if (dvui.buttonIcon(@src(), "plus", dvui.entypo.plus, .{}, .{}, .{ .gravity_x = 1.0 })) {
                const time = std.Io.Clock.real.now(dvui.io).nanoseconds;
                const item = List.Item.new(time, "New Item");
                list.append(gpa, time, item);
                new_item = true;
            }
        }

        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
        defer scroll.deinit();

        var removed_idx: ?usize = null;
        var insert_before_idx: ?usize = null;
        var reorder = dvui.reorder(@src(), .{}, .{ .expand = .horizontal });
        var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal });

        var last_index: usize = 0;
        for (list.list.items, 0..) |*li, i| {
            if (li.status != .want) continue;
            last_index = i;
            var reorderable = reorder.reorderable(@src(), .{}, .{ .id_extra = li.id, .expand = .horizontal });

            if (reorderable.removed()) {
                removed_idx = i; // this entry is being dragged
            } else if (reorderable.insertBefore()) {
                insert_before_idx = i; // this entry was dropped onto
            }

            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });

            var temp: bool = false;
            if (dvui.checkbox(@src(), &temp, "", .{ .gravity_y = 0.5 })) {
                const time = std.Io.Clock.real.now(dvui.io).nanoseconds;
                li.updateStatus(time, .got);
            }

            //dvui.label(@src(), "{s}", .{std.mem.sliceTo(&li.name, 0)}, .{ .color_text = .gray });

            var te = dvui.textEntry(@src(), .{
                .text = .{ .internal = .{ .limit = List.NAME_MAX_LEN } },
                .text_initial = std.mem.sliceTo(&li.name, 0),
            }, .{
                .style = .window,
                .border = .all(0),
                .min_size_content = dvui.Font.theme(.body).sizeM(1, 1),
                .max_size_content = .size(dvui.Font.theme(.body).sizeM(200, 1)),
            });

            if (refresh_items) {
                te.textSet(std.mem.sliceTo(&li.name, 0), false);
            }

            if (new_item and i == list.list.items.len - 1) {
                dvui.focusWidget(te.data().id, null, null);
            }

            var save = false;
            const focused = dvui.dataGetPtrDefault(null, te.data().id, "focused", bool, false);
            if (te.data().id == dvui.focusedWidgetId()) {
                if (!focused.*) {
                    // just gained focus, move cursor to end
                    te.textLayout.selection.moveCursor(std.math.maxInt(usize), false);
                }
                focused.* = true;
            } else if (focused.*) {
                focused.* = false;
                // we were focused and lost it
                save = true;
            }

            if (te.enter_pressed) save = true;

            if (save) {
                const time = std.Io.Clock.real.now(dvui.io).nanoseconds;
                li.updateName(time, te.textGet());
            }
            te.deinit();

            _ = dvui.ReorderWidget.draggable(@src(), .{ .reorderable = reorderable }, .{ .gravity_x = 1.0, .min_size_content = dvui.Size.all(30), .gravity_y = 0.5, .color_text = .gray });

            hbox.deinit();

            _ = dvui.separator(@src(), .{ .expand = .horizontal });

            reorderable.deinit();
        }

        if (reorder.finalSlot()) {
            insert_before_idx = last_index + 1;
        }

        if (insert_before_idx) |ibi| {
            if (removed_idx) |ri| {
                const time = std.Io.Clock.real.now(dvui.io).nanoseconds;
                if (ri > ibi) {
                    // we want to be before ibi, but reorder will move that down, so the slot we want is exactly ibi
                    list.reorder(time, ri, ibi);
                } else if (ri != ibi - 1) {
                    // ibi is not moving, so we want the slot before it
                    list.reorder(time, ri, ibi - 1);
                }
            }
        }

        vbox.deinit();
        reorder.deinit();

        dvui.label(@src(), "Got", .{}, .{});

        for (list.list.items, 0..) |*li, i| {
            if (li.status != .got) continue;

            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal });
            defer hbox.deinit();

            var temp: bool = true;
            if (dvui.checkbox(@src(), &temp, "", .{ .gravity_y = 0.5 })) {
                const time = std.Io.Clock.real.now(dvui.io).nanoseconds;
                li.updateStatus(time, .want);
            }

            dvui.label(@src(), "{s}", .{std.mem.sliceTo(&li.name, 0)}, .{ .color_text = .gray });
        }
    }

    return .ok;
}
