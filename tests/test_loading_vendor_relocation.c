/* Synthetic executable memory and current-process reads only; no game code. */
#define wmain loading_unused_production_entry
#include "../src/nav_install_external.c"
#undef wmain
#include "../vendor/minhook/src/buffer.h"
#include "../vendor/minhook/src/trampoline.h"

typedef uint64_t (__fastcall *F6)(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t);
static F6 loading_original;
static RUNTIME_FUNCTION loading_unwind[2];
static unsigned checks;
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"failed line%d: %s\n",__LINE__,#x);return 1;}}while(0)
static __declspec(noinline) uint64_t __fastcall loading_forward(uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,uint64_t f){return loading_original(a,b,c,d,e,f);}
static int unwind_checks(unsigned char *tramp){
    const unsigned char info[8]={2,7,2,0,7,0x34,2,0},leaf[4]={1,0,0,0};
    memcpy(tramp+40,info,8);memcpy(tramp+48,leaf,4);
    loading_unwind[0]=(RUNTIME_FUNCTION){0,21,40};loading_unwind[1]=(RUNTIME_FUNCTION){21,35,48};
    CHECK(RtlAddFunctionTable(loading_unwind,2,(uintptr_t)tramp));
    const unsigned pcs[]={0,3,7,13,20,21,34};
    for(unsigned i=0;i<sizeof(pcs)/sizeof(pcs[0]);i++){
        DECLSPEC_ALIGN(16) uint64_t stack[96]={0};uint64_t *entry=stack+64;
        const uint64_t caller=UINT64_C(0x12345000),saved=UINT64_C(0xabcdef0123456789),live=UINT64_C(0x9876543210abcdef);
        entry[0]=caller;entry[2]=saved;
        CONTEXT c;memset(&c,0,sizeof(c));c.ContextFlags=CONTEXT_FULL;c.Rip=(uintptr_t)tramp+pcs[i];c.Rsp=(uintptr_t)entry;c.Rbx=live;
        DWORD64 base=0;PRUNTIME_FUNCTION f=RtlLookupFunctionEntry(c.Rip,&base,NULL);
        CHECK(f==loading_unwind+(pcs[i]>=21?1:0));CHECK(base==(uintptr_t)tramp);
        PVOID handler=NULL;DWORD64 establisher=0;
        RtlVirtualUnwind(UNW_FLAG_NHANDLER,base,c.Rip,f,&c,&handler,&establisher,NULL);
        CHECK(c.Rip==caller);CHECK(c.Rsp==(uintptr_t)(entry+1));
        CHECK(c.Rbx==(pcs[i]>=7&&pcs[i]<21?saved:live));
    }
    return 0;
}
int main(void){
    unsigned char *target=VirtualAlloc(NULL,4096,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);
    CHECK(target!=NULL);memset(target,0xcc,4096);memcpy(target,LOADING_WRAPPER_SIGNATURE,7);
    const unsigned char body[]={0x48,0x89,0xc8,0x48,0x31,0xd0,0x4c,0x31,0xc0,0x4c,0x31,0xc8,
        0x48,0x33,0x44,0x24,0x28,0x48,0x33,0x44,0x24,0x30,0xc3};
    memcpy(target+7,body,sizeof(body));InitializeBuffer();
    TRAMPOLINE ct={0};ct.pTarget=target;ct.pDetour=(void*)&loading_forward;ct.pTrampoline=AllocateBuffer(target);
    CHECK(ct.pTrampoline!=NULL);CHECK(CreateTrampolineFunction(&ct));CHECK(!ct.patchAbove);
    CHECK(ct.nIP==3&&ct.oldIPs[0]==0&&ct.oldIPs[1]==3&&ct.oldIPs[2]==7&&ct.newIPs[0]==0&&ct.newIPs[1]==3&&ct.newIPs[2]==7);
    CHECK(ct.pRelay==(unsigned char*)ct.pTrampoline+21);
    if(unwind_checks(ct.pTrampoline))return 1;
    CHECK(FlushInstructionCache(GetCurrentProcess(),target,4096));CHECK(FlushInstructionCache(GetCurrentProcess(),ct.pTrampoline,MEMORY_SLOT_SIZE));
    NavInstallPlan h={0};h.target=(uintptr_t)target;h.trampoline=(uintptr_t)ct.pTrampoline;h.relay=(uintptr_t)ct.pRelay;h.detour=(uintptr_t)&loading_forward;
    h.stolen_length=7;h.n_ip=ct.nIP;memcpy(h.old_ip,ct.oldIPs,ct.nIP);memcpy(h.new_ip,ct.newIPs,ct.nIP);
    WinNI w={GetCurrentProcess(),GetCurrentProcessId()};plan.publisher_base=(uintptr_t)GetModuleHandleW(NULL);
    CHECK(validate_trampoline(&w,&h,2));
    h.stolen_length=9;CHECK(!validate_trampoline(&w,&h,2));h.stolen_length=7;
    h.old_ip[1]=2;CHECK(!validate_trampoline(&w,&h,2));h.old_ip[1]=3;
    h.new_ip[2]=9;CHECK(!validate_trampoline(&w,&h,2));h.new_ip[2]=7;
    h.relay++;CHECK(!validate_trampoline(&w,&h,2));h.relay--;
    h.old_ip[3]=1;CHECK(!validate_trampoline(&w,&h,2));h.old_ip[3]=0;
    unsigned char *tr=ct.pTrampoline;
    tr[7]^=1;CHECK(!validate_trampoline(&w,&h,2));tr[7]^=1;
    tr[40]^=1;CHECK(!validate_trampoline(&w,&h,2));tr[40]^=1;
    tr[48]^=1;CHECK(!validate_trampoline(&w,&h,2));tr[48]^=1;
    uint64_t detour=h.detour;h.detour=(uintptr_t)target;CHECK(!validate_trampoline(&w,&h,2));h.detour=detour;
    CHECK(validate_trampoline(&w,&h,2));
    /* Protocol rejection occurs before opening or hashing any game image. */
    NavInstallShared saved_plan=plan;unsigned char dummy[32]={0};
    memset(&plan,0,sizeof(plan));plan.magic=NAV_INSTALL_MAGIC;plan.version=1;plan.byte_size=sizeof(plan);plan.pid=w.pid;plan.hook_count=NAV_INSTALL_HOOKS;plan.ready=1;
    CHECK(!validate_plan(&w,L"unused",dummy));plan.version=NAV_INSTALL_VERSION;plan.hook_count=2;CHECK(!validate_plan(&w,L"unused",dummy));
    plan.hook_count=NAV_INSTALL_HOOKS;plan.byte_size=4416;CHECK(!validate_plan(&w,L"unused",dummy));plan=saved_plan;
    F6 stock=(F6)target,relocated=(F6)tr;loading_original=relocated;
    const uint64_t values[][6]={{1,2,UINT64_C(0xffffffff80000000),4,UINT64_C(0x123456789abcdef0),UINT64_C(0xfedcba9876543210)},
        {UINT64_MAX,0,0,0,UINT64_MAX,0},{0x11,0x22,0x33,0x44,0x55,0x66}};
    for(unsigned i=0;i<3;i++){const uint64_t *v=values[i];uint64_t want=v[0]^v[1]^v[2]^v[3]^v[4]^v[5];
        CHECK(stock(v[0],v[1],v[2],v[3],v[4],v[5])==want);CHECK(relocated(v[0],v[1],v[2],v[3],v[4],v[5])==want);}
    unsigned char *bridge=target+0x600;memcpy(bridge,LOADING_WRAPPER_SIGNATURE,3);abs_jump(bridge+3,(uintptr_t)tr+3);
    CHECK(FlushInstructionCache(GetCurrentProcess(),bridge,17));F6 resumed=(F6)bridge;
    for(unsigned i=0;i<3;i++){const uint64_t *v=values[i];CHECK(resumed(v[0],v[1],v[2],v[3],v[4],v[5])==(v[0]^v[1]^v[2]^v[3]^v[4]^v[5]));}
    int64_t delta=(int64_t)(uintptr_t)ct.pRelay-(int64_t)((uintptr_t)target+5);CHECK(delta>=INT32_MIN&&delta<=INT32_MAX);
    unsigned char patch[5]={0xe9};int32_t rel=(int32_t)delta;memcpy(patch+1,&rel,4);memcpy(target,patch,5);CHECK(FlushInstructionCache(GetCurrentProcess(),target,5));
    for(unsigned i=0;i<3;i++){const uint64_t *v=values[i];CHECK(stock(v[0],v[1],v[2],v[3],v[4],v[5])==(v[0]^v[1]^v[2]^v[3]^v[4]^v[5]));}
    printf("{\"passed\":true,\"checks\":%u,\"game_executed\":false,\"helper_shape_checks\":true,\"old_protocol_rejected\":true,\"copied_rbx_unwind\":true,\"six_arguments\":true}\n",checks);
    return 0;
}
