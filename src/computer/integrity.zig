//! Mandatory integrity levels, for UIPI.
//!
//! Windows silently drops SendInput aimed at a window whose process runs at
//! a higher integrity level (an elevated app, UAC prompts), and refuses
//! focus/move/close from lower levels. Rather than report success for input
//! that went nowhere (or landed somewhere else), every injecting or
//! window-changing path checks the target process first and refuses when
//! its level is higher than ours or cannot be read.

const std = @import("std");
const w = @import("win32.zig");

const TOKEN_QUERY: u32 = 0x0008;
const TokenIntegrityLevel: c_int = 25;

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) w.HANDLE;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "advapi32" fn OpenProcessToken(ProcessHandle: w.HANDLE, DesiredAccess: u32, TokenHandle: *?w.HANDLE) callconv(.winapi) w.BOOL;
extern "advapi32" fn GetTokenInformation(TokenHandle: w.HANDLE, TokenInformationClass: c_int, TokenInformation: ?*anyopaque, TokenInformationLength: u32, ReturnLength: *u32) callconv(.winapi) w.BOOL;
extern "advapi32" fn GetSidSubAuthorityCount(pSid: *anyopaque) callconv(.winapi) *u8;
extern "advapi32" fn GetSidSubAuthority(pSid: *anyopaque, nSubAuthority: u32) callconv(.winapi) *u32;

pub const untrusted: u32 = 0x0000;
pub const low: u32 = 0x1000;
pub const medium: u32 = 0x2000;
pub const high: u32 = 0x3000;
pub const system: u32 = 0x4000;

/// TOKEN_MANDATORY_LABEL { SID_AND_ATTRIBUTES { PSID Sid; DWORD Attributes } }
const TokenMandatoryLabel = extern struct { sid: ?*anyopaque, attributes: u32 };

fn levelOfToken(token: w.HANDLE) ?u32 {
    var buf: [128]u8 align(8) = undefined;
    var len: u32 = 0;
    if (!w.ok(GetTokenInformation(token, TokenIntegrityLevel, &buf, buf.len, &len))) return null;
    const label: *const TokenMandatoryLabel = @ptrCast(&buf);
    const sid = label.sid orelse return null;
    const count = GetSidSubAuthorityCount(sid).*;
    if (count == 0) return null;
    return GetSidSubAuthority(sid, count - 1).*;
}

fn levelOfProcess(h: w.HANDLE) ?u32 {
    var tok: ?w.HANDLE = null;
    if (!w.ok(OpenProcessToken(h, TOKEN_QUERY, &tok)) or tok == null) return null;
    defer _ = w.CloseHandle(tok.?);
    return levelOfToken(tok.?);
}

var own_cache: ?u32 = null;

pub fn ownLevel() ?u32 {
    if (own_cache == null) own_cache = levelOfProcess(GetCurrentProcess());
    return own_cache;
}

/// Level of `pid`, or null when its token can't be read (a process of
/// another user or at a higher level usually denies TOKEN_QUERY).
pub fn levelOfPid(pid: u32) ?u32 {
    if (pid == GetCurrentProcessId()) return ownLevel();
    const h = w.OpenProcess(w.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer _ = w.CloseHandle(h);
    return levelOfProcess(h);
}

/// Unknown levels are treated as higher: refusing is the safe answer.
pub fn mayDrive(ours: ?u32, theirs: ?u32) bool {
    const o = ours orelse return false;
    const th = theirs orelse return false;
    return th <= o;
}

pub const Error = error{TargetElevated};

pub fn checkPid(pid: u32) Error!void {
    if (pid == 0) return; // no window: nothing to drop input on
    if (!mayDrive(ownLevel(), levelOfPid(pid))) return error.TargetElevated;
}

pub fn checkHwnd(hwnd: ?w.HWND) Error!void {
    const h = hwnd orelse return;
    var pid: u32 = 0;
    _ = w.GetWindowThreadProcessId(h, &pid);
    return checkPid(pid);
}

const t = std.testing;

test "mayDrive: equal or lower allowed, higher or unknown refused" {
    try t.expect(mayDrive(medium, medium));
    try t.expect(mayDrive(medium, low));
    try t.expect(mayDrive(high, medium));
    try t.expect(!mayDrive(medium, high));
    try t.expect(!mayDrive(medium, system));
    try t.expect(!mayDrive(medium, null));
    try t.expect(!mayDrive(null, medium));
}

test "our own level is readable and drives our own process" {
    const lvl = ownLevel() orelse return error.NoLevel;
    try t.expect(lvl >= low and lvl <= system);
    try checkPid(GetCurrentProcessId());
}
