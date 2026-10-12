#ifndef MANEATER_PRIVATE_GETUP_RUNTIME_H
#define MANEATER_PRIVATE_GETUP_RUNTIME_H
#include "getup_core.h"
#include "getup_signatures.h"

#define GETUP_FUNCTION_GLOBAL_RVA 0x4868c20U
#define GETUP_CONSTRUCTOR_PAIR_RVA 0x375a5d0U
#define GETUP_CONSTRUCTOR_RVA 0xe395f0U
#define GETUP_FUNCTION_DESCRIPTOR_RVA 0x4600830U
#define GETUP_FUNCTION_PAIR_RVA 0x375d310U
#define GETUP_FUNCTION_NAME_RVA 0x3759a88U
#define GETUP_PROPERTY_RVA 0x375b308U
#define GETUP_PROPERTY_NAME_RVA 0x3756c88U
#define GETUP_NATIVE_SLOT_OFFSET 0xd8U

static GetupEnvironment g_getup_environment;
static GetupExec g_getup_original;

static int getup_writable_range(const void *address, size_t size) {
    uintptr_t at = (uintptr_t)address, end;
    if (!address || !size || size > UINTPTR_MAX - at) return 0;
    end = at + size;
    while (at < end) {
        MEMORY_BASIC_INFORMATION m;
        uintptr_t next;
        DWORD p;
        if (!VirtualQuery((const void *)at, &m, sizeof(m)) || m.State != MEM_COMMIT ||
            (m.Protect & (PAGE_GUARD | PAGE_NOACCESS))) return 0;
        p = m.Protect & 0xffU;
        if (p != PAGE_READWRITE && p != PAGE_WRITECOPY &&
            p != PAGE_EXECUTE_READWRITE && p != PAGE_EXECUTE_WRITECOPY) return 0;
        next = (uintptr_t)m.BaseAddress + m.RegionSize;
        if (next <= at) return 0;
        at = next < end ? next : end;
    }
    return 1;
}

static int getup_complete_signature(uintptr_t rva, const unsigned char *bytes, size_t size) {
    size_t done = 0;
    while (done < size) {
        size_t part = size - done;
        if (part > 64) part = 64;
        if (!signature_matches(rva + done, bytes + done, part)) return 0;
        done += part;
    }
    return 1;
}

static int getup_image_string(uintptr_t rva, const char *expected, size_t bytes) {
    char actual[80];
    return bytes <= sizeof(actual) && read_image(rva, actual, bytes) &&
        memcmp(actual, expected, bytes) == 0;
}

static int getup_static_guards(void) {
    uintptr_t pair[2], constructor_pair[2], descriptor_name, property_name, owned_property;
    unsigned char property[48];
    uint32_t kind, count, offset;
    static const char function_name[] = "GetUninjuredChestDownGetupAnimation";
    static const char array_name[] = "UninjuredGetupChestDown";
    /* Experimental-build opt-in for the public FPS fix never waives these
     * private fixed-layout guards. Installation also checks the full file hash.
     */
    if (g_experimental_build ||
        !getup_complete_signature(GETUP_SELECTOR_RVA, getup_sig_selector, sizeof(getup_sig_selector)) ||
        !getup_complete_signature(GETUP_RESERVE_RVA, getup_sig_reserve, sizeof(getup_sig_reserve)) ||
        !getup_complete_signature(GETUP_FREE_RVA, getup_sig_free, sizeof(getup_sig_free)) ||
        !getup_complete_signature(GETUP_INVOKE_RVA, getup_sig_invoke, sizeof(getup_sig_invoke)) ||
        !getup_complete_signature(GETUP_METADATA_GETTER_RVA, getup_sig_metadata_getter, sizeof(getup_sig_metadata_getter)) ||
        !getup_complete_signature(GETUP_ORIGINAL_ENTRY_RVA, getup_sig_original_entry, sizeof(getup_sig_original_entry)) ||
        !read_image(GETUP_CONSTRUCTOR_PAIR_RVA, constructor_pair, sizeof(constructor_pair)) ||
        constructor_pair[0] != g_game_base + GETUP_CONSTRUCTOR_RVA ||
        constructor_pair[1] != g_game_base + GETUP_FUNCTION_NAME_RVA ||
        !read_image(GETUP_FUNCTION_DESCRIPTOR_RVA + 0x10U, &descriptor_name, sizeof(descriptor_name)) ||
        descriptor_name != g_game_base + GETUP_FUNCTION_NAME_RVA ||
        !read_image(0x375c688U, &owned_property, sizeof(owned_property)) ||
        owned_property != g_game_base + GETUP_PROPERTY_RVA ||
        !read_image(GETUP_FUNCTION_PAIR_RVA, pair, sizeof(pair)) ||
        pair[0] != g_game_base + GETUP_FUNCTION_NAME_RVA ||
        pair[1] != g_game_base + GETUP_ORIGINAL_ENTRY_RVA ||
        !getup_image_string(GETUP_FUNCTION_NAME_RVA, function_name, sizeof(function_name)) ||
        !getup_image_string(GETUP_PROPERTY_NAME_RVA, array_name, sizeof(array_name)) ||
        !read_image(GETUP_PROPERTY_RVA, property, sizeof(property))) return 0;
    memcpy(&property_name, property, sizeof(property_name));
    memcpy(&kind, property + 0x18, sizeof(kind));
    memcpy(&count, property + 0x20, sizeof(count));
    memcpy(&offset, property + 0x24, sizeof(offset));
    return property_name == g_game_base + GETUP_PROPERTY_NAME_RVA &&
        kind == 0x16 && count == 1 && offset == GETUP_ARRAY_OFFSET;
}

static void GETUP_CALL getup_private_exec(void *self, void *frame, void *result) {
    if (!getup_try_dispatch(&g_getup_environment, self, frame, result))
        g_getup_original(self, frame, result);
}

static void getup_write_log(HANDLE log, const char *message) {
    DWORD written;
    if (log == INVALID_HANDLE_VALUE) return;
    WriteFile(log, message, (DWORD)strlen(message), &written, NULL);
    WriteFile(log, "\r\n", 2, &written, NULL);
}

static HANDLE getup_open_log(void) {
    wchar_t path[MAX_PATH];
    static const wchar_t name[] = L"maneater_getup_fix.log";
    DWORD length = GetModuleFileNameW(g_self, path, MAX_PATH);
    size_t slash;
    if (!length || length >= MAX_PATH) return INVALID_HANDLE_VALUE;
    slash = length;
    while (slash && path[slash-1] != L'\\' && path[slash-1] != L'/') --slash;
    if (slash + sizeof(name)/sizeof(name[0]) > MAX_PATH) return INVALID_HANDLE_VALUE;
    memcpy(path + slash, name, sizeof(name));
    return CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                       NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
}

static DWORD WINAPI getup_install_worker(void *unused) {
    HANDLE log = getup_open_log();
    HMODULE pinned;
    ULONGLONG started = GetTickCount64();
    void *function = NULL, *native = NULL;
    void *volatile *slot = NULL;
    (void)unused;
    getup_write_log(log, "Maneater v0.7.0: optimized uninjured chest-down get-up animation lookup.");
    if (!getup_static_guards()) {
        getup_write_log(log, "PASS-THROUGH: strict native helper, registration or array-layout guard failed.");
        goto done;
    }
    /* Read published metadata only. No UE factory, allocator or selector is
     * called on this worker. The typed selector runs only in the game's call.
     */
    do {
        if (!read_image(GETUP_FUNCTION_GLOBAL_RVA, &function, sizeof(function))) {
            getup_write_log(log, "PASS-THROUGH: function metadata global became unreadable.");
            goto done;
        }
        if (function && (uintptr_t)function <= UINTPTR_MAX - GETUP_NATIVE_SLOT_OFFSET - sizeof(void *)) {
            slot = (void *volatile *)((uintptr_t)function + GETUP_NATIVE_SLOT_OFFSET);
            if (!safe_read((const void *)slot, &native, sizeof(native))) {
                getup_write_log(log, "PASS-THROUGH: published native slot could not be read.");
                goto done;
            }
            if (native == (void *)(g_game_base + GETUP_ORIGINAL_ENTRY_RVA)) break;
        }
        Sleep(250);
    } while (GetTickCount64() - started < 300000U);
    if (!slot || native != (void *)(g_game_base + GETUP_ORIGINAL_ENTRY_RVA)) {
        getup_write_log(log, "PASS-THROUGH: expected native function did not become available within five minutes; foreign entries were preserved.");
        goto done;
    }
    if (native != (void *)(g_game_base + GETUP_ORIGINAL_ENTRY_RVA) ||
        !writable_vptr((const void *)slot) || !getup_static_guards()) {
        getup_write_log(log, "PASS-THROUGH: native function is different or already modified.");
        goto done;
    }
    g_getup_original = (GetupExec)native;
    g_getup_environment.function = function;
    g_getup_environment.reserve = (GetupReserve)(g_game_base + GETUP_RESERVE_RVA);
    g_getup_environment.select = (GetupSelect)(g_game_base + GETUP_SELECTOR_RVA);
    g_getup_environment.release = (GetupFree)(g_game_base + GETUP_FREE_RVA);
    g_getup_environment.read = safe_read;
    g_getup_environment.writable = getup_writable_range;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                            (LPCWSTR)(uintptr_t)&getup_private_exec, &pinned)) {
        getup_write_log(log, "PASS-THROUGH: replacement module could not be pinned.");
        goto done;
    }
    MemoryBarrier();
    if (InterlockedCompareExchangePointer(slot, (void *)&getup_private_exec, native) != native) {
        getup_write_log(log, "PASS-THROUGH: native slot changed concurrently; it was not overwritten.");
        goto done;
    }
    getup_write_log(log, "INSTALLED: one native function pointer. Original selector/RNG retained; no executable instructions or game assets changed.");
done:
    if (log != INVALID_HANDLE_VALUE) CloseHandle(log);
    return 0;
}

static void getup_start_worker(void) {
    HMODULE pinned;
    HANDLE worker;
    /* The polling worker also needs a live module even before a function slot
     * is published. This holds the private DLL for the process lifetime. */
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                            (LPCWSTR)(uintptr_t)&getup_install_worker, &pinned)) return;
    worker = CreateThread(NULL, 0, getup_install_worker, NULL, 0, NULL);
    if (worker) CloseHandle(worker);
}
#endif
