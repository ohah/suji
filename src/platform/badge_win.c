// Windows app badge count bridge.
//
// Windows has no numeric taskbar badge API. Electron-style badge count is
// approximated with a taskbar overlay icon via ITaskbarList3::SetOverlayIcon.

#if defined(_WIN32)

#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0601
#endif
#define CINTERFACE
#define COBJMACROS

#include <windows.h>
#include <objbase.h>
#include <shobjidl.h>
#include <stdint.h>
#include <stdio.h>

static HICON suji_create_badge_icon(uint32_t count) {
    const int size = 32;
    HDC screen = GetDC(NULL);
    if (!screen) return NULL;
    HDC dc = CreateCompatibleDC(screen);
    if (!dc) {
        ReleaseDC(NULL, screen);
        return NULL;
    }

    HBITMAP color = CreateCompatibleBitmap(screen, size, size);
    HBITMAP mask = CreateBitmap(size, size, 1, 1, NULL);
    if (!color || !mask) {
        if (color) DeleteObject(color);
        if (mask) DeleteObject(mask);
        DeleteDC(dc);
        ReleaseDC(NULL, screen);
        return NULL;
    }

    HGDIOBJ old_bitmap = SelectObject(dc, color);
    RECT rect = {0, 0, size, size};
    HBRUSH bg = CreateSolidBrush(RGB(214, 39, 40));
    FillRect(dc, &rect, bg);
    DeleteObject(bg);

    wchar_t text[16];
    if (count > 99) {
        lstrcpyW(text, L"99+");
    } else {
        swprintf(text, sizeof(text) / sizeof(text[0]), L"%u", count);
    }

    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, RGB(255, 255, 255));
    HFONT font = CreateFontW(
        -20,
        0,
        0,
        0,
        FW_BOLD,
        FALSE,
        FALSE,
        FALSE,
        DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS,
        DEFAULT_QUALITY,
        DEFAULT_PITCH | FF_SWISS,
        L"Segoe UI");
    HGDIOBJ old_font = NULL;
    if (font) old_font = SelectObject(dc, font);
    DrawTextW(dc, text, -1, &rect, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    if (old_font) SelectObject(dc, old_font);
    if (font) DeleteObject(font);
    SelectObject(dc, old_bitmap);

    ICONINFO ii;
    ZeroMemory(&ii, sizeof(ii));
    ii.fIcon = TRUE;
    ii.hbmMask = mask;
    ii.hbmColor = color;
    HICON icon = CreateIconIndirect(&ii);

    DeleteObject(color);
    DeleteObject(mask);
    DeleteDC(dc);
    ReleaseDC(NULL, screen);
    return icon;
}

int suji_windows_badge_set_count(void *hwnd_ptr, uint32_t count) {
    HWND hwnd = (HWND)hwnd_ptr;
    if (!hwnd) return 0;

    HRESULT init = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    int should_uninit = SUCCEEDED(init);
    if (FAILED(init) && init != RPC_E_CHANGED_MODE) return 0;

    ITaskbarList3 *taskbar = NULL;
    HRESULT hr = CoCreateInstance(
        &CLSID_TaskbarList,
        NULL,
        CLSCTX_INPROC_SERVER,
        &IID_ITaskbarList3,
        (void **)&taskbar);
    if (FAILED(hr) || !taskbar) {
        if (should_uninit) CoUninitialize();
        return 0;
    }

    hr = ITaskbarList3_HrInit(taskbar);
    if (FAILED(hr)) {
        ITaskbarList3_Release(taskbar);
        if (should_uninit) CoUninitialize();
        return 0;
    }

    HICON icon = NULL;
    wchar_t description[32] = L"";
    if (count > 0) {
        icon = suji_create_badge_icon(count);
        if (!icon) {
            ITaskbarList3_Release(taskbar);
            if (should_uninit) CoUninitialize();
            return 0;
        }
        swprintf(description, sizeof(description) / sizeof(description[0]), L"%u", count);
    }

    hr = ITaskbarList3_SetOverlayIcon(taskbar, hwnd, icon, description);
    if (icon) DestroyIcon(icon);
    ITaskbarList3_Release(taskbar);
    if (should_uninit) CoUninitialize();
    return SUCCEEDED(hr) ? 1 : 0;
}

#else

#include <stdint.h>

int suji_windows_badge_set_count(void *hwnd, uint32_t count) {
    (void)hwnd;
    (void)count;
    return 0;
}

#endif
