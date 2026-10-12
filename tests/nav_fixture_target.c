/* Synthetic separate process; no game images/settings are opened. */
#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <limits.h>
#include "nav_fixture_contract.h"
#include "../vendor/minhook/src/trampoline.h"
#include "../vendor/minhook/src/buffer.h"
typedef uint64_t (__fastcall *F8)(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t);
static NavFixtureShared *s;
static F8 f[NAV_INSTALL_HOOKS],t[NAV_INSTALL_HOOKS];
static RUNTIME_FUNCTION unwind_tables[NAV_INSTALL_HOOKS][2];
static void check(int ok){if(!ok)InterlockedIncrement((LONG*)&s->errors);}
static uint64_t body(unsigned i,uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,uint64_t g,uint64_t h,uint64_t j){
    check(a==0x11&&b==0x22&&c==0x33&&d==0x44&&e==UINT64_C(0x123456789abcdef0)&&g==UINT64_C(0xfedcba9876543210)&&h==0x77&&j==0x88&&GetLastError()==0x88);
    InterlockedIncrement((LONG*)&s->body_calls[i]);SetLastError(0x90+i);return a^b^c^d^e^g^h^j;
}
static uint64_t __fastcall body0(uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,uint64_t g,uint64_t h,uint64_t j){return body(0,a,b,c,d,e,g,h,j);}
static uint64_t __fastcall body2(uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,uint64_t g,uint64_t h,uint64_t j){return body(2,a,b,c,d,e,g,h,j);}
static uint64_t __fastcall body1(uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,uint64_t g,uint64_t h,uint64_t j){return body(1,a,b,c,d,e,g,h,j);}
static uint64_t wrap(unsigned i,uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,uint64_t g,uint64_t h,uint64_t j){
    DWORD before=GetLastError();InterlockedIncrement((LONG*)&s->wrapper_calls[i]);SetLastError(before);
    uint64_t r=t[i](a,b,c,d,e,g,h,j);DWORD after=GetLastError();SetLastError(0xbad);SetLastError(after);return r;
}
static uint64_t __fastcall wrap0(uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,uint64_t g,uint64_t h,uint64_t j){return wrap(0,a,b,c,d,e,g,h,j);}
static uint64_t __fastcall wrap1(uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,uint64_t g,uint64_t h,uint64_t j){return wrap(1,a,b,c,d,e,g,h,j);}
static uint64_t __fastcall wrap2(uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,uint64_t g,uint64_t h,uint64_t j){return wrap(2,a,b,c,d,e,g,h,j);}
static void jump(uint8_t*b,uint64_t a){b[0]=0xff;b[1]=0x25;memset(b+2,0,4);memcpy(b+6,&a,8);}
static DWORD WINAPI worker(void*u){(void)u;const uint64_t a[8]={0x11,0x22,0x33,0x44,UINT64_C(0x123456789abcdef0),UINT64_C(0xfedcba9876543210),0x77,0x88};
    uint64_t want=0;for(unsigned i=0;i<8;i++)want^=a[i];
    while(!s->stop){
        for(unsigned i=0;i<NAV_INSTALL_HOOKS;i++){SetLastError(0x88);check(f[i](a[0],a[1],a[2],a[3],a[4],a[5],a[6],a[7])==want);check(GetLastError()==0x90+i);}
        SetLastError(0x88);check(f[0](a[0],0,a[2],a[3],a[4],a[5],a[6],a[7])==0x77);check(GetLastError()==0x88);
        InterlockedIncrement((LONG*)&s->heartbeat);Sleep(1);
    }return 0;
}
int wmain(int argc,wchar_t**argv){
    if(argc!=2)return 2;HANDLE m=OpenFileMappingW(FILE_MAP_ALL_ACCESS,FALSE,argv[1]);if(!m)return 3;
    s=MapViewOfFile(m,FILE_MAP_ALL_ACCESS,0,0,sizeof(*s));if(!s)return 4;
    uint8_t *code=VirtualAlloc(NULL,8192,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);if(!code)return 5;
    uint8_t *targets[NAV_INSTALL_HOOKS]={code+0x100,code+0x900,code+0x1100};
    uint64_t detours[NAV_INSTALL_HOOKS]={(uintptr_t)wrap0,(uintptr_t)wrap1,(uintptr_t)wrap2};memset(code,0xcc,8192);
    const uint8_t connect[9]={0x48,0x85,0xd2,0x0f,0x84,0xd8,0x04,0,0};
    const uint8_t finder[9]={0x41,0x56,0x48,0x81,0xec,0x60,0x01,0,0};
    memcpy(targets[0],connect,9);jump(targets[0]+9,(uintptr_t)body0);
    const uint8_t empty[]={0xb8,0x77,0,0,0,0xc3};memcpy(targets[0]+0x4e1,empty,sizeof(empty));
    memcpy(targets[1],finder,9);
    /* Restore the synthetic copied stack prologue before the C ABI body. */
    const uint8_t restore[]={0x48,0x81,0xc4,0x60,0x01,0,0,0x41,0x5e};
    memcpy(targets[1]+9,restore,sizeof(restore));jump(targets[1]+18,(uintptr_t)body1);
    const uint8_t loading[]={0x48,0x8b,0xc4,0x48,0x89,0x58,0x10};
    memcpy(targets[2],loading,7);jump(targets[2]+7,(uintptr_t)body2);
    InitializeBuffer();
    for(unsigned i=0;i<NAV_INSTALL_HOOKS;i++){
        TRAMPOLINE ct;memset(&ct,0,sizeof(ct));ct.pTarget=targets[i];ct.pDetour=(void*)(uintptr_t)detours[i];ct.pTrampoline=AllocateBuffer(targets[i]);
        if(!ct.pTrampoline||!CreateTrampolineFunction(&ct)||ct.patchAbove)return 6;
        NavInstallPlan *h=&s->install.plans[i];h->target=(uintptr_t)targets[i];h->trampoline=(uintptr_t)ct.pTrampoline;h->relay=(uintptr_t)ct.pRelay;h->detour=detours[i];
        h->guard_length=64;h->n_ip=ct.nIP;h->stolen_length=i==2?7:9;
        memcpy(h->old_ip,ct.oldIPs,ct.nIP);memcpy(h->new_ip,ct.newIPs,ct.nIP);memcpy(h->guard,targets[i],h->guard_length);memcpy(h->original5,targets[i],5);
        h->patch5[0]=0xe9;int64_t delta=(int64_t)h->relay-(int64_t)(h->target+5);if(delta<INT32_MIN||delta>INT32_MAX)return 7;int32_t rel=(int32_t)delta;memcpy(h->patch5+1,&rel,4);
        t[i]=(F8)(uintptr_t)h->trampoline;f[i]=(F8)targets[i];
        RUNTIME_FUNCTION *rf=unwind_tables[i];uint8_t *tr=ct.pTrampoline;
        if(i==1){const uint8_t info[12]={2,9,3,0,9,1,44,0,2,0xe0,0,0},leaf[4]={1,0,0,0};
            memcpy(tr+40,info,12);memcpy(tr+52,leaf,4);rf[0]=(RUNTIME_FUNCTION){0,23,40};rf[1]=(RUNTIME_FUNCTION){23,37,52};
        }else if(i==0){const uint8_t leaf[4]={1,0,0,0};memcpy(tr+48,leaf,4);rf[0]=(RUNTIME_FUNCTION){0,47,48};}
        else{const uint8_t info[8]={2,7,2,0,7,0x34,2,0},leaf[4]={1,0,0,0};memcpy(tr+40,info,8);memcpy(tr+48,leaf,4);rf[0]=(RUNTIME_FUNCTION){0,21,40};rf[1]=(RUNTIME_FUNCTION){21,35,48};}
        if(!RtlAddFunctionTable(rf,i==0?1:2,(DWORD64)(uintptr_t)tr))return 8;
    }
    DWORD old;if(!VirtualProtect(code,8192,PAGE_EXECUTE_READ,&old)||!FlushInstructionCache(GetCurrentProcess(),code,8192))return 9;
    HANDLE threads[4];for(unsigned i=0;i<4;i++){threads[i]=CreateThread(NULL,0,worker,NULL,0,NULL);if(!threads[i])return 10;}
    s->install.magic=NAV_INSTALL_MAGIC;s->install.version=NAV_INSTALL_VERSION;s->install.hook_count=NAV_INSTALL_HOOKS;s->install.byte_size=sizeof(s->install);s->install.pid=GetCurrentProcessId();InterlockedExchange((LONG*)&s->install.ready,1);
    while(!s->stop)Sleep(5);
    WaitForMultipleObjects(4,threads,TRUE,5000);for(unsigned i=0;i<4;i++)CloseHandle(threads[i]);
    int result=s->errors?11:0;UnmapViewOfFile(s);CloseHandle(m);return result;
}
