/* Offline synthetic ABI fixture. No game, worker, publication or helper runs. */
#include "../src/maneater_fps_hook.c"
#include <stdlib.h>

static unsigned assertions,calls;
#define CHECK(x) do { ++assertions; if(!(x)){fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x);exit(1);} } while(0)
typedef struct LoadingProbe {
    uintptr_t arg1,filename;
    uint32_t flags,padding;
    uintptr_t arg4,arg5,result;
    uint64_t nonvolatile[8],xmm[20];
} LoadingProbe;
_Static_assert(offsetof(LoadingProbe,result)==40,"probe result");
_Static_assert(offsetof(LoadingProbe,nonvolatile)==48,"probe registers");
_Static_assert(offsetof(LoadingProbe,xmm)==112,"probe XMM registers");
extern void loading_abi_probe(void *,LoadingProbe *);
static LoadingProbe expected;
static DWORD incoming_error,outgoing_error;
static unsigned incoming_mxcsr,outgoing_mxcsr;
static void *__fastcall loader_mock(void *a,const wchar_t *b,uint32_t c,void *inserted,void *d,void *e) {
    ++calls;
    CHECK((uintptr_t)a==expected.arg1 && (uintptr_t)b==expected.filename);
    CHECK(c==expected.flags && inserted==NULL);
    CHECK((uintptr_t)d==expected.arg4 && (uintptr_t)e==expected.arg5);
    CHECK(GetLastError()==incoming_error && _mm_getcsr()==incoming_mxcsr);
    SetLastError(outgoing_error);_mm_setcsr(outgoing_mxcsr);
    return (void *)expected.result;
}
static void *__fastcall loader_exception(void *a,const wchar_t *b,uint32_t c,void *d,void *e,void *f) {
    (void)a;(void)b;(void)c;(void)d;(void)e;(void)f;
    RaiseException(UINT32_C(0xe00a71f4),0,0,NULL);return NULL;
}
static uint64_t random_bits(uint64_t *s){*s^=*s<<13;*s^=*s>>7;*s^=*s<<17;return *s;}
static void test_forwarding(void) {
    static const uint32_t flags[]={0,1,UINT32_C(0x7fffffff),UINT32_C(0x80000000),UINT32_MAX};
    static const uint64_t nonvolatile[]={UINT64_C(0x1011223344556677),UINT64_C(0x2022334455667788),
        UINT64_C(0x3033445566778899),UINT64_C(0x40445566778899aa),UINT64_C(0x505566778899aabb),
        UINT64_C(0x6066778899aabbcc),UINT64_C(0x70778899aabbccdd),UINT64_C(0x808899aabbccddee)};
    void *unreadable=VirtualAlloc(NULL,4096,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);CHECK(unreadable!=NULL);
    uint64_t state=UINT64_C(0x3909b227ba792187);
    loading_internal=&loader_mock;
    for(unsigned i=0;i<4096;++i) {
        LoadingProbe p;memset(&p,0,sizeof(p));
        p.arg1=i%7?random_bits(&state):0;
        p.filename=i%4?random_bits(&state):(uintptr_t)unreadable;
        p.flags=i<5?flags[i]:(uint32_t)random_bits(&state);
        p.arg4=random_bits(&state);p.arg5=i%3?random_bits(&state):0;p.result=random_bits(&state);
        expected=p;incoming_error=(DWORD)i+311;outgoing_error=(DWORD)i+711;
        incoming_mxcsr=0x1f80U|((i&3U)<<13);outgoing_mxcsr=incoming_mxcsr|0x20U;
        _mm_setcsr(incoming_mxcsr);SetLastError(incoming_error);
        loading_abi_probe((void *)&loading_package,&p);
        CHECK(p.result==expected.result);
        CHECK(GetLastError()==outgoing_error && _mm_getcsr()==outgoing_mxcsr);
        CHECK(!memcmp(p.nonvolatile,nonvolatile,sizeof(nonvolatile)));
        for(unsigned j=0;j<10;++j) {
            CHECK(p.xmm[j*2]==UINT64_C(0x1122334455667700)+j);
            CHECK(p.xmm[j*2+1]==UINT64_C(0x8877665544332200)+j);
        }
    }
    CHECK(calls==4096);CHECK(VirtualFree(unreadable,0,MEM_RELEASE));
    loading_internal=&loader_exception;int caught=0;
    __try { (void)loading_package(NULL,NULL,UINT32_MAX,NULL,NULL); }
    __except(GetExceptionCode()==UINT32_C(0xe00a71f4)?EXCEPTION_EXECUTE_HANDLER:EXCEPTION_CONTINUE_SEARCH) { caught=1; }
    CHECK(caught);loading_internal=&loader_mock;
}
static void test_trampoline(void) {
    unsigned char *region=VirtualAlloc(NULL,4096,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);CHECK(region!=NULL);
    unsigned char *target=region+128,*trampoline=region+512;
    memcpy(target,LOADING_WRAPPER_SIGNATURE,LOADING_WRAPPER_SIZE);
    TRAMPOLINE t;memset(&t,0,sizeof(t));t.pTarget=target;t.pTrampoline=trampoline;t.pDetour=(void *)&loading_package;
    CHECK(CreateTrampolineFunction(&t));CHECK(!t.patchAbove && t.nIP==3);
    CHECK(t.oldIPs[0]==0 && t.oldIPs[1]==3 && t.oldIPs[2]==7);
    CHECK(t.newIPs[0]==0 && t.newIPs[1]==3 && t.newIPs[2]==7);
    CHECK(t.pRelay==trampoline+21);
    unsigned char expected_bytes[35]={0};memcpy(expected_bytes,LOADING_WRAPPER_SIGNATURE,7);
    nav_absjump(expected_bytes+7,(uintptr_t)target+7);nav_absjump(expected_bytes+21,(uintptr_t)&loading_package);
    CHECK(!memcmp(expected_bytes,trampoline,sizeof(expected_bytes)));
    CHECK(nav_register_unwind(2,trampoline));
    static const unsigned offsets[]={0,3,7,13,20,21,34};
    static const unsigned char body_info[]={2,7,2,0,7,0x34,2,0},relay_info[]={1,0,0,0};
    CHECK(!memcmp(trampoline+40,body_info,sizeof(body_info)) && !memcmp(trampoline+48,relay_info,sizeof(relay_info)));
    for(unsigned i=0;i<sizeof(offsets)/sizeof(offsets[0]);++i) {
        DWORD64 image_base=0;RUNTIME_FUNCTION *f=RtlLookupFunctionEntry((DWORD64)(uintptr_t)(trampoline+offsets[i]),&image_base,NULL);
        CHECK(f==&nav_unwind[2][offsets[i]>=21] && image_base==(DWORD64)(uintptr_t)trampoline);
        DWORD64 stack[8]={UINT64_C(0x1020304050607080),0,UINT64_C(0x99aabbccddeeff00)};
        CONTEXT c;memset(&c,0,sizeof(c));c.Rsp=(DWORD64)(uintptr_t)stack;c.Rip=image_base+offsets[i];c.Rbx=UINT64_C(0xdeadbeef12345678);
        PVOID handler=NULL;DWORD64 frame=0;RtlVirtualUnwind(0,image_base,c.Rip,f,&c,&handler,&frame,NULL);
        CHECK(c.Rip==stack[0] && c.Rsp==(DWORD64)(uintptr_t)(stack+1));
        CHECK(c.Rbx==((offsets[i]>=7 && offsets[i]<21)?stack[2]:UINT64_C(0xdeadbeef12345678)));
    }
    CHECK(RtlDeleteFunctionTable(nav_unwind[2]));CHECK(VirtualFree(region,0,MEM_RELEASE));
}
int main(void) {
    unsigned saved=_mm_getcsr();test_forwarding();test_trampoline();_mm_setcsr(saved);
    CHECK(NAV_INSTALL_VERSION==2 && NAV_INSTALL_HOOKS==3 && sizeof(NavInstallShared)==6544);
    printf("{\"Passed\":true,\"Assertions\":%u,\"ForwardedCalls\":%u,\"UnwindBoundaries\":7,\"GameExecuted\":false,\"AttachmentExecuted\":false}\n",assertions,calls);return 0;
}
