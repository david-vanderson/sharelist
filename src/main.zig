const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const List = @import("list.zig");

var list: List = .empty;
var tag_id: u32 = 0;
var editing_tags: bool = false;
var last_sync: i128 = 0;

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
            .org = "dvui",
            .app = "ShareList",
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
    win.content_scale = 1.2;
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

fn time() i128 {
    return dvui.realTime();
}

fn callAfterDelete(id: dvui.Id, response: dvui.enums.DialogResponse) !void {
    const item_id = dvui.dataGet(null, id, "id", u32) orelse return;
    switch (response) {
        else => return,
        .ok => {
            for (list.stuff.items) |*li| {
                if (li.id == item_id) {
                    li.updateStatus(time(), .history);
                    last_sync = 0;
                    break;
                }
            }
        },
    }
}

fn sync() !void {
    last_sync = time();
    dvui.toast(@src(), .{ .message = "Sync", .timeout = 1_000_000 });

    const payload = try std.fmt.allocPrint(gpa, "{f}", .{list});
    defer gpa.free(payload);

    if (dvui.backend.kind == .web) {
        const url = std.mem.sliceTo(dvui.backend.wasm.wasm_url(), 0);
        const uri = try std.Uri.parseAfterScheme("http", url);

        if (uri.query == null) {
            std.log.err("query null", .{});
            return;
        }
        var query_buf: [100]u8 = undefined;
        const query = uri.query.?.toRaw(&query_buf) catch return error.query_to_raw;

        var list_id: ?u32 = null;

        var it = std.mem.tokenizeScalar(u8, query, '&');
        while (it.next()) |q| {
            if (std.mem.startsWith(u8, q, "id")) {
                if (q.len != 11) {
                    std.log.err("query bad: id bad", .{});
                    return;
                }
                list_id = try std.fmt.parseInt(u32, q[3..], 16);
            }
        }

        if (list_id == null) {
            std.log.err("query bad: no id", .{});
            return;
        }
        std.log.debug("id is {any}", .{list_id});

        var target_buf: [100]u8 = undefined;
        const target = try std.fmt.bufPrint(&target_buf, "/sharelist/list?id={x}", .{list_id.?});
        const status = dvui.backend.wasm.wasm_fetch_status(LOAD_ID);
        if (status < 0) {
            std.log.warn("wasm_fetch already in flight: {d}", .{status});
        } else {
            dvui.backend.wasm.wasm_fetch(LOAD_ID, target.ptr, target.len, payload.ptr, payload.len);
        }
    } else {
        var url: ?[]const u8 = null;
        var args = try dvui.App.main_init.?.minimal.args.iterateAllocator(dvui.currentWindow().arena());
        defer args.deinit();
        var arg_idx: usize = 0;
        while (args.next()) |arg| {
            std.log.debug("arg: {s}", .{arg});
            if (arg_idx == 1) {
                url = arg;
                break;
            }
            arg_idx += 1;
        }

        if (url == null) {
            std.log.err("Failed to get url arg", .{});
        }

        var client: std.http.Client = .{
            .allocator = gpa,
            .io = dvui.io,
        };
        defer client.deinit();

        var result_body = std.Io.Writer.Allocating.init(gpa);
        defer result_body.deinit();

        _ = client.fetch(.{ .location = .{ .url = url.? }, .payload = payload, .response_writer = &result_body.writer }) catch |err| {
            std.log.err("Failed to post list: {any}", .{err});
            return;
        };

        var r: std.Io.Reader = .fixed(result_body.written());
        var loaded = List.load(gpa, &r) catch |err| blk: {
            std.log.err("Failed to load list: {any}", .{err});
            break :blk List.empty;
        };
        defer loaded.deinit(gpa);

        list.merge(gpa, time(), &loaded);
        dvui.currentWindow().title(std.mem.sliceTo(&list.name, 0));
    }
}

// Run each frame to do normal UI
pub fn appFrame() !dvui.App.Result {
    const new_item = false;
    var refresh_items = false;
    var items_visible = false;
    var changed = false;

    if (dvui.backend.kind == .web) {
        // check outstanding fetches
        const status = dvui.backend.wasm.wasm_fetch_status(LOAD_ID);
        if (status > 0) {
            const size = dvui.backend.wasm.wasm_fetch_body_size(LOAD_ID);
            var data: []u8 = "";
            defer if (size > 0) gpa.free(data);
            if (size > 0) {
                data = try gpa.alloc(u8, size);
                dvui.backend.wasm.wasm_fetch_body(LOAD_ID, data.ptr);
            }

            var r: std.Io.Reader = .fixed(data);
            var loaded = List.load(gpa, &r) catch |err| blk: {
                std.log.err("Failed to load list: {any}", .{err});
                dvui.toast(@src(), .{ .message = "Sync Version Mismatch\nRefresh", .timeout = 5_000_000 });
                break :blk .empty;
            };
            defer loaded.deinit(gpa);

            list.merge(gpa, time(), &loaded);
            dvui.currentWindow().title(std.mem.sliceTo(&list.name, 0));
            refresh_items = true;

            std.log.debug("wasm fetch complete ({d}): {s}", .{ status, data });
        }
    }

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = true, .style = .window });
        defer hbox.deinit();

        {
            var selected_idx: ?usize = null;
            var num_tags: usize = 0;
            for (list.stuff.items) |*li| {
                if (li.id == tag_id) {
                    selected_idx = num_tags;
                }
                if (li.status == .tag) {
                    num_tags += 1;
                }
            }

            if (selected_idx == null) {
                if (editing_tags) {
                    selected_idx = num_tags + 1;
                } else {
                    selected_idx = num_tags;
                }
            }

            var dd: dvui.DropdownWidget = undefined;
            dd.init(@src(), .{ .selected_index = selected_idx }, .{});
            defer dd.deinit();

            var hbox2 = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
            if (editing_tags) {
                dvui.label(@src(), "Editing Tags", .{}, .{ .gravity_y = 0.5, .padding = .{} });
            } else if (tag_id == 0) {
                dvui.label(@src(), "All", .{}, .{ .gravity_y = 0.5, .padding = .{} });
            } else {
                for (list.stuff.items) |*li| {
                    if (li.id == tag_id) {
                        const name = std.mem.sliceTo(&li.name, 0);
                        dvui.label(@src(), "{s}", .{name}, .{ .gravity_y = 0.5, .padding = .{} });
                        break;
                    }
                }
            }
            dvui.icon(
                @src(),
                "dropdown_triangle",
                dvui.entypo.chevron_small_down,
                .{},
                .{ .gravity_y = 0.5, .role = .none },
            );
            hbox2.deinit();

            if (dd.dropped()) {
                for (list.stuff.items) |*li| {
                    if (li.status == .tag) {
                        const name = std.mem.sliceTo(&li.name, 0);
                        if (dd.addChoiceLabel(name)) {
                            tag_id = li.id;
                            editing_tags = false;
                        }
                    }
                }

                if (dd.addChoiceLabel("All")) {
                    tag_id = 0;
                    editing_tags = false;
                }

                if (dd.addChoiceLabel("[Edit Tags]")) {
                    tag_id = 0;
                    editing_tags = true;
                }
            }
        }

        _ = dvui.spacer(@src(), .{ .expand = .horizontal });

        if (dvui.button(@src(), "Sync", .{}, .{ .gravity_x = 1.0 })) {
            try sync();
            refresh_items = true;
        }

        if ((time() - last_sync) > 5 * std.time.ns_per_min) {
            try sync();
            refresh_items = true;
        }

        if (dvui.button(@src(), "Debug", .{}, .{ .gravity_x = 1.0 })) {
            dvui.toggleDebugWindow();
        }

        if (dvui.backend.kind == .web) {
            const status = dvui.backend.wasm.wasm_fetch_status(LOAD_ID);
            if (status < 0) {
                dvui.refresh(null, @src(), null);
                dvui.icon(@src(), "sync", dvui.entypo.cycle, .{}, .{
                    .expand = .ratio,
                    .rotation = -std.math.pi * @as(f32, @floatFromInt(@mod(@divFloor(dvui.frameTimeNS(), 1_000_000), 1000))) / 1000,
                });
            }
        }

        //if (dvui.button(@src(), "Test", .{}, .{})) {
        //    for (0..100) |i| {
        //        std.log.debug("reorder {d}", .{i});
        //        list.reorder(time(), 0, 1);
        //    }
        //}
    }

    if (editing_tags) {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = true, .style = .window });
        defer hbox.deinit();

        dvui.label(@src(), "List Name", .{}, .{ .gravity_y = 0.5 });

        var te = dvui.textEntry(@src(), .{
            .text = .{ .internal = .{ .limit = List.NAME_MAX_LEN } },
            .text_initial = std.mem.sliceTo(&list.name, 0),
        }, .{ .expand = .horizontal });
        defer te.deinit();

        if (refresh_items) {
            te.textSet(std.mem.sliceTo(&list.name, 0), false);
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
            if (!std.mem.eql(u8, te.textGet(), std.mem.sliceTo(&list.name, 0))) {
                list.updateName(time(), te.textGet());
                changed = true;
                dvui.currentWindow().title(std.mem.sliceTo(&list.name, 0));
            }
        }
    }

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer hbox.deinit();

        //if (dvui.buttonIcon(@src(), "plus", dvui.entypo.plus, .{}, .{}, .{ .expand = .ratio })) {
        //    std.log.debug("plus time {d}", .{time()});
        //    const item = List.Item.new(time(), "New Item");
        //    list.append(gpa, time(), item);
        //    new_item = true;
        //}

        var te: dvui.TextEntryWidget = undefined;
        te.init(@src(), .{}, .{ .expand = .horizontal });

        var sug = dvui.suggestion(&te, .{ .open_on_text_change = true });

        var make_new = false;
        if (sug.dropped()) {
            if (sug.addChoiceLabel(te.textGet())) {
                make_new = true;
            }
            if (sug.addChoiceLabel("[close]")) {
                sug.close();
            }
            var matches: std.ArrayList(*List.Item) = .empty;
            for (list.stuff.items) |*li| {
                if (li.status == .tag) continue;
                if (std.ascii.startsWithIgnoreCase(&li.name, te.textGet())) {
                    matches.append(dvui.currentWindow().arena(), li) catch {};
                }
            }
            std.mem.sortUnstable(*List.Item, matches.items, {}, (struct {
                fn lessThan(_: void, lhs: *List.Item, rhs: *List.Item) bool {
                    if (lhs.last_write > rhs.last_write) return true;
                    return false;
                }
            }).lessThan);

            for (matches.items) |lip| {
                if (sug.addChoiceLabel(std.mem.sliceTo(&lip.name, 0))) {
                    if (editing_tags) {
                        lip.updateStatus(time(), .tag);
                        changed = true;
                    } else {
                        lip.updateStatus(time(), .want);
                        lip.updateTag(time(), tag_id);
                        changed = true;
                    }

                    te.textSet("", false);
                    break;
                }
            }
        }

        sug.deinit();

        if (te.enter_pressed) make_new = true;

        if (make_new) {
            const item = List.Item.new(time(), if (editing_tags) .tag else .want, tag_id, te.textGet());
            list.append(gpa, time(), item);
            changed = true;
            te.textSet("", false);
        }

        // suggestion forwards events to textEntry, so don't call te.processEvents()
        te.draw();
        te.deinit();
    }

    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both, .style = .window });
    defer scroll.deinit();

    var removed_idx: ?usize = null;
    var insert_before_idx: ?usize = null;
    var reorder = dvui.reorder(@src(), .{}, .{ .expand = .horizontal });
    var vbox = dvui.box(@src(), .{}, .{ .expand = .horizontal });

    var last_index: usize = 0;
    for (list.stuff.items, 0..) |*li, i| {
        if (editing_tags) {
            if (li.status != .tag) continue;
        } else {
            if (li.status != .want) continue;
            if (tag_id != 0 and li.tag != tag_id) continue;
        }

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

        if (editing_tags) {
            if (dvui.buttonIcon(
                @src(),
                "trash",
                dvui.entypo.trash,
                .{},
                .{},
                .{ .gravity_y = 0.5 },
            )) {
                const msg = std.fmt.allocPrint(dvui.currentWindow().arena(), "Delete \'{s}\'?", .{std.mem.sliceTo(&li.name, 0)}) catch "Delete?";
                dvui.dialog(@src(), .{ .id = li.id }, .{ .title = "Delete Tag?", .message = msg, .callafterFn = callAfterDelete, .cancel_label = "Cancel", .default = .cancel });
            }
        } else {
            var temp: bool = false;
            if (dvui.checkbox(@src(), &temp, null, .{ .gravity_y = 0.5 })) {
                anim.startEnd();
            }

            if (anim.end()) {
                li.updateStatus(time(), if (editing_tags) .history else .got);
                changed = true;
            }
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

        if (new_item and i == list.stuff.items.len - 1) {
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
            if (!std.mem.eql(u8, te.textGet(), std.mem.sliceTo(&li.name, 0))) {
                li.updateName(time(), te.textGet());
                changed = true;
            }
        }
        te.deinit();

        _ = dvui.ReorderWidget.draggable(@src(), .{ .reorderable = reorderable }, .{ .gravity_x = 1.0, .min_size_content = dvui.Size.all(30), .gravity_y = 0.5, .color_text = .gray });

        if (!editing_tags and tag_id == 0) {
            for (list.stuff.items) |*item| {
                if (li.tag == item.id) {
                    dvui.label(@src(), "{s}", .{std.mem.sliceTo(&item.name, 0)}, .{ .color_text = .gray, .gravity_x = 1.0, .font = dvui.Font.theme(.body).larger(-2) });
                    break;
                }
            }
        }

        hbox.deinit();

        _ = dvui.separator(@src(), .{ .expand = .horizontal });
    }

    if (reorder.finalSlot()) {
        insert_before_idx = last_index + 1;
    }

    if (insert_before_idx) |ibi| {
        if (removed_idx) |ri| {
            if (ri > ibi) {
                // we want to be before ibi, but reorder will move that down, so the slot we want is exactly ibi
                list.reorder(time(), ri, ibi);
            } else if (ri != ibi - 1) {
                // ibi is not moving, so we want the slot before it
                list.reorder(time(), ri, ibi - 1);
            }
        }
    }

    vbox.deinit();
    reorder.deinit();

    if (!editing_tags) {
        _ = dvui.separator(@src(), .{ .expand = .horizontal });

        var items_got = false;
        for (list.stuff.items, 0..) |*li, i| {
            if (li.status != .got) continue;
            if (tag_id != 0 and li.tag != tag_id) continue;

            items_visible = true;
            items_got = true;

            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .id_extra = i, .expand = .horizontal, .padding = .{ .x = 8 } });
            defer hbox.deinit();

            var temp: bool = true;
            if (dvui.checkbox(@src(), &temp, "", .{ .gravity_y = 0.5 })) {
                li.updateStatus(time(), .want);
                changed = true;
            }

            _ = dvui.spacer(@src(), .{ .padding = .{ .x = 4 } });

            dvui.label(@src(), "{s}", .{std.mem.sliceTo(&li.name, 0)}, .{ .color_text = .gray });
        }

        if (items_got) {
            if (dvui.button(@src(), "Clear Checked", .{}, .{ .gravity_x = 0.5 })) {
                for (list.stuff.items) |*li| {
                    if (li.status == .got) {
                        li.updateStatus(time(), .history);
                        changed = true;
                    }
                }
            }
        }

        if (!items_visible) {
            dvui.label(@src(), "-- No Items --", .{}, .{ .gravity_x = 0.5 });
        }
    }

    if (changed) try sync();

    global_pinch_zoom();

    return .ok;
}
