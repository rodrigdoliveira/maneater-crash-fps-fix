/* Independent synthetic third-trampoline geometry/unwind check only. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "../vendor/minhook/src/buffer.h"
#include "../vendor/minhook/src/trampoline.h"
static unsigned checks;
static RUNTIME_FUNCTION table[2];
#define CHECK(x) do{checks++;if(!(x)){fprintf(stderr,"FAIL line%d %s\n",__LINE__,#x);return 1;}}while(0)
static uintptr_t __fastcall unused_detour(void*a,void*b,uint32_t c,void*d,void*e){(void)a;(void)b;(void)c;(void)d;(void)e;return 0;}
static int absolute_jump(const unsigned char*p,uintptr_t target){uintptr_t to=0;memcpy(&to,p+6,8);return p[0]==0xff&&p[1]==0x25&&!p[2]&&!p[3]&&!p[4]&&!p[5]&&to==target;}
int main(void){
    const unsigned char original[7]={0x48,0x8b,0xc4,0x48,0x89,0x58,0x10};
    const unsigned char info[8]={2,7,2,0,7,0x34,2,0},leaf[4]={1,0,0,0};
    unsigned char *target=VirtualAlloc(NULL,4096,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);CHECK(target!=NULL);memset(target,0xcc,4096);memcpy(target,original,7);target[7]=0x31;target[8]=0xc0;target[9]=0xc3;
    InitializeBuffer();TRAMPOLINE t={0};t.pTarget=target;t.pTrampoline=AllocateBuffer(target);t.pDetour=(void*)&unused_detour;
    CHECK(t.pTrampoline!=NULL);CHECK(CreateTrampolineFunction(&t));CHECK(!t.patchAbove);
    unsigned char *tr=t.pTrampoline;
    CHECK(t.nIP==3&&t.oldIPs[0]==0&&t.oldIPs[1]==3&&t.oldIPs[2]==7&&t.newIPs[0]==0&&t.newIPs[1]==3&&t.newIPs[2]==7);
    CHECK(!memcmp(tr,original,7));CHECK(absolute_jump(tr+7,(uintptr_t)target+7));CHECK(t.pRelay==tr+21);CHECK(absolute_jump(tr+21,(uintptr_t)&unused_detour));
    memcpy(tr+40,info,8);memcpy(tr+48,leaf,4);table[0]=(RUNTIME_FUNCTION){0,21,40};table[1]=(RUNTIME_FUNCTION){21,35,48};
    CHECK(RtlAddFunctionTable(table,2,(DWORD64)(uintptr_t)tr));
    const unsigned pcs[]={0,3,7,13,20,21,34};
    for(unsigned i=0;i<sizeof(pcs)/sizeof(pcs[0]);i++){
        DECLSPEC_ALIGN(16) DWORD64 stack[16]={0};DWORD64 *entry=stack+4;entry[0]=0x1122334455;entry[2]=0xaabbccdd;
        CONTEXT c;memset(&c,0,sizeof(c));c.ContextFlags=CONTEXT_FULL;c.Rip=(uintptr_t)tr+pcs[i];c.Rsp=(uintptr_t)entry;c.Rbx=0x99887766;
        DWORD64 image=0;PRUNTIME_FUNCTION found=RtlLookupFunctionEntry(c.Rip,&image,NULL);CHECK(found==table+(pcs[i]>=21));CHECK(image==(uintptr_t)tr);
        PVOID handler=NULL;DWORD64 frame=0;RtlVirtualUnwind(0,image,c.Rip,found,&c,&handler,&frame,NULL);
        CHECK(c.Rip==entry[0]);CHECK(c.Rsp==(uintptr_t)(entry+1));CHECK(c.Rbx==((pcs[i]>=7&&pcs[i]<21)?entry[2]:UINT64_C(0x99887766)));
    }
    printf("{\"Passed\":true,\"Checks\":%u,\"ThirdTrampolineCodeBytes\":35,\"VirtualUnwindOffsets\":[0,3,7,13,20,21,34],\"GameExecuted\":false}\n",checks);
    return 0;
}
