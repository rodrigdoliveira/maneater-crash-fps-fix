/* A separate native process fixture exercises the exact external WinAPI adapter.
   It calls the transaction core on a synthetic plan, never production validation.
   The production entry compiled below remains strict and rejects this target. */
#define wmain ni_unused_production_entry
#include "../src/nav_install_external.c"
#undef wmain
#include "nav_fixture_contract.h"
static int production_refuses_fixture(WinNI *w,const wchar_t *exe){
    wchar_t name[128],path[32768],result[32768],cmd[32768],sha[65];DWORD n=32768;
    HANDLE map=NULL;NavInstallShared *v=NULL;HANDLE mods=INVALID_HANDLE_VALUE;int ok=0;
    _snwprintf(name,128,L"Local\\ManeaterCodexAreaInstall_%lu_00000000000000000000000000000000",(unsigned long)w->pid);
    map=CreateFileMappingW(INVALID_HANDLE_VALUE,NULL,PAGE_READWRITE,0,sizeof(*v),name);
    if(!map||GetLastError()==ERROR_ALREADY_EXISTS)goto done;
    v=MapViewOfFile(map,FILE_MAP_ALL_ACCESS,0,0,sizeof(*v));if(!v)goto done;memset(v,0,sizeof(*v));
    v->magic=NAV_INSTALL_MAGIC;v->version=NAV_INSTALL_VERSION;v->byte_size=sizeof(*v);v->pid=w->pid;v->hook_count=NAV_INSTALL_HOOKS;
    FILETIME c,e,k,u;if(!GetProcessTimes(w->process,&c,&e,&k,&u))goto done;v->process_creation_filetime=ft64(c);
    mods=CreateToolhelp32Snapshot(TH32CS_SNAPMODULE,w->pid);if(mods==INVALID_HANDLE_VALUE)goto done;
    MODULEENTRY32W m;memset(&m,0,sizeof(m));m.dwSize=sizeof(m);if(!Module32FirstW(mods,&m))goto done;
    v->game_base=(uintptr_t)m.modBaseAddr;v->publisher_base=v->game_base;v->game_image_size=m.modBaseSize;v->publisher_image_size=m.modBaseSize;
    IMAGE_DOS_HEADER d;IMAGE_NT_HEADERS64 nt;
    if(!win_read(w,v->game_base,&d,sizeof(d))||!win_read(w,v->game_base+d.e_lfanew,&nt,sizeof(nt)))goto done;
    v->game_timestamp=nt.FileHeader.TimeDateStamp;v->publisher_timestamp=v->game_timestamp;
    unsigned char actual[32];wchar_t expected[65];for(unsigned i=0;i<65;i++)expected[i]=NI_GAME_SHA[i];
    if(!parse_hex(expected,v->game_sha256,32)||!QueryFullProcessImageNameW(w->process,0,path,&n)||!image_hash(path,actual)||!memcmp(actual,v->game_sha256,32))goto done;
    for(unsigned i=0;i<32;i++)_snwprintf(sha+i*2,3,L"%02X",actual[i]);sha[64]=0;
    LARGE_INTEGER q;QueryPerformanceCounter(&q);DWORD len=GetTempPathW(32768,result);
    if(!len || len>=32768)goto done;
    int added=_snwprintf(result+len,32768-len,L"maneater-area-fixture-refusal-%lu-%llx.json",(unsigned long)GetCurrentProcessId(),(unsigned long long)q.QuadPart);
    if(added<0 || (DWORD)added>=32768-len)goto done;
    InterlockedExchange((LONG*)&v->ready,1);
    _snwprintf(cmd,32768,L"\"%ls\" %lu \"%ls\" %ls \"%ls\"",exe,(unsigned long)w->pid,name,sha,result);
    STARTUPINFOW st;PROCESS_INFORMATION pi;memset(&st,0,sizeof(st));st.cb=sizeof(st);memset(&pi,0,sizeof(pi));
    if(!CreateProcessW(exe,cmd,NULL,NULL,FALSE,CREATE_NO_WINDOW,NULL,NULL,&st,&pi))goto done;CloseHandle(pi.hThread);
    if(WaitForSingleObject(pi.hProcess,15000)==WAIT_OBJECT_0){DWORD status;GetExitCodeProcess(pi.hProcess,&status);ok=status==3&&v->installer_state==NAV_INSTALL_PENDING;
        if(ok)fwprintf(stderr,L"Production-refusal result: %ls\n",result);
    }
    CloseHandle(pi.hProcess);
done:
    if(v)UnmapViewOfFile(v);if(map)CloseHandle(map);if(mods!=INVALID_HANDLE_VALUE)CloseHandle(mods);return ok;
}
int wmain(int argc,wchar_t**argv){
    if(argc!=3)return 2;
    wchar_t name[128],command[32768];LARGE_INTEGER q;QueryPerformanceCounter(&q);
    _snwprintf(name,128,L"Local\\ManeaterNavFixture_%lu_%llx",(unsigned long)GetCurrentProcessId(),(unsigned long long)q.QuadPart);
    HANDLE mapping=CreateFileMappingW(INVALID_HANDLE_VALUE,NULL,PAGE_READWRITE,0,sizeof(NavFixtureShared),name);
    if(!mapping||GetLastError()==ERROR_ALREADY_EXISTS)return 3;
    NavFixtureShared *s=MapViewOfFile(mapping,FILE_MAP_ALL_ACCESS,0,0,sizeof(*s));if(!s)return 4;memset(s,0,sizeof(*s));
    _snwprintf(command,32768,L"\"%ls\" \"%ls\"",argv[1],name);
    STARTUPINFOW st;PROCESS_INFORMATION pi;memset(&st,0,sizeof(st));st.cb=sizeof(st);memset(&pi,0,sizeof(pi));
    if(!CreateProcessW(argv[1],command,NULL,NULL,FALSE,CREATE_NO_WINDOW,NULL,NULL,&st,&pi))return 5;CloseHandle(pi.hThread);
    int exitcode=1;NIResult r;memset(&r,0,sizeof(r));
    for(unsigned i=0;i<500&&!s->install.ready;i++){if(WaitForSingleObject(pi.hProcess,0)==WAIT_OBJECT_0)goto done;Sleep(10);}
    if(!s->install.ready)goto done;
    memcpy(&plan,&s->install,sizeof(plan));WinNI w={0};w.pid=pi.dwProcessId;
    w.process=OpenProcess(PROCESS_QUERY_INFORMATION|PROCESS_VM_READ|PROCESS_VM_WRITE|PROCESS_VM_OPERATION|SYNCHRONIZE,FALSE,w.pid);if(!w.process)goto done;
    if(!production_refuses_fixture(&w,argv[2])){CloseHandle(w.process);goto done;}
    memset(&workspace,0,sizeof(workspace));if(!preopen_threads(&w)){CloseHandle(w.process);goto done;}
    Sleep(150);LONG before=s->heartbeat;SYSTEM_INFO si;GetSystemInfo(&si);
    r=ni_transaction(&plan,&workspace,&ops,&w,si.dwPageSize);
    for(unsigned i=0;i<workspace.thread_count;i++)CloseHandle(workspace.threads[i].handle);
    if(!r.installed||r.fatal||r.pages!=2||r.threads_owned<5){CloseHandle(w.process);goto done;}
    Sleep(350);
    if(s->errors||s->heartbeat<=before){CloseHandle(w.process);goto done;}
    for(unsigned i=0;i<NAV_INSTALL_HOOKS;i++)if(!s->body_calls[i]||!s->wrapper_calls[i]){CloseHandle(w.process);goto done;}
    printf("{\"external_process\":true,\"strict_production_refused_fixture\":true,\"threads_owned\":%u,\"unique_pages\":%u,\"contexts_moved\":%u,\"heartbeat_before\":%ld,\"heartbeat_after\":%ld,\"errors\":%ld,\"body_calls\":[%ld,%ld,%ld],\"wrapper_calls\":[%ld,%ld,%ld],\"all_passed\":true}\n",r.threads_owned,r.pages,r.contexts_moved,(long)before,(long)s->heartbeat,(long)s->errors,(long)s->body_calls[0],(long)s->body_calls[1],(long)s->body_calls[2],(long)s->wrapper_calls[0],(long)s->wrapper_calls[1],(long)s->wrapper_calls[2]);
    CloseHandle(w.process);exitcode=0;
done:
    InterlockedExchange((LONG*)&s->stop,1);
    if(WaitForSingleObject(pi.hProcess,5000)!=WAIT_OBJECT_0){fprintf(stderr,"fixture target did not exit\n");exitcode=7;}
    else{DWORD e;GetExitCodeProcess(pi.hProcess,&e);if(e)exitcode=8;}
    CloseHandle(pi.hProcess);UnmapViewOfFile(s);CloseHandle(mapping);return exitcode;
}
