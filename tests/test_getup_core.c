/* Independent mocked contract tests. No game image is loaded or executed. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../src/getup_core.h"

static unsigned long checks, cases;
#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"FAIL %s:%d: %s\n",__func__,__LINE__,#x); exit(1); } } while(0)

typedef struct Range { uintptr_t start; size_t size; } Range;
typedef struct SourceBlock { uint64_t before; void *items[GETUP_MAX_COUNT]; uint64_t after; } SourceBlock;
typedef struct Fixture {
    unsigned char object[0x940], frame[0x100], code[8];
    SourceBlock source;
    struct { uint64_t before; void *value; uint64_t after; } result;
    unsigned char object_before[0x940], frame_before[0x100];
    unsigned char source_before[sizeof(SourceBlock)];
    Range ranges[16]; unsigned range_count;
    GetupEnvironment env;
    GetupArray expected_source;
    void *self, *frame_arg, *result_arg;
    void *function_marker, *returned;
    unsigned reserve_calls, select_calls, free_calls, read_calls, write_calls;
    unsigned read_failure, write_failure, partial_read_failure;
    int reserve_mode;
    void *allocation; size_t allocation_size;
    int initial_count;
    uintptr_t expected_next_code;
} Fixture;
static Fixture f;
static unsigned char function_marker;

static void allow_range(const void *p,size_t n) {
    CHECK(f.range_count < 16 && p && n);
    f.ranges[f.range_count++] = (Range){(uintptr_t)p,n};
}
static int allowed(const void *p,size_t n) {
    uintptr_t at=(uintptr_t)p;
    if (!p || !n || n > UINTPTR_MAX-at) return 0;
    for(unsigned i=0;i<f.range_count;++i)
        if(at>=f.ranges[i].start && at-f.ranges[i].start<=f.ranges[i].size &&
           n<=f.ranges[i].size-(size_t)(at-f.ranges[i].start)) return 1;
    if(f.allocation && at>=(uintptr_t)f.allocation &&
       at-(uintptr_t)f.allocation<=f.allocation_size &&
       n<=f.allocation_size-(size_t)(at-(uintptr_t)f.allocation)) return 1;
    return 0;
}
static int page_ok(const void *p,size_t n,int writing) {
    uintptr_t at=(uintptr_t)p,end;
    if(!p || !n || n>UINTPTR_MAX-at) return 0;
    end=at+n;
    while(at<end) {
        MEMORY_BASIC_INFORMATION m; DWORD protection;
        if(VirtualQuery((const void *)at,&m,sizeof(m))!=sizeof(m) || m.State!=MEM_COMMIT ||
           (m.Protect&(PAGE_GUARD|PAGE_NOACCESS))) return 0;
        protection=m.Protect&0xffU;
        if(writing && protection!=PAGE_READWRITE && protection!=PAGE_WRITECOPY &&
           protection!=PAGE_EXECUTE_READWRITE && protection!=PAGE_EXECUTE_WRITECOPY) return 0;
        if(!writing && protection==PAGE_EXECUTE) return 0;
        uintptr_t next=(uintptr_t)m.BaseAddress+m.RegionSize;
        if(next<=at) return 0;
        at=next<end?next:end;
    }
    return 1;
}
static int mock_read(const void *p,void *out,size_t n) {
    ++f.read_calls;
    if(!allowed(p,n) || !page_ok(p,n,0)) return 0;
    if(f.read_failure==f.read_calls) {
        if(f.partial_read_failure && n>1) memcpy(out,p,n/2);
        return 0;
    }
    memcpy(out,p,n); return 1;
}
static int mock_writable(const void *p,size_t n) {
    ++f.write_calls;
    if(f.write_failure==f.write_calls) return 0;
    return allowed(p,n) && page_ok(p,n,1);
}
static void GETUP_CALL mock_release(void *p) {
    CHECK(f.allocation && p==(unsigned char *)f.allocation+8);
    uint64_t first,last;
    memcpy(&first,f.allocation,8);
    memcpy(&last,(unsigned char *)f.allocation+f.allocation_size-8,8);
    CHECK(first==UINT64_C(0xa0761d6478bd642f));
    CHECK(last==UINT64_C(0xe7037ed1a0b428db));
    ++f.free_calls;
    memset(f.allocation,0xdd,f.allocation_size);
    CHECK(HeapFree(GetProcessHeap(),0,f.allocation));
    f.allocation=NULL; f.allocation_size=0;
}
static void GETUP_CALL mock_reserve(GetupArray *copy,int32_t count,int32_t slack) {
    ++f.reserve_calls;
    CHECK(count==f.initial_count && copy->count==count && count>0 && slack==0);
    CHECK(copy->data==NULL && copy->capacity==0 && f.allocation==NULL);
    if(f.reserve_mode==1) return;
    size_t n=(size_t)count*sizeof(void *);
    f.allocation_size=n+16;
    f.allocation=HeapAlloc(GetProcessHeap(),0,f.allocation_size);
    CHECK(f.allocation!=NULL);
    uint64_t before=UINT64_C(0xa0761d6478bd642f),after=UINT64_C(0xe7037ed1a0b428db);
    memcpy(f.allocation,&before,8);
    memset((unsigned char *)f.allocation+8,0xcc,n);
    memcpy((unsigned char *)f.allocation+8+n,&after,8);
    copy->data=(void **)((unsigned char *)f.allocation+8);
    copy->capacity=f.reserve_mode==2?count-1:count;
}
static void *GETUP_CALL mock_select(void *self,GetupArray *copy) {
    ++f.select_calls;
    CHECK(self==f.self && f.select_calls==1);
    CHECK(copy->count==f.initial_count && copy->capacity==copy->count);
    uintptr_t actual_code;
    memcpy(&actual_code,(unsigned char *)f.frame_arg+GETUP_FRAME_CODE_OFFSET,sizeof(actual_code));
    CHECK(actual_code==f.expected_next_code);
    if(copy->count) {
        CHECK(copy->data && copy->data!=f.expected_source.data);
        CHECK(memcmp(copy->data,f.expected_source.data,(size_t)copy->count*sizeof(void *))==0);
        /* Exercise ownership transfer and mutating null-compaction semantics
         * on the copy. The source buffer must remain exactly unchanged. */
        int32_t count=0;
        for(int32_t i=0;i<copy->count;++i) if(copy->data[i]) copy->data[count++]=copy->data[i];
        copy->count=count;
        mock_release(copy->data);
        copy->data=NULL; copy->count=copy->capacity=0;
    } else CHECK(copy->data==NULL && f.allocation==NULL && f.reserve_calls==0);
    return f.returned;
}
static void setup(int count,int code_present) {
    CHECK(f.allocation==NULL);
    memset(&f,0,sizeof(f));
    memset(f.object,0x79,sizeof(f.object));
    memset(f.frame,0xa5,sizeof(f.frame));
    memset(f.code,0x6d,sizeof(f.code)); f.code[0]=0x16;
    f.source.before=UINT64_C(0x0123456789abcdef);
    f.source.after=UINT64_C(0xfedcba9876543210);
    for(int i=0;i<GETUP_MAX_COUNT;++i) f.source.items[i]=(void *)(uintptr_t)(0x10000U+16U*(unsigned)i);
    f.result.before=UINT64_C(0xcafebabedeadbeef);
    f.result.after=UINT64_C(0x5a5a55aa11224488);
    f.result.value=(void *)(uintptr_t)UINT64_C(0x3141592653589793);
    f.function_marker=&function_marker;
    f.env=(GetupEnvironment){f.function_marker,mock_reserve,mock_select,mock_release,mock_read,mock_writable};
    f.self=f.object; f.frame_arg=f.frame; f.result_arg=&f.result.value;
    f.initial_count=count;
    f.returned=count?f.source.items[count/2]:NULL;
    f.expected_source=(GetupArray){f.source.items,count,count};
    memcpy(f.object+GETUP_ARRAY_OFFSET,&f.expected_source,sizeof(f.expected_source));
    uintptr_t code=code_present?(uintptr_t)f.code:0;
    memcpy(f.frame+GETUP_FRAME_CODE_OFFSET,&code,sizeof(code));
    memcpy(f.frame+GETUP_FRAME_NATIVE_OFFSET,&f.function_marker,sizeof(f.function_marker));
    f.expected_next_code=code+(code!=0);
    allow_range(f.object,sizeof(f.object)); allow_range(f.frame,sizeof(f.frame));
    allow_range(f.code,sizeof(f.code)); allow_range(&f.source,sizeof(f.source));
    allow_range(&f.result,sizeof(f.result));
}
static void snapshot(void) {
    memcpy(f.object_before,f.object,sizeof(f.object));
    memcpy(f.frame_before,f.frame,sizeof(f.frame));
    memcpy(f.source_before,&f.source,sizeof(f.source));
}
static void verify_unchanged(int succeeded,void *previous_result) {
    CHECK(memcmp(f.object_before,f.object,sizeof(f.object))==0);
    CHECK(memcmp(f.source_before,&f.source,sizeof(f.source))==0);
    CHECK(f.result.before==UINT64_C(0xcafebabedeadbeef));
    CHECK(f.result.after==UINT64_C(0x5a5a55aa11224488));
    if(succeeded) {
        memcpy(f.frame_before+GETUP_FRAME_CODE_OFFSET,&f.expected_next_code,sizeof(f.expected_next_code));
        CHECK(f.result.value==f.returned);
    } else CHECK(f.result.value==previous_result);
    CHECK(memcmp(f.frame_before,f.frame,sizeof(f.frame))==0);
    CHECK(f.allocation==NULL);
}
static int run(const GetupEnvironment *env,void *self,void *frame,void *result,int expected) {
    snapshot(); void *previous=f.result.value;
    int accepted=getup_try_dispatch(env,self,frame,result);
    CHECK(accepted==expected);
    verify_unchanged(accepted,previous);
    ++cases; return accepted;
}
static void expect_fail(void) {
    run(&f.env,f.self,f.frame_arg,f.result_arg,0);
    CHECK(f.select_calls==0);
}
static void test_success(void) {
    for(int with_code=0;with_code<2;++with_code) for(int count=0;count<=9;++count) {
        setup(count,with_code);
        for(int i=0;i<count;++i) if(i%3==1) f.source.items[i]=NULL;
        f.returned=(void *)(uintptr_t)UINT64_C(0x1020304050607080);
        run(&f.env,f.self,f.frame_arg,f.result_arg,1);
        CHECK(f.select_calls==1 && f.reserve_calls==(unsigned)(count!=0));
        CHECK(f.free_calls==(unsigned)(count!=0));
        CHECK(f.code[0]==0x16 && f.code[1]==0x6d);
    }
    setup(12,1); memset(f.source.items,0,12*sizeof(void *)); f.returned=NULL;
    run(&f.env,f.self,f.frame_arg,f.result_arg,1);
    CHECK(f.select_calls==1 && f.free_calls==1);
    setup(GETUP_MAX_COUNT,1);
    run(&f.env,f.self,f.frame_arg,f.result_arg,1);
    CHECK(f.free_calls==1);
    setup(9,1); f.expected_source.capacity=37;
    memcpy(f.object+GETUP_ARRAY_OFFSET,&f.expected_source,sizeof(f.expected_source));
    run(&f.env,f.self,f.frame_arg,f.result_arg,1);
    CHECK(f.free_calls==1 && f.select_calls==1);
    /* A retained-capacity empty source has no allocation to transfer. */
    setup(0,0); f.expected_source.data=(void **)(uintptr_t)1; f.expected_source.capacity=15;
    memcpy(f.object+GETUP_ARRAY_OFFSET,&f.expected_source,sizeof(f.expected_source));
    run(&f.env,f.self,f.frame_arg,f.result_arg,1);
    CHECK(f.reserve_calls==0 && f.select_calls==1 && f.free_calls==0);
}
static void test_input_refusals(void) {
    setup(3,1); run(NULL,f.self,f.frame_arg,f.result_arg,0); CHECK(f.read_calls==0);
    for(unsigned member=0;member<6;++member) {
        setup(3,1); GetupEnvironment broken=f.env;
        if(member==0) broken.function=NULL; if(member==1) broken.reserve=NULL;
        if(member==2) broken.select=NULL; if(member==3) broken.release=NULL;
        if(member==4) broken.read=NULL; if(member==5) broken.writable=NULL;
        run(&broken,f.self,f.frame_arg,f.result_arg,0); CHECK(f.read_calls==0);
    }
    for(unsigned bad=0;bad<5;++bad) {
        setup(3,1);
        void *self=bad==0?NULL:f.self;
        void *frame=bad==1?NULL:f.frame_arg;
        void *result=bad==2?NULL:f.result_arg;
        if(bad==3) self=(void *)(UINTPTR_MAX-GETUP_ARRAY_OFFSET);
        if(bad==4) frame=(void *)(UINTPTR_MAX-GETUP_FRAME_NATIVE_OFFSET);
        run(&f.env,self,frame,result,0); CHECK(f.read_calls==0);
    }
    setup(3,1); void *different=(void *)(uintptr_t)0x12345;
    memcpy(f.frame+GETUP_FRAME_NATIVE_OFFSET,&different,sizeof(different)); expect_fail();
    CHECK(f.read_calls==1 && f.reserve_calls==0);
    setup(3,1); f.code[0]=0x15; expect_fail(); CHECK(f.reserve_calls==0);
    setup(3,1); uintptr_t code=UINTPTR_MAX; memcpy(f.frame+GETUP_FRAME_CODE_OFFSET,&code,sizeof(code)); expect_fail();
    setup(3,1); code=1; memcpy(f.frame+GETUP_FRAME_CODE_OFFSET,&code,sizeof(code)); expect_fail();
    setup(3,1); run(&f.env,(void *)(uintptr_t)1,f.frame_arg,f.result_arg,0);
    setup(3,1); run(&f.env,f.self,(void *)(uintptr_t)1,f.result_arg,0);
    setup(3,1); run(&f.env,f.self,f.frame_arg,(void *)(uintptr_t)1,0);
    for(unsigned malformed=0;malformed<7;++malformed) {
        setup(3,1); GetupArray a=f.expected_source;
        if(malformed==0) a.count=-1;
        if(malformed==1) a.count=GETUP_MAX_COUNT+1;
        if(malformed==2) a.capacity=2;
        if(malformed==3) a.capacity=-1;
        if(malformed==4) a.capacity=GETUP_MAX_COUNT+1;
        if(malformed==5) a.data=NULL;
        if(malformed==6) { a.count=0; a.capacity=-1; }
        memcpy(f.object+GETUP_ARRAY_OFFSET,&a,sizeof(a)); expect_fail();
        CHECK(f.reserve_calls==0 && f.free_calls==0);
    }
}
static void test_failures(void) {
    for(unsigned code_mode=0;code_mode<2;++code_mode) {
        unsigned final_read=code_mode?5:4;
        for(unsigned n=1;n<=final_read;++n) {
            setup(7,(int)code_mode); f.read_failure=n; expect_fail();
            CHECK(f.read_calls==n);
            CHECK(f.reserve_calls==(unsigned)(n==final_read));
            CHECK(f.free_calls==(unsigned)(n==final_read));
        }
    }
    setup(7,1); f.read_failure=5; f.partial_read_failure=1; expect_fail(); CHECK(f.free_calls==1);
    for(unsigned n=1;n<=3;++n) {
        setup(7,1); f.write_failure=n; expect_fail(); CHECK(f.write_calls==n);
        CHECK(f.reserve_calls==(unsigned)(n==3) && f.free_calls==(unsigned)(n==3));
    }
    setup(7,1); f.reserve_mode=1; expect_fail(); CHECK(f.reserve_calls==1 && f.free_calls==0);
    setup(7,1); f.reserve_mode=2; expect_fail(); CHECK(f.reserve_calls==1 && f.free_calls==1);
    setup(7,1); GetupArray a=f.expected_source; a.data=(void **)(UINTPTR_MAX-4);
    memcpy(f.object+GETUP_ARRAY_OFFSET,&a,sizeof(a)); expect_fail(); CHECK(f.free_calls==1);
}
static void test_windows_protection(void) {
    unsigned char *page=VirtualAlloc(NULL,4096,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    CHECK(page!=NULL); DWORD old;
    /* Real read-only frame: all metadata reads work, but Code is not writable. */
    setup(5,1); memcpy(page,f.frame,sizeof(f.frame)); allow_range(page,4096);
    CHECK(VirtualProtect(page,4096,PAGE_READONLY,&old));
    run(&f.env,f.self,page,f.result_arg,0); CHECK(f.reserve_calls==0);
    CHECK(memcmp(page,f.frame,sizeof(f.frame))==0);
    CHECK(VirtualProtect(page,4096,PAGE_READWRITE,&old));
    /* Real read-only result: refuse before allocating or consuming bytecode. */
    setup(5,1); memcpy(page,&f.result.value,sizeof(void *)); allow_range(page,4096);
    CHECK(VirtualProtect(page,4096,PAGE_READONLY,&old));
    run(&f.env,f.self,f.frame_arg,page,0); CHECK(f.reserve_calls==0);
    CHECK(memcmp(page,&f.result.value,sizeof(void *))==0);
    CHECK(VirtualProtect(page,4096,PAGE_READWRITE,&old));
    /* Protected source read fails after reserving; the temporary copy frees. */
    setup(5,1); allow_range(page,4096); GetupArray a={(void **)page,5,5};
    memcpy(f.object+GETUP_ARRAY_OFFSET,&a,sizeof(a));
    CHECK(VirtualProtect(page,4096,PAGE_NOACCESS,&old)); expect_fail(); CHECK(f.free_calls==1);
    CHECK(VirtualProtect(page,4096,PAGE_READWRITE,&old));
    /* Protected frame must never be dereferenced by the pure dispatcher. */
    setup(5,1); allow_range(page,4096);
    CHECK(VirtualProtect(page,4096,PAGE_NOACCESS,&old));
    run(&f.env,f.self,page,f.result_arg,0); CHECK(f.read_calls==1 && f.reserve_calls==0);
    CHECK(VirtualProtect(page,4096,PAGE_READWRITE,&old));
    /* PAGE_GUARD is rejected before a read, so no guard exception is raised. */
    setup(5,1); allow_range(page,4096);
    CHECK(VirtualProtect(page,4096,PAGE_READWRITE|PAGE_GUARD,&old));
    run(&f.env,f.self,page,f.result_arg,0); CHECK(f.read_calls==1 && f.reserve_calls==0);
    CHECK(VirtualProtect(page,4096,PAGE_READWRITE,&old));
    CHECK(VirtualFree(page,0,MEM_RELEASE));
}
static uint32_t random_state=0x7b653d59U;
static uint32_t next_random(void) {
    uint32_t x=random_state; x^=x<<13; x^=x>>17; x^=x<<5; return random_state=x;
}
static void test_randomized_source_preservation(void) {
    for(unsigned trial=0;trial<2048;++trial) {
        int count=(int)(next_random()%257);
        setup(count,(int)(next_random()&1));
        f.expected_source.capacity=count+(int)(next_random()%(unsigned)(GETUP_MAX_COUNT-count+1));
        memcpy(f.object+GETUP_ARRAY_OFFSET,&f.expected_source,sizeof(f.expected_source));
        for(int i=0;i<count;++i) {
            uint32_t x=next_random();
            f.source.items[i]=(x%4==0)?NULL:(void *)(uintptr_t)(0x20000U+16U*(x%31));
        }
        f.returned=count?f.source.items[next_random()%(unsigned)count]:NULL;
        run(&f.env,f.self,f.frame_arg,f.result_arg,1);
        CHECK(f.select_calls==1 && f.reserve_calls==(unsigned)(count!=0));
        CHECK(f.free_calls==(unsigned)(count!=0));
    }
}
int main(void) {
    CHECK(sizeof(void *)==8 && sizeof(GetupArray)==16);
    test_success(); test_input_refusals(); test_failures(); test_windows_protection();
    test_randomized_source_preservation();
    printf("{\"Passed\":true,\"Assertions\":%lu,\"Cases\":%lu,\"RandomizedCases\":2048,\"GameExecuted\":false,\"Scope\":\"Mocked core ABI, copying, ownership, fallback and real Windows protection guards; not equivalence proof for opaque game getter\"}\n",checks,cases);
    return 0;
}
