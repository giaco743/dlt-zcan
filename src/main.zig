const std = @import("std");
const builtin = @import("builtin");

const fmt = std.fmt;
const heap = std.heap;
const mem = std.mem;
const meta = std.meta;

const vaxis = @import("vaxis");

const log = std.log.scoped(.main);
pub const panic = vaxis.panic_handler;

const dlt = @import("dlt.zig");
const index = @import("index.zig");
const pretty = @import("pretty.zig");

const MAX_VISIBLE_ROWS = 64;
const ROW_BUF_SIZE = 4 * 1024;

const MIN_TEXT_FIELD_WIDTH = 30;
const TOGGLE_BOX_WIDTH = 15;

const normal: vaxis.Cell.Color = .default;
const errr: vaxis.Cell.Color = .{ .index = 1 };
const warn: vaxis.Cell.Color = .{ .index = 3 };
const fatal: vaxis.Cell.Color = .{ .index = 5 };

fn ToggleBox(comptime title: []const u8) type {
    return struct {
        toggled: bool,

        fn draw(
            self: *const @This(),
            x: u16,
            y: u16,
            width: u16,
            win: vaxis.Window,
        ) !void {
            drawTitleBox(title, win, x, y, width);

            const toggle_win = win.child(.{
                .x_off = x + 2,
                .y_off = y + 1,
                .width = width - 4,
                .height = 1,
            });

            if (self.toggled) {
                _ = toggle_win.printSegment(
                    .{
                        .text = "☑",
                    },
                    .{
                        .row_offset = y,
                        .col_offset = 0,
                    },
                );
            } else {
                _ = toggle_win.printSegment(
                    .{
                        .text = "☐",
                    },
                    .{
                        .row_offset = y,
                        .col_offset = 0,
                    },
                );
            }
        }
    };
}

const CachedRow = struct {
    idx: usize,
    msg: dlt.DltMessage,
};

const DltViewer = struct {
    file: []const u8,
    index: []const usize,
    rows: [MAX_VISIBLE_ROWS]CachedRow = undefined,
    row_count: usize = 0,
    rowbufs: [MAX_VISIBLE_ROWS][ROW_BUF_SIZE]u8 = undefined,
    filter: dlt.DltFilter = .{},
    at_end: bool = false,

    pub fn draw(self: *DltViewer, win: vaxis.Window) !void {
        const height: usize = @intCast(win.height);
        const visible = @min(height, MAX_VISIBLE_ROWS);

        // Fill the row cache if it is not full
        if (!self.at_end) {
            var start = if (self.row_count > 0) self.rows[self.row_count - 1].idx + 1 else 0;
            while (self.row_count < visible) {
                const cached_msg = try self.getNext(start) orelse {
                    self.at_end = true;
                    break;
                };
                start = cached_msg.idx + 1;
                self.rows[self.row_count] = cached_msg;
                self.row_count += 1;
            }
        }
        // Print all messages in the row buf
        var row_idx: usize = 0;
        while (row_idx < self.row_count) : (row_idx += 1) {
            try drawRow(
                win,
                @intCast(row_idx),
                self.rows[row_idx].msg,
                &self.rowbufs[row_idx],
            );
        }
    }
    fn drawRow(
        win: vaxis.Window,
        y: u16,
        msg: dlt.DltMessage,
        outbuf: []u8,
    ) !void {
        const row = try pretty.printMessage(msg, outbuf[0..]);

        const bg = if (msg.level) |lvl| switch (lvl) {
            .fatal => fatal,
            .err => errr,
            .warn => warn,
            else => normal,
        } else normal;
        _ = win.printSegment(
            .{
                .text = row,
                .style = .{ .bg = bg },
            },
            .{
                .row_offset = y,
                .col_offset = 0,
            },
        );
    }
    // Scroll down looks for the first next message, that matche the filter
    // and copies the rest forward
    fn scrollDown(self: *DltViewer) !void {
        if (self.row_count == 0)
            return;
        const start = self.rows[self.row_count - 1].idx + 1;
        if (start < self.index.len) {
            std.mem.copyForwards(CachedRow, self.rows[0 .. self.row_count - 1], self.rows[1..self.row_count]);
            if (try self.getNext(start)) |next| {
                self.rows[self.row_count - 1] = next;
            } else self.row_count -= 1;
        }
    }
    fn scrollUp(self: *DltViewer) !void {
        const start = self.rows[self.row_count - 1].idx;
        if (start > 0) {
            if (try self.getPrev(start)) |prev| {
                std.mem.copyBackwards(CachedRow, self.rows[1..self.row_count], self.rows[0 .. self.row_count - 1]);
                self.rows[0] = prev;
            }
        }
    }
    fn getNext(self: *DltViewer, start: usize) !?CachedRow {
        var idx = start;
        while (idx < self.index.len) : (idx += 1) {
            const msg =
                try dlt.DltMessage.init(self.file[self.index[idx] + dlt.STORAGE_HEADER_SIZE ..]);

            if (try msg.matches(self.filter)) {
                return .{ .idx = idx, .msg = msg };
            }
        }
        return null;
    }
    fn getPrev(self: *DltViewer, start: usize) !?CachedRow {
        var idx = start;
        while (idx > 0) : (idx -= 1) {
            const msg =
                try dlt.DltMessage.init(self.file[self.index[idx] + dlt.STORAGE_HEADER_SIZE ..]);

            if (try msg.matches(self.filter)) {
                return .{ .idx = idx, .msg = msg };
            }
        }
        return null;
    }
    fn clear(self: *DltViewer) void {
        self.rows = undefined;
        self.rowbufs = undefined;
        self.row_count = 0;
        self.at_end = false;
    }
};

const Focus = enum {
    ecu,
    app,
    ctx,
    from,
    until,
    subs,
    table,
};

fn drawTitleBox(
    comptime title: []const u8,
    win: vaxis.Window,
    x: u16,
    y: u16,
    width: u16,
) void {
    if (width < title.len + 6)
        return;

    // Top border
    _ = win.printSegment(
        .{ .text = "┌" },
        .{ .row_offset = y, .col_offset = x },
    );

    _ = win.printSegment(
        .{ .text = "─ " },
        .{ .row_offset = y, .col_offset = x + 1 },
    );

    _ = win.printSegment(
        .{ .text = title },
        .{ .row_offset = y, .col_offset = x + 3 },
    );

    // Padding after title.
    const used = title.len + 4;
    const padding = width - used - 1;

    var col = x + 3 + @as(u16, @intCast(title.len));

    _ = win.printSegment(
        .{ .text = " " },
        .{ .row_offset = y, .col_offset = col },
    );
    col += 1;

    var i: u16 = 0;
    while (i < padding) : (i += 1) {
        _ = win.printSegment(
            .{ .text = "─" },
            .{ .row_offset = y, .col_offset = col },
        );
        col += 1;
    }

    _ = win.printSegment(
        .{ .text = "┐" },
        .{ .row_offset = y, .col_offset = x + width - 1 },
    );

    // Bottom border
    _ = win.printSegment(
        .{ .text = "└" },
        .{ .row_offset = y + 2, .col_offset = x },
    );

    var bottom_col = x + 1;
    while (bottom_col < x + width - 1) : (bottom_col += 1) {
        _ = win.printSegment(
            .{ .text = "─" },
            .{ .row_offset = y + 2, .col_offset = bottom_col },
        );
    }

    _ = win.printSegment(
        .{ .text = "┘" },
        .{ .row_offset = y + 2, .col_offset = x + width - 1 },
    );

    // Vertical sides
    _ = win.printSegment(
        .{ .text = "│" },
        .{ .row_offset = y + 1, .col_offset = x },
    );

    _ = win.printSegment(
        .{ .text = "│" },
        .{ .row_offset = y + 1, .col_offset = x + width - 1 },
    );
}

fn drawInputBox(
    comptime title: []const u8,
    win: vaxis.Window,
    input: *vaxis.widgets.TextInput,
    x: u16,
    y: u16,
    width: u16,
    style: vaxis.Cell.Style,
) void {
    drawTitleBox(title, win, x, y, width);

    const input_win = win.child(.{
        .x_off = x + 2,
        .y_off = y + 1,
        .width = width - 3,
        .height = 1,
    });

    input.drawWithStyle(input_win, style);
}

pub fn dltIdFromTextInput(self: *const vaxis.widgets.TextInput.Buffer, out: []u8) !?[]const u8 {
    const first = self.firstHalf();
    const second = self.secondHalf();
    if (first.len + second.len == 0) return null else if (first.len + second.len > out.len) return error.OutOfBounds;

    @memcpy(out[0..first.len], first);
    @memcpy(out[first.len .. first.len + second.len], second);
    return out[0..];
}

pub fn dltStringFromTextInput(self: *const vaxis.widgets.TextInput.Buffer, out: []u8) !?[]const u8 {
    const first = self.firstHalf();
    const second = self.secondHalf();
    if (first.len + second.len == 0) return null else if (first.len + second.len > out.len) return error.OutOfBounds;

    @memcpy(out[0..first.len], first);
    @memcpy(out[first.len .. first.len + second.len], second);
    return out[0 .. first.len + second.len];
}

pub fn dltTimestampFromTextInput(self: *const vaxis.widgets.TextInput.Buffer, out: []u8) !?u32 {
    const first = self.firstHalf();
    const second = self.secondHalf();
    if (first.len + second.len == 0) return null else if (first.len + second.len > 13) return error.OutOfBounds;

    @memcpy(out[0..first.len], first);
    @memcpy(out[first.len .. first.len + second.len], second);
    var it = std.mem.splitScalar(u8, out, ':');
    const h = try std.fmt.parseInt(u32, it.next() orelse return error.MissingHour, 10);
    const m = try std.fmt.parseInt(u32, it.next() orelse return error.MissingMinutes, 10);
    const s = try std.fmt.parseFloat(f32, it.next() orelse return error.MissingSeconds);
    return h * 36_000_000 + m * 600_000 + @as(u32, @intFromFloat(s * 10_000));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.gpa;

    var it = try init.minimal.args.iterateAllocator(init.gpa);
    defer it.deinit();
    _ = it.next() orelse {
        return error.MissingProgramName;
    };
    var path: ?[]const u8 = null;
    if ((it.next())) |arg|
        path = arg
    else
        return error.MultiplePaths;

    var file = try std.Io.Dir.cwd().openFile(io, path orelse return error.MissingPath, .{});
    defer file.close(io);

    var mmap = try file.createMemoryMap(
        io,
        .{
            .len = try file.length(io),
            .protection = .{ .read = true },
        },
    );
    defer mmap.destroy(io);

    const allocator = init.arena.allocator();
    const dlt_index = try index.index(mmap.memory, allocator);
    defer allocator.free(dlt_index);

    try std.posix.madvise(
        mmap.memory.ptr,
        mmap.memory.len,
        std.posix.MADV.DONTNEED,
    );

    var viewer = DltViewer{ .file = mmap.memory, .index = dlt_index, .filter = .{} };

    var buffer: [1024]u8 = undefined;
    var tty: vaxis.Tty = try .init(io, &buffer);
    defer tty.deinit();
    const tty_writer = tty.writer();
    var vx = try vaxis.init(io, alloc, init.environ_map, .{
        .kitty_keyboard_flags = .{ .report_events = true },
    });
    defer vx.deinit(alloc, tty.writer());

    var loop: vaxis.Loop(union(enum) {
        key_press: vaxis.Key,
        winsize: vaxis.Winsize,
    }) = .init(io, &tty, &vx);
    try loop.installResizeHandler();
    try loop.start();
    defer loop.stop();
    try vx.enterAltScreen(tty_writer);
    try tty_writer.flush();

    var ecuout = [_]u8{0} ** 4;
    var ecu_input_style: vaxis.Cell.Style = .{};
    var ecu_input = vaxis.widgets.TextInput.init(alloc);
    defer ecu_input.deinit();
    var appout = [_]u8{0} ** 4;
    var app_input_style: vaxis.Cell.Style = .{};
    var app_input = vaxis.widgets.TextInput.init(alloc);
    defer app_input.deinit();
    var ctxout = [_]u8{0} ** 4;
    var ctx_input_style: vaxis.Cell.Style = .{};
    var ctx_input = vaxis.widgets.TextInput.init(alloc);
    defer ctx_input.deinit();
    var fromout = [_]u8{0} ** 13;
    var from_input_style: vaxis.Cell.Style = .{};
    var from_input = vaxis.widgets.TextInput.init(alloc);
    defer from_input.deinit();
    var untilout = [_]u8{0} ** 13;
    var until_input_style: vaxis.Cell.Style = .{};
    var until_input = vaxis.widgets.TextInput.init(alloc);
    defer until_input.deinit();
    var subsout = [_]u8{0} ** 128;
    var subs_input_style: vaxis.Cell.Style = .{};
    var subs_input = vaxis.widgets.TextInput.init(alloc);
    defer subs_input.deinit();

    var fatal_box = ToggleBox("Fatal"){ .toggled = true };
    var error_box = ToggleBox("Error"){ .toggled = true };
    var warn_box = ToggleBox("Warn"){ .toggled = true };
    var info_box = ToggleBox("Info"){ .toggled = true };
    var debug_box = ToggleBox("Debug"){ .toggled = false };

    try vx.setMouseMode(tty_writer, true);

    try tty_writer.flush();

    try vx.queryTerminal(
        tty_writer,
        .fromMilliseconds(250),
    );
    try tty_writer.flush();

    // Wait for the initial terminal size.
    while (true) {
        const event = try loop.nextEvent();

        switch (event) {
            .winsize => |ws| {
                try vx.resize(alloc, tty_writer, ws);
                break;
            },
            else => continue,
        }
    }

    var focus: Focus = .table;

    while (true) {
        const win = vx.window();
        win.clear();

        const style: vaxis.Style = .{
            .fg = .{ .index = 0 },
        };
        const hdr_width: ?u16 = if (win.height < 6)
            null
        else if (win.width >= 3 * MIN_TEXT_FIELD_WIDTH + 5 * TOGGLE_BOX_WIDTH)
            (win.width - 5 * TOGGLE_BOX_WIDTH) / 3
        else if (win.width >= 3 * MIN_TEXT_FIELD_WIDTH)
            win.width / 3
        else
            null;
        if (hdr_width) |width| {
            // Text fields
            drawInputBox("ECU ID", win, &ecu_input, 0, 0, width, ecu_input_style);
            drawInputBox("APP ID", win, &app_input, width, 0, width, app_input_style);
            drawInputBox("CTX ID", win, &ctx_input, 2 * width, 0, width, ctx_input_style);
            drawInputBox("From", win, &from_input, 0, 3, width, from_input_style);
            drawInputBox("Until", win, &until_input, width, 3, width, until_input_style);
            drawInputBox("Substring", win, &subs_input, 2 * width, 3, width, subs_input_style);

            // Put the cursor where the focused input wants it.
            switch (focus) {
                .ecu => win.showCursor(
                    0 + 2 + ecu_input.prev_cursor_col,
                    1,
                ),
                .app => win.showCursor(
                    width + 2 + app_input.prev_cursor_col,
                    1,
                ),
                .ctx => win.showCursor(
                    2 * width + 2 + ctx_input.prev_cursor_col,
                    1,
                ),
                .from => win.showCursor(
                    0 + 2 + from_input.prev_cursor_col,
                    4,
                ),
                .until => win.showCursor(
                    width + 2 + until_input.prev_cursor_col,
                    4,
                ),
                .subs => win.showCursor(
                    2 * width + 2 + subs_input.prev_cursor_col,
                    4,
                ),
                .table => win.hideCursor(),
            }

            // Toggle boxes
            if (win.width >= 3 * MIN_TEXT_FIELD_WIDTH + 5 * TOGGLE_BOX_WIDTH) {
                try fatal_box.draw(3 * width, 0, TOGGLE_BOX_WIDTH, win);
                try error_box.draw(3 * width + TOGGLE_BOX_WIDTH, 0, TOGGLE_BOX_WIDTH, win);
                try warn_box.draw(3 * width + 2 * TOGGLE_BOX_WIDTH, 0, TOGGLE_BOX_WIDTH, win);
                try info_box.draw(3 * width + 3 * TOGGLE_BOX_WIDTH, 0, TOGGLE_BOX_WIDTH, win);
                try debug_box.draw(3 * width + 4 * TOGGLE_BOX_WIDTH, 0, TOGGLE_BOX_WIDTH, win);

                drawInputBox("Substring", win, &subs_input, 2 * width, 3, width + 5 * TOGGLE_BOX_WIDTH, subs_input_style);
            } else drawInputBox("Substring", win, &subs_input, 2 * width, 3, width, subs_input_style);
        }

        const y_offset_table: u16 = if (hdr_width == null) 0 else 6;
        const tbl = win.child(.{
            .x_off = 0,
            .y_off = y_offset_table,
            .width = win.width,
            .height = win.height - y_offset_table,
            .border = .{
                .where = .all,
                .style = style,
            },
        });
        viewer.filter.fatal = fatal_box.toggled;
        viewer.filter.err = error_box.toggled;
        viewer.filter.warn = warn_box.toggled;
        viewer.filter.info = info_box.toggled;
        viewer.filter.debug = debug_box.toggled;
        try viewer.draw(tbl);

        try vx.render(tty_writer);
        try tty_writer.flush();

        const event = try loop.nextEvent();

        switch (event) {
            .key_press => |key| {
                if (key.matches('e', .{ .ctrl = true })) {
                    focus = .ecu;
                }
                if (key.matches('a', .{ .ctrl = true })) {
                    focus = .app;
                }
                if (key.matches('k', .{ .ctrl = true })) {
                    focus = .ctx;
                }
                if (key.matches('f', .{ .ctrl = true })) {
                    focus = .from;
                }
                if (key.matches('u', .{ .ctrl = true })) {
                    focus = .until;
                }
                if (key.matches('s', .{ .ctrl = true })) {
                    focus = .subs;
                }
                if (key.matches('t', .{ .ctrl = true })) {
                    focus = .table;
                }
                if (key.matches('c', .{ .ctrl = true })) {
                    break;
                }
                if (key.matches('f', .{ .alt = true })) {
                    fatal_box.toggled = !fatal_box.toggled;
                    viewer.clear();
                }
                if (key.matches('e', .{ .alt = true })) {
                    error_box.toggled = !error_box.toggled;
                    viewer.clear();
                }
                if (key.matches('w', .{ .alt = true })) {
                    warn_box.toggled = !warn_box.toggled;
                    viewer.clear();
                }
                if (key.matches('i', .{ .alt = true })) {
                    info_box.toggled = !info_box.toggled;
                    viewer.clear();
                }
                if (key.matches('d', .{ .alt = true })) {
                    debug_box.toggled = !debug_box.toggled;
                    viewer.clear();
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    switch (focus) {
                        .ecu => {
                            ecuout = [_]u8{0} ** 4;
                            if (dltIdFromTextInput(&ecu_input.buf, &ecuout)) |id| {
                                ecu_input_style = .{ .fg = .default };
                                viewer.filter.ecuid = id;
                                viewer.clear();
                            } else |_| {
                                ecu_input_style = .{ .fg = .{ .index = 1 } };
                            }
                        },
                        .app => {
                            appout = [_]u8{0} ** 4;
                            if (dltIdFromTextInput(&app_input.buf, &appout)) |id| {
                                app_input_style = .{ .fg = .default };
                                viewer.filter.apid = id;
                                viewer.clear();
                            } else |_| {
                                app_input_style = .{ .fg = .{ .index = 1 } };
                            }
                        },
                        .ctx => {
                            ctxout = [_]u8{0} ** 4;
                            if (dltIdFromTextInput(&ctx_input.buf, &ctxout)) |id| {
                                ctx_input_style = .{ .fg = .default };
                                viewer.filter.ctid = id;
                                viewer.clear();
                            } else |_| {
                                ctx_input_style = .{ .fg = .{ .index = 1 } };
                            }
                        },
                        .from => {
                            fromout = [_]u8{0} ** 13;
                            if (dltTimestampFromTextInput(&from_input.buf, &fromout)) |from| {
                                from_input_style = .{ .fg = .default };
                                viewer.filter.from = from;
                                viewer.clear();
                            } else |_| {
                                from_input_style = .{ .fg = .{ .index = 1 } };
                            }
                        },
                        .until => {
                            untilout = [_]u8{0} ** 13;
                            if (dltTimestampFromTextInput(&until_input.buf, &untilout)) |until| {
                                until_input_style = .{ .fg = .default };
                                viewer.filter.until = until;
                                viewer.clear();
                            } else |_| {
                                until_input_style = .{ .fg = .{ .index = 1 } };
                            }
                        },
                        .subs => {
                            subsout = [_]u8{0} ** 128;
                            if (dltStringFromTextInput(&subs_input.buf, &subsout)) |subs| {
                                subs_input_style = .{ .fg = .default };
                                viewer.filter.substring = subs;
                                viewer.clear();
                            } else |_| {
                                subs_input_style = .{ .fg = .{ .index = 1 } };
                            }
                        },
                        .table => {},
                    }
                } else {
                    // Send key to currently focused input
                    switch (focus) {
                        .ecu => {
                            try ecu_input.update(.{ .key_press = key });
                        },
                        .app => {
                            try app_input.update(.{ .key_press = key });
                        },
                        .ctx => {
                            try ctx_input.update(.{ .key_press = key });
                        },
                        .from => {
                            try from_input.update(.{ .key_press = key });
                        },
                        .until => {
                            try until_input.update(.{ .key_press = key });
                        },

                        .subs => {
                            try subs_input.update(.{ .key_press = key });
                        },
                        .table => {
                            if (key.matches(vaxis.Key.down, .{}))
                                try viewer.scrollDown();

                            if (key.matches(vaxis.Key.up, .{}))
                                try viewer.scrollUp();
                        },
                    }
                }
            },
            .winsize => |ws| {
                try vx.resize(alloc, tty_writer, ws);
            },
        }
    }
}
