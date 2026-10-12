#ifndef MANEATER_PRIVATE_GETUP_CORE_H
#define MANEATER_PRIVATE_GETUP_CORE_H

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#if defined(_WIN32)
#define GETUP_CALL __fastcall
#else
#define GETUP_CALL
#endif

/* This private candidate mirrors the readable sibling getter's array-copy /
 * selector contract. The obscured Down getter is not fully devirtualized;
 * equivalence to that getter is an explicitly documented inference. */
typedef struct GetupArray {
    void **data;
    int32_t count;
    int32_t capacity;
} GetupArray;

typedef void (GETUP_CALL *GetupExec)(void *, void *, void *);
typedef void (GETUP_CALL *GetupReserve)(GetupArray *, int32_t, int32_t);
typedef void *(GETUP_CALL *GetupSelect)(void *, GetupArray *);
typedef void (GETUP_CALL *GetupFree)(void *);
typedef int (*GetupRead)(const void *, void *, size_t);
typedef int (*GetupWritable)(const void *, size_t);

typedef struct GetupEnvironment {
    void *function;
    GetupReserve reserve;
    GetupSelect select;
    GetupFree release;
    GetupRead read;
    GetupWritable writable;
} GetupEnvironment;

#define GETUP_ARRAY_OFFSET 0x910U
#define GETUP_FRAME_CODE_OFFSET 0x20U
#define GETUP_FRAME_NATIVE_OFFSET 0x88U
#define GETUP_MAX_COUNT 4096

static int getup_array_valid(GetupArray a) {
    return a.count >= 0 && a.count <= GETUP_MAX_COUNT &&
        a.capacity >= a.count && a.capacity <= GETUP_MAX_COUNT &&
        (a.count == 0 || a.data != NULL);
}

/* Return zero without consuming any bytecode or touching the result when the
 * inputs are not the narrow, known no-argument native call. The caller then
 * invokes the original entry point. Game-owned allocations use the original
 * allocator and are transferred to the original selector, which frees them.
 */
static int getup_try_dispatch(const GetupEnvironment *e, void *self,
                              void *frame, void *result) {
    uintptr_t object = (uintptr_t)self, stack = (uintptr_t)frame;
    uintptr_t code = 0, next_code;
    void *active = NULL, *selected;
    unsigned char terminator = 0;
    GetupArray source = {0}, copy = {0};
    size_t bytes;
    if (!e || !e->function || !e->reserve || !e->select || !e->release ||
        !e->read || !e->writable || !self || !frame || !result ||
        object > UINTPTR_MAX - GETUP_ARRAY_OFFSET - sizeof(source) ||
        stack > UINTPTR_MAX - GETUP_FRAME_NATIVE_OFFSET - sizeof(active)) return 0;
    if (!e->read((const void *)(stack + GETUP_FRAME_NATIVE_OFFSET), &active, sizeof(active)) ||
        active != e->function ||
        !e->read((const void *)(stack + GETUP_FRAME_CODE_OFFSET), &code, sizeof(code)) ||
        !e->writable((void *)(stack + GETUP_FRAME_CODE_OFFSET), sizeof(code)) ||
        !e->writable(result, sizeof(selected))) return 0;
    if (code && (code == UINTPTR_MAX ||
        !e->read((const void *)code, &terminator, 1) || terminator != 0x16)) return 0;
    if (!e->read((const void *)(object + GETUP_ARRAY_OFFSET), &source, sizeof(source)) ||
        !getup_array_valid(source)) return 0;
    bytes = (size_t)source.count * sizeof(void *);
    copy.count = source.count;
    if (source.count) {
        e->reserve(&copy, source.count, 0);
        if (!copy.data || copy.capacity < copy.count ||
            !e->writable(copy.data, bytes) || !e->read(source.data, copy.data, bytes)) {
            if (copy.data) e->release(copy.data);
            return 0;
        }
    }
    /* No new engine selection algorithm: keep the original null filtering,
     * random draw (including its empty-array behavior), and ownership rules.
     * All four existing Blueprint getter calls remain in their original order.
     */
    next_code = code + (code != 0);
    memcpy((void *)(stack + GETUP_FRAME_CODE_OFFSET), &next_code, sizeof(next_code));
    selected = e->select(self, &copy);
    memcpy(result, &selected, sizeof(selected));
    return 1;
}
#endif
