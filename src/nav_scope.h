#ifndef MANEATER_PRIVATE_NAV_SCOPE_H
#define MANEATER_PRIVATE_NAV_SCOPE_H
#include "nav_filter.h"

/* Private per-call snapshots. Geometry is owned by the executing native
 * ConnectExtLinks call; neither it nor its guarded cluster helper mutates it.
 * No object, tile pointer or index survives that call. */
typedef struct NavTileView {
    const void *tile;
    unsigned char tile_copy[0xb0];
    unsigned char header[0x74];
    uintptr_t header_ptr, polys_ptr, verts_ptr, data_end;
    uint32_t salt, npoly, nverts;
} NavTileView;
typedef struct NavScope {
    void *nav;
    NavTileView source, target;
    NavIndex index;
    void *allocation;
    unsigned queries, rejected, disabled;
} NavScope;

static uintptr_t nav_ptr_at(const unsigned char *b, size_t o) {
    uintptr_t v; memcpy(&v,b+o,sizeof(v)); return v;
}
static uint32_t nav_u32_at(const unsigned char *b, size_t o) {
    uint32_t v; memcpy(&v,b+o,sizeof(v)); return v;
}
static int nav_span(uintptr_t a,size_t n) {
    return a>=0x10000 && n && n<=UINTPTR_MAX-a;
}
static int nav_disjoint(uintptr_t a,size_t n,uintptr_t b,size_t m) {
    return nav_span(a,n) && nav_span(b,m) && (a+n<=b || b+m<=a);
}
/* Loader-created packed section layout: validating this is stronger than
 * accepting merely readable, possibly aliased vertex and polygon pointers. */
static int nav_layout(NavTileView *v) {
    const unsigned char *t=v->tile_copy, *h=v->header;
    const unsigned offsets[]={0x18,0x10,0x20,0x28,0x30,0x38,0x40,0x48,0x50,0x70,0x78};
    const unsigned counts[]={7,6,8,9,10,11,12,13,14,28,6};
    const unsigned strides[]={12,32,16,12,12,4,16,40,64,20,2};
    uintptr_t at;
    uint32_t data_size=nav_u32_at(t,0x60);
    v->header_ptr=nav_ptr_at(t,8); v->polys_ptr=nav_ptr_at(t,0x10);
    v->verts_ptr=nav_ptr_at(t,0x18); v->salt=nav_u32_at(t,0);
    v->npoly=nav_u32_at(h,0x18); v->nverts=nav_u32_at(h,0x1c);
    if(nav_u32_at(h,0)!=0x444e4156 || nav_u32_at(h,4)!=7 ||
       !v->npoly || v->npoly>NAV_MAX_POLYS || !v->nverts || v->nverts>NAV_MAX_VERTICES ||
       nav_ptr_at(t,0x58)!=v->header_ptr || data_size<0x74 || data_size>64U*1024U*1024U ||
       !nav_span(v->header_ptr,data_size))return 0;
    v->data_end=v->header_ptr+data_size; at=v->header_ptr+0x74;
    for(unsigned i=0;i<sizeof(offsets)/sizeof(offsets[0]);++i) {
        uint32_t n=nav_u32_at(h,counts[i]*4U);
        uintptr_t p=nav_ptr_at(t,offsets[i]);
        /* BV tree and cluster mapping are null when their counts are zero. */
        int absent=(i==6 && n==0) || (i==10 && nav_u32_at(h,0x70)==0);
        if(n>1048576U || (!absent && p!=at) || (absent && p!=0))return 0;
        /* Its base must follow the cluster records; map length is not part of
         * the filter's read set and differs for off-mesh polygons. */
        if(i==10)n=0;
        size_t bytes=(size_t)n*strides[i];
        if(bytes>v->data_end-at)return 0;
        at+=bytes;
    }
    return nav_disjoint((uintptr_t)v->tile,0xb0,v->header_ptr,data_size);
}
static int nav_views_disjoint(const NavTileView *a,const NavTileView *b,void *nav) {
    size_t as=a->data_end-a->header_ptr,bs=b->data_end-b->header_ptr;
    if(!nav_disjoint(a->header_ptr,as,b->header_ptr,bs) ||
       !nav_disjoint((uintptr_t)a->tile,0xb0,(uintptr_t)b->tile,0xb0) ||
       !nav_disjoint((uintptr_t)a->tile,0xb0,b->header_ptr,bs) ||
       !nav_disjoint((uintptr_t)b->tile,0xb0,a->header_ptr,as) ||
       !nav_disjoint((uintptr_t)nav,0xa8,a->header_ptr,as) ||
       !nav_disjoint((uintptr_t)nav,0xa8,b->header_ptr,bs) ||
       !nav_disjoint((uintptr_t)nav,0xa8,(uintptr_t)a->tile,0xb0) ||
       !nav_disjoint((uintptr_t)nav,0xa8,(uintptr_t)b->tile,0xb0))return 0;
    const NavTileView *tiles[2]={a,b};
    for(unsigned i=0;i<2;++i) {
        const unsigned char *t=tiles[i]->tile_copy;
        uintptr_t p=nav_ptr_at(t,0x98);
        uint32_t count=nav_u32_at(t,0xa0), cap=nav_u32_at(t,0xa4);
        if(count>cap || cap>1048576U || (cap && !p))return 0;
        if(cap && (!nav_disjoint(p,(size_t)cap*16,a->header_ptr,as) ||
                   !nav_disjoint(p,(size_t)cap*16,b->header_ptr,bs) ||
                   !nav_disjoint(p,(size_t)cap*16,(uintptr_t)a->tile,0xb0) ||
                   !nav_disjoint(p,(size_t)cap*16,(uintptr_t)b->tile,0xb0) ||
                   !nav_disjoint(p,(size_t)cap*16,(uintptr_t)nav,0xa8)))return 0;
    }
    uint32_t ac=nav_u32_at(a->tile_copy,0xa4),bc=nav_u32_at(b->tile_copy,0xa4);
    if(ac && bc && !nav_disjoint(nav_ptr_at(a->tile_copy,0x98),(size_t)ac*16,
                               nav_ptr_at(b->tile_copy,0x98),(size_t)bc*16))return 0;
    return 1;
}
/* Only identity and immutable header fields are compared. firstLink and free
 * list/cluster fields are expected to change during successful native calls. */
static int nav_identity(const NavTileView *v) {
    const unsigned char *t=(const unsigned char *)v->tile;
    return nav_u32_at(t,0)==v->salt && nav_ptr_at(t,8)==v->header_ptr &&
        nav_ptr_at(t,0x10)==v->polys_ptr && nav_ptr_at(t,0x18)==v->verts_ptr &&
        memcmp((const void *)v->header_ptr,v->header,sizeof(v->header))==0;
}
static int nav_query_identity(const NavScope *s,void *nav,void *source,void *target,
                              const float *va,const float *vb,int32_t poly) {
    uintptr_t a=(uintptr_t)va,b=(uintptr_t)vb,base=s->source.verts_ptr;
    size_t bytes=(size_t)s->source.nverts*12;
    return !s->disabled && nav==s->nav && source==s->source.tile && target==s->target.tile &&
        poly>=0 && (uint32_t)poly<s->source.npoly && a>=base && b>=base &&
        a-base<bytes && b-base<bytes && (a-base)%12==0 && (b-base)%12==0 &&
        nav_identity(&s->source) && nav_identity(&s->target);
}
#endif
