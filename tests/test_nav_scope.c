/* Independent packed-layout and scope-identity fixtures. No game execution. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../src/nav_scope.h"
static unsigned assertions,cases;
#define CHECK(x) do {++assertions;if(!(x)){fprintf(stderr,"FAIL %s:%d %s\n",__func__,__LINE__,#x);exit(1);}} while(0)
typedef struct Fixture {unsigned char tile[0xb0],data[4096],cluster[512];NavTileView view;size_t size;} Fixture;
static void u32(unsigned char *p,unsigned off,uint32_t x){memcpy(p+off,&x,4);}
static void ptr(unsigned char *p,unsigned off,const void *x){uintptr_t v=(uintptr_t)x;memcpy(p+off,&v,sizeof(v));}
static void capture(Fixture *f){memset(&f->view,0,sizeof(f->view));f->view.tile=f->tile;memcpy(f->view.tile_copy,f->tile,0xb0);memcpy(f->view.header,f->data,0x74);}
static Fixture *make_fixture(int all_sections,int clusters) {
    Fixture *f=calloc(1,sizeof(*f));CHECK(f!=NULL);
    u32(f->data,0,0x444e4156);u32(f->data,4,7);u32(f->data,0x18,3);u32(f->data,0x1c,6);
    u32(f->data,0x20,8);u32(f->data,0x24,2);u32(f->data,0x28,all_sections?1:0);
    u32(f->data,0x2c,all_sections?2:0);u32(f->data,0x30,all_sections?1:0);
    u32(f->data,0x34,all_sections?2:0);u32(f->data,0x38,all_sections?1:0);
    u32(f->data,0x3c,2);u32(f->data,0x70,clusters?1:0);u32(f->tile,0,0x25);
    ptr(f->tile,8,f->data);ptr(f->tile,0x58,f->data);
    /* Explicit native AddTile layout, independently specified from its ASM:
     * vertices12, polys32, links16, details12, detail vertices12, tris4,
     * BV nodes16, offmesh40, extra segments64, clusters20, cluster-map base.
     * The map has two entries here, fewer than three polygons. */
    unsigned char *at=f->data+0x74;
    ptr(f->tile,0x18,at);at+=6*12;
    ptr(f->tile,0x10,at);at+=3*32;
    ptr(f->tile,0x20,at);at+=8*16;
    ptr(f->tile,0x28,at);at+=2*12;
    ptr(f->tile,0x30,at);at+=(all_sections?1:0)*12;
    ptr(f->tile,0x38,at);at+=(all_sections?2:0)*4;
    ptr(f->tile,0x40,all_sections?at:NULL);at+=(all_sections?1:0)*16;
    ptr(f->tile,0x48,at);at+=(all_sections?2:0)*40;
    ptr(f->tile,0x50,at);at+=(all_sections?1:0)*64;
    ptr(f->tile,0x70,at);at+=(clusters?1:0)*20;
    ptr(f->tile,0x78,clusters?at:NULL);at+=(clusters?2:0)*2;
    f->size=(size_t)(at-f->data);CHECK(f->size<sizeof(f->data));u32(f->tile,0x60,(uint32_t)f->size);
    ptr(f->tile,0x98,f->cluster);u32(f->tile,0xa0,1);u32(f->tile,0xa4,4);
    capture(f);return f;
}
static void test_layout(void){
    for(int full=0;full<2;++full)for(int clusters=0;clusters<2;++clusters){
        Fixture *f=make_fixture(full,clusters);unsigned char original_tile[0xb0],original_header[0x74];
        memcpy(original_tile,f->tile,0xb0);memcpy(original_header,f->data,0x74);
        CHECK(nav_layout(&f->view)==1);CHECK(f->view.npoly==3 && f->view.nverts==6 && f->view.salt==0x25);
        CHECK(f->view.header_ptr==(uintptr_t)f->data && f->view.data_end==(uintptr_t)f->data+f->size);
        CHECK(memcmp(original_tile,f->tile,0xb0)==0 && memcmp(original_header,f->data,0x74)==0);
        const unsigned offsets[]={0x18,0x10,0x20,0x28,0x30,0x38,0x40,0x48,0x50,0x70,0x78};
        for(unsigned i=0;i<sizeof(offsets)/sizeof(offsets[0]);++i){
            NavTileView bad=f->view;uintptr_t old;memcpy(&old,bad.tile_copy+offsets[i],sizeof(old));old=old?old+4:(uintptr_t)f->data;
            memcpy(bad.tile_copy+offsets[i],&old,sizeof(old));CHECK(nav_layout(&bad)==0);++cases;
        }
        for(unsigned badcase=0;badcase<14;++badcase){
            NavTileView bad=f->view;
            if(badcase==0)u32(bad.header,0,0);
            if(badcase==1)u32(bad.header,4,8);
            if(badcase==2)u32(bad.header,0x18,0);
            if(badcase==3)u32(bad.header,0x18,(uint32_t)NAV_MAX_POLYS+1);
            if(badcase==4)u32(bad.header,0x1c,0);
            if(badcase==5)u32(bad.header,0x1c,(uint32_t)NAV_MAX_VERTICES+1);
            if(badcase==6)ptr(bad.tile_copy,0x58,f->data+4);
            if(badcase==7)u32(bad.tile_copy,0x60,0x73);
            if(badcase==8)u32(bad.tile_copy,0x60,64U*1024U*1024U+1);
            if(badcase==9)u32(bad.tile_copy,0x60,0x74);
            if(badcase==10)u32(bad.header,0x20,1048577);
            if(badcase==11)bad.tile=f->data+16;
            if(badcase==12){ptr(bad.tile_copy,8,(void *)(uintptr_t)1);ptr(bad.tile_copy,0x58,(void *)(uintptr_t)1);}
            if(badcase==13){ptr(bad.tile_copy,8,(void *)(UINTPTR_MAX-63));ptr(bad.tile_copy,0x58,(void *)(UINTPTR_MAX-63));}
            CHECK(nav_layout(&bad)==0);++cases;
        }
        free(f);++cases;
    }
    CHECK(nav_span(0x10000,1)==1 && nav_span(0xffff,1)==0 && nav_span(0x10000,0)==0);
    CHECK(nav_span(UINTPTR_MAX,1)==0 && nav_span(UINTPTR_MAX-1,1)==1);
    CHECK(nav_disjoint(0x10000,16,0x10010,16)==1 && nav_disjoint(0x10000,16,0x1000f,16)==0);
}
static void test_aliases(void){
    Fixture *a=make_fixture(1,1),*b=make_fixture(1,1);unsigned char nav[0xa8];
    CHECK(nav_layout(&a->view)==1 && nav_layout(&b->view)==1);
    CHECK(nav_views_disjoint(&a->view,&b->view,nav)==1);
    for(unsigned k=0;k<15;++k){
        NavTileView av=a->view,bv=b->view;void *nav_arg=nav;
        if(k==0){bv.header_ptr=av.header_ptr;bv.data_end=av.data_end;}
        if(k==1)bv.tile=av.tile;
        if(k==2)av.tile=(void *)(bv.header_ptr+8);
        if(k==3)bv.tile=(void *)(av.header_ptr+8);
        if(k==4)nav_arg=a->data;
        if(k==5)nav_arg=b->data;
        if(k==6)nav_arg=a->tile;
        if(k==7)nav_arg=b->tile;
        if(k==8)nav_arg=a->cluster;
        if(k==9)ptr(av.tile_copy,0x98,b->cluster);
        if(k==10)ptr(av.tile_copy,0x98,a->data);
        if(k==11)ptr(av.tile_copy,0x98,b->tile);
        if(k==12)u32(av.tile_copy,0xa0,5);
        if(k==13)u32(av.tile_copy,0xa4,1048577);
        if(k==14)ptr(av.tile_copy,0x98,NULL);
        CHECK(nav_views_disjoint(&av,&bv,nav_arg)==0);++cases;
    }
    CHECK(nav_views_disjoint(&a->view,&b->view,NULL)==0);
    CHECK(nav_views_disjoint(&a->view,&b->view,(void *)(uintptr_t)1)==0);
    free(a);free(b);
}
static void test_identity_and_queries(void){
    Fixture *a=make_fixture(1,1),*b=make_fixture(1,1);unsigned char nav[0xa8];NavScope s={0};
    CHECK(nav_layout(&a->view)==1 && nav_layout(&b->view)==1);
    s.nav=nav;s.source=a->view;s.target=b->view;
    const float *first=(const float *)a->view.verts_ptr,*last=(const float *)(a->view.verts_ptr+5*12);
    CHECK(nav_identity(&s.source)==1 && nav_identity(&s.target)==1);
    CHECK(nav_query_identity(&s,nav,a->tile,b->tile,first,last,0)==1);
    CHECK(nav_query_identity(&s,nav,a->tile,b->tile,last,first,2)==1);
    for(unsigned k=0;k<116;++k){
        a->data[k]^=0x40;CHECK(nav_identity(&s.source)==0);CHECK(nav_query_identity(&s,nav,a->tile,b->tile,first,last,0)==0);a->data[k]^=0x40;++cases;
        b->data[k]^=0x20;CHECK(nav_identity(&s.target)==0);b->data[k]^=0x20;++cases;
    }
    for(unsigned i=0;i<4;++i){const unsigned offsets[]={0,8,0x10,0x18};unsigned char saved[8];size_t bytes=i?8:4;
        memcpy(saved,a->tile+offsets[i],bytes);a->tile[offsets[i]]^=4;CHECK(nav_identity(&s.source)==0);memcpy(a->tile+offsets[i],saved,bytes);++cases;}
    for(unsigned k=0;k<11;++k){
        NavScope bad=s;void *nv=nav,*source=a->tile,*target=b->tile;const float *va=first,*vb=last;int32_t poly=0;
        if(k==0)bad.disabled=1;
        if(k==1)nv=a->cluster;
        if(k==2)source=b->tile;
        if(k==3)target=a->tile;
        if(k==4)va=(const float *)(a->view.verts_ptr-12);
        if(k==5)vb=(const float *)(a->view.verts_ptr+6*12);
        if(k==6)va=(const float *)(a->view.verts_ptr+1);
        if(k==7)vb=(const float *)(a->view.verts_ptr+4);
        if(k==8)poly=-1;
        if(k==9)poly=3;
        if(k==10)va=NULL;
        CHECK(nav_query_identity(&bad,nv,source,target,va,vb,poly)==0);++cases;
    }
    /* Native link construction legitimately changes these values. Such
     * changes must not invalidate immutable geometry identity. */
    u32(a->tile,4,77);u32(b->tile,4,22);
    u32((unsigned char *)a->view.polys_ptr,0,0xabcd);u32((unsigned char *)b->view.polys_ptr,0,0x1234);
    memset((void *)nav_ptr_at(a->tile,0x20),0xc5,16);
    ptr(a->tile,0x98,a->cluster+128);u32(a->tile,0xa0,2);u32(a->tile,0xa4,8);
    CHECK(nav_identity(&s.source)==1 && nav_identity(&s.target)==1);
    CHECK(nav_query_identity(&s,nav,a->tile,b->tile,first,last,0)==1);
    /* Use both core entry points on owned packed geometry as a smoke check;
     * polygons are zeroed, hence contain no external edges. */
    NavPortal records[18];NavIndex index;
    memset((void *)a->view.polys_ptr,0,3*32);
    CHECK(nav_build_index((NavPoly *)a->view.polys_ptr,3,(NavVertex *)a->view.verts_ptr,6,records,18,&index)==1);
    CHECK(nav_may_connect(&index,first,last,0)==0);
    free(a);free(b);
}
int main(void){
    CHECK(sizeof(uintptr_t)==8);test_layout();test_aliases();test_identity_and_queries();
    printf("{\"Passed\":true,\"Assertions\":%u,\"Cases\":%u,\"GameExecuted\":false,\"Scope\":\"Packed layout, alias refusals, live identity/header mutation, source query bounds and normal link-only mutation\",\"Limits\":\"Owned readable fixture memory only; runtime safe-read guards, TLS/ABI forwarding and concurrent geometry-content mutation are outside these pure scope tests\"}\n",assertions,cases);
    return 0;
}
