#include "../src/nav_install_core.h"
#include <stdio.h>
#include <stdlib.h>
enum {OP_SUSPEND=1,OP_RESUME,OP_GET,OP_SET,OP_READ,OP_WRITE,OP_PROTECT,OP_FLUSH,OP_CENSUS};
typedef struct Mock {
    NavInstallShared plan;
    uint8_t bytes[NAV_INSTALL_HOOKS][16];
    DWORD counts[3];
    CONTEXT contexts[3];
    DWORD protections[3];
    unsigned calls[10];
    int fail_op,fail_n,second_fail_op,second_fail_n;
    int new_thread,partial_write,partial_context,unexpected_resume;
    unsigned writes;
} Mock;
static NIWorkspace w;
static unsigned assertions;
#define CHECK(x) do{assertions++;if(!(x)){fprintf(stderr,"FAIL line%d: %s\n",__LINE__,#x);exit(1);}}while(0)
static int fail(Mock*m,int op){unsigned n=++m->calls[op];return (m->fail_op==op&&n==(unsigned)m->fail_n)||(m->second_fail_op==op&&n==(unsigned)m->second_fail_n);}
static unsigned ti(HANDLE h){return (unsigned)(uintptr_t)h-1;}
static int hi(Mock*m,uint64_t a){for(unsigned i=0;i<NAV_INSTALL_HOOKS;i++)if(m->plan.plans[i].target==a)return (int)i;return -1;}
static unsigned pi(uint64_t a){return a==0x1000?0:a==0x2000?1:2;}
static DWORD ms(void*u,HANDLE h){Mock*m=u;if(fail(m,OP_SUSPEND))return(DWORD)-1;unsigned i=ti(h);return m->counts[i]++;}
static DWORD mr(void*u,HANDLE h){Mock*m=u;if(fail(m,OP_RESUME))return(DWORD)-1;unsigned i=ti(h);DWORD old=m->counts[i];if(old)m->counts[i]--;return m->unexpected_resume&&i==1?old+1:old;}
static BOOL mg(void*u,HANDLE h,CONTEXT*c){Mock*m=u;if(fail(m,OP_GET))return FALSE;*c=m->contexts[ti(h)];return TRUE;}
static BOOL mt(void*u,HANDLE h,const CONTEXT*c){Mock*m=u;if(fail(m,OP_SET)){if(m->partial_context)m->contexts[ti(h)]=*c;return FALSE;}m->contexts[ti(h)]=*c;return TRUE;}
static BOOL md(void*u,uint64_t a,void*b,SIZE_T n){Mock*m=u;if(fail(m,OP_READ))return FALSE;int i=hi(m,a);if(i<0||n>16)return FALSE;memcpy(b,m->bytes[i],n);return TRUE;}
static BOOL mw(void*u,uint64_t a,const void*b,SIZE_T n){Mock*m=u;int i=hi(m,a);if(i<0||n>16)return FALSE;m->writes++;if(fail(m,OP_WRITE)){if(m->partial_write)m->bytes[i][0]=*(const uint8_t*)b;return FALSE;}memcpy(m->bytes[i],b,n);return TRUE;}
static BOOL mp(void*u,uint64_t a,SIZE_T n,DWORD p,DWORD*old){(void)n;Mock*m=u;if(fail(m,OP_PROTECT))return FALSE;unsigned i=pi(a);*old=m->protections[i];m->protections[i]=p;return TRUE;}
static BOOL mf(void*u,uint64_t a,SIZE_T n){(void)a;(void)n;return !fail(u,OP_FLUSH);}
static BOOL mc(void*u,DWORD*ids,unsigned cap,unsigned*n){Mock*m=u;if(fail(m,OP_CENSUS))return FALSE;*n=m->new_thread?4:3;if(cap<*n)return FALSE;ids[0]=10;ids[1]=11;ids[2]=12;if(m->new_thread)ids[3]=99;return TRUE;}
static DWORD me(void*u){(void)u;return 123;}
static const NIOps o={ms,mr,mg,mt,md,mw,mp,mf,mc,me};
static void init(Mock*m){
    memset(m,0,sizeof(*m));memset(&w,0,sizeof(w));w.thread_count=3;
    const uint64_t a[NAV_INSTALL_HOOKS]={0x1000,0x2000,0x3000};
    for(unsigned i=0;i<NAV_INSTALL_HOOKS;i++){
        NavInstallPlan*p=&m->plan.plans[i];p->target=a[i];p->trampoline=0x9000+i*0x100;p->guard_length=12;p->stolen_length=i==2?7:9;
        p->n_ip=3;p->old_ip[0]=0;p->new_ip[0]=0;
        p->old_ip[1]=i==1?2:3;p->new_ip[1]=i==1?2:3;
        p->old_ip[2]=i==2?7:9;p->new_ip[2]=i==0?19:i==1?9:7;
        for(unsigned j=0;j<12;j++)p->guard[j]=(uint8_t)(0x40+i+j);
        memcpy(p->original5,p->guard,5);p->patch5[0]=0xe9;for(unsigned j=1;j<5;j++)p->patch5[j]=(uint8_t)(0xa0+i+j);
        memcpy(m->bytes[i],p->guard,12);
    }
    for(unsigned i=0;i<3;i++){w.threads[i].handle=(HANDLE)(uintptr_t)(i+1);w.threads[i].tid=10+i;m->protections[i]=PAGE_EXECUTE_READ;}
    m->contexts[0].Rip=0x1003;m->contexts[1].Rip=0x2002;m->contexts[2].Rip=0x3003;
}
static void balanced(Mock*m){for(unsigned i=0;i<3;i++)CHECK(m->counts[i]==0);CHECK(m->calls[OP_RESUME]<=m->calls[OP_SUSPEND]);}
static void stock(Mock*m){for(unsigned i=0;i<NAV_INSTALL_HOOKS;i++)CHECK(!memcmp(m->bytes[i],m->plan.plans[i].original5,5));for(unsigned i=0;i<3;i++)CHECK(m->protections[i]==PAGE_EXECUTE_READ);CHECK(m->contexts[0].Rip==0x1003);CHECK(m->contexts[1].Rip==0x2002);CHECK(m->contexts[2].Rip==0x3003);}
int main(void){
    Mock m;NIResult r;
    init(&m);r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(r.installed&&r.code==NI_OK&&!r.fatal);CHECK(r.pages==3&&r.threads_owned==3&&r.contexts_moved==3);balanced(&m);CHECK(m.contexts[0].Rip==0x9003);CHECK(m.contexts[1].Rip==0x9102);CHECK(m.contexts[2].Rip==0x9203);for(unsigned i=0;i<NAV_INSTALL_HOOKS;i++)CHECK(!memcmp(m.bytes[i],m.plan.plans[i].patch5,5));for(unsigned i=0;i<3;i++)CHECK(m.protections[i]==PAGE_EXECUTE_READ);
    const int failures[][3]={{OP_SUSPEND,2,NI_SUSPEND},{OP_GET,2,NI_GET_CONTEXT},{OP_SET,2,NI_SET_CONTEXT},{OP_PROTECT,2,NI_PROTECT},{OP_WRITE,2,NI_WRITE},{OP_FLUSH,2,NI_FLUSH},{OP_PROTECT,4,NI_RESTORE_PROTECT},{OP_READ,4,NI_WRITE},{OP_CENSUS,1,NI_NEW_THREAD},{OP_WRITE,3,NI_WRITE},{OP_FLUSH,3,NI_FLUSH},{OP_SET,3,NI_SET_CONTEXT},{OP_READ,6,NI_WRITE}};
    for(unsigned n=0;n<sizeof(failures)/sizeof(failures[0]);n++){
        init(&m);m.fail_op=failures[n][0];m.fail_n=failures[n][1];m.partial_write=1;m.partial_context=1;
        r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(!r.installed&&!r.fatal&&r.code==failures[n][2]);CHECK(!r.rollback_errors&&!r.resume_errors);balanced(&m);stock(&m);
        if(m.fail_op==OP_SUSPEND||m.fail_op==OP_GET||m.fail_op==OP_SET||m.fail_op==OP_CENSUS)CHECK(m.writes==0);
    }
    init(&m);m.new_thread=1;r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(r.code==NI_NEW_THREAD&&!r.installed&&m.writes==0);balanced(&m);stock(&m);
    init(&m);m.contexts[0].Rip=0x1001;r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(r.code==NI_BAD_IP&&!r.installed&&m.writes==0);balanced(&m);CHECK(m.contexts[0].Rip==0x1001);
    init(&m);m.contexts[1].Rip=0x2006;r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(r.code==NI_BAD_IP&&!r.installed&&m.writes==0);balanced(&m);CHECK(m.contexts[1].Rip==0x2006);
    init(&m);m.contexts[2].Rip=0x3004;r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(r.code==NI_BAD_IP&&!r.installed&&m.writes==0);balanced(&m);CHECK(m.contexts[2].Rip==0x3004);
    init(&m);m.counts[1]=2;r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(r.code==NI_FOREIGN_SUSPEND&&!r.installed);CHECK(m.counts[0]==0&&m.counts[1]==2&&m.counts[2]==0);CHECK(m.calls[OP_RESUME]==2);stock(&m);
    init(&m);m.bytes[1][7]^=1;r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(r.code==NI_BYTES_CHANGED&&!r.installed&&m.writes==0);balanced(&m);stock(&m);
    init(&m);m.bytes[2][7]^=1;r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(r.code==NI_BYTES_CHANGED&&!r.installed&&m.writes==0);balanced(&m);stock(&m);
    init(&m);m.fail_op=OP_RESUME;m.fail_n=2;r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(r.fatal&&!r.installed&&r.code==NI_RESUME&&r.resume_errors==1);CHECK(m.calls[OP_RESUME]==3);CHECK(m.counts[0]==0&&m.counts[1]==1&&m.counts[2]==0);
    init(&m);m.unexpected_resume=1;r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(r.fatal&&!r.installed&&r.code==NI_RESUME&&r.resume_errors==1);CHECK(m.calls[OP_RESUME]==3);balanced(&m);
    init(&m);m.fail_op=OP_WRITE;m.fail_n=2;m.second_fail_op=OP_SET;m.second_fail_n=4;
    r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(r.fatal&&!r.installed&&r.rollback_errors==1);balanced(&m);CHECK(m.contexts[0].Rip==0x9003);CHECK(m.contexts[1].Rip==0x2002);for(unsigned i=0;i<NAV_INSTALL_HOOKS;i++)CHECK(!memcmp(m.bytes[i],m.plan.plans[i].original5,5));
    /* Both patches on one page must restore one original protection exactly. */
    init(&m);m.plan.plans[1].target=0x1100;m.contexts[1].Rip=0x1102;m.plan.plans[2].target=0x1200;m.contexts[2].Rip=0x1203;
    r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(r.installed&&r.pages==1&&m.calls[OP_PROTECT]==2);balanced(&m);
    CHECK(m.contexts[0].Rip==0x9003&&m.contexts[1].Rip==0x9102);
    /* Workspace reuse cannot carry a stale suspension into an early abort. */
    init(&m);w.threads[2].owned=1;w.threads[2].context_changed=1;m.fail_op=OP_SUSPEND;m.fail_n=2;
    r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(r.code==NI_SUSPEND&&m.calls[OP_RESUME]==1);balanced(&m);stock(&m);
    init(&m);m.plan.plans[0].guard_length=NAV_INSTALL_MAX_GUARD+1;
    r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(r.code==NI_BAD_PLAN&&!r.installed&&!m.calls[OP_SUSPEND]&&!m.writes);
    init(&m);m.plan.plans[2].target=0x3ffe;
    r=ni_transaction(&m.plan,&w,&o,&m,4096);CHECK(r.code==NI_BAD_PLAN&&!r.installed&&!m.calls[OP_SUSPEND]&&!m.writes);
    printf("{\"assertions\":%u,\"cases\":28,\"hooks\":%u,\"all_passed\":true,\"mock_fault_injections\":true,\"game_executed\":false}\n",assertions,NAV_INSTALL_HOOKS);return 0;
}
