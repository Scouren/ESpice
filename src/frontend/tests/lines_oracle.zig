//! The logical-line readers as they stood before the single-scan rewrite
//! (HEAD 76627329), kept as the oracle for `tests/lines.zig`: every
//! logical line the rewrite produces must match this copy. Do not optimize it; it is the reference.
const std = @import("std");

/// Appends a continuation piece to a logical line, copying `head` on first use.
fn join(arena: std.mem.Allocator, joined: *?std.ArrayList(u8), head: []const u8, piece: []const u8) !void {
    if (joined.* == null) {
        joined.* = .empty;
        try joined.*.?.appendSlice(arena, head);
    }
    try joined.*.?.append(arena, ' ');
    try joined.*.?.appendSlice(arena, piece);
}

/// The next physical line without its `\r`, advancing `rest`.
fn nextPhysicalLine(rest: *[]const u8) ?[]const u8 {
    const src = rest.*;
    if (src.len == 0) return null;
    const nl = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
    const line = std.mem.trimEnd(u8, src[0..nl], "\r");
    rest.* = if (nl == src.len) src[nl..] else src[nl + 1 ..];
    return line;
}

/// ngspice: title line, case folded, `*` comments, `$`/`;` tails, `+` continuation.
pub const ngspice = struct {
    /// Logical-line iterator; a joined line is allocated in `arena`.
    /// tests/frontend/grammar/ngspice_lines.peg is the spec; section numbers cite
    /// dev/research/ngspice-syntax.md.
    pub const Lines = struct {
        rest: []const u8,
        arena: std.mem.Allocator,

        /// A first byte that makes the line a comment [§1.5]: `*`, `#`, `$`,
        /// `;` silently, and the punctuation ngspice rewrites to `*` with a
        /// warning.
        fn isCommentLead(c: u8) bool {
            return std.mem.indexOfScalar(u8, "*#$;=[]?()&%\"!:,\x0c", c) != null;
        }

        /// `line` up to its end-of-line comment [§1.5], trimmed: `;` or `//`
        /// anywhere, `$` at the start or after a blank, tab or comma, all
        /// outside quotes (a backslash escapes a quote). Braces do not
        /// protect. One scalar pass: cards are short, and stdlib vector
        /// scans cost more in setup than they save.
        fn stripComment(line: []const u8) []const u8 {
            var quote: u8 = 0;
            var i: usize = 0;
            while (i < line.len) : (i += 1) {
                const c = line[i];
                if (quote != 0) {
                    if (c == '\\') {
                        i += 1;
                    } else if (c == quote) quote = 0;
                    continue;
                }
                switch (c) {
                    '\'', '"' => quote = c,
                    ';' => break,
                    '/' => if (i + 1 < line.len and line[i + 1] == '/') break,
                    '$' => if (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t' or line[i - 1] == ',') break,
                    else => {}, // else: any other byte is text
                }
            }
            return std.mem.trim(u8, line[0..@min(i, line.len)], " \t");
        }

        /// True when `line` ends in `\\` and blanks [§1.6]: it continues on
        /// the next line, whatever comment sits before the backslashes.
        fn endsGlued(line: []const u8) bool {
            return std.mem.endsWith(u8, std.mem.trimEnd(u8, line, " \t"), "\\\\");
        }

        /// `line` without its trailing `\\` and blanks.
        fn unglued(line: []const u8) []const u8 {
            const t = std.mem.trimEnd(u8, line, " \t");
            return t[0 .. t.len - 2];
        }

        /// The next logical line, continuations joined; null at the end.
        /// The line borrows `rest`'s text, or lives in `arena` when it joins
        /// continuations. Fails only with `OutOfMemory` while joining.
        pub fn next(self: *Lines) !?[]const u8 {
            var t: []const u8 = undefined;
            while (true) {
                const raw = nextPhysicalLine(&self.rest) orelse return null;
                t = std.mem.trim(u8, raw, " \t");
                if (t.len == 0 or isCommentLead(t[0])) continue;
                // §1.3: a line starting with `@` ends the file.
                if (t[0] == '@') {
                    self.rest = "";
                    return null;
                }
                // §1.6: a `+` line with nothing to continue is ignored.
                if (t[0] == '+') continue;
                // §1.5: a line holding only an end-of-line comment (`//x`)
                // becomes a comment line, so a `+` after it continues nothing.
                if (!endsGlued(t) and stripComment(t).len == 0) continue;
                break;
            }
            var glued = endsGlued(t);
            const head = stripComment(if (glued) unglued(t) else t);
            var joined: ?std.ArrayList(u8) = null;
            // Each pass consumes a physical line or ends the statement.
            const passes_max = self.rest.len + 1;
            var passes: usize = 0;
            while (true) : (passes += 1) {
                std.debug.assert(passes <= passes_max);
                const save = self.rest;
                const raw = nextPhysicalLine(&self.rest) orelse break;
                var u = std.mem.trim(u8, raw, " \t");
                if (glued) {
                    // §1.6: the line after a `\\` continues the statement as is.
                } else if (u.len > 0 and u[0] == '+') {
                    u = u[1..];
                } else if (u.len == 0 or u[0] == '*' or u[0] == '#' or u[0] == '$') {
                    continue;
                } else {
                    self.rest = save;
                    break;
                }
                glued = endsGlued(u);
                try join(self.arena, &joined, head, stripComment(if (glued) unglued(u) else u));
            }
            return if (joined) |j| j.items else head;
        }
    };
};
