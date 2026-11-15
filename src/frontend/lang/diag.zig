//! The diagnostic catalogue of the ESPice language front end. In: rows
//! the lexer, parser, checker and lowering append (a code, a byte offset,
//! a subject). Out: `path:line:col: error E3002: title: subject` lines,
//! once, after the whole file was read. Codes are never renumbered or
//! reused; the leading digit is the stage (1 lexical, 2 syntax, 3 schema
//! and types, 4 lowering refusals).
//! Cites: docs/using/language.md "What is checked, and when"; contract
//! item 6; compiler-construction rule 5.
//!
//! Contents:
//! - `pub const Severity`
//! - `pub const Code`
//! - `pub const Info`
//! - `pub const Diag`
//! - `pub const Diags`: `add`
//! - `pub fn info(code: Code) Info`
//! - `pub fn hasError(rows: []const Diag) bool`
//! - `pub fn render(src: []const u8, path: []const u8, rows: []const Diag) void`
//! - `pub fn lineCol(src: []const u8, at: u32) struct { u32, u32 }`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// An error fails the file; a warning is printed and the file reads.
pub const Severity = enum(u1) { err, warn };

/// One row per thing the front end can say about a file. The value is the
/// code's number; `info` holds its severity, title and explanation.
pub const Code = enum(u16) {
    // 1: lexical.
    unknown_char = 1001,
    unterminated_string = 1002,
    bad_number = 1003,
    bare_mega = 1004,
    spice_suffix = 1005,
    unknown_unit = 1006,
    legacy_operator = 1007,
    farad_warning = 1008,
    percent_prefix = 1009,
    // 2: syntax.
    bad_header = 2001,
    unexpected = 2002,
    unclosed = 2003,
    too_deep = 2004,
    positional_after_key = 2005,
    block_line = 2006,
    stray_close = 2007,
    // 3: schema and types.
    unknown_directive = 3001,
    unknown_key = 3002,
    unknown_word = 3003,
    missing_key = 3004,
    repeated_key = 3005,
    wrong_unit = 3006,
    fraction = 3007,
    wrong_kind = 3008,
    arity = 3009,
    reads_circuit = 3010,
    misplaced = 3011,
    unknown_family = 3012,
    bad_quoted_name = 3013,
    retired = 3014,
    mixed_ports = 3015,
    hdl_include = 3016,
    duplicate_instance = 3017,
    stim_name = 3018,
    meas_function = 3201,
    meas_signal = 3202,
    // 4: lowering refusals.
    not_lowered = 4001,
    no_filler = 4002,
    no_legacy = 4003,
    sweep_not_lowered = 4004,
    meas_nested = 4201,
};

/// What a code means: its severity, a one-line title, and the explain
/// text that says what to write instead.
pub const Info = struct { severity: Severity, title: []const u8, explain: []const u8 };

/// One reported problem: `at` is a byte offset into the file, `subject`
/// the text it is about (a slice of the file or a static string).
pub const Diag = struct { code: Code, at: u32, subject: []const u8 };

/// The rows of one file, in the order the stages appended them.
pub const Diags = struct {
    rows: std.ArrayList(Diag) = .empty,
    gpa: Allocator,

    /// Appends one row. Fails only with `OutOfMemory`.
    pub fn add(d: *Diags, code: Code, at: u32, subject: []const u8) Allocator.Error!void {
        try d.rows.append(d.gpa, .{ .code = code, .at = at, .subject = subject });
    }
};

const table = std.EnumArray(Code, Info).init(.{
    .unknown_char = .{ .severity = .err, .title = "a character the language does not use", .explain = "Names, numbers, strings in double quotes, brackets and the operators of the Expressions section; comments are //." },
    .unterminated_string = .{ .severity = .err, .title = "a string with no closing quote on its line", .explain = "Close the string with \" before the end of the line." },
    .bad_number = .{ .severity = .err, .title = "a number that does not read", .explain = "digits [. digits] [e [+|-] digits] [prefix] [unit]." },
    .bare_mega = .{ .severity = .err, .title = "a bare M: mega needs a unit", .explain = "M is mega and m milli; write 1MHz, 1MOhm or 1e6." },
    .spice_suffix = .{ .severity = .err, .title = "a SPICE scale suffix the language does not read", .explain = "meg is M with a unit (1MHz), mil is 25.4um, x is M; K U N P are written k u n p." },
    .unknown_unit = .{ .severity = .err, .title = "an unknown unit", .explain = "Units: V A s Hz Ohm S F H m C deg %." },
    .legacy_operator = .{ .severity = .err, .title = "a legacy operator", .explain = "Write ** for ^, != for <>, idiv() for \\, and parentheses for '...' and {...}." },
    .farad_warning = .{ .severity = .warn, .title = "1F is one farad", .explain = "Femto is 1f or 1fF." },
    .percent_prefix = .{ .severity = .err, .title = "a prefix before %", .explain = "A ratio is a plain number before %: 5%." },
    .bad_header = .{ .severity = .err, .title = "the header is not .espice 1", .explain = "Line 1 of a file in this language is .espice 1." },
    .unexpected = .{ .severity = .err, .title = "unexpected token", .explain = "See the grammar in Files and statements." },
    .unclosed = .{ .severity = .err, .title = "a bracket or block left open", .explain = "Close every (, [ and { the file opens." },
    .too_deep = .{ .severity = .err, .title = "nested deeper than the front end reads", .explain = "Expressions and blocks nest at most 256 levels." },
    .positional_after_key = .{ .severity = .err, .title = "a positional argument after a keyed one", .explain = "A call takes its positional arguments first, then key=value." },
    .block_line = .{ .severity = .err, .title = "a block brace not at the end or start of its line", .explain = "{ closes the line that opens a block, and } stands on a line of its own." },
    .stray_close = .{ .severity = .err, .title = "a } with no block open", .explain = "Remove it, or open the block it closes." },
    .unknown_directive = .{ .severity = .err, .title = "an unknown directive", .explain = "The directives are the ones language.md lists." },
    .unknown_key = .{ .severity = .err, .title = "an unknown key", .explain = "The keys of a statement are the ones its signature lists." },
    .unknown_word = .{ .severity = .err, .title = "a word the setting does not list", .explain = "An enum takes one of its listed words." },
    .missing_key = .{ .severity = .err, .title = "a required key is missing", .explain = "Give every key the signature does not bracket." },
    .repeated_key = .{ .severity = .err, .title = "a key given twice", .explain = "Give each key once; the bare principal value counts as its key." },
    .wrong_unit = .{ .severity = .err, .title = "a unit that is not the slot's", .explain = "Write the slot's unit, none, or an expression." },
    .fraction = .{ .severity = .err, .title = "a fraction in an integer slot", .explain = "Write a whole number." },
    .wrong_kind = .{ .severity = .err, .title = "a value of the wrong kind", .explain = "The slot's type says what it takes (Types)." },
    .arity = .{ .severity = .err, .title = "the wrong number of arguments", .explain = "See the statement's signature." },
    .reads_circuit = .{ .severity = .err, .title = "reads the circuit outside a behavioural source", .explain = "v(), i(), time, temper, hertz, ddt and the step functions belong in a bsource, or a resistor, capacitor or inductor value." },
    .misplaced = .{ .severity = .err, .title = "a statement where it cannot stand", .explain = "See where the statement may appear in language.md." },
    .unknown_family = .{ .severity = .err, .title = "a model family or polarity the table does not list", .explain = "See the family table in Models." },
    .bad_quoted_name = .{ .severity = .err, .title = "a quoted name with a character names may not hold", .explain = "A quoted name holds no blank, (, ), comma, =, quote or brace." },
    .retired = .{ .severity = .err, .title = "not in the language", .explain = "See Not in the language for the spelling to use." },
    .mixed_ports = .{ .severity = .err, .title = "a port list mixing positional and named ports", .explain = "Write all ports by position or all as port=node." },
    .hdl_include = .{ .severity = .err, .title = "a Verilog-A or Verilog file read with .include", .explain = "Load it with .hdl \"model.va\"." },
    .duplicate_instance = .{ .severity = .err, .title = "an instance name used twice in one block", .explain = "Names ignore case; give each instance of a block its own name." },
    .stim_name = .{ .severity = .err, .title = "a .stim pwl signal whose name does not start with v or i", .explain = "The name's first letter says the source it becomes: v for a voltage, i for a current." },
    .meas_function = .{ .severity = .err, .title = "a measurement function the result kind does not take", .explain = "thd snr sndr enob sfdr read fft; jitter tran or trannoise; em_avg tran; the margins lstb; find with neither at nor when dcmatch, lstb or op." },
    .meas_signal = .{ .severity = .err, .title = "a waveform where a measurement takes a value", .explain = "v(), i() and time stand in a signal; a level, a key's value and a computed measurement read parameters and earlier results." },
    .not_lowered = .{ .severity = .err, .title = "no longer reported", .explain = "Every statement lowers; the code is kept so that no code is renumbered." },
    .no_filler = .{ .severity = .err, .title = "an argument the legacy card cannot leave out", .explain = "Give the omitted arguments before it explicitly." },
    .no_legacy = .{ .severity = .err, .title = "a construct with no legacy card that means it", .explain = "Write the construct in the legacy dialect, or leave it out." },
    .sweep_not_lowered = .{ .severity = .err, .title = "a sweep clause on a statement that takes none", .explain = "Only an analysis takes sweep; vary a parameter with .step." },
    .meas_nested = .{ .severity = .err, .title = "a measurement inside arithmetic", .explain = "Give the inner measurement its own .meas and use its name; only cross(...) - cross(...) combines two." },
});

/// The catalogue row of `code`.
pub fn info(code: Code) Info {
    return table.get(code);
}

/// Whether any row is an error.
pub fn hasError(rows: []const Diag) bool {
    for (rows) |d| if (info(d.code).severity == .err) return true;
    return false;
}

/// Logs every row in source order as `path:line:col: E3002 title: subject`.
/// Silent under `builtin.is_test`, as the reader's `render` is: a test
/// reads the rows instead.
pub fn render(src: []const u8, path: []const u8, rows: []const Diag) void {
    if (@import("builtin").is_test) return;
    for (rows) |d| {
        const line, const col = lineCol(src, d.at);
        const i = info(d.code);
        switch (i.severity) {
            .err => std.log.err("{s}:{d}:{d}: E{d}: {s}: {s}", .{ path, line, col, @backingInt(d.code), i.title, d.subject }),
            .warn => std.log.warn("{s}:{d}:{d}: W{d}: {s}: {s}", .{ path, line, col, @backingInt(d.code), i.title, d.subject }),
        }
    }
}

/// The 1-based line and column of byte `at` in `src`.
pub fn lineCol(src: []const u8, at: u32) struct { u32, u32 } {
    assert(at <= src.len);
    var line: u32 = 1;
    var start: u32 = 0;
    for (src[0..at], 0..) |c, i| if (c == '\n') {
        line += 1;
        start = @intCast(i + 1);
    };
    return .{ line, at - start + 1 };
}

// ---- private ----

test "line and column of an offset" {
    const src = "ab\ncd\n";
    try std.testing.expectEqual(.{ 1, 1 }, lineCol(src, 0));
    try std.testing.expectEqual(.{ 2, 2 }, lineCol(src, 4));
    try std.testing.expectEqual(.{ 3, 1 }, lineCol(src, 6));
}
