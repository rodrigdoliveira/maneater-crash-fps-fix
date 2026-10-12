/* Private external installer. Exact-build two navigation and one loading entry hooks.
   This executable is never loaded into the game. No game files are changed. */
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0a00
#endif
#include "nav_install_core.h"
#include "nav_signatures.h"
#include "loading_signatures.h"
#include <tlhelp32.h>
#include <bcrypt.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include <inttypes.h>

#define NI_GAME_SHA "CC34E43BBD1F757E3883ADAF37D643C1A0FB2963967CA33AF7CB6CB8F54480C0"
typedef struct WinNI { HANDLE process; DWORD pid; } WinNI;
static NIWorkspace workspace;
static NavInstallShared plan;
static unsigned char scratch[NAV_INSTALL_MAX_GUARD];
static const unsigned char *const guards[NAV_INSTALL_HOOKS]={area_nav_connect_guard,area_nav_finder_guard,LOADING_WRAPPER_SIGNATURE};
static const uint32_t lengths[NAV_INSTALL_HOOKS]={sizeof(area_nav_connect_guard),sizeof(area_nav_finder_guard),LOADING_WRAPPER_SIZE};
static const uint32_t rvas[NAV_INSTALL_HOOKS]={AREA_NAV_CONNECT_RVA,AREA_NAV_FINDER_RVA,LOADING_WRAPPER_RVA};
static uint64_t ft64(FILETIME f){return ((uint64_t)f.dwHighDateTime<<32)|f.dwLowDateTime;}
static DWORD win_last(void *u){(void)u;return GetLastError();}
static DWORD win_suspend(void *u,HANDLE h){(void)u;return SuspendThread(h);}
static DWORD win_resume(void *u,HANDLE h){(void)u;return ResumeThread(h);}
static BOOL win_get(void *u,HANDLE h,CONTEXT *c){(void)u;return GetThreadContext(h,c);}
static BOOL win_set(void *u,HANDLE h,const CONTEXT *c){(void)u;return SetThreadContext(h,c);}
static BOOL win_read(void *u,uint64_t a,void *b,SIZE_T n){SIZE_T got=0;return ReadProcessMemory(((WinNI*)u)->process,(void*)(uintptr_t)a,b,n,&got)&&got==n;}
static BOOL win_write(void *u,uint64_t a,const void *b,SIZE_T n){SIZE_T put=0;return WriteProcessMemory(((WinNI*)u)->process,(void*)(uintptr_t)a,b,n,&put)&&put==n;}
static BOOL win_protect(void *u,uint64_t a,SIZE_T n,DWORD prot,DWORD *old){return VirtualProtectEx(((WinNI*)u)->process,(void*)(uintptr_t)a,n,prot,old);}
static BOOL win_flush(void *u,uint64_t a,SIZE_T n){return FlushInstructionCache(((WinNI*)u)->process,(void*)(uintptr_t)a,n);}
static BOOL win_census(void *u,DWORD *ids,unsigned cap,unsigned *count){
    HANDLE s=CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD,0);
    THREADENTRY32 te;BOOL ok=FALSE;*count=0;
    if(s==INVALID_HANDLE_VALUE)return FALSE;
    memset(&te,0,sizeof(te));te.dwSize=sizeof(te);
    if(Thread32First(s,&te)){
        ok=TRUE;
        do{
            if(te.dwSize>=offsetof(THREADENTRY32,th32OwnerProcessID)+sizeof(DWORD)&&te.th32OwnerProcessID==((WinNI*)u)->pid){
                if(*count==cap){SetLastError(ERROR_BUFFER_OVERFLOW);ok=FALSE;break;}
                ids[(*count)++]=te.th32ThreadID;
            }
            te.dwSize=sizeof(te);
        }while(Thread32Next(s,&te));
        if(ok&&GetLastError()!=ERROR_NO_MORE_FILES)ok=FALSE;
    }
    DWORD e=GetLastError();CloseHandle(s);SetLastError(e);return ok;
}
static const NIOps ops={win_suspend,win_resume,win_get,win_set,win_read,win_write,win_protect,win_flush,win_census,win_last};
static int hexval(wchar_t c){if(c>=L'0'&&c<=L'9')return c-L'0';if(c>=L'a'&&c<=L'f')return c-L'a'+10;if(c>=L'A'&&c<=L'F')return c-L'A'+10;return -1;}
static int parse_hex(const wchar_t *s,unsigned char *out,unsigned n){
    if(wcslen(s)!=n*2)return 0;
    for(unsigned i=0;i<n;i++){int a=hexval(s[i*2]),b=hexval(s[i*2+1]);if(a<0||b<0)return 0;out[i]=(unsigned char)((a<<4)|b);}return 1;
}
static int image_hash(const wchar_t *path,unsigned char out[32]){
    HANDLE f=INVALID_HANDLE_VALUE;BCRYPT_ALG_HANDLE alg=NULL;BCRYPT_HASH_HANDLE h=NULL;
    unsigned char *object=NULL,*buf=NULL;DWORD size=0,used=0,n=0;int ok=0;
    f=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_SEQUENTIAL_SCAN,NULL);
    if(f==INVALID_HANDLE_VALUE||BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,NULL,0)<0||
       BCryptGetProperty(alg,BCRYPT_OBJECT_LENGTH,(PUCHAR)&size,sizeof(size),&used,0)<0||!size)goto done;
    object=VirtualAlloc(NULL,size,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);buf=VirtualAlloc(NULL,1048576,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    if(!object||!buf||BCryptCreateHash(alg,&h,object,size,NULL,0,0)<0)goto done;
    for(;;){if(!ReadFile(f,buf,1048576,&n,NULL))goto done;if(!n)break;if(BCryptHashData(h,buf,n,0)<0)goto done;}
    if(BCryptFinishHash(h,out,32,0)<0)goto done;ok=1;
done:
    if(h)BCryptDestroyHash(h);if(alg)BCryptCloseAlgorithmProvider(alg,0);
    if(object)VirtualFree(object,0,MEM_RELEASE);if(buf)VirtualFree(buf,0,MEM_RELEASE);if(f!=INVALID_HANDLE_VALUE)CloseHandle(f);return ok;
}
static int readable(DWORD p){p&=0xff;return p==PAGE_READONLY||p==PAGE_READWRITE||p==PAGE_WRITECOPY||p==PAGE_EXECUTE_READ||p==PAGE_EXECUTE_READWRITE||p==PAGE_EXECUTE_WRITECOPY;}
static int executable(DWORD p){p&=0xff;return p==PAGE_EXECUTE_READ||p==PAGE_EXECUTE_READWRITE||p==PAGE_EXECUTE_WRITECOPY;}
static int region(WinNI *w,uint64_t a,SIZE_T n,DWORD type,uint64_t allocation,int exec){
    uint64_t end=a+n;if(end<a)return 0;
    while(a<end){MEMORY_BASIC_INFORMATION m;
        if(VirtualQueryEx(w->process,(void*)(uintptr_t)a,&m,sizeof(m))!=sizeof(m)||m.State!=MEM_COMMIT||m.Type!=type||
           (m.Protect&PAGE_GUARD)||!readable(m.Protect)||(exec&&!executable(m.Protect))||
           (allocation&&(uint64_t)(uintptr_t)m.AllocationBase!=allocation))return 0;
        uint64_t next=(uint64_t)(uintptr_t)m.BaseAddress+m.RegionSize;if(next<=a)return 0;a=next<end?next:end;
    }return 1;
}
static int module_path(DWORD pid,uint64_t base,wchar_t *path,DWORD *size){
    HANDLE s=CreateToolhelp32Snapshot(TH32CS_SNAPMODULE|TH32CS_SNAPMODULE32,pid);MODULEENTRY32W m;int found=0;
    if(s==INVALID_HANDLE_VALUE)return 0;memset(&m,0,sizeof(m));m.dwSize=sizeof(m);
    if(Module32FirstW(s,&m))do{if((uint64_t)(uintptr_t)m.modBaseAddr==base){wcscpy(path,m.szExePath);*size=m.modBaseSize;found=1;break;}}while(Module32NextW(s,&m));CloseHandle(s);return found;
}
static int image_pe(WinNI *w,uint64_t base,uint32_t size,uint32_t stamp){
    IMAGE_DOS_HEADER d;IMAGE_NT_HEADERS64 n;
    if(!region(w,base,sizeof(d),MEM_IMAGE,base,0)||!win_read(w,base,&d,sizeof(d))||d.e_magic!=IMAGE_DOS_SIGNATURE||d.e_lfanew<(LONG)sizeof(d)||d.e_lfanew>4096)return 0;
    if(!win_read(w,base+(uint32_t)d.e_lfanew,&n,sizeof(n))||n.Signature!=IMAGE_NT_SIGNATURE||n.FileHeader.Machine!=IMAGE_FILE_MACHINE_AMD64||
       n.OptionalHeader.Magic!=IMAGE_NT_OPTIONAL_HDR64_MAGIC||n.OptionalHeader.SizeOfImage!=size||n.FileHeader.TimeDateStamp!=stamp||
       n.FileHeader.NumberOfSections==0||n.FileHeader.NumberOfSections>96)return 0;
    return 1;
}
static int native_code_section(WinNI *w,uint64_t base,uint64_t a,unsigned length){
    IMAGE_DOS_HEADER d;IMAGE_NT_HEADERS64 n;IMAGE_SECTION_HEADER sections[96];
    if(!win_read(w,base,&d,sizeof(d))||!win_read(w,base+d.e_lfanew,&n,sizeof(n))||n.FileHeader.NumberOfSections>96)return 0;
    uint64_t st=base+d.e_lfanew+offsetof(IMAGE_NT_HEADERS64,OptionalHeader)+n.FileHeader.SizeOfOptionalHeader;
    if(!win_read(w,st,sections,n.FileHeader.NumberOfSections*sizeof(sections[0])))return 0;
    for(unsigned i=0;i<n.FileHeader.NumberOfSections;i++){
        IMAGE_SECTION_HEADER *s=&sections[i];uint64_t start=base+s->VirtualAddress,end=start+s->Misc.VirtualSize;
        if(a>=start&&a+length<=end&&(s->Characteristics&IMAGE_SCN_MEM_EXECUTE)&&(s->Characteristics&IMAGE_SCN_CNT_CODE))return 1;
    }return 0;
}
static void abs_jump(unsigned char *b,uint64_t target){b[0]=0xff;b[1]=0x25;memset(b+2,0,4);memcpy(b+6,&target,8);}
static int validate_trampoline(WinNI *w,const NavInstallPlan *h,unsigned index){
    unsigned char expected[64]={0},actual[64];unsigned total;
    if(index==0){
        if(h->stolen_length!=9||h->n_ip!=3||h->old_ip[0]!=0||h->old_ip[1]!=3||h->old_ip[2]!=9||
           h->new_ip[0]!=0||h->new_ip[1]!=3||h->new_ip[2]!=19||h->relay!=h->trampoline+33)return 0;
        memcpy(expected,guards[index],3);expected[3]=0x75;expected[4]=0x0e;
        abs_jump(expected+5,h->target+0x4e1);abs_jump(expected+19,h->target+9);abs_jump(expected+33,h->detour);total=47;
    }else if(index==1){
        if(h->stolen_length!=9||h->n_ip!=3||h->old_ip[0]!=0||h->old_ip[1]!=2||h->old_ip[2]!=9||
           h->new_ip[0]!=0||h->new_ip[1]!=2||h->new_ip[2]!=9||h->relay!=h->trampoline+23)return 0;
        memcpy(expected,guards[index],9);abs_jump(expected+9,h->target+9);abs_jump(expected+23,h->detour);total=37;
    }else if(index==2){
        if(h->stolen_length!=7||h->n_ip!=3||h->old_ip[0]!=0||h->old_ip[1]!=3||h->old_ip[2]!=7||
           h->new_ip[0]!=0||h->new_ip[1]!=3||h->new_ip[2]!=7||h->relay!=h->trampoline+21)return 0;
        memcpy(expected,guards[index],7);abs_jump(expected+7,h->target+7);abs_jump(expected+21,h->detour);total=35;
    }else{
        return 0;
    }
    for(unsigned n=h->n_ip;n<NAV_INSTALL_MAX_IPS;n++)if(h->old_ip[n]||h->new_ip[n])return 0;
    if(!region(w,h->trampoline,56,MEM_PRIVATE,0,1)||!region(w,h->detour,1,MEM_IMAGE,plan.publisher_base,1)||
       !native_code_section(w,plan.publisher_base,h->detour,1)||!win_read(w,h->trampoline,actual,total)||memcmp(actual,expected,total))return 0;
    /* Code and its resident x64 unwind descriptions are one accepted shape.
       Registration itself is supplied by the hash-verified publisher. */
    if(!win_read(w,h->trampoline,actual,56))return 0;
    static const unsigned char leaf_info[4]={1,0,0,0};
    static const unsigned char finder_info[12]={2,9,3,0,9,1,44,0,2,0xe0,0,0};
    static const unsigned char loading_info[8]={2,7,2,0,7,0x34,2,0};
    if(index==0){if(memcmp(actual+48,leaf_info,4))return 0;}
    else if(index==1){if(memcmp(actual+40,finder_info,12)||memcmp(actual+52,leaf_info,4))return 0;}
    else if(memcmp(actual+40,loading_info,8)||memcmp(actual+48,leaf_info,4))return 0;
    return 1;
}
static int validate_loading_dependency(WinNI *w){
    const uint64_t address=plan.game_base+LOADING_INTERNAL_RVA;
    if(!region(w,address,LOADING_INTERNAL_SIZE,MEM_IMAGE,plan.game_base,1)||
       !native_code_section(w,plan.game_base,address,LOADING_INTERNAL_SIZE))return 0;
    for(unsigned offset=0;offset<LOADING_INTERNAL_SIZE;){
        unsigned chunk=LOADING_INTERNAL_SIZE-offset;if(chunk>128)chunk=128;
        if(!win_read(w,address+offset,scratch,chunk)||memcmp(scratch,LOADING_INTERNAL_SIGNATURE+offset,chunk))return 0;
        offset+=chunk;
    }
    return 1;
}
static int validate_plan(WinNI *w,const wchar_t *mapping,const unsigned char publisher_hash[32]){
    FILETIME created,exit,kernel,user;USHORT pm,nm;wchar_t game_path[32768],pub_path[32768];DWORD count=32768,sz;
    unsigned char expected_game[32],actual[32];wchar_t game_sha[65];
    for(unsigned i=0;i<65;i++)game_sha[i]=(wchar_t)NI_GAME_SHA[i];
    if(plan.magic!=NAV_INSTALL_MAGIC||plan.version!=NAV_INSTALL_VERSION||plan.byte_size!=sizeof(plan)||plan.pid!=w->pid||plan.hook_count!=NAV_INSTALL_HOOKS||
       !plan.ready||plan.reserved||plan.game_base>UINT64_MAX-plan.game_image_size||plan.publisher_base>UINT64_MAX-plan.publisher_image_size||
       !GetProcessTimes(w->process,&created,&exit,&kernel,&user)||ft64(created)!=plan.process_creation_filetime||
       !IsWow64Process2(w->process,&pm,&nm)||pm!=IMAGE_FILE_MACHINE_UNKNOWN||nm!=IMAGE_FILE_MACHINE_AMD64)return 0;
    wchar_t prefix[128];_snwprintf(prefix,128,L"Local\\ManeaterCodexAreaInstall_%lu_",(unsigned long)w->pid);
    size_t pre=wcslen(prefix);unsigned char token[16];
    if(wcsncmp(mapping,prefix,pre)||!parse_hex(mapping+pre,token,16)||memcmp(token,plan.instance_token,16))return 0;
    if(!QueryFullProcessImageNameW(w->process,0,game_path,&count)||!parse_hex(game_sha,expected_game,32)||
       !image_hash(game_path,actual)||memcmp(actual,expected_game,32)||memcmp(plan.game_sha256,expected_game,32))return 0;
    const wchar_t *bn=wcsrchr(game_path,L'\\');bn=bn?bn+1:game_path;
    if(_wcsicmp(bn,L"Maneater-Win64-Shipping.exe")||!module_path(w->pid,plan.game_base,pub_path,&sz)||
       _wcsicmp(pub_path,game_path)||sz!=plan.game_image_size||!image_pe(w,plan.game_base,plan.game_image_size,plan.game_timestamp))return 0;
    if(!module_path(w->pid,plan.publisher_base,pub_path,&sz)||sz!=plan.publisher_image_size||
       !image_pe(w,plan.publisher_base,plan.publisher_image_size,plan.publisher_timestamp)||!image_hash(pub_path,actual)||memcmp(actual,publisher_hash,32))return 0;
    if(!validate_loading_dependency(w))return 0;
    if(!region(w,plan.game_base+AREA_NAV_AUX_RVA,sizeof(area_nav_aux_guard),MEM_IMAGE,plan.game_base,1)||
       !native_code_section(w,plan.game_base,plan.game_base+AREA_NAV_AUX_RVA,sizeof(area_nav_aux_guard))||
       !win_read(w,plan.game_base+AREA_NAV_AUX_RVA,scratch,sizeof(area_nav_aux_guard))||
       memcmp(scratch,area_nav_aux_guard,sizeof(area_nav_aux_guard)))return 0;
    uint32_t tolerance;
    if(!region(w,plan.game_base+AREA_NAV_TOLERANCE_RVA,sizeof(tolerance),MEM_IMAGE,plan.game_base,0)||
       !win_read(w,plan.game_base+AREA_NAV_TOLERANCE_RVA,&tolerance,sizeof(tolerance))||
       tolerance!=AREA_NAV_TOLERANCE_BITS)return 0;
    for(unsigned k=0;k<NAV_INSTALL_HOOKS;k++){
        const NavInstallPlan *h=&plan.plans[k];
        if(h->target_rva!=rvas[k]||h->target!=plan.game_base+rvas[k]||h->guard_length!=lengths[k]||
           memcmp(h->guard,guards[k],lengths[k])||memcmp(h->original5,guards[k],5)||h->patch5[0]!=0xe9||
           !region(w,h->target,h->guard_length,MEM_IMAGE,plan.game_base,1)||!native_code_section(w,plan.game_base,h->target,h->guard_length)||
           !win_read(w,h->target,scratch,h->guard_length)||memcmp(scratch,guards[k],h->guard_length))return 0;
        int64_t delta=(int64_t)h->relay-(int64_t)(h->target+5);int32_t rel;
        memcpy(&rel,h->patch5+1,4);if(delta<INT32_MIN||delta>INT32_MAX||rel!=delta||!validate_trampoline(w,h,k))return 0;
        for(unsigned n=0;n<sizeof(h->reserved);n++)if(h->reserved[n])return 0;
        for(unsigned n=h->guard_length;n<sizeof(h->guard);n++)if(h->guard[n])return 0;
        for(unsigned j=0;j<k;j++)if(h->trampoline==plan.plans[j].trampoline||h->detour==plan.plans[j].detour)return 0;
    }return 1;
}
static int preopen_threads(WinNI *w){
    unsigned n=0;if(!win_census(w,workspace.census_ids,NI_MAX_THREADS,&n)||!n)return 0;
    for(unsigned i=0;i<n;i++){
        DWORD tid=workspace.census_ids[i];HANDLE h=OpenThread(THREAD_SUSPEND_RESUME|THREAD_GET_CONTEXT|THREAD_SET_CONTEXT|THREAD_QUERY_LIMITED_INFORMATION|SYNCHRONIZE,FALSE,tid);
        if(!h)return 0;
        if(GetProcessIdOfThread(h)!=w->pid){CloseHandle(h);return 0;}
        NIThread *t=&workspace.threads[workspace.thread_count++];memset(t,0,sizeof(*t));t->tid=tid;t->handle=h;
    }return 1;
}
static int result_file(const wchar_t *path,const NIResult *r,DWORD pid,uint64_t begin,uint64_t end,uint64_t freq){
    char b[2048];int n=snprintf(b,sizeof(b),"{\"pid\":%lu,\"code\":%d,\"win32_error\":%lu,\"installed\":%d,\"fatal\":%d,\"rollback_errors\":%u,\"resume_errors\":%u,\"threads_owned\":%u,\"contexts_moved\":%u,\"patch_attempts\":%u,\"unique_pages\":%u,\"second_census_count\":%u,\"begin_qpc\":\"%" PRIu64 "\",\"end_qpc\":\"%" PRIu64 "\",\"qpc_frequency\":\"%" PRIu64 "\",\"transaction_ms\":%.6f,\"external_only\":true,\"residual_thread_birth_race\":true,\"resident_trampolines\":true}\n",(unsigned long)pid,r->code,(unsigned long)r->win32_error,r->installed,r->fatal,r->rollback_errors,r->resume_errors,r->threads_owned,r->contexts_moved,r->patch_attempts,r->pages,r->second_census_count,begin,end,freq,freq?(double)(end-begin)*1000/freq:0.0);
    if(n<0||(size_t)n>=sizeof(b))return 0;
    HANDLE f=CreateFileW(path,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);DWORD put=0;
    if(f==INVALID_HANDLE_VALUE)return 0;int ok=WriteFile(f,b,(DWORD)n,&put,NULL)&&put==(DWORD)n;CloseHandle(f);fputs(b,stdout);return ok;
}
int wmain(int argc,wchar_t **argv){
    WinNI w={0};HANDLE map=NULL;NavInstallShared *shared=NULL;NIResult r;memset(&r,0,sizeof(r));
    unsigned char pubhash[32];SYSTEM_INFO si;LARGE_INTEGER freq,begin,end;int claimed=0;
    memset(&workspace,0,sizeof(workspace));memset(&plan,0,sizeof(plan));
    if(argc!=5){fputs("usage: nav_install_external.exe PID mapping-name frozen-DLL-SHA256 result-json\n",stderr);return 2;}
    wchar_t *tail;unsigned long pid=wcstoul(argv[1],&tail,10);
    if(*tail||!pid||pid>UINT32_MAX||!parse_hex(argv[3],pubhash,32))return 2;w.pid=(DWORD)pid;
    QueryPerformanceFrequency(&freq);QueryPerformanceCounter(&begin);end=begin;
    w.process=OpenProcess(PROCESS_QUERY_INFORMATION|PROCESS_VM_READ|PROCESS_VM_WRITE|PROCESS_VM_OPERATION|SYNCHRONIZE,FALSE,w.pid);
    map=OpenFileMappingW(FILE_MAP_READ|FILE_MAP_WRITE,FALSE,argv[2]);
    if(!w.process||!map){r.code=NI_OPEN;r.win32_error=GetLastError();goto done;}
    shared=MapViewOfFile(map,FILE_MAP_READ|FILE_MAP_WRITE,0,0,sizeof(*shared));
    if(!shared||InterlockedCompareExchange((volatile LONG*)&shared->ready,0,0)!=1){r.code=NI_BAD_PLAN;goto done;}
    memcpy(&plan,shared,sizeof(plan));MemoryBarrier();
    if(memcmp(shared->plans,plan.plans,sizeof(plan.plans))||!validate_plan(&w,argv[2],pubhash)) {r.code=NI_BAD_PLAN;r.win32_error=GetLastError();goto done;}
    if(InterlockedCompareExchange((volatile LONG*)&shared->installer_state,NAV_INSTALL_CLAIMED,NAV_INSTALL_PENDING)!=NAV_INSTALL_PENDING){r.code=NI_BAD_PLAN;goto done;}
    claimed=1;FILETIME c,e,k,u;GetProcessTimes(GetCurrentProcess(),&c,&e,&k,&u);shared->installer_pid=GetCurrentProcessId();shared->installer_creation_filetime=ft64(c);
    if(!preopen_threads(&w)){r.code=NI_OPEN;r.win32_error=GetLastError();goto done;}
    /* Prefault helper storage/API paths before first suspension. */
    for(SIZE_T i=0;i<sizeof(workspace);i+=4096){volatile unsigned char *v=(volatile unsigned char*)&workspace;unsigned char x=v[i];v[i]=x;}
    GetSystemInfo(&si);QueryPerformanceCounter(&begin);
    r=ni_transaction(&plan,&workspace,&ops,&w,si.dwPageSize);
    QueryPerformanceCounter(&end);
done:
    if(claimed&&shared){
        shared->result_code=r.code;shared->win32_error=r.win32_error;shared->rollback_errors=r.rollback_errors;shared->resume_errors=r.resume_errors;
        shared->contexts_moved=r.contexts_moved;shared->threads_owned=r.threads_owned;MemoryBarrier();
        InterlockedExchange((volatile LONG*)&shared->installer_state,r.installed?NAV_INSTALL_INSTALLED:r.fatal?NAV_INSTALL_FATAL:NAV_INSTALL_REJECTED);
    }
    for(unsigned i=0;i<workspace.thread_count;i++)if(workspace.threads[i].handle)CloseHandle(workspace.threads[i].handle);
    int output_ok=result_file(argv[4],&r,w.pid,(uint64_t)begin.QuadPart,(uint64_t)end.QuadPart,(uint64_t)freq.QuadPart);
    if(shared)UnmapViewOfFile(shared);if(map)CloseHandle(map);if(w.process)CloseHandle(w.process);
    return r.installed&&output_ok?0:r.fatal?4:3;
}
