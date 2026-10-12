#ifndef MANEATER_PRIVATE_NAV_INSTALL_CONTRACT_H
#define MANEATER_PRIVATE_NAV_INSTALL_CONTRACT_H
#include <stdint.h>
#include <stddef.h>

#define NAV_INSTALL_MAGIC UINT64_C(0x31303056414E434D) /* MCNAV001 */
#define NAV_INSTALL_VERSION 2u
#define NAV_INSTALL_HOOKS 3u
#define NAV_INSTALL_MAX_GUARD 2048u
#define NAV_INSTALL_MAX_IPS 8u
/* DLL writes ready last, then treats the plan and all metadata as immutable.
   Installer owns installer_state/result/error fields. DLL only reads them.
   All code/storage remains resident even on rejection/rollback. */
#define NAV_INSTALL_PENDING 0
#define NAV_INSTALL_CLAIMED 1
#define NAV_INSTALL_INSTALLED 2
#define NAV_INSTALL_REJECTED 3
#define NAV_INSTALL_FATAL 4

#pragma pack(push, 8)
typedef struct NavInstallPlan {
    uint64_t target;
    uint64_t trampoline;
    uint64_t relay;
    uint64_t detour;
    uint32_t target_rva;
    uint32_t guard_length;
    uint32_t n_ip;
    uint32_t stolen_length;
    uint8_t old_ip[NAV_INSTALL_MAX_IPS];
    uint8_t new_ip[NAV_INSTALL_MAX_IPS];
    uint8_t original5[5];
    uint8_t patch5[5];
    uint8_t reserved[6];
    uint8_t guard[NAV_INSTALL_MAX_GUARD];
} NavInstallPlan;

typedef struct NavInstallShared {
    uint64_t magic;
    uint32_t version;
    uint32_t byte_size;
    uint32_t pid;
    uint32_t hook_count;
    uint64_t process_creation_filetime;
    uint64_t game_base;
    uint32_t game_image_size;
    uint32_t game_timestamp;
    uint8_t game_sha256[32];
    uint64_t publisher_base;
    uint32_t publisher_image_size;
    uint32_t publisher_timestamp;
    uint8_t instance_token[16];
    volatile int32_t ready;
    volatile int32_t installer_state;
    volatile int32_t result_code;
    volatile int32_t win32_error;
    volatile int32_t rollback_errors;
    volatile int32_t resume_errors;
    volatile int32_t contexts_moved;
    volatile int32_t threads_owned;
    uint64_t installer_creation_filetime;
    uint32_t installer_pid;
    uint32_t reserved;
    NavInstallPlan plans[NAV_INSTALL_HOOKS];
} NavInstallShared;
#pragma pack(pop)

_Static_assert(sizeof(NavInstallPlan) == 2128, "fixed plan layout");
_Static_assert(offsetof(NavInstallShared, ready) == 112, "aligned status");
_Static_assert(offsetof(NavInstallShared, plans) == 160, "fixed plans offset");
_Static_assert(sizeof(NavInstallShared) == 6544, "fixed mapping layout");
#endif
