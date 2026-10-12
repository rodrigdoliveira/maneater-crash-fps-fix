#ifndef MANEATER_PRIVATE_LOADING_RUNTIME_H
#define MANEATER_PRIVATE_LOADING_RUNTIME_H
#include <stdint.h>
#include <wchar.h>
#include "loading_signatures.h"

/* The fully guarded stock wrapper constructs a temporary label which never
 * reaches the loader. Preserve all five opaque inputs, the inserted NULL,
 * and the inner loader's full pointer-sized result. No filename inspection,
 * logging, allocation or game-state access occurs in this replacement. */
typedef void *(__fastcall *LoadingInternalFn)(void *,const wchar_t *,uint32_t,void *,void *,void *);
static LoadingInternalFn loading_internal;
static __attribute__((noinline)) void *__fastcall loading_package(
    void *outer,const wchar_t *filename,uint32_t flags,void *arg4,void *arg5) {
    return loading_internal(outer,filename,flags,NULL,arg4,arg5);
}
#endif
