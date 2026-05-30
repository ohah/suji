//! Shared CoreFoundation helpers used by macOS native API modules.

pub extern "c" fn CFDataCreate(allocator: ?*anyopaque, bytes: [*]const u8, length: c_long) ?*anyopaque;
pub extern "c" fn CFDataGetBytePtr(data: ?*anyopaque) [*]const u8;
pub extern "c" fn CFDataGetLength(data: ?*anyopaque) c_long;
pub extern "c" fn CFRelease(cf: ?*anyopaque) void;
