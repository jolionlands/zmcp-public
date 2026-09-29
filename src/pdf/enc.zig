//! Simple-font encodings (WinAnsi, MacRoman, Standard) and a subset of the
//! Adobe glyph list. Tables map a byte code to a Unicode code point (0 = none).

const std = @import("std");

const cp1252_hi = [32]u21{
    0x20AC, 0x2022, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
    0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x2022, 0x017D, 0x2022,
    0x2022, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
    0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x2022, 0x017E, 0x0178,
};

const mac_hi_utf8 =
    "ÄÅÇÉÑÖÜáàâäãåçéè" ++
    "êëíìîïñóòôöõúùûü" ++
    "†°¢£§•¶ß®©™´¨≠ÆØ" ++
    "∞±≤≥¥µ∂∑∏π∫ªºΩæø" ++
    "¿¡¬√ƒ≈∆«»…\u{00A0}ÀÃÕŒœ" ++
    "–—“”‘’÷◊ÿŸ⁄€‹›ﬁﬂ" ++
    "‡·‚„‰ÂÊÁËÈÍÎÏÌÓÔ" ++
    "\u{F8FF}ÒÚÛÙıˆ˜¯˘˙˚¸˝˛ˇ";

fn ascii() [256]u21 {
    var t = [_]u21{0} ** 256;
    var i: usize = 0x20;
    while (i < 0x7F) : (i += 1) t[i] = @intCast(i);
    return t;
}

pub const win_ansi: [256]u21 = blk: {
    @setEvalBranchQuota(10000);
    var t = ascii();
    for (cp1252_hi, 0..) |c, i| t[0x80 + i] = c;
    var i: usize = 0xA0;
    while (i < 256) : (i += 1) t[i] = @intCast(i);
    t[0x7F] = 0x2022;
    break :blk t;
};

pub const mac_roman: [256]u21 = blk: {
    @setEvalBranchQuota(100000);
    var t = ascii();
    var it = (std.unicode.Utf8View.initComptime(mac_hi_utf8)).iterator();
    var i: usize = 0x80;
    while (it.nextCodepoint()) |cp| : (i += 1) t[i] = cp;
    break :blk t;
};

const std_hi = [_][2]u21{
    .{ 0xA1, 0xA1 },   .{ 0xA2, 0xA2 },   .{ 0xA3, 0xA3 },   .{ 0xA4, 0x2044 }, .{ 0xA5, 0xA5 },   .{ 0xA6, 0x192 },
    .{ 0xA7, 0xA7 },   .{ 0xA8, 0xA4 },   .{ 0xA9, 0x27 },   .{ 0xAA, 0x201C }, .{ 0xAB, 0xAB },   .{ 0xAC, 0x2039 },
    .{ 0xAD, 0x203A }, .{ 0xAE, 0xFB01 }, .{ 0xAF, 0xFB02 }, .{ 0xB1, 0x2013 }, .{ 0xB2, 0x2020 }, .{ 0xB3, 0x2021 },
    .{ 0xB4, 0xB7 },   .{ 0xB6, 0xB6 },   .{ 0xB7, 0x2022 }, .{ 0xB8, 0x201A }, .{ 0xB9, 0x201E }, .{ 0xBA, 0x201D },
    .{ 0xBB, 0xBB },   .{ 0xBC, 0x2026 }, .{ 0xBD, 0x2030 }, .{ 0xBF, 0xBF },   .{ 0xC1, 0x60 },   .{ 0xC2, 0xB4 },
    .{ 0xC3, 0x2C6 },  .{ 0xC4, 0x2DC },  .{ 0xC5, 0xAF },   .{ 0xC6, 0x2D8 },  .{ 0xC7, 0x2D9 },  .{ 0xC8, 0xA8 },
    .{ 0xCA, 0x2DA },  .{ 0xCB, 0xB8 },   .{ 0xCD, 0x2DD },  .{ 0xCE, 0x2DB },  .{ 0xCF, 0x2C7 },  .{ 0xD0, 0x2014 },
    .{ 0xE1, 0xC6 },   .{ 0xE3, 0xAA },   .{ 0xE8, 0x141 },  .{ 0xE9, 0xD8 },   .{ 0xEA, 0x152 },  .{ 0xEB, 0xBA },
    .{ 0xF1, 0xE6 },   .{ 0xF5, 0x131 },  .{ 0xF8, 0x142 },  .{ 0xF9, 0xF8 },   .{ 0xFA, 0x153 },  .{ 0xFB, 0xDF },
};

pub const standard: [256]u21 = blk: {
    var t = ascii();
    t[0x27] = 0x2019;
    t[0x60] = 0x2018;
    for (std_hi) |p| t[p[0]] = p[1];
    break :blk t;
};

const glyph_entries = [_]struct { []const u8, u21 }{
    .{ "space", 0x20 },         .{ "exclam", 0x21 },        .{ "quotedbl", 0x22 },      .{ "numbersign", 0x23 },
    .{ "dollar", 0x24 },        .{ "percent", 0x25 },       .{ "ampersand", 0x26 },     .{ "quotesingle", 0x27 },
    .{ "parenleft", 0x28 },     .{ "parenright", 0x29 },    .{ "asterisk", 0x2A },      .{ "plus", 0x2B },
    .{ "comma", 0x2C },         .{ "hyphen", 0x2D },        .{ "period", 0x2E },        .{ "slash", 0x2F },
    .{ "zero", 0x30 },          .{ "one", 0x31 },           .{ "two", 0x32 },           .{ "three", 0x33 },
    .{ "four", 0x34 },          .{ "five", 0x35 },          .{ "six", 0x36 },           .{ "seven", 0x37 },
    .{ "eight", 0x38 },         .{ "nine", 0x39 },          .{ "colon", 0x3A },         .{ "semicolon", 0x3B },
    .{ "less", 0x3C },          .{ "equal", 0x3D },         .{ "greater", 0x3E },       .{ "question", 0x3F },
    .{ "at", 0x40 },            .{ "bracketleft", 0x5B },   .{ "backslash", 0x5C },     .{ "bracketright", 0x5D },
    .{ "asciicircum", 0x5E },   .{ "underscore", 0x5F },    .{ "grave", 0x60 },         .{ "braceleft", 0x7B },
    .{ "bar", 0x7C },           .{ "braceright", 0x7D },    .{ "asciitilde", 0x7E },    .{ "nbspace", 0xA0 },
    .{ "nonbreakingspace", 0xA0 }, .{ "exclamdown", 0xA1 }, .{ "cent", 0xA2 },          .{ "sterling", 0xA3 },
    .{ "currency", 0xA4 },      .{ "yen", 0xA5 },           .{ "brokenbar", 0xA6 },     .{ "section", 0xA7 },
    .{ "dieresis", 0xA8 },      .{ "copyright", 0xA9 },     .{ "ordfeminine", 0xAA },   .{ "guillemotleft", 0xAB },
    .{ "logicalnot", 0xAC },    .{ "sfthyphen", 0x2D },     .{ "registered", 0xAE },    .{ "macron", 0xAF },
    .{ "degree", 0xB0 },        .{ "plusminus", 0xB1 },     .{ "twosuperior", 0xB2 },   .{ "threesuperior", 0xB3 },
    .{ "acute", 0xB4 },         .{ "mu", 0xB5 },            .{ "paragraph", 0xB6 },     .{ "periodcentered", 0xB7 },
    .{ "cedilla", 0xB8 },       .{ "onesuperior", 0xB9 },   .{ "ordmasculine", 0xBA },  .{ "guillemotright", 0xBB },
    .{ "onequarter", 0xBC },    .{ "onehalf", 0xBD },       .{ "threequarters", 0xBE }, .{ "questiondown", 0xBF },
    .{ "Agrave", 0xC0 },        .{ "Aacute", 0xC1 },        .{ "Acircumflex", 0xC2 },   .{ "Atilde", 0xC3 },
    .{ "Adieresis", 0xC4 },     .{ "Aring", 0xC5 },         .{ "AE", 0xC6 },            .{ "Ccedilla", 0xC7 },
    .{ "Egrave", 0xC8 },        .{ "Eacute", 0xC9 },        .{ "Ecircumflex", 0xCA },   .{ "Edieresis", 0xCB },
    .{ "Igrave", 0xCC },        .{ "Iacute", 0xCD },        .{ "Icircumflex", 0xCE },   .{ "Idieresis", 0xCF },
    .{ "Eth", 0xD0 },           .{ "Ntilde", 0xD1 },        .{ "Ograve", 0xD2 },        .{ "Oacute", 0xD3 },
    .{ "Ocircumflex", 0xD4 },   .{ "Otilde", 0xD5 },        .{ "Odieresis", 0xD6 },     .{ "multiply", 0xD7 },
    .{ "Oslash", 0xD8 },        .{ "Ugrave", 0xD9 },        .{ "Uacute", 0xDA },        .{ "Ucircumflex", 0xDB },
    .{ "Udieresis", 0xDC },     .{ "Yacute", 0xDD },        .{ "Thorn", 0xDE },         .{ "germandbls", 0xDF },
    .{ "agrave", 0xE0 },        .{ "aacute", 0xE1 },        .{ "acircumflex", 0xE2 },   .{ "atilde", 0xE3 },
    .{ "adieresis", 0xE4 },     .{ "aring", 0xE5 },         .{ "ae", 0xE6 },            .{ "ccedilla", 0xE7 },
    .{ "egrave", 0xE8 },        .{ "eacute", 0xE9 },        .{ "ecircumflex", 0xEA },   .{ "edieresis", 0xEB },
    .{ "igrave", 0xEC },        .{ "iacute", 0xED },        .{ "icircumflex", 0xEE },   .{ "idieresis", 0xEF },
    .{ "eth", 0xF0 },           .{ "ntilde", 0xF1 },        .{ "ograve", 0xF2 },        .{ "oacute", 0xF3 },
    .{ "ocircumflex", 0xF4 },   .{ "otilde", 0xF5 },        .{ "odieresis", 0xF6 },     .{ "divide", 0xF7 },
    .{ "oslash", 0xF8 },        .{ "ugrave", 0xF9 },        .{ "uacute", 0xFA },        .{ "ucircumflex", 0xFB },
    .{ "udieresis", 0xFC },     .{ "yacute", 0xFD },        .{ "thorn", 0xFE },         .{ "ydieresis", 0xFF },
    .{ "Aogonek", 0x104 },      .{ "aogonek", 0x105 },      .{ "Cacute", 0x106 },       .{ "cacute", 0x107 },
    .{ "Ccaron", 0x10C },       .{ "ccaron", 0x10D },       .{ "Dcaron", 0x10E },       .{ "dcaron", 0x10F },
    .{ "Eogonek", 0x118 },      .{ "eogonek", 0x119 },      .{ "Ecaron", 0x11A },       .{ "ecaron", 0x11B },
    .{ "Gbreve", 0x11E },       .{ "gbreve", 0x11F },       .{ "Idotaccent", 0x130 },   .{ "dotlessi", 0x131 },
    .{ "Lslash", 0x141 },       .{ "lslash", 0x142 },       .{ "Nacute", 0x143 },       .{ "nacute", 0x144 },
    .{ "Ncaron", 0x147 },       .{ "ncaron", 0x148 },       .{ "OE", 0x152 },           .{ "oe", 0x153 },
    .{ "Rcaron", 0x158 },       .{ "rcaron", 0x159 },       .{ "Sacute", 0x15A },       .{ "sacute", 0x15B },
    .{ "Scedilla", 0x15E },     .{ "scedilla", 0x15F },     .{ "Scaron", 0x160 },       .{ "scaron", 0x161 },
    .{ "Tcaron", 0x164 },       .{ "tcaron", 0x165 },       .{ "Uring", 0x16E },        .{ "uring", 0x16F },
    .{ "Ydieresis", 0x178 },    .{ "Zacute", 0x179 },       .{ "zacute", 0x17A },       .{ "Zdotaccent", 0x17B },
    .{ "zdotaccent", 0x17C },   .{ "Zcaron", 0x17D },       .{ "zcaron", 0x17E },       .{ "florin", 0x192 },
    .{ "circumflex", 0x2C6 },   .{ "caron", 0x2C7 },        .{ "breve", 0x2D8 },        .{ "dotaccent", 0x2D9 },
    .{ "ring", 0x2DA },         .{ "ogonek", 0x2DB },       .{ "tilde", 0x2DC },        .{ "hungarumlaut", 0x2DD },
    .{ "Alpha", 0x391 },        .{ "Beta", 0x392 },         .{ "Gamma", 0x393 },        .{ "Delta", 0x2206 },
    .{ "Epsilon", 0x395 },      .{ "Zeta", 0x396 },         .{ "Eta", 0x397 },          .{ "Theta", 0x398 },
    .{ "Iota", 0x399 },         .{ "Kappa", 0x39A },        .{ "Lambda", 0x39B },       .{ "Mu", 0x39C },
    .{ "Nu", 0x39D },           .{ "Xi", 0x39E },           .{ "Omicron", 0x39F },      .{ "Pi", 0x3A0 },
    .{ "Rho", 0x3A1 },          .{ "Sigma", 0x3A3 },        .{ "Tau", 0x3A4 },          .{ "Upsilon", 0x3A5 },
    .{ "Phi", 0x3A6 },          .{ "Chi", 0x3A7 },          .{ "Psi", 0x3A8 },          .{ "Omega", 0x2126 },
    .{ "alpha", 0x3B1 },        .{ "beta", 0x3B2 },         .{ "gamma", 0x3B3 },        .{ "delta", 0x3B4 },
    .{ "epsilon", 0x3B5 },      .{ "zeta", 0x3B6 },         .{ "eta", 0x3B7 },          .{ "theta", 0x3B8 },
    .{ "iota", 0x3B9 },         .{ "kappa", 0x3BA },        .{ "lambda", 0x3BB },       .{ "nu", 0x3BD },
    .{ "xi", 0x3BE },           .{ "omicron", 0x3BF },      .{ "pi", 0x3C0 },           .{ "rho", 0x3C1 },
    .{ "sigma", 0x3C3 },        .{ "tau", 0x3C4 },          .{ "upsilon", 0x3C5 },      .{ "phi", 0x3C6 },
    .{ "chi", 0x3C7 },          .{ "psi", 0x3C8 },          .{ "omega", 0x3C9 },        .{ "endash", 0x2013 },
    .{ "emdash", 0x2014 },      .{ "quoteleft", 0x2018 },   .{ "quoteright", 0x2019 },  .{ "quotesinglbase", 0x201A },
    .{ "quotedblleft", 0x201C }, .{ "quotedblright", 0x201D }, .{ "quotedblbase", 0x201E }, .{ "dagger", 0x2020 },
    .{ "daggerdbl", 0x2021 },   .{ "bullet", 0x2022 },      .{ "ellipsis", 0x2026 },    .{ "perthousand", 0x2030 },
    .{ "guilsinglleft", 0x2039 }, .{ "guilsinglright", 0x203A }, .{ "fraction", 0x2044 }, .{ "Euro", 0x20AC },
    .{ "trademark", 0x2122 },   .{ "partialdiff", 0x2202 }, .{ "summation", 0x2211 },   .{ "minus", 0x2212 },
    .{ "product", 0x220F },     .{ "radical", 0x221A },     .{ "infinity", 0x221E },    .{ "integral", 0x222B },
    .{ "approxequal", 0x2248 }, .{ "notequal", 0x2260 },    .{ "lessequal", 0x2264 },   .{ "greaterequal", 0x2265 },
    .{ "lozenge", 0x25CA },     .{ "ff", 0xFB00 },          .{ "fi", 0xFB01 },          .{ "fl", 0xFB02 },
    .{ "ffi", 0xFB03 },         .{ "ffl", 0xFB04 },         .{ "arrowright", 0x2192 },  .{ "arrowleft", 0x2190 },
    .{ "arrowup", 0x2191 },     .{ "arrowdown", 0x2193 },   .{ "checkmark", 0x2713 },   .{ "mu1", 0xB5 },
};

const glyph_map = std.StaticStringMap(u21).initComptime(glyph_entries);

fn hexVal(s: []const u8) ?u21 {
    return std.fmt.parseInt(u21, s, 16) catch null;
}

/// Adobe glyph name to a code point; 0 when unknown.
pub fn glyphToUnicode(name_in: []const u8) u21 {
    var name = name_in;
    if (std.mem.indexOfScalar(u8, name, '.')) |d| {
        if (d == 0) return 0;
        name = name[0..d];
    }
    if (name.len == 1) return name[0];
    if (glyph_map.get(name)) |cp| return cp;
    if (name.len >= 7 and std.mem.startsWith(u8, name, "uni") and (name.len - 3) % 4 == 0) {
        return hexVal(name[3..7]) orelse 0;
    }
    if (name.len >= 5 and name.len <= 7 and name[0] == 'u') {
        return hexVal(name[1..]) orelse 0;
    }
    if (std.mem.indexOfScalar(u8, name, '_')) |u| {
        if (u > 0) return glyphToUnicode(name[0..u]);
    }
    return 0;
}

test "glyph names" {
    const t = std.testing;
    try t.expectEqual(@as(u21, 0x20), glyphToUnicode("space"));
    try t.expectEqual(@as(u21, 'A'), glyphToUnicode("A"));
    try t.expectEqual(@as(u21, 0xFB01), glyphToUnicode("fi"));
    try t.expectEqual(@as(u21, 0x2014), glyphToUnicode("emdash"));
    try t.expectEqual(@as(u21, 0x41), glyphToUnicode("uni0041"));
    try t.expectEqual(@as(u21, 0x1F600), glyphToUnicode("u1F600"));
    try t.expectEqual(@as(u21, 'a'), glyphToUnicode("a.sc"));
    try t.expectEqual(@as(u21, 0), glyphToUnicode("nosuchglyph"));
}

test "encoding tables" {
    const t = std.testing;
    try t.expectEqual(@as(u21, 0x20AC), win_ansi[0x80]);
    try t.expectEqual(@as(u21, 0xE9), win_ansi[0xE9]);
    try t.expectEqual(@as(u21, 0xC4), mac_roman[0x80]);
    try t.expectEqual(@as(u21, 0x2019), standard[0x27]);
    try t.expectEqual(@as(u21, 0xFB02), standard[0xAF]);
    try t.expectEqual(@as(u21, 0xB8), mac_roman[0xFC]);
}
