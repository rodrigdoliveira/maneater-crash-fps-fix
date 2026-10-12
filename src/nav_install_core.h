#ifndef MANEATER_PRIVATE_NAV_INSTALL_CORE_H
#define MANEATER_PRIVATE_NAV_INSTALL_CORE_H
#include <windows.h>
#include <stdint.h>
#include <string.h>
#include "nav_install_contract.h"

#define NI_MAX_THREADS 1024u
#define NI_MAX_PAGES (2u * NAV_INSTALL_HOOKS)
enum {
    NI_OK=0, NI_BAD_PLAN=1, NI_OPEN=2, NI_SUSPEND=3, NI_FOREIGN_SUSPEND=4,
    NI_GET_CONTEXT=5, NI_NEW_THREAD=6, NI_READ=7, NI_BYTES_CHANGED=8,
    NI_PROTECT=9, NI_BAD_IP=10, NI_SET_CONTEXT=11, NI_WRITE=12,
    NI_FLUSH=13, NI_RESTORE_PROTECT=14, NI_RESUME=15, NI_ROLLBACK=16
};
typedef struct NIThread {
    HANDLE handle;
    DWORD tid;
    DWORD previous_count;
    int owned;
    int context_changed;
    CONTEXT original;
    CONTEXT relocated;
} NIThread;
typedef struct NIPage { uint64_t address; DWORD original; int changed; } NIPage;
typedef struct NIResult {
    int code;
    DWORD win32_error;
    unsigned rollback_errors;
    unsigned resume_errors;
    unsigned threads_owned;
    unsigned contexts_moved;
    unsigned patch_attempts;
    unsigned pages;
    unsigned second_census_count;
    int installed;
    int fatal;
} NIResult;
typedef struct NIOps {
    DWORD (*suspend)(void *, HANDLE);
    DWORD (*resume)(void *, HANDLE);
    BOOL (*get_context)(void *, HANDLE, CONTEXT *);
    BOOL (*set_context)(void *, HANDLE, const CONTEXT *);
    BOOL (*read)(void *, uint64_t, void *, SIZE_T);
    BOOL (*write)(void *, uint64_t, const void *, SIZE_T);
    BOOL (*protect)(void *, uint64_t, SIZE_T, DWORD, DWORD *);
    BOOL (*flush)(void *, uint64_t, SIZE_T);
    BOOL (*census)(void *, DWORD *, unsigned, unsigned *);
    DWORD (*last_error)(void *);
} NIOps;
typedef struct NIWorkspace {
    NIThread threads[NI_MAX_THREADS];
    unsigned thread_count;
    DWORD census_ids[NI_MAX_THREADS];
    NIPage pages[NI_MAX_PAGES];
    unsigned page_count;
    uint8_t read_guard[NAV_INSTALL_MAX_GUARD];
    uint8_t read_patch[5];
    int attempted[NAV_INSTALL_HOOKS];
} NIWorkspace;

/* Caller has already verified all handles/identity/plan/trampolines and prefaulted
   this storage. These operations execute only in the external helper process.
   There is no allocation, logging, formatting, retry or target execution here. */
static void ni_error(NIResult *r, int code, const NIOps *o, void *u) {
    if (!r->code) { r->code=code; r->win32_error=o->last_error(u); }
}
static int ni_known_thread(const NIWorkspace *w, DWORD tid) {
    for (unsigned i=0;i<w->thread_count;i++) if (w->threads[i].tid==tid) return 1;
    return 0;
}
static int ni_relocate(const NavInstallShared *p, uint64_t ip, uint64_t *out) {
    *out=ip;
    for(unsigned k=0;k<NAV_INSTALL_HOOKS;k++) {
        const NavInstallPlan *h=&p->plans[k];
        if(ip>=h->target && ip<h->target+h->stolen_length) {
            for(unsigned n=0;n<h->n_ip;n++) if(ip==h->target+h->old_ip[n]) {
                *out=h->trampoline+h->new_ip[n]; return 1;
            }
            return 0;
        }
    }
    return 1;
}
static NIResult ni_transaction(const NavInstallShared *p, NIWorkspace *w,
                              const NIOps *o, void *u, SIZE_T page_size) {
    NIResult r; memset(&r,0,sizeof(r));
    memset(w->attempted,0,sizeof(w->attempted));
    w->page_count=0;
    if(!page_size || (page_size&(page_size-1)) || w->thread_count>NI_MAX_THREADS) {
        r.code=NI_BAD_PLAN; return r;
    }
    for(unsigned k=0;k<NAV_INSTALL_HOOKS;k++) {
        const NavInstallPlan *h=&p->plans[k];
        if(!h->guard_length || h->guard_length>NAV_INSTALL_MAX_GUARD ||
           h->stolen_length<5 || h->stolen_length>h->guard_length ||
           !h->n_ip || h->n_ip>NAV_INSTALL_MAX_IPS ||
           h->target>UINT64_MAX-h->guard_length) {
            r.code=NI_BAD_PLAN;return r;
        }
        uint64_t page=p->plans[k].target&~((uint64_t)page_size-1);
        if((p->plans[k].target&((uint64_t)page_size-1))+5>page_size) {
            r.code=NI_BAD_PLAN;return r;
        }
        unsigned n=0;while(n<w->page_count && w->pages[n].address!=page)n++;
        if(n==w->page_count) {
            if(n==NI_MAX_PAGES){r.code=NI_BAD_PLAN;return r;}
            memset(&w->pages[n],0,sizeof(w->pages[n]));w->pages[n].address=page;w->page_count++;
        }
    }
    r.pages=w->page_count;
    for(unsigned i=0;i<w->thread_count;i++) {
        w->threads[i].owned=0;w->threads[i].context_changed=0;
    }
    /* Suspension increments are owned individually, never inferred from IDs. */
    for(unsigned i=0;i<w->thread_count;i++) {
        NIThread *t=&w->threads[i];
        t->owned=0;t->context_changed=0;
        DWORD prev=o->suspend(u,t->handle);
        if(prev==(DWORD)-1){ni_error(&r,NI_SUSPEND,o,u);goto abort;}
        t->previous_count=prev;t->owned=1;r.threads_owned++;
        if(prev!=0){ni_error(&r,NI_FOREIGN_SUSPEND,o,u);goto abort;}
    }
    for(unsigned i=0;i<w->thread_count;i++) {
        NIThread *t=&w->threads[i];memset(&t->original,0,sizeof(t->original));
        t->original.ContextFlags=CONTEXT_CONTROL;
        if(!o->get_context(u,t->handle,&t->original)){ni_error(&r,NI_GET_CONTEXT,o,u);goto abort;}
        t->relocated=t->original;
        uint64_t ip;
        if(!ni_relocate(p,t->original.Rip,&ip)){ni_error(&r,NI_BAD_IP,o,u);goto abort;}
        t->relocated.Rip=ip;
    }
    /* A second bounded census rejects any currently live unowned thread. */
    {
        unsigned count=0;
        if(!o->census(u,w->census_ids,NI_MAX_THREADS,&count)){ni_error(&r,NI_NEW_THREAD,o,u);goto abort;}
        r.second_census_count=count;
        for(unsigned n=0;n<count;n++)if(!ni_known_thread(w,w->census_ids[n])) {
            ni_error(&r,NI_NEW_THREAD,o,u);goto abort;
        }
    }
    for(unsigned k=0;k<NAV_INSTALL_HOOKS;k++) {
        const NavInstallPlan *h=&p->plans[k];
        if(!o->read(u,h->target,w->read_guard,h->guard_length)){ni_error(&r,NI_READ,o,u);goto abort;}
        if(memcmp(w->read_guard,h->guard,h->guard_length)){ni_error(&r,NI_BYTES_CHANGED,o,u);goto abort;}
    }
    /* Stage write permissions for every distinct page before any IP/code change. */
    for(unsigned n=0;n<w->page_count;n++) {
        NIPage *pg=&w->pages[n];DWORD old;
        if(!o->protect(u,pg->address,page_size,PAGE_EXECUTE_READWRITE,&old)){ni_error(&r,NI_PROTECT,o,u);goto abort;}
        pg->original=old;pg->changed=1;
    }
    for(unsigned i=0;i<w->thread_count;i++) {
        NIThread *t=&w->threads[i];
        if(t->original.Rip!=t->relocated.Rip) {
            /* Treat even a reported failure as a possibly applied context. */
            t->context_changed=1;
            if(!o->set_context(u,t->handle,&t->relocated)){ni_error(&r,NI_SET_CONTEXT,o,u);goto abort;}
            r.contexts_moved++;
        }
    }
    for(unsigned k=0;k<NAV_INSTALL_HOOKS;k++) {
        const NavInstallPlan *h=&p->plans[k];
        w->attempted[k]=1;r.patch_attempts++;
        if(!o->write(u,h->target,h->patch5,5)){ni_error(&r,NI_WRITE,o,u);goto abort;}
        if(!o->read(u,h->target,w->read_patch,5)||memcmp(w->read_patch,h->patch5,5)) {
            ni_error(&r,NI_WRITE,o,u);goto abort;
        }
    }
    for(unsigned k=0;k<NAV_INSTALL_HOOKS;k++)if(!o->flush(u,p->plans[k].target,5)) {
        ni_error(&r,NI_FLUSH,o,u);goto abort;
    }
    for(unsigned n=0;n<w->page_count;n++) {
        NIPage *pg=&w->pages[n];DWORD old;
        if(!o->protect(u,pg->address,page_size,pg->original,&old)){ni_error(&r,NI_RESTORE_PROTECT,o,u);goto abort;}
        pg->changed=0;
    }
    r.installed=1;
    goto resume;
abort:
    /* If protection was restored before a later error, reopen it for rollback. */
    for(unsigned n=0;n<w->page_count;n++) {
        NIPage *pg=&w->pages[n];int needed=0;
        for(unsigned k=0;k<NAV_INSTALL_HOOKS;k++)
            if(w->attempted[k] && (p->plans[k].target&~((uint64_t)page_size-1))==pg->address)needed=1;
        if(needed&&!pg->changed) {
            DWORD old;
            if(o->protect(u,pg->address,page_size,PAGE_EXECUTE_READWRITE,&old))pg->changed=1;
            else r.rollback_errors++;
        }
    }
    for(unsigned k=0;k<NAV_INSTALL_HOOKS;k++)if(w->attempted[k]) {
        const NavInstallPlan *h=&p->plans[k];
        if(!o->write(u,h->target,h->original5,5))r.rollback_errors++;
        if(!o->read(u,h->target,w->read_patch,5)||memcmp(w->read_patch,h->original5,5))r.rollback_errors++;
        if(!o->flush(u,h->target,5))r.rollback_errors++;
    }
    for(unsigned i=0;i<w->thread_count;i++) {
        NIThread *t=&w->threads[i];
        if(t->context_changed) {
            if(!o->set_context(u,t->handle,&t->original))r.rollback_errors++;
            /* Retained trampoline remains valid if this restoration fails. */
            t->context_changed=0;
        }
    }
    for(unsigned n=0;n<w->page_count;n++) {
        NIPage *pg=&w->pages[n];DWORD old;
        if(pg->changed) {
            if(!o->protect(u,pg->address,page_size,pg->original,&old))r.rollback_errors++;
            else pg->changed=0;
        }
    }
resume:
    /* Exactly one attempt for each owned increment. Never resume-to-zero. */
    for(unsigned i=0;i<w->thread_count;i++) {
        NIThread *t=&w->threads[i];
        if(t->owned) {
            DWORD prev=o->resume(u,t->handle);
            if(prev==(DWORD)-1||prev!=t->previous_count+1){r.resume_errors++;if(!r.win32_error)r.win32_error=o->last_error(u);}
            t->owned=0;
        }
    }
    if(r.rollback_errors||r.resume_errors){r.fatal=1;r.installed=0;if(!r.code)r.code=r.resume_errors?NI_RESUME:NI_ROLLBACK;}
    return r;
}
#endif
