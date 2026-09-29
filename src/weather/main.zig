//! zmcp-weather — pure-Zig port of @dangahagan/weather-mcp.
//!
//! Tools (same names/schemas as the reference):
//!   get_forecast            — NOAA (US) or Open-Meteo (global) forecast
//!   get_current_conditions  — NOAA latest observation (US)
//!   get_alerts              — NOAA active alerts (US)
//!   get_historical_weather  — Open-Meteo archive / NOAA recent observations
//!   check_service_status    — NOAA + Open-Meteo health probe
//!   search_location         — Open-Meteo geocoding
//!   get_air_quality         — Open-Meteo air quality (AQI, pollutants, UV)
//!   get_marine_conditions   — Open-Meteo marine (waves, swell, currents)
//!   get_weather_imagery     — RainViewer precipitation radar tiles
//!   get_lightning_activity  — Blitzortung (MQTT transport unsupported here)
//!   get_river_conditions    — NOAA NWPS river gauges (US)
//!   get_wildfire_info       — NIFC WFIGS ArcGIS fire perimeters (US)
//!
//! Network access goes through the FetchFn seam so tests inject canned HTTP.
//!
//! Parity deviations vs the reference (documented in the port):
//!   - No response caching, no retry/backoff, no ENABLED_TOOLS filtering.
//!   - include_severe_weather / include_fire_weather / include_normals flags
//!     are accepted but reported as unavailable (gridpoint/NCEI pipelines
//!     not ported).
//!   - get_marine_conditions always uses Open-Meteo (reference tries NOAA
//!     gridpoints first for Great Lakes/coastal bays, then falls back).
//!   - get_lightning_activity: the reference streams Blitzortung over a
//!     plaintext MQTT broker; this port has no MQTT client, so the tool
//!     validates args, then returns a clear error. The statistics/safety
//!     logic is ported and unit-tested.
//!   - Timestamps are shown in the ISO form returned by the APIs (no
//!     local-timezone conversion).

const std = @import("std");
const mcp = @import("mcp");

const UA_PRODUCT = "zmcp-weather/0.1.0";

pub fn main(init: std.process.Init) !void {
    const arena = init.gpa;
    const io = init.io;
    try mcp.run(arena, io, .{ .name = "zmcp-weather", .version = "0.1.0" }, &tool_table);
}

const tool_table = [_]mcp.ToolDef{
    .{
        .name = "get_forecast",
        .description = "Get future weather forecast for a location (global coverage). Use this for upcoming weather predictions (e.g., \"tomorrow\", \"this week\", \"next 7 days\", \"hourly forecast\"). Returns forecast data including temperature, precipitation, wind, conditions, and sunrise/sunset times. Supports both daily and hourly granularity. Automatically selects best data source: NOAA for US locations (more detailed), Open-Meteo for international locations. For current weather, use get_current_conditions. For past weather, use get_historical_weather. If this tool returns an error, check the error message for status page links and consider using check_service_status to verify API availability.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "latitude": { "type": "number", "description": "Latitude of the location (-90 to 90)", "minimum": -90, "maximum": 90 },
        \\    "longitude": { "type": "number", "description": "Longitude of the location (-180 to 180)", "minimum": -180, "maximum": 180 },
        \\    "days": { "type": "number", "description": "Number of days to include in forecast (1-16 for global, 1-7 for US NOAA, default: 7)", "minimum": 1, "maximum": 16, "default": 7 },
        \\    "granularity": { "type": "string", "description": "Forecast granularity: \"daily\" for day/night periods or \"hourly\" for hour-by-hour detail (default: \"daily\")", "enum": ["daily", "hourly"], "default": "daily" },
        \\    "include_precipitation_probability": { "type": "boolean", "description": "Include precipitation probability in the forecast output (default: true)", "default": true },
        \\    "include_severe_weather": { "type": "boolean", "description": "Include severe weather probabilities such as thunderstorm chance, wind gust probabilities, and tropical storm/hurricane risks (default: false, US/NOAA only)", "default": false },
        \\    "include_normals": { "type": "boolean", "description": "Include climate normals (30-year averages) for comparison with forecasted temperatures (default: false, daily forecasts only). Shows normal high/low and departure from normal for the first forecast day.", "default": false },
        \\    "source": { "type": "string", "description": "Data source: \"auto\" (default, selects NOAA for US or Open-Meteo for international), \"noaa\" (US only), or \"openmeteo\" (global)", "enum": ["auto", "noaa", "openmeteo"], "default": "auto" }
        \\  },
        \\  "required": ["latitude", "longitude"]
        \\}
        ,
        .handler = handleGetForecast,
        .read_only = true,
    },
    .{
        .name = "get_current_conditions",
        .description = "Get the most recent weather observation for a location (US only). Use this for current weather or when asking about \"today's weather\", \"right now\", or recent conditions without a specific historical date range. Returns the latest observation from the nearest weather station. Optionally includes fire weather indices (Haines Index, Grassland Fire Danger, Red Flag Threat) when requested. For specific past dates or date ranges, use get_historical_weather instead. If this tool returns an error, check the error message for status page links and consider using check_service_status to verify API availability.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "latitude": { "type": "number", "description": "Latitude of the location (-90 to 90)", "minimum": -90, "maximum": 90 },
        \\    "longitude": { "type": "number", "description": "Longitude of the location (-180 to 180)", "minimum": -180, "maximum": 180 },
        \\    "include_fire_weather": { "type": "boolean", "description": "Include fire weather indices (Haines Index, Grassland Fire Danger, Red Flag Threat) in the response (default: false, US only)", "default": false },
        \\    "include_normals": { "type": "boolean", "description": "Include climate normals (30-year averages) for comparison with current conditions (default: false). Shows normal high/low temperatures and precipitation, with departure from normal.", "default": false }
        \\  },
        \\  "required": ["latitude", "longitude"]
        \\}
        ,
        .handler = handleGetCurrentConditions,
        .read_only = true,
    },
    .{
        .name = "get_alerts",
        .description = "Get active weather alerts, watches, warnings, and advisories for a location (US only). Use this for safety-critical weather information when asked about \"any alerts?\", \"weather warnings?\", \"is it safe?\", \"dangerous weather?\", or \"weather watches?\". Returns severity, urgency, certainty, effective/expiration times, and affected areas. For forecast data, use get_forecast instead. If this tool returns an error, check the error message for status page links and consider using check_service_status to verify API availability.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "latitude": { "type": "number", "description": "Latitude of the location (-90 to 90)", "minimum": -90, "maximum": 90 },
        \\    "longitude": { "type": "number", "description": "Longitude of the location (-180 to 180)", "minimum": -180, "maximum": 180 },
        \\    "active_only": { "type": "boolean", "description": "Whether to show only active alerts (default: true)", "default": true }
        \\  },
        \\  "required": ["latitude", "longitude"]
        \\}
        ,
        .handler = handleGetAlerts,
        .read_only = true,
    },
    .{
        .name = "get_historical_weather",
        .description = "Get historical weather data for a specific date range in the past. Use this when the user asks about weather on specific past dates (e.g., \"yesterday\", \"last week\", \"November 4, 2024\", \"30 years ago\"). Automatically uses NOAA API for recent dates (last 7 days, US only) or Open-Meteo API for older dates (worldwide, back to 1940). Do NOT use for current conditions - use get_current_conditions instead. If this tool returns an error, check the error message for status page links and consider using check_service_status to verify API availability.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "latitude": { "type": "number", "description": "Latitude of the location (-90 to 90)", "minimum": -90, "maximum": 90 },
        \\    "longitude": { "type": "number", "description": "Longitude of the location (-180 to 180)", "minimum": -180, "maximum": 180 },
        \\    "start_date": { "type": "string", "description": "Start date in ISO format (YYYY-MM-DD or ISO 8601 datetime)" },
        \\    "end_date": { "type": "string", "description": "End date in ISO format (YYYY-MM-DD or ISO 8601 datetime)" },
        \\    "limit": { "type": "number", "description": "Maximum number of observations to return (default: 168 for one week of hourly data)", "minimum": 1, "maximum": 500, "default": 168 }
        \\  },
        \\  "required": ["latitude", "longitude", "start_date", "end_date"]
        \\}
        ,
        .handler = handleGetHistoricalWeather,
        .read_only = true,
    },
    .{
        .name = "check_service_status",
        .description = "Check the operational status of the NOAA and Open-Meteo weather APIs. Use this when experiencing errors or to proactively verify service availability before making weather data requests. Returns current status, helpful messages, and links to official status pages.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {},
        \\  "required": []
        \\}
        ,
        .handler = handleCheckServiceStatus,
        .read_only = true,
    },
    .{
        .name = "search_location",
        .description = "Search for locations by name to get coordinates for weather queries. Use this when the user provides a location name instead of coordinates (e.g., \"Paris\", \"New York\", \"Tokyo\", \"San Francisco, CA\"). Returns location matches with coordinates, timezone, elevation, and other metadata. Enables natural language location queries like \"What's the weather in Paris?\" by converting location names to coordinates.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "query": { "type": "string", "description": "Location name to search for (e.g., \"Paris\", \"New York, NY\", \"Tokyo\")" },
        \\    "limit": { "type": "number", "description": "Maximum number of results to return (1-100, default: 5)", "minimum": 1, "maximum": 100, "default": 5 }
        \\  },
        \\  "required": ["query"]
        \\}
        ,
        .handler = handleSearchLocation,
        .read_only = true,
    },
    .{
        .name = "get_air_quality",
        .description = "Get air quality data including AQI (Air Quality Index), pollutant concentrations, and UV index for a location (global coverage). Use this when asked about \"air quality\", \"pollution\", \"AQI\", \"UV index\", \"safe to exercise outside\", or health-related environmental conditions. Returns current conditions and optional hourly forecast. Shows appropriate AQI scale (US AQI for US locations, European EAQI elsewhere) with health recommendations. Pollutants include PM2.5, PM10, ozone, NO2, SO2, and CO.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "latitude": { "type": "number", "description": "Latitude of the location (-90 to 90)", "minimum": -90, "maximum": 90 },
        \\    "longitude": { "type": "number", "description": "Longitude of the location (-180 to 180)", "minimum": -180, "maximum": 180 },
        \\    "forecast": { "type": "boolean", "description": "Include hourly air quality forecast for next 5 days (default: false, shows current only)", "default": false }
        \\  },
        \\  "required": ["latitude", "longitude"]
        \\}
        ,
        .handler = handleGetAirQuality,
        .read_only = true,
    },
    .{
        .name = "get_marine_conditions",
        .description = "Get marine conditions including wave height, swell, ocean currents, and sea state for a location (global coverage). Use this when asked about \"ocean conditions\", \"wave height\", \"surf conditions\", \"safe to boat\", \"marine forecast\", \"swell\", or \"sea state\". Returns current conditions and optional daily/hourly forecast. Includes significant wave height, wind waves, swell, wave period, and ocean currents. Shows safety assessment for maritime activities. NOTE: Data has limited accuracy in coastal areas and is NOT suitable for coastal navigation - always consult official marine forecasts.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "latitude": { "type": "number", "description": "Latitude of the location (-90 to 90)", "minimum": -90, "maximum": 90 },
        \\    "longitude": { "type": "number", "description": "Longitude of the location (-180 to 180)", "minimum": -180, "maximum": 180 },
        \\    "forecast": { "type": "boolean", "description": "Include marine forecast for next 5 days (default: false, shows current only)", "default": false }
        \\  },
        \\  "required": ["latitude", "longitude"]
        \\}
        ,
        .handler = handleGetMarineConditions,
        .read_only = true,
    },
    .{
        .name = "get_weather_imagery",
        .description = "Get weather imagery including radar, satellite, and precipitation maps for a location (global coverage). Use this when asked about \"show radar\", \"satellite image\", \"precipitation map\", \"weather map\", \"animated radar\", or \"what does radar show\". Returns image URLs with timestamps for current or animated weather visualization. Supports precipitation radar (global via RainViewer). Includes disclaimer about data delays and official forecast consultation. For numerical forecast data, use get_forecast instead.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "latitude": { "type": "number", "description": "Latitude of the location (-90 to 90)", "minimum": -90, "maximum": 90 },
        \\    "longitude": { "type": "number", "description": "Longitude of the location (-180 to 180)", "minimum": -180, "maximum": 180 },
        \\    "type": { "type": "string", "description": "Type of imagery: \"radar\", \"satellite\", or \"precipitation\" (default: \"precipitation\")", "enum": ["radar", "satellite", "precipitation"], "default": "precipitation" },
        \\    "animated": { "type": "boolean", "description": "Return animated frames showing progression over time (default: false)", "default": false },
        \\    "layers": { "type": "array", "description": "Optional layers to include in imagery (future enhancement)", "items": { "type": "string" } }
        \\  },
        \\  "required": ["latitude", "longitude", "type"]
        \\}
        ,
        .handler = handleGetWeatherImagery,
        .read_only = true,
    },
    .{
        .name = "get_lightning_activity",
        .description = "Get real-time lightning strike activity and safety assessment for a location (global coverage). Use this when asked about \"lightning nearby\", \"lightning strikes\", \"thunderstorm activity\", \"is it safe from lightning\", or \"lightning danger\". Returns recent strikes within specified radius and time window, including distance, polarity, intensity, and critical safety recommendations. Provides 4-level safety assessment (safe/elevated/high/extreme) based on proximity. SAFETY-CRITICAL tool for outdoor activities and severe weather monitoring.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "latitude": { "type": "number", "description": "Latitude of the location (-90 to 90)", "minimum": -90, "maximum": 90 },
        \\    "longitude": { "type": "number", "description": "Longitude of the location (-180 to 180)", "minimum": -180, "maximum": 180 },
        \\    "radius": { "type": "number", "description": "Search radius in kilometers (1-500, default: 100)", "minimum": 1, "maximum": 500, "default": 100 },
        \\    "timeWindow": { "type": "number", "description": "Time window in minutes for historical strikes (5-120, default: 60)", "minimum": 5, "maximum": 120, "default": 60 }
        \\  },
        \\  "required": ["latitude", "longitude"]
        \\}
        ,
        .handler = handleGetLightningActivity,
        .read_only = true,
    },
    .{
        .name = "get_river_conditions",
        .description = "Monitor river levels and flood status for a location (US only). Use this when asked about \"river flooding\", \"river level\", \"flood stage\", \"streamflow\", \"safe to kayak\", or \"river conditions\". Returns current river gauge data within specified radius including river stage, flow rate, flood category levels (action/minor/moderate/major), and forecasted conditions. Provides safety assessment based on flood stages. SAFETY-CRITICAL tool for flood-prone areas and water recreation.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "latitude": { "type": "number", "description": "Latitude of the location (-90 to 90)", "minimum": -90, "maximum": 90 },
        \\    "longitude": { "type": "number", "description": "Longitude of the location (-180 to 180)", "minimum": -180, "maximum": 180 },
        \\    "radius": { "type": "number", "description": "Search radius in kilometers (1-500, default: 50)", "minimum": 1, "maximum": 500, "default": 50 }
        \\  },
        \\  "required": ["latitude", "longitude"]
        \\}
        ,
        .handler = handleGetRiverConditions,
        .read_only = true,
    },
    .{
        .name = "get_wildfire_info",
        .description = "Monitor active wildfires and fire perimeters for a location (US focus). Use this when asked about \"wildfires nearby\", \"fire danger\", \"active fires\", \"wildfire smoke\", \"fire perimeters\", or \"evacuation risk\". Returns active wildfire information within specified radius including fire name, size, containment percentage, distance from location, and safety assessment. Provides critical evacuation awareness and air quality impact information. SAFETY-CRITICAL tool for wildfire-prone areas.",
        .input_schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "latitude": { "type": "number", "description": "Latitude of the location (-90 to 90)", "minimum": -90, "maximum": 90 },
        \\    "longitude": { "type": "number", "description": "Longitude of the location (-180 to 180)", "minimum": -180, "maximum": 180 },
        \\    "radius": { "type": "number", "description": "Search radius in kilometers (1-500, default: 100)", "minimum": 1, "maximum": 500, "default": 100 }
        \\  },
        \\  "required": ["latitude", "longitude"]
        \\}
        ,
        .handler = handleGetWildfireInfo,
        .read_only = true,
    },
};

// ---------------------------------------------------------------------------
// HTTP seam — all network access goes through FetchFn so tests inject canned
// responses. Real implementation follows the src/rss/main.zig pattern.
// ---------------------------------------------------------------------------

pub const HttpResp = struct {
    status: u16,
    body: []u8,
};

pub const FetchFn = *const fn (
    alloc: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
) anyerror!HttpResp;

fn httpsGet(alloc: std.mem.Allocator, io: std.Io, url: []const u8) !HttpResp {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();
    const ua_owned = try mcp.userAgent(alloc, io, UA_PRODUCT);
    defer alloc.free(ua_owned);

    var resp_buf: std.Io.Writer.Allocating = .init(alloc);
    defer resp_buf.deinit();
    var decompress_buf: [128 * 1024]u8 = undefined;

    const fetch_res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &resp_buf.writer,
        .method = .GET,
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = ua_owned },
            .{ .name = "Accept", .value = "application/json, application/geo+json" },
        },
        .decompress_buffer = &decompress_buf,
    });

    return .{
        .status = @intFromEnum(fetch_res.status),
        .body = try alloc.dupe(u8, resp_buf.written()),
    };
}

// ---------------------------------------------------------------------------
// Argument extraction helpers
// ---------------------------------------------------------------------------

fn argNum(args: std.json.Value, key: []const u8) ?f64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn argStr(args: std.json.Value, key: []const u8) ?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn argBool(args: std.json.Value, key: []const u8, default: bool) bool {
    if (args != .object) return default;
    const v = args.object.get(key) orelse return default;
    return if (v == .bool) v.bool else default;
}

/// Positive-integer argument with strict validation like the reference
/// (validatePositiveInteger): null when absent, error otherwise.
fn argPosInt(args: std.json.Value, key: []const u8, min: i64, max: i64) !?i64 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    const n: i64 = switch (v) {
        .integer => |i| i,
        .float => |f| blk: {
            if (f != @trunc(f)) return error.InvalidInteger;
            break :blk @intFromFloat(f);
        },
        else => return error.InvalidType,
    };
    if (n < min or n > max) return error.OutOfRange;
    return n;
}

fn getCoords(alloc: std.mem.Allocator, args: std.json.Value) !struct { lat: f64, lon: f64 } {
    _ = alloc;
    const lat = argNum(args, "latitude") orelse return error.MissingCoordinates;
    const lon = argNum(args, "longitude") orelse return error.MissingCoordinates;
    if (lat < -90 or lat > 90) return error.InvalidLatitude;
    if (lon < -180 or lon > 180) return error.InvalidLongitude;
    return .{ .lat = lat, .lon = lon };
}

fn clampContainment(value: f64) f64 {
    if (!std.math.isFinite(value)) return 0;
    return @max(0.0, @min(100.0, value));
}

fn coordsError(alloc: std.mem.Allocator, err: anyerror) !mcp.ToolResult {
    const msg = switch (err) {
        error.MissingCoordinates => "Invalid arguments: expected object with latitude and longitude",
        error.InvalidLatitude => "Invalid latitude: must be between -90 and 90.",
        error.InvalidLongitude => "Invalid longitude: must be between -180 and 180.",
        else => @errorName(err),
    };
    return .{ .text = try alloc.dupe(u8, msg), .is_error = true };
}

// ---------------------------------------------------------------------------
// URL builders (pure, unit-tested)
// ---------------------------------------------------------------------------

fn writePctEncoded(w: *std.Io.Writer, s: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        const unreserved = std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            try w.writeByte(c);
        } else if (c == ' ') {
            try w.writeAll("%20");
        } else {
            try w.writeByte('%');
            try w.writeByte(hex[c >> 4]);
            try w.writeByte(hex[c & 0xF]);
        }
    }
}

fn geocodeUrl(buf: []u8, query: []const u8, limit: i64) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("https://geocoding-api.open-meteo.com/v1/search?name=");
    try writePctEncoded(&w, query);
    try w.print("&count={d}&language=en&format=json", .{limit});
    return w.buffered();
}

fn omForecastUrl(buf: []u8, lat: f64, lon: f64, days: i64, hourly: bool) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.print("https://api.open-meteo.com/v1/forecast?latitude={d:.4}&longitude={d:.4}&forecast_days={d}", .{ lat, lon, days });
    try w.writeAll("&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch&timezone=auto");
    try w.writeAll("&daily=weather_code,temperature_2m_max,temperature_2m_min,apparent_temperature_max,apparent_temperature_min,sunrise,sunset,daylight_duration,sunshine_duration,uv_index_max,precipitation_sum,rain_sum,showers_sum,snowfall_sum,precipitation_hours,precipitation_probability_max,wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant");
    if (hourly) {
        try w.writeAll("&hourly=temperature_2m,relative_humidity_2m,dewpoint_2m,apparent_temperature,precipitation_probability,precipitation,rain,showers,snowfall,snow_depth,weather_code,pressure_msl,cloud_cover,visibility,wind_speed_10m,wind_direction_10m,wind_gusts_10m,uv_index,is_day");
    }
    return w.buffered();
}

fn omArchiveUrl(buf: []u8, lat: f64, lon: f64, start_date: []const u8, end_date: []const u8, hourly: bool) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.print("https://archive-api.open-meteo.com/v1/archive?latitude={d:.4}&longitude={d:.4}&start_date={s}&end_date={s}", .{ lat, lon, start_date, end_date });
    try w.writeAll("&temperature_unit=fahrenheit&wind_speed_unit=mph&precipitation_unit=inch&timezone=auto");
    if (hourly) {
        try w.writeAll("&hourly=temperature_2m,relative_humidity_2m,dewpoint_2m,apparent_temperature,precipitation,rain,snowfall,weather_code,pressure_msl,cloud_cover,wind_speed_10m,wind_direction_10m,wind_gusts_10m");
    } else {
        try w.writeAll("&daily=temperature_2m_max,temperature_2m_min,temperature_2m_mean,apparent_temperature_max,apparent_temperature_min,precipitation_sum,rain_sum,snowfall_sum,precipitation_hours,weather_code,wind_speed_10m_max,wind_gusts_10m_max,wind_direction_10m_dominant");
    }
    return w.buffered();
}

const AQ_FIELDS = "pm10,pm2_5,carbon_monoxide,nitrogen_dioxide,sulphur_dioxide,ozone,aerosol_optical_depth,dust,uv_index,uv_index_clear_sky,ammonia,european_aqi,european_aqi_pm2_5,european_aqi_pm10,european_aqi_nitrogen_dioxide,european_aqi_ozone,european_aqi_sulphur_dioxide,us_aqi,us_aqi_pm2_5,us_aqi_pm10,us_aqi_nitrogen_dioxide,us_aqi_ozone,us_aqi_sulphur_dioxide,us_aqi_carbon_monoxide";

fn omAirQualityUrl(buf: []u8, lat: f64, lon: f64, forecast_days: ?i64) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.print("https://air-quality-api.open-meteo.com/v1/air-quality?latitude={d:.4}&longitude={d:.4}&timezone=auto", .{ lat, lon });
    try w.print("&current={s}", .{AQ_FIELDS});
    if (forecast_days) |d| {
        try w.print("&forecast_days={d}&hourly={s}", .{ d, AQ_FIELDS });
    }
    return w.buffered();
}

const MARINE_FIELDS = "wave_height,wave_direction,wave_period,wind_wave_height,wind_wave_direction,wind_wave_period,wind_wave_peak_period,swell_wave_height,swell_wave_direction,swell_wave_period,swell_wave_peak_period,ocean_current_velocity,ocean_current_direction";
const MARINE_DAILY_FIELDS = "wave_height_max,wave_direction_dominant,wave_period_max,wind_wave_height_max,wind_wave_direction_dominant,wind_wave_period_max,wind_wave_peak_period_max,swell_wave_height_max,swell_wave_direction_dominant,swell_wave_period_max,swell_wave_peak_period_max";

fn omMarineUrl(buf: []u8, lat: f64, lon: f64, forecast_days: ?i64) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.print("https://marine-api.open-meteo.com/v1/marine?latitude={d:.4}&longitude={d:.4}&timezone=auto", .{ lat, lon });
    try w.print("&current={s}", .{MARINE_FIELDS});
    if (forecast_days) |d| {
        try w.print("&forecast_days={d}&hourly={s}&daily={s}", .{ d, MARINE_FIELDS, MARINE_DAILY_FIELDS });
    }
    return w.buffered();
}

fn noaaPointsUrl(buf: []u8, lat: f64, lon: f64) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.print("https://api.weather.gov/points/{d:.4},{d:.4}", .{ lat, lon });
    return w.buffered();
}

fn noaaAlertsUrl(buf: []u8, lat: f64, lon: f64, active_only: bool) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (active_only) {
        try w.print("https://api.weather.gov/alerts/active?point={d:.4},{d:.4}", .{ lat, lon });
    } else {
        try w.print("https://api.weather.gov/alerts?point={d:.4},{d:.4}", .{ lat, lon });
    }
    return w.buffered();
}

fn nwpsGaugesUrl(buf: []u8, west: f64, south: f64, east: f64, north: f64) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.print("https://api.water.noaa.gov/nwps/v1/gauges?west={d:.4}&south={d:.4}&east={d:.4}&north={d:.4}", .{ west, south, east, north });
    return w.buffered();
}

fn nifcQueryUrl(buf: []u8, west: f64, south: f64, east: f64, north: f64) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/services/WFIGS_Interagency_Perimeters_Current/FeatureServer/0/query?");
    try w.writeAll("f=json&geometryType=esriGeometryEnvelope&spatialRel=esriSpatialRelIntersects&outFields=*&returnGeometry=true&returnCentroid=false&returnExceededLimitFeatures=false&maxAllowableOffset=0.0001&where=1%3D1");
    try w.print("&geometry={d:.4},{d:.4},{d:.4},{d:.4}", .{ west, south, east, north });
    return w.buffered();
}

const RAINVIEWER_URL = "https://api.rainviewer.com/public/weather-maps.json";

/// Web-Mercator tile URL for a RainViewer frame path at the given coordinate.
fn rainviewerTileUrl(buf: []u8, path: []const u8, lat: f64, lon: f64, zoom: i32) ![]const u8 {
    const max_lat = 85.05112878;
    const clamped = @max(-max_lat, @min(max_lat, lat));
    const n = std.math.pow(f64, 2, @floatFromInt(zoom));
    const x: i64 = @intFromFloat(@floor(((lon + 180.0) / 360.0) * n));
    const lat_rad = clamped * std.math.pi / 180.0;
    const y_f = (1.0 - @log(@tan(lat_rad) + 1.0 / @cos(lat_rad)) / std.math.pi) / 2.0 * n;
    const y: i64 = @intFromFloat(@floor(y_f));
    var w: std.Io.Writer = .fixed(buf);
    try w.print("https://tilecache.rainviewer.com{s}/512/{d}/{d}/{d}/4/1_1.png", .{ path, zoom, x, y });
    return w.buffered();
}

// ---------------------------------------------------------------------------
// Pure domain helpers (unit-tested)
// ---------------------------------------------------------------------------

/// Bounding-box US check from the reference forecastHandler.
fn isInUS(lat: f64, lon: f64) bool {
    const continental = lat >= 24.5 and lat <= 49.4 and lon >= -125.0 and lon <= -66.9;
    const alaska = lat >= 51.0 and lat <= 71.4 and lon >= -180.0 and lon <= -129.9;
    const hawaii = lat >= 18.9 and lat <= 28.5 and lon >= -178.4 and lon <= -154.8;
    const pr = lat >= 17.9 and lat <= 18.5 and lon >= -67.3 and lon <= -65.2;
    return continental or alaska or hawaii or pr;
}

/// US-AQI region check from utils/airQuality.js.
fn shouldUseUSAQI(lat: f64, lon: f64) bool {
    const contiguous = lat >= 24 and lat <= 49 and lon >= -125 and lon <= -66;
    const alaska = lat >= 51 and lat <= 71 and lon >= -180 and lon <= -130;
    const hawaii = lat >= 18 and lat <= 28 and lon >= -160 and lon <= -154;
    const pr = lat >= 17.5 and lat <= 18.5 and lon >= -67.5 and lon <= -65.5;
    const usvi = lat >= 17.5 and lat <= 18.5 and lon >= -65.5 and lon <= -64.5;
    const guam = lat >= 13 and lat <= 14 and lon >= 144 and lon <= 145;
    return contiguous or alaska or hawaii or pr or usvi or guam;
}

/// Haversine distance in km (utils/distance.js).
fn haversineKm(lat1: f64, lon1: f64, lat2: f64, lon2: f64) f64 {
    const r = 6371.0;
    const dlat = (lat2 - lat1) * std.math.pi / 180.0;
    const dlon = (lon2 - lon1) * std.math.pi / 180.0;
    const a = @sin(dlat / 2) * @sin(dlat / 2) +
        @cos(lat1 * std.math.pi / 180.0) * @cos(lat2 * std.math.pi / 180.0) *
            @sin(dlon / 2) * @sin(dlon / 2);
    return r * 2 * std.math.atan2(@sqrt(a), @sqrt(1 - a));
}

/// WMO weather interpretation code table (services/openmeteo.js).
fn weatherDescription(code: i64) []const u8 {
    return switch (code) {
        0 => "Clear sky",
        1 => "Mainly clear",
        2 => "Partly cloudy",
        3 => "Overcast",
        45 => "Foggy",
        48 => "Depositing rime fog",
        51 => "Light drizzle",
        53 => "Moderate drizzle",
        55 => "Dense drizzle",
        56 => "Light freezing drizzle",
        57 => "Dense freezing drizzle",
        61 => "Slight rain",
        63 => "Moderate rain",
        65 => "Heavy rain",
        66 => "Light freezing rain",
        67 => "Heavy freezing rain",
        71 => "Slight snow",
        73 => "Moderate snow",
        75 => "Heavy snow",
        77 => "Snow grains",
        80 => "Slight rain showers",
        81 => "Moderate rain showers",
        82 => "Violent rain showers",
        85 => "Slight snow showers",
        86 => "Heavy snow showers",
        95 => "Thunderstorm",
        96 => "Thunderstorm with slight hail",
        99 => "Thunderstorm with heavy hail",
        else => "Unknown",
    };
}

const CARDINALS = [_][]const u8{ "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW" };

fn cardinalDirection(degrees: f64) []const u8 {
    const norm = @mod(degrees + 360.0, 360.0);
    const idx: usize = @intFromFloat(@mod(@round(norm / 22.5), 16.0));
    return CARDINALS[idx];
}

const AqiCategory = struct {
    level: []const u8,
    description: []const u8,
    health_implications: []const u8,
    cautionary: []const u8,
    color: []const u8,
};

fn usAqiCategory(aqi: f64) AqiCategory {
    if (aqi <= 50) return .{ .level = "Good", .description = "Air quality is satisfactory", .health_implications = "Air quality is considered satisfactory, and air pollution poses little or no risk.", .cautionary = "None", .color = "Green" };
    if (aqi <= 100) return .{ .level = "Moderate", .description = "Air quality is acceptable", .health_implications = "Air quality is acceptable; however, unusually sensitive people may experience minor respiratory symptoms.", .cautionary = "Unusually sensitive people should consider reducing prolonged outdoor exertion.", .color = "Yellow" };
    if (aqi <= 150) return .{ .level = "Unhealthy for Sensitive Groups", .description = "Sensitive groups may experience health effects", .health_implications = "Members of sensitive groups may experience health effects. The general public is not likely to be affected.", .cautionary = "Children, elderly, and people with respiratory conditions should limit prolonged outdoor exertion.", .color = "Orange" };
    if (aqi <= 200) return .{ .level = "Unhealthy", .description = "Everyone may begin to experience health effects", .health_implications = "Everyone may begin to experience health effects; sensitive groups may experience more serious health effects.", .cautionary = "Everyone should limit prolonged outdoor exertion, especially sensitive groups.", .color = "Red" };
    if (aqi <= 300) return .{ .level = "Very Unhealthy", .description = "Health alert: everyone may experience serious effects", .health_implications = "Health alert: everyone may experience more serious health effects.", .cautionary = "Everyone should avoid prolonged outdoor exertion. Sensitive groups should remain indoors.", .color = "Purple" };
    return .{ .level = "Hazardous", .description = "Health warnings of emergency conditions", .health_implications = "Health warnings of emergency conditions. The entire population is more likely to be affected.", .cautionary = "Everyone should avoid all outdoor exertion. Sensitive groups should remain indoors with air filtration.", .color = "Maroon" };
}

fn euAqiCategory(aqi: f64) AqiCategory {
    if (aqi <= 20) return .{ .level = "Good", .description = "Air quality is good", .health_implications = "The air quality is good. Enjoy your usual outdoor activities.", .cautionary = "None", .color = "Blue" };
    if (aqi <= 40) return .{ .level = "Fair", .description = "Air quality is fair", .health_implications = "Enjoy your usual outdoor activities.", .cautionary = "None", .color = "Green" };
    if (aqi <= 60) return .{ .level = "Moderate", .description = "Air quality is moderate", .health_implications = "Consider reducing intense outdoor activities if you experience symptoms.", .cautionary = "Sensitive individuals should consider reducing intense activities.", .color = "Yellow" };
    if (aqi <= 80) return .{ .level = "Poor", .description = "Air quality is poor", .health_implications = "Consider reducing intense outdoor activities if you experience symptoms such as sore eyes, cough, or sore throat.", .cautionary = "Sensitive groups should reduce outdoor activities.", .color = "Orange" };
    if (aqi <= 100) return .{ .level = "Very Poor", .description = "Air quality is very poor", .health_implications = "Consider reducing physical activities, particularly outdoors, especially if you experience symptoms.", .cautionary = "Sensitive groups should avoid outdoor activities. General population should reduce outdoor activities.", .color = "Red" };
    return .{ .level = "Extremely Poor", .description = "Air quality is extremely poor", .health_implications = "Reduce physical activities outdoors. People with respiratory or heart conditions should remain indoors.", .cautionary = "Everyone should avoid outdoor activities. Sensitive groups should remain indoors.", .color = "Purple" };
}

const UvCategory = struct {
    level: []const u8,
    description: []const u8,
    recommendation: []const u8,
};

fn uvIndexCategory(uv: f64) UvCategory {
    if (uv < 3) return .{ .level = "Low", .description = "Minimal protection required", .recommendation = "No protection required. You can safely stay outside." };
    if (uv < 6) return .{ .level = "Moderate", .description = "Protection recommended", .recommendation = "Wear sunscreen, hat, and sunglasses. Seek shade during midday hours." };
    if (uv < 8) return .{ .level = "High", .description = "Protection essential", .recommendation = "Apply SPF 30+ sunscreen. Wear protective clothing, hat, and sunglasses. Reduce midday sun exposure." };
    if (uv < 11) return .{ .level = "Very High", .description = "Extra protection required", .recommendation = "Minimize sun exposure 10am-4pm. Apply SPF 30+ sunscreen every 2 hours. Wear protective clothing and sunglasses." };
    return .{ .level = "Extreme", .description = "Maximum protection required", .recommendation = "Avoid sun exposure 10am-4pm. Stay in shade. Apply SPF 50+ sunscreen frequently. Wear full protective clothing." };
}

const WaveCategory = struct {
    description: []const u8,
    level: []const u8,
    recommendation: []const u8,
};

fn waveHeightCategory(meters: f64) WaveCategory {
    if (meters < 0.1) return .{ .description = "Calm (glassy)", .level = "Calm", .recommendation = "Ideal for all water activities" };
    if (meters < 0.5) return .{ .description = "Calm (rippled)", .level = "Calm", .recommendation = "Excellent conditions for all vessels" };
    if (meters < 1.25) return .{ .description = "Smooth", .level = "Slight", .recommendation = "Good conditions for most activities" };
    if (meters < 2.5) return .{ .description = "Slight", .level = "Moderate", .recommendation = "Safe for experienced boaters" };
    if (meters < 4.0) return .{ .description = "Moderate", .level = "Moderate", .recommendation = "Use caution, especially for small craft" };
    if (meters < 6.0) return .{ .description = "Rough", .level = "Rough", .recommendation = "Hazardous for small vessels, secure all gear" };
    if (meters < 9.0) return .{ .description = "Very Rough", .level = "Very Rough", .recommendation = "Dangerous conditions, avoid non-essential travel" };
    if (meters < 14.0) return .{ .description = "High", .level = "High", .recommendation = "Very dangerous, only experienced vessels should be out" };
    return .{ .description = "Very High", .level = "Extreme", .recommendation = "Extremely dangerous, all vessels should seek shelter" };
}

/// GeoNames feature-code descriptions (handlers/locationHandler.js).
fn featureDescription(code: []const u8) ?[]const u8 {
    const map = .{
        .{ "PPL", "Populated place" },
        .{ "PPLA", "Administrative capital" },
        .{ "PPLA2", "Second-order administrative capital" },
        .{ "PPLA3", "Third-order administrative capital" },
        .{ "PPLA4", "Fourth-order administrative capital" },
        .{ "PPLC", "National capital" },
        .{ "PPLG", "Seat of government" },
        .{ "PPLS", "Populated places" },
        .{ "PPLX", "Section of populated place" },
        .{ "ADM1", "First-order administrative division" },
        .{ "ADM2", "Second-order administrative division" },
        .{ "ADM3", "Third-order administrative division" },
        .{ "ADM4", "Fourth-order administrative division" },
        .{ "PCLI", "Independent political entity" },
        .{ "PCLD", "Dependent political entity" },
        .{ "ISL", "Island" },
        .{ "MT", "Mountain" },
        .{ "MTS", "Mountains" },
        .{ "LAKE", "Lake" },
        .{ "RSTN", "Railroad station" },
        .{ "AIRP", "Airport" },
        .{ "AIRF", "Airfield" },
        .{ "PRK", "Park" },
        .{ "RES", "Reserve" },
        .{ "RESN", "Nature reserve" },
        .{ "RESW", "Wildlife reserve" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, code, entry[0])) return entry[1];
    }
    return null;
}

/// Escape Markdown special characters in user-supplied text
/// (handlers/locationHandler.js escapeMarkdown).
fn escapeMarkdown(alloc: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (text) |c| {
        switch (c) {
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '*', '_', '[', ']', '(', ')', '`', '~', '#', '!' => {
                try out.append(alloc, '\\');
                try out.append(alloc, c);
            },
            '<' => try out.appendSlice(alloc, "&lt;"),
            '>' => try out.appendSlice(alloc, "&gt;"),
            '\n' => try out.append(alloc, ' '),
            '\r' => {},
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Lightning statistics + safety (ported from handlers/lightningHandler.js).
// The reference obtains strikes over MQTT; the computation is transport-free.
// ---------------------------------------------------------------------------

pub const LightningStrike = struct {
    timestamp_ms: i64,
    latitude: f64,
    longitude: f64,
    polarity: f64 = 0,
    amplitude: f64 = 0,
    station_count: i64 = 0,
    distance: f64 = 0,
};

pub const LightningStats = struct {
    total: usize,
    cloud_to_ground: usize,
    intra_cloud: usize,
    average_distance: f64,
    nearest_distance: f64,
    strikes_per_minute: f64,
    density_per_sq_km: f64,
};

fn lightningStats(strikes: []const LightningStrike, radius_km: f64, window_min: f64) LightningStats {
    if (strikes.len == 0) {
        return .{ .total = 0, .cloud_to_ground = 0, .intra_cloud = 0, .average_distance = 0, .nearest_distance = 0, .strikes_per_minute = 0, .density_per_sq_km = 0 };
    }
    var ctg: usize = 0;
    var total_dist: f64 = 0;
    for (strikes) |s| {
        if (@abs(s.amplitude) > 20) ctg += 1;
        total_dist += s.distance;
    }
    const n: f64 = @floatFromInt(strikes.len);
    return .{
        .total = strikes.len,
        .cloud_to_ground = ctg,
        .intra_cloud = strikes.len - ctg,
        .average_distance = total_dist / n,
        .nearest_distance = strikes[0].distance,
        .strikes_per_minute = n / window_min,
        .density_per_sq_km = n / (std.math.pi * radius_km * radius_km),
    };
}

pub const SafetyLevel = enum { safe, elevated, high, extreme };

pub const LightningSafety = struct {
    level: SafetyLevel,
    message: []const u8,
    nearest_distance: ?f64,
    active_thunderstorm: bool,
};

fn assessLightningSafety(alloc: std.mem.Allocator, strikes: []const LightningStrike, stats: LightningStats, now_ms: i64) !LightningSafety {
    var recent: usize = 0;
    for (strikes) |s| {
        const age_min = @as(f64, @floatFromInt(now_ms - s.timestamp_ms)) / 60000.0;
        if (age_min <= 10) recent += 1;
    }
    const active = recent > 0 or stats.strikes_per_minute > 0.5;
    const nearest: ?f64 = if (strikes.len > 0) strikes[0].distance else null;
    if (nearest == null or nearest.? > 50) {
        return .{ .level = .safe, .message = try alloc.dupe(u8, "No significant lightning activity detected in the area."), .nearest_distance = nearest, .active_thunderstorm = active };
    }
    if (nearest.? > 16) {
        return .{ .level = .elevated, .message = try std.fmt.allocPrint(alloc, "Lightning detected {d:.1} km away. Thunderstorm in the vicinity.", .{nearest.?}), .nearest_distance = nearest, .active_thunderstorm = active };
    }
    if (nearest.? > 8) {
        return .{ .level = .high, .message = try std.fmt.allocPrint(alloc, "Lightning strike detected {d:.1} km away. High risk - seek shelter immediately.", .{nearest.?}), .nearest_distance = nearest, .active_thunderstorm = active };
    }
    return .{ .level = .extreme, .message = try std.fmt.allocPrint(alloc, "EXTREME DANGER: Lightning strike within {d:.1} km. You are in immediate danger.", .{nearest.?}), .nearest_distance = nearest, .active_thunderstorm = active };
}

// ---------------------------------------------------------------------------
// JSON value helpers
// ---------------------------------------------------------------------------

fn jObj(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn jStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const fv = jObj(v, key) orelse return null;
    return if (fv == .string) fv.string else null;
}

fn jNum(v: std.json.Value, key: []const u8) ?f64 {
    const fv = jObj(v, key) orelse return null;
    return switch (fv) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

/// Numeric value out of a JSON array at index i (null-safe).
fn arrNum(arr: std.json.Value, i: usize) ?f64 {
    if (arr != .array) return null;
    if (i >= arr.array.items.len) return null;
    return switch (arr.array.items[i]) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

fn arrStr(arr: std.json.Value, i: usize) ?[]const u8 {
    if (arr != .array) return null;
    if (i >= arr.array.items.len) return null;
    return switch (arr.array.items[i]) {
        .string => |s| s,
        else => null,
    };
}

fn arrLen(v: std.json.Value, key: []const u8) usize {
    const fv = jObj(v, key) orelse return 0;
    return if (fv == .array) fv.array.items.len else 0;
}

/// NOAA quantity object: {"unitCode": "wmoUnit:degC", "value": 20.5}.
/// Returns null when value is JSON null.
fn noaaQty(v: std.json.Value, key: []const u8) ?f64 {
    const qv = jObj(v, key) orelse return null;
    if (qv != .object) return null;
    return jNum(qv, "value");
}

fn noaaQtyUnit(v: std.json.Value, key: []const u8) []const u8 {
    const qv = jObj(v, key) orelse return "";
    if (qv != .object) return "";
    return jStr(qv, "unitCode") orelse "";
}

fn toFahrenheit(value: f64, unit_code: []const u8) ?f64 {
    if (std.mem.indexOf(u8, unit_code, "degF") != null) return value;
    if (std.mem.indexOf(u8, unit_code, "degC") != null) return value * 9.0 / 5.0 + 32.0;
    return null;
}

// ---------------------------------------------------------------------------
// Time helpers (compact, from src/time/main.zig idioms)
// ---------------------------------------------------------------------------

fn nowSeconds(io: std.Io) i64 {
    const ts = std.Io.Timestamp.now(io, .real);
    return @divFloor(ts.toMilliseconds(), 1000);
}

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

/// Days since 1970-01-01 for a Gregorian date.
fn daysFromCivil(y: i32, m: u8, d: u8) i64 {
    var yy: i32 = 1970;
    var days: i64 = 0;
    if (y >= 1970) {
        while (yy < y) : (yy += 1) days += if (isLeap(yy)) @as(i64, 366) else 365;
    } else {
        while (yy > y) : (yy -= 1) {
            const py = yy - 1;
            days -= if (isLeap(py)) @as(i64, 366) else 365;
        }
    }
    var mm: u8 = 1;
    while (mm < m) : (mm += 1) days += daysInMonth(y, mm);
    return days + @as(i64, d - 1);
}

const Ymd = struct { y: i32, m: u8, d: u8 };

/// Parse the leading YYYY-MM-DD of an ISO date/datetime string.
fn parseYmd(s: []const u8) ?Ymd {
    if (s.len < 10) return null;
    if (s[4] != '-' or s[7] != '-') return null;
    const y = std.fmt.parseInt(i32, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > daysInMonth(y, m)) return null;
    return .{ .y = y, .m = m, .d = d };
}

/// Extract "YYYY-MM-DD" (first 10 chars) if the string looks like an ISO date.
fn isoDatePart(s: []const u8) []const u8 {
    if (parseYmd(s) == null) return s;
    return s[0..10];
}

/// Convert an ISO date/datetime to RFC3339 for NOAA query params:
/// dates without a time component get T00:00:00Z appended.
fn rfc3339(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len == 10 and parseYmd(s) != null) {
        return std.fmt.allocPrint(alloc, "{s}T00:00:00Z", .{s});
    }
    return alloc.dupe(u8, s);
}

// ---------------------------------------------------------------------------
// Shared fetch/parse plumbing for tool implementations
// ---------------------------------------------------------------------------

/// Fetch a URL and parse the body as JSON. On any failure returns a
/// ToolResult-shaped error via `err_out` and null on the happy path.
const JsonOrError = union(enum) {
    parsed: std.json.Parsed(std.json.Value),
    err_result: mcp.ToolResult,
};

fn fetchJson(alloc: std.mem.Allocator, io: std.Io, fetch: FetchFn, url: []const u8, source: []const u8) !JsonOrError {
    const resp = fetch(alloc, io, url) catch |err| {
        return .{ .err_result = .{
            .text = try std.fmt.allocPrint(alloc, "{s} request failed: {s}", .{ source, @errorName(err) }),
            .is_error = true,
        } };
    };
    if (resp.status != 200) {
        // Open-Meteo style error bodies carry a "reason" field.
        var reason: []const u8 = "";
        if (std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{})) |p| {
            var parsed = p;
            defer parsed.deinit();
            reason = jStr(parsed.value, "reason") orelse (jStr(parsed.value, "detail") orelse (jStr(parsed.value, "title") orelse ""));
        } else |_| {}
        if (resp.status == 404 and std.mem.eql(u8, source, "NOAA")) {
            return .{ .err_result = .{
                .text = try std.fmt.allocPrint(alloc, "NOAA data not found for this location (HTTP 404). {s}\n\nThis location may be outside NOAA's coverage area (US only).", .{reason}),
                .is_error = true,
            } };
        }
        if (reason.len > 0) {
            return .{ .err_result = .{
                .text = try std.fmt.allocPrint(alloc, "{s} API error (HTTP {d}): {s}", .{ source, resp.status, reason }),
                .is_error = true,
            } };
        }
        return .{ .err_result = .{
            .text = try std.fmt.allocPrint(alloc, "{s} API error (HTTP {d})", .{ source, resp.status }),
            .is_error = true,
        } };
    }
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, resp.body, .{}) catch |err| {
        return .{ .err_result = .{
            .text = try std.fmt.allocPrint(alloc, "{s} returned malformed JSON: {s}", .{ source, @errorName(err) }),
            .is_error = true,
        } };
    };
    return .{ .parsed = parsed };
}

// ---------------------------------------------------------------------------
// Tool handlers (thin wrappers binding the real HTTPS fetch)
// ---------------------------------------------------------------------------

fn handleGetForecast(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return forecastImpl(alloc, io, args, httpsGet);
}

fn handleGetCurrentConditions(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return currentConditionsImpl(alloc, io, args, httpsGet);
}

fn handleGetAlerts(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return alertsImpl(alloc, io, args, httpsGet);
}

fn handleGetHistoricalWeather(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return historicalImpl(alloc, io, args, nowSeconds(io), httpsGet);
}

fn handleCheckServiceStatus(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return statusImpl(alloc, io, args, httpsGet);
}

fn handleSearchLocation(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return searchLocationImpl(alloc, io, args, httpsGet);
}

fn handleGetAirQuality(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return airQualityImpl(alloc, io, args, httpsGet);
}

fn handleGetMarineConditions(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return marineImpl(alloc, io, args, httpsGet);
}

fn handleGetWeatherImagery(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return imageryImpl(alloc, io, args, nowSeconds(io), httpsGet);
}

fn handleGetLightningActivity(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return lightningImpl(alloc, io, args);
}

fn handleGetRiverConditions(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return riverImpl(alloc, io, args, httpsGet);
}

fn handleGetWildfireInfo(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    return wildfireImpl(alloc, io, args, httpsGet);
}

// ---------------------------------------------------------------------------
// Tool implementations — each takes a FetchFn so tests inject canned HTTP.
// ---------------------------------------------------------------------------

const Civil = struct { y: i32, m: u8, d: u8, hh: u8, mm: u8, ss: u8 };

fn unixToCivil(ts: i64) Civil {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, ts)) };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    return .{
        .y = @intCast(yd.year),
        .m = @intFromEnum(md.month),
        .d = md.day_index + 1,
        .hh = ds.getHoursIntoDay(),
        .mm = ds.getMinutesIntoHour(),
        .ss = ds.getSecondsIntoMinute(),
    };
}

fn isoFromUnix(buf: []u8, ts: i64) []const u8 {
    const c = unixToCivil(ts);
    const yu: u32 = @intCast(@max(0, c.y));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ yu, c.m, c.d, c.hh, c.mm, c.ss }) catch unreachable;
}

fn dateFromUnix(buf: []u8, ts: i64) []const u8 {
    const c = unixToCivil(ts);
    const yu: u32 = @intCast(@max(0, c.y));
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yu, c.m, c.d }) catch unreachable;
}

// --- search_location ---

fn searchLocationImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, fetch: FetchFn) !mcp.ToolResult {
    const raw_query = argStr(args, "query") orelse {
        return .{ .text = "query parameter is required and must be a string", .is_error = true };
    };
    const query = trimWs(raw_query);
    if (query.len == 0) {
        return .{ .text = "query parameter is required and must be a string", .is_error = true };
    }
    var limit: i64 = 5;
    if (argNum(args, "limit")) |l| {
        limit = @intFromFloat(@max(1, @min(100, @round(l))));
    }

    var url_buf: [2048]u8 = undefined;
    const url = try geocodeUrl(&url_buf, query, limit);
    const parsed = switch (try fetchJson(alloc, io, fetch, url, "Open-Meteo")) {
        .parsed => |p| p,
        .err_result => |tr| return tr,
    };
    defer parsed.deinit();

    const results_v = jObj(parsed.value, "results");
    const results = if (results_v != null and results_v.? == .array) results_v.?.array.items else &[_]std.json.Value{};
    if (results.len == 0) {
        return .{ .text = try std.fmt.allocPrint(alloc,
            \\No locations found matching "{s}". Try:
            \\- Using a different spelling
            \\- Being more specific (e.g., "Paris, France" instead of "Paris")
            \\- Using a nearby city or landmark
        , .{query}), .is_error = true };
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    const escaped_query = try escapeMarkdown(alloc, query);
    try w.writeAll("# Location Search Results\n\n");
    try w.print("**Query:** \"{s}\"\n", .{escaped_query});
    try w.print("**Found:** {d} location{s}\n\n---\n\n", .{ results.len, if (results.len > 1) "s" else "" });

    for (results, 0..) |loc, i| {
        const name = jStr(loc, "name") orelse "Unknown";
        const lat = jNum(loc, "latitude") orelse 0;
        const lon = jNum(loc, "longitude") orelse 0;
        try w.print("## {d}. {s}\n\n", .{ i + 1, name });
        try w.print("**Full Name:** {s}", .{name});
        if (jStr(loc, "admin1")) |a1| try w.print(", {s}", .{a1});
        const a1 = jStr(loc, "admin1") orelse "";
        if (jStr(loc, "admin2")) |a2| {
            if (!std.mem.eql(u8, a2, a1)) try w.print(", {s}", .{a2});
        }
        if (jStr(loc, "country")) |c| try w.print(", {s}", .{c});
        try w.writeByte('\n');
        try w.print("**Coordinates:** {d:.4}°, {d:.4}°\n", .{ lat, lon });
        if (jStr(loc, "country_code")) |cc| {
            var upper_buf: [8]u8 = undefined;
            if (cc.len <= upper_buf.len) {
                const up = std.ascii.upperString(&upper_buf, cc);
                try w.print("**Country Code:** {s}\n", .{up});
            }
        }
        if (jStr(loc, "timezone")) |tz| try w.print("**Timezone:** {s}\n", .{tz});
        if (jNum(loc, "elevation")) |elev| {
            try w.print("**Elevation:** {d:.0}m ({d:.0}ft)\n", .{ elev, elev * 3.28084 });
        }
        if (jNum(loc, "population")) |pop| {
            if (pop > 0) try w.print("**Population:** {d:.0}\n", .{pop});
        }
        if (jStr(loc, "feature_code")) |fc| {
            if (featureDescription(fc)) |desc| try w.print("**Type:** {s}\n", .{desc});
        }
        try w.writeAll("\n*To get weather for this location, use these coordinates:*\n");
        try w.print("*Latitude: {d:.4}, Longitude: {d:.4}*\n\n", .{ lat, lon });
        if (i < results.len - 1) try w.writeAll("---\n\n");
    }
    try w.writeAll("---\n*Data source: Open-Meteo Geocoding API*\n");
    return .{ .text = try withAttribution(alloc, out.written(), ATTR_OPEN_METEO) };
}

/// One-line data credits appended to results (Open-Meteo requires CC BY 4.0
/// attribution; NOAA/NWS is credited as the source).
const ATTR_OPEN_METEO = "Data: Open-Meteo.com (CC BY 4.0)";
const ATTR_NOAA = "Data: NOAA/NWS";

fn withAttribution(alloc: std.mem.Allocator, body: []const u8, attribution: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ std.mem.trimEnd(u8, body, "\n"), attribution });
}

fn trimWs(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, &std.ascii.whitespace);
}

// --- get_forecast ---

fn forecastImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, fetch: FetchFn) !mcp.ToolResult {
    const coords = getCoords(alloc, args) catch |err| return coordsError(alloc, err);
    var days: i64 = 7;
    if (argPosInt(args, "days", 1, 16) catch {
        return .{ .text = "Invalid days: must be an integer between 1 and 16.", .is_error = true };
    }) |d| days = d;

    const granularity_raw = argStr(args, "granularity") orelse "daily";
    if (!std.mem.eql(u8, granularity_raw, "daily") and !std.mem.eql(u8, granularity_raw, "hourly")) {
        return .{ .text = try std.fmt.allocPrint(alloc, "Invalid granularity: \"{s}\". Must be either \"daily\" or \"hourly\".", .{granularity_raw}), .is_error = true };
    }
    const hourly = std.mem.eql(u8, granularity_raw, "hourly");
    const include_precip = argBool(args, "include_precipitation_probability", true);
    const include_severe = argBool(args, "include_severe_weather", false);
    const include_normals = argBool(args, "include_normals", false);

    const source = argStr(args, "source") orelse "auto";
    if (!std.mem.eql(u8, source, "auto") and !std.mem.eql(u8, source, "noaa") and !std.mem.eql(u8, source, "openmeteo")) {
        return .{ .text = try std.fmt.allocPrint(alloc, "Invalid source: \"{s}\". Must be \"auto\", \"noaa\", or \"openmeteo\".", .{source}), .is_error = true };
    }
    const use_noaa = std.mem.eql(u8, source, "noaa") or
        (std.mem.eql(u8, source, "auto") and isInUS(coords.lat, coords.lon));

    if (use_noaa) {
        return forecastNoaa(alloc, io, coords, days, hourly, include_precip, include_severe, include_normals, fetch);
    }
    return forecastOpenMeteo(alloc, io, coords, days, hourly, include_precip, include_normals, fetch);
}

fn noaaGrid(alloc: std.mem.Allocator, io: std.Io, coords: anytype, fetch: FetchFn) !union(enum) {
    grid: struct { office: []const u8, x: i64, y: i64 },
    err_result: mcp.ToolResult,
} {
    var url_buf: [256]u8 = undefined;
    const url = try noaaPointsUrl(&url_buf, coords.lat, coords.lon);
    const parsed = switch (try fetchJson(alloc, io, fetch, url, "NOAA")) {
        .parsed => |p| p,
        .err_result => |tr| return .{ .err_result = tr },
    };
    defer parsed.deinit();
    const props = jObj(parsed.value, "properties") orelse {
        return .{ .err_result = .{ .text = "NOAA points response missing properties", .is_error = true } };
    };
    const office = jStr(props, "gridId") orelse {
        return .{ .err_result = .{ .text = "NOAA points response missing grid id", .is_error = true } };
    };
    const gx = jNum(props, "gridX") orelse {
        return .{ .err_result = .{ .text = "NOAA points response missing gridX", .is_error = true } };
    };
    const gy = jNum(props, "gridY") orelse {
        return .{ .err_result = .{ .text = "NOAA points response missing gridY", .is_error = true } };
    };
    return .{ .grid = .{
        .office = try alloc.dupe(u8, office),
        .x = @intFromFloat(gx),
        .y = @intFromFloat(gy),
    } };
}

fn forecastNoaa(alloc: std.mem.Allocator, io: std.Io, coords: anytype, days: i64, hourly: bool, include_precip: bool, include_severe: bool, include_normals: bool, fetch: FetchFn) !mcp.ToolResult {
    const grid = switch (try noaaGrid(alloc, io, coords, fetch)) {
        .grid => |g| g,
        .err_result => |tr| return tr,
    };

    var url_buf: [512]u8 = undefined;
    const url = if (hourly)
        try std.fmt.bufPrint(&url_buf, "https://api.weather.gov/gridpoints/{s}/{d},{d}/forecast/hourly", .{ grid.office, grid.x, grid.y })
    else
        try std.fmt.bufPrint(&url_buf, "https://api.weather.gov/gridpoints/{s}/{d},{d}/forecast", .{ grid.office, grid.x, grid.y });

    const parsed = switch (try fetchJson(alloc, io, fetch, url, "NOAA")) {
        .parsed => |p| p,
        .err_result => |tr| return tr,
    };
    defer parsed.deinit();

    const props = jObj(parsed.value, "properties") orelse {
        return .{ .text = "NOAA forecast response missing properties", .is_error = true };
    };
    const periods_v = jObj(props, "periods");
    const all_periods = if (periods_v != null and periods_v.? == .array) periods_v.?.array.items else &[_]std.json.Value{};
    const max_periods: usize = if (hourly) @intCast(days * 24) else @intCast(days * 2);
    const periods = all_periods[0..@min(all_periods.len, max_periods)];

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    try w.print("# Weather Forecast ({s})\n\n", .{if (hourly) "Hourly" else "Daily"});
    try w.print("**Location:** {d:.4}, {d:.4}\n", .{ coords.lat, coords.lon });
    if (noaaQty(props, "elevation")) |elev| try w.print("**Elevation:** {d:.0}m\n", .{elev});
    if (jStr(props, "updated")) |upd| try w.print("**Updated:** {s}\n", .{upd});
    try w.print("**Showing:** {d} {s}\n\n", .{ periods.len, if (hourly) "hours" else "periods" });

    for (periods) |period| {
        const name = jStr(period, "name") orelse "";
        const start = jStr(period, "startTime") orelse "";
        const header = if (hourly and name.len == 0) start else name;
        try w.print("## {s}\n", .{header});
        if (jNum(period, "temperature")) |t| {
            const unit = jStr(period, "temperatureUnit") orelse "F";
            try w.print("**Temperature:** {d:.0}°{s}", .{ t, unit });
            if (jStr(period, "temperatureTrend")) |trend| {
                if (trend.len > 0) try w.print(" ({s})", .{trend});
            }
            try w.writeByte('\n');
        }
        if (include_precip) {
            if (noaaQty(period, "probabilityOfPrecipitation")) |p| {
                try w.print("**Precipitation Chance:** {d:.0}%\n", .{p});
            }
        }
        const wind_speed = jStr(period, "windSpeed") orelse "";
        const wind_dir = jStr(period, "windDirection") orelse "";
        if (wind_speed.len > 0 or wind_dir.len > 0) {
            try w.print("**Wind:** {s} {s}\n", .{ wind_speed, wind_dir });
        }
        if (noaaQty(period, "relativeHumidity")) |rh| try w.print("**Humidity:** {d:.0}%\n", .{rh});
        if (jStr(period, "shortForecast")) |sf| try w.print("**Forecast:** {s}\n\n", .{sf});
        if (!hourly) {
            if (jStr(period, "detailedForecast")) |df| try w.print("{s}\n\n", .{df});
        }
    }
    try w.writeAll("---\n*Data source: NOAA National Weather Service (US)*\n");
    if (include_severe) {
        try w.writeAll("\n*Note: Severe weather probability data is not available in this build (gridpoint probability pipeline not ported).*\n");
    }
    if (include_normals and !hourly) {
        try w.writeAll("\n## Climate Normals\n\n⚠️ Climate normals data not available in this build.\n");
    }
    return .{ .text = try withAttribution(alloc, out.written(), ATTR_NOAA) };
}

fn forecastOpenMeteo(alloc: std.mem.Allocator, io: std.Io, coords: anytype, days: i64, hourly: bool, include_precip: bool, include_normals: bool, fetch: FetchFn) !mcp.ToolResult {
    var url_buf: [4096]u8 = undefined;
    const url = try omForecastUrl(&url_buf, coords.lat, coords.lon, days, hourly);
    const parsed = switch (try fetchJson(alloc, io, fetch, url, "Open-Meteo")) {
        .parsed => |p| p,
        .err_result => |tr| return tr,
    };
    defer parsed.deinit();

    const root = parsed.value;
    const daily_v = jObj(root, "daily");
    const hourly_v = jObj(root, "hourly");
    const tz = jStr(root, "timezone") orelse "auto";

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    try w.print("# Weather Forecast ({s})\n\n", .{if (hourly) "Hourly" else "Daily"});
    try w.print("**Location:** {d:.4}, {d:.4}\n", .{ coords.lat, coords.lon });
    if (jNum(root, "elevation")) |elev| try w.print("**Elevation:** {d:.0}m\n", .{elev});
    try w.print("**Timezone:** {s}\n", .{tz});
    try w.print("**Forecast Days:** {d}\n\n", .{days});

    if (hourly and hourly_v != null and hourly_v.? == .object) {
        const h = hourly_v.?;
        const times_v = jObj(h, "time");
        const total = if (times_v != null and times_v.? == .array) times_v.?.array.items.len else 0;
        const n = @min(total, @as(usize, @intCast(days * 24)));
        const t2m = jObj(h, "temperature_2m") orelse .null;
        const at = jObj(h, "apparent_temperature") orelse .null;
        const pp = jObj(h, "precipitation_probability") orelse .null;
        const precip = jObj(h, "precipitation") orelse .null;
        const ws = jObj(h, "wind_speed_10m") orelse .null;
        const wd = jObj(h, "wind_direction_10m") orelse .null;
        const wg = jObj(h, "wind_gusts_10m") orelse .null;
        const rh = jObj(h, "relative_humidity_2m") orelse .null;
        const wc = jObj(h, "weather_code") orelse .null;
        for (0..n) |i| {
            try w.print("## {s}\n", .{arrStr(times_v.?, i) orelse "?"});
            if (arrNum(t2m, i)) |t| {
                try w.print("**Temperature:** {d:.0}°F", .{@round(t)});
                if (arrNum(at, i)) |f| try w.print(" (feels like {d:.0}°F)", .{@round(f)});
                try w.writeByte('\n');
            }
            if (include_precip) {
                if (arrNum(pp, i)) |p| try w.print("**Precipitation Chance:** {d:.0}%\n", .{p});
            }
            if (arrNum(precip, i)) |p| {
                if (p > 0) try w.print("**Precipitation:** {d:.2} in\n", .{p});
            }
            if (arrNum(ws, i)) |s| {
                try w.print("**Wind:** {d:.0} mph", .{@round(s)});
                if (arrNum(wd, i)) |d| try w.print(" {s}", .{cardinalDirection(d)});
                try w.writeByte('\n');
                if (arrNum(wg, i)) |g| {
                    if (g > s * 1.2) try w.print("**Wind Gusts:** {d:.0} mph\n", .{@round(g)});
                }
            }
            if (arrNum(rh, i)) |r| try w.print("**Humidity:** {d:.0}%\n", .{r});
            if (arrNum(wc, i)) |c| try w.print("**Conditions:** {s}\n", .{weatherDescription(@intFromFloat(c))});
            try w.writeByte('\n');
        }
    } else if (daily_v != null and daily_v.? == .object) {
        const d = daily_v.?;
        const times_v = jObj(d, "time");
        const total = if (times_v != null and times_v.? == .array) times_v.?.array.items.len else 0;
        const n = @min(total, @as(usize, @intCast(days)));
        const tmax = jObj(d, "temperature_2m_max") orelse .null;
        const tmin = jObj(d, "temperature_2m_min") orelse .null;
        const atmax = jObj(d, "apparent_temperature_max") orelse .null;
        const atmin = jObj(d, "apparent_temperature_min") orelse .null;
        const sunrise = jObj(d, "sunrise") orelse .null;
        const sunset = jObj(d, "sunset") orelse .null;
        const daylight = jObj(d, "daylight_duration") orelse .null;
        const ppmax = jObj(d, "precipitation_probability_max") orelse .null;
        const psum = jObj(d, "precipitation_sum") orelse .null;
        const wsmax = jObj(d, "wind_speed_10m_max") orelse .null;
        const wgmax = jObj(d, "wind_gusts_10m_max") orelse .null;
        const wddom = jObj(d, "wind_direction_10m_dominant") orelse .null;
        const wc = jObj(d, "weather_code") orelse .null;
        const uv = jObj(d, "uv_index_max") orelse .null;
        for (0..n) |i| {
            try w.print("## {s}\n", .{arrStr(times_v.?, i) orelse "?"});
            if (arrNum(tmax, i) != null and arrNum(tmin, i) != null) {
                try w.print("**Temperature:** High {d:.0}°F / Low {d:.0}°F\n", .{ @round(arrNum(tmax, i).?), @round(arrNum(tmin, i).?) });
            }
            if (arrNum(atmax, i) != null and arrNum(atmin, i) != null) {
                try w.print("**Feels Like:** High {d:.0}°F / Low {d:.0}°F\n", .{ @round(arrNum(atmax, i).?), @round(arrNum(atmin, i).?) });
            }
            if (arrStr(sunrise, i)) |sr| try w.print("**Sunrise:** {s}\n", .{sr});
            if (arrStr(sunset, i)) |ss| try w.print("**Sunset:** {s}\n", .{ss});
            if (arrNum(daylight, i)) |dl| {
                const hours: i64 = @intFromFloat(@floor(dl / 3600));
                const mins: i64 = @intFromFloat(@floor(@mod(dl, 3600) / 60));
                try w.print("**Daylight Duration:** {d}h {d}m\n", .{ hours, mins });
            }
            if (include_precip) {
                if (arrNum(ppmax, i)) |p| try w.print("**Precipitation Chance:** {d:.0}%\n", .{p});
            }
            if (arrNum(psum, i)) |p| {
                if (p > 0) try w.print("**Precipitation:** {d:.2} in\n", .{p});
            }
            if (arrNum(wsmax, i)) |s| {
                try w.print("**Wind:** {d:.0} mph", .{@round(s)});
                if (arrNum(wddom, i)) |dd| try w.print(" {s}", .{cardinalDirection(dd)});
                try w.writeByte('\n');
                if (arrNum(wgmax, i)) |g| {
                    if (g > s * 1.2) try w.print("**Wind Gusts:** {d:.0} mph\n", .{@round(g)});
                }
            }
            if (arrNum(wc, i)) |c| try w.print("**Conditions:** {s}\n", .{weatherDescription(@intFromFloat(c))});
            if (arrNum(uv, i)) |u| try w.print("**UV Index:** {d:.1}\n", .{u});
            try w.writeByte('\n');
        }
    } else {
        return .{ .text = "No forecast data available for the specified location", .is_error = true };
    }

    try w.writeAll("---\n*Data source: Open-Meteo (Global)*\n");
    if (include_normals and !hourly) {
        try w.writeAll("\n## Climate Normals\n\n⚠️ Climate normals data not available in this build.\n");
    }
    return .{ .text = try withAttribution(alloc, out.written(), ATTR_OPEN_METEO) };
}

// --- get_current_conditions ---

fn currentConditionsImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, fetch: FetchFn) !mcp.ToolResult {
    const coords = getCoords(alloc, args) catch |err| return coordsError(alloc, err);
    const include_fire = argBool(args, "include_fire_weather", false);
    const include_normals = argBool(args, "include_normals", false);

    var url_buf: [512]u8 = undefined;
    const stations_url = try std.fmt.bufPrint(&url_buf, "https://api.weather.gov/points/{d:.4},{d:.4}/stations", .{ coords.lat, coords.lon });
    const stations = switch (try fetchJson(alloc, io, fetch, stations_url, "NOAA")) {
        .parsed => |p| p,
        .err_result => |tr| return tr,
    };
    defer stations.deinit();

    const features_v = jObj(stations.value, "features");
    const features = if (features_v != null and features_v.? == .array) features_v.?.array.items else &[_]std.json.Value{};
    if (features.len == 0) {
        return .{ .text = "No weather stations found near the specified location.", .is_error = true };
    }

    // Try stations in order until one yields a latest observation.
    var obs: ?std.json.Parsed(std.json.Value) = null;
    for (features) |st| {
        const props = jObj(st, "properties") orelse continue;
        const station_id = jStr(props, "stationIdentifier") orelse continue;
        var obs_url_buf: [512]u8 = undefined;
        const obs_url = std.fmt.bufPrint(&obs_url_buf, "https://api.weather.gov/stations/{s}/observations/latest", .{station_id}) catch continue;
        switch (try fetchJson(alloc, io, fetch, obs_url, "NOAA")) {
            .parsed => |p| {
                obs = p;
                break;
            },
            .err_result => continue,
        }
    }
    const obs_parsed = obs orelse {
        return .{ .text = "Unable to retrieve current conditions from nearby stations.", .is_error = true };
    };
    defer obs_parsed.deinit();

    const props = jObj(obs_parsed.value, "properties") orelse {
        return .{ .text = "NOAA observation response missing properties", .is_error = true };
    };

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("# Current Weather Conditions\n\n");
    if (jStr(props, "station")) |st| try w.print("**Station:** {s}\n", .{st});
    if (jStr(props, "timestamp")) |ts| try w.print("**Time:** {s}\n\n", .{ts});
    if (jStr(props, "textDescription")) |td| try w.print("**Conditions:** {s}\n", .{td});

    var temp_f: ?f64 = null;
    if (noaaQty(props, "temperature")) |t| {
        temp_f = toFahrenheit(t, noaaQtyUnit(props, "temperature"));
        if (temp_f) |tf| {
            try w.print("**Temperature:** {d:.0}°F\n", .{@round(tf)});
            if (noaaQty(props, "heatIndex")) |hi| {
                if (toFahrenheit(hi, noaaQtyUnit(props, "heatIndex"))) |hif| {
                    if (tf > 80 and hif > tf) try w.print("**Feels Like (Heat Index):** {d:.0}°F\n", .{@round(hif)});
                }
            }
            if (noaaQty(props, "windChill")) |wc| {
                if (toFahrenheit(wc, noaaQtyUnit(props, "windChill"))) |wcf| {
                    if (tf < 50 and wcf < tf) try w.print("**Feels Like (Wind Chill):** {d:.0}°F\n", .{@round(wcf)});
                }
            }
        }
    }
    const max24 = if (noaaQty(props, "maxTemperatureLast24Hours")) |v| toFahrenheit(v, noaaQtyUnit(props, "maxTemperatureLast24Hours")) else null;
    const min24 = if (noaaQty(props, "minTemperatureLast24Hours")) |v| toFahrenheit(v, noaaQtyUnit(props, "minTemperatureLast24Hours")) else null;
    if (max24 != null or min24 != null) {
        try w.writeAll("**24-Hour Range:**");
        if (max24) |v| try w.print(" High {d:.0}°F", .{@round(v)});
        if (max24 != null and min24 != null) try w.writeAll(" /");
        if (min24) |v| try w.print(" Low {d:.0}°F", .{@round(v)});
        try w.writeByte('\n');
    }
    if (noaaQty(props, "dewpoint")) |d| {
        if (toFahrenheit(d, noaaQtyUnit(props, "dewpoint"))) |df| {
            try w.print("**Dewpoint:** {d:.0}°F\n", .{@round(df)});
        }
    }
    if (noaaQty(props, "relativeHumidity")) |rh| try w.print("**Humidity:** {d:.0}%\n", .{@round(rh)});

    if (noaaQty(props, "windSpeed")) |ws| {
        const unit = noaaQtyUnit(props, "windSpeed");
        const mph = if (std.mem.indexOf(u8, unit, "km_h") != null) ws * 0.621371 else ws * 2.23694;
        try w.print("**Wind:** {d:.0} mph", .{@round(mph)});
        if (noaaQty(props, "windDirection")) |dir| try w.print(" from {d:.0}°", .{@round(dir)});
        if (noaaQty(props, "windGust")) |g| {
            const gunit = noaaQtyUnit(props, "windGust");
            const gmph = if (std.mem.indexOf(u8, gunit, "km_h") != null) g * 0.621371 else g * 2.23694;
            if (gmph > mph * 1.2) try w.print(", gusting to {d:.0} mph", .{@round(gmph)});
        }
        try w.writeByte('\n');
    }
    if (noaaQty(props, "barometricPressure")) |p| {
        try w.print("**Pressure:** {d:.2} inHg\n", .{p * 0.0002953});
    }
    if (noaaQty(props, "visibility")) |v| {
        const miles = v * 0.000621371;
        try w.print("**Visibility:** {d:.1} miles", .{miles});
        if (miles < 0.25) {
            try w.writeAll(" (dense fog)");
        } else if (miles < 1.0) {
            try w.writeAll(" (fog)");
        } else if (miles < 3.0) {
            try w.writeAll(" (haze/mist)");
        } else if (miles >= 10.0) {
            try w.writeAll(" (clear)");
        }
        try w.writeByte('\n');
    }
    if (jObj(props, "cloudLayers")) |cl| {
        if (cl == .array and cl.array.items.len > 0) {
            try w.writeAll("**Cloud Cover:** ");
            var first = true;
            for (cl.array.items) |layer| {
                const amount = jStr(layer, "amount") orelse continue;
                const desc = if (std.mem.eql(u8, amount, "FEW"))
                    "Few clouds"
                else if (std.mem.eql(u8, amount, "SCT"))
                    "Scattered clouds"
                else if (std.mem.eql(u8, amount, "BKN"))
                    "Broken clouds"
                else if (std.mem.eql(u8, amount, "OVC"))
                    "Overcast"
                else if (std.mem.eql(u8, amount, "CLR"))
                    "Clear"
                else if (std.mem.eql(u8, amount, "SKC"))
                    "Sky clear"
                else
                    amount;
                if (!first) try w.writeAll(", ");
                first = false;
                try w.writeAll(desc);
                if (noaaQty(layer, "base")) |base| {
                    const bunit = noaaQtyUnit(layer, "base");
                    const ft = if (std.mem.indexOf(u8, bunit, ":m") != null) base * 3.28084 else base;
                    try w.print(" at {d:.0} ft", .{@round(ft)});
                }
            }
            if (!first) try w.writeByte('\n');
        }
    }

    const p1 = noaaQty(props, "precipitationLastHour");
    const p3 = noaaQty(props, "precipitationLast3Hours");
    const p6 = noaaQty(props, "precipitationLast6Hours");
    if (p1 != null or p3 != null or p6 != null) {
        try w.writeAll("\n## Recent Precipitation\n");
        if (p1) |v| try w.print("**Last Hour:** {d:.2} inches\n", .{v * 0.0393701});
        if (p3) |v| try w.print("**Last 3 Hours:** {d:.2} inches\n", .{v * 0.0393701});
        if (p6) |v| try w.print("**Last 6 Hours:** {d:.2} inches\n", .{v * 0.0393701});
    }
    if (include_fire) {
        try w.writeAll("\n## Fire Weather\n\n⚠️ Fire weather data not available in this build (gridpoint pipeline not ported).\n");
    }
    if (include_normals) {
        try w.writeAll("\n## Climate Normals\n\n⚠️ Climate normals data not available in this build.\n");
    }
    try w.writeAll("\n---\n*Data source: NOAA National Weather Service*\n");
    return .{ .text = try withAttribution(alloc, out.written(), ATTR_NOAA) };
}

// --- get_alerts ---

fn severityRank(sev: []const u8) u8 {
    if (std.mem.eql(u8, sev, "Extreme")) return 0;
    if (std.mem.eql(u8, sev, "Severe")) return 1;
    if (std.mem.eql(u8, sev, "Moderate")) return 2;
    if (std.mem.eql(u8, sev, "Minor")) return 3;
    return 4;
}

fn severityEmoji(sev: []const u8) []const u8 {
    if (std.mem.eql(u8, sev, "Extreme")) return "🔴";
    if (std.mem.eql(u8, sev, "Severe")) return "🟠";
    if (std.mem.eql(u8, sev, "Moderate")) return "🟡";
    if (std.mem.eql(u8, sev, "Minor")) return "🔵";
    return "⚪";
}

fn alertsImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, fetch: FetchFn) !mcp.ToolResult {
    const coords = getCoords(alloc, args) catch |err| return coordsError(alloc, err);
    const active_only = argBool(args, "active_only", true);

    var url_buf: [512]u8 = undefined;
    const url = try noaaAlertsUrl(&url_buf, coords.lat, coords.lon, active_only);
    const parsed = switch (try fetchJson(alloc, io, fetch, url, "NOAA")) {
        .parsed => |p| p,
        .err_result => |tr| return tr,
    };
    defer parsed.deinit();

    const features_v = jObj(parsed.value, "features");
    const alerts = if (features_v != null and features_v.? == .array) features_v.?.array.items else &[_]std.json.Value{};

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("# Weather Alerts\n\n");
    try w.print("**Location:** {d:.4}, {d:.4}\n", .{ coords.lat, coords.lon });
    try w.print("**Status:** {s}\n", .{if (active_only) "Active alerts only" else "All alerts"});
    if (jStr(parsed.value, "updated")) |upd| try w.print("**Updated:** {s}\n", .{upd});
    try w.writeByte('\n');

    if (alerts.len == 0) {
        try w.writeAll("✅ **No active weather alerts for this location.**\n\n");
        try w.writeAll("The area is currently clear of weather warnings, watches, and advisories.\n");
    } else {
        try w.print("⚠️ **{d} active alert{s} found**\n\n", .{ alerts.len, if (alerts.len > 1) "s" else "" });
        const sorted = try alloc.dupe(std.json.Value, alerts);
        std.mem.sort(std.json.Value, sorted, {}, struct {
            fn less(_: void, a: std.json.Value, b: std.json.Value) bool {
                const ap = jObj(a, "properties") orelse return false;
                const bp = jObj(b, "properties") orelse return true;
                return severityRank(jStr(ap, "severity") orelse "") < severityRank(jStr(bp, "severity") orelse "");
            }
        }.less);
        for (sorted) |alert| {
            const props = jObj(alert, "properties") orelse continue;
            const sev = jStr(props, "severity") orelse "Unknown";
            try w.print("{s} **{s}**\n---\n", .{ severityEmoji(sev), jStr(props, "event") orelse "Alert" });
            if (jStr(props, "headline")) |h| try w.print("**{s}**\n\n", .{h});
            try w.print("**Severity:** {s} | **Urgency:** {s} | **Certainty:** {s}\n", .{ sev, jStr(props, "urgency") orelse "Unknown", jStr(props, "certainty") orelse "Unknown" });
            try w.print("**Area:** {s}\n", .{jStr(props, "areaDesc") orelse "Unknown"});
            if (jStr(props, "effective")) |e| try w.print("**Effective:** {s}\n", .{e});
            if (jStr(props, "expires")) |e| try w.print("**Expires:** {s}\n", .{e});
            const onset = jStr(props, "onset");
            const effective = jStr(props, "effective");
            if (onset != null and (effective == null or !std.mem.eql(u8, onset.?, effective.?))) {
                try w.print("**Onset:** {s}\n", .{onset.?});
            }
            if (jStr(props, "ends")) |e| try w.print("**Ends:** {s}\n", .{e});
            if (jStr(props, "description")) |d| try w.print("\n**Description:**\n{s}\n", .{d});
            if (jStr(props, "instruction")) |instr| try w.print("\n**Instructions:**\n{s}\n", .{instr});
            if (jStr(props, "response")) |r| try w.print("\n**Recommended Response:** {s}\n", .{r});
            if (jStr(props, "senderName")) |s| try w.print("**Sender:** {s}\n\n", .{s});
        }
    }
    try w.writeAll("---\n*Data source: NOAA National Weather Service*\n");
    return .{ .text = try withAttribution(alloc, out.written(), ATTR_NOAA) };
}

// --- get_historical_weather ---

fn historicalImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, now_secs: i64, fetch: FetchFn) !mcp.ToolResult {
    const coords = getCoords(alloc, args) catch |err| return coordsError(alloc, err);
    const start_raw = argStr(args, "start_date") orelse {
        return .{ .text = "Invalid start_date: must be a string (YYYY-MM-DD or ISO 8601 datetime)", .is_error = true };
    };
    const end_raw = argStr(args, "end_date") orelse {
        return .{ .text = "Invalid end_date: must be a string (YYYY-MM-DD or ISO 8601 datetime)", .is_error = true };
    };
    const start_ymd = parseYmd(start_raw) orelse {
        return .{ .text = try std.fmt.allocPrint(alloc, "Invalid start_date: \"{s}\" is not a valid date format", .{start_raw}), .is_error = true };
    };
    const end_ymd = parseYmd(end_raw) orelse {
        return .{ .text = try std.fmt.allocPrint(alloc, "Invalid end_date: \"{s}\" is not a valid date format", .{end_raw}), .is_error = true };
    };
    const start_days = daysFromCivil(start_ymd.y, start_ymd.m, start_ymd.d);
    const end_days = daysFromCivil(end_ymd.y, end_ymd.m, end_ymd.d);
    if (start_days > end_days) {
        return .{ .text = "Invalid date range: start_date must be before or equal to end_date", .is_error = true };
    }
    const now_days = @divFloor(now_secs, 86400);
    if (start_days > now_days) {
        return .{ .text = try std.fmt.allocPrint(alloc, "Start date ({s}) cannot be in the future.", .{isoDatePart(start_raw)}), .is_error = true };
    }
    if (end_days > now_days) {
        return .{ .text = try std.fmt.allocPrint(alloc, "End date ({s}) cannot be in the future.", .{isoDatePart(end_raw)}), .is_error = true };
    }
    var limit: i64 = 168;
    if (argPosInt(args, "limit", 1, 500) catch {
        return .{ .text = "Invalid limit: must be an integer between 1 and 500.", .is_error = true };
    }) |l| limit = l;

    const use_archival = start_days < now_days - 7;
    if (use_archival) {
        return historicalArchive(alloc, io, coords, isoDatePart(start_raw), isoDatePart(end_raw), start_days, end_days, limit, fetch);
    }
    return historicalNoaaRecent(alloc, io, coords, start_raw, end_raw, limit, fetch);
}

fn historicalArchive(alloc: std.mem.Allocator, io: std.Io, coords: anytype, start_date: []const u8, end_date: []const u8, start_days: i64, end_days: i64, limit: i64, fetch: FetchFn) !mcp.ToolResult {
    const use_hourly = (end_days - start_days) <= 31;
    var url_buf: [4096]u8 = undefined;
    const url = try omArchiveUrl(&url_buf, coords.lat, coords.lon, start_date, end_date, use_hourly);
    const parsed = switch (try fetchJson(alloc, io, fetch, url, "Open-Meteo")) {
        .parsed => |p| p,
        .err_result => |tr| return tr,
    };
    defer parsed.deinit();

    const root = parsed.value;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    const lat_res = jNum(root, "latitude") orelse coords.lat;
    const lon_res = jNum(root, "longitude") orelse coords.lon;
    const elev = jNum(root, "elevation") orelse 0;

    const hourly_v = jObj(root, "hourly");
    const daily_v = jObj(root, "daily");

    if (use_hourly and hourly_v != null and hourly_v.? == .object) {
        const h = hourly_v.?;
        const times_v = jObj(h, "time");
        const total = if (times_v != null and times_v.? == .array) times_v.?.array.items.len else 0;
        if (total == 0) {
            return .{ .text = try std.fmt.allocPrint(alloc, "No historical weather data available for the specified date range ({s} to {s}).", .{ start_date, end_date }), .is_error = true };
        }
        const n = @min(total, @as(usize, @intCast(limit)));
        try w.writeAll("# Historical Weather Observations (Hourly)\n\n");
        try w.print("**Period:** {s} to {s}\n", .{ start_date, end_date });
        try w.print("**Location:** {d:.4}°N, {d:.4}°{s} ({d:.0}m elevation)\n", .{ lat_res, @abs(lon_res), if (lon_res >= 0) "E" else "W", elev });
        try w.print("**Number of observations:** {d}\n", .{total});
        try w.writeAll("**Data source:** Open-Meteo Historical Weather API (Reanalysis)\n\n");

        const t2m = jObj(h, "temperature_2m") orelse .null;
        const at = jObj(h, "apparent_temperature") orelse .null;
        const wc = jObj(h, "weather_code") orelse .null;
        const precip = jObj(h, "precipitation") orelse .null;
        const snow = jObj(h, "snowfall") orelse .null;
        const ws = jObj(h, "wind_speed_10m") orelse .null;
        const wd = jObj(h, "wind_direction_10m") orelse .null;
        const rh = jObj(h, "relative_humidity_2m") orelse .null;
        const pres = jObj(h, "pressure_msl") orelse .null;
        const cc = jObj(h, "cloud_cover") orelse .null;
        for (0..n) |i| {
            try w.print("## {s}\n", .{arrStr(times_v.?, i) orelse "?"});
            if (arrNum(t2m, i)) |t| try w.print("- **Temperature:** {d:.0}°F\n", .{@round(t)});
            if (arrNum(at, i)) |t| try w.print("- **Feels Like:** {d:.0}°F\n", .{@round(t)});
            if (arrNum(wc, i)) |c| try w.print("- **Conditions:** {s}\n", .{weatherDescription(@intFromFloat(c))});
            if (arrNum(precip, i)) |p| {
                if (p > 0) try w.print("- **Precipitation:** {d:.2} in\n", .{p});
            }
            if (arrNum(snow, i)) |s| {
                if (s > 0) try w.print("- **Snowfall:** {d:.1} in\n", .{s});
            }
            if (arrNum(ws, i)) |s| {
                try w.print("- **Wind:** {d:.0} mph", .{@round(s)});
                if (arrNum(wd, i)) |dd| try w.print(" from {d:.0}°", .{@round(dd)});
                try w.writeByte('\n');
            }
            if (arrNum(rh, i)) |r| try w.print("- **Humidity:** {d:.0}%\n", .{@round(r)});
            if (arrNum(pres, i)) |p| try w.print("- **Pressure:** {d:.2} inHg\n", .{p * 0.02953});
            if (arrNum(cc, i)) |c| try w.print("- **Cloud Cover:** {d:.0}%\n", .{c});
            try w.writeByte('\n');
        }
        return .{ .text = try withAttribution(alloc, out.written(), ATTR_OPEN_METEO) };
    }
    if (daily_v != null and daily_v.? == .object) {
        const d = daily_v.?;
        const times_v = jObj(d, "time");
        const total = if (times_v != null and times_v.? == .array) times_v.?.array.items.len else 0;
        if (total == 0) {
            return .{ .text = try std.fmt.allocPrint(alloc, "No historical weather data available for the specified date range ({s} to {s}).", .{ start_date, end_date }), .is_error = true };
        }
        try w.writeAll("# Historical Weather Data (Daily Summaries)\n\n");
        try w.print("**Period:** {s} to {s}\n", .{ start_date, end_date });
        try w.print("**Location:** {d:.4}°N, {d:.4}°{s} ({d:.0}m elevation)\n", .{ lat_res, @abs(lon_res), if (lon_res >= 0) "E" else "W", elev });
        try w.print("**Number of days:** {d}\n", .{total});
        try w.writeAll("**Data source:** Open-Meteo Historical Weather API (Reanalysis)\n\n");

        const tmax = jObj(d, "temperature_2m_max") orelse .null;
        const tmin = jObj(d, "temperature_2m_min") orelse .null;
        const tmean = jObj(d, "temperature_2m_mean") orelse .null;
        const wc = jObj(d, "weather_code") orelse .null;
        const psum = jObj(d, "precipitation_sum") orelse .null;
        const ssum = jObj(d, "snowfall_sum") orelse .null;
        const wsmax = jObj(d, "wind_speed_10m_max") orelse .null;
        for (0..total) |i| {
            try w.print("## {s}\n", .{arrStr(times_v.?, i) orelse "?"});
            if (arrNum(tmax, i)) |t| try w.print("- **High Temperature:** {d:.0}°F\n", .{@round(t)});
            if (arrNum(tmin, i)) |t| try w.print("- **Low Temperature:** {d:.0}°F\n", .{@round(t)});
            if (arrNum(tmean, i)) |t| try w.print("- **Average Temperature:** {d:.0}°F\n", .{@round(t)});
            if (arrNum(wc, i)) |c| try w.print("- **Conditions:** {s}\n", .{weatherDescription(@intFromFloat(c))});
            if (arrNum(psum, i)) |p| try w.print("- **Precipitation:** {d:.2} in\n", .{p});
            if (arrNum(ssum, i)) |s| {
                if (s > 0) try w.print("- **Snowfall:** {d:.1} in\n", .{s});
            }
            if (arrNum(wsmax, i)) |s| try w.print("- **Max Wind Speed:** {d:.0} mph\n", .{@round(s)});
            try w.writeByte('\n');
        }
        return .{ .text = try withAttribution(alloc, out.written(), ATTR_OPEN_METEO) };
    }
    return .{ .text = "No weather data available in response", .is_error = true };
}

fn historicalNoaaRecent(alloc: std.mem.Allocator, io: std.Io, coords: anytype, start_raw: []const u8, end_raw: []const u8, limit: i64, fetch: FetchFn) !mcp.ToolResult {
    var url_buf: [512]u8 = undefined;
    const stations_url = try std.fmt.bufPrint(&url_buf, "https://api.weather.gov/points/{d:.4},{d:.4}/stations", .{ coords.lat, coords.lon });
    const stations = switch (try fetchJson(alloc, io, fetch, stations_url, "NOAA")) {
        .parsed => |p| p,
        .err_result => |tr| return tr,
    };
    defer stations.deinit();
    const features_v = jObj(stations.value, "features");
    const features = if (features_v != null and features_v.? == .array) features_v.?.array.items else &[_]std.json.Value{};
    if (features.len == 0) {
        return .{ .text = "No weather stations found near the specified location.", .is_error = true };
    }
    const props0 = jObj(features[0], "properties") orelse {
        return .{ .text = "No weather stations found near the specified location.", .is_error = true };
    };
    const station_id = jStr(props0, "stationIdentifier") orelse {
        return .{ .text = "No weather stations found near the specified location.", .is_error = true };
    };

    const start_iso = try rfc3339(alloc, start_raw);
    const end_iso = try rfc3339(alloc, end_raw);
    var obs_url_buf: [1024]u8 = undefined;
    const obs_url = try std.fmt.bufPrint(&obs_url_buf, "https://api.weather.gov/stations/{s}/observations?start={s}&end={s}&limit={d}", .{ station_id, start_iso, end_iso, limit });
    const parsed = switch (try fetchJson(alloc, io, fetch, obs_url, "NOAA")) {
        .parsed => |p| p,
        .err_result => |tr| return tr,
    };
    defer parsed.deinit();

    const obs_features_v = jObj(parsed.value, "features");
    const obs_features = if (obs_features_v != null and obs_features_v.? == .array) obs_features_v.?.array.items else &[_]std.json.Value{};
    if (obs_features.len == 0) {
        return .{ .text = try std.fmt.allocPrint(alloc,
            \\No historical observations found for the specified date range ({s} to {s}).
            \\
            \\This may occur because:
            \\- The dates are outside the station's available data range
            \\- There are gaps in the observation records for this location
            \\- The weather station near this location may not have archived data for these dates
        , .{ start_raw, end_raw }) };
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("# Historical Weather Observations\n\n");
    try w.print("**Period:** {s} to {s}\n", .{ isoDatePart(start_raw), isoDatePart(end_raw) });
    try w.print("**Number of observations:** {d}\n", .{obs_features.len});
    try w.writeAll("**Data source:** NOAA Real-time API\n\n");
    for (obs_features) |obs_f| {
        const props = jObj(obs_f, "properties") orelse continue;
        try w.print("## {s}\n", .{jStr(props, "timestamp") orelse "?"});
        if (noaaQty(props, "temperature")) |t| {
            if (toFahrenheit(t, noaaQtyUnit(props, "temperature"))) |tf| {
                try w.print("- **Temperature:** {d:.0}°F\n", .{@round(tf)});
            }
        }
        if (jStr(props, "textDescription")) |td| try w.print("- **Conditions:** {s}\n", .{td});
        if (noaaQty(props, "windSpeed")) |ws| {
            const unit = noaaQtyUnit(props, "windSpeed");
            const mph = if (std.mem.indexOf(u8, unit, "km_h") != null) ws * 0.621371 else ws * 2.23694;
            try w.print("- **Wind:** {d:.0} mph\n", .{@round(mph)});
        }
        try w.writeByte('\n');
    }
    return .{ .text = try withAttribution(alloc, out.written(), ATTR_NOAA) };
}

// --- check_service_status ---

const ServiceProbe = struct {
    operational: bool,
    message: []const u8,
};

fn probeService(alloc: std.mem.Allocator, io: std.Io, fetch: FetchFn, url: []const u8, name: []const u8, ok_statuses: []const u16) ServiceProbe {
    const resp = fetch(alloc, io, url) catch {
        return .{ .operational = false, .message = std.fmt.allocPrint(alloc, "Cannot connect to {s} (network failure)", .{name}) catch "connection failure" };
    };
    for (ok_statuses) |s| {
        if (resp.status == s) {
            if (s == 200) return .{ .operational = true, .message = std.fmt.allocPrint(alloc, "{s} is operational", .{name}) catch "operational" };
            return .{ .operational = true, .message = std.fmt.allocPrint(alloc, "{s} is responding (HTTP {d})", .{ name, s }) catch "responding" };
        }
    }
    return .{ .operational = false, .message = std.fmt.allocPrint(alloc, "{s} is experiencing server errors (HTTP {d})", .{ name, resp.status }) catch "server error" };
}

fn statusImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, fetch: FetchFn) !mcp.ToolResult {
    _ = args;
    const noaa = probeService(alloc, io, fetch, "https://api.weather.gov/points/39.8283,-98.5795", "NOAA Weather API", &.{ 200, 404, 429 });
    const om = probeService(alloc, io, fetch, "https://archive-api.open-meteo.com/v1/archive?latitude=51.5074&longitude=-0.1278&start_date=2020-01-01&end_date=2020-01-01&daily=temperature_2m_max&timezone=UTC", "Open-Meteo API", &.{ 200, 400, 429 });

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("# Weather API Service Status\n\n");
    try w.writeAll("## Server Version\n\n");
    try w.writeAll("**Installed Version:** 0.1.0 (zmcp-weather)\n");
    try w.writeAll("**Upstream Reference:** https://github.com/dgahagan/weather-mcp/releases/latest\n\n");

    try w.writeAll("## NOAA Weather API (Forecasts & Current Conditions)\n\n");
    try w.print("**Status:** {s}\n", .{if (noaa.operational) "✅ Operational" else "❌ Issues Detected"});
    try w.print("**Message:** {s}\n", .{noaa.message});
    try w.writeAll("**Status Page:** https://weather-gov.github.io/api/planned-outages\n");
    try w.writeAll("**Coverage:** United States locations only\n\n");
    if (!noaa.operational) {
        try w.writeAll("**Recommended Actions:**\n");
        try w.writeAll("- Check planned outages: https://weather-gov.github.io/api/planned-outages\n");
        try w.writeAll("- View service notices: https://www.weather.gov/notification\n\n");
    }

    try w.writeAll("## Open-Meteo API (Historical Weather Data)\n\n");
    try w.print("**Status:** {s}\n", .{if (om.operational) "✅ Operational" else "❌ Issues Detected"});
    try w.print("**Message:** {s}\n", .{om.message});
    try w.writeAll("**Status Page:** https://open-meteo.com/en/docs/model-updates\n");
    try w.writeAll("**Coverage:** Global (worldwide locations)\n\n");
    if (!om.operational) {
        try w.writeAll("**Recommended Actions:**\n");
        try w.writeAll("- Check production status: https://open-meteo.com/en/docs/model-updates\n");
        try w.writeAll("- View GitHub issues: https://github.com/open-meteo/open-meteo/issues\n\n");
    }

    if (noaa.operational and om.operational) {
        try w.writeAll("## Overall Status: ✅ All Services Operational\n\n");
        try w.writeAll("Both NOAA and Open-Meteo APIs are functioning normally. Weather data requests should succeed.\n");
    } else if (!noaa.operational and !om.operational) {
        try w.writeAll("## Overall Status: ❌ Multiple Service Issues\n\n");
        try w.writeAll("Both weather APIs are experiencing issues. Please check the status pages above for updates.\n");
    } else {
        try w.writeAll("## Overall Status: ⚠️ Partial Service Availability\n\n");
        if (noaa.operational) {
            try w.writeAll("NOAA API is operational: Forecasts and current conditions for US locations are available.\n");
            try w.writeAll("Open-Meteo API has issues: Historical weather data may be unavailable.\n");
        } else {
            try w.writeAll("Open-Meteo API is operational: Historical weather data is available globally.\n");
            try w.writeAll("NOAA API has issues: Forecasts and current conditions for US locations may be unavailable.\n");
        }
    }
    return .{ .text = try alloc.dupe(u8, out.written()) };
}

// --- get_air_quality ---

fn pollutantDisplayName(key: []const u8) []const u8 {
    const map = .{
        .{ "pm2_5", "PM2.5 (Fine Particulate Matter)" },
        .{ "pm10", "PM10 (Coarse Particulate Matter)" },
        .{ "ozone", "Ozone (O₃)" },
        .{ "nitrogen_dioxide", "Nitrogen Dioxide (NO₂)" },
        .{ "sulphur_dioxide", "Sulfur Dioxide (SO₂)" },
        .{ "carbon_monoxide", "Carbon Monoxide (CO)" },
        .{ "ammonia", "Ammonia (NH₃)" },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, key, entry[0])) return entry[1];
    }
    return key;
}

fn aqiEmoji(level: []const u8) []const u8 {
    if (std.mem.eql(u8, level, "Good")) return "🟢";
    if (std.mem.eql(u8, level, "Fair")) return "🟢";
    if (std.mem.eql(u8, level, "Moderate")) return "🟡";
    if (std.mem.eql(u8, level, "Unhealthy for Sensitive Groups")) return "🟠";
    if (std.mem.eql(u8, level, "Poor")) return "🟠";
    if (std.mem.eql(u8, level, "Unhealthy")) return "🔴";
    if (std.mem.eql(u8, level, "Very Poor")) return "🔴";
    if (std.mem.eql(u8, level, "Very Unhealthy")) return "🟣";
    return "🟤";
}

fn uvEmoji(level: []const u8) []const u8 {
    if (std.mem.eql(u8, level, "Low")) return "🟢";
    if (std.mem.eql(u8, level, "Moderate")) return "🟡";
    if (std.mem.eql(u8, level, "High")) return "🟠";
    if (std.mem.eql(u8, level, "Very High")) return "🔴";
    return "🟣";
}

fn writePollutantConc(w: *std.Io.Writer, value: f64, units: []const u8) !void {
    if (value < 1) {
        try w.print("{d:.2}", .{value});
    } else if (value < 10) {
        try w.print("{d:.1}", .{value});
    } else {
        try w.print("{d:.0}", .{@round(value)});
    }
    if (units.len > 0) try w.print(" {s}", .{units});
}

fn airQualityImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, fetch: FetchFn) !mcp.ToolResult {
    const coords = getCoords(alloc, args) catch |err| return coordsError(alloc, err);
    const want_forecast = argBool(args, "forecast", false);

    var url_buf: [4096]u8 = undefined;
    const url = try omAirQualityUrl(&url_buf, coords.lat, coords.lon, if (want_forecast) 5 else null);
    const parsed = switch (try fetchJson(alloc, io, fetch, url, "Open-Meteo")) {
        .parsed => |p| p,
        .err_result => |tr| return tr,
    };
    defer parsed.deinit();

    const root = parsed.value;
    const current_v = jObj(root, "current");
    if (current_v == null or current_v.? != .object) {
        return .{ .text = "No current air quality data available for the specified location", .is_error = true };
    }
    const current = current_v.?;
    const units_v = jObj(root, "current_units");
    const use_us = shouldUseUSAQI(coords.lat, coords.lon);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("# Air Quality Report\n\n");
    try w.print("**Location:** {d:.4}, {d:.4}\n", .{ coords.lat, coords.lon });
    if (jStr(root, "timezone")) |tz| try w.print("**Timezone:** {s}\n", .{tz});
    if (jNum(root, "elevation")) |e| try w.print("**Elevation:** {d:.0}m\n", .{@round(e)});
    try w.writeByte('\n');
    if (jStr(current, "time")) |t| try w.print("**Observation Time:** {s}\n\n", .{t});

    const us_aqi = jNum(current, "us_aqi");
    const eu_aqi = jNum(current, "european_aqi");
    if (use_us and us_aqi != null) {
        const cat = usAqiCategory(us_aqi.?);
        try w.print("## {s} US Air Quality Index: {d:.0}\n\n", .{ aqiEmoji(cat.level), @round(us_aqi.?) });
        try w.print("**Category:** {s} ({s})\n", .{ cat.level, cat.color });
        try w.print("**Description:** {s}\n\n", .{cat.description});
        try w.print("**Health Implications:**\n{s}\n\n", .{cat.health_implications});
        if (!std.mem.eql(u8, cat.cautionary, "None")) try w.print("⚠️ **Caution:** {s}\n\n", .{cat.cautionary});
    } else if (!use_us and eu_aqi != null) {
        const cat = euAqiCategory(eu_aqi.?);
        try w.print("## {s} European Air Quality Index: {d:.0}\n\n", .{ aqiEmoji(cat.level), @round(eu_aqi.?) });
        try w.print("**Category:** {s} ({s})\n", .{ cat.level, cat.color });
        try w.print("**Description:** {s}\n\n", .{cat.description});
        try w.print("**Health Implications:**\n{s}\n\n", .{cat.health_implications});
        if (!std.mem.eql(u8, cat.cautionary, "None")) try w.print("⚠️ **Caution:** {s}\n\n", .{cat.cautionary});
    }

    if (jNum(current, "uv_index")) |uv| {
        const cat = uvIndexCategory(uv);
        try w.print("## {s} UV Index: {d:.1}\n\n", .{ uvEmoji(cat.level), uv });
        try w.print("**Level:** {s}\n", .{cat.level});
        try w.print("**Description:** {s}\n", .{cat.description});
        try w.print("**Recommendation:** {s}\n\n", .{cat.recommendation});
        if (jNum(current, "uv_index_clear_sky")) |ucs| {
            if (@abs(ucs - uv) > 1) try w.print("*Note: UV index under clear sky would be {d:.1}*\n\n", .{ucs});
        }
    }

    try w.writeAll("## Pollutant Concentrations\n\n");
    const pollutant_keys = [_][]const u8{ "pm2_5", "pm10", "ozone", "nitrogen_dioxide", "sulphur_dioxide", "carbon_monoxide", "ammonia" };
    for (pollutant_keys) |key| {
        if (jNum(current, key)) |v| {
            const units = if (units_v != null and units_v.? == .object) (jStr(units_v.?, key) orelse "") else "";
            try w.print("**{s}:** ", .{pollutantDisplayName(key)});
            try writePollutantConc(w, v, units);
            try w.writeByte('\n');
        }
    }
    if (jNum(current, "aerosol_optical_depth")) |aod| {
        try w.print("**Aerosol Optical Depth:** {d:.3} (atmospheric haze indicator)\n", .{aod});
    }
    try w.writeByte('\n');

    if (use_us and eu_aqi != null) {
        try w.print("*European AQI: {d:.0} ({s})*\n\n", .{ @round(eu_aqi.?), euAqiCategory(eu_aqi.?).level });
    } else if (!use_us and us_aqi != null) {
        try w.print("*US AQI: {d:.0} ({s})*\n\n", .{ @round(us_aqi.?), usAqiCategory(us_aqi.?).level });
    }

    if (want_forecast) {
        const hourly_v = jObj(root, "hourly");
        if (hourly_v != null and hourly_v.? == .object) {
            const h = hourly_v.?;
            const times_v = jObj(h, "time");
            const total = if (times_v != null and times_v.? == .array) times_v.?.array.items.len else 0;
            if (total > 0) {
                const aqi_arr = jObj(h, if (use_us) "us_aqi" else "european_aqi") orelse .null;
                const hours = @min(total, 24);
                try w.writeAll("---\n\n## Air Quality Forecast\n\n");
                try w.print("**Next {d} hours:**\n\n", .{hours});
                var start: usize = 0;
                while (start < hours) : (start += 6) {
                    const end = @min(start + 6, hours);
                    var min_aqi: f64 = std.math.inf(f64);
                    var max_aqi: f64 = -std.math.inf(f64);
                    for (start..end) |j| {
                        if (arrNum(aqi_arr, j)) |v| {
                            min_aqi = @min(min_aqi, v);
                            max_aqi = @max(max_aqi, v);
                        }
                    }
                    if (min_aqi == std.math.inf(f64)) continue;
                    const cat = if (use_us) usAqiCategory((min_aqi + max_aqi) / 2) else euAqiCategory((min_aqi + max_aqi) / 2);
                    try w.print("**{s} - {s}:** {s} AQI {d:.0}-{d:.0} ({s})\n", .{
                        arrStr(times_v.?, start) orelse "?",
                        arrStr(times_v.?, end - 1) orelse "?",
                        if (use_us) "US" else "EU",
                        @round(min_aqi),
                        @round(max_aqi),
                        cat.level,
                    });
                }
                try w.print("\n*Forecast includes {d} hours of data*\n", .{total});
            }
        }
    }
    return .{ .text = try withAttribution(alloc, out.written(), ATTR_OPEN_METEO) };
}

// --- get_marine_conditions ---

fn marineImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, fetch: FetchFn) !mcp.ToolResult {
    const coords = getCoords(alloc, args) catch |err| return coordsError(alloc, err);
    const want_forecast = argBool(args, "forecast", false);

    var url_buf: [4096]u8 = undefined;
    const url = try omMarineUrl(&url_buf, coords.lat, coords.lon, if (want_forecast) 5 else null);
    const parsed = switch (try fetchJson(alloc, io, fetch, url, "Open-Meteo")) {
        .parsed => |p| p,
        .err_result => |tr| return tr,
    };
    defer parsed.deinit();

    const root = parsed.value;
    const current_v = jObj(root, "current");
    if (current_v == null or current_v.? != .object) {
        return .{ .text = "No current marine conditions data available for the specified location", .is_error = true };
    }
    const current = current_v.?;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("# Marine Conditions Report\n\n");
    try w.print("**Location:** {d:.4}, {d:.4}\n", .{ coords.lat, coords.lon });
    if (jStr(root, "timezone")) |tz| try w.print("**Timezone:** {s}\n", .{tz});
    try w.writeByte('\n');
    try w.writeAll("⚠️ **DISCLAIMER:** This data is modeled and may have limited accuracy in coastal areas. **NOT suitable for coastal navigation.** Always consult official marine forecasts for safety-critical decisions.\n\n");
    if (jStr(current, "time")) |t| try w.print("**Observation Time:** {s}\n\n", .{t});

    const wave_h = jNum(current, "wave_height");
    const wind_wave_h = jNum(current, "wind_wave_height");
    const swell_h = jNum(current, "swell_wave_height");
    const wave_p = jNum(current, "wave_period");

    if (wave_h) |wh| {
        const cat = waveHeightCategory(wh);
        var desc: []const u8 = cat.description;
        if (wave_p != null and wave_p.? < 6 and wh > 1.0) {
            desc = try std.fmt.allocPrint(alloc, "{s} and choppy (short period)", .{desc});
        } else if (wave_p != null and wave_p.? > 12 and wh > 2.0) {
            desc = try std.fmt.allocPrint(alloc, "{s} with long-period swell (powerful)", .{desc});
        }
        var ctx: []const u8 = "";
        if (wind_wave_h != null and swell_h != null) {
            if (wind_wave_h.? > swell_h.? * 1.5) {
                ctx = " Conditions dominated by local wind waves.";
            } else if (swell_h.? > wind_wave_h.? * 1.5) {
                ctx = " Conditions dominated by swell from distant systems.";
            } else {
                ctx = " Mixed wind and swell conditions.";
            }
        }
        const emoji = if (std.mem.eql(u8, cat.level, "Calm"))
            "🟢"
        else if (std.mem.eql(u8, cat.level, "Slight") or std.mem.eql(u8, cat.level, "Moderate"))
            "🟡"
        else if (std.mem.eql(u8, cat.level, "Rough"))
            "🟠"
        else if (std.mem.eql(u8, cat.level, "Very Rough"))
            "🔴"
        else
            "🟤";
        try w.print("## {s} Current Conditions: {s}\n\n", .{ emoji, cat.level });
        try w.print("{s}{s}\n\n", .{ desc, ctx });
    } else {
        try w.writeAll("## ⚪ Current Conditions: Unknown\n\nMarine conditions data not available\n\n");
    }

    try w.writeAll("## 🌊 Wave Conditions\n\n");
    if (wave_h) |wh| {
        const cat = waveHeightCategory(wh);
        try w.print("**Significant Wave Height:** {d:.1}m ({d:.1}ft) ({s})\n", .{ wh, wh * 3.28084, cat.description });
    }
    if (jNum(current, "wave_direction")) |d| {
        try w.print("**Wave Direction:** {s} ({d:.0}°)\n", .{ cardinalDirection(d), @round(@mod(d + 360, 360)) });
    }
    if (wave_p) |p| try w.print("**Wave Period:** {d:.1}s\n", .{p});
    try w.writeByte('\n');

    if (wind_wave_h != null and wind_wave_h.? > 0) {
        try w.writeAll("### Wind Waves\n\n");
        try w.print("**Height:** {d:.1}m ({d:.1}ft)\n", .{ wind_wave_h.?, wind_wave_h.? * 3.28084 });
        if (jNum(current, "wind_wave_direction")) |d| try w.print("**Direction:** {s} ({d:.0}°)\n", .{ cardinalDirection(d), @round(@mod(d + 360, 360)) });
        if (jNum(current, "wind_wave_period")) |p| try w.print("**Period:** {d:.1}s\n", .{p});
        if (jNum(current, "wind_wave_peak_period")) |p| try w.print("**Peak Period:** {d:.1}s\n", .{p});
        try w.writeByte('\n');
    }
    if (swell_h != null and swell_h.? > 0) {
        try w.writeAll("### Swell\n\n");
        try w.print("**Height:** {d:.1}m ({d:.1}ft)\n", .{ swell_h.?, swell_h.? * 3.28084 });
        if (jNum(current, "swell_wave_direction")) |d| try w.print("**Direction:** {s} ({d:.0}°)\n", .{ cardinalDirection(d), @round(@mod(d + 360, 360)) });
        if (jNum(current, "swell_wave_period")) |p| try w.print("**Period:** {d:.1}s\n", .{p});
        if (jNum(current, "swell_wave_peak_period")) |p| try w.print("**Peak Period:** {d:.1}s\n", .{p});
        try w.writeByte('\n');
    }
    if (jNum(current, "ocean_current_velocity") != null or jNum(current, "ocean_current_direction") != null) {
        try w.writeAll("## 🌀 Ocean Currents\n\n");
        if (jNum(current, "ocean_current_velocity")) |v| {
            try w.print("**Velocity:** {d:.2} m/s ({d:.2} knots)\n", .{ v, v * 1.94384 });
        }
        if (jNum(current, "ocean_current_direction")) |d| {
            try w.print("**Direction:** {s} ({d:.0}°)\n", .{ cardinalDirection(d), @round(@mod(d + 360, 360)) });
        }
        try w.writeByte('\n');
    }

    if (want_forecast) {
        const daily_v = jObj(root, "daily");
        if (daily_v != null and daily_v.? == .object) {
            const d = daily_v.?;
            const times_v = jObj(d, "time");
            const total = if (times_v != null and times_v.? == .array) times_v.?.array.items.len else 0;
            if (total > 0) {
                const n = @min(total, 5);
                try w.writeAll("---\n\n## 📅 Marine Forecast\n\n");
                try w.print("**Next {d} days:**\n\n", .{n});
                const whmax = jObj(d, "wave_height_max") orelse .null;
                const wddom = jObj(d, "wave_direction_dominant") orelse .null;
                const wpmax = jObj(d, "wave_period_max") orelse .null;
                const smax = jObj(d, "swell_wave_height_max") orelse .null;
                const sddom = jObj(d, "swell_wave_direction_dominant") orelse .null;
                for (0..n) |i| {
                    try w.print("**{s}:**\n", .{arrStr(times_v.?, i) orelse "?"});
                    if (arrNum(whmax, i)) |v| {
                        try w.print("  • Max Wave Height: {d:.1}m ({d:.1}ft) ({s})\n", .{ v, v * 3.28084, waveHeightCategory(v).description });
                    }
                    if (arrNum(wddom, i)) |v| try w.print("  • Wave Direction: {s} ({d:.0}°)\n", .{ cardinalDirection(v), @round(@mod(v + 360, 360)) });
                    if (arrNum(wpmax, i)) |v| try w.print("  • Max Wave Period: {d:.1}s\n", .{v});
                    if (arrNum(smax, i)) |v| {
                        if (v > 0.5) {
                            try w.print("  • Swell Height: {d:.1}m ({d:.1}ft)\n", .{ v, v * 3.28084 });
                            if (arrNum(sddom, i)) |sd| try w.print("  • Swell Direction: {s} ({d:.0}°)\n", .{ cardinalDirection(sd), @round(@mod(sd + 360, 360)) });
                        }
                    }
                    try w.writeByte('\n');
                }
            }
        }
    }

    try w.writeAll("---\n\n### Interpreting Marine Conditions\n\n");
    try w.writeAll("**Significant Wave Height:** The average height of the highest 1/3 of waves\n");
    try w.writeAll("**Wind Waves:** Waves generated by local winds (shorter period)\n");
    try w.writeAll("**Swell:** Long-period waves from distant weather systems (longer period)\n");
    try w.writeAll("**Wave Period:** Time between successive wave crests (longer = more powerful)\n\n");
    try w.writeAll("🟢 **Calm** (0-2m): Safe for most vessels\n");
    try w.writeAll("🟡 **Moderate** (2-4m): Challenging for small craft\n");
    try w.writeAll("🟠 **Rough** (4-6m): Hazardous for small vessels\n");
    try w.writeAll("🔴 **Very Rough** (6-9m): Dangerous for most vessels\n");
    try w.writeAll("🟤 **High** (>9m): Extremely dangerous\n");
    return .{ .text = try withAttribution(alloc, out.written(), ATTR_OPEN_METEO) };
}

// --- get_weather_imagery ---

fn imageryImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, now_secs: i64, fetch: FetchFn) !mcp.ToolResult {
    const coords = getCoords(alloc, args) catch |err| return coordsError(alloc, err);
    const img_type = argStr(args, "type") orelse {
        return .{ .text = "type parameter is required (\"radar\", \"satellite\", or \"precipitation\")", .is_error = true };
    };
    const is_radar = std.mem.eql(u8, img_type, "radar") or std.mem.eql(u8, img_type, "precipitation");
    if (!is_radar and !std.mem.eql(u8, img_type, "satellite")) {
        return .{ .text = try std.fmt.allocPrint(alloc, "Invalid imagery type: {s}. Must be one of: radar, satellite, precipitation", .{img_type}), .is_error = true };
    }
    if (std.mem.eql(u8, img_type, "satellite")) {
        return .{ .text = "Satellite imagery is not yet implemented. Use type=\"precipitation\" or type=\"radar\" for precipitation radar.", .is_error = true };
    }
    const animated = argBool(args, "animated", false);

    const parsed = switch (try fetchJson(alloc, io, fetch, RAINVIEWER_URL, "RainViewer")) {
        .parsed => |p| p,
        .err_result => |tr| return tr,
    };
    defer parsed.deinit();

    const radar_v = jObj(parsed.value, "radar");
    const past_v = if (radar_v != null) jObj(radar_v.?, "past") else null;
    const frames = if (past_v != null and past_v.? == .array) past_v.?.array.items else &[_]std.json.Value{};

    const Frame = struct { ts: i64, path: []const u8 };
    var selected: std.ArrayList(Frame) = .empty;
    defer selected.deinit(alloc);
    if (frames.len > 0) {
        if (animated) {
            for (frames) |f| {
                const ts = jNum(f, "time") orelse continue;
                const path = jStr(f, "path") orelse continue;
                try selected.append(alloc, .{ .ts = @intFromFloat(ts), .path = path });
            }
        } else {
            const f = frames[frames.len - 1];
            if (jNum(f, "time")) |ts| {
                if (jStr(f, "path")) |path| {
                    try selected.append(alloc, .{ .ts = @intFromFloat(ts), .path = path });
                }
            }
        }
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("# Weather Imagery\n\n");
    try w.print("**Location:** {d:.4}, {d:.4}\n", .{ coords.lat, coords.lon });
    var cap_buf: [1]u8 = undefined;
    try w.print("**Type:** {s}{s}\n", .{ std.ascii.upperString(&cap_buf, img_type[0..1]), img_type[1..] });
    try w.writeAll("**Coverage:** Global\n");
    try w.print("**Resolution:** {s}\n", .{if (animated) "multiple frames" else "Latest snapshot"});
    try w.writeAll("**Source:** RainViewer\n");
    try w.print("**Animated:** {s}\n\n", .{if (animated) "Yes" else "No"});

    var ts_buf: [40]u8 = undefined;
    var url_buf: [512]u8 = undefined;
    if (animated and selected.items.len > 1) {
        try w.print("## 🎬 Animation Frames ({d} frames)\n\n", .{selected.items.len});
        // Show first, middle, last when there are many frames.
        var idxs: std.ArrayList(usize) = .empty;
        defer idxs.deinit(alloc);
        if (selected.items.len <= 5) {
            for (0..selected.items.len) |i| try idxs.append(alloc, i);
        } else {
            try idxs.append(alloc, 0);
            try idxs.append(alloc, selected.items.len / 2);
            try idxs.append(alloc, selected.items.len - 1);
        }
        for (idxs.items) |i| {
            const fr = selected.items[i];
            const tile = rainviewerTileUrl(&url_buf, fr.path, coords.lat, coords.lon, 6) catch continue;
            try w.print("### Frame {d} - {s}\n", .{ i + 1, isoFromUnix(&ts_buf, fr.ts) });
            try w.print("![Precipitation radar at {s}]({s})\n\n", .{ isoFromUnix(&ts_buf, fr.ts), tile });
        }
        if (selected.items.len > 5) {
            try w.print("*Showing 3 of {d} frames for brevity*\n\n", .{selected.items.len});
        }
    } else if (selected.items.len > 0) {
        const fr = selected.items[0];
        try w.writeAll("## 📸 Current Imagery\n\n");
        try w.print("**Timestamp:** {s}\n", .{isoFromUnix(&ts_buf, fr.ts)});
        const tile = rainviewerTileUrl(&url_buf, fr.path, coords.lat, coords.lon, 6) catch "";
        try w.print("![Precipitation radar at {s}]({s})\n\n", .{ isoFromUnix(&ts_buf, fr.ts), tile });
    } else {
        try w.writeAll("## ⚠️ No Imagery Available\n\nNo imagery data is currently available for this location and time.\n\n");
    }

    try w.writeAll("---\n\n⚠️ **DISCLAIMER:** RainViewer provides global precipitation radar. Data may have 5-10 minute delay. For official forecasts, consult local meteorological services.\n\n");
    try w.writeAll("---\n");
    try w.print("*Generated: {s}*\n", .{isoFromUnix(&ts_buf, now_secs)});
    try w.writeAll("*Data source: RainViewer*\n");
    return .{ .text = try alloc.dupe(u8, out.written()) };
}

// --- get_lightning_activity ---

fn lightningImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value) !mcp.ToolResult {
    _ = io;
    _ = getCoords(alloc, args) catch |err| return coordsError(alloc, err);
    if (argNum(args, "radius")) |r| {
        if (r < 1 or r > 500) {
            return .{ .text = "radius must be a number between 1 and 500 km", .is_error = true };
        }
    }
    if (argNum(args, "timeWindow")) |tw| {
        if (tw < 5 or tw > 120) {
            return .{ .text = "timeWindow must be a number between 5 and 120 minutes", .is_error = true };
        }
    }
    return .{ .text = try alloc.dupe(u8,
        \\Real-time lightning data is not available in this build.
        \\
        \\The reference implementation (weather-mcp) streams Blitzortung strikes over a
        \\plaintext MQTT broker (mqtt://blitzortung.ha.sed.pl:1883). This Zig port has no
        \\MQTT client, so live lightning data cannot be retrieved. The strike statistics
        \\and safety-assessment logic are ported and unit-tested; only the transport is
        \\missing. For lightning safety information, consult official weather services.
        \\When thunder roars, go indoors!
    ), .is_error = true };
}

// --- get_river_conditions ---

fn floodEmoji(category: []const u8) []const u8 {
    if (category.len == 0 or std.mem.eql(u8, category, "no flooding")) return "✅";
    if (std.mem.eql(u8, category, "action")) return "🟡";
    if (std.mem.eql(u8, category, "minor")) return "🟠";
    if (std.mem.eql(u8, category, "moderate")) return "🔴";
    if (std.mem.eql(u8, category, "major")) return "🔴🔴";
    return "⚪";
}

fn riverImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, fetch: FetchFn) !mcp.ToolResult {
    const coords = getCoords(alloc, args) catch |err| return coordsError(alloc, err);
    var radius: f64 = 50;
    if (argNum(args, "radius")) |r| {
        if (std.math.isFinite(r)) radius = @max(1, @min(500, r));
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("# River Conditions Report\n\n");
    try w.print("**Location:** {d:.4}, {d:.4}\n", .{ coords.lat, coords.lon });
    try w.print("**Search Radius:** {d:.0} km ({d:.1} miles)\n\n", .{ radius, radius * 0.621371 });

    const lat_delta = radius / 111.0;
    const lon_delta = radius / (111.0 * @cos(coords.lat * std.math.pi / 180.0));
    const west = @max(-180.0, coords.lon - lon_delta);
    const east = @min(180.0, coords.lon + lon_delta);
    const south = @max(-90.0, coords.lat - lat_delta);
    const north = @min(90.0, coords.lat + lat_delta);

    var url_buf: [1024]u8 = undefined;
    const url = try nwpsGaugesUrl(&url_buf, west, south, east, north);
    const fetch_result = fetchJson(alloc, io, fetch, url, "NWPS") catch {
        try w.writeAll("❌ **Error retrieving river gauge data**\n\nUnable to fetch river conditions.\n");
        try w.writeAll("\n---\n*Data sources: NOAA National Water Prediction Service (NWPS), USGS Water Services*\n");
        return .{ .text = try alloc.dupe(u8, out.written()) };
    };
    switch (fetch_result) {
        .err_result => |tr| {
            // Reference embeds the error in a normal (non-error) report.
            try w.print("❌ **Error retrieving river gauge data**\n\n{s}\n", .{tr.text});
            try w.writeAll("\n---\n*Data sources: NOAA National Water Prediction Service (NWPS), USGS Water Services*\n");
            return .{ .text = try alloc.dupe(u8, out.written()) };
        },
        .parsed => |parsed| {
            defer parsed.deinit();
            if (parsed.value != .array) {
                try w.writeAll("❌ **Error retrieving river gauge data**\n\nUnexpected response from NWPS.\n");
                try w.writeAll("\n---\n*Data sources: NOAA National Water Prediction Service (NWPS), USGS Water Services*\n");
                return .{ .text = try alloc.dupe(u8, out.written()) };
            }

            const GaugeDist = struct { gauge: std.json.Value, distance: f64 };
            var near: std.ArrayList(GaugeDist) = .empty;
            defer near.deinit(alloc);
            for (parsed.value.array.items) |g| {
                const glat = jNum(g, "latitude") orelse continue;
                const glon = jNum(g, "longitude") orelse continue;
                const dist = haversineKm(coords.lat, coords.lon, glat, glon);
                if (dist <= radius) try near.append(alloc, .{ .gauge = g, .distance = dist });
            }
            std.mem.sort(GaugeDist, near.items, {}, struct {
                fn less(_: void, a: GaugeDist, b: GaugeDist) bool {
                    return a.distance < b.distance;
                }
            }.less);

            if (near.items.len == 0) {
                try w.print("ℹ️ **No river gauges found within {d:.0} km**\n\n", .{radius});
                try w.writeAll("Try expanding the search radius or choosing a location closer to rivers or streams.\n\n");
                try w.writeAll("**Tip:** River gauges are typically located along major rivers and waterways.\n");
            } else {
                try w.print("📊 **Found {d} river gauge{s}**\n\n", .{ near.items.len, if (near.items.len > 1) "s" else "" });
                const max_show: usize = 5;
                const show = near.items[0..@min(near.items.len, max_show)];
                for (show) |gd| {
                    try formatGauge(w, alloc, gd.gauge, gd.distance);
                }
                if (near.items.len > max_show) {
                    try w.print("\n*Note: {d} additional gauges found within radius (showing nearest {d} only)*\n", .{ near.items.len - max_show, max_show });
                }
            }
        },
    }
    try w.writeAll("\n---\n*Data sources: NOAA National Water Prediction Service (NWPS), USGS Water Services*\n");
    try w.writeAll("*River conditions are updated hourly. Always consult official sources for critical decisions.*\n");
    return .{ .text = try withAttribution(alloc, out.written(), ATTR_NOAA) };
}

fn formatGauge(w: *std.Io.Writer, alloc: std.mem.Allocator, gauge: std.json.Value, distance: f64) !void {
    _ = alloc;
    try w.print("## {s}\n\n", .{jStr(gauge, "name") orelse "Unknown gauge"});
    try w.print("**Distance:** {d:.1} km ({d:.1} mi)\n", .{ distance, distance * 0.621371 });
    const state = jStr(gauge, "state") orelse "";
    const county = jStr(gauge, "county") orelse "";
    try w.print("**Location:** {s}", .{state});
    if (county.len > 0) try w.print(", {s} County", .{county});
    try w.writeByte('\n');
    if (jNum(gauge, "latitude") != null and jNum(gauge, "longitude") != null) {
        try w.print("**Coordinates:** {d:.4}, {d:.4}\n", .{ jNum(gauge, "latitude").?, jNum(gauge, "longitude").? });
    }
    const lid = jStr(gauge, "lid") orelse "";
    const usgs = jStr(gauge, "usgsId") orelse "";
    try w.print("**Gauge ID:** {s}", .{lid});
    if (usgs.len > 0) try w.print(" (USGS: {s})", .{usgs});
    try w.writeByte('\n');
    const in_service = if (jObj(gauge, "inService")) |v| (v == .bool and v.bool) else false;
    try w.print("**Status:** {s}\n\n", .{if (in_service) "✅ Active" else "❌ Out of Service"});

    const status_v = jObj(gauge, "status");
    try w.writeAll("### Current Conditions\n");
    const observed = if (status_v != null) jObj(status_v.?, "observed") else null;
    if (observed != null and observed.? == .object) {
        const obs = observed.?;
        if (jStr(obs, "validTime")) |vt| try w.print("**Observed:** {s}\n", .{vt});
        if (jNum(obs, "primary")) |p| try w.print("**River Stage:** {d:.2} ft\n", .{p});
        if (jNum(obs, "secondary")) |s| try w.print("**Flow Rate:** {d:.2} kcfs ({d:.0} cfs)\n", .{ s, s * 1000 });
        const cat = jStr(obs, "floodCategory") orelse "";
        try w.print("**Flood Category:** {s} {s}\n\n", .{ floodEmoji(cat), if (cat.len > 0) blk: {
            break :blk upperAlloc(w, cat) catch cat;
        } else "NO FLOODING" });
    } else {
        try w.writeAll("*No current observations available*\n\n");
    }

    const flood_v = jObj(gauge, "flood");
    const cats = if (flood_v != null) jObj(flood_v.?, "categories") else null;
    if (cats != null and cats.? == .object) {
        try w.writeAll("### Flood Stages\n");
        if (jNum(cats.?, "action")) |v| try w.print("**Action Stage:** {d:.1} ft\n", .{v});
        if (jNum(cats.?, "minor")) |v| try w.print("**Minor Flood:** {d:.1} ft\n", .{v});
        if (jNum(cats.?, "moderate")) |v| try w.print("**Moderate Flood:** {d:.1} ft\n", .{v});
        if (jNum(cats.?, "major")) |v| try w.print("**Major Flood:** {d:.1} ft\n", .{v});
        try w.writeByte('\n');
        if (observed != null and observed.? == .object) {
            if (jNum(observed.?, "primary")) |stage| {
                if (jNum(cats.?, "action")) |action| {
                    if (action > 0) try w.print("**Current stage is {d:.0}% of action stage**\n\n", .{stage / action * 100});
                }
            }
        }
    }

    const forecast_v = if (status_v != null) jObj(status_v.?, "forecast") else null;
    if (forecast_v != null and forecast_v.? == .object) {
        const fc = forecast_v.?;
        try w.writeAll("### Forecast\n");
        if (jStr(fc, "validTime")) |vt| try w.print("**Valid Time:** {s}\n", .{vt});
        if (jNum(fc, "primary")) |p| try w.print("**Forecasted Stage:** {d:.2} ft\n", .{p});
        if (jNum(fc, "secondary")) |s| try w.print("**Forecasted Flow:** {d:.2} kcfs\n", .{s});
        const cat = jStr(fc, "floodCategory") orelse "";
        try w.print("**Forecasted Category:** {s} {s}\n\n", .{ floodEmoji(cat), if (cat.len > 0) cat else "NO FLOODING" });
    }

    const crests = if (flood_v != null) jObj(flood_v.?, "crests") else null;
    const recent = if (crests != null) jObj(crests.?, "recent") else null;
    if (recent != null and recent.? == .array and recent.?.array.items.len > 0) {
        try w.writeAll("### Recent Historic Crests\n");
        const items = recent.?.array.items[0..@min(recent.?.array.items.len, 3)];
        for (items) |crest| {
            const date = jStr(crest, "date") orelse "";
            const year = if (date.len >= 4) date[0..4] else date;
            try w.print("- **{s}:** ", .{year});
            if (jNum(crest, "value")) |v| try w.print("{d:.2} ft", .{v});
            if (jNum(crest, "flow")) |f| try w.print(" ({d:.0} cfs)", .{f});
            if (jStr(crest, "description")) |d| try w.print(" - {s}", .{d});
            try w.writeByte('\n');
        }
        try w.writeByte('\n');
    }
    try w.writeAll("---\n\n");
}

fn upperAlloc(w: *std.Io.Writer, cat: []const u8) ![]const u8 {
    _ = w;
    // Flood category is lowercase in the API; uppercase letters into a static
    // buffer per call site (short strings like "no flooding").
    const S = struct {
        var buf: [64]u8 = undefined;
    };
    if (cat.len > S.buf.len) return cat;
    for (cat, 0..) |c, i| S.buf[i] = std.ascii.toUpper(c);
    return S.buf[0..cat.len];
}

// --- get_wildfire_info ---

fn wildfireImpl(alloc: std.mem.Allocator, io: std.Io, args: std.json.Value, fetch: FetchFn) !mcp.ToolResult {
    const coords = getCoords(alloc, args) catch |err| return coordsError(alloc, err);
    var radius: f64 = 100;
    if (argNum(args, "radius")) |r| {
        if (std.math.isFinite(r)) radius = @max(1, @min(500, r));
    }
    const now_ms = nowSeconds(io) * 1000;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    try w.writeAll("# Wildfire Information Report\n\n");
    try w.print("**Location:** {d:.4}, {d:.4}\n", .{ coords.lat, coords.lon });
    try w.print("**Search Radius:** {d:.0} km ({d:.1} miles)\n\n", .{ radius, radius * 0.621371 });

    const lat_off = radius / 111.0;
    const lon_off = radius / (111.0 * @cos(coords.lat * std.math.pi / 180.0));
    const west = coords.lon - lon_off;
    const east = coords.lon + lon_off;
    const south = coords.lat - lat_off;
    const north = coords.lat + lat_off;

    var url_buf: [2048]u8 = undefined;
    const url = try nifcQueryUrl(&url_buf, west, south, east, north);
    const fetch_result = fetchJson(alloc, io, fetch, url, "NIFC") catch {
        try w.writeAll("❌ **Error retrieving wildfire data**\n\nUnable to fetch fire information.\n");
        try writeWildfireFooter(w);
        return .{ .text = try alloc.dupe(u8, out.written()) };
    };
    switch (fetch_result) {
        .err_result => |tr| {
            try w.print("❌ **Error retrieving wildfire data**\n\n{s}\n", .{tr.text});
        },
        .parsed => |parsed| {
            defer parsed.deinit();
            const features_v = jObj(parsed.value, "features");
            const features = if (features_v != null and features_v.? == .array) features_v.?.array.items else &[_]std.json.Value{};
            if (features.len == 0) {
                try w.print("✅ **No active wildfires found within {d:.0} km**\n\n", .{radius});
                try w.writeAll("The area is currently clear of reported wildfire activity.\n\n");
                try w.writeAll("**Note:** This data includes active wildfires and prescribed burns tracked by the National Interagency Fire Center. Small fires or very recent ignitions may not yet be included.\n");
            } else {
                const Fire = struct {
                    name: []const u8,
                    distance: f64,
                    acres: f64,
                    containment: f64,
                    discovery_ms: i64,
                    lat: ?f64,
                    lon: ?f64,
                    state: []const u8,
                    county: []const u8,
                    city: []const u8,
                    ftype: []const u8,
                };
                var fires: std.ArrayList(Fire) = .empty;
                defer fires.deinit(alloc);
                for (features) |feature| {
                    const attrs = jObj(feature, "attributes") orelse continue;
                    var dist = radius;
                    var flat: ?f64 = null;
                    var flon: ?f64 = null;
                    if (jNum(attrs, "attr_InitialLatitude") != null and jNum(attrs, "attr_InitialLongitude") != null) {
                        flat = jNum(attrs, "attr_InitialLatitude");
                        flon = jNum(attrs, "attr_InitialLongitude");
                        dist = haversineKm(coords.lat, coords.lon, flat.?, flon.?);
                    } else if (jObj(feature, "geometry")) |geom| {
                        if (jObj(geom, "rings")) |rings| {
                            if (rings == .array and rings.array.items.len > 0) {
                                const ring0 = rings.array.items[0];
                                if (ring0 == .array and ring0.array.items.len > 0) {
                                    const pt = ring0.array.items[0];
                                    if (pt == .array and pt.array.items.len >= 2) {
                                        const plon = arrNum(pt, 0);
                                        const plat = arrNum(pt, 1);
                                        if (plon != null and plat != null) {
                                            flat = plat;
                                            flon = plon;
                                            dist = haversineKm(coords.lat, coords.lon, plat.?, plon.?);
                                        }
                                    }
                                }
                            }
                        }
                    }
                    if (dist > radius) continue;
                    const type_cat = jStr(attrs, "attr_IncidentTypeCategory") orelse "";
                    try fires.append(alloc, .{
                        .name = jStr(attrs, "poly_IncidentName") orelse "Unknown Fire",
                        .distance = dist,
                        .acres = jNum(attrs, "poly_GISAcres") orelse (jNum(attrs, "attr_FinalAcres") orelse (jNum(attrs, "attr_CalculatedAcres") orelse 0)),
                        .containment = clampContainment(jNum(attrs, "attr_PercentContained") orelse 0),
                        .discovery_ms = if (jNum(attrs, "attr_FireDiscoveryDateTime")) |ms| @intFromFloat(ms) else now_ms,
                        .lat = flat,
                        .lon = flon,
                        .state = jStr(attrs, "attr_POOState") orelse "",
                        .county = jStr(attrs, "attr_POOCounty") orelse "",
                        .city = jStr(attrs, "attr_POOCity") orelse "",
                        .ftype = if (std.mem.eql(u8, type_cat, "WF")) "Wildfire" else if (std.mem.eql(u8, type_cat, "RX")) "Prescribed Fire" else "Unknown",
                    });
                }
                std.mem.sort(Fire, fires.items, {}, struct {
                    fn less(_: void, a: Fire, b: Fire) bool {
                        return a.distance < b.distance;
                    }
                }.less);

                var wf_count: usize = 0;
                var rx_count: usize = 0;
                for (fires.items) |f| {
                    if (std.mem.eql(u8, f.ftype, "Wildfire")) wf_count += 1;
                    if (std.mem.eql(u8, f.ftype, "Prescribed Fire")) rx_count += 1;
                }
                try w.print("🔥 **Found {d} active fire{s}**\n", .{ fires.items.len, if (fires.items.len > 1) "s" else "" });
                if (wf_count > 0) try w.print("   - {d} wildfire{s}\n", .{ wf_count, if (wf_count > 1) "s" else "" });
                if (rx_count > 0) try w.print("   - {d} prescribed burn{s}\n", .{ rx_count, if (rx_count > 1) "s" else "" });
                try w.writeByte('\n');

                const max_show: usize = 5;
                const show = fires.items[0..@min(fires.items.len, max_show)];
                var date_buf: [16]u8 = undefined;
                for (show) |f| {
                    const emoji = if (std.mem.eql(u8, f.ftype, "Wildfire")) "🔥" else if (std.mem.eql(u8, f.ftype, "Prescribed Fire")) "🟦" else "⚪";
                    try w.print("## {s}\n\n", .{f.name});
                    try w.print("**Type:** {s} {s}\n", .{ emoji, f.ftype });
                    try w.print("**Distance:** {d:.1} km ({d:.1} mi)\n", .{ f.distance, f.distance * 0.621371 });
                    if (f.state.len > 0) {
                        try w.print("**Location:** {s}", .{f.state});
                        if (f.county.len > 0) try w.print(", {s} County", .{f.county});
                        if (f.city.len > 0) try w.print(" near {s}", .{f.city});
                        try w.writeByte('\n');
                    }
                    if (f.lat != null and f.lon != null) {
                        try w.print("**Coordinates:** {d:.4}, {d:.4}\n", .{ f.lat.?, f.lon.? });
                    }
                    try w.writeAll("\n### Status\n");
                    try w.print("**Size:** {d:.0} acres ({d:.0} hectares)\n", .{ f.acres, f.acres * 0.404686 });
                    const bars: usize = @intFromFloat(@round(f.containment / 10));
                    try w.print("**Containment:** {d:.0}% ", .{f.containment});
                    for (0..@min(bars, 10)) |_| try w.writeAll("█");
                    for (0..(10 - @min(bars, 10))) |_| try w.writeAll("░");
                    try w.writeByte('\n');
                    try w.print("**Discovery Date:** {s}\n", .{dateFromUnix(&date_buf, @divFloor(f.discovery_ms, 1000))});
                    const days_active = @divFloor(now_ms - f.discovery_ms, 86400000);
                    try w.print("**Days Active:** {d}\n", .{days_active});
                    try w.writeAll("\n---\n\n");
                }
                if (fires.items.len > max_show) {
                    try w.print("\n*Note: {d} additional fires found within radius (showing nearest {d} only)*\n", .{ fires.items.len - max_show, max_show });
                }

                // Safety assessment from nearest actual wildfire.
                for (fires.items) |f| {
                    if (!std.mem.eql(u8, f.ftype, "Wildfire")) continue;
                    try w.writeAll("\n## Safety Assessment\n\n");
                    if (f.distance < 5) {
                        try w.writeAll("⚠️ **EXTREME DANGER** - Wildfire within 5 km\n");
                        try w.writeAll("- Evacuate immediately if advised by authorities\n- Monitor local emergency alerts\n- Have evacuation plan ready\n");
                    } else if (f.distance < 25) {
                        try w.writeAll("🟠 **HIGH ALERT** - Wildfire within 25 km\n");
                        try w.writeAll("- Monitor fire conditions closely\n- Prepare for possible evacuation\n- Watch for smoke and changing conditions\n");
                    } else if (f.distance < 50) {
                        try w.writeAll("🟡 **CAUTION** - Wildfire within 50 km\n");
                        try w.writeAll("- Be aware of smoke and air quality impacts\n- Monitor local news and fire updates\n");
                    } else {
                        try w.print("ℹ️ **AWARENESS** - Wildfire detected within {d:.0} km\n", .{radius});
                        try w.writeAll("- Stay informed about fire progression\n- Air quality may be affected by smoke\n");
                    }
                    try w.writeByte('\n');
                    break;
                }
            }
        },
    }
    try writeWildfireFooter(w);
    return .{ .text = try alloc.dupe(u8, out.written()) };
}

fn writeWildfireFooter(w: *std.Io.Writer) !void {
    try w.writeAll("\n---\n*Data source: NIFC (National Interagency Fire Center) WFIGS*\n");
    try w.writeAll("*Wildfire data is updated throughout the day. Always consult official sources for evacuation orders and emergency information.*\n");
    try w.writeAll("*For active incidents and evacuation orders, visit: https://inciweb.nwcg.gov/*\n");
}

// ---------------------------------------------------------------------------
// Tests — mock fetch seam + canned API responses
// ---------------------------------------------------------------------------

const TestFixture = struct {
    url_part: []const u8,
    status: u16,
    body: []const u8,
};

var test_fixtures: []const TestFixture = &.{};

fn mockFetch(alloc: std.mem.Allocator, io: std.Io, url: []const u8) anyerror!HttpResp {
    _ = io;
    // Longest url_part wins so "/stations" beats the "api.weather.gov/points/" prefix.
    var best: ?TestFixture = null;
    for (test_fixtures) |f| {
        if (std.mem.indexOf(u8, url, f.url_part) != null) {
            if (best == null or f.url_part.len > best.?.url_part.len) best = f;
        }
    }
    const f = best orelse return error.NoFixture;
    if (f.status == 0) return error.ConnectionRefused;
    return .{ .status = f.status, .body = try alloc.dupe(u8, f.body) };
}

fn testIo() std.Io {
    const t = std.Io.Threaded.global_single_threaded;
    return t.io();
}

fn parseArgs(alloc: std.mem.Allocator, s: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, alloc, s, .{});
}

// --- URL construction ---

test "geocodeUrl encodes query and appends params" {
    var buf: [1024]u8 = undefined;
    const url = try geocodeUrl(&buf, "New York, NY", 5);
    try std.testing.expectEqualStrings(
        "https://geocoding-api.open-meteo.com/v1/search?name=New%20York%2C%20NY&count=5&language=en&format=json",
        url,
    );
}

test "omForecastUrl daily and hourly variants" {
    var buf: [4096]u8 = undefined;
    const daily = try omForecastUrl(&buf, 48.8566, 2.3522, 7, false);
    try std.testing.expect(std.mem.indexOf(u8, daily, "https://api.open-meteo.com/v1/forecast?latitude=48.8566&longitude=2.3522&forecast_days=7") == 0);
    try std.testing.expect(std.mem.indexOf(u8, daily, "temperature_unit=fahrenheit") != null);
    try std.testing.expect(std.mem.indexOf(u8, daily, "&daily=weather_code,temperature_2m_max") != null);
    try std.testing.expect(std.mem.indexOf(u8, daily, "&hourly=") == null);

    const hourly = try omForecastUrl(&buf, 48.8566, 2.3522, 3, true);
    try std.testing.expect(std.mem.indexOf(u8, hourly, "forecast_days=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, hourly, "&hourly=temperature_2m,relative_humidity_2m") != null);
}

test "omArchiveUrl hourly and daily variants" {
    var buf: [4096]u8 = undefined;
    const hourly = try omArchiveUrl(&buf, 51.5074, -0.1278, "2020-01-01", "2020-01-07", true);
    try std.testing.expect(std.mem.indexOf(u8, hourly, "https://archive-api.open-meteo.com/v1/archive?latitude=51.5074&longitude=-0.1278&start_date=2020-01-01&end_date=2020-01-07") == 0);
    try std.testing.expect(std.mem.indexOf(u8, hourly, "&hourly=temperature_2m") != null);

    const daily = try omArchiveUrl(&buf, 51.5074, -0.1278, "2019-01-01", "2019-12-31", false);
    try std.testing.expect(std.mem.indexOf(u8, daily, "&daily=temperature_2m_max") != null);
    try std.testing.expect(std.mem.indexOf(u8, daily, "&hourly=") == null);
}

test "omAirQualityUrl current-only and forecast variants" {
    var buf: [4096]u8 = undefined;
    const current = try omAirQualityUrl(&buf, 40.7128, -74.006, null);
    try std.testing.expect(std.mem.indexOf(u8, current, "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=40.7128&longitude=-74.0060") == 0);
    try std.testing.expect(std.mem.indexOf(u8, current, "&current=pm10,pm2_5") != null);
    try std.testing.expect(std.mem.indexOf(u8, current, "&hourly=") == null);

    const fc = try omAirQualityUrl(&buf, 40.7128, -74.006, 5);
    try std.testing.expect(std.mem.indexOf(u8, fc, "&forecast_days=5&hourly=pm10") != null);
}

test "omMarineUrl with forecast includes daily aggregates" {
    var buf: [4096]u8 = undefined;
    const url = try omMarineUrl(&buf, 25.0, -80.0, 5);
    try std.testing.expect(std.mem.indexOf(u8, url, "https://marine-api.open-meteo.com/v1/marine?latitude=25.0000&longitude=-80.0000") == 0);
    try std.testing.expect(std.mem.indexOf(u8, url, "&current=wave_height") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "&daily=wave_height_max") != null);
}

test "noaa URL builders" {
    var buf: [1024]u8 = undefined;
    const points = try noaaPointsUrl(&buf, 39.8283, -98.5795);
    try std.testing.expectEqualStrings("https://api.weather.gov/points/39.8283,-98.5795", points);

    const active = try noaaAlertsUrl(&buf, 40.0, -100.0, true);
    try std.testing.expectEqualStrings("https://api.weather.gov/alerts/active?point=40.0000,-100.0000", active);

    const all = try noaaAlertsUrl(&buf, 40.0, -100.0, false);
    try std.testing.expectEqualStrings("https://api.weather.gov/alerts?point=40.0000,-100.0000", all);
}

test "nwpsGaugesUrl and nifcQueryUrl bbox encoding" {
    var buf: [2048]u8 = undefined;
    const gauges = try nwpsGaugesUrl(&buf, -98.2, 29.5, -97.2, 30.5);
    try std.testing.expect(std.mem.indexOf(u8, gauges, "https://api.water.noaa.gov/nwps/v1/gauges?west=-98.2000&south=29.5000&east=-97.2000&north=30.5000") == 0);

    const nifc = try nifcQueryUrl(&buf, -119.0, 33.5, -117.5, 34.6);
    try std.testing.expect(std.mem.indexOf(u8, nifc, "WFIGS_Interagency_Perimeters_Current/FeatureServer/0/query?") != null);
    try std.testing.expect(std.mem.indexOf(u8, nifc, "geometry=-119.0000,33.5000,-117.5000,34.6000") != null);
    try std.testing.expect(std.mem.indexOf(u8, nifc, "where=1%3D1") != null);
}

test "rainviewerTileUrl computes web-mercator tile for coordinate" {
    var buf: [512]u8 = undefined;
    // Equator / prime meridian at zoom 6 is exactly the center tile (32, 32).
    const url = try rainviewerTileUrl(&buf, "/v2/radar/1700000000", 0, 0, 6);
    try std.testing.expectEqualStrings("https://tilecache.rainviewer.com/v2/radar/1700000000/512/6/32/32/4/1_1.png", url);
}

// --- pure domain helpers ---

test "isInUS bounding boxes" {
    try std.testing.expect(isInUS(39.8, -98.6)); // Kansas
    try std.testing.expect(isInUS(64.2, -149.9)); // Alaska
    try std.testing.expect(isInUS(21.3, -157.8)); // Hawaii
    try std.testing.expect(isInUS(18.2, -66.4)); // Puerto Rico
    try std.testing.expect(!isInUS(48.85, 2.35)); // Paris
    try std.testing.expect(!isInUS(51.5, -0.12)); // London
}

test "shouldUseUSAQI regions" {
    try std.testing.expect(shouldUseUSAQI(40.7, -74.0)); // NYC
    try std.testing.expect(shouldUseUSAQI(13.5, 144.7)); // Guam
    try std.testing.expect(!shouldUseUSAQI(48.85, 2.35)); // Paris
    try std.testing.expect(!shouldUseUSAQI(-33.9, 151.2)); // Sydney
}

test "haversineKm known distances" {
    try std.testing.expectApproxEqAbs(@as(f64, 0), haversineKm(48.85, 2.35, 48.85, 2.35), 0.001);
    // Paris -> London is roughly 343 km.
    const d = haversineKm(48.8566, 2.3522, 51.5074, -0.1278);
    try std.testing.expect(d > 335 and d < 350);
}

test "weatherDescription WMO codes" {
    try std.testing.expectEqualStrings("Clear sky", weatherDescription(0));
    try std.testing.expectEqualStrings("Heavy rain", weatherDescription(65));
    try std.testing.expectEqualStrings("Thunderstorm with heavy hail", weatherDescription(99));
    try std.testing.expectEqualStrings("Unknown", weatherDescription(1234));
}

test "cardinalDirection" {
    try std.testing.expectEqualStrings("N", cardinalDirection(0));
    try std.testing.expectEqualStrings("E", cardinalDirection(90));
    try std.testing.expectEqualStrings("SW", cardinalDirection(225));
    try std.testing.expectEqualStrings("N", cardinalDirection(350));
    try std.testing.expectEqualStrings("N", cardinalDirection(-10));
}

test "AQI/UV/wave categories" {
    try std.testing.expectEqualStrings("Good", usAqiCategory(50).level);
    try std.testing.expectEqualStrings("Moderate", usAqiCategory(51).level);
    try std.testing.expectEqualStrings("Unhealthy for Sensitive Groups", usAqiCategory(150).level);
    try std.testing.expectEqualStrings("Hazardous", usAqiCategory(500).level);

    try std.testing.expectEqualStrings("Good", euAqiCategory(20).level);
    try std.testing.expectEqualStrings("Extremely Poor", euAqiCategory(150).level);

    try std.testing.expectEqualStrings("Low", uvIndexCategory(2.9).level);
    try std.testing.expectEqualStrings("Moderate", uvIndexCategory(3).level);
    try std.testing.expectEqualStrings("Extreme", uvIndexCategory(11).level);

    try std.testing.expectEqualStrings("Calm (glassy)", waveHeightCategory(0.05).description);
    try std.testing.expectEqualStrings("Smooth", waveHeightCategory(1.0).description);
    try std.testing.expectEqualStrings("Very High", waveHeightCategory(20).description);
}

test "escapeMarkdown neutralizes markup" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const out = try escapeMarkdown(alloc, "a*b_[c](d) <e>\nf#");
    defer alloc.free(out);
    try std.testing.expectEqualStrings("a\\*b\\_\\[c\\]\\(d\\) &lt;e&gt; f\\#", out);
}

test "parseYmd valid and invalid" {
    const ok = parseYmd("2024-02-29").?;
    try std.testing.expectEqual(@as(i32, 2024), ok.y);
    try std.testing.expectEqual(@as(u8, 2), ok.m);
    try std.testing.expectEqual(@as(u8, 29), ok.d);
    try std.testing.expect(parseYmd("2023-02-29") == null); // not a leap year
    try std.testing.expect(parseYmd("garbage") == null);
    try std.testing.expect(parseYmd("2024-13-01") == null);
    try std.testing.expect(parseYmd("2024-02-29T10:00:00Z") != null);
}

test "rfc3339 appends time to bare dates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const s = try rfc3339(alloc, "2024-01-15");
    defer alloc.free(s);
    try std.testing.expectEqualStrings("2024-01-15T00:00:00Z", s);
    const full = try rfc3339(alloc, "2024-01-15T08:30:00Z");
    defer alloc.free(full);
    try std.testing.expectEqualStrings("2024-01-15T08:30:00Z", full);
}

test "lightningStats computes counts and rates" {
    const strikes = [_]LightningStrike{
        .{ .timestamp_ms = 1000, .latitude = 0, .longitude = 0, .amplitude = 30, .distance = 10 },
        .{ .timestamp_ms = 2000, .latitude = 0, .longitude = 0, .amplitude = 5, .distance = 20 },
        .{ .timestamp_ms = 3000, .latitude = 0, .longitude = 0, .amplitude = -25, .distance = 30 },
    };
    const stats = lightningStats(&strikes, 100, 60);
    try std.testing.expectEqual(@as(usize, 3), stats.total);
    try std.testing.expectEqual(@as(usize, 2), stats.cloud_to_ground);
    try std.testing.expectEqual(@as(usize, 1), stats.intra_cloud);
    try std.testing.expectApproxEqAbs(@as(f64, 20), stats.average_distance, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 10), stats.nearest_distance, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), stats.strikes_per_minute, 0.0001);

    const empty = lightningStats(&.{}, 100, 60);
    try std.testing.expectEqual(@as(usize, 0), empty.total);
}

test "assessLightningSafety distance levels" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const now: i64 = 60 * 60 * 1000;

    const far = [_]LightningStrike{.{ .timestamp_ms = now - 5 * 60 * 1000, .latitude = 0, .longitude = 0, .distance = 60 }};
    const s1 = try assessLightningSafety(alloc, &far, lightningStats(&far, 100, 60), now);
    try std.testing.expectEqual(SafetyLevel.safe, s1.level);
    try std.testing.expect(s1.active_thunderstorm); // recent strike

    const mid = [_]LightningStrike{.{ .timestamp_ms = now - 5 * 60 * 1000, .latitude = 0, .longitude = 0, .distance = 20 }};
    const s2 = try assessLightningSafety(alloc, &mid, lightningStats(&mid, 100, 60), now);
    try std.testing.expectEqual(SafetyLevel.elevated, s2.level);

    const close = [_]LightningStrike{.{ .timestamp_ms = now - 5 * 60 * 1000, .latitude = 0, .longitude = 0, .distance = 10 }};
    const s3 = try assessLightningSafety(alloc, &close, lightningStats(&close, 100, 60), now);
    try std.testing.expectEqual(SafetyLevel.high, s3.level);

    const very_close = [_]LightningStrike{.{ .timestamp_ms = now - 5 * 60 * 1000, .latitude = 0, .longitude = 0, .distance = 3 }};
    const s4 = try assessLightningSafety(alloc, &very_close, lightningStats(&very_close, 100, 60), now);
    try std.testing.expectEqual(SafetyLevel.extreme, s4.level);

    const none = try assessLightningSafety(alloc, &.{}, lightningStats(&.{}, 100, 60), now);
    try std.testing.expectEqual(SafetyLevel.safe, none.level);
    try std.testing.expect(!none.active_thunderstorm);
}

test "featureDescription maps GeoNames codes" {
    try std.testing.expectEqualStrings("National capital", featureDescription("PPLC").?);
    try std.testing.expectEqualStrings("Airport", featureDescription("AIRP").?);
    try std.testing.expect(featureDescription("ZZZ") == null);
}

// --- search_location ---

const GEOCODE_PARIS =
    \\{"results":[{"name":"Paris","latitude":48.8566,"longitude":2.3522,"country":"France","country_code":"fr","timezone":"Europe/Paris","elevation":35.0,"population":2138551,"feature_code":"PPLC","admin1":"Île-de-France"}]}
;

test "searchLocationImpl formats results" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "geocoding-api.open-meteo.com", .status = 200, .body = GEOCODE_PARIS }};
    var args = try parseArgs(alloc, "{\"query\":\"Paris\"}");
    defer args.deinit();

    const result = try searchLocationImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Paris") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "48.8566") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "2.3522") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "France") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "National capital") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Europe/Paris") != null);
    try std.testing.expect(std.mem.endsWith(u8, result.text, "Data: Open-Meteo.com (CC BY 4.0)"));
}

test "searchLocationImpl city not found is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "geocoding-api.open-meteo.com", .status = 200, .body = "{\"generationtime_ms\":0.5}" }};
    var args = try parseArgs(alloc, "{\"query\":\"Zzzzznotaplace\"}");
    defer args.deinit();

    const result = try searchLocationImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "No locations found matching") != null);
}

test "searchLocationImpl HTTP failure is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "geocoding-api.open-meteo.com", .status = 500, .body = "{\"error\":true,\"reason\":\"boom\"}" }};
    var args = try parseArgs(alloc, "{\"query\":\"Paris\"}");
    defer args.deinit();

    const result = try searchLocationImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "HTTP 500") != null);
}

test "searchLocationImpl malformed JSON is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "geocoding-api.open-meteo.com", .status = 200, .body = "not json{{{" }};
    var args = try parseArgs(alloc, "{\"query\":\"Paris\"}");
    defer args.deinit();

    const result = try searchLocationImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "malformed JSON") != null);
}

test "searchLocationImpl network failure is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "geocoding-api.open-meteo.com", .status = 0, .body = "" }};
    var args = try parseArgs(alloc, "{\"query\":\"Paris\"}");
    defer args.deinit();

    const result = try searchLocationImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "ConnectionRefused") != null);
}

test "searchLocationImpl requires query" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var args = try parseArgs(alloc, "{}");
    defer args.deinit();
    const result = try searchLocationImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "query") != null);
}

// --- get_forecast ---

const OM_FORECAST_DAILY =
    \\{"latitude":48.86,"longitude":2.35,"elevation":43.0,"timezone":"Europe/Paris",
    \\"daily":{"time":["2026-08-01","2026-08-02"],"weather_code":[1,61],
    \\"temperature_2m_max":[77.0,68.0],"temperature_2m_min":[59.0,55.4],
    \\"apparent_temperature_max":[80.0,66.0],"apparent_temperature_min":[57.0,53.0],
    \\"sunrise":["2026-08-01T06:20","2026-08-02T06:21"],"sunset":["2026-08-01T20:30","2026-08-02T20:29"],
    \\"daylight_duration":[51000,50800],"precipitation_probability_max":[10,80],
    \\"precipitation_sum":[0.0,0.35],"wind_speed_10m_max":[8.1,12.3],
    \\"wind_gusts_10m_max":[15.0,25.0],"wind_direction_10m_dominant":[220,180],"uv_index_max":[6.5,3.2]}}
;

test "forecastImpl Open-Meteo daily for international location" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "api.open-meteo.com/v1/forecast", .status = 200, .body = OM_FORECAST_DAILY }};
    var args = try parseArgs(alloc, "{\"latitude\":48.8566,\"longitude\":2.3522,\"days\":2}");
    defer args.deinit();

    const result = try forecastImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Weather Forecast (Daily)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "High 77") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Low 55") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Precipitation Chance:** 80%") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Slight rain") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Open-Meteo") != null);
    try std.testing.expect(std.mem.endsWith(u8, result.text, "Data: Open-Meteo.com (CC BY 4.0)"));
}

const NOAA_POINTS =
    \\{"properties":{"gridId":"TOP","gridX":32,"gridY":45,"timeZone":"America/Chicago"}}
;
const NOAA_FORECAST =
    \\{"properties":{"elevation":{"value":200},"updated":"2026-08-01T12:00:00Z",
    \\"periods":[
    \\{"name":"Today","startTime":"2026-08-01T13:00:00-05:00","temperature":90,"temperatureUnit":"F","temperatureTrend":"","probabilityOfPrecipitation":{"value":20},"relativeHumidity":{"value":45},"windSpeed":"10 mph","windDirection":"S","shortForecast":"Sunny","detailedForecast":"Sunny with a high near 90.","isDaytime":true},
    \\{"name":"Tonight","startTime":"2026-08-01T20:00:00-05:00","temperature":70,"temperatureUnit":"F","temperatureTrend":"falling","probabilityOfPrecipitation":{"value":null},"relativeHumidity":{"value":60},"windSpeed":"5 mph","windDirection":"SE","shortForecast":"Clear","detailedForecast":"Clear, with a low around 70.","isDaytime":false}]}}
;

test "forecastImpl NOAA for US location (auto source)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{
        .{ .url_part = "api.weather.gov/points/", .status = 200, .body = NOAA_POINTS },
        .{ .url_part = "api.weather.gov/gridpoints/TOP/32,45/forecast", .status = 200, .body = NOAA_FORECAST },
    };
    var args = try parseArgs(alloc, "{\"latitude\":39.8283,\"longitude\":-98.5795,\"days\":1}");
    defer args.deinit();

    const result = try forecastImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "## Today") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "90°F") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Precipitation Chance:** 20%") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Sunny with a high near 90.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "NOAA") != null);
    try std.testing.expect(std.mem.endsWith(u8, result.text, "Data: NOAA/NWS"));
}

test "forecastImpl source=openmeteo overrides US auto-detection" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "api.open-meteo.com/v1/forecast", .status = 200, .body = OM_FORECAST_DAILY }};
    var args = try parseArgs(alloc, "{\"latitude\":39.8283,\"longitude\":-98.5795,\"days\":2,\"source\":\"openmeteo\"}");
    defer args.deinit();

    const result = try forecastImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Open-Meteo") != null);
}

test "forecastImpl rejects out-of-range latitude" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var args = try parseArgs(alloc, "{\"latitude\":95,\"longitude\":2.35}");
    defer args.deinit();
    const result = try forecastImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "latitude") != null);
}

test "forecastImpl NOAA 404 surfaces coverage hint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "api.weather.gov/points/", .status = 404, .body = "{\"title\":\"Not Found\",\"detail\":\"no grid\"}" }};
    var args = try parseArgs(alloc, "{\"latitude\":39.8283,\"longitude\":-98.5795}");
    defer args.deinit();
    const result = try forecastImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "coverage area") != null);
}

// --- get_current_conditions ---

const NOAA_STATIONS =
    \\{"features":[{"properties":{"stationIdentifier":"KTEST","timeZone":"America/Chicago"}}]}
;
const NOAA_LATEST_OBS =
    \\{"properties":{"station":"https://api.weather.gov/stations/KTEST","timestamp":"2026-08-01T12:00:00Z","textDescription":"Clear",
    \\"temperature":{"value":30,"unitCode":"wmoUnit:degC"},
    \\"dewpoint":{"value":15,"unitCode":"wmoUnit:degC"},
    \\"relativeHumidity":{"value":40,"unitCode":"wmoUnit:percent"},
    \\"windSpeed":{"value":18,"unitCode":"wmoUnit:km_h-1"},
    \\"windDirection":{"value":180,"unitCode":"wmoUnit:degree_(angle)"},
    \\"windGust":{"value":30,"unitCode":"wmoUnit:km_h-1"},
    \\"barometricPressure":{"value":101325,"unitCode":"wmoUnit:Pa"},
    \\"visibility":{"value":16093,"unitCode":"wmoUnit:m"},
    \\"heatIndex":{"value":null,"unitCode":"wmoUnit:degC"},
    \\"windChill":{"value":null,"unitCode":"wmoUnit:degC"},
    \\"precipitationLastHour":{"value":null,"unitCode":"wmoUnit:mm"},
    \\"precipitationLast3Hours":{"value":null,"unitCode":"wmoUnit:mm"},
    \\"precipitationLast6Hours":{"value":null,"unitCode":"wmoUnit:mm"},
    \\"cloudLayers":[{"amount":"FEW","base":{"value":1000,"unitCode":"wmoUnit:m"}}]}}
;

test "currentConditionsImpl parses observation with unit conversion" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{
        .{ .url_part = "api.weather.gov/points/", .status = 200, .body = NOAA_POINTS },
        .{ .url_part = "points/39.8283,-98.5795/stations", .status = 200, .body = NOAA_STATIONS },
        .{ .url_part = "observations/latest", .status = 200, .body = NOAA_LATEST_OBS },
    };
    var args = try parseArgs(alloc, "{\"latitude\":39.8283,\"longitude\":-98.5795}");
    defer args.deinit();

    const result = try currentConditionsImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Current Weather Conditions") != null);
    // 30 °C -> 86 °F
    try std.testing.expect(std.mem.indexOf(u8, result.text, "86°F") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Humidity:** 40%") != null);
    // 18 km/h -> ~11 mph
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Wind:** 11 mph") != null);
    // gust 30 km/h -> ~19 mph, > 1.2x sustained
    try std.testing.expect(std.mem.indexOf(u8, result.text, "gusting to 19 mph") != null);
    try std.testing.expect(std.mem.endsWith(u8, result.text, "Data: NOAA/NWS"));
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Clear") != null);
}

test "currentConditionsImpl no stations is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{
        .{ .url_part = "/stations", .status = 200, .body = "{\"features\":[]}" },
    };
    var args = try parseArgs(alloc, "{\"latitude\":39.8283,\"longitude\":-98.5795}");
    defer args.deinit();
    const result = try currentConditionsImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "No weather stations") != null);
}

// --- get_alerts ---

const NOAA_ALERTS =
    \\{"updated":"2026-08-01T12:00:00Z","features":[
    \\{"properties":{"event":"Flood Watch","severity":"Moderate","urgency":"Future","certainty":"Possible","headline":"Flood watch headline","areaDesc":"Test County","effective":"2026-08-02T00:00:00Z","expires":"2026-08-03T00:00:00Z","onset":null,"ends":null,"description":"Flooding possible.","instruction":null,"response":"Monitor","senderName":"NWS Test"}},
    \\{"properties":{"event":"Severe Thunderstorm Warning","severity":"Severe","urgency":"Immediate","certainty":"Observed","headline":"Storm warning","areaDesc":"Test County","effective":"2026-08-01T10:00:00Z","expires":"2026-08-01T18:00:00Z","onset":"2026-08-01T10:00:00Z","ends":"2026-08-01T18:00:00Z","description":"A severe storm.","instruction":"Stay indoors.","response":"Shelter","senderName":"NWS Test"}}]}
;

test "alertsImpl sorts by severity and formats details" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "api.weather.gov/alerts", .status = 200, .body = NOAA_ALERTS }};
    var args = try parseArgs(alloc, "{\"latitude\":39.8283,\"longitude\":-98.5795}");
    defer args.deinit();

    const result = try alertsImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "2 active alerts found") != null);
    // Severe must sort before Moderate even though the fixture lists it second.
    const severe_idx = std.mem.indexOf(u8, result.text, "Severe Thunderstorm Warning").?;
    const flood_idx = std.mem.indexOf(u8, result.text, "Flood Watch").?;
    try std.testing.expect(severe_idx < flood_idx);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Stay indoors.") != null);
    try std.testing.expect(std.mem.endsWith(u8, result.text, "Data: NOAA/NWS"));
}

test "alertsImpl empty list is a clear message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "api.weather.gov/alerts", .status = 200, .body = "{\"features\":[]}" }};
    var args = try parseArgs(alloc, "{\"latitude\":39.8283,\"longitude\":-98.5795}");
    defer args.deinit();
    const result = try alertsImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "No active weather alerts") != null);
}

// --- get_historical_weather ---

const OM_ARCHIVE_HOURLY =
    \\{"latitude":48.86,"longitude":2.35,"elevation":43.0,"timezone":"Europe/Paris",
    \\"hourly":{"time":["2020-01-01T00:00","2020-01-01T01:00"],"temperature_2m":[41.0,40.0],
    \\"apparent_temperature":[38.0,37.0],"weather_code":[3,3],"precipitation":[0.0,0.02],
    \\"snowfall":[0,0],"wind_speed_10m":[10.0,11.0],"wind_direction_10m":[200,210],
    \\"relative_humidity_2m":[80,81],"pressure_msl":[1015.0,1016.0],"cloud_cover":[90,95]}}
;

test "historicalImpl archival path formats hourly observations" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "archive-api.open-meteo.com", .status = 200, .body = OM_ARCHIVE_HOURLY }};
    var args = try parseArgs(alloc, "{\"latitude\":48.8566,\"longitude\":2.3522,\"start_date\":\"2020-01-01\",\"end_date\":\"2020-01-02\",\"limit\":5}");
    defer args.deinit();
    // now far in the future so the archival path is chosen.
    const now: i64 = 1800000000;

    const result = try historicalImpl(alloc, testIo(), args.value, now, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Historical Weather Observations (Hourly)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "41°F") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Overcast") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Humidity:** 80%") != null);
}

test "historicalImpl rejects future dates" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var args = try parseArgs(alloc, "{\"latitude\":48.8566,\"longitude\":2.3522,\"start_date\":\"2999-01-01\",\"end_date\":\"2999-01-02\"}");
    defer args.deinit();
    const now: i64 = 1800000000;
    const result = try historicalImpl(alloc, testIo(), args.value, now, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "future") != null);
}

test "historicalImpl rejects inverted range" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var args = try parseArgs(alloc, "{\"latitude\":48.8566,\"longitude\":2.3522,\"start_date\":\"2020-01-10\",\"end_date\":\"2020-01-01\"}");
    defer args.deinit();
    const now: i64 = 1800000000;
    const result = try historicalImpl(alloc, testIo(), args.value, now, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "start_date") != null);
}

// --- check_service_status ---

test "statusImpl reports both services operational" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{
        .{ .url_part = "api.weather.gov/points/39.8283", .status = 200, .body = NOAA_POINTS },
        .{ .url_part = "archive-api.open-meteo.com", .status = 200, .body = OM_ARCHIVE_HOURLY },
    };
    var args = try parseArgs(alloc, "{}");
    defer args.deinit();
    const result = try statusImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Weather API Service Status") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "All Services Operational") != null);
}

test "statusImpl reports partial availability when NOAA is down" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{
        .{ .url_part = "api.weather.gov/points/39.8283", .status = 503, .body = "" },
        .{ .url_part = "archive-api.open-meteo.com", .status = 200, .body = OM_ARCHIVE_HOURLY },
    };
    var args = try parseArgs(alloc, "{}");
    defer args.deinit();
    const result = try statusImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Partial Service Availability") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Issues Detected") != null);
}

// --- get_air_quality ---

const OM_AIR_QUALITY =
    \\{"latitude":40.71,"longitude":-74.0,"elevation":10.0,"timezone":"America/New_York",
    \\"current_units":{"pm2_5":"μg/m³","pm10":"μg/m³","ozone":"μg/m³"},
    \\"current":{"time":"2026-08-01T12:00","pm2_5":12.5,"pm10":20.1,"ozone":60.0,
    \\"nitrogen_dioxide":15.0,"sulphur_dioxide":2.0,"carbon_monoxide":300.0,
    \\"uv_index":5.5,"uv_index_clear_sky":6.0,"us_aqi":55,"european_aqi":30}}
;

test "airQualityImpl shows US AQI for US location" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "air-quality-api.open-meteo.com", .status = 200, .body = OM_AIR_QUALITY }};
    var args = try parseArgs(alloc, "{\"latitude\":40.7128,\"longitude\":-74.006}");
    defer args.deinit();

    const result = try airQualityImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "US Air Quality Index: 55") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Moderate") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "UV Index: 5.5") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "PM2.5") != null);
    // secondary scale reference
    try std.testing.expect(std.mem.indexOf(u8, result.text, "European AQI: 30") != null);
}

test "airQualityImpl shows European AQI for non-US location" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "air-quality-api.open-meteo.com", .status = 200, .body = OM_AIR_QUALITY }};
    var args = try parseArgs(alloc, "{\"latitude\":48.8566,\"longitude\":2.3522}");
    defer args.deinit();
    const result = try airQualityImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "European Air Quality Index: 30") != null);
}

// --- get_marine_conditions ---

const OM_MARINE =
    \\{"latitude":25.0,"longitude":-80.0,"timezone":"America/New_York",
    \\"current":{"time":"2026-08-01T12:00","wave_height":1.5,"wave_direction":90.0,"wave_period":7.0,
    \\"wind_wave_height":1.0,"wind_wave_direction":100.0,"wind_wave_period":5.0,"wind_wave_peak_period":6.0,
    \\"swell_wave_height":0.8,"swell_wave_direction":80.0,"swell_wave_period":9.0,"swell_wave_peak_period":10.0,
    \\"ocean_current_velocity":0.5,"ocean_current_direction":45.0}}
;

test "marineImpl formats waves, swell, currents and safety" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "marine-api.open-meteo.com", .status = 200, .body = OM_MARINE }};
    var args = try parseArgs(alloc, "{\"latitude\":25.0,\"longitude\":-80.0}");
    defer args.deinit();

    const result = try marineImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Marine Conditions Report") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "1.5m (4.9ft)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Slight") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Swell") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Ocean Currents") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "NOT suitable for coastal navigation") != null);
}

// --- get_weather_imagery ---

const RAINVIEWER_MAPS =
    \\{"version":"2.0","generated":1700000000,"host":"https://tilecache.rainviewer.com",
    \\"radar":{"past":[{"time":1699999000,"path":"/v2/radar/1699999000"},{"time":1700000000,"path":"/v2/radar/1700000000"}],
    \\"nowcast":[{"time":1700000600,"path":"/v2/radar/1700000600"}]}}
;

test "imageryImpl radar returns latest frame tile URL" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "api.rainviewer.com", .status = 200, .body = RAINVIEWER_MAPS }};
    var args = try parseArgs(alloc, "{\"latitude\":48.8566,\"longitude\":2.3522,\"type\":\"radar\"}");
    defer args.deinit();

    const result = try imageryImpl(alloc, testIo(), args.value, 1700001000, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Weather Imagery") != null);
    // latest past frame at zoom 6 for Paris
    try std.testing.expect(std.mem.indexOf(u8, result.text, "https://tilecache.rainviewer.com/v2/radar/1700000000/512/6/") != null);
}

test "imageryImpl animated lists multiple frames" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "api.rainviewer.com", .status = 200, .body = RAINVIEWER_MAPS }};
    var args = try parseArgs(alloc, "{\"latitude\":48.8566,\"longitude\":2.3522,\"type\":\"precipitation\",\"animated\":true}");
    defer args.deinit();
    const result = try imageryImpl(alloc, testIo(), args.value, 1700001000, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Animation Frames (2 frames)") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "/v2/radar/1699999000/") != null);
}

test "imageryImpl satellite is a clear error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var args = try parseArgs(alloc, "{\"latitude\":48.8566,\"longitude\":2.3522,\"type\":\"satellite\"}");
    defer args.deinit();
    const result = try imageryImpl(alloc, testIo(), args.value, 1700001000, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Satellite imagery is not yet implemented") != null);
}

test "imageryImpl rejects unknown type" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var args = try parseArgs(alloc, "{\"latitude\":48.8566,\"longitude\":2.3522,\"type\":\"xray\"}");
    defer args.deinit();
    const result = try imageryImpl(alloc, testIo(), args.value, 1700001000, mockFetch);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Invalid imagery type") != null);
}

// --- get_lightning_activity ---

test "lightningImpl reports MQTT transport unsupported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var args = try parseArgs(alloc, "{\"latitude\":48.8566,\"longitude\":2.3522}");
    defer args.deinit();
    const result = try lightningImpl(alloc, testIo(), args.value);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "MQTT") != null);
}

test "lightningImpl validates radius bounds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var args = try parseArgs(alloc, "{\"latitude\":48.8566,\"longitude\":2.3522,\"radius\":999}");
    defer args.deinit();
    const result = try lightningImpl(alloc, testIo(), args.value);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "radius") != null);
}

// --- get_river_conditions ---

const NWPS_GAUGES =
    \\[{"lid":"TEST1","name":"Test River at Testville","latitude":30.0,"longitude":-97.7,"state":"TX","county":"Travis","usgsId":"08158000","inService":true,
    \\"status":{"observed":{"validTime":"2026-08-01T12:00:00Z","primary":5.25,"secondary":1.5,"floodCategory":"no flooding"},
    \\"forecast":{"validTime":"2026-08-02T00:00:00Z","primary":6.0,"secondary":2.0,"floodCategory":"action"}},
    \\"flood":{"categories":{"action":10.0,"minor":15.0,"moderate":20.0,"major":25.0},
    \\"crests":{"recent":[{"date":"2020-05-01","value":18.5,"flow":20000.0,"description":"May 2020 flood"}]}}},
    \\{"lid":"FAR01","name":"Far River","latitude":34.0,"longitude":-97.7,"state":"OK","county":"","usgsId":"","inService":true,
    \\"status":{"observed":{"validTime":"2026-08-01T12:00:00Z","primary":2.0,"secondary":0.5,"floodCategory":"no flooding"}},
    \\"flood":{"categories":{"action":5.0,"minor":8.0,"moderate":12.0,"major":15.0},"crests":{"recent":[]}}}]
;

test "riverImpl formats nearest gauges and filters by radius" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "api.water.noaa.gov", .status = 200, .body = NWPS_GAUGES }};
    var args = try parseArgs(alloc, "{\"latitude\":30.0,\"longitude\":-97.7,\"radius\":50}");
    defer args.deinit();

    const result = try riverImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "River Conditions Report") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Test River at Testville") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "River Stage:** 5.25 ft") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Minor Flood:** 15.0 ft") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Forecasted Stage:** 6.00 ft") != null);
    // The far gauge (444 km away) must be filtered out of a 50 km radius.
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Far River") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Found 1 river gauge") != null);
}

test "riverImpl no gauges nearby" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "api.water.noaa.gov", .status = 200, .body = "[]" }};
    var args = try parseArgs(alloc, "{\"latitude\":30.0,\"longitude\":-97.7}");
    defer args.deinit();
    const result = try riverImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "No river gauges found") != null);
}

// --- get_wildfire_info ---

const NIFC_FIRES =
    \\{"features":[{"attributes":{"poly_IncidentName":"Test Fire","poly_GISAcres":1500.5,"attr_PercentContained":40.0,
    \\"attr_FireDiscoveryDateTime":1754000000000,"attr_InitialLatitude":34.05,"attr_InitialLongitude":-118.2,
    \\"attr_POOState":"US-CA","attr_POOCounty":"Los Angeles","attr_POOCity":"Testville","attr_IncidentTypeCategory":"WF",
    \\"poly_FeatureStatus":"Active"},"geometry":{"rings":[[[-118.2,34.05]]]}}]}
;

const NIFC_FIRE_OUT_OF_RANGE =
    \\{"features":[{"attributes":{"poly_IncidentName":"Bad Fire","attr_PercentContained":-50.0,"attr_InitialLatitude":34.05,"attr_InitialLongitude":-118.2,"attr_IncidentTypeCategory":"WF"}}]}
;

test "wildfireImpl formats fires with containment and safety" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "arcgis.com", .status = 200, .body = NIFC_FIRES }};
    var args = try parseArgs(alloc, "{\"latitude\":34.05,\"longitude\":-118.25,\"radius\":100}");
    defer args.deinit();

    const result = try wildfireImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Wildfire Information Report") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Test Fire") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Found 1 active fire") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Containment:** 40%") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "1501 acres") != null);
}

test "wildfireImpl no fires nearby" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "arcgis.com", .status = 200, .body = "{\"features\":[]}" }};
    var args = try parseArgs(alloc, "{\"latitude\":34.05,\"longitude\":-118.25}");
    defer args.deinit();
    const result = try wildfireImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "No active wildfires found") != null);
}

test "wildfireImpl clamps untrusted containment percentages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    test_fixtures = &.{.{ .url_part = "arcgis.com", .status = 200, .body = NIFC_FIRE_OUT_OF_RANGE }};
    var args = try parseArgs(alloc, "{\"latitude\":34.05,\"longitude\":-118.25}");
    defer args.deinit();
    const result = try wildfireImpl(alloc, testIo(), args.value, mockFetch);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.text, "Containment:** 0%") != null);
}

test "withAttribution appends a single credit line" {
    const alloc = std.testing.allocator;
    const t = try withAttribution(alloc, "body\n", ATTR_OPEN_METEO);
    defer alloc.free(t);
    try std.testing.expectEqualStrings("body\n\nData: Open-Meteo.com (CC BY 4.0)", t);
}
