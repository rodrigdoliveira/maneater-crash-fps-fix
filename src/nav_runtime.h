#ifndef MANEATER_PRIVATE_NAV_RUNTIME_H
#define MANEATER_PRIVATE_NAV_RUNTIME_H
#include "nav_scope.h"
#include "nav_signatures.h"
#include "nav_install_contract.h"
#include "nav_helper_hash.h"
#include "loading_runtime.h"
#include "../vendor/minhook/src/buffer.h"
#include "../vendor/minhook/src/trampoline.h"
#include <bcrypt.h>

typedef void (__fastcall *NavConnectFn)(void *,void *,void *,uint32_t,uint8_t);
typedef int32_t (__fastcall *NavFinderFn)(void *,const float *,const float *,void *,int32_t,void *,uint32_t,void *);
static NavConnectFn nav_original_connect;
static NavFinderFn nav_original_finder;
static DWORD nav_tls=TLS_OUT_OF_INDEXES;
static volatile LONG nav_enabled;
static NavInstallPlan nav_plans[NAV_INSTALL_HOOKS];
static RUNTIME_FUNCTION nav_unwind[NAV_INSTALL_HOOKS][2];
static NavInstallShared *nav_shared;
static HANDLE nav_mapping;
static wchar_t nav_mapping_name[160];

static int nav_read_view(void *tile,NavTileView *v) {
    memset(v,0,sizeof(*v)); v->tile=tile;
    return read_call_snapshot(tile,v->tile_copy,sizeof(v->tile_copy)) &&
        read_call_snapshot((const void *)nav_ptr_at(v->tile_copy,8),v->header,sizeof(v->header)) && nav_layout(v);
}
static int nav_build_scope(NavScope *s,void *nav,void *source,void *target,uint32_t side) {
    unsigned char mesh[0xa8];
    if((side!=UINT32_MAX && !nav_cardinal_side(side)) ||
       !nav_read_view(target,&s->target) || s->target.npoly<256 || !nav_read_view(source,&s->source) ||
       !nav_views_disjoint(&s->source,&s->target,nav) || !read_call_snapshot(nav,mesh,sizeof(mesh)))return 0;
    uintptr_t tiles=nav_ptr_at(mesh,0x90);
    uint32_t max_tiles=nav_u32_at(mesh,0x30);
    if(!max_tiles || max_tiles>1048576U || !nav_span(tiles,(size_t)max_tiles*0xb0))return 0;
    uintptr_t a=(uintptr_t)source,b=(uintptr_t)target;
    if(a<tiles || b<tiles || (a-tiles)%0xb0 || (b-tiles)%0xb0 ||
       (a-tiles)/0xb0>=max_tiles || (b-tiles)/0xb0>=max_tiles)return 0;
    size_t sp=(size_t)s->source.npoly*sizeof(NavPoly),tp=(size_t)s->target.npoly*sizeof(NavPoly);
    size_t tv=(size_t)s->target.nverts*sizeof(NavVertex),sv=(size_t)s->source.nverts*sizeof(NavVertex);
    size_t cap=(size_t)s->target.npoly;
    /* Source polygons are only needed for eligibility. Reuse that bounded
     * scratch for checking vertex readability afterwards. */
    size_t source_bytes=sp>sv?sp:sv;
    size_t bytes=source_bytes+tp+tv+cap*sizeof(NavPortal);
    s->allocation=HeapAlloc(GetProcessHeap(),0,bytes);
    if(!s->allocation)return 0;
    NavPoly *source_polys=(NavPoly *)s->allocation;
    NavPoly *target_polys=(NavPoly *)((unsigned char *)s->allocation+source_bytes);
    NavVertex *vertices=(NavVertex *)((unsigned char *)target_polys+tp);
    NavPortal *portals=(NavPortal *)((unsigned char *)vertices+tv);
    if(!read_call_snapshot((void *)s->source.polys_ptr,source_polys,sp))return 0;
    size_t queries=0;
    for(size_t i=0;i<s->source.npoly;++i) {
        unsigned count=source_polys[i].bytes[30];
        if(count>6)return 0;
        for(unsigned j=0;j<count;++j) {
            if(nav_poly_u16(&source_polys[i],4+j*2)>=s->source.nverts)return 0;
            uint16_t flag=nav_poly_u16(&source_polys[i],16+j*2);
            if((flag==0x8000 || flag==0x8002 || flag==0x8004 || flag==0x8006) &&
               (side==UINT32_MAX || flag==(0x8000U|side)))++queries;
        }
    }
    /* Amortize a bounded snapshot over repeated queries. Dense portal tiles
     * use native code: this is an index for sparse boundaries, not a new mesh. */
    if(queries<32 || !read_call_snapshot((void *)s->target.polys_ptr,target_polys,tp) ||
       !read_call_snapshot((void *)s->target.verts_ptr,vertices,tv) ||
       !read_call_snapshot((void *)s->source.verts_ptr,s->allocation,sv) ||
       !nav_build_index(target_polys,s->target.npoly,vertices,s->target.nverts,portals,cap,&s->index) ||
       !nav_identity(&s->source) || !nav_identity(&s->target))return 0;
    s->nav=nav; return 1;
}
static __attribute__((noinline)) void __fastcall nav_connect(void *nav,void *source,void *target,uint32_t side,uint8_t cluster) {
    DWORD incoming=GetLastError();
    unsigned mxcsr=_mm_getcsr();
    NavScope *previous=(NavScope *)TlsGetValue(nav_tls);
    if(previous)previous->disabled=1;
    NavScope scope; memset(&scope,0,sizeof(scope));
    /* Install a disabled sentinel even during allocation, preventing foreign
     * allocator reentry from accidentally using the outer snapshot. */
    scope.disabled=1;
    int set=TlsSetValue(nav_tls,&scope)!=0;
    __try {
        if(set && !previous && InterlockedCompareExchange(&nav_enabled,0,0) &&
           nav_build_scope(&scope,nav,source,target,side))scope.disabled=0;
        _mm_setcsr(mxcsr); SetLastError(incoming);
        nav_original_connect(nav,source,target,side,cluster);
    } __finally {
        /* Also release the transient scope if a recoverable exception escapes
         * a native allocator. The exception continues to its original handler. */
        DWORD outgoing=GetLastError(); unsigned outgoing_mxcsr=_mm_getcsr();
        if(set)TlsSetValue(nav_tls,previous);
        if(scope.allocation)HeapFree(GetProcessHeap(),0,scope.allocation);
        _mm_setcsr(outgoing_mxcsr); SetLastError(outgoing);
    }
}
static int32_t nav_dispatch(uintptr_t caller,void *nav,const float *va,const float *vb,void *source,
                            int32_t poly,void *target,uint32_t side,void *out) {
    DWORD incoming=GetLastError(); unsigned mxcsr=_mm_getcsr();
    NavScope *s=(NavScope *)TlsGetValue(nav_tls);
    int reject=0;
    /* Unmasked floating exceptions must never acquire an extra operation. */
    if((mxcsr&0x1f80U)==0x1f80U && caller==g_game_base+0x2b5aef5U && s &&
       nav_query_identity(s,nav,source,target,va,vb,poly)) {
        ++s->queries;
        reject=!nav_may_connect_trusted(&s->index,va,vb,side);
        if(reject)++s->rejected;
        /* Stop paying for an unhelpful filter within a positive-heavy call. */
        if(s->queries==16 && s->rejected<4)s->disabled=1;
    }
    _mm_setcsr(mxcsr); SetLastError(incoming);
    if(reject)return 0;
    return nav_original_finder(nav,va,vb,source,poly,target,side,out);
}
static __attribute__((noinline)) int32_t __fastcall nav_finder(void *nav,const float *va,const float *vb,void *source,
                                                               int32_t poly,void *target,uint32_t side,void *out) {
    return nav_dispatch((uintptr_t)CALLER_RETURN_ADDRESS(),nav,va,vb,source,poly,target,side,out);
}

static void nav_absjump(unsigned char *b,uintptr_t target) {
    b[0]=0xff;b[1]=0x25;memset(b+2,0,4);memcpy(b+6,&target,8);
}
static int nav_register_unwind(unsigned i,unsigned char *trampoline) {
    /* MinHook emits code only. Publish matching x64 unwind descriptions too,
     * so suspended prologue threads and asynchronous stack walkers retain
     * the original PUSH R14 / allocation semantics. All storage stays live. */
    if(i>=NAV_INSTALL_HOOKS)return 0;
    RUNTIME_FUNCTION *f=nav_unwind[i];memset(f,0,sizeof(nav_unwind[i]));
    if(i==1) {
        /* V2 explicitly describes epilogues; this fragment has none. V1 would
         * infer an epilogue from the FF25 transfer and lose its live frame. */
        static const unsigned char finder_info[12]={2,9,3,0,9,1,44,0,2,0xe0,0,0};
        memcpy(trampoline+40,finder_info,12);memset(trampoline+52,0,4);trampoline[52]=1;
        f[0].BeginAddress=0;f[0].EndAddress=23;f[0].UnwindData=40;
        f[1].BeginAddress=23;f[1].EndAddress=37;f[1].UnwindData=52;
    }else if(i==2) {
        /* The copied home store saves RBX at entry RSP+16. Version 2 avoids
         * mistaking the absolute jump-back for an epilogue. The relay has no
         * original prologue and receives its own leaf description. */
        static const unsigned char loading_info[8]={2,7,2,0,7,0x34,2,0};
        memcpy(trampoline+40,loading_info,8);memset(trampoline+48,0,4);trampoline[48]=1;
        f[0].BeginAddress=0;f[0].EndAddress=21;f[0].UnwindData=40;
        f[1].BeginAddress=21;f[1].EndAddress=35;f[1].UnwindData=48;
    }else {
        memset(trampoline+48,0,4);trampoline[48]=1;
        f[0].BeginAddress=0;f[0].EndAddress=47;f[0].UnwindData=48;
    }
    if(!RtlAddFunctionTable(f,i?2:1,(DWORD64)(uintptr_t)trampoline))return 0;
    if(i==1) {
        /* Refuse attachment if this Windows unwinder does not understand the
         * registered description. Inspect a synthetic stack; execute no code. */
        DWORD64 stack[80]={0};DWORD64 *entry=stack+64;
        CONTEXT context;memset(&context,0,sizeof(context));
        entry[0]=UINT64_C(0x1122446688);entry[-1]=UINT64_C(0xabcdef1234);
        context.Rip=(DWORD64)(uintptr_t)(trampoline+9);
        context.Rsp=(DWORD64)(uintptr_t)entry-0x168;context.R14=0;
        PVOID handler=NULL;DWORD64 frame=0;
        RtlVirtualUnwind(0,(DWORD64)(uintptr_t)trampoline,context.Rip,&f[0],&context,&handler,&frame,NULL);
        if(context.Rip!=entry[0] || context.Rsp!=(DWORD64)(uintptr_t)(entry+1) || context.R14!=entry[-1])return 0;
    }else if(i==2) {
        static const unsigned offsets[]={0,3,7,13,20,21,34};
        for(unsigned j=0;j<sizeof(offsets)/sizeof(offsets[0]);++j) {
            DWORD64 stack[8]={UINT64_C(0x1122446688),0,UINT64_C(0xabcdef1234)};
            CONTEXT context;memset(&context,0,sizeof(context));
            context.Rip=(DWORD64)(uintptr_t)(trampoline+offsets[j]);
            context.Rsp=(DWORD64)(uintptr_t)stack;context.Rbx=UINT64_C(0x9988776655);
            PVOID handler=NULL;DWORD64 frame=0;
            RUNTIME_FUNCTION *entry=&f[offsets[j]>=21];
            RtlVirtualUnwind(0,(DWORD64)(uintptr_t)trampoline,context.Rip,entry,&context,&handler,&frame,NULL);
            DWORD64 expected=(offsets[j]>=7 && offsets[j]<21)?stack[2]:UINT64_C(0x9988776655);
            if(context.Rip!=stack[0] || context.Rsp!=(DWORD64)(uintptr_t)(stack+1) || context.Rbx!=expected)return 0;
        }
    }
    return 1;
}
static int nav_prepare_plan(unsigned i) {
    if(i>=NAV_INSTALL_HOOKS)return 0;
    const unsigned char *guard=i==2?LOADING_WRAPPER_SIGNATURE:(i?area_nav_finder_guard:area_nav_connect_guard);
    unsigned rva=i==2?LOADING_WRAPPER_RVA:(i?AREA_NAV_FINDER_RVA:AREA_NAV_CONNECT_RVA);
    size_t length=i==2?LOADING_WRAPPER_SIZE:(i?sizeof(area_nav_finder_guard):sizeof(area_nav_connect_guard));
    if(length>NAV_INSTALL_MAX_GUARD)return 0;
    unsigned stolen=i==2?7:9,second=i==1?2:3,third_new=i==2?7:(i?9:19);
    TRAMPOLINE t;memset(&t,0,sizeof(t));
    t.pTarget=(void *)(g_game_base+rva);t.pDetour=i==2?(void *)&loading_package:(i?(void *)&nav_finder:(void *)&nav_connect);
    t.pTrampoline=AllocateBuffer(t.pTarget);
    if(!t.pTrampoline || !CreateTrampolineFunction(&t) || t.patchAbove || t.nIP!=3 ||
       t.oldIPs[0]!=0 || t.oldIPs[1]!=second || t.oldIPs[2]!=stolen ||
       t.newIPs[0]!=0 || t.newIPs[1]!=second || t.newIPs[2]!=third_new)return 0;
    unsigned relay=i==2?21:(i?23:33);unsigned char expected[64]={0};
    if(i){memcpy(expected,guard,stolen);nav_absjump(expected+stolen,(uintptr_t)t.pTarget+stolen);}
    else{memcpy(expected,guard,3);expected[3]=0x75;expected[4]=0x0e;
         nav_absjump(expected+5,(uintptr_t)t.pTarget+0x4e1);nav_absjump(expected+19,(uintptr_t)t.pTarget+9);}
    nav_absjump(expected+relay,(uintptr_t)t.pDetour);
    if(t.pRelay!=(unsigned char *)t.pTrampoline+relay || memcmp(t.pTrampoline,expected,relay+14) ||
       !nav_register_unwind(i,t.pTrampoline) ||
       !FlushInstructionCache(GetCurrentProcess(),t.pTrampoline,MEMORY_SLOT_SIZE))return 0;
    int64_t d=(int64_t)(uintptr_t)t.pRelay-(int64_t)((uintptr_t)t.pTarget+5);
    if(d<INT32_MIN || d>INT32_MAX)return 0;
    NavInstallPlan *p=&nav_plans[i];memset(p,0,sizeof(*p));
    p->target=(uintptr_t)t.pTarget;p->trampoline=(uintptr_t)t.pTrampoline;p->relay=(uintptr_t)t.pRelay;p->detour=(uintptr_t)t.pDetour;
    p->target_rva=rva;p->guard_length=(uint32_t)length;p->n_ip=t.nIP;p->stolen_length=stolen;
    memcpy(p->old_ip,t.oldIPs,t.nIP);memcpy(p->new_ip,t.newIPs,t.nIP);memcpy(p->original5,guard,5);
    p->patch5[0]=0xe9;int32_t rel=(int32_t)d;memcpy(p->patch5+1,&rel,4);memcpy(p->guard,guard,length);
    if(i==1)nav_original_finder=(NavFinderFn)t.pTrampoline;else if(i==0)nav_original_connect=(NavConnectFn)t.pTrampoline;
    return 1;
}
static int nav_hash_file(const wchar_t *path,unsigned char out[32]) {
    HANDLE f=CreateFileW(path,GENERIC_READ,FILE_SHARE_READ|FILE_SHARE_DELETE,NULL,OPEN_EXISTING,FILE_FLAG_SEQUENTIAL_SCAN,NULL);
    BCRYPT_ALG_HANDLE alg=NULL;BCRYPT_HASH_HANDLE hash=NULL;unsigned char *object=NULL,*buf=NULL;
    DWORD size=0,used=0,n=0;int ok=0;
    if(f==INVALID_HANDLE_VALUE || BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,NULL,0)<0 ||
       BCryptGetProperty(alg,BCRYPT_OBJECT_LENGTH,(PUCHAR)&size,sizeof(size),&used,0)<0 || !size)goto done;
    object=HeapAlloc(GetProcessHeap(),0,size);buf=HeapAlloc(GetProcessHeap(),0,1048576);
    if(!object || !buf || BCryptCreateHash(alg,&hash,object,size,NULL,0,0)<0)goto done;
    for(;;){if(!ReadFile(f,buf,1048576,&n,NULL))goto done;if(!n)break;if(BCryptHashData(hash,buf,n,0)<0)goto done;}
    ok=BCryptFinishHash(hash,out,32,0)>=0;
done:
    if(hash)BCryptDestroyHash(hash);if(alg)BCryptCloseAlgorithmProvider(alg,0);
    if(object)HeapFree(GetProcessHeap(),0,object);if(buf)HeapFree(GetProcessHeap(),0,buf);if(f!=INVALID_HANDLE_VALUE)CloseHandle(f);return ok;
}
static int nav_sibling(wchar_t path[32768],const wchar_t *name) {
    DWORD n=GetModuleFileNameW(g_self,path,32768);if(!n || n>=32768)return 0;
    while(n && path[n-1]!=L'\\' && path[n-1]!=L'/')--n;
    size_t len=wcslen(name);if(n+len>=32768)return 0;memcpy(path+n,name,(len+1)*sizeof(wchar_t));return 1;
}
static void nav_hex(const unsigned char *b,unsigned n,wchar_t *out) {
    static const wchar_t digits[]=L"0123456789abcdef";
    for(unsigned i=0;i<n;++i){out[2*i]=digits[b[i]>>4];out[2*i+1]=digits[b[i]&15];}out[n*2]=0;
}
static int nav_publish(void) {
    HMODULE pinned;FILETIME c,e,k,u;unsigned char token[16];wchar_t suffix[33];
    IMAGE_DOS_HEADER dos;IMAGE_NT_HEADERS64 nt;
    if(g_experimental_build ||
       !getup_complete_signature(AREA_NAV_CONNECT_RVA,area_nav_connect_guard,sizeof(area_nav_connect_guard)) ||
       !getup_complete_signature(AREA_NAV_FINDER_RVA,area_nav_finder_guard,sizeof(area_nav_finder_guard)) ||
       !getup_complete_signature(AREA_NAV_AUX_RVA,area_nav_aux_guard,sizeof(area_nav_aux_guard)) ||
       !getup_complete_signature(LOADING_WRAPPER_RVA,LOADING_WRAPPER_SIGNATURE,LOADING_WRAPPER_SIZE) ||
       !getup_complete_signature(LOADING_INTERNAL_RVA,LOADING_INTERNAL_SIGNATURE,LOADING_INTERNAL_SIZE))return 0;
    uint32_t tolerance;
    if(!read_image(AREA_NAV_TOLERANCE_RVA,&tolerance,4) || tolerance!=AREA_NAV_TOLERANCE_BITS)return 0;
    nav_tls=TlsAlloc();if(nav_tls==TLS_OUT_OF_INDEXES)return 0;
    if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,(LPCWSTR)(uintptr_t)&nav_finder,&pinned) ||
       !safe_read(g_self,&dos,sizeof(dos)) || dos.e_lfanew<0 || dos.e_lfanew>4096 ||
       !safe_read((char *)g_self+dos.e_lfanew,&nt,sizeof(nt)))return 0;
    /* Immutable dependency is published before any detour can be installed. */
    loading_internal=(LoadingInternalFn)(g_game_base+LOADING_INTERNAL_RVA);
    InitializeBuffer();for(unsigned i=0;i<NAV_INSTALL_HOOKS;++i)if(!nav_prepare_plan(i))return 0;
    if(BCryptGenRandom(NULL,token,16,BCRYPT_USE_SYSTEM_PREFERRED_RNG)<0 ||
       !GetProcessTimes(GetCurrentProcess(),&c,&e,&k,&u))return 0;
    nav_hex(token,16,suffix);
    _snwprintf(nav_mapping_name,160,L"Local\\ManeaterCodexAreaInstall_%lu_%ls",(unsigned long)GetCurrentProcessId(),suffix);
    nav_mapping=CreateFileMappingW(INVALID_HANDLE_VALUE,NULL,PAGE_READWRITE,0,sizeof(NavInstallShared),nav_mapping_name);
    if(!nav_mapping || GetLastError()==ERROR_ALREADY_EXISTS)return 0;
    nav_shared=MapViewOfFile(nav_mapping,FILE_MAP_ALL_ACCESS,0,0,sizeof(NavInstallShared));if(!nav_shared)return 0;
    memset(nav_shared,0,sizeof(*nav_shared));nav_shared->magic=NAV_INSTALL_MAGIC;nav_shared->version=NAV_INSTALL_VERSION;
    nav_shared->byte_size=sizeof(*nav_shared);nav_shared->pid=GetCurrentProcessId();nav_shared->hook_count=NAV_INSTALL_HOOKS;
    nav_shared->process_creation_filetime=((uint64_t)c.dwHighDateTime<<32)|c.dwLowDateTime;
    nav_shared->game_base=g_game_base;nav_shared->game_image_size=g_game_image_size;nav_shared->game_timestamp=EXPECTED_TIMESTAMP;
    static const unsigned char game_sha[32]={0xcc,0x34,0xe4,0x3b,0xbd,0x1f,0x75,0x7e,0x38,0x83,0xad,0xaf,0x37,0xd6,0x43,0xc1,0xa0,0xfb,0x29,0x63,0x96,0x7c,0xa3,0x3a,0xf7,0xcb,0x6c,0xb8,0xf5,0x44,0x80,0xc0};
    memcpy(nav_shared->game_sha256,game_sha,32);nav_shared->publisher_base=(uintptr_t)g_self;
    nav_shared->publisher_image_size=nt.OptionalHeader.SizeOfImage;nav_shared->publisher_timestamp=nt.FileHeader.TimeDateStamp;
    memcpy(nav_shared->instance_token,token,16);memcpy(nav_shared->plans,nav_plans,sizeof(nav_plans));
    MemoryBarrier();InterlockedExchange((volatile LONG *)&nav_shared->ready,1);return 1;
}
static DWORD WINAPI nav_worker(void *unused) {
    (void)unused;wchar_t helper[32768],self[32768],output[32768],command[66000],hash_hex[65],result_name[120];
    unsigned char hash[32];HANDLE log=INVALID_HANDLE_VALUE;PROCESS_INFORMATION pi={0};STARTUPINFOW si={0};
    if(!nav_sibling(output,L"maneater_area_fix.log"))return 0;
    log=CreateFileW(output,FILE_APPEND_DATA,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);
    getup_write_log(log,"Maneater v0.9.0: package-loading cleanup and bounded navigation/get-up reads with FPS correction.");
    if(!nav_sibling(helper,L"ManeaterAreaHelper.exe") || !nav_hash_file(helper,hash) || memcmp(hash,nav_expected_helper_sha,32)) {
        getup_write_log(log,"PASS-THROUGH: helper is missing or its hash changed.");goto done;
    }
    DWORD n=GetModuleFileNameW(g_self,self,32768);
    if(!n || n>=32768 || !nav_hash_file(self,hash))goto done;nav_hex(hash,32,hash_hex);
    if(!nav_publish()){getup_write_log(log,"PASS-THROUGH: native guards, trampoline or mapping preparation failed.");goto done;}
    _snwprintf(result_name,120,L"maneater_area_attach_%lu_%llu.json",(unsigned long)GetCurrentProcessId(),(unsigned long long)nav_shared->process_creation_filetime);
    if(!nav_sibling(output,result_name))goto done;
    int length=_snwprintf(command,66000,L"\"%ls\" %lu \"%ls\" %ls \"%ls\"",helper,(unsigned long)GetCurrentProcessId(),nav_mapping_name,hash_hex,output);
    if(length<0 || length>=32767){getup_write_log(log,"PASS-THROUGH: helper command too long.");goto done;}
    si.cb=sizeof(si);si.dwFlags=STARTF_USESHOWWINDOW;si.wShowWindow=SW_HIDE;
    if(!CreateProcessW(helper,command,NULL,NULL,FALSE,CREATE_NO_WINDOW,NULL,NULL,&si,&pi)){
        getup_write_log(log,"PASS-THROUGH: external attachment helper could not start.");goto done;
    }
    CloseHandle(pi.hThread);
    /* The helper owns a bounded suspension transaction. Never kill it mid
     * transaction; no game input, profiler, or long-lived child is involved. */
    WaitForSingleObject(pi.hProcess,INFINITE);CloseHandle(pi.hProcess);
    if(nav_shared->installer_state==NAV_INSTALL_INSTALLED && !nav_shared->result_code &&
       !nav_shared->rollback_errors && !nav_shared->resume_errors &&
       !memcmp(nav_shared->plans,nav_plans,sizeof(nav_plans))) {
        int good=1;
        for(unsigned i=0;i<NAV_INSTALL_HOOKS;++i) {
            if(!getup_complete_signature(nav_plans[i].target_rva,nav_plans[i].patch5,5) ||
               !getup_complete_signature(nav_plans[i].target_rva+5,nav_plans[i].guard+5,nav_plans[i].guard_length-5))good=0;
        }
        if(!getup_complete_signature(LOADING_INTERNAL_RVA,LOADING_INTERNAL_SIGNATURE,LOADING_INTERNAL_SIZE))good=0;
        if(good){InterlockedExchange(&nav_enabled,1);getup_write_log(log,"INSTALLED: loading wrapper and navigation filter attached; loader inputs and prior get-up/FPS patches retained.");}
        else getup_write_log(log,"ATTACHMENT NOT CONFIRMED: post-install guards changed; loader may remain attached. See attachment result.");
    }else {
        char message[224];snprintf(message,sizeof(message),"ATTACHMENT NOT CONFIRMED: state=%ld code=%ld error=%ld rollback=%ld resume=%ld; loader may remain attached. See attachment result.",
            (long)nav_shared->installer_state,(long)nav_shared->result_code,(long)nav_shared->win32_error,(long)nav_shared->rollback_errors,(long)nav_shared->resume_errors);
        getup_write_log(log,message);
    }
done:
    if(log!=INVALID_HANDLE_VALUE)CloseHandle(log);
    /* Mapping, trampolines and TLS slot intentionally remain process-lifetime
     * resident even after an aborted transaction with an uncertain rollback. */
    return 0;
}
static void nav_start_worker(void) {
    HANDLE h=CreateThread(NULL,0,nav_worker,NULL,0,NULL);if(h)CloseHandle(h);
}
#endif
