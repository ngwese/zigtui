const std = @import("std");
const render = @import("../render/mod.zig");
const style = @import("../style/mod.zig");
const Rect = render.Rect;
const Buffer = render.Buffer;
const Style = style.Style;

/// A single node in the tree.  Nodes without children are always leaf nodes;
/// the `expanded` field is ignored for them.
pub const TreeNode = struct {
    label: []const u8,
    children: []const TreeNode = &.{},
    expanded: bool = false,
    style: Style = .{},

    pub fn isLeaf(self: TreeNode) bool {
        return self.children.len == 0;
    }
};

pub const Tree = struct {
    roots: []const TreeNode,
    selected: ?usize = null,
    /// First visible flat index; used when the tree is taller than the area.
    scroll_offset: usize = 0,
    style: Style = .{},
    highlight_style: Style = .{},
    highlight_symbol: []const u8 = "> ",
    /// Indentation per depth level, in cells.
    indent: u16 = 2,
    /// Prefix for expanded nodes.
    expanded_symbol: []const u8 = "▼ ",
    /// Prefix for collapsed nodes.
    collapsed_symbol: []const u8 = "▶ ",
    /// Prefix for leaf nodes.
    leaf_symbol: []const u8 = "  ",

    /// Adjust `scroll_offset` so `selected` stays inside a viewport of `height` rows.
    pub fn ensureSelectedVisible(self: *Tree, height: usize) void {
        const total = self.visibleCount();
        const max_scroll = total -| height;
        if (self.scroll_offset > max_scroll) self.scroll_offset = max_scroll;
        if (height == 0) return;
        const sel = self.selected orelse return;
        if (sel < self.scroll_offset) {
            self.scroll_offset = sel;
        } else if (sel >= self.scroll_offset + height) {
            self.scroll_offset = sel + 1 - height;
        }
    }

    pub fn render(self: Tree, area: Rect, buf: *Buffer) void {
        if (area.width == 0 or area.height == 0) return;

        var row: u16 = 0;
        var flat_idx: usize = 0;
        self.renderNodes(self.roots, 0, area, buf, &row, &flat_idx);
    }

    fn renderNodes(
        self: Tree,
        nodes: []const TreeNode,
        depth: u16,
        area: Rect,
        buf: *Buffer,
        row: *u16,
        flat_idx: *usize,
    ) void {
        for (nodes) |node| {
            const skip = flat_idx.* < self.scroll_offset;
            if (!skip and row.* >= area.height) return;

            const is_selected = if (self.selected) |sel| sel == flat_idx.* else false;

            if (!skip) {
                const y = area.y + row.*;
                const row_style = if (is_selected)
                    self.style.merge(node.style).merge(self.highlight_style)
                else
                    self.style.merge(node.style);

                // Clear row background
                {
                    var fx: u16 = area.x;
                    while (fx < area.x + area.width) : (fx += 1) {
                        buf.setChar(fx, y, ' ', row_style);
                    }
                }

                var x: u16 = area.x;

                // Indent
                const indent_cells = depth * self.indent;
                x += indent_cells;
                if (x < area.x + area.width) {
                    // Highlight symbol
                    const sym_width: u16 = blk: {
                        var count: u16 = 0;
                        var iter = std.unicode.Utf8View.initUnchecked(self.highlight_symbol).iterator();
                        while (iter.nextCodepoint()) |_| count += 1;
                        break :blk count;
                    };
                    if (is_selected and x + sym_width <= area.x + area.width) {
                        buf.setString(x, y, self.highlight_symbol, row_style);
                    }
                    x += sym_width;

                    // Node kind symbol
                    const kind_sym = if (node.isLeaf())
                        self.leaf_symbol
                    else if (node.expanded)
                        self.expanded_symbol
                    else
                        self.collapsed_symbol;

                    const kind_width: u16 = blk: {
                        var count: u16 = 0;
                        var iter = std.unicode.Utf8View.initUnchecked(kind_sym).iterator();
                        while (iter.nextCodepoint()) |_| count += 1;
                        break :blk count;
                    };
                    if (x + kind_width <= area.x + area.width) {
                        buf.setString(x, y, kind_sym, row_style);
                    }
                    x += kind_width;

                    // Label
                    if (x < area.x + area.width) {
                        const available = area.x + area.width - x;
                        buf.setStringTruncated(x, y, node.label, available, row_style);
                    }
                }

                row.* += 1;
            }

            flat_idx.* += 1;

            // Recurse into children if expanded
            if (!node.isLeaf() and node.expanded) {
                self.renderNodes(node.children, depth + 1, area, buf, row, flat_idx);
            }
        }
    }

    /// Count of currently visible rows (expanded nodes and all their visible children).
    pub fn visibleCount(self: Tree) usize {
        return countVisible(self.roots);
    }

    pub const Hit = struct {
        index: usize,
        /// True when the click landed on a directory disclosure symbol.
        on_disclosure: bool,
        is_dir: bool,
    };

    /// Resolve a click within `area` to a visible tree row.
    pub fn hitTest(self: Tree, area: Rect, px: u16, py: u16) ?Hit {
        if (area.width == 0 or area.height == 0) return null;
        if (px < area.x or py < area.y) return null;
        if (px >= area.x + area.width or py >= area.y + area.height) return null;

        const target_row = py - area.y;
        var row: u16 = 0;
        var flat_idx: usize = 0;
        return hitNodes(self, self.roots, 0, area, px, target_row, &row, &flat_idx);
    }

    fn hitNodes(
        self: Tree,
        nodes: []const TreeNode,
        depth: u16,
        area: Rect,
        px: u16,
        target_row: u16,
        row: *u16,
        flat_idx: *usize,
    ) ?Hit {
        for (nodes) |node| {
            const skip = flat_idx.* < self.scroll_offset;
            if (!skip and row.* > target_row) return null;

            if (!skip and row.* == target_row) {
                const sym_width = codepointCount(self.highlight_symbol);
                const kind_sym = if (node.isLeaf())
                    self.leaf_symbol
                else if (node.expanded)
                    self.expanded_symbol
                else
                    self.collapsed_symbol;
                const kind_width = codepointCount(kind_sym);
                const kind_x = area.x + depth * self.indent + sym_width;
                const on_disclosure = !node.isLeaf() and px >= kind_x and px < kind_x + kind_width;
                return .{
                    .index = flat_idx.*,
                    .on_disclosure = on_disclosure,
                    .is_dir = !node.isLeaf(),
                };
            }

            if (!skip) row.* += 1;
            flat_idx.* += 1;

            if (!node.isLeaf() and node.expanded) {
                if (hitNodes(self, node.children, depth + 1, area, px, target_row, row, flat_idx)) |hit| {
                    return hit;
                }
            }
        }
        return null;
    }

    pub fn selectNext(self: *Tree) void {
        const total = self.visibleCount();
        if (total == 0) return;
        if (self.selected) |sel| {
            if (sel + 1 < total) self.selected = sel + 1;
        } else {
            self.selected = 0;
        }
    }

    pub fn selectPrevious(self: *Tree) void {
        if (self.selected) |sel| {
            if (sel > 0) {
                self.selected = sel - 1;
            }
        } else {
            const total = self.visibleCount();
            if (total > 0) self.selected = total - 1;
        }
    }

    pub fn toggleSelectedNode(self: *Tree, mutable_roots: []TreeNode) void {
        if (self.selected) |sel| {
            _ = toggleAtIndex(mutable_roots, sel, 0);
        }
    }
};

fn codepointCount(text: []const u8) u16 {
    var count: u16 = 0;
    var iter = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (iter.nextCodepoint()) |_| count += 1;
    return count;
}

fn countVisible(nodes: []const TreeNode) usize {
    var count: usize = 0;
    for (nodes) |node| {
        count += 1;
        if (!node.isLeaf() and node.expanded) {
            count += countVisible(node.children);
        }
    }
    return count;
}

fn toggleAtIndex(nodes: []TreeNode, target: usize, current: usize) usize {
    var idx = current;
    for (nodes) |*node| {
        if (idx == target) {
            node.expanded = !node.expanded;
            return idx + 1; // sentinel "found"
        }
        idx += 1;
        if (!node.isLeaf() and node.expanded) {
            const result = toggleAtIndex(node.children, target, idx);
            if (result != idx + countVisible(node.children)) return result; // found inside
            idx += countVisible(node.children);
        }
    }
    return idx;
}

test "Tree visibleCount respects expanded" {
    const leaf1 = TreeNode{ .label = "a.zig" };
    const leaf2 = TreeNode{ .label = "b.zig" };
    const dir = TreeNode{ .label = "src", .children = &.{ leaf1, leaf2 }, .expanded = false };
    const t = Tree{ .roots = &.{dir} };
    try std.testing.expectEqual(@as(usize, 1), t.visibleCount()); // collapsed

    const dir_open = TreeNode{ .label = "src", .children = &.{ leaf1, leaf2 }, .expanded = true };
    const t2 = Tree{ .roots = &.{dir_open} };
    try std.testing.expectEqual(@as(usize, 3), t2.visibleCount());
}

test "Tree ensureSelectedVisible scrolls" {
    const leaves = [_]TreeNode{
        .{ .label = "0" },
        .{ .label = "1" },
        .{ .label = "2" },
        .{ .label = "3" },
        .{ .label = "4" },
    };
    var t = Tree{ .roots = &leaves, .selected = 0 };
    t.ensureSelectedVisible(3);
    try std.testing.expectEqual(@as(usize, 0), t.scroll_offset);

    t.selected = 4;
    t.ensureSelectedVisible(3);
    try std.testing.expectEqual(@as(usize, 2), t.scroll_offset);

    t.selected = 1;
    t.ensureSelectedVisible(3);
    try std.testing.expectEqual(@as(usize, 1), t.scroll_offset);
}

test "Tree hitTest disclosure vs row" {
    const leaf = TreeNode{ .label = "a.lua" };
    const dir = TreeNode{ .label = "proj", .children = &.{leaf}, .expanded = false };
    const t = Tree{
        .roots = &.{dir},
        .highlight_symbol = "▶ ",
        .collapsed_symbol = "▶ ",
        .leaf_symbol = "  ",
    };
    const area = Rect{ .x = 0, .y = 0, .width = 20, .height = 5 };

    // highlight symbol occupies cols 0-1, disclosure at cols 2-3
    const disc = t.hitTest(area, 2, 0).?;
    try std.testing.expectEqual(@as(usize, 0), disc.index);
    try std.testing.expect(disc.on_disclosure);
    try std.testing.expect(disc.is_dir);

    const label = t.hitTest(area, 8, 0).?;
    try std.testing.expectEqual(@as(usize, 0), label.index);
    try std.testing.expect(!label.on_disclosure);
}
