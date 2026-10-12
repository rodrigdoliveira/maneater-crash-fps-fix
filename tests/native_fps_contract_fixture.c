/* Standalone EXE tests. Including the implementation does not run DllMain;
 * main never starts its worker, publishes a vtable, or loads the proxy DLL.
 */
#include "../src/maneater_fps_hook.c"

static const wchar_t *test_forwarded;
static uint32_t test_flags;
static void *test_object;
static unsigned test_calls;
#define REQUIRE_FIXTURE(condition, message) do { if (!(condition)) { puts("FAIL: " message); return 0; } } while (0)

static int test_optin_and_metadata(void) {
    static const wchar_t *values[] = {NULL, L"", L"0", L"1", L"11", L"true", L" 1", L"1 "};
    IMAGE_NT_HEADERS64 nt, changed;
    unsigned char bytes[sizeof(k_engine_set_prefix) + 1U];
    int experimental = 0;
    SIZE_T i;
    for (i = 0; i < sizeof(values) / sizeof(values[0]); ++i) {
        REQUIRE_FIXTURE(SetEnvironmentVariableW(L"MANEATER_FIX_ALLOW_UNTESTED", values[i]), "fixture process environment set");
        REQUIRE_FIXTURE(allow_untested_build() == (i == 3U), "only exact environment value1 opts in");
    }
    REQUIRE_FIXTURE(SetEnvironmentVariableW(L"MANEATER_FIX_ALLOW_UNTESTED", NULL), "fixture environment unset");
    REQUIRE_FIXTURE(host_name_matches(L"D:\\Games\\Maneater-Win64-Shipping.exe", sizeof(L"D:\\Games\\Maneater-Win64-Shipping.exe") / sizeof(wchar_t) - 1U), "expected host basename");
    REQUIRE_FIXTURE(host_name_matches(L"MANEATER-WIN64-SHIPPING.EXE", sizeof(L"MANEATER-WIN64-SHIPPING.EXE") / sizeof(wchar_t) - 1U), "host basename ASCII case");
    REQUIRE_FIXTURE(!host_name_matches(L"Maneater.exe", sizeof(L"Maneater.exe") / sizeof(wchar_t) - 1U) &&
        !host_name_matches(L"Maneater-Win64-Shipping.exe.bak", sizeof(L"Maneater-Win64-Shipping.exe.bak") / sizeof(wchar_t) - 1U), "other host basenames refused");

    memset(&nt, 0, sizeof(nt));
    nt.Signature = IMAGE_NT_SIGNATURE;
    nt.FileHeader.Machine = IMAGE_FILE_MACHINE_AMD64;
    nt.FileHeader.SizeOfOptionalHeader = sizeof(IMAGE_OPTIONAL_HEADER64);
    nt.FileHeader.NumberOfSections = 1;
    nt.FileHeader.TimeDateStamp = EXPECTED_TIMESTAMP;
    nt.OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR64_MAGIC;
    nt.OptionalHeader.SizeOfHeaders = 0x400U;
    nt.OptionalHeader.SizeOfImage = EXPECTED_IMAGE_SIZE;
    nt.OptionalHeader.AddressOfEntryPoint = EXPECTED_ENTRYPOINT;
    REQUIRE_FIXTURE(compatible_header(&nt, 0x80U + sizeof(nt), 0, &experimental) && !experimental,
        "known metadata allowed without opt-in");
    changed = nt; changed.FileHeader.TimeDateStamp ^= 1U;
    REQUIRE_FIXTURE(!compatible_header(&changed, 0x80U + sizeof(changed), 0, &experimental), "changed timestamp strict refusal");
    REQUIRE_FIXTURE(compatible_header(&changed, 0x80U + sizeof(changed), 1, &experimental) && experimental,
        "changed timestamp allowed only by explicit opt-in");
    changed = nt; changed.OptionalHeader.SizeOfImage -= 0x1000U;
    REQUIRE_FIXTURE(!compatible_header(&changed, 0x80U + sizeof(changed), 0, &experimental) &&
        compatible_header(&changed, 0x80U + sizeof(changed), 1, &experimental) && experimental,
        "different fitting image size gated by opt-in");
    changed = nt; changed.OptionalHeader.AddressOfEntryPoint += 16U;
    REQUIRE_FIXTURE(!compatible_header(&changed, 0x80U + sizeof(changed), 0, &experimental) &&
        compatible_header(&changed, 0x80U + sizeof(changed), 1, &experimental) && experimental,
        "different valid entrypoint gated by opt-in");
    changed = nt; changed.FileHeader.Machine = IMAGE_FILE_MACHINE_I386;
    REQUIRE_FIXTURE(!compatible_header(&changed, 0x80U + sizeof(changed), 1, &experimental), "opt-in cannot waive architecture");
    changed = nt; changed.OptionalHeader.Magic = IMAGE_NT_OPTIONAL_HDR32_MAGIC;
    REQUIRE_FIXTURE(!compatible_header(&changed, 0x80U + sizeof(changed), 1, &experimental), "opt-in cannot waive PE32+");
    changed = nt; changed.Signature = 0;
    REQUIRE_FIXTURE(!compatible_header(&changed, 0x80U + sizeof(changed), 1, &experimental), "invalid PE signature refused");
    changed = nt; changed.FileHeader.SizeOfOptionalHeader = 1;
    REQUIRE_FIXTURE(!compatible_header(&changed, 0x80U + sizeof(changed), 1, &experimental), "truncated optional header refused");
    changed = nt; changed.FileHeader.NumberOfSections = 0;
    REQUIRE_FIXTURE(!compatible_header(&changed, 0x80U + sizeof(changed), 1, &experimental), "missing image section headers refused");
    changed = nt; changed.FileHeader.NumberOfSections = 65535U;
    REQUIRE_FIXTURE(!compatible_header(&changed, 0x80U + sizeof(changed), 1, &experimental), "section table outside image headers refused");
    changed = nt; changed.OptionalHeader.SizeOfImage = CVAR_DATA_POINTER_RVA + (DWORD)sizeof(void *) - 1U;
    changed.OptionalHeader.AddressOfEntryPoint = 0x1000U;
    REQUIRE_FIXTURE(!compatible_header(&changed, 0x80U + sizeof(changed), 1, &experimental), "small image cannot contain required fixed layout");
    changed = nt; changed.OptionalHeader.AddressOfEntryPoint = changed.OptionalHeader.SizeOfImage;
    REQUIRE_FIXTURE(!compatible_header(&changed, 0x80U + sizeof(changed), 1, &experimental), "entrypoint outside image refused");
    REQUIRE_FIXTURE(!compatible_header(&nt, nt.OptionalHeader.SizeOfHeaders + 1U, 1, &experimental), "NT header outside image headers refused");
    REQUIRE_FIXTURE(rva_in_bounds(16, 8, 8) && !rva_in_bounds(16, 8, 9) &&
        !rva_in_bounds(16, 16, 1) && !rva_in_bounds(16, 0, 0) &&
        !rva_in_bounds(16, UINTPTR_MAX, 2), "fixed RVA exact boundary and overflow guards");
    memset(bytes, 0, sizeof(bytes));
    memcpy(bytes, k_engine_set_prefix, sizeof(k_engine_set_prefix));
    REQUIRE_FIXTURE(byte_signature_matches(bytes, k_engine_set_prefix, sizeof(k_engine_set_prefix)), "exact code signature matches");
    bytes[0] ^= 1U;
    REQUIRE_FIXTURE(!byte_signature_matches(bytes, k_engine_set_prefix, sizeof(k_engine_set_prefix)), "wrong code signature refused");
    memset(bytes, 0, sizeof(bytes));
    memcpy(bytes + 1, k_engine_set_prefix, sizeof(k_engine_set_prefix));
    REQUIRE_FIXTURE(!byte_signature_matches(bytes, k_engine_set_prefix, sizeof(k_engine_set_prefix)), "shifted fixed-offset signature refused");
    return 1;
}

static int test_image_ownership(void) {
    uintptr_t base = (uintptr_t)GetModuleHandleW(NULL);
    IMAGE_DOS_HEADER dos;
    IMAGE_NT_HEADERS64 nt;
    void *private_region;
    REQUIRE_FIXTURE(safe_read((const void *)base, &dos, sizeof(dos)) &&
        safe_read((const void *)(base + (uintptr_t)dos.e_lfanew), &nt, sizeof(nt)), "fixture own image header read");
    g_game_base = base; g_game_image_size = nt.OptionalHeader.SizeOfImage;
    REQUIRE_FIXTURE(image_range((uintptr_t)&numeric_sixty - base, 1, 1), "own mapped executable range accepted");
    REQUIRE_FIXTURE(image_range((uintptr_t)k_expected_help - base, sizeof(k_expected_help), 0), "own mapped readonly data accepted");
    REQUIRE_FIXTURE(!image_range(g_game_image_size, 1, 0) &&
        !image_range(UINTPTR_MAX, 2, 0), "out-of-image and shifted RVA refused");
    private_region = VirtualAlloc(NULL, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    REQUIRE_FIXTURE(private_region != NULL, "private fixture allocation");
    g_game_base = (uintptr_t)private_region; g_game_image_size = 4096;
    if (image_range(0, 8, 0)) {
        VirtualFree(private_region, 0, MEM_RELEASE);
        puts("FAIL: readable private allocation treated as game image"); return 0;
    }
    VirtualFree(private_region, 0, MEM_RELEASE);
    g_game_base = base; g_game_image_size = nt.OptionalHeader.SizeOfImage;
    return 1;
}
static void __fastcall record_set(void *object, const wchar_t *value, uint32_t flags) {
    test_object = object;
    test_forwarded = value;
    test_flags = flags;
    ++test_calls;
}

int main(void) {
    const wchar_t *accepted[] = {L"60",L"60.000000",L" +060.00 \t",L"60.0"};
    const wchar_t *rejected[] = {L"0",L"120",L"59.9999",L"60.1",L"-60",L"600",L"60fps",L"60e0",L"",L"   ",L"60."};
    wchar_t unterminated[80], boundary[80];
    unsigned i;
    int dummy_object = 0;
    if (!test_optin_and_metadata() || !test_image_ownership()) return 1;
    for (i = 0; i < sizeof(accepted)/sizeof(accepted[0]); ++i) {
        if (!numeric_sixty(accepted[i])) { puts("FAIL: decimal60 request not recognized"); return 1; }
    }
    for (i = 0; i < sizeof(rejected)/sizeof(rejected[0]); ++i) {
        if (numeric_sixty(rejected[i])) { puts("FAIL: non60 request matched"); return 1; }
    }
    if (numeric_sixty(NULL) || numeric_sixty((const wchar_t *)(uintptr_t)1)) { puts("FAIL: invalid pointer matched"); return 1; }
    for (i = 0; i < 80; ++i) { unterminated[i] = L'0'; boundary[i] = L' '; }
    if (numeric_sixty(unterminated)) { puts("FAIL: unterminated buffer matched"); return 1; }
    boundary[77]=L'6';boundary[78]=L'0';boundary[79]=L'\0';
    if (!numeric_sixty(boundary)) { puts("FAIL: valid final buffer positions rejected"); return 1; }
    boundary[78]=L'\0';
    if (numeric_sixty(boundary)) { puts("FAIL: boundary single digit matched"); return 1; }
    g_original_set = record_set;
    g_target_object = &dummy_object;
    g_game_base = (uintptr_t)GetModuleHandleW(NULL);
    /* This is an arbitrary caller, so even60 must retain its pointer and flags. */
    for (i = 0; i < sizeof(accepted)/sizeof(accepted[0]); ++i) {
        hooked_set(&dummy_object, accepted[i], 0x04000000U);
        if (test_object != &dummy_object || test_forwarded != accepted[i] || test_flags != 0x04000000U) {
            puts("FAIL: unrelated caller request was altered"); return 1;
        }
    }
    if (test_calls != sizeof(accepted)/sizeof(accepted[0]) || g_redirect_count != 0) { puts("FAIL: forwarding call count"); return 1; }
    if (validate_build()) { puts("FAIL: unrelated test EXE passed strict host/build guard"); return 1; }
    if (!SetEnvironmentVariableW(L"MANEATER_FIX_ALLOW_UNTESTED", L"1") || validate_build()) {
        puts("FAIL: process opt-in bypassed unrelated host refusal"); return 1;
    }
    SetEnvironmentVariableW(L"MANEATER_FIX_ALLOW_UNTESTED", NULL);
    puts("PASS: explicit opt-in, metadata-only relaxation, fixed RVA bounds/signatures/image ownership, parser and unrelated caller ABI.");
    puts("No DLL loaded, worker started, game object accessed, or vtable installed.");
    return 0;
}
