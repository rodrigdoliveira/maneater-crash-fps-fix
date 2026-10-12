/* Synthetic executable buffers only. Exact accepted native prefixes, eight
 * arguments and instruction-boundary resumes; vendor code is unmodified. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
#include "../vendor/minhook/src/buffer.h"
#include "../vendor/minhook/src/trampoline.h"

typedef uint64_t (__fastcall *FixtureFn)(uint64_t,uint64_t,uint64_t,uint64_t,
                                       uint64_t,uint64_t,uint64_t,uint64_t);
static FixtureFn original_function;
static unsigned checks;
static RUNTIME_FUNCTION unwind_tables[2][2];
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"FAIL line%d: %s\n",__LINE__,#x); return 1; } } while(0)
static __declspec(noinline) uint64_t __fastcall forward(uint64_t a,uint64_t b,uint64_t c,uint64_t d,
                                                      uint64_t e,uint64_t f,uint64_t g,uint64_t h) {
    return original_function(a,b,c,d,e,f,g,h);
}
static uint64_t qword(const unsigned char *p) { uint64_t v;memcpy(&v,p,8);return v; }
static void abs_jump(unsigned char *p,uintptr_t to) {
    static const unsigned char prefix[]={0xff,0x25,0,0,0,0};
    memcpy(p,prefix,6);memcpy(p+6,&to,8);
}
static int jump_matches(const unsigned char *p,uintptr_t to) {
    const unsigned char prefix[]={0xff,0x25,0,0,0,0};
    return !memcmp(p,prefix,6)&&qword(p+6)==to;
}
static uint64_t expected(const uint64_t v[8],int connect) {
    return connect&&!v[1]?0x77:v[0]^v[1]^v[2]^v[3]^v[4]^v[5]^v[6]^v[7];
}
static int unwind_fixture(unsigned char *tramp,int connect) {
    RUNTIME_FUNCTION *f=unwind_tables[connect?0:1];
    memset(f,0,sizeof(unwind_tables[0]));
    if(connect){
        const unsigned char info[4]={1,0,0,0};memcpy(tramp+48,info,4);
        f[0].BeginAddress=0;f[0].EndAddress=47;f[0].UnwindData=48;
    }else{
        /* Version 2 has no listed epilogues: the jump back retains the
           original stack allocation and must not be classified as an exit. */
        const unsigned char info[12]={2,9,3,0,9,1,44,0,2,0xe0,0,0};
        const unsigned char leaf[4]={1,0,0,0};
        memcpy(tramp+40,info,12);memcpy(tramp+52,leaf,4);
        f[0].BeginAddress=0;f[0].EndAddress=23;f[0].UnwindData=40;
        f[1].BeginAddress=23;f[1].EndAddress=37;f[1].UnwindData=52;
    }
    CHECK(RtlAddFunctionTable(f,connect?1:2,(DWORD64)(uintptr_t)tramp));
    /* Independently construct machine state at each relocated instruction
       boundary, plus the relay entered before any original stack prologue. */
    const unsigned pc_connect[]={0,3,19,33,46};
    const unsigned pc_finder[]={0,2,9,15,22,23,36};
    const unsigned *pcs=connect?pc_connect:pc_finder;
    unsigned n=connect?5:7;
    for(unsigned i=0;i<n;i++){
        DECLSPEC_ALIGN(16) uint64_t stack[96]={0};
        uint64_t *entry=stack+64;
        const uint64_t caller=UINT64_C(0x12345000),saved=UINT64_C(0xabcdef0123456789),live=UINT64_C(0x9999888877776666);
        entry[0]=caller;entry[-1]=saved;
        unsigned pc=pcs[i];CONTEXT c;memset(&c,0,sizeof(c));c.ContextFlags=CONTEXT_FULL;
        c.Rip=(uintptr_t)tramp+pc;c.Rsp=(uintptr_t)entry;c.R14=live;
        int pushed=!connect&&pc>=2&&pc<23;
        if(pushed)c.Rsp-=8;
        if(!connect&&pc>=9&&pc<23)c.Rsp-=0x160;
        DWORD64 image=0;PRUNTIME_FUNCTION got=RtlLookupFunctionEntry(c.Rip,&image,NULL);
        CHECK(got==f+(!connect&&pc>=23?1:0));CHECK(image==(uintptr_t)tramp);
        PVOID data=NULL;DWORD64 establisher=0;
        RtlVirtualUnwind(UNW_FLAG_NHANDLER,image,c.Rip,got,&c,&data,&establisher,NULL);
        if(c.Rip!=caller)fprintf(stderr,"unwind connect=%d pc=%u gotRip=%llx wanted=%llx rsp=%llx wantedRsp=%llx r14=%llx\n",connect,pc,(unsigned long long)c.Rip,(unsigned long long)caller,(unsigned long long)c.Rsp,(unsigned long long)(uintptr_t)(entry+1),(unsigned long long)c.R14);
        CHECK(c.Rip==caller);CHECK(c.Rsp==(uintptr_t)(entry+1));CHECK(c.R14==(pushed?saved:live));
    }
    /* The registered tables and synthetic code remain resident until exit. */
    return 0;
}
static int one(int connect) {
    const unsigned char connect_prefix[]={0x48,0x85,0xd2,0x0f,0x84,0xd8,0x04,0,0};
    const unsigned char finder_prefix[]={0x41,0x56,0x48,0x81,0xec,0x60,0x01,0,0};
    const unsigned char reg_body[]={0x48,0x89,0xc8,0x48,0x31,0xd0,0x4c,0x31,0xc0,0x4c,0x31,0xc8};
    const unsigned char connect_stack[]={0x48,0x33,0x44,0x24,0x28,0x48,0x33,0x44,0x24,0x30,
        0x48,0x33,0x44,0x24,0x38,0x48,0x33,0x44,0x24,0x40,0xc3};
    const unsigned char finder_stack[]={0x48,0x33,0x84,0x24,0x90,0x01,0,0,
        0x48,0x33,0x84,0x24,0x98,0x01,0,0,0x48,0x33,0x84,0x24,0xa0,0x01,0,0,
        0x48,0x33,0x84,0x24,0xa8,0x01,0,0,0x48,0x81,0xc4,0x60,0x01,0,0,0x41,0x5e,0xc3};
    unsigned char *target=VirtualAlloc(NULL,4096,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);
    CHECK(target!=NULL);memset(target,0xcc,4096);
    memcpy(target,connect?connect_prefix:finder_prefix,9);
    memcpy(target+9,reg_body,sizeof(reg_body));
    memcpy(target+9+sizeof(reg_body),connect?connect_stack:finder_stack,
           connect?sizeof(connect_stack):sizeof(finder_stack));
    if(connect){const unsigned char empty[]={0xb8,0x77,0,0,0,0xc3};memcpy(target+0x4e1,empty,sizeof(empty));}
    CHECK(FlushInstructionCache(GetCurrentProcess(),target,4096));
    TRAMPOLINE t={0};t.pTarget=target;t.pDetour=(void*)&forward;t.pTrampoline=AllocateBuffer(target);
    CHECK(t.pTrampoline!=NULL);CHECK(CreateTrampolineFunction(&t));CHECK(!t.patchAbove);
    unsigned char *tramp=t.pTrampoline;
    CHECK(t.nIP==3&&t.oldIPs[0]==0&&t.newIPs[0]==0&&t.oldIPs[2]==9);
    if(connect){
        CHECK(t.oldIPs[1]==3&&t.newIPs[1]==3&&t.newIPs[2]==19);
        CHECK(!memcmp(tramp,connect_prefix,3)&&tramp[3]==0x75&&tramp[4]==0x0e);
        CHECK(jump_matches(tramp+5,(uintptr_t)target+0x4e1));
        CHECK(jump_matches(tramp+19,(uintptr_t)target+9));
        CHECK(t.pRelay==tramp+33);
    }else{
        CHECK(t.oldIPs[1]==2&&t.newIPs[1]==2&&t.newIPs[2]==9);
        CHECK(!memcmp(tramp,finder_prefix,9));
        CHECK(jump_matches(tramp+9,(uintptr_t)target+9));
        CHECK(t.pRelay==tramp+23);
    }
    CHECK(jump_matches(t.pRelay,(uintptr_t)&forward));
    if(unwind_fixture(tramp,connect))return 1;
    CHECK(FlushInstructionCache(GetCurrentProcess(),tramp,MEMORY_SLOT_SIZE));
    FixtureFn stock=(FixtureFn)target,relocated=(FixtureFn)tramp;
    uint64_t values[][8]={{1,2,3,255,UINT64_C(0x123456789abcdef0),UINT64_C(0xfedcba9876543210),777,888},
        {UINT64_MAX,0,1,0,UINT64_C(0xfeed0123),UINT64_C(0xabcdef00),UINT64_MAX,12},
        {UINT64_C(0xf00),UINT64_C(0x123),0,255,0x12345678,0x87654321,17,19}};
    for(unsigned i=0;i<3;i++){
        uint64_t *v=values[i],want=expected(v,connect);
        CHECK(stock(v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7])==want);
        CHECK(relocated(v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7])==want);
    }
    /* Resume at the second displaced instruction after the first instruction
       has executed: preserve flags for JZ, and the existing R14 stack push. */
    unsigned char *boundary=target+0x600;
    unsigned prefix=connect?3:2;
    memcpy(boundary,connect?connect_prefix:finder_prefix,prefix);
    abs_jump(boundary+prefix,(uintptr_t)tramp+prefix);
    CHECK(FlushInstructionCache(GetCurrentProcess(),boundary,14+prefix));
    FixtureFn resumed=(FixtureFn)boundary;
    for(unsigned i=0;i<3;i++){
        uint64_t *v=values[i];
        CHECK(resumed(v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7])==expected(v,connect));
    }
    intptr_t delta=(intptr_t)t.pRelay-((intptr_t)target+5);
    CHECK(delta>=INT32_MIN&&delta<=INT32_MAX);
    unsigned char patch[5]={0xe9};int32_t rel=(int32_t)delta;memcpy(patch+1,&rel,4);
    original_function=relocated;memcpy(target,patch,5);
    CHECK(FlushInstructionCache(GetCurrentProcess(),target,5));
    for(unsigned i=0;i<3;i++){
        uint64_t *v=values[i];
        CHECK(stock(v[0],v[1],v[2],v[3],v[4],v[5],v[6],v[7])==expected(v,connect));
    }
    /* Published relay/storage intentionally lives until fixture process exit. */
    return 0;
}
int main(void) {
    InitializeBuffer();
    if(one(1)||one(0))return 1;
    printf("{\"passed\":true,\"checks\":%u,\"game_executed\":false,\"eight_arguments\":true,\"boundary_resumes\":true,\"virtual_unwind\":true}\n",checks);
    return 0;
}
