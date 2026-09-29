//! The parts of zmcp-computer that zmcp-desktop reuses (as the module
//! "computer_shared"): the Win32 declarations, the integrity-level check,
//! key names/combos with the chord blocklists and held-key tracking, the
//! SendInput builders, and the actuation guards (typing cap, coordinate
//! validation, KeyGuard).

pub const win32 = @import("win32.zig");
pub const integrity = @import("integrity.zig");
pub const keys = @import("keys.zig");
pub const input = @import("input.zig");
pub const guard = @import("guard.zig");

test {
    _ = guard;
}
