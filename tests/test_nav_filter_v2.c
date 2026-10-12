/* Independent differential test: immutable v1, v2 checked/trusted APIs,
 * and an assembly scalar-SSE oracle for original necessary conditions.
 * All memory belongs to this synthetic process; no game code is executed. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xmmintrin.h>

#define NavVertex V1NavVertex
#define NavPoly V1NavPoly
#define NavPortal V1NavPortal
#define NavIndex V1NavIndex
#define nav_float_contract v1_float_contract
#define nav_poly_size_contract v1_poly_size_contract
#define nav_vertex_size_contract v1_vertex_size_contract
#define nav_portal_size_contract v1_portal_size_contract
#define nav_float_bits v1_float_bits
#define nav_float_from_bits v1_float_from_bits
#define nav_finite v1_finite
#define nav_cardinal_side v1_cardinal_side
#define nav_poly_u16 v1_poly_u16
#define nav_build_index v1_build_index
#define nav_order_axis v1_order_axis
#define nav_may_connect v1_may_connect
#include "nav_filter_v1_reference.h"
#undef NavVertex
#undef NavPoly
#undef NavPortal
#undef NavIndex
#undef nav_float_contract
#undef nav_poly_size_contract
#undef nav_vertex_size_contract
#undef nav_portal_size_contract
#undef nav_float_bits
#undef nav_float_from_bits
#undef nav_finite
#undef nav_cardinal_side
#undef nav_poly_u16
#undef nav_build_index
#undef nav_order_axis
#undef nav_may_connect
#undef MANEATER_PRIVATE_NAV_FILTER_H
#include "../src/nav_filter.h"

static uint64_t assertions,queries,false_negatives,equality_failures,builder_cases,corruption_cases,ordered_portals,native_possible_queries;
static uint32_t seed=0x136d7813U;
#define CHECK(x) do { ++assertions; if(!(x)) { fprintf(stderr,"FAIL %s:%d %s\n",__func__,__LINE__,#x); exit(1); } } while(0)
static uint32_t random_u32(void){uint32_t x=seed;x^=x<<13;x^=x>>17;x^=x<<5;return seed=x;}
static float from_bits(uint32_t u){float f;memcpy(&f,&u,4);return f;}
static uint32_t as_bits(float f){uint32_t u;memcpy(&u,&f,4);return u;}
static void put_u16(uint8_t *p,uint16_t u){memcpy(p,&u,2);}
static uint16_t get_u16(const uint8_t *p){uint16_t u;memcpy(&u,p,2);return u;}
static int original_ja(float a,float b){unsigned char f;__asm__ volatile("comiss %2,%1; seta %0":"=qm"(f):"x"(a),"x"(b):"cc");return f;}
static int original_jc(float a,float b){unsigned char f;__asm__ volatile("comiss %2,%1; setb %0":"=qm"(f):"x"(a),"x"(b):"cc");return f;}
static float original_sub(float a,float b){__asm__ volatile("subss %1,%0":"+x"(a):"x"(b));return a;}
static float original_min(float a,float b){__asm__ volatile("minss %1,%0":"+x"(a):"x"(b));return a;}
static float original_max(float a,float b){__asm__ volatile("maxss %1,%0":"+x"(a):"x"(b));return a;}
static void original_sort(float a,float b,float *lo,float *hi){if(original_jc(a,b)){*lo=a;*hi=b;}else{*lo=b;*hi=a;}}
static int original_edge(float plane,float a,float b,const float va[3],const float vb[3],uint32_t side){
    unsigned ax=(side==0||side==4)?2:0,pa=(side==0||side==4)?0:2;
    float delta=from_bits(as_bits(original_sub(va[pa],plane))&0x7fffffffU),tol=from_bits(0x3c23d70aU);
    if(original_ja(delta,tol))return 0;
    float sl,sh,tl,th;original_sort(va[ax],vb[ax],&sl,&sh);original_sort(a,b,&tl,&th);
    return !original_jc(original_sub(original_min(th,sh),original_max(tl,sl)),tol);
}
static int original_tile(const NavPoly *p,size_t n,const NavVertex *v,const float a[3],const float b[3],uint32_t side){
    if(side!=0&&side!=2&&side!=4&&side!=6)return 1;
    unsigned ax=(side==0||side==4)?2:0,pa=(side==0||side==4)?0:2;
    for(size_t i=0;i<n;i++){unsigned count=p[i].bytes[30];for(unsigned j=0;j<count;j++){
        if(get_u16(p[i].bytes+16+j*2)!=(0x8000U|side))continue;
        unsigned x=get_u16(p[i].bytes+4+j*2),y=get_u16(p[i].bytes+4+((j+1)%count)*2);
        if(original_edge(v[x].xyz[pa],v[x].xyz[ax],v[y].xyz[ax],a,b,side))return 1;
    }}return 0;
}
static float random_finite(void){
    static const uint32_t special[]={0,0x80000000U,1,0x80000001U,0x007fffffU,0x00800000U,0x3c23d709U,0x3c23d70aU,0x3c23d70bU,0xbc23d70aU,0x7f7fffffU,0xff7fffffU};
    uint32_t x=random_u32();if((x&15U)<4)return from_bits(special[(x>>4)%12]);
    if((x&15U)==4){uint32_t u=random_u32();if((u&0x7f800000U)==0x7f800000U)u^=0x00800000U;return from_bits(u);}
    return (float)((int)(x%4097)-2048)/8.0f;
}
static float random_query(void){uint32_t x=random_u32();if((x&31U)==0)return from_bits(0x7fc00001U);if((x&31U)==1)return from_bits(0x7f800001U);if((x&31U)==2)return from_bits(0x7f800000U);return random_finite();}
static void interval(float a[3],float b[3],uint32_t side,float plane,float lo,float hi){
    memset(a,0,12);memset(b,0,12);unsigned ax=(side==0||side==4)?2:0,pa=(side==0||side==4)?0:2;
    a[pa]=b[pa]=plane;a[ax]=lo;b[ax]=hi;
}
static void check_order(const V1NavIndex *one,const NavIndex *two){
    CHECK(one->count==two->count);size_t offset=0;
    for(unsigned s=0;s<4;s++){CHECK(two->side_begin[s]==offset);size_t count=0;
        for(size_t i=0;i<one->count;i++)if(one->records[i].side==s*2){
            CHECK(offset+count<two->count);CHECK(!memcmp(one->records+i,two->records+offset+count,sizeof(NavPortal)));count++;ordered_portals++;
        }CHECK(two->side_count[s]==count);offset+=count;
    }CHECK(offset==two->count);
}
static __attribute__((noinline)) void compare_query(const V1NavIndex *one,const NavIndex *two,const float a[3],const float b[3],uint32_t side,int native_possible){
    float sa[3],sb[3];memcpy(sa,a,12);memcpy(sb,b,12);NavIndex saved=*two;
    unsigned controls=_mm_getcsr()&~0x3fU;
    int expected=v1_may_connect(one,a,b,side),checked=nav_may_connect(two,a,b,side),trusted=nav_may_connect_trusted(two,a,b,side);
    queries++;if(expected!=checked||expected!=trusted)equality_failures++;
    CHECK(expected==checked&&expected==trusted);
    if(native_possible)native_possible_queries++;
    if(native_possible&&(!checked||!trusted))false_negatives++;
    CHECK(!native_possible||(checked&&trusted));CHECK(!memcmp(sa,a,12)&&!memcmp(sb,b,12));CHECK(!memcmp(&saved,two,sizeof(saved)));CHECK((_mm_getcsr()&~0x3fU)==controls);
}
static void build_pair(const NavPoly *p,size_t n,const NavVertex *v,size_t nv,V1NavPortal *r1,NavPortal *r2,size_t cap,V1NavIndex *i1,NavIndex *i2){
    builder_cases++;int first=v1_build_index((const V1NavPoly*)p,n,(const V1NavVertex*)v,nv,r1,cap,i1),second=nav_build_index(p,n,v,nv,r2,cap,i2);
    CHECK(first==second);CHECK(i1->valid==i2->valid);CHECK(i1->count==i2->count);
    if(first)check_order(i1,i2);else{float a[3]={0,0,0},b[3]={1,0,1};CHECK(nav_may_connect(i2,a,b,0)==1);CHECK(nav_may_connect_trusted(i2,a,b,0)==1);}
}
static void test_boundaries(void){
    static const uint32_t bits[]={0,0x80000000U,1,0x80000001U,0x007fffffU,0x00800000U,0x3c23d708U,0x3c23d709U,0x3c23d70aU,0x3c23d70bU,0x3c23d70cU,0xbc23d70aU,0x7f7fffffU,0xff7fffffU,0x7f800000U,0xff800000U,0x7fc00001U,0x7f800001U};
    for(unsigned side=0;side<8;side+=2){NavPoly p={0};NavVertex v[2]={{{0,0,0}},{{1,0,1}}};V1NavPortal r1[6];NavPortal r2[6];V1NavIndex i1;NavIndex i2;float a[3],b[3];
        p.bytes[30]=2;put_u16(p.bytes+4,0);put_u16(p.bytes+6,1);put_u16(p.bytes+16,(uint16_t)(0x8000U|side));
        build_pair(&p,1,v,2,r1,r2,6,&i1,&i2);
        for(unsigned k=0;k<sizeof(bits)/sizeof(bits[0]);k++)for(unsigned where=0;where<3;where++){
            interval(a,b,side,where==0?from_bits(bits[k]):0,where==1?from_bits(bits[k]):0,where==2?from_bits(bits[k]):1);
            compare_query(&i1,&i2,a,b,side,original_tile(&p,1,v,a,b,side));
        }
        for(unsigned reverse=0;reverse<2;reverse++){interval(a,b,side,0,(float)reverse,(float)(1-reverse));compare_query(&i1,&i2,a,b,side,original_tile(&p,1,v,a,b,side));}
        v[0].xyz[0]=v[0].xyz[2]=-FLT_MAX;v[1].xyz[0]=v[1].xyz[2]=FLT_MAX;build_pair(&p,1,v,2,r1,r2,6,&i1,&i2);
        interval(a,b,side,FLT_MAX,-FLT_MAX,FLT_MAX);compare_query(&i1,&i2,a,b,side,original_tile(&p,1,v,a,b,side));
    }
}
static void test_random_tiles(void){
    for(unsigned trial=0;trial<1800;trial++){
        NavPoly p[64],saved_p[64];NavVertex v[384],saved_v[384];V1NavPortal r1[384];
        struct{uint64_t before;NavPortal records[384];uint64_t after;} r2;
        V1NavIndex i1;NavIndex i2;size_t n=random_u32()%65,nv=n*6;
        memset(p,0,sizeof(p));memset(v,0,sizeof(v));r2.before=UINT64_C(0x123456789abcdef0);r2.after=UINT64_C(0xfedcba9876543210);
        for(size_t i=0;i<nv;i++)for(unsigned j=0;j<3;j++)v[i].xyz[j]=random_finite();
        for(size_t i=0;i<n;i++){unsigned count=random_u32()%7;p[i].bytes[30]=(uint8_t)count;for(unsigned j=0;j<count;j++){
            put_u16(p[i].bytes+4+j*2,(uint16_t)(i*6+j));unsigned s=random_u32()%8;put_u16(p[i].bytes+16+j*2,(uint16_t)(s<4?0x8000U+s*2:s==4?0x8001U:s==5?0xffffU:s==6?0x9000U:0));
        }}memcpy(saved_p,p,sizeof(p));memcpy(saved_v,v,sizeof(v));build_pair(p,n,v,nv,r1,r2.records,384,&i1,&i2);
        CHECK(r2.before==UINT64_C(0x123456789abcdef0)&&r2.after==UINT64_C(0xfedcba9876543210));CHECK(!memcmp(p,saved_p,sizeof(p))&&!memcmp(v,saved_v,sizeof(v)));
        for(unsigned side=0;side<8;side+=2){float a[3],b[3];for(unsigned j=0;j<3;j++){a[j]=random_query();b[j]=random_query();}
            compare_query(&i1,&i2,a,b,side,original_tile(p,n,v,a,b,side));
            if(i1.count){const V1NavPortal *r=&r1[random_u32()%i1.count];interval(a,b,r->side,r->plane,r->axis_a,r->axis_b);compare_query(&i1,&i2,a,b,r->side,original_tile(p,n,v,a,b,r->side));}
        }
    }
}
static void test_builder_refusal(void){
    NavPoly p={0};NavVertex v[2]={{{0,0,0}},{{0,0,1}}};V1NavPortal r1[6];NavPortal r2[6];V1NavIndex i1;NavIndex i2;
    p.bytes[30]=2;put_u16(p.bytes+6,1);put_u16(p.bytes+16,0x8000);put_u16(p.bytes+18,0x8002);
    for(unsigned bad=0;bad<12;bad++){NavPoly copy=p;NavVertex verts[2];memcpy(verts,v,sizeof(v));size_t n=1,nv=2,cap=6;const NavPoly *pp=&copy;const NavVertex *vv=verts;
        if(bad==0)copy.bytes[30]=7;if(bad==1)put_u16(copy.bytes+4,2);if(bad==2)verts[1].xyz[1]=from_bits(0x7fc00001U);if(bad==3)cap=1;
        if(bad==4)n=NAV_MAX_POLYS+1;if(bad==5)nv=NAV_MAX_VERTICES+1;if(bad==6)cap=NAV_MAX_PORTALS+1;if(bad==7)pp=NULL;if(bad==8)vv=NULL;
        if(bad==9)verts[0].xyz[0]=from_bits(0x7f800001U);if(bad==10)verts[0].xyz[2]=from_bits(0x7f800000U);if(bad==11)verts[0].xyz[1]=from_bits(0xff800000U);
        build_pair(pp,n,vv,nv,r1,r2,cap,&i1,&i2);CHECK(!i2.valid&&!i2.count);
    }
    build_pair(NULL,0,NULL,0,r1,r2,0,&i1,&i2);float a[3]={0},b[3]={1,0,1};compare_query(&i1,&i2,a,b,0,0);
}
static void test_corruption(void){
    NavPoly p={0};NavVertex v[2]={{{0,0,0}},{{1,0,1}}};V1NavPortal r1[6];NavPortal r2[6];V1NavIndex i1;NavIndex i2;
    p.bytes[30]=2;put_u16(p.bytes+6,1);put_u16(p.bytes+16,0x8000);put_u16(p.bytes+18,0x8002);build_pair(&p,1,v,2,r1,r2,6,&i1,&i2);
    float a[3],b[3];interval(a,b,0,20,20,21);
    unsigned char *unreadable=VirtualAlloc(NULL,4096,MEM_RESERVE|MEM_COMMIT,PAGE_NOACCESS);CHECK(unreadable!=NULL);
    for(unsigned bad=0;bad<17;bad++){
        NavIndex x=i2;corruption_cases++;
        if(bad==0)x.valid=0;if(bad==1)x.count=NAV_MAX_PORTALS+1;if(bad==2)x.records=NULL;if(bad==3)x.trusted=0;
        if(bad==4)x.trusted^=1;if(bad==5)x.side_begin[0]=1;if(bad==6)x.side_begin[1]++;
        if(bad==7)x.side_count[0]=x.count+1;if(bad==8)x.side_count[3]++;
        if(bad==9)x.side_count[0]=SIZE_MAX;if(bad==10)x.side_begin[2]=SIZE_MAX;
        if(bad==11)x.count=SIZE_MAX;if(bad==12)x.side_count[0]=0;
        if(bad==13)x.side_begin[3]=x.count+1;if(bad==14)x.trusted=UINT32_MAX;
        if(bad==15){x.valid=2;x.records=(const NavPortal*)unreadable;}
        if(bad==16){x.trusted=0;x.records=(const NavPortal*)unreadable;}
        CHECK(nav_may_connect_trusted(&x,a,b,0)==1);
        if(bad==0||bad==1||bad==2||bad==11||bad==15)CHECK(nav_may_connect(&x,a,b,0)==1);
    }
    for(unsigned s=0;s<4;s++)for(unsigned field=0;field<2;field++){
        NavIndex x=i2;x.records=(const NavPortal*)unreadable;if(field)x.side_count[s]=SIZE_MAX;else x.side_begin[s]=SIZE_MAX;
        corruption_cases++;CHECK(nav_may_connect_trusted(&x,a,b,0)==1);
    }
    for(unsigned bad=0;bad<5;bad++){
        NavPortal copy[6];memcpy(copy,r2,sizeof(copy));NavIndex x=i2;x.records=copy;x.trusted=0;
        if(bad==0)copy[0].side=1;if(bad==1)copy[0].plane=from_bits(0x7fc00001U);if(bad==2)copy[0].axis_a=from_bits(0x7f800001U);
        if(bad==3)copy[0].axis_b=from_bits(0x7f800000U);if(bad==4)copy[0].plane=from_bits(0xff800000U);
        V1NavIndex base={(const V1NavPortal*)copy,x.count,1};corruption_cases++;
        CHECK(nav_may_connect(&x,a,b,0)==1);CHECK(v1_may_connect(&base,a,b,0)==1);CHECK(nav_may_connect_trusted(&x,a,b,0)==1);
    }
    const uint32_t invalid_side[]={1,3,5,7,8,0x8000U,UINT32_MAX};
    for(unsigned k=0;k<sizeof(invalid_side)/sizeof(invalid_side[0]);k++){corruption_cases++;CHECK(nav_may_connect_trusted(&i2,a,b,invalid_side[k])==1);CHECK(nav_may_connect(&i2,a,b,invalid_side[k])==1);}
    CHECK(nav_may_connect_trusted(NULL,a,b,0)==1);CHECK(nav_may_connect_trusted(&i2,NULL,b,0)==1);CHECK(nav_may_connect_trusted(&i2,a,NULL,0)==1);
    CHECK(VirtualFree(unreadable,0,MEM_RELEASE));
}
static volatile unsigned benchmark_sink;
static void benchmark(const char *name,unsigned flags_stride,int mixed,int possible){
    const size_t n=1024,nv=n*6,cap=nv;const unsigned repetitions=15000;
    NavPoly *p=calloc(n,sizeof(*p));NavVertex *v=calloc(nv,sizeof(*v));V1NavPortal *r1=calloc(cap,sizeof(*r1));NavPortal *r2=calloc(cap,sizeof(*r2));CHECK(p&&v&&r1&&r2);
    for(size_t i=0;i<n;i++){p[i].bytes[30]=6;for(unsigned j=0;j<6;j++){put_u16(p[i].bytes+4+j*2,(uint16_t)(i*6+j));v[i*6+j]=(NavVertex){{0,0,(float)(j&1)}};}
        if(i%flags_stride==0){unsigned side=mixed?(unsigned)(i/flags_stride%4)*2:0;put_u16(p[i].bytes+16,(uint16_t)(0x8000U|side));
            /* Every side's endpoint interval is [0,1]. */
            if(side==2||side==6){v[i*6].xyz[0]=0;v[i*6+1].xyz[0]=1;v[i*6].xyz[2]=v[i*6+1].xyz[2]=0;}
        }
    }
    V1NavIndex one;NavIndex two;LARGE_INTEGER freq,start,end;QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&start);for(unsigned k=0;k<120;k++)CHECK(v1_build_index((V1NavPoly*)p,n,(V1NavVertex*)v,nv,r1,cap,&one));QueryPerformanceCounter(&end);double build1=(double)(end.QuadPart-start.QuadPart)*1000/freq.QuadPart;
    QueryPerformanceCounter(&start);for(unsigned k=0;k<120;k++)CHECK(nav_build_index(p,n,v,nv,r2,cap,&two));QueryPerformanceCounter(&end);double build2=(double)(end.QuadPart-start.QuadPart)*1000/freq.QuadPart;
    check_order(&one,&two);float a[4][3],b[4][3];for(unsigned side=0;side<4;side++)interval(a[side],b[side],side*2,0,possible?0:20,possible?1:21);
    unsigned sum1=0,sum2=0,sum_checked=0;double timing[3];
    for(unsigned path=0;path<3;path++){
        QueryPerformanceCounter(&start);for(unsigned k=0;k<repetitions;k++){unsigned side=mixed?k%4:0;int r=path==0?v1_may_connect(&one,a[side],b[side],side*2):path==1?nav_may_connect(&two,a[side],b[side],side*2):nav_may_connect_trusted(&two,a[side],b[side],side*2);if(path==0)sum1+=(unsigned)r;else if(path==1)sum_checked+=(unsigned)r;else sum2+=(unsigned)r;}
        QueryPerformanceCounter(&end);timing[path]=(double)(end.QuadPart-start.QuadPart)*1000/freq.QuadPart;
    }CHECK(sum1==sum2&&sum1==sum_checked);benchmark_sink+=sum1+sum2+sum_checked;
    printf("{\"Benchmark\":\"%s\",\"TargetPolygons\":%zu,\"Portals\":%zu,\"Queries\":%u,\"V1Build120_ms\":%.6f,\"V2Build120_ms\":%.6f,\"V1CheckedQueries_ms\":%.6f,\"V2CheckedQueries_ms\":%.6f,\"V2TrustedQueries_ms\":%.6f,\"V2TrustedToV1Ratio\":%.6f,\"FPSInference\":false}\n",name,n,one.count,repetitions,build1,build2,timing[0],timing[1],timing[2],timing[0]?timing[2]/timing[0]:0);
    free(r2);free(r1);free(v);free(p);
}
int main(void){
    unsigned saved=_mm_getcsr();CHECK(sizeof(V1NavPortal)==sizeof(NavPortal));CHECK(sizeof(V1NavPoly)==sizeof(NavPoly));CHECK(sizeof(V1NavVertex)==sizeof(NavVertex));
    for(unsigned round=0;round<4;round++)for(unsigned denorm=0;denorm<4;denorm++){
        _mm_setcsr(0x1f80U|(round<<13)|((denorm&1)?0x40U:0)|((denorm&2)?0x8000U:0));
        test_boundaries();test_random_tiles();test_builder_refusal();test_corruption();
    }
    _mm_setcsr(0x1f80U);benchmark("mixed-side-sparse-misses",16,1,0);benchmark("mixed-side-dense-misses",1,1,0);benchmark("single-side-dense-misses",1,0,0);benchmark("mixed-side-all-possible",1,1,1);benchmark("single-side-all-possible",1,0,1);
    _mm_setcsr(saved);CHECK(false_negatives==0&&equality_failures==0);
    printf("{\"Passed\":true,\"Assertions\":%llu,\"Queries\":%llu,\"FalseNegatives\":%llu,\"V1V2DecisionDifferences\":%llu,\"BuilderCases\":%llu,\"CorruptionCases\":%llu,\"StableSidePortalChecks\":%llu,\"NativeCoarsePossibleQueries\":%llu,\"MXCSRModes\":16,\"GameExecuted\":false}\n",(unsigned long long)assertions,(unsigned long long)queries,(unsigned long long)false_negatives,(unsigned long long)equality_failures,(unsigned long long)builder_cases,(unsigned long long)corruption_cases,(unsigned long long)ordered_portals,(unsigned long long)native_possible_queries);
    return 0;
}
