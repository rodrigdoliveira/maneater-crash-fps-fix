/* Independent scalar-SSE necessary-predicate oracle and synthetic fixtures.
 * No game binary, proprietary code or live game memory is executed/read. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xmmintrin.h>
#include "../src/nav_filter.h"

static uint64_t assertions,queries,false_negatives,possible_queries,rejections,negative_controls;
#define CHECK(x) do { ++assertions; if(!(x)) { fprintf(stderr,"FAIL %s:%d %s\n",__func__,__LINE__,#x); exit(1); } } while(0)
static uint32_t seed=0x719c43e5U;
static uint32_t random_u32(void) { uint32_t x=seed;x^=x<<13;x^=x>>17;x^=x<<5;return seed=x; }
static float bits_float(uint32_t u) { float f;memcpy(&f,&u,4);return f; }
static uint32_t float_bits(float f) { uint32_t u;memcpy(&u,&f,4);return u; }

/* Use COMISS's actual CF/ZF results, not C's ordered comparisons. Unordered
 * sets CF/ZF/PF; JA is false, JC true. All fixture exceptions stay masked. */
static int native_ja(float left,float right) {
    unsigned char flag;
    __asm__ volatile("comiss %2, %1; seta %0" : "=qm"(flag) : "x"(left),"x"(right) : "cc");
    return flag;
}
static int native_jc(float left,float right) {
    unsigned char flag;
    __asm__ volatile("comiss %2, %1; setb %0" : "=qm"(flag) : "x"(left),"x"(right) : "cc");
    return flag;
}
static float native_sub(float left,float right) {
    __asm__ volatile("subss %1, %0" : "+x"(left) : "x"(right));return left;
}
static float native_min(float left,float right) {
    __asm__ volatile("minss %1, %0" : "+x"(left) : "x"(right));return left;
}
static float native_max(float left,float right) {
    __asm__ volatile("maxss %1, %0" : "+x"(left) : "x"(right));return left;
}
static void native_axis(float first,float second,__m128 *low,__m128 *high) {
    if(native_jc(first,second)) { *low=_mm_set_ss(first); *high=_mm_set_ss(second); }
    else { *low=_mm_set_ss(second); *high=_mm_set_ss(first); }
}
static int native_edge_necessary(float plane,float axis_a,float axis_b,
                                 const float va[3],const float vb[3],uint32_t side) {
    unsigned axis=(side==0 || side==4)?2:0;
    unsigned plane_axis=(side==0 || side==4)?0:2;
    const float tolerance=bits_float(0x3c23d70aU);
    __m128 sl,sh,tl,th;
    float delta=native_sub(va[plane_axis],plane);
    delta=bits_float(float_bits(delta)&0x7fffffffU);
    if(native_ja(delta,tolerance)) return 0;
    native_axis(va[axis],vb[axis],&sl,&sh);
    native_axis(axis_a,axis_b,&tl,&th);
    float overlap=native_sub(native_min(_mm_cvtss_f32(th),_mm_cvtss_f32(sh)),native_max(_mm_cvtss_f32(tl),_mm_cvtss_f32(sl)));
    return !native_jc(overlap,tolerance);
}
static int reference_records(const NavPortal *p,size_t n,const float a[3],const float b[3],uint32_t side) {
    if(side!=0 && side!=2 && side!=4 && side!=6) return 1;
    for(size_t i=0;i<n;++i)
        if(p[i].side==side && native_edge_necessary(p[i].plane,p[i].axis_a,p[i].axis_b,a,b,side)) return 1;
    return 0;
}
static uint16_t get_u16(const uint8_t *p) { uint16_t u;memcpy(&u,p,2);return u; }
static void put_u16(uint8_t *p,uint16_t u) { memcpy(p,&u,2); }
static int reference_tile(const NavPoly *polys,size_t n,const NavVertex *verts,
                          const float a[3],const float b[3],uint32_t side) {
    if(side!=0 && side!=2 && side!=4 && side!=6) return 1;
    const unsigned axis=(side==0 || side==4)?2:0,pa=(side==0 || side==4)?0:2;
    for(size_t i=0;i<n;++i) {
        unsigned count=polys[i].bytes[30];
        for(unsigned j=0;j<count;++j) {
            if(get_u16(polys[i].bytes+16+2*j)!=(uint16_t)(0x8000U|side)) continue;
            unsigned first=get_u16(polys[i].bytes+4+2*j),second=get_u16(polys[i].bytes+4+2*((j+1)%count));
            if(native_edge_necessary(verts[first].xyz[pa],verts[first].xyz[axis],verts[second].xyz[axis],a,b,side)) return 1;
        }
    }
    return 0;
}
static __attribute__((noinline)) int differential(const NavIndex *idx,const float a[3],const float b[3],uint32_t side,int original_possible) {
    float saved_a[3],saved_b[3]; unsigned char output_sentinel[128],saved_output[128];
    NavIndex saved_index=*idx;
    memcpy(saved_a,a,12);memcpy(saved_b,b,12);memset(output_sentinel,0x7d,sizeof(output_sentinel));memcpy(saved_output,output_sentinel,sizeof(saved_output));
    const unsigned controls=_mm_getcsr()&~0x3fU;
    int may=nav_may_connect(idx,a,b,side);
    CHECK(may==0 || may==1);++queries;
    if(original_possible) { ++possible_queries;if(!may)++false_negatives;CHECK(may==1); }
    if(!may)++rejections;
    CHECK(memcmp(a,saved_a,12)==0 && memcmp(b,saved_b,12)==0);
    CHECK(memcmp(idx,&saved_index,sizeof(*idx))==0);
    CHECK(memcmp(output_sentinel,saved_output,sizeof(saved_output))==0);
    CHECK((_mm_getcsr()&~0x3fU)==controls);
    return may;
}
static float random_float(void) {
    uint32_t x=random_u32();
    static const uint32_t special[]={0,0x80000000U,1,0x80000001U,0x007fffffU,0x00800000U,
        0x3c23d709U,0x3c23d70aU,0x3c23d70bU,0x7f7fffffU,0xff7fffffU,0x7f800000U,
        0xff800000U,0x7fc00001U,0x7f800001U,0xff800001U};
    if((x&15)<4) return bits_float(special[(x>>4)%16]);
    if((x&15)==4) return bits_float(random_u32());
    return (float)((int32_t)(x%4097)-2048)/8.0f;
}
static void query_from_interval(float a[3],float b[3],uint32_t side,float plane,float lo,float hi) {
    memset(a,0,12);memset(b,0,12);
    unsigned axis=(side==0 || side==4)?2:0,pa=(side==0 || side==4)?0:2;
    a[pa]=plane;b[pa]=plane;a[axis]=lo;b[axis]=hi;
}
static void test_native_nan_flags(void) {
    float nan=bits_float(0x7fc00001U);
    CHECK(native_ja(nan,0.01f)==0 && native_jc(nan,0.01f)==1);
}
static void test_boundaries(void) {
    static const uint32_t values[]={0,0x80000000U,1,0x80000001U,0x007fffffU,0x00800000U,
        0x3c23d708U,0x3c23d709U,0x3c23d70aU,0x3c23d70bU,0x3c23d70cU,
        0xbc23d709U,0xbc23d70aU,0xbc23d70bU,0x7f7fffffU,0xff7fffffU,
        0x7f800000U,0xff800000U,0x7fc00001U,0x7f800001U};
    for(unsigned s=0;s<4;++s) {
        uint32_t side=s*2;NavPortal p={0,0,1,side};NavIndex idx={.records=&p,.count=1,.valid=1};float a[3],b[3];
        for(unsigned k=0;k<sizeof(values)/sizeof(values[0]);++k) {
            query_from_interval(a,b,side,bits_float(values[k]),0,1);
            differential(&idx,a,b,side,reference_records(&p,1,a,b,side));
            query_from_interval(a,b,side,0,0,bits_float(values[k]));
            differential(&idx,a,b,side,reference_records(&p,1,a,b,side));
            query_from_interval(a,b,side,0,bits_float(values[k]),0);
            differential(&idx,a,b,side,reference_records(&p,1,a,b,side));
            p.plane=bits_float(values[k]);p.axis_a=0;p.axis_b=1;query_from_interval(a,b,side,0,0,1);
            differential(&idx,a,b,side,reference_records(&p,1,a,b,side));p.plane=0;
            p.axis_a=bits_float(values[k]);p.axis_b=1;
            differential(&idx,a,b,side,reference_records(&p,1,a,b,side));p.axis_a=0;
        }
        query_from_interval(a,b,side,0,1,0);CHECK(differential(&idx,a,b,side,1)==1);
        p.axis_a=1;p.axis_b=0;CHECK(differential(&idx,a,b,side,1)==1);
        p.axis_a=p.axis_b=0;CHECK(differential(&idx,a,b,side,0)==0);
        p.plane=-FLT_MAX;query_from_interval(a,b,side,FLT_MAX,0,1);
        int may=differential(&idx,a,b,side,0);
        float delta=native_sub(FLT_MAX,-FLT_MAX);
        if((float_bits(delta)&0x7f800000U)==0x7f800000U)CHECK(may==1);
        /* Directed rounding can saturate to a finite maximum; only an actual
         * nonfinite SSE intermediate must force the uncertain path. */
    }
}
static void test_random_records(void) {
    for(unsigned trial=0;trial<10000;++trial) {
        NavPortal p[12];size_t n=random_u32()%13;
        for(size_t i=0;i<n;++i) p[i]=(NavPortal){random_float(),random_float(),random_float(),(random_u32()%4)*2};
        NavIndex idx={.records=p,.count=n,.valid=1};float a[3],b[3];
        for(unsigned j=0;j<3;++j) { a[j]=random_float();b[j]=random_float(); }
        uint32_t side=(random_u32()%4)*2;
        differential(&idx,a,b,side,reference_records(p,n,a,b,side));
        if(n && trial%3==0) {
            size_t i=random_u32()%n;side=p[i].side;
            query_from_interval(a,b,side,p[i].plane,p[i].axis_a,p[i].axis_b);
            differential(&idx,a,b,side,reference_records(p,n,a,b,side));
        }
    }
}
static void set_poly(NavPoly *p,unsigned count,unsigned first_vert,uint16_t side_flag) {
    memset(p->bytes,0x6d,32);p->bytes[30]=(uint8_t)count;
    for(unsigned j=0;j<count;++j) {put_u16(p->bytes+4+2*j,(uint16_t)(first_vert+j));put_u16(p->bytes+16+2*j,side_flag);}
}
static void test_builder(void) {
    NavPoly polys[2],saved_polys[2];NavVertex verts[6],saved_verts[6];
    struct { uint64_t before;NavPortal records[12];uint64_t after; } out;
    NavIndex idx;float a[3],b[3];
    for(unsigned j=0;j<6;++j) verts[j]=(NavVertex){{0,(float)j,(float)(j%3)}};
    set_poly(&polys[0],3,0,0x8000);set_poly(&polys[1],3,3,0x8000);
    /* All six flagged edges must be retained, including later edges that a
     * first-edge-only index would wrongly omit. */
    memset(&out,0xa7,sizeof(out));out.before=0x123456789abcdef0ULL;out.after=0xfedcba9876543210ULL;
    memcpy(saved_polys,polys,sizeof(polys));memcpy(saved_verts,verts,sizeof(verts));
    CHECK(nav_build_index(polys,2,verts,6,out.records,12,&idx)==1 && idx.count==6 && idx.valid==1);
    CHECK(memcmp(saved_polys,polys,sizeof(polys))==0 && memcmp(saved_verts,verts,sizeof(verts))==0);
    CHECK(out.before==0x123456789abcdef0ULL && out.after==0xfedcba9876543210ULL);
    for(unsigned i=0;i<6;++i) { CHECK(out.records[i].plane==verts[i].xyz[0]);CHECK(out.records[i].axis_a==verts[i].xyz[2]); }
    query_from_interval(a,b,0,0,0,2);CHECK(differential(&idx,a,b,0,reference_tile(polys,2,verts,a,b,0))==1);
    /* Native plane reads the first endpoint only. The second's wildly
     * different plane must not suppress a potentially connecting edge. */
    set_poly(&polys[0],2,0,0);put_u16(polys[0].bytes+16,0x8000);
    verts[0]=(NavVertex){{0,0,0}};verts[1]=(NavVertex){{10000,0,2}};
    CHECK(nav_build_index(polys,1,verts,2,out.records,12,&idx)==1 && idx.count==1);
    query_from_interval(a,b,0,0,0,2);CHECK(differential(&idx,a,b,0,1)==1);
    set_poly(&polys[0],3,0,0);put_u16(polys[0].bytes+20,0x8000);
    verts[0]=(NavVertex){{0,0,2}};verts[1]=(NavVertex){{0,0,40}};verts[2]=(NavVertex){{0,0,0}};
    CHECK(nav_build_index(polys,1,verts,3,out.records,12,&idx)==1 && idx.count==1);
    query_from_interval(a,b,0,0,0,2);CHECK(differential(&idx,a,b,0,1)==1);
    set_poly(&polys[0],4,0,0);put_u16(polys[0].bytes+16,0x8000);put_u16(polys[0].bytes+20,0x8000);
    for(unsigned j=0;j<4;++j)verts[j]=(NavVertex){{0,0,(float)(j<2?j:8+j)}};
    CHECK(nav_build_index(polys,1,verts,4,out.records,12,&idx)==1 && idx.count==2);
    query_from_interval(a,b,0,0,10,11);
    CHECK(reference_tile(polys,1,verts,a,b,0)==1);
    CHECK(differential(&idx,a,b,0,1)==1);
    NavIndex deliberately_incomplete=idx;deliberately_incomplete.count=1;
    CHECK(nav_may_connect(&deliberately_incomplete,a,b,0)==0);++negative_controls;
    for(unsigned bad=0;bad<10;++bad) {
        set_poly(&polys[0],2,0,0x8000);verts[0]=(NavVertex){{0,0,0}};verts[1]=(NavVertex){{0,0,1}};
        size_t np=1,nv=2,cap=12;const NavPoly *pp=polys;const NavVertex *vv=verts;NavPortal *rr=out.records;
        if(bad==0)polys[0].bytes[30]=7;
        if(bad==1)put_u16(polys[0].bytes+4,2);
        if(bad==2)verts[1].xyz[1]=bits_float(0x7fc00001U);
        if(bad==3)cap=1;
        if(bad==4)np=NAV_MAX_POLYS+1;
        if(bad==5)nv=NAV_MAX_VERTICES+1;
        if(bad==6)cap=NAV_MAX_PORTALS+1;
        if(bad==7)pp=NULL;
        if(bad==8)vv=NULL;
        if(bad==9)rr=NULL;
        idx=(NavIndex){.records=out.records,.count=6,.valid=1};CHECK(nav_build_index(pp,np,vv,nv,rr,cap,&idx)==0);
        CHECK(idx.valid==0 && idx.count==0);CHECK(nav_may_connect(&idx,a,b,0)==1);
    }
    CHECK(nav_build_index(NULL,0,NULL,0,NULL,0,&idx)==1 && idx.valid==1 && idx.count==0);
    CHECK(differential(&idx,a,b,0,0)==0);
    CHECK(nav_build_index(NULL,0,NULL,0,NULL,0,NULL)==0);
}
static void test_random_tiles(void) {
    for(unsigned trial=0;trial<3000;++trial) {
        NavPoly polys[16],saved_polys[16];NavVertex verts[96],saved_verts[96];NavPortal records[96];NavIndex idx;
        size_t np=random_u32()%17,nv=np*6;
        for(size_t i=0;i<nv;++i) for(unsigned j=0;j<3;++j) verts[i].xyz[j]=(float)((int)(random_u32()%129)-64)/8.0f;
        size_t expected=0;
        for(size_t i=0;i<np;++i) {
            unsigned count=random_u32()%7;set_poly(&polys[i],count,(unsigned)i*6,0);
            for(unsigned j=0;j<count;++j) {
                uint32_t value=random_u32()%8;uint16_t flag;
                if(value<4) {flag=(uint16_t)(0x8000U+value*2);++expected;}
                else {static const uint16_t other[]={0,0x8001,0x9000,0xffff};flag=other[value-4];}
                put_u16(polys[i].bytes+16+2*j,flag);
            }
        }
        memcpy(saved_polys,polys,sizeof(polys));memcpy(saved_verts,verts,sizeof(verts));
        CHECK(nav_build_index(polys,np,verts,nv,records,96,&idx)==1 && idx.count==expected);
        CHECK(memcmp(saved_polys,polys,sizeof(polys))==0 && memcmp(saved_verts,verts,sizeof(verts))==0);
        for(unsigned j=0;j<4;++j) {
            float a[3],b[3];for(unsigned k=0;k<3;++k){a[k]=random_float();b[k]=random_float();}
            uint32_t side=j*2;differential(&idx,a,b,side,reference_tile(polys,np,verts,a,b,side));
        }
    }
}
static void test_guard_refusal(void) {
    NavPortal p={0,0,1,0};NavIndex idx={.records=&p,.count=1,.valid=1};float a[3],b[3];query_from_interval(a,b,0,0,0,1);
    CHECK(nav_may_connect(NULL,a,b,0)==1);CHECK(nav_may_connect(&idx,NULL,b,0)==1);CHECK(nav_may_connect(&idx,a,NULL,0)==1);
    for(unsigned invalid=0;invalid<3;++invalid) {NavIndex bad=idx;if(invalid==0)bad.valid=0;if(invalid==1)bad.count=NAV_MAX_PORTALS+1;if(invalid==2)bad.records=NULL;CHECK(differential(&bad,a,b,0,1)==1);}
    const uint32_t sides[]={1,3,5,7,8,0x8000U,0x10000U,UINT32_MAX};
    for(unsigned i=0;i<sizeof(sides)/sizeof(sides[0]);++i)CHECK(differential(&idx,a,b,sides[i],1)==1);
    p.side=1;CHECK(differential(&idx,a,b,0,1)==1);p.side=0;
    p.plane=bits_float(0x7f800001U);CHECK(differential(&idx,a,b,0,1)==1);
}
static void benchmark(const char *name,unsigned np,unsigned flag_stride,unsigned query_count,unsigned nominal_negative_percent,int layered) {
    NavPoly *polys=calloc(np,sizeof(*polys));NavVertex *verts=calloc((size_t)np*6,sizeof(*verts));NavPortal *records=calloc((size_t)np*6,sizeof(*records));
    CHECK(polys && verts && records);NavIndex idx;LARGE_INTEGER freq,start,finish;QueryPerformanceFrequency(&freq);
    for(unsigned i=0;i<np;++i) {
        set_poly(&polys[i],6,i*6,0);
        for(unsigned j=0;j<6;++j) verts[(size_t)i*6+j]=(NavVertex){{0,(float)(layered?i*10:0),(float)(j%2)}};
        if(i%flag_stride==0)put_u16(polys[i].bytes+16,0x8000);
    }
    QueryPerformanceCounter(&start);CHECK(nav_build_index(polys,np,verts,(size_t)np*6,records,(size_t)np*6,&idx)==1);QueryPerformanceCounter(&finish);
    double build_ms=(double)(finish.QuadPart-start.QuadPart)*1000.0/freq.QuadPart;
    unsigned skipped=0;QueryPerformanceCounter(&start);
    for(unsigned q=0;q<query_count;++q) {
        float a[3],b[3];int intended_negative=(q%100)<nominal_negative_percent;
        query_from_interval(a,b,0,0,intended_negative?20:0,intended_negative?21:1);if(layered){a[1]=b[1]=10000;}
        if(!nav_may_connect(&idx,a,b,0))++skipped;
    }
    QueryPerformanceCounter(&finish);double filter_ms=(double)(finish.QuadPart-start.QuadPart)*1000.0/freq.QuadPart;
    printf("{\"Benchmark\":\"%s\",\"TargetPolygons\":%u,\"TargetEdgeSlots\":%u,\"IndexedPortals\":%zu,\"Queries\":%u,\"NominalNegativePercent\":%u,\"OriginalFinderScansAvoided\":%u,\"OriginalFinderCallsRetained\":%u,\"AvoidedNativeEdgeScanIterationsForProvenMisses\":%llu,\"FilterPortalVisitUpperBound\":%llu,\"Build_ms\":%.6f,\"FilterQueries_ms\":%.6f,\"FPSInference\":false}\n",
        name,np,np*6,idx.count,query_count,nominal_negative_percent,skipped,query_count-skipped,
        (unsigned long long)skipped*np*6,(unsigned long long)query_count*idx.count,build_ms,filter_ms);
    free(records);free(verts);free(polys);
}
int main(void) {
    uint16_t endian=1;CHECK(*(uint8_t *)&endian==1);unsigned saved_csr=_mm_getcsr();
    for(unsigned rounding=0;rounding<4;++rounding) for(unsigned denormal=0;denormal<4;++denormal) {
        _mm_setcsr(0x1f80U|(rounding<<13)|((denormal&1)?0x40U:0)|((denormal&2)?0x8000U:0));
        test_native_nan_flags();test_boundaries();test_random_records();test_builder();test_random_tiles();test_guard_refusal();
    }
    _mm_setcsr(0x1f80U);
    benchmark("sparse-portals-80-percent-horizontal-misses",1024,16,500,80,0);
    benchmark("dense-all-possible",1024,1,500,0,0);
    benchmark("dense-all-horizontal-misses",1024,1,500,100,0);
    benchmark("layered-identical-horizontal-intervals",1024,1,500,0,1);
    benchmark("small-target-one-query",1,1,1,100,0);
    _mm_setcsr(saved_csr);CHECK(false_negatives==0);
    printf("{\"Passed\":true,\"Assertions\":%llu,\"DifferentialQueries\":%llu,\"NativeCoarsePossibleQueries\":%llu,\"ConservativeRejections\":%llu,\"FalseNegatives\":%llu,\"FirstEdgeOnlyNegativeControls\":%llu,\"MXCSRModes\":16,\"GameExecuted\":false,\"Scope\":\"Necessary-predicate rejection only; no full height/output algorithm replacement or runtime TLS/memory-guard coverage\"}\n",
        (unsigned long long)assertions,(unsigned long long)queries,(unsigned long long)possible_queries,(unsigned long long)rejections,(unsigned long long)false_negatives,(unsigned long long)negative_controls);
    return 0;
}
