/* Authored inert DLLs/loader only. No game or production mod is loaded. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#if defined(FIXTURE_PROXY)
__attribute__((section(".dxgifwd"),used))
const unsigned char fixture_export_space[65536]={'M','E','C','F','F','W','D','1'};
int Placeholder(void){return -1;}
#elif defined(FIXTURE_BACKEND)
#define ARGS uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,uint64_t f,uint64_t g,uint64_t h
#define VALUE (a+3*b+5*c+7*d+11*e+13*f+17*g+19*h)
uint64_t First(ARGS){return VALUE+100;}
uint64_t Second(ARGS){return VALUE+200;}
uint64_t Third(ARGS){return VALUE+300;}
#else
typedef uint64_t (*Call)(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t);
static unsigned checks;
static int check(HMODULE m,LPCSTR symbol,uint64_t add){
    Call fn=(Call)(uintptr_t)GetProcAddress(m,symbol);
    ++checks;return fn&&fn(1,2,3,4,5,6,7,8)==UINT64_C(454)+add;
}
int wmain(int argc,wchar_t **argv){
    if(argc!=7)return 2;
    HMODULE m=LoadLibraryW(argv[1]);if(!m){fprintf(stderr,"fixture load failed %lu\n",GetLastError());return 3;}
    unsigned a=(unsigned)wcstoul(argv[2],NULL,10),b=(unsigned)wcstoul(argv[3],NULL,10),c=(unsigned)wcstoul(argv[4],NULL,10);
    int third=wcstoul(argv[5],NULL,10)!=0,alias=wcstoul(argv[6],NULL,10)!=0;
    if(!check(m,"CreateDXGIFactory",100)||!check(m,"CreateDXGIFactory1",200)||
       !check(m,MAKEINTRESOURCEA(a),100)||!check(m,MAKEINTRESOURCEA(b),200)||!check(m,MAKEINTRESOURCEA(c),300))return 4;
    if(third&&!check(m,"CreateDXGIFactory2",300))return 5;
    if(alias&&!check(m,"AliasFactory",200))return 6;
    if(GetProcAddress(m,"FunctionThatDoesNotExist"))return 7;
    if(!FreeLibrary(m))return 8;
    printf("PASS: %u name/ordinal forwarding calls preserve eight arguments and 64-bit results.\n",checks);return 0;
}
#endif
