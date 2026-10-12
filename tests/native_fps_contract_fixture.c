/* Standalone EXE tests. Including the implementation does not run DllMain;
 * main never starts its worker, publishes a vtable, or loads the proxy DLL.
 */
#include "../src/maneater_fps_hook.c"

static const wchar_t *test_forwarded;
static uint32_t test_flags;
static void *test_object;
static unsigned test_calls;
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
    if (validate_build()) { puts("FAIL: unrelated test EXE passed game build guard"); return 1; }
    puts("PASS: decimal parser boundaries, invalid pointers, unrelated caller ABI/flags, and unknown-build refusal.");
    puts("No DLL loaded, worker started, game object accessed, or vtable installed.");
    return 0;
}
