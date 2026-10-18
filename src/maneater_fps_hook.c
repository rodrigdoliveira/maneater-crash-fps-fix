#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <wchar.h>
#include <intrin.h>
/* Installer-owned export storage. Only this non-executable section and the PE
 * export-directory/checksum fields are personalized, before loading the DLL.
 * The native implementation and its RVAs stay unchanged across Windows builds. */
__attribute__((section(".dxgifwd"), used))
const unsigned char maneater_dxgi_forwarding_space[65536] = {'M','E','C','F','F','W','D','1'};
#if defined(_MSC_VER)
#pragma intrinsic(_ReturnAddress)
#define CALLER_RETURN_ADDRESS() _ReturnAddress()
#else
#define CALLER_RETURN_ADDRESS() __builtin_extract_return_addr(__builtin_return_address(0))
#endif

/* The FPS component changes no executable bytes or CVar state from its worker.
 * The additional private navigation component uses an external transaction
 * to attach two exact-build native entry hooks; see nav_runtime.h.
 * It forwards one object's existing Set call, changing 60 to 120 only for the
 * verified engine SetMaxFPS callsite. Other requests retain their original ABI.
 * Strict metadata is the default. An explicit game-process environment flag
 * may waive only metadata equality; every fixed-RVA code/object guard remains.
 */
#define EXPECTED_TIMESTAMP 0x61ae6d91UL
#define EXPECTED_IMAGE_SIZE 0x1e1c8000UL
#define EXPECTED_ENTRYPOINT 0x1debe020UL
#define CVAR_OBJECT_POINTER_RVA 0x04adf540UL
#define CVAR_DATA_POINTER_RVA 0x04adf548UL
#define CVAR_VTABLE_RVA 0x0385b288UL
#define CVAR_SET_RVA 0x00f4aed0UL
#define ENGINE_SET_RVA 0x02942d10UL
#define ENGINE_SET_CALL_RVA 0x02942d7aUL
#define ENGINE_SET_RETURN_RVA 0x02942d80UL
#define CVAR_GETFLAGS_RVA 0x00f3f890UL
#define CVAR_GETDATA_RVA 0x00f3a320UL
#define CVAR_GETFLOAT_RVA 0x00f3f8f0UL
#define SHADOW_SLOT_COUNT 64U
#define SET_SLOT 16U
#define STACK_CAPACITY 12U

typedef void (__fastcall *ConsoleSetFn)(void *, const wchar_t *, uint32_t);

static HMODULE g_self;
static uintptr_t g_game_base;
static DWORD g_game_image_size;
static int g_experimental_build;
static void *g_target_object;
static ConsoleSetFn g_original_set;
/* One preceding entry is preserved verbatim, including the RTTI locator if one
 * is present. The verified float class uses 22 slots; preserving 64 readable
 * entries also keeps neighboring entries intact rather than truncating them.
 * This allocation and the DLL remain resident until process exit.
 */
static void **g_shadow_allocation;
static volatile LONG g_redirect_count;
static volatile LONG g_first_capture_state;
static void *g_first_stack[STACK_CAPACITY];
static USHORT g_first_stack_count;
static HANDLE g_log = INVALID_HANDLE_VALUE;

static const unsigned char k_engine_set_prefix[] = {
    0x48,0x89,0x5c,0x24,0x08,0x57,0x48,0x83,0xec,0x40,
    0x48,0x8b,0x3d,0x1f,0xc8,0x19,0x02,0x0f,0x29,0x74,
    0x24,0x30,0x48,0x8b,0xcf,0x0f,0x28,0xf1
};
static const unsigned char k_engine_set_call[] = {0xff,0x90,0x80,0x00,0x00,0x00};
static const unsigned char k_console_set_prefix[] = {
    0x48,0x89,0x6c,0x24,0x10,0x48,0x89,0x74,0x24,0x18,
    0x57,0x48,0x83,0xec,0x20,0x48,0x8b,0xea,0x41,0x8b,
    0xf0,0x41,0x8b,0xd0,0x48,0x8b,0xf9,0xe8,0x20,0xf7,0xfe,0xff
};
static const unsigned char k_getflags[] = {0x8b,0x41,0x18,0xc3,0xcc,0xcc,0xcc,0xcc,0xcc,0xcc};
static const unsigned char k_getdata[] = {0x48,0x8d,0x41,0x38,0xc3,0xcc,0xcc,0xcc,0xcc,0xcc};
static const unsigned char k_getfloat_prefix[] = {
    0x40,0x53,0x48,0x83,0xec,0x20,0x80,0x3d,0xfb,0x70,0xa2,0x03,
    0x00,0x48,0x8b,0xd9,0x74,0x1d
};
static const wchar_t k_expected_help[] = L"Caps FPS to the given value.  Set to <= 0 to be uncapped.";
static const wchar_t k_replacement[] = L"120";

static int allow_untested_build(void) {
    wchar_t value[3] = {0, 0, 0};
    DWORD length = GetEnvironmentVariableW(L"MANEATER_FIX_ALLOW_UNTESTED", value, 3);
    return length == 1 && value[0] == L'1' && value[1] == L'\0';
}

static int host_name_matches(const wchar_t *path, SIZE_T length) {
    static const wchar_t expected[] = L"maneater-win64-shipping.exe";
    SIZE_T start = 0, i;
    if (!path || length == 0) return 0;
    for (i = 0; i < length; ++i) if (path[i] == L'\\' || path[i] == L'/') start = i + 1;
    if (length - start != sizeof(expected) / sizeof(expected[0]) - 1U) return 0;
    for (i = 0; i < length - start; ++i) {
        wchar_t c = path[start + i];
        if (c >= L'A' && c <= L'Z') c += L'a' - L'A';
        if (c != expected[i]) return 0;
    }
    return 1;
}

static int rva_in_bounds(DWORD image_size, uintptr_t rva, SIZE_T size) {
    return size != 0 && rva < (uintptr_t)image_size &&
        size <= (SIZE_T)((uintptr_t)image_size - rva);
}

static int fixed_layout_fits(DWORD image_size) {
    return rva_in_bounds(image_size, CVAR_OBJECT_POINTER_RVA, sizeof(void *)) &&
        rva_in_bounds(image_size, CVAR_DATA_POINTER_RVA, sizeof(void *)) &&
        rva_in_bounds(image_size, CVAR_VTABLE_RVA - sizeof(void *),
                      (SHADOW_SLOT_COUNT + 1U) * sizeof(void *)) &&
        rva_in_bounds(image_size, ENGINE_SET_RVA, sizeof(k_engine_set_prefix)) &&
        rva_in_bounds(image_size, ENGINE_SET_CALL_RVA, sizeof(k_engine_set_call)) &&
        rva_in_bounds(image_size, ENGINE_SET_RETURN_RVA, 1) &&
        rva_in_bounds(image_size, CVAR_SET_RVA, sizeof(k_console_set_prefix)) &&
        rva_in_bounds(image_size, CVAR_GETFLAGS_RVA, sizeof(k_getflags)) &&
        rva_in_bounds(image_size, CVAR_GETDATA_RVA, sizeof(k_getdata)) &&
        rva_in_bounds(image_size, CVAR_GETFLOAT_RVA, sizeof(k_getfloat_prefix));
}

/* Pure metadata gate, also exercised without creating a game object. */
static int compatible_header(const IMAGE_NT_HEADERS64 *nt, SIZE_T header_end,
                             int allow_untested, int *experimental) {
    int exact;
    if (!nt || !experimental) return 0;
    *experimental = 0;
    if (nt->Signature != IMAGE_NT_SIGNATURE || nt->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64 ||
        nt->FileHeader.SizeOfOptionalHeader < sizeof(IMAGE_OPTIONAL_HEADER64) ||
        nt->FileHeader.NumberOfSections == 0 ||
        nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR64_MAGIC ||
        nt->OptionalHeader.SizeOfHeaders == 0 ||
        nt->OptionalHeader.SizeOfHeaders > nt->OptionalHeader.SizeOfImage ||
        header_end > nt->OptionalHeader.SizeOfHeaders ||
        (SIZE_T)(nt->FileHeader.SizeOfOptionalHeader - sizeof(IMAGE_OPTIONAL_HEADER64)) +
            (SIZE_T)nt->FileHeader.NumberOfSections * sizeof(IMAGE_SECTION_HEADER) >
            nt->OptionalHeader.SizeOfHeaders - header_end ||
        nt->OptionalHeader.AddressOfEntryPoint == 0 ||
        nt->OptionalHeader.AddressOfEntryPoint >= nt->OptionalHeader.SizeOfImage ||
        !fixed_layout_fits(nt->OptionalHeader.SizeOfImage)) return 0;
    exact = nt->FileHeader.TimeDateStamp == EXPECTED_TIMESTAMP &&
        nt->OptionalHeader.SizeOfImage == EXPECTED_IMAGE_SIZE &&
        nt->OptionalHeader.AddressOfEntryPoint == EXPECTED_ENTRYPOINT;
    if (!exact && !allow_untested) return 0;
    *experimental = !exact;
    return 1;
}

static int byte_signature_matches(const unsigned char *actual, const unsigned char *expected, SIZE_T size) {
    SIZE_T i;
    if (!actual || !expected || size == 0 || size > 64U) return 0;
    for (i = 0; i < size; ++i) if (actual[i] != expected[i]) return 0;
    return 1;
}

static int readable_range(const void *address, SIZE_T size) {
    uintptr_t at = (uintptr_t)address;
    uintptr_t end;
    if (at < 0x10000U || size == 0 || size > UINTPTR_MAX - at) return 0;
    end = at + size;
    while (at < end) {
        MEMORY_BASIC_INFORMATION info;
        uintptr_t region_end;
        DWORD protection;
        if (!VirtualQuery((const void *)at, &info, sizeof(info))) return 0;
        if (info.State != MEM_COMMIT || (info.Protect & (PAGE_GUARD | PAGE_NOACCESS))) return 0;
        protection = info.Protect & 0xffU;
        if (protection != PAGE_READONLY && protection != PAGE_READWRITE &&
            protection != PAGE_WRITECOPY && protection != PAGE_EXECUTE_READ &&
            protection != PAGE_EXECUTE_READWRITE && protection != PAGE_EXECUTE_WRITECOPY) return 0;
        region_end = (uintptr_t)info.BaseAddress + info.RegionSize;
        if (region_end <= at) return 0;
        at = region_end < end ? region_end : end;
    }
    return 1;
}

static int safe_read(const void *address, void *buffer, SIZE_T size) {
    SIZE_T copied = 0;
    if (!readable_range(address, size)) return 0;
    return ReadProcessMemory(GetCurrentProcess(), address, buffer, size, &copied) && copied == size;
}

/* Runtime snapshots of data owned by the current, guarded engine call.
 * VirtualQuery reports the whole following region, so even a tiny read can
 * scan a large resident allocation. ReadProcessMemory checks only the bounded
 * range we actually need and reports inaccessible/partial reads as failure.
 * Keep mapped-image and write-permission checks on their separate paths.
 * Nothing about a pointer's readability is cached across calls. */
static int read_call_snapshot(const void *address, void *buffer, SIZE_T size) {
    uintptr_t from = (uintptr_t)address, to = (uintptr_t)buffer;
    SIZE_T copied = 0;
    if (from < 0x10000U || to < 0x10000U || !size || size > 1024U * 1024U ||
        size > UINTPTR_MAX - from || size > UINTPTR_MAX - to) return 0;
    return ReadProcessMemory(GetCurrentProcess(), address, buffer, size, &copied) && copied == size;
}

/* Fixed offsets must belong to the main mapped image, not merely to readable
 * memory nearby. Heap CVar storage has its separate existing object guards.
 */
static int image_range(uintptr_t rva, SIZE_T size, int executable) {
    uintptr_t at, end;
    if (!g_game_base || !rva_in_bounds(g_game_image_size, rva, size) ||
        rva > UINTPTR_MAX - g_game_base) return 0;
    at = g_game_base + rva;
    if (size > UINTPTR_MAX - at) return 0;
    end = at + size;
    while (at < end) {
        MEMORY_BASIC_INFORMATION info;
        uintptr_t region_end;
        DWORD protection;
        if (!VirtualQuery((const void *)at, &info, sizeof(info)) || info.State != MEM_COMMIT ||
            info.Type != MEM_IMAGE || (uintptr_t)info.AllocationBase != g_game_base ||
            (info.Protect & (PAGE_GUARD | PAGE_NOACCESS))) return 0;
        protection = info.Protect & 0xffU;
        if (executable && protection != PAGE_EXECUTE_READ && protection != PAGE_EXECUTE_READWRITE &&
            protection != PAGE_EXECUTE_WRITECOPY) return 0;
        if (!readable_range((const void *)at, 1)) return 0;
        region_end = (uintptr_t)info.BaseAddress + info.RegionSize;
        if (region_end <= at) return 0;
        at = region_end < end ? region_end : end;
    }
    return 1;
}

static int read_image(uintptr_t rva, void *buffer, SIZE_T size) {
    return image_range(rva, size, 0) && safe_read((const void *)(g_game_base + rva), buffer, size);
}

static int writable_vptr(const void *object) {
    MEMORY_BASIC_INFORMATION info;
    DWORD protection;
    uintptr_t at = (uintptr_t)object;
    if ((at & (sizeof(void *) - 1U)) != 0 || !VirtualQuery(object, &info, sizeof(info))) return 0;
    if (info.State != MEM_COMMIT || (info.Protect & (PAGE_GUARD | PAGE_NOACCESS))) return 0;
    protection = info.Protect & 0xffU;
    if (protection != PAGE_READWRITE && protection != PAGE_WRITECOPY &&
        protection != PAGE_EXECUTE_READWRITE && protection != PAGE_EXECUTE_WRITECOPY) return 0;
    return at + sizeof(void *) <= (uintptr_t)info.BaseAddress + info.RegionSize;
}

static int signature_matches(uintptr_t rva, const unsigned char *expected, SIZE_T size) {
    unsigned char actual[64];
    if (size > sizeof(actual) || !image_range(rva, size, 1) ||
        !safe_read((const void *)(g_game_base + rva), actual, size)) return 0;
    return byte_signature_matches(actual, expected, size);
}

static void open_log(void) {
    wchar_t path[MAX_PATH];
    static const wchar_t name[] = L"maneater_codex_fps.log";
    DWORD length = GetModuleFileNameW(g_self, path, MAX_PATH);
    SIZE_T slash, i;
    if (length == 0 || length >= MAX_PATH) return;
    slash = length;
    while (slash > 0 && path[slash - 1] != L'\\' && path[slash - 1] != L'/') --slash;
    if (slash + (sizeof(name) / sizeof(name[0])) > MAX_PATH) return;
    for (i = 0; i < sizeof(name) / sizeof(name[0]); ++i) path[slash + i] = name[i];
    g_log = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                       NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
}

static void log_line(const char *line) {
    DWORD written;
    SIZE_T length = 0;
    if (g_log == INVALID_HANDLE_VALUE) return;
    while (line[length]) ++length;
    if (length > 1024U) return;
    WriteFile(g_log, line, (DWORD)length, &written, NULL);
    WriteFile(g_log, "\r\n", 2, &written, NULL);
}

static int validate_build(void) {
    IMAGE_DOS_HEADER dos;
    IMAGE_NT_HEADERS64 nt;
    wchar_t host_path[32768];
    DWORD host_length;
    uintptr_t nt_rva;
    MEMORY_BASIC_INFORMATION main_info;
    g_game_base = (uintptr_t)GetModuleHandleW(NULL);
    g_game_image_size = 0;
    g_experimental_build = 0;
    host_length = GetModuleFileNameW(NULL, host_path, (DWORD)(sizeof(host_path) / sizeof(host_path[0])));
    if (host_length == 0 || host_length >= sizeof(host_path) / sizeof(host_path[0]) ||
        !host_name_matches(host_path, host_length)) return 0;
    if (!g_game_base || !VirtualQuery((const void *)g_game_base, &main_info, sizeof(main_info)) ||
        main_info.Type != MEM_IMAGE || (uintptr_t)main_info.AllocationBase != g_game_base) return 0;
    if (!g_game_base || !safe_read((const void *)g_game_base, &dos, sizeof(dos))) return 0;
    if (dos.e_magic != IMAGE_DOS_SIGNATURE || dos.e_lfanew < 0 || dos.e_lfanew > 0x100000) return 0;
    nt_rva = (uintptr_t)dos.e_lfanew;
    if (nt_rva > UINTPTR_MAX - g_game_base ||
        !safe_read((const void *)(g_game_base + nt_rva), &nt, sizeof(nt)) ||
        !compatible_header(&nt, nt_rva + sizeof(nt), allow_untested_build(), &g_experimental_build)) return 0;
    g_game_image_size = nt.OptionalHeader.SizeOfImage;
    if (!image_range(0, sizeof(dos), 0) || !image_range(nt_rva, sizeof(nt), 0)) return 0;
    return signature_matches(ENGINE_SET_RVA, k_engine_set_prefix, sizeof(k_engine_set_prefix)) &&
        signature_matches(ENGINE_SET_CALL_RVA, k_engine_set_call, sizeof(k_engine_set_call)) &&
        signature_matches(CVAR_SET_RVA, k_console_set_prefix, sizeof(k_console_set_prefix)) &&
        signature_matches(CVAR_GETFLAGS_RVA, k_getflags, sizeof(k_getflags)) &&
        signature_matches(CVAR_GETDATA_RVA, k_getdata, sizeof(k_getdata)) &&
        signature_matches(CVAR_GETFLOAT_RVA, k_getfloat_prefix, sizeof(k_getfloat_prefix));
}

static int numeric_sixty(const wchar_t *value) {
    /* Read one bounded, committed region into local storage. The actual engine
     * string is owned by its existing call; ReadProcessMemory also avoids an
     * exception if a foreign caller supplies an inaccessible pointer.
     */
    wchar_t text[80];
    MEMORY_BASIC_INFORMATION info;
    uintptr_t at = (uintptr_t)value, region_end;
    SIZE_T available, chars, i = 0, zeros;
    if (!value || !VirtualQuery(value, &info, sizeof(info))) return 0;
    region_end = (uintptr_t)info.BaseAddress + info.RegionSize;
    if (region_end <= at) return 0;
    available = region_end - at;
    chars = available / sizeof(wchar_t);
    if (chars > sizeof(text) / sizeof(text[0])) chars = sizeof(text) / sizeof(text[0]);
    if (chars == 0 || !safe_read(value, text, chars * sizeof(wchar_t))) return 0;
    for (zeros = 0; zeros < chars && text[zeros] != L'\0'; ++zeros) {}
    if (zeros == chars) return 0;
    while (text[i] == L' ' || text[i] == L'\t' || text[i] == L'\r' || text[i] == L'\n') ++i;
    if (text[i] == L'+') ++i;
    while (text[i] == L'0') ++i;
    if (text[i] != L'6' || text[i + 1] != L'0') return 0;
    i += 2;
    if (text[i] == L'.') {
        ++i;
        if (text[i] != L'0') return 0;
        while (text[i] == L'0') ++i;
    }
    while (text[i] == L' ' || text[i] == L'\t' || text[i] == L'\r' || text[i] == L'\n') ++i;
    return text[i] == L'\0';
}

static void __fastcall hooked_set(void *object, const wchar_t *value, uint32_t flags) {
    const wchar_t *forwarded = value;
    uintptr_t caller = (uintptr_t)CALLER_RETURN_ADDRESS();
    ConsoleSetFn original = g_original_set;
    /* Original is set before the atomic vptr exchange and never changes. */
    if (object == g_target_object && caller == g_game_base + ENGINE_SET_RETURN_RVA && numeric_sixty(value)) {
        forwarded = k_replacement;
        InterlockedIncrement(&g_redirect_count);
        if (InterlockedCompareExchange(&g_first_capture_state, -1, 0) == 0) {
            g_first_stack_count = CaptureStackBackTrace(0, STACK_CAPACITY, g_first_stack, NULL);
            InterlockedExchange(&g_first_capture_state, 1);
        }
    }
    original(object, forwarded, flags);
}

/* Return0 means not initialized yet; -1 means this object is incompatible. */
static int validate_object(void *object, void ***vtable_out, float values[2], uint32_t *flags_out) {
    unsigned char fields[64];
    void **vtable;
    void *data_pointer;
    void *slots[SHADOW_SLOT_COUNT];
    wchar_t help[80];
    uintptr_t help_pointer;
    int32_t help_count, help_capacity;
    uint32_t flags;
    SIZE_T i, expected_count = sizeof(k_expected_help) / sizeof(k_expected_help[0]);
    if (!object) return 0;
    if (!safe_read(object, fields, sizeof(fields))) return -1;
    memcpy(&vtable, fields, sizeof(vtable));
    if ((uintptr_t)vtable != g_game_base + CVAR_VTABLE_RVA || !writable_vptr(object)) return -1;
    if (!image_range(CVAR_VTABLE_RVA - sizeof(void *), (SHADOW_SLOT_COUNT + 1U) * sizeof(void *), 0) ||
        !read_image(CVAR_VTABLE_RVA, slots, sizeof(slots))) return -1;
    if ((uintptr_t)slots[3] != g_game_base + CVAR_GETFLAGS_RVA ||
        (uintptr_t)slots[12] != g_game_base + CVAR_GETDATA_RVA ||
        (uintptr_t)slots[16] != g_game_base + CVAR_SET_RVA ||
        (uintptr_t)slots[19] != g_game_base + CVAR_GETFLOAT_RVA) return -1;
    if (!image_range(CVAR_GETFLAGS_RVA, sizeof(k_getflags), 1) ||
        !image_range(CVAR_GETDATA_RVA, sizeof(k_getdata), 1) ||
        !image_range(CVAR_SET_RVA, sizeof(k_console_set_prefix), 1) ||
        !image_range(CVAR_GETFLOAT_RVA, sizeof(k_getfloat_prefix), 1)) return -1;
    memcpy(&help_pointer, fields + 8, sizeof(help_pointer));
    memcpy(&help_count, fields + 16, sizeof(help_count));
    memcpy(&help_capacity, fields + 20, sizeof(help_capacity));
    if (help_count != (int32_t)expected_count || help_capacity < help_count || help_capacity > 4096) return -1;
    if (!safe_read((const void *)help_pointer, help, expected_count * sizeof(wchar_t))) return -1;
    for (i = 0; i < expected_count; ++i) if (help[i] != k_expected_help[i]) return -1;
    memcpy(&flags, fields + 24, sizeof(flags));
    if ((flags & 0x00ffffffU) != 0 || (flags & 0xff000000U) > 0x0a000000U) return -1;
    if (!read_image(CVAR_DATA_POINTER_RVA, &data_pointer, sizeof(data_pointer))) return -1;
    if (!data_pointer) return 0;
    if ((uintptr_t)data_pointer != (uintptr_t)object + 0x38U) return -1;
    memcpy(values, fields + 56, sizeof(float) * 2);
    *flags_out = flags;
    *vtable_out = vtable;
    return 1;
}

#include "getup_runtime.h"
#include "nav_runtime.h"

static DWORD WINAPI install_worker(void *unused) {
    void *object = NULL;
    void **original_vtable = NULL;
    float initial_values[2] = {0, 0};
    uint32_t flags = 0;
    ULONGLONG started;
    int validation = 0;
    HMODULE pinned;
    char line[256];
    (void)unused;
    open_log();
    log_line("Maneater FPS hook v0.9.0: requested native 60 -> 120; menu0 and other settings forwarded.");
    if (!validate_build()) {
        log_line("PASS-THROUGH: runtime build/signature guard rejected this executable; no object changed.");
        goto done;
    }
    getup_start_worker();
    nav_start_worker();
    if (g_experimental_build) {
        log_line("UNTESTED BUILD: explicit process opt-in allowed different PE metadata; exact fixed-RVA signatures matched. CVar identity/layout guards remain mandatory.");
    }
    started = GetTickCount64();
    do {
        if (!read_image(CVAR_OBJECT_POINTER_RVA, &object, sizeof(object))) {
            log_line("PASS-THROUGH: registered object pointer could not be read.");
            goto done;
        }
        validation = validate_object(object, &original_vtable, initial_values, &flags);
        if (validation != 0) break;
        Sleep(100);
    } while (GetTickCount64() - started < 120000U);
    if (validation != 1) {
        log_line(validation < 0 ? "PASS-THROUGH: CVar identity/layout/vtable guard rejected the object." :
            "PASS-THROUGH: CVar did not become initialized within120 seconds.");
        goto done;
    }
    g_shadow_allocation = (void **)VirtualAlloc(NULL, (SHADOW_SLOT_COUNT + 1U) * sizeof(void *),
                                               MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!g_shadow_allocation || !read_image(CVAR_VTABLE_RVA - sizeof(void *), g_shadow_allocation,
                                           (SHADOW_SLOT_COUNT + 1U) * sizeof(void *)) ||
        (uintptr_t)g_shadow_allocation[3U + 1U] != g_game_base + CVAR_GETFLAGS_RVA ||
        (uintptr_t)g_shadow_allocation[12U + 1U] != g_game_base + CVAR_GETDATA_RVA ||
        (uintptr_t)g_shadow_allocation[SET_SLOT + 1U] != g_game_base + CVAR_SET_RVA ||
        (uintptr_t)g_shadow_allocation[19U + 1U] != g_game_base + CVAR_GETFLOAT_RVA) {
        log_line("PASS-THROUGH: shadow vtable could not be allocated or copied.");
        goto done;
    }
    g_target_object = object;
    g_original_set = (ConsoleSetFn)g_shadow_allocation[SET_SLOT + 1U];
    g_shadow_allocation[SET_SLOT + 1U] = (void *)&hooked_set;
    /* Pin before publishing a pointer into this DLL; no unloading or freeing
     * shadow memory can invalidate a live object. Process exit reclaims both.
     */
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                            (LPCWSTR)(uintptr_t)&hooked_set, &pinned)) {
        log_line("PASS-THROUGH: DLL lifetime could not be pinned.");
        goto done;
    }
    MemoryBarrier();
    if (InterlockedCompareExchangePointer((void *volatile *)object, g_shadow_allocation + 1,
                                          original_vtable) != original_vtable) {
        log_line("PASS-THROUGH: vtable changed concurrently; no object overwritten.");
        goto done;
    }
    snprintf(line, sizeof(line), "INSTALLED: one CVar object; initial values %.3f/%.3f, flags0x%08lx. Awaiting an existing engine SetMaxFPS call.",
             initial_values[0], initial_values[1], (unsigned long)flags);
    log_line(line);
    /* The first capture is transferred through an interlocked completion flag.
     * Only this worker writes logs; the gameplay hook performs no file I/O.
     */
    for (;;) {
        Sleep(1000);
        if (InterlockedCompareExchange(&g_first_capture_state, 1, 1) == 1) {
            USHORT i;
            log_line("REDIRECTED: verified native call requested60; forwarded120 with its original flags/callback.");
            for (i = 0; i < g_first_stack_count; ++i) {
                uintptr_t address = (uintptr_t)g_first_stack[i];
                if (address >= g_game_base && address - g_game_base < g_game_image_size) {
                    snprintf(line, sizeof(line), "first redirect game frame%u: RVA0x%llx", (unsigned)i,
                             (unsigned long long)(address - g_game_base));
                    log_line(line);
                }
            }
            break;
        }
    }
done:
    if (g_log != INVALID_HANDLE_VALUE) { CloseHandle(g_log); g_log = INVALID_HANDLE_VALUE; }
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved) {
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        HANDLE thread;
        g_self = instance;
        DisableThreadLibraryCalls(instance);
        thread = CreateThread(NULL, 0, install_worker, NULL, 0, NULL);
        if (thread) CloseHandle(thread);
    }
    /* No detach cleanup: the installed object may still dispatch through this
     * module. Pinning and process-lifetime shadow storage prevent dangling code.
     */
    return TRUE;
}
