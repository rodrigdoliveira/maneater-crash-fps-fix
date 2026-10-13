/* Standalone synthetic-memory fixture. This includes the implementation but
 * never invokes DllMain, workers, publication, the helper, or game code. */
#include <windows.h>
static unsigned fixture_region_queries,fixture_snapshot_reads;
static SIZE_T WINAPI counted_virtual_query(LPCVOID p,PMEMORY_BASIC_INFORMATION m,SIZE_T n) {
    ++fixture_region_queries;return VirtualQuery(p,m,n);
}
static BOOL WINAPI counted_process_read(HANDLE h,LPCVOID p,LPVOID b,SIZE_T n,SIZE_T *done) {
    ++fixture_snapshot_reads;return ReadProcessMemory(h,p,b,n,done);
}
#define VirtualQuery counted_virtual_query
#define ReadProcessMemory counted_process_read
#include "../src/maneater_fps_hook.c"
#undef VirtualQuery
#undef ReadProcessMemory
#include <stdlib.h>

static unsigned assertions, groups, finder_calls, connect_calls;
#define CHECK(x) do { ++assertions; if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); exit(1); } } while (0)

typedef struct TestScene {
    unsigned char *nav, *tiles, *data[2];
    float *verts[2];
    NavPoly *polys[2];
    size_t size;
} TestScene;
typedef struct Forwarded {
    void *nav, *source, *target, *out;
    const float *va, *vb;
    int32_t poly;
    uint32_t side;
} Forwarded;
static Forwarded forwarded;
static DWORD expected_in_error, original_out_error;
static unsigned expected_in_mxcsr, original_out_mxcsr;
static unsigned char output[64];
static int original_write, connect_action, connect_depth, observed_disabled;
static TestScene *active_scene;
static void *exception_allocation;
#define FIXTURE_EXCEPTION UINT32_C(0xe00a71f3)

static void put32(unsigned char *p,size_t at,uint32_t v){memcpy(p+at,&v,4);}
static void putptr(unsigned char *p,size_t at,const void *v){uintptr_t a=(uintptr_t)v;memcpy(p+at,&a,8);}
static void put16(NavPoly *p,size_t at,uint16_t v){p->bytes[at]=(uint8_t)v;p->bytes[at+1]=(uint8_t)(v>>8);}
static void *tile(TestScene *s,unsigned which){return s->tiles+which*0xb0;}

static void make_scene(TestScene *s,uint32_t vertex_count)
{
    static const unsigned offsets[]={0x18,0x10,0x20,0x28,0x30,0x38,0x40,0x48,0x50,0x70,0x78};
    static const unsigned counts[]={7,6,8,9,10,11,12,13,14,28,6};
    static const unsigned strides[]={12,32,16,12,12,4,16,40,64,20,2};
    memset(s,0,sizeof(*s));
    s->size=0x74+(size_t)vertex_count*12+256*32+256*16+256*12;
    s->nav=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,0xa8);
    s->tiles=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,2*0xb0);
    CHECK(s->nav && s->tiles);
    put32(s->nav,0x30,2);putptr(s->nav,0x90,s->tiles);
    for(unsigned k=0;k<2;++k){
        unsigned char *t=tile(s,k);
        s->data[k]=HeapAlloc(GetProcessHeap(),HEAP_ZERO_MEMORY,s->size);
        CHECK(s->data[k]!=NULL);
        unsigned char *h=s->data[k];
        put32(h,0,0x444e4156);put32(h,4,7);put32(h,0x18,256);put32(h,0x1c,vertex_count);
        put32(h,0x20,256);put32(h,0x24,256);
        put32(t,0,k+1);putptr(t,8,h);putptr(t,0x58,h);put32(t,0x60,(uint32_t)s->size);
        unsigned char *at=h+0x74;
        for(unsigned i=0;i<11;++i){
            uint32_t n=nav_u32_at(h,counts[i]*4);
            int absent=(i==6 && n==0)||(i==10 && nav_u32_at(h,0x70)==0);
            putptr(t,offsets[i],absent?NULL:at);
            if(i==10)n=0;
            at+=(size_t)n*strides[i];
        }
        CHECK(at==h+s->size);
        s->verts[k]=(float *)nav_ptr_at(t,0x18);
        s->polys[k]=(NavPoly *)nav_ptr_at(t,0x10);
        for(unsigned i=0;i<vertex_count;++i){
            s->verts[k][i*3]=k?10.0f:0.0f;
            s->verts[k][i*3+1]=0.0f;
            s->verts[k][i*3+2]=(float)(i&1);
        }
        for(unsigned i=0;i<32;++i){
            NavPoly *p=&s->polys[k][i];p->bytes[30]=2;
            put16(p,4,0);put16(p,6,1);put16(p,16,0x8000);put16(p,18,0);
        }
    }
}
static void free_scene(TestScene *s)
{
    for(unsigned i=0;i<2;++i)if(s->data[i])CHECK(HeapFree(GetProcessHeap(),0,s->data[i]));
    CHECK(HeapFree(GetProcessHeap(),0,s->tiles));CHECK(HeapFree(GetProcessHeap(),0,s->nav));
}
static void release_scope(NavScope *s){if(s->allocation)CHECK(HeapFree(GetProcessHeap(),0,s->allocation));memset(s,0,sizeof(*s));}

static int32_t __fastcall original_finder(void *nav,const float *va,const float *vb,void *source,
                                        int32_t poly,void *target,uint32_t side,void *out)
{
    ++finder_calls;
    CHECK(GetLastError()==expected_in_error);CHECK(_mm_getcsr()==expected_in_mxcsr);
    forwarded=(Forwarded){nav,source,target,out,va,vb,poly,side};
    if(original_write && out)((unsigned char *)out)[13]=0x37;
    _mm_setcsr(original_out_mxcsr);SetLastError(original_out_error);
    return INT32_C(0x12345678);
}
static void __fastcall original_connect(void *nav,void *source,void *target,uint32_t side,uint8_t cluster)
{
    ++connect_calls;
    CHECK(nav==active_scene->nav && source==tile(active_scene,0) && target==tile(active_scene,1));
    CHECK(side==0 && cluster==0x9b);
    CHECK(GetLastError()==expected_in_error);CHECK(_mm_getcsr()==expected_in_mxcsr);
    NavScope *s=TlsGetValue(nav_tls);CHECK(s!=NULL);observed_disabled=s->disabled;
    SetLastError(expected_in_error);
    if(connect_action==3){
        CHECK(!s->disabled && s->allocation!=NULL);exception_allocation=s->allocation;
        RaiseException(FIXTURE_EXCEPTION,0,0,NULL);
        CHECK(0); /* A hook must never swallow the original native exception. */
    }else if(connect_action==1){
        CHECK(!s->disabled && s->index.valid && s->index.count==32);
        CHECK(nav_dispatch(g_game_base+0x2b5aef5,nav,active_scene->verts[0],active_scene->verts[0]+3,
                           source,0,target,0,output)==0);
    }else if(connect_action==2){
        if(connect_depth==0){
            CHECK(!s->disabled);connect_depth=1;
            nav_connect(nav,source,target,side,cluster);connect_depth=0;
            CHECK(TlsGetValue(nav_tls)==s);CHECK(s->disabled);
        }else{
            CHECK(s->disabled);
            CHECK(nav_dispatch(g_game_base+0x2b5aef5,nav,active_scene->verts[0],active_scene->verts[0]+3,
                               source,0,target,0,output)==INT32_C(0x12345678));
        }
    }
    _mm_setcsr(original_out_mxcsr);SetLastError(original_out_error);
}
static void set_environment(unsigned mxcsr)
{
    expected_in_error=0x7135;original_out_error=0x9276;
    expected_in_mxcsr=mxcsr;original_out_mxcsr=(mxcsr&~0x6000U)|0x4000U|0x20U;
    _mm_setcsr(mxcsr);SetLastError(expected_in_error);
}
static void check_forwarded(TestScene *s,const float *va,const float *vb,int32_t poly,uint32_t side)
{
    CHECK(forwarded.nav==s->nav && forwarded.source==tile(s,0) && forwarded.target==tile(s,1));
    CHECK(forwarded.va==va && forwarded.vb==vb && forwarded.poly==poly && forwarded.side==side && forwarded.out==output);
    CHECK(GetLastError()==original_out_error && _mm_getcsr()==original_out_mxcsr);
}
static int32_t call(TestScene *s,uintptr_t caller,const float *va,const float *vb,int32_t poly,uint32_t side)
{
    return nav_dispatch(caller,s->nav,va,vb,tile(s,0),poly,tile(s,1),side,output);
}

static void test_bounded_snapshot(void)
{
    SYSTEM_INFO info;GetSystemInfo(&info);SIZE_T page=info.dwPageSize;
    unsigned char *memory=VirtualAlloc(NULL,page*3,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    unsigned char copy[176];DWORD old;MEMORY_BASIC_INFORMATION state;
    CHECK(memory!=NULL);memset(memory,0x51,page*3);
    fixture_region_queries=0;
    CHECK(read_call_snapshot(memory+page-88,copy,sizeof(copy)));
    for(unsigned i=0;i<sizeof(copy);++i)CHECK(copy[i]==0x51);
    CHECK(!read_call_snapshot(NULL,copy,sizeof(copy)));
    CHECK(!read_call_snapshot((void *)(uintptr_t)0x1234,copy,sizeof(copy)));
    CHECK(!read_call_snapshot(memory,copy,0));
    CHECK(!read_call_snapshot(memory,copy,1024U*1024U+1U));
    CHECK(!read_call_snapshot((void *)(UINTPTR_MAX-10U),copy,16));
    CHECK(!read_call_snapshot(memory,(void *)(UINTPTR_MAX-10U),16));
    CHECK(VirtualProtect(memory+page,page,PAGE_READWRITE|PAGE_GUARD,&old));
    for(unsigned attempt=0;attempt<3;++attempt){
        CHECK(!read_call_snapshot(memory+page,copy,sizeof(copy)));
        CHECK(VirtualQuery(memory+page,&state,sizeof(state))==sizeof(state));
        CHECK(state.Protect==(PAGE_READWRITE|PAGE_GUARD));
    }
    CHECK(!read_call_snapshot(memory+page-88,copy,sizeof(copy)));
    CHECK(VirtualQuery(memory+page,&state,sizeof(state))==sizeof(state));
    CHECK(state.Protect==(PAGE_READWRITE|PAGE_GUARD));
    NavTileView view;
    CHECK(!nav_read_view(memory+page,&view));
    CHECK(VirtualProtect(memory+page,page,PAGE_NOACCESS,&old));
    CHECK(!read_call_snapshot(memory+page,copy,sizeof(copy)));
    CHECK(!read_call_snapshot(memory+page-88,copy,sizeof(copy)));
    CHECK(VirtualProtect(memory+page,page,PAGE_READONLY,&old));
    CHECK(read_call_snapshot(memory+page-88,copy,sizeof(copy)));
    CHECK(VirtualFree(memory+page,page,MEM_DECOMMIT));
    CHECK(!read_call_snapshot(memory+page,copy,sizeof(copy)));
    CHECK(!read_call_snapshot(memory+page-88,copy,sizeof(copy)));
    CHECK(VirtualFree(memory,0,MEM_RELEASE));
    CHECK(!read_call_snapshot(memory,copy,sizeof(copy)));
    CHECK(fixture_region_queries==0); /* Runtime reader must never region-scan. */
    ++groups;
}

static void test_large_vertex_scratch(void)
{
    const uint32_t counts[]={1024,65536};
    for(unsigned i=0;i<sizeof(counts)/sizeof(counts[0]);++i){
        TestScene scene;NavScope scope;memset(&scope,0,sizeof(scope));make_scene(&scene,counts[i]);
        fixture_region_queries=0;
        CHECK(nav_build_scope(&scope,scene.nav,tile(&scene,0),tile(&scene,1),0));
        CHECK(fixture_region_queries==0 && scope.source.nverts==counts[i]);
        CHECK(scope.index.valid && scope.index.count==32);
        /* Reading the larger vertex range into reused scratch must not
         * overwrite the following target polygon/vertex/index storage. */
        for(size_t j=0;j<scope.index.count;++j){
            CHECK(scope.index.records[j].plane==10.0f && scope.index.records[j].side==0);
        }
        CHECK(!nav_may_connect_trusted(&scope.index,scene.verts[0],scene.verts[0]+3,0));
        release_scope(&scope);free_scene(&scene);
    }
    ++groups;
}

static void test_unwind_metadata(void)
{
    unsigned char *code=VirtualAlloc(NULL,4096,MEM_RESERVE|MEM_COMMIT,PAGE_EXECUTE_READWRITE);
    CHECK(code!=NULL);
    /* Only metadata is interpreted. Neither this synthetic native prologue
     * nor its absolute-jump placeholders is ever executed. */
    memcpy(code,area_nav_finder_guard,9);
    nav_absjump(code+9,UINT64_C(0x123400009));nav_absjump(code+23,UINT64_C(0x456700000));
    CHECK(nav_register_unwind(1,code));
    for(unsigned step=0;step<3;++step){
        const unsigned offsets[3]={0,2,9};
        uint64_t stack[96]={0};uint64_t *entry=&stack[80];
        *entry=UINT64_C(0x1122446688);entry[-1]=UINT64_C(0x9988776655);
        CONTEXT ctx;memset(&ctx,0,sizeof(ctx));ctx.ContextFlags=CONTEXT_FULL;
        ctx.Rip=(DWORD64)(uintptr_t)(code+offsets[step]);ctx.R14=UINT64_C(0xaabbccdd);
        ctx.Rsp=(DWORD64)(uintptr_t)entry-(step==0?0:step==1?8:0x168);
        DWORD64 base=0;PRUNTIME_FUNCTION fn=RtlLookupFunctionEntry(ctx.Rip,&base,NULL);CHECK(fn!=NULL && base==(DWORD64)(uintptr_t)code);
        void *handler=NULL;DWORD64 establisher=0;
        RtlVirtualUnwind(UNW_FLAG_NHANDLER,base,ctx.Rip,fn,&ctx,&handler,&establisher,NULL);
        if(ctx.Rip!=*entry || ctx.Rsp!=(DWORD64)(uintptr_t)(entry+1)){
            fprintf(stderr,"Unwind step%u off%u rip=%llx expected=%llx rsp=%llx expected=%llx r14=%llx\n",step,offsets[step],(unsigned long long)ctx.Rip,(unsigned long long)*entry,(unsigned long long)ctx.Rsp,(unsigned long long)(uintptr_t)(entry+1),(unsigned long long)ctx.R14);
        }
        CHECK(ctx.Rip==*entry && ctx.Rsp==(DWORD64)(uintptr_t)(entry+1));
        CHECK(ctx.R14==(step==0?UINT64_C(0xaabbccdd):UINT64_C(0x9988776655)));
    }
    CHECK(RtlDeleteFunctionTable(nav_unwind[1]));
    CHECK(VirtualFree(code,0,MEM_RELEASE));++groups;
}

int main(void)
{
    unsigned saved_mxcsr=_mm_getcsr();TestScene scene;NavScope scope;
    memset(&scope,0,sizeof(scope));make_scene(&scene,4);active_scene=&scene;
    nav_tls=TlsAlloc();CHECK(nav_tls!=TLS_OUT_OF_INDEXES);
    nav_original_finder=original_finder;nav_original_connect=original_connect;
    g_game_base=UINT64_C(0x140000000);nav_enabled=1;
    test_bounded_snapshot();test_large_vertex_scratch();fixture_region_queries=0;
    CHECK(nav_build_scope(&scope,scene.nav,tile(&scene,0),tile(&scene,1),0));
    CHECK(fixture_region_queries==0);
    CHECK(scope.index.valid==1 && scope.index.count==32 && !scope.disabled);
    CHECK(TlsSetValue(nav_tls,&scope));
    ++groups;

    /* Negative: no original invocation, no output write, exact caller state. */
    unsigned char before[sizeof(output)];memset(output,0xa9,sizeof(output));memcpy(before,output,sizeof(output));
    set_environment(0x5fb1);finder_calls=0;original_write=1;
    unsigned reads_before=fixture_snapshot_reads;
    CHECK(call(&scene,g_game_base+0x2b5aef5,scene.verts[0],scene.verts[0]+3,0,0)==0);
    CHECK(fixture_snapshot_reads==reads_before && fixture_region_queries==0);
    CHECK(!finder_calls && !memcmp(output,before,sizeof(output)));
    CHECK(GetLastError()==expected_in_error && _mm_getcsr()==expected_in_mxcsr);
    CHECK(scope.queries==1 && scope.rejected==1);++groups;

    /* Positive: all eight arguments, native output and native state propagate. */
    for(unsigned i=0;i<4;++i)scene.verts[0][i*3]=10.0f;
    set_environment(0x1f80);finder_calls=0;
    CHECK(call(&scene,g_game_base+0x2b5aef5,scene.verts[0],scene.verts[0]+3,0,0)==INT32_C(0x12345678));
    CHECK(finder_calls==1 && output[13]==0x37);check_forwarded(&scene,scene.verts[0],scene.verts[0]+3,0,0);++groups;
    for(unsigned i=0;i<4;++i)scene.verts[0][i*3]=0.0f;

    /* Disabled, unmasked exceptions, odd side, invalid vertices/caller/poly. */
    for(unsigned i=0;i<7;++i){
        const float *va=scene.verts[0],*vb=scene.verts[0]+3;
        uintptr_t caller=g_game_base+0x2b5aef5;int32_t poly=0;uint32_t side=0;
        scope.disabled=(i==0);unsigned mode=(i==1)?0x1f00:0x1f80;
        if(i==2)side=1;if(i==3)va=(float *)((unsigned char *)va+4);
        if(i==4)caller++;if(i==5)poly=-1;if(i==6)poly=256;
        set_environment(mode);finder_calls=0;
        CHECK(call(&scene,caller,va,vb,poly,side)==INT32_C(0x12345678));
        CHECK(finder_calls==1);check_forwarded(&scene,va,vb,poly,side);
    }
    scope.disabled=0;++groups;

    /* Mutable links are expected; immutable pointer/header changes fall back. */
    put32((unsigned char *)tile(&scene,1),4,99);put32((unsigned char *)&scene.polys[1][0],0,45);
    set_environment(0x1f80);finder_calls=0;
    CHECK(call(&scene,g_game_base+0x2b5aef5,scene.verts[0],scene.verts[0]+3,0,0)==0 && !finder_calls);
    for(unsigned i=0;i<4;++i){
        unsigned char *t=tile(&scene,1);uintptr_t ptr=nav_ptr_at(t,8);uint32_t salt=nav_u32_at(t,0);
        if(i==0)putptr(t,8,NULL);if(i==1)put32(t,0,salt+1);
        if(i==2)put32(scene.data[1],0x18,255);if(i==3)putptr(t,0x18,scene.verts[0]);
        set_environment(0x1f80);finder_calls=0;
        CHECK(call(&scene,g_game_base+0x2b5aef5,scene.verts[0],scene.verts[0]+3,0,0)==INT32_C(0x12345678));
        CHECK(finder_calls==1);check_forwarded(&scene,scene.verts[0],scene.verts[0]+3,0,0);
        putptr(t,8,(void *)ptr);put32(t,0,salt);put32(scene.data[1],0x18,256);putptr(t,0x18,scene.verts[1]);
    }
    ++groups;

    /* Adaptive fallback is conservative and scoped to the current call. */
    scope.queries=15;scope.rejected=0;for(unsigned i=0;i<4;++i)scene.verts[0][i*3]=10.0f;
    set_environment(0x1f80);
    CHECK(call(&scene,g_game_base+0x2b5aef5,scene.verts[0],scene.verts[0]+3,0,0)==INT32_C(0x12345678));
    CHECK(scope.disabled);for(unsigned i=0;i<4;++i)scene.verts[0][i*3]=0.0f;
    CHECK(TlsSetValue(nav_tls,NULL));release_scope(&scope);++groups;

    /* Full connect wrapper: incoming state reaches native code, outgoing state
     * survives scratch allocation/free; query only sees this call's context. */
    connect_action=1;connect_calls=0;finder_calls=0;memset(output,0xa9,sizeof(output));
    set_environment(0x3fb0);nav_connect(scene.nav,tile(&scene,0),tile(&scene,1),0,0x9b);
    CHECK(connect_calls==1 && !finder_calls);
    CHECK(GetLastError()==original_out_error && _mm_getcsr()==original_out_mxcsr);
    CHECK(TlsGetValue(nav_tls)==NULL); /* This OS call clears LastError afterward. */
    CHECK(!memcmp(output,before,sizeof(output)));++groups;

    connect_action=0;nav_enabled=0;set_environment(0x1f80);
    nav_connect(scene.nav,tile(&scene,0),tile(&scene,1),0,0x9b);
    CHECK(observed_disabled);CHECK(GetLastError()==original_out_error && _mm_getcsr()==original_out_mxcsr);
    nav_enabled=1;++groups;

    connect_action=2;connect_calls=0;finder_calls=0;connect_depth=0;set_environment(0x1f80);
    nav_connect(scene.nav,tile(&scene,0),tile(&scene,1),0,0x9b);
    CHECK(connect_calls==2 && finder_calls==1);CHECK(GetLastError()==original_out_error && _mm_getcsr()==original_out_mxcsr);
    CHECK(TlsGetValue(nav_tls)==NULL);++groups;

    /* Recoverable original exceptions propagate while releasing owned scratch
     * and restoring TLS; the next ordinary scoped call still works. */
    connect_action=3;exception_allocation=NULL;set_environment(0x1f80);
    int caught=0;
    __try {
        nav_connect(scene.nav,tile(&scene,0),tile(&scene,1),0,0x9b);
    } __except(GetExceptionCode()==FIXTURE_EXCEPTION?EXCEPTION_EXECUTE_HANDLER:EXCEPTION_CONTINUE_SEARCH) {
        caught=1;
    }
    CHECK(caught && exception_allocation!=NULL && TlsGetValue(nav_tls)==NULL);
    CHECK(!HeapValidate(GetProcessHeap(),0,exception_allocation));
    connect_action=1;finder_calls=0;set_environment(0x1f80);
    nav_connect(scene.nav,tile(&scene,0),tile(&scene,1),0,0x9b);
    CHECK(!finder_calls && GetLastError()==original_out_error && _mm_getcsr()==original_out_mxcsr);
    CHECK(TlsGetValue(nav_tls)==NULL);++groups;

    /* Snapshot validation rejects malformed, aliased and read-inaccessible
     * inputs before making a usable index. No unsafe native callbacks execute. */
    for(unsigned i=0;i<8;++i){
        memset(&scope,0,sizeof(scope));
        if(i==0)scene.polys[1][0].bytes[30]=7;
        if(i==1)put16(&scene.polys[1][0],4,4);
        if(i==2)scene.verts[1][2]=nav_float_from_bits(UINT32_C(0x7f800000));
        if(i==3)putptr((unsigned char *)tile(&scene,1),0x10,scene.verts[1]);
        if(i==4)putptr(scene.nav,0x90,scene.tiles+1);
        if(i==6){
            for(unsigned p=0;p<256;++p){
                scene.polys[1][p].bytes[30]=2;
                put16(&scene.polys[1][p],4,0);put16(&scene.polys[1][p],6,1);
                put16(&scene.polys[1][p],16,0x8000);put16(&scene.polys[1][p],18,0x8000);
            }
        }
        if(i==7)put16(&scene.polys[0][31],16,0);
        void *target=i==5?(void *)(uintptr_t)0x1234:tile(&scene,1);
        CHECK(!nav_build_scope(&scope,scene.nav,tile(&scene,0),target,0));
        CHECK(!scope.index.valid);release_scope(&scope);
        scene.polys[1][0].bytes[30]=2;put16(&scene.polys[1][0],4,0);scene.verts[1][2]=0;
        putptr((unsigned char *)tile(&scene,1),0x10,scene.polys[1]);putptr(scene.nav,0x90,scene.tiles);
        if(i==6){
            for(unsigned p=0;p<256;++p){
                scene.polys[1][p].bytes[30]=p<32?2:0;
                put16(&scene.polys[1][p],16,p<32?0x8000:0);put16(&scene.polys[1][p],18,0);
            }
        }
        if(i==7)put16(&scene.polys[0][31],16,0x8000);
    }
    ++groups;
    CHECK(TlsFree(nav_tls));nav_tls=TLS_OUT_OF_INDEXES;free_scene(&scene);test_unwind_metadata();_mm_setcsr(saved_mxcsr);
    printf("{\"Passed\":true,\"Groups\":%u,\"Assertions\":%u,\"GameExecuted\":false,\"NativeAttachmentExecuted\":false,\"Scope\":\"Full compiled FPS/getup/nav implementation; synthetic packed tiles and typed originals only\"}\n",groups,assertions);
    return 0;
}
