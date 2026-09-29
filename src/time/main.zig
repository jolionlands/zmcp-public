//! zmcp-time — drop-in replacement for `uvx mcp-server-time`.
//!
//! Tools:
//!   get_current_time(timezone)                                    — ISO-8601 + day_of_week + is_dst
//!   convert_time(source_timezone, time, target_timezone)          — convert HH:MM between zones
//!
//! No external zoneinfo dependency. Carries a small in-process table of common
//! IANA zones with fixed UTC offsets and DST rules (current rule set as of
//! 2026; correct for "today's current time" use). Unknown zones return a
//! clear error instead of guessing.
//!
//! Local-timezone default is UTC; set ZMCP_LOCAL_TZ (an IANA name from the
//! built-in table) to change it.

const std = @import("std");
const mcp = @import("mcp");

const DEFAULT_LOCAL_TZ = "UTC";

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-time", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "get_current_time",
        .description = "Get current time in a specific timezone. IANA name like 'UTC', 'America/New_York', 'Europe/London'. Returns datetime ISO-8601 with offset, day_of_week, is_dst.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "timezone": { "type": "string", "description": "IANA timezone name (e.g., 'America/New_York'). Use UTC if no timezone provided." }
        \\  },
        \\  "required": ["timezone"]
        \\}
        ,
        .handler = handleGetCurrentTime,
        .read_only = true,
    },
    .{
        .name = "convert_time",
        .description = "Convert a wall-clock time between two IANA timezones. Returns source and target datetime + time_difference (e.g. '+14.0h').",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "source_timezone": { "type": "string", "description": "Source IANA timezone name (e.g., 'America/New_York'). Use UTC if no source timezone provided." },
        \\    "time":            { "type": "string", "description": "Time to convert in 24-hour format (HH:MM)." },
        \\    "target_timezone": { "type": "string", "description": "Target IANA timezone name (e.g., 'Asia/Tokyo'). Use UTC if no target timezone provided." }
        \\  },
        \\  "required": ["source_timezone", "time", "target_timezone"]
        \\}
        ,
        .handler = handleConvertTime,
        .read_only = true,
    },
};

// ---------------------------------------------------------------------------
// Timezone table
// ---------------------------------------------------------------------------

/// DST rule kind for a zone.
const DstRule = enum {
    /// No DST observed (UTC, Asia/*, Africa, most of Australia ex SE).
    none,
    /// US/Canada DST: 2nd Sunday in March → 1st Sunday in November.
    us,
    /// EU DST: last Sunday in March → last Sunday in October.
    eu,
    /// Southeast Australia DST (AEST/AEDT etc.): 1st Sun Oct → 1st Sun Apr (S. hemisphere reversal).
    au_se,
    /// New Zealand DST: last Sun Sep → 1st Sun Apr.
    nz,
    /// Chile (Santiago): 1st Sat Sep (24:00) → 1st Sat Apr (24:00). Approximated to Sundays.
    cl,
};

const ZoneInfo = struct {
    /// Standard UTC offset in minutes.
    std_offset_min: i32,
    /// DST shift in minutes when DST active (almost always 60).
    dst_offset_min: i32,
    /// DST rule for the zone.
    rule: DstRule,
};

const ZoneEntry = struct {
    name: []const u8,
    info: ZoneInfo,
};

const zones = [_]ZoneEntry{
    // UTC family
    .{ .name = "UTC", .info = .{ .std_offset_min = 0, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Etc/UTC", .info = .{ .std_offset_min = 0, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "GMT", .info = .{ .std_offset_min = 0, .dst_offset_min = 0, .rule = .none } },

    // Europe (EU rule)
    .{ .name = "Europe/London", .info = .{ .std_offset_min = 0, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Dublin", .info = .{ .std_offset_min = 0, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Lisbon", .info = .{ .std_offset_min = 0, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Paris", .info = .{ .std_offset_min = 60, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Berlin", .info = .{ .std_offset_min = 60, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Madrid", .info = .{ .std_offset_min = 60, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Rome", .info = .{ .std_offset_min = 60, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Amsterdam", .info = .{ .std_offset_min = 60, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Brussels", .info = .{ .std_offset_min = 60, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Vienna", .info = .{ .std_offset_min = 60, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Stockholm", .info = .{ .std_offset_min = 60, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Oslo", .info = .{ .std_offset_min = 60, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Copenhagen", .info = .{ .std_offset_min = 60, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Zurich", .info = .{ .std_offset_min = 60, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Helsinki", .info = .{ .std_offset_min = 120, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Athens", .info = .{ .std_offset_min = 120, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Bucharest", .info = .{ .std_offset_min = 120, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Europe/Warsaw", .info = .{ .std_offset_min = 60, .dst_offset_min = 60, .rule = .eu } },

    // Europe no-DST (Russia, Turkey, Belarus)
    .{ .name = "Europe/Moscow", .info = .{ .std_offset_min = 180, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Europe/Istanbul", .info = .{ .std_offset_min = 180, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Europe/Minsk", .info = .{ .std_offset_min = 180, .dst_offset_min = 0, .rule = .none } },

    // North America (US rule). Hawaii / Arizona / SK no DST.
    .{ .name = "America/New_York", .info = .{ .std_offset_min = -300, .dst_offset_min = 60, .rule = .us } },
    .{ .name = "America/Toronto", .info = .{ .std_offset_min = -300, .dst_offset_min = 60, .rule = .us } },
    .{ .name = "America/Chicago", .info = .{ .std_offset_min = -360, .dst_offset_min = 60, .rule = .us } },
    .{ .name = "America/Mexico_City", .info = .{ .std_offset_min = -360, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "America/Denver", .info = .{ .std_offset_min = -420, .dst_offset_min = 60, .rule = .us } },
    .{ .name = "America/Phoenix", .info = .{ .std_offset_min = -420, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "America/Los_Angeles", .info = .{ .std_offset_min = -480, .dst_offset_min = 60, .rule = .us } },
    .{ .name = "America/San_Francisco", .info = .{ .std_offset_min = -480, .dst_offset_min = 60, .rule = .us } },
    .{ .name = "America/Vancouver", .info = .{ .std_offset_min = -480, .dst_offset_min = 60, .rule = .us } },
    .{ .name = "America/Anchorage", .info = .{ .std_offset_min = -540, .dst_offset_min = 60, .rule = .us } },
    .{ .name = "Pacific/Honolulu", .info = .{ .std_offset_min = -600, .dst_offset_min = 0, .rule = .none } },

    // South America
    .{ .name = "America/Sao_Paulo", .info = .{ .std_offset_min = -180, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "America/Argentina/Buenos_Aires", .info = .{ .std_offset_min = -180, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "America/Santiago", .info = .{ .std_offset_min = -240, .dst_offset_min = 60, .rule = .cl } },
    .{ .name = "America/Bogota", .info = .{ .std_offset_min = -300, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "America/Lima", .info = .{ .std_offset_min = -300, .dst_offset_min = 0, .rule = .none } },

    // Asia (no DST in any of these)
    .{ .name = "Asia/Tokyo", .info = .{ .std_offset_min = 540, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Asia/Seoul", .info = .{ .std_offset_min = 540, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Asia/Shanghai", .info = .{ .std_offset_min = 480, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Asia/Hong_Kong", .info = .{ .std_offset_min = 480, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Asia/Singapore", .info = .{ .std_offset_min = 480, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Asia/Taipei", .info = .{ .std_offset_min = 480, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Asia/Bangkok", .info = .{ .std_offset_min = 420, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Asia/Ho_Chi_Minh", .info = .{ .std_offset_min = 420, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Asia/Jakarta", .info = .{ .std_offset_min = 420, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Asia/Manila", .info = .{ .std_offset_min = 480, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Asia/Kolkata", .info = .{ .std_offset_min = 330, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Asia/Calcutta", .info = .{ .std_offset_min = 330, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Asia/Karachi", .info = .{ .std_offset_min = 300, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Asia/Dubai", .info = .{ .std_offset_min = 240, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Asia/Tel_Aviv", .info = .{ .std_offset_min = 120, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Asia/Jerusalem", .info = .{ .std_offset_min = 120, .dst_offset_min = 60, .rule = .eu } },
    .{ .name = "Asia/Riyadh", .info = .{ .std_offset_min = 180, .dst_offset_min = 0, .rule = .none } },

    // Africa (no DST)
    .{ .name = "Africa/Cairo", .info = .{ .std_offset_min = 120, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Africa/Lagos", .info = .{ .std_offset_min = 60, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Africa/Johannesburg", .info = .{ .std_offset_min = 120, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Africa/Nairobi", .info = .{ .std_offset_min = 180, .dst_offset_min = 0, .rule = .none } },

    // Oceania
    .{ .name = "Australia/Brisbane", .info = .{ .std_offset_min = 600, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Australia/Sydney", .info = .{ .std_offset_min = 600, .dst_offset_min = 60, .rule = .au_se } },
    .{ .name = "Australia/Melbourne", .info = .{ .std_offset_min = 600, .dst_offset_min = 60, .rule = .au_se } },
    .{ .name = "Australia/Hobart", .info = .{ .std_offset_min = 600, .dst_offset_min = 60, .rule = .au_se } },
    .{ .name = "Australia/Adelaide", .info = .{ .std_offset_min = 570, .dst_offset_min = 60, .rule = .au_se } },
    .{ .name = "Australia/Perth", .info = .{ .std_offset_min = 480, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Australia/Darwin", .info = .{ .std_offset_min = 570, .dst_offset_min = 0, .rule = .none } },
    .{ .name = "Pacific/Auckland", .info = .{ .std_offset_min = 720, .dst_offset_min = 60, .rule = .nz } },
    .{ .name = "Pacific/Fiji", .info = .{ .std_offset_min = 720, .dst_offset_min = 0, .rule = .none } },
};

fn lookupZone(name: []const u8) ?ZoneInfo {
    // Case-sensitive — IANA names are case-sensitive.
    for (zones) |z| {
        if (std.mem.eql(u8, z.name, name)) return z.info;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Calendar helpers — operate on the proleptic Gregorian calendar.
// ---------------------------------------------------------------------------

const Date = struct {
    year: i32,
    month: u8, // 1-12
    day: u8, // 1-31
    hour: u8 = 0,
    minute: u8 = 0,
    second: u8 = 0,
};

fn isLeap(y: i32) bool {
    if (@mod(y, 4) != 0) return false;
    if (@mod(y, 100) != 0) return true;
    return @mod(y, 400) == 0;
}

fn daysInMonth(y: i32, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeap(y)) @as(u8, 29) else @as(u8, 28),
        else => 0,
    };
}

/// Convert a UTC Unix timestamp (seconds) to a calendar Date.
fn unixToDate(ts: i64) Date {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, ts)) };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    return .{
        .year = @intCast(yd.year),
        .month = @intFromEnum(md.month),
        .day = md.day_index + 1,
        .hour = ds.getHoursIntoDay(),
        .minute = ds.getMinutesIntoHour(),
        .second = ds.getSecondsIntoMinute(),
    };
}

/// Convert a Date to a UTC Unix timestamp (seconds). Treats the Date as UTC.
fn dateToUnix(d: Date) i64 {
    // Days since 1970-01-01.
    var y: i32 = 1970;
    var days: i64 = 0;
    if (d.year >= 1970) {
        while (y < d.year) : (y += 1) {
            days += if (isLeap(y)) @as(i64, 366) else @as(i64, 365);
        }
    } else {
        while (y > d.year) : (y -= 1) {
            const py = y - 1;
            days -= if (isLeap(py)) @as(i64, 366) else @as(i64, 365);
        }
    }
    var m: u8 = 1;
    while (m < d.month) : (m += 1) {
        days += daysInMonth(d.year, m);
    }
    days += @as(i64, d.day - 1);
    return days * 86400 + @as(i64, d.hour) * 3600 + @as(i64, d.minute) * 60 + d.second;
}

/// 0 = Sunday, 1 = Monday, ..., 6 = Saturday.
fn dayOfWeek(ts: i64) u8 {
    // 1970-01-01 was a Thursday (4).
    const days = @divFloor(ts, 86400);
    const mod7 = @mod(days + 4, 7);
    return @intCast(mod7);
}

fn dowName(d: u8) []const u8 {
    return switch (d) {
        0 => "Sunday",
        1 => "Monday",
        2 => "Tuesday",
        3 => "Wednesday",
        4 => "Thursday",
        5 => "Friday",
        6 => "Saturday",
        else => "Unknown",
    };
}

// ---------------------------------------------------------------------------
// DST decision — operates on the zone's local "naive" date (year/month/day/h/m).
// ---------------------------------------------------------------------------

/// Return the day-of-month of the Nth Sunday in the given (year, month).
/// nth=1 for first Sunday, nth=2 for second, etc.
fn nthSunday(year: i32, month: u8, nth: u8) u8 {
    // ts of yyyy-mm-01 UTC
    const ts = dateToUnix(.{ .year = year, .month = month, .day = 1 });
    const dow = dayOfWeek(ts); // 0 = Sun
    // Days until first Sunday from day 1:
    //  if day 1 is Sunday (dow=0) -> 0 days, first Sun = day 1
    //  else (7 - dow)
    const first_offset: u8 = if (dow == 0) 0 else (7 - dow);
    return first_offset + 1 + (nth - 1) * 7;
}

/// Return the day-of-month of the last Sunday in the given (year, month).
fn lastSunday(year: i32, month: u8) u8 {
    const dim = daysInMonth(year, month);
    // ts of yyyy-mm-DIM UTC
    const ts = dateToUnix(.{ .year = year, .month = month, .day = dim });
    const dow = dayOfWeek(ts); // 0 = Sun
    // Last Sunday is DIM - dow (when dow=0, dim itself is Sunday).
    return dim - dow;
}

/// Decide whether DST is active for a zone at the given local naive date+time.
/// Approximation: we use the local zone's standard wall-clock to look up the
/// boundary. The transition hour (typically 02:00 local) is treated as the
/// instant of switch. The "ambiguous hour" around fall-back is resolved to
/// standard time (the common convention).
fn isDstActive(rule: DstRule, year: i32, month: u8, day: u8, hour: u8) bool {
    switch (rule) {
        .none => return false,
        .us => {
            // 2nd Sun of March 02:00 → 1st Sun of November 02:00.
            const start_day = nthSunday(year, 3, 2);
            const end_day = nthSunday(year, 11, 1);
            return inDstWindowNorthern(year, month, day, hour, 3, start_day, 11, end_day, 2);
        },
        .eu => {
            // Last Sun of March 01:00 UTC ≈ 02:00 CET → Last Sun of October 01:00 UTC.
            // We approximate using local 02:00 transition.
            const start_day = lastSunday(year, 3);
            const end_day = lastSunday(year, 10);
            return inDstWindowNorthern(year, month, day, hour, 3, start_day, 10, end_day, 2);
        },
        .au_se => {
            // SE Australia: 1st Sun of October 02:00 → 1st Sun of April 03:00 (next year side too).
            // Southern hemisphere: DST is active in spring/summer (Oct-Apr).
            const start_day_oct = nthSunday(year, 10, 1);
            const end_day_apr = nthSunday(year, 4, 1);
            // Active if: (month > 10) or (month==10 and day after start_day_oct) or (month < 4)
            //           or (month==4 and day before end_day_apr).
            if (month > 10) return true;
            if (month == 10) {
                if (day < start_day_oct) return false;
                if (day == start_day_oct) return hour >= 2;
                return true;
            }
            if (month < 4) return true;
            if (month == 4) {
                if (day < end_day_apr) return true;
                if (day == end_day_apr) return hour < 3;
                return false;
            }
            return false;
        },
        .nz => {
            // NZ: last Sun of Sep 02:00 → 1st Sun of April 03:00.
            const start_day = lastSunday(year, 9);
            const end_day = nthSunday(year, 4, 1);
            if (month > 9) return true;
            if (month == 9) {
                if (day < start_day) return false;
                if (day == start_day) return hour >= 2;
                return true;
            }
            if (month < 4) return true;
            if (month == 4) {
                if (day < end_day) return true;
                if (day == end_day) return hour < 3;
                return false;
            }
            return false;
        },
        .cl => {
            // Chile: 1st Sat Sep 24:00 ≈ 1st Sun Sep 00:00 → 1st Sat Apr 24:00 ≈ 1st Sun Apr 00:00.
            const start_day = nthSunday(year, 9, 1);
            const end_day = nthSunday(year, 4, 1);
            if (month > 9) return true;
            if (month == 9) {
                return day >= start_day;
            }
            if (month < 4) return true;
            if (month == 4) {
                return day < end_day;
            }
            return false;
        },
    }
}

/// Northern hemisphere DST window: start_month/start_day at transition_hour
/// through end_month/end_day at transition_hour, in the same calendar year.
fn inDstWindowNorthern(
    year: i32,
    month: u8,
    day: u8,
    hour: u8,
    start_month: u8,
    start_day: u8,
    end_month: u8,
    end_day: u8,
    transition_hour: u8,
) bool {
    _ = year;
    // Before start month: out.
    if (month < start_month) return false;
    if (month > end_month) return false;
    // In start month, before transition day: out.
    if (month == start_month) {
        if (day < start_day) return false;
        if (day == start_day) return hour >= transition_hour;
        return true;
    }
    // In end month: out after transition day at transition hour.
    if (month == end_month) {
        if (day < end_day) return true;
        if (day == end_day) return hour < transition_hour;
        return false;
    }
    return true; // middle months
}

// ---------------------------------------------------------------------------
// Effective UTC offset (minutes) for a zone at a given UTC instant.
// ---------------------------------------------------------------------------

fn effectiveOffsetMinUTC(info: ZoneInfo, ts_utc: i64) struct { offset: i32, is_dst: bool } {
    // First compute the local naive datetime assuming standard offset.
    const std_d = unixToDate(ts_utc + @as(i64, info.std_offset_min) * 60);
    const dst_active = isDstActive(info.rule, std_d.year, std_d.month, std_d.day, std_d.hour);
    if (dst_active) {
        return .{ .offset = info.std_offset_min + info.dst_offset_min, .is_dst = true };
    }
    return .{ .offset = info.std_offset_min, .is_dst = false };
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

fn formatLocal(buf: []u8, d: Date, offset_min: i32) ![]u8 {
    const sign: u8 = if (offset_min >= 0) '+' else '-';
    const abs_off = if (offset_min >= 0) offset_min else -offset_min;
    const oh: u32 = @intCast(@divFloor(abs_off, 60));
    const om: u32 = @intCast(@mod(abs_off, 60));
    const year_u: u32 = @intCast(if (d.year < 0) 0 else d.year);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{c}{d:0>2}:{d:0>2}", .{
        year_u, d.month, d.day,
        d.hour, d.minute, d.second,
        sign, oh, om,
    });
}

fn nowSeconds(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    const ms = ts.toMilliseconds();
    return @divFloor(ms, 1000);
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

fn getStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

/// Timezone to use: the explicit argument, else ZMCP_LOCAL_TZ if set and
/// non-empty, else UTC.
fn resolveTz(arg: ?[]const u8, env: ?[]const u8) []const u8 {
    if (arg) |a| return a;
    if (env) |e| {
        const t = std.mem.trim(u8, e, " \t\r\n");
        if (t.len > 0) return t;
    }
    return DEFAULT_LOCAL_TZ;
}

fn handleGetCurrentTime(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const env_tz = mcp.envAlloc(alloc, io, "ZMCP_LOCAL_TZ");
    defer if (env_tz) |e| alloc.free(e);
    const tz = resolveTz(getStr(args, "timezone"), env_tz);
    const info = lookupZone(tz) orelse {
        return .{
            .text = try std.fmt.allocPrint(alloc, "error: unknown timezone '{s}'. zmcp-time carries a curated table of ~60 common IANA zones; if you need a less common one, file a request.", .{tz}),
            .is_error = true,
        };
    };

    const ts = nowSeconds(io);
    const eff = effectiveOffsetMinUTC(info, ts);
    const local_d = unixToDate(ts + @as(i64, eff.offset) * 60);
    var iso_buf: [40]u8 = undefined;
    const iso = try formatLocal(&iso_buf, local_d, eff.offset);
    const dow = dayOfWeek(ts + @as(i64, eff.offset) * 60);

    return .{
        .text = try std.fmt.allocPrint(
            alloc,
            "{{\n  \"timezone\": \"{s}\",\n  \"datetime\": \"{s}\",\n  \"day_of_week\": \"{s}\",\n  \"is_dst\": {s}\n}}",
            .{ tz, iso, dowName(dow), if (eff.is_dst) "true" else "false" },
        ),
    };
}

fn handleConvertTime(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    const src_tz = getStr(args, "source_timezone") orelse return .{
        .text = "error: source_timezone required",
        .is_error = true,
    };
    const tgt_tz = getStr(args, "target_timezone") orelse return .{
        .text = "error: target_timezone required",
        .is_error = true,
    };
    const time_str = getStr(args, "time") orelse return .{
        .text = "error: time required (HH:MM)",
        .is_error = true,
    };

    const src_info = lookupZone(src_tz) orelse return .{
        .text = try std.fmt.allocPrint(alloc, "error: unknown source timezone '{s}'", .{src_tz}),
        .is_error = true,
    };
    const tgt_info = lookupZone(tgt_tz) orelse return .{
        .text = try std.fmt.allocPrint(alloc, "error: unknown target timezone '{s}'", .{tgt_tz}),
        .is_error = true,
    };

    // Parse HH:MM
    const colon = std.mem.indexOfScalar(u8, time_str, ':') orelse return .{
        .text = "error: time must be HH:MM",
        .is_error = true,
    };
    const hh = std.fmt.parseInt(u8, time_str[0..colon], 10) catch return .{
        .text = "error: time must be HH:MM",
        .is_error = true,
    };
    const mm = std.fmt.parseInt(u8, time_str[colon + 1 ..], 10) catch return .{
        .text = "error: time must be HH:MM",
        .is_error = true,
    };
    if (hh >= 24 or mm >= 60) {
        return .{ .text = "error: hours 0-23 and minutes 0-59", .is_error = true };
    }

    // Use today's date in the source timezone as the conversion date.
    const ts_now = nowSeconds(io);
    const src_eff_now = effectiveOffsetMinUTC(src_info, ts_now);
    const src_now_local = unixToDate(ts_now + @as(i64, src_eff_now.offset) * 60);

    // Build local Date in source at HH:MM today.
    const src_local_d: Date = .{
        .year = src_now_local.year,
        .month = src_now_local.month,
        .day = src_now_local.day,
        .hour = hh,
        .minute = mm,
        .second = 0,
    };

    // Compute UTC timestamp for that local source moment using the *standard*
    // offset first, then re-check DST and adjust if needed (sufficient for
    // single-pass disambiguation outside the gap/overlap hour).
    var ts_utc = dateToUnix(src_local_d) - @as(i64, src_info.std_offset_min) * 60;
    var src_eff = effectiveOffsetMinUTC(src_info, ts_utc);
    ts_utc = dateToUnix(src_local_d) - @as(i64, src_eff.offset) * 60;
    src_eff = effectiveOffsetMinUTC(src_info, ts_utc);

    const tgt_eff = effectiveOffsetMinUTC(tgt_info, ts_utc);
    const tgt_local_d = unixToDate(ts_utc + @as(i64, tgt_eff.offset) * 60);

    // Format src/tgt ISO strings.
    var src_iso_buf: [40]u8 = undefined;
    const src_iso = try formatLocal(&src_iso_buf, src_local_d, src_eff.offset);
    var tgt_iso_buf: [40]u8 = undefined;
    const tgt_iso = try formatLocal(&tgt_iso_buf, tgt_local_d, tgt_eff.offset);

    const src_dow = dayOfWeek(ts_utc + @as(i64, src_eff.offset) * 60);
    const tgt_dow = dayOfWeek(ts_utc + @as(i64, tgt_eff.offset) * 60);

    // Time-difference string in the form "+14.0h" / "-3.5h" / "+0.0h".
    const diff_min = tgt_eff.offset - src_eff.offset;
    const diff_abs = if (diff_min >= 0) diff_min else -diff_min;
    const diff_h_int: i32 = @divFloor(diff_abs, 60);
    const diff_m_int: i32 = @mod(diff_abs, 60);
    // Convert minutes-portion into a decimal of an hour, kept to 1 decimal
    // (10/30/45/60). Use the most common simplification: print as N.M where
    // M = (minutes / 6) so 30m -> .5, 45m -> .7.
    const decimal_minute: i32 = @divFloor(diff_m_int, 6);
    const diff_sign: u8 = if (diff_min >= 0) '+' else '-';

    var diff_buf: [16]u8 = undefined;
    const diff_str = try std.fmt.bufPrint(&diff_buf, "{c}{d}.{d}h", .{ diff_sign, diff_h_int, decimal_minute });

    return .{
        .text = try std.fmt.allocPrint(
            alloc,
            "{{\n  \"source\": {{\n    \"timezone\": \"{s}\",\n    \"datetime\": \"{s}\",\n    \"day_of_week\": \"{s}\",\n    \"is_dst\": {s}\n  }},\n  \"target\": {{\n    \"timezone\": \"{s}\",\n    \"datetime\": \"{s}\",\n    \"day_of_week\": \"{s}\",\n    \"is_dst\": {s}\n  }},\n  \"time_difference\": \"{s}\"\n}}",
            .{
                src_tz, src_iso, dowName(src_dow), if (src_eff.is_dst) "true" else "false",
                tgt_tz, tgt_iso, dowName(tgt_dow), if (tgt_eff.is_dst) "true" else "false",
                diff_str,
            },
        ),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "lookupZone resolves common IANA names" {
    try std.testing.expect(lookupZone("Australia/Brisbane") != null);
    try std.testing.expect(lookupZone("America/New_York") != null);
    try std.testing.expect(lookupZone("UTC") != null);
    try std.testing.expect(lookupZone("Europe/London") != null);
    try std.testing.expect(lookupZone("Asia/Tokyo") != null);
    try std.testing.expect(lookupZone("Pacific/Auckland") != null);
    try std.testing.expect(lookupZone("BogusZone") == null);
}

test "dateToUnix / unixToDate roundtrip" {
    const d: Date = .{ .year = 2024, .month = 1, .day = 1 };
    const ts = dateToUnix(d);
    try std.testing.expectEqual(@as(i64, 1704067200), ts);
    const back = unixToDate(ts);
    try std.testing.expectEqual(@as(i32, 2024), back.year);
    try std.testing.expectEqual(@as(u8, 1), back.month);
    try std.testing.expectEqual(@as(u8, 1), back.day);
}

test "dayOfWeek for 2024-01-01 is Monday" {
    const ts = dateToUnix(.{ .year = 2024, .month = 1, .day = 1 });
    try std.testing.expectEqual(@as(u8, 1), dayOfWeek(ts));
}

test "nthSunday/lastSunday for 2024" {
    // 2024-03-10 is the second Sunday of March.
    try std.testing.expectEqual(@as(u8, 10), nthSunday(2024, 3, 2));
    // 2024-11-03 is the first Sunday of November.
    try std.testing.expectEqual(@as(u8, 3), nthSunday(2024, 11, 1));
    // 2024-03-31 is the last Sunday of March.
    try std.testing.expectEqual(@as(u8, 31), lastSunday(2024, 3));
    // 2024-10-27 is the last Sunday of October.
    try std.testing.expectEqual(@as(u8, 27), lastSunday(2024, 10));
}

test "US DST active in July, inactive in January" {
    try std.testing.expect(isDstActive(.us, 2024, 7, 4, 12));
    try std.testing.expect(!isDstActive(.us, 2024, 1, 15, 12));
    try std.testing.expect(!isDstActive(.us, 2024, 12, 25, 12));
}

test "EU DST active in July, inactive in January" {
    try std.testing.expect(isDstActive(.eu, 2024, 7, 1, 12));
    try std.testing.expect(!isDstActive(.eu, 2024, 1, 1, 12));
}

test "AU_SE DST: active Dec, inactive July" {
    try std.testing.expect(isDstActive(.au_se, 2024, 12, 25, 12));
    try std.testing.expect(!isDstActive(.au_se, 2024, 7, 1, 12));
}

test "Brisbane never observes DST" {
    const info = lookupZone("Australia/Brisbane").?;
    // Pick midyear and midwinter — neither should show is_dst.
    const ts_jul = dateToUnix(.{ .year = 2024, .month = 7, .day = 1 });
    const ts_dec = dateToUnix(.{ .year = 2024, .month = 12, .day = 25 });
    try std.testing.expect(!effectiveOffsetMinUTC(info, ts_jul).is_dst);
    try std.testing.expect(!effectiveOffsetMinUTC(info, ts_dec).is_dst);
}

test "formatLocal produces ISO-8601 with offset" {
    var buf: [40]u8 = undefined;
    const d: Date = .{ .year = 2024, .month = 1, .day = 1, .hour = 12, .minute = 34, .second = 56 };
    const s = try formatLocal(&buf, d, 600); // +10:00
    try std.testing.expectEqualStrings("2024-01-01T12:34:56+10:00", s);
}

test "resolveTz: argument, then ZMCP_LOCAL_TZ, then UTC" {
    try std.testing.expectEqualStrings("Asia/Tokyo", resolveTz("Asia/Tokyo", "Europe/London"));
    try std.testing.expectEqualStrings("Europe/London", resolveTz(null, " Europe/London\n"));
    try std.testing.expectEqualStrings("UTC", resolveTz(null, "  "));
    try std.testing.expectEqualStrings("UTC", resolveTz(null, null));
    try std.testing.expect(lookupZone(DEFAULT_LOCAL_TZ) != null);
}
