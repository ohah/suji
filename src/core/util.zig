/// Suji 공통 유틸리티

/// 슬라이스를 고정 크기 버퍼에 null-terminate 복사
/// C ABI 함수에 전달할 때 사용
pub fn nullTerminate(src: []const u8, dst: []u8) [:0]const u8 {
    const len = @min(src.len, dst.len - 1);
    @memcpy(dst[0..len], src[0..len]);
    dst[len] = 0;
    return dst[0..len :0];
}

/// 슬라이스를 고정 크기 버퍼에 복사 (null-terminate 없이)
pub fn copyToBuf(src: []const u8, dst: []u8) []const u8 {
    const len = @min(src.len, dst.len);
    @memcpy(dst[0..len], src[0..len]);
    return dst[0..len];
}

/// IPC 버퍼 크기 상수
pub const MAX_CHANNEL_NAME = 256;
pub const MAX_REQUEST = 8192;
pub const MAX_RESPONSE = 16384;
pub const MAX_ERROR_MSG = 512;
pub const MAX_NUM_BUF = 64;
