/* Real memory-read integration for the get-up dispatcher. No game, DLL entry,
 * worker, selector, hook installation or production allocator is executed. */
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
static SIZE_T WINAPI observed_query(LPCVOID, PMEMORY_BASIC_INFORMATION, SIZE_T);
#define VirtualQuery observed_query
#include "../src/maneater_fps_hook.c"
#undef VirtualQuery
#include <stdlib.h>

static unsigned assertions, cases, queries, allocations, releases, selects, fallbacks;
#define CHECK(x) do { ++assertions; if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); exit(1); } } while (0)
static SIZE_T WINAPI observed_query(LPCVOID at, PMEMORY_BASIC_INFORMATION info, SIZE_T size) {
    ++queries;
    return VirtualQuery(at, info, size);
}
static unsigned char object[0x940], frame[0x100], code[2], marker;
static void *items[4], *result, *allocation;
static void *expected_items[4];
static int expected_count;
static uintptr_t expected_code;
static unsigned char expected_frame[sizeof(frame)];

static void GETUP_CALL reserve_mock(GetupArray *copy,int32_t count,int32_t slack) {
    ++allocations;
    CHECK(!allocation && !copy->data && copy->count==count && count>0 && count<=4 && slack==0);
    allocation=HeapAlloc(GetProcessHeap(),0,(size_t)count*sizeof(void *));
    CHECK(allocation!=NULL);
    copy->data=allocation;copy->capacity=count;
}
static void GETUP_CALL release_mock(void *p) {
    ++releases; CHECK(p==allocation && p!=NULL);
    CHECK(HeapFree(GetProcessHeap(),0,p)); allocation=NULL;
}
static void *GETUP_CALL select_mock(void *self,GetupArray *copy) {
    ++selects; CHECK(self==object && copy->count==expected_count);
    uintptr_t actual;memcpy(&actual,frame+GETUP_FRAME_CODE_OFFSET,sizeof(actual));
    CHECK(actual==expected_code);
    if(copy->count) {
        CHECK(copy->data==allocation && copy->data!=items);
        CHECK(!memcmp(copy->data,expected_items,(size_t)copy->count*sizeof(void *)));
        release_mock(copy->data);
    } else CHECK(!copy->data && !allocation);
    return &marker;
}
static void GETUP_CALL fallback_mock(void *self,void *stack,void *out) {
    ++fallbacks;CHECK(self==object);(void)stack;(void)out;
    /* Observe fallback without dereferencing a deliberately invalid input. */
}
static void setup(int count,int has_code) {
    CHECK(allocation==NULL);
    queries=allocations=releases=selects=fallbacks=0;
    memset(object,0,sizeof(object));memset(frame,0,sizeof(frame));
    code[0]=0x16;code[1]=0;
    items[0]=&marker;items[1]=NULL;items[2]=&marker;items[3]=&result;
    memcpy(expected_items,items,sizeof(items));
    result=(void *)(uintptr_t)0x12345678U;
    GetupArray source={items,count,count};
    memcpy(object+GETUP_ARRAY_OFFSET,&source,sizeof(source));
    uintptr_t current=has_code?(uintptr_t)code:0;
    memcpy(frame+GETUP_FRAME_CODE_OFFSET,&current,sizeof(current));
    void *function=&marker;
    memcpy(frame+GETUP_FRAME_NATIVE_OFFSET,&function,sizeof(function));
    memcpy(expected_frame,frame,sizeof(frame));
    expected_count=count;expected_code=current+(current!=0);
    g_getup_environment=(GetupEnvironment){&marker,reserve_mock,select_mock,release_mock,
        read_call_snapshot,getup_writable_range};
    g_getup_original=fallback_mock;
}
static void verify_failure(void) {
    CHECK(fallbacks==1 && selects==0 && allocation==NULL);
    CHECK(result==(void *)(uintptr_t)0x12345678U);
    CHECK(!memcmp(frame,expected_frame,sizeof(frame)));
    ++cases;
}
static void test_success(void) {
    for(int count=0;count<=4;++count) for(int has_code=0;has_code<2;++has_code) {
        setup(count,has_code);
        getup_private_exec(object,frame,&result);
        CHECK(result==&marker && selects==1 && fallbacks==0);
        CHECK(allocations==(unsigned)(count!=0) && releases==allocations && !allocation);
        /* The only region queries left are explicit writability checks:
         * Frame.Code and result, plus the allocated copy when nonempty. */
        CHECK(queries==(unsigned)(2+(count!=0)));
        memcpy(expected_frame+GETUP_FRAME_CODE_OFFSET,&expected_code,sizeof(expected_code));
        CHECK(!memcmp(frame,expected_frame,sizeof(frame)));
        CHECK(!memcmp(items,expected_items,sizeof(items)));
        ++cases;
    }
}
static void test_refusals(void) {
    SYSTEM_INFO info;GetSystemInfo(&info);size_t page=info.dwPageSize;
    unsigned char *memory=VirtualAlloc(NULL,page*2,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    CHECK(memory!=NULL && page>=sizeof(frame));DWORD previous;
    const DWORD protections[]={PAGE_NOACCESS,PAGE_READWRITE|PAGE_GUARD};
    for(unsigned i=0;i<2;++i) {
        setup(3,1);
        CHECK(VirtualProtect(memory,page,protections[i],&previous));
        getup_private_exec(object,memory,&result);
        verify_failure();CHECK(allocations==0 && queries==0);
        MEMORY_BASIC_INFORMATION state;
        CHECK(VirtualQuery(memory,&state,sizeof(state))==sizeof(state));
        CHECK(state.Protect==protections[i]); /* Snapshot must not consume guard. */
        CHECK(VirtualProtect(memory,page,PAGE_READWRITE,&previous));
    }
    setup(3,1);memcpy(memory,frame,sizeof(frame));
    CHECK(VirtualProtect(memory,page,PAGE_READONLY,&previous));
    getup_private_exec(object,memory,&result);
    verify_failure();CHECK(queries==1 && allocations==0);
    CHECK(!memcmp(memory,expected_frame,sizeof(frame)));
    CHECK(VirtualProtect(memory,page,PAGE_READWRITE,&previous));

    setup(3,1);memcpy(memory,&result,sizeof(result));
    CHECK(VirtualProtect(memory,page,PAGE_READONLY,&previous));
    getup_private_exec(object,frame,memory);
    verify_failure();CHECK(queries==2 && allocations==0);
    CHECK(!memcmp(memory,&result,sizeof(result)));
    CHECK(VirtualProtect(memory,page,PAGE_READWRITE,&previous));

    for(unsigned i=0;i<2;++i) {
        setup(3,1);
        GetupArray source={(void **)memory,3,3};
        memcpy(object+GETUP_ARRAY_OFFSET,&source,sizeof(source));
        CHECK(VirtualProtect(memory,page,protections[i],&previous));
        getup_private_exec(object,frame,&result);
        verify_failure();CHECK(allocations==1 && releases==1 && queries==3);
        MEMORY_BASIC_INFORMATION state;
        CHECK(VirtualQuery(memory,&state,sizeof(state))==sizeof(state));
        CHECK(state.Protect==protections[i]);
        CHECK(VirtualProtect(memory,page,PAGE_READWRITE,&previous));
    }
    /* A partial readable prefix must never reach selection or consume bytecode. */
    setup(3,1);
    GetupArray crossing={(void **)(memory+page-sizeof(void *)),3,3};
    memcpy(crossing.data,items,sizeof(void *));
    memcpy(object+GETUP_ARRAY_OFFSET,&crossing,sizeof(crossing));
    CHECK(VirtualProtect(memory+page,page,PAGE_NOACCESS,&previous));
    getup_private_exec(object,frame,&result);
    verify_failure();CHECK(allocations==1 && releases==1 && queries==3);
    CHECK(VirtualProtect(memory+page,page,PAGE_READWRITE,&previous));
    CHECK(VirtualFree(memory,0,MEM_RELEASE));
}
int main(void) {
    test_success();test_refusals();
    printf("{\"Passed\":true,\"Assertions\":%u,\"Cases\":%u,\"GameExecuted\":false,\"ProductionSnapshotReader\":true}\n",assertions,cases);
    return 0;
}
