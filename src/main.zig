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
    list.deinit(win.gpa);
}

pub fn global_pinch_zoom() void {
    const uniqueId = dvui.parentGet().extendId(@src(), 0);
    const scale_gesture = dvui.dataGetPtrDefault(null, uniqueId, "scale_gesture", f32, 1.0);

    const evts = dvui.events();
    for (evts) |*e| {
        // only thing we care about now is if someone else already handled it
        if (!e.handled and e.evt == .mouse) {
            if (e.evt.mouse.action == .pinch_begin) {
                scale_gesture.* = dvui.currentWindow().content_scale;
            } else if (e.evt.mouse.action == .pinch_update) {
                dvui.currentWindow().content_scale = scale_gesture.* * e.evt.mouse.action.pinch_update;
            }
        }
    }
}

const LOAD_ID = 123;

// Run each frame to do normal UI
pub fn appFrame() !dvui.App.Result {
    {
        var new_item = false;
        var refresh_items = false;
        var items_visible = false;

        if (dvui.backend.kind == .web) {
            // check outstanding fetches
            if (dvui.backend.wasm.wasm_fetch_completed(LOAD_ID) > 0) {
                const size = dvui.backend.wasm.wasm_fetch_completed_body_size(LOAD_ID);
                const data = try gpa.alloc(u8, size);
                defer gpa.free(data);
                dvui.backend.wasm.wasm_fetch_completed_body(LOAD_ID, data.ptr);
                std.log.debug("wasm fetch complete: {s}", .{data});

                var r: std.Io.Reader = .fixed(data);
                var loaded = List.load(gpa, &r);
                defer loaded.deinit(gpa);

                const time = std.Io.Clock.real.now(dvui.io).nanoseconds;
                list.merge(gpa, time, &loaded);
            }
        }

        {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hbox.deinit();

            if (dvui.button(@src(), "Debug", .{}, .{})) {
                dvui.toggleDebugWindow();
            }

            if (dvui.button(@src(), "Load", .{}, .{})) blk: {
                const url = "http://localhost:8111/list.txt";
                if (dvui.backend.kind == .web) {
                    const body = "";
                    dvui.backend.wasm.wasm_fetch(LOAD_ID, url.ptr, url.len, body.ptr, body.len);
                } else {
                    var client: std.http.Client = .{
                        .allocator = gpa,
                        .io = dvui.io,
                    };
                    defer client.deinit();

                    var result_body = std.Io.Writer.Allocating.init(gpa);
                    defer result_body.deinit();

                    const response = client.fetch(.{ .location = .{ .url = url }, .response_writer = &result_body.writer }) catch |err| {
                        std.log.err("Failed to fetch list: {any}", .{err});
                        break :blk;
                    };

                    _ = response;

                    var r: std.Io.Reader = .fixed(result_body.written());
                    var loaded = List.load(gpa, &r);
                    defer loaded.deinit(gpa);

                    const time = std.Io.Clock.real.now(dvui.io).nanoseconds;
                    list.merge(gpa, time, &loaded);
                }
                refresh_items = true;
            }

            if (dvui.button(@src(), "Save", .{}, .{})) {
                std.log.debug("List:\n{f}", .{list});

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
                    std.log.debug("reorder {d}", .{i});
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

            items_visible = true;
            last_index = i;

            var reorderable = reorder.reorderable(@src(), .{}, .{ .id_extra = li.id, .expand = .horizontal });
            defer reorderable.deinit();

            var anim = dvui.animate(@src(), .{ .kind = .vertical, .duration = if (reorderable.floating()) 0 else 300_000 }, .{ .expand = .both });
            defer anim.deinit();

            if (reorderable.removed()) {
                removed_idx = i; // this entry is being dragged
            } else if (reorderable.insertBefore()) {
                insert_before_idx = i; // this entry was dropped onto
            }

            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 8 } });

            var temp: bool = false;
            if (dvui.checkbox(@src(), &temp, "", .{ .gravity_y = 0.5 })) {
                anim.startEnd();
            }

            if (anim.end()) {
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

        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        for (list.list.items, 0..) |*li, i| {
            if (li.status != .got) continue;

            items_visible = true;

            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal, .padding = .{ .x = 8 } });
            defer hbox.deinit();

            var temp: bool = true;
            if (dvui.checkbox(@src(), &temp, "", .{ .gravity_y = 0.5 })) {
                const time = std.Io.Clock.real.now(dvui.io).nanoseconds;
                li.updateStatus(time, .want);
            }

            _ = dvui.spacer(@src(), .{ .padding = .{ .x = 4 } });

            dvui.label(@src(), "{s}", .{std.mem.sliceTo(&li.name, 0)}, .{ .color_text = .gray });
        }

        if (!items_visible) {
            dvui.label(@src(), "-- No Items --", .{}, .{ .gravity_x = 0.5 });
        }
    }

    global_pinch_zoom();

    return .ok;
}
