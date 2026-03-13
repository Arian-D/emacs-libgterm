//! emacs-libgterm: Terminal emulator for Emacs using libghostty-vt.
//!
//! This module implements an Emacs dynamic module that wraps ghostty-vt
//! (the terminal emulation library extracted from the Ghostty terminal
//! emulator). It provides:
//!
//!   - gterm-new: Create a new terminal instance
//!   - gterm-feed: Feed raw bytes (shell output) into the terminal
//!   - gterm-content: Read the terminal screen as a string
//!   - gterm-cursor-pos: Get the cursor position (row, col)
//!   - gterm-resize: Resize the terminal
//!   - gterm-free: Destroy a terminal instance
//!
//! The Elisp layer (gterm.el) handles PTY management, buffer display,
//! and keybinding, calling these primitives as needed.

const std = @import("std");
const emacs = @import("emacs_env.zig");
const ghostty_vt = @import("ghostty-vt");

/// Required by Emacs to verify GPL compatibility of dynamic modules.
export var plugin_is_GPL_compatible: c_int = 0;

const Terminal = ghostty_vt.Terminal;
const Allocator = std.mem.Allocator;

// We use the general purpose allocator since terminal instances are
// long-lived and few in number.
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator: Allocator = gpa.allocator();

// ── Terminal wrapper ────────────────────────────────────────────────────

const GtermInstance = struct {
    terminal: Terminal,
    rows: u16,
    cols: u16,

    pub fn init(cols: u16, rows: u16) !*GtermInstance {
        const self = try allocator.create(GtermInstance);
        self.* = .{
            .terminal = try .init(allocator, .{
                .cols = cols,
                .rows = rows,
            }),
            .rows = rows,
            .cols = cols,
        };
        return self;
    }

    pub fn deinit(self: *GtermInstance) void {
        self.terminal.deinit(allocator);
        allocator.destroy(self);
    }

    /// Feed raw bytes through the terminal's VT parser.
    pub fn feed(self: *GtermInstance, bytes: []const u8) void {
        var stream = self.terminal.vtStream();
        defer stream.deinit();
        stream.nextSlice(bytes);
    }

    /// Render the visible screen cell-by-cell into a buffer.
    /// Each terminal row becomes one line. Empty cells mid-line become
    /// spaces. Trailing empty cells per row are trimmed.
    pub fn renderContent(self: *GtermInstance) ![]const u8 {
        const screen = self.terminal.screens.active;
        const page_list = &screen.pages;
        const cols = self.cols;
        const rows = self.rows;

        // Pre-allocate: worst case ~4 bytes per cell (UTF-8) + newlines
        var buf: std.array_list.Managed(u8) = .init(allocator);
        errdefer buf.deinit();
        try buf.ensureTotalCapacity(@as(usize, cols) * rows * 4);

        var row: u16 = 0;
        while (row < rows) : (row += 1) {
            // Get a pin to the start of this row in the viewport
            const pin = page_list.pin(.{ .viewport = .{
                .x = 0,
                .y = row,
            } }) orelse continue;

            // Get the row's cells
            const page = &pin.node.data;
            const page_row = page.getRow(pin.y);
            const page_cells = page.getCells(page_row);

            // Find the last non-empty column (trim trailing empties)
            var last_non_empty: usize = 0;
            for (0..@min(cols, page_cells.len)) |c| {
                const cell = &page_cells[c];
                if (cell.wide == .spacer_tail) continue;
                const cp = cell.codepoint();
                if (cp != 0) last_non_empty = c + 1;
            }

            // Render each cell up to last_non_empty
            var col: usize = 0;
            while (col < last_non_empty) : (col += 1) {
                if (col >= page_cells.len) {
                    try buf.append(' ');
                    continue;
                }
                const cell = &page_cells[col];

                // Skip spacer tails (second cell of wide chars)
                if (cell.wide == .spacer_tail or cell.wide == .spacer_head) {
                    continue;
                }

                const cp = cell.codepoint();
                if (cp == 0) {
                    try buf.append(' ');
                } else {
                    // Encode the codepoint as UTF-8
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &utf8_buf) catch 1;
                    try buf.appendSlice(utf8_buf[0..len]);

                    // If this cell has grapheme clusters, append them too
                    if (cell.content_tag == .codepoint_grapheme) {
                        if (page.lookupGrapheme(cell)) |graphemes| {
                            for (graphemes) |gcp| {
                                const glen = std.unicode.utf8Encode(gcp, &utf8_buf) catch continue;
                                try buf.appendSlice(utf8_buf[0..glen]);
                            }
                        }
                    }
                }
            }

            // Add newline after each row
            try buf.append('\n');
        }

        return try buf.toOwnedSlice();
    }

    /// Get cursor position (0-based row, col).
    pub fn cursorPos(self: *GtermInstance) struct { row: u16, col: u16 } {
        return .{
            .row = @intCast(self.terminal.screens.active.cursor.y),
            .col = @intCast(self.terminal.screens.active.cursor.x),
        };
    }

    /// Resize the terminal.
    pub fn resize(self: *GtermInstance, cols: u16, rows: u16) !void {
        try self.terminal.resize(allocator, cols, rows);
        self.cols = cols;
        self.rows = rows;
    }
};

// ── Helpers ─────────────────────────────────────────────────────────────

fn getInstanceFromArg(env: *emacs.emacs_env, arg: emacs.emacs_value) ?*GtermInstance {
    const ptr = env.get_user_ptr.?(env, arg);
    if (emacs.check_exit(env)) return null;
    return @ptrCast(@alignCast(ptr));
}

// ── Emacs module functions ──────────────────────────────────────────────

/// (gterm-new COLS ROWS) -> user-ptr
fn gtermNew(
    env: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const e = env.?;
    const cols_i = e.extract_integer.?(e, args[0]);
    const rows_i = e.extract_integer.?(e, args[1]);

    if (cols_i <= 0 or rows_i <= 0 or cols_i > 500 or rows_i > 500) {
        emacs.signal_error(e, "args-out-of-range", "cols and rows must be between 1 and 500");
        return emacs.nil(e);
    }

    const cols: u16 = @intCast(cols_i);
    const rows: u16 = @intCast(rows_i);

    const instance = GtermInstance.init(cols, rows) catch {
        emacs.signal_error(e, "error", "failed to allocate terminal instance");
        return emacs.nil(e);
    };

    return e.make_user_ptr.?(e, &gtermFinalizer, @ptrCast(instance));
}

/// Invoked by Emacs GC when the user-ptr is collected.
fn gtermFinalizer(ptr: ?*anyopaque) callconv(.c) void {
    if (ptr) |p| {
        const instance: *GtermInstance = @ptrCast(@alignCast(p));
        instance.deinit();
    }
}

/// (gterm-feed TERM BYTES-STRING) -> nil
fn gtermFeed(
    env: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const e = env.?;
    const instance = getInstanceFromArg(e, args[0]) orelse return emacs.nil(e);

    // Get string length first
    var len: emacs.ptrdiff_t = 0;
    _ = e.copy_string_contents.?(e, args[1], null, &len);
    if (emacs.check_exit(e)) return emacs.nil(e);
    if (len <= 1) return emacs.nil(e); // len includes null terminator

    // Allocate buffer and copy
    const buf = allocator.alloc(u8, @intCast(len)) catch {
        emacs.signal_error(e, "error", "allocation failed");
        return emacs.nil(e);
    };
    defer allocator.free(buf);

    _ = e.copy_string_contents.?(e, args[1], buf.ptr, &len);
    if (emacs.check_exit(e)) return emacs.nil(e);

    // Feed bytes (exclude null terminator)
    const data_len: usize = @intCast(len - 1);
    instance.feed(buf[0..data_len]);

    return emacs.nil(e);
}

/// (gterm-content TERM) -> string
fn gtermContent(
    env: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const e = env.?;
    const instance = getInstanceFromArg(e, args[0]) orelse return emacs.nil(e);

    const content = instance.renderContent() catch {
        emacs.signal_error(e, "error", "failed to read terminal content");
        return emacs.nil(e);
    };
    defer allocator.free(content);

    return e.make_string.?(e, content.ptr, @intCast(content.len));
}

/// (gterm-cursor-pos TERM) -> (ROW . COL)
fn gtermCursorPos(
    env: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const e = env.?;
    const instance = getInstanceFromArg(e, args[0]) orelse return emacs.nil(e);
    const pos = instance.cursorPos();

    const row_val = e.make_integer.?(e, @intCast(pos.row));
    const col_val = e.make_integer.?(e, @intCast(pos.col));

    var cons_args = [_]emacs.emacs_value{ row_val, col_val };
    return e.funcall.?(e, e.intern.?(e, "cons"), 2, &cons_args);
}

/// (gterm-resize TERM COLS ROWS) -> nil
fn gtermResize(
    env: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const e = env.?;
    const instance = getInstanceFromArg(e, args[0]) orelse return emacs.nil(e);

    const cols_i = e.extract_integer.?(e, args[1]);
    const rows_i = e.extract_integer.?(e, args[2]);

    if (cols_i <= 0 or rows_i <= 0 or cols_i > 500 or rows_i > 500) {
        emacs.signal_error(e, "args-out-of-range", "cols and rows must be between 1 and 500");
        return emacs.nil(e);
    }

    instance.resize(@intCast(cols_i), @intCast(rows_i)) catch {
        emacs.signal_error(e, "error", "resize failed");
        return emacs.nil(e);
    };

    return emacs.nil(e);
}

/// (gterm-free TERM) -> nil
fn gtermFree(
    env: ?*emacs.emacs_env,
    _: emacs.ptrdiff_t,
    args: [*c]emacs.emacs_value,
    _: ?*anyopaque,
) callconv(.c) emacs.emacs_value {
    const e = env.?;
    const instance = getInstanceFromArg(e, args[0]) orelse return emacs.nil(e);
    instance.deinit();
    return emacs.nil(e);
}

// ── Module entry point ──────────────────────────────────────────────────

/// Called by Emacs when the module is loaded via (require 'gterm-module).
export fn emacs_module_init(runtime: ?*emacs.emacs_runtime) callconv(.c) c_int {
    const rt = runtime.?;
    const env: *emacs.emacs_env = rt.get_environment.?(rt);

    // Register functions
    emacs.defun(env, "gterm-new", 2, 2, &gtermNew,
        "Create a new gterm terminal instance.\nCOLS and ROWS specify the terminal dimensions.\nReturns an opaque terminal handle.",
    );

    emacs.defun(env, "gterm-feed", 2, 2, &gtermFeed,
        "Feed raw bytes into a gterm terminal.\nTERM is a terminal handle from `gterm-new'.\nBYTES is a unibyte string of terminal output.",
    );

    emacs.defun(env, "gterm-content", 1, 1, &gtermContent,
        "Return the visible screen content of a gterm terminal as a string.\nTERM is a terminal handle from `gterm-new'.",
    );

    emacs.defun(env, "gterm-cursor-pos", 1, 1, &gtermCursorPos,
        "Return the cursor position of a gterm terminal as (ROW . COL).\nBoth values are 0-based. TERM is a terminal handle from `gterm-new'.",
    );

    emacs.defun(env, "gterm-resize", 3, 3, &gtermResize,
        "Resize a gterm terminal to COLS columns and ROWS rows.\nTERM is a terminal handle from `gterm-new'.",
    );

    emacs.defun(env, "gterm-free", 1, 1, &gtermFree,
        "Free a gterm terminal instance.\nTERM is a terminal handle from `gterm-new'.\nThis is optional; the GC finalizer also handles cleanup.",
    );

    emacs.provide(env, "gterm-module");
    return 0;
}

// ── Tests ───────────────────────────────────────────────────────────────

test "create and destroy terminal instance" {
    const instance = try GtermInstance.init(80, 24);
    defer instance.deinit();

    const pos = instance.cursorPos();
    try std.testing.expectEqual(@as(u16, 0), pos.row);
    try std.testing.expectEqual(@as(u16, 0), pos.col);
}

test "feed bytes and read content" {
    const instance = try GtermInstance.init(80, 24);
    defer instance.deinit();

    instance.feed("Hello, gterm!");

    const content = try instance.renderContent();
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "Hello, gterm!") != null);
}

test "cursor moves after printing" {
    const instance = try GtermInstance.init(80, 24);
    defer instance.deinit();

    instance.feed("ABCDE");
    const pos = instance.cursorPos();
    try std.testing.expectEqual(@as(u16, 0), pos.row);
    try std.testing.expectEqual(@as(u16, 5), pos.col);
}

test "resize terminal" {
    const instance = try GtermInstance.init(80, 24);
    defer instance.deinit();

    try instance.resize(120, 40);
    try std.testing.expectEqual(@as(u16, 120), instance.cols);
    try std.testing.expectEqual(@as(u16, 40), instance.rows);
}
