#ifndef MANEATER_NAV_FIXTURE_CONTRACT_H
#define MANEATER_NAV_FIXTURE_CONTRACT_H
#include "../src/nav_install_contract.h"
typedef struct NavFixtureShared {
    NavInstallShared install;
    volatile int32_t stop;
    volatile int32_t errors;
    volatile int32_t heartbeat;
    volatile int32_t body_calls[NAV_INSTALL_HOOKS];
    volatile int32_t wrapper_calls[NAV_INSTALL_HOOKS];
} NavFixtureShared;
#endif
