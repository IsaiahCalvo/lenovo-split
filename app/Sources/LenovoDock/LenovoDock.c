#include "LenovoDock.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef CFTypeRef (*CreateFn)(CFAllocatorRef,io_service_t);
typedef IOReturn (*DPFn)(CFTypeRef,uint32_t,void *,uint32_t);
typedef struct { CFTypeRef device; LenovoDockState *state; DPFn read,write; uint64_t usbID; } Link;
static uint64_t refreshedUSB=0;
static uint8_t refreshedSource[128];
void lenovo_dock_forget_host_refresh(void) { refreshedUSB=0; }
static int fail(Link *l,const char *what, uint32_t rc) {
 snprintf(l->state->error,sizeof(l->state->error),"%s (0x%08x)",what,rc);return -1;
}
static int number(io_service_t s,CFStringRef key) {
 CFTypeRef v=IORegistryEntryCreateCFProperty(s,key,NULL,0);int out=-1;
 if(v){if(CFGetTypeID(v)==CFNumberGetTypeID())CFNumberGetValue(v,kCFNumberIntType,&out);CFRelease(v);}return out;
}
static uint64_t dock_id(void) {
 io_iterator_t it=0; if(IOServiceGetMatchingServices(0,IOServiceMatching("IOUSBHostDevice"),&it))return 0;
 io_service_t s;uint64_t found=0;
 while((s=IOIteratorNext(it))) {
  if(number(s,CFSTR("idVendor"))==0x17ef && number(s,CFSTR("idProduct"))==0xa38f)IORegistryEntryGetRegistryEntryID(s,&found);
  IOObjectRelease(s);
 }
 IOObjectRelease(it);return found;
}
int lenovo_dock_connected(void) { return dock_id()!=0; }
static int rd(Link*l,uint32_t addr,void*data,uint32_t size) {
 if(!size||size>16)return fail(l,"Invalid read size",size);
 memset(data,0xa5,size);IOReturn rc=l->read(l->device,addr,data,size);
 return rc?fail(l,"Could not read dock",rc):0;
}
static int wr(Link*l,uint32_t addr,const void*data,uint32_t size) {
 if((addr!=0x4b2&&addr!=0x4b8&&addr!=0x4bc&&addr!=0x4c0)||!size||size>16)return fail(l,"Denied mailbox write",addr);
 IOReturn rc=l->write(l->device,addr,(void*)data,size);return rc?fail(l,"Dock mailbox write failed",rc):0;
}
static int command(Link*l,uint8_t op) {
 if(op!=1&&op!=2&&op!=0x21&&op!=0x31)return fail(l,"Denied command",op);
 uint8_t cmd=op|0x80;if(wr(l,0x4b2,&cmd,1))return -1;
 for(int i=0;i<30;i++){
  uint8_t result[2];if(rd(l,0x4b2,result,2))return -1;
  if(!(result[0]&0x80))return result[1]&&!(op==2&&result[1]==4)?fail(l,"Dock command failed",result[1]):0;
  usleep(100000);
 }
 return fail(l,"Dock command timed out",op);
}
static int memread(Link*l,uint32_t addr,uint8_t*data,uint32_t size) {
 for(uint32_t off=0;off<size;){uint32_t n=size-off;if(n>16)n=16;
  uint32_t at=addr+off;
  if(wr(l,0x4bc,&at,4)||wr(l,0x4b8,&n,4)||command(l,0x31)||rd(l,0x4c0,data+off,n))return -1;
  off+=n;
 }return 0;
}
static int openlink(Link*l) {
 CreateFn create=(CreateFn)dlsym(RTLD_DEFAULT,"IODPDeviceCreateWithService");
 l->read=(DPFn)dlsym(RTLD_DEFAULT,"IODPDeviceReadDPCD");l->write=(DPFn)dlsym(RTLD_DEFAULT,"IODPDeviceWriteDPCD");
 if(!create||!l->read||!l->write)return fail(l,"DisplayPort API unavailable",0);
 io_iterator_t it=0;if(IOServiceGetMatchingServices(0,IOServiceMatching("DCPDPDeviceProxy"),&it))return fail(l,"No DisplayPort device",0);
 io_service_t s,chosen=0;int count=0;
 while((s=IOIteratorNext(it))){
  CFTypeRef loc=IORegistryEntryCreateCFProperty(s,CFSTR("Location"),NULL,0);
  CFTypeRef supported=IORegistryEntryCreateCFProperty(s,CFSTR("IODPDeviceUserInterfaceSupported"),NULL,0);
  if(loc&&CFEqual(loc,CFSTR("External"))&&supported&&CFEqual(supported,kCFBooleanTrue)){
   count++;if(!chosen){chosen=s;IOObjectRetain(chosen);}
  }
  if(loc)CFRelease(loc);if(supported)CFRelease(supported);IOObjectRelease(s);
 }IOObjectRelease(it);
 if(count!=1){if(chosen)IOObjectRelease(chosen);return fail(l,"Expected one external DisplayPort path",count);}
 l->device=create(NULL,chosen);IOObjectRelease(chosen);
 return l->device?0:fail(l,"Could not open external DisplayPort path",0);
}
// Publish the wide timing on the Mac when the dock rebuilds its passthrough
// EDID on host reconnect. This changes a temporary macOS override, not firmware.
static int refresh_host_edid(Link *l, const uint8_t original[128]) {
 // Repeating SetVirtualEDIDMode temporarily takes the display offline. Only
 // refresh once for a given physical USB connection and monitor EDID.
 if(refreshedUSB==l->usbID && !memcmp(refreshedSource,original,128))return 0;
 typedef IOReturn (*SetEdidFn)(CFTypeRef,uint32_t,CFDataRef);
 CreateFn create=(CreateFn)dlsym(RTLD_DEFAULT,"IOAVServiceCreateWithService");
 SetEdidFn set=(SetEdidFn)dlsym(RTLD_DEFAULT,"IOAVServiceSetVirtualEDIDMode");
 if(!create||!set)return fail(l,"Mac display refresh is unavailable",0);
 static const uint8_t header[]={0,255,255,255,255,255,255,0};
 if(memcmp(original,header,8))return fail(l,"Invalid source display data",0);
 uint8_t e[128];memcpy(e,original,128);
 // Exact 3840x1080@60 timing measured from this dock's own split EDID.
 const uint8_t timing[]={0xa2,0x6c,0,0x18,0xf1,0x38,0x2d,0x40,0x58,0x2c,0x45,0,0xff,0xff,0,0,0,0x1e};
 memcpy(e+108,timing,18);e[126]=0;e[127]=0;
 unsigned sum=0;for(int i=0;i<127;i++)sum+=e[i];e[127]=(uint8_t)(-sum);
 io_iterator_t it=0; if(IOServiceGetMatchingServices(0,IOServiceMatching("DCPAVServiceProxy"),&it))return fail(l,"No Mac display service",0);
 io_service_t s,chosen=0;int count=0;
 while((s=IOIteratorNext(it))){
  CFTypeRef loc=IORegistryEntryCreateCFProperty(s,CFSTR("Location"),NULL,0);
  if(loc&&CFEqual(loc,CFSTR("External"))){count++;if(!chosen){chosen=s;IOObjectRetain(s);}}
  if(loc)CFRelease(loc);IOObjectRelease(s);
 }IOObjectRelease(it);
 if(count!=1){if(chosen)IOObjectRelease(chosen);return fail(l,"Expected one external Mac display service",count);}
 CFTypeRef av=create(NULL,chosen);IOObjectRelease(chosen);if(!av)return fail(l,"Could not open Mac display service",0);
 CFDataRef data=CFDataCreate(NULL,e,128);if(!data){CFRelease(av);return fail(l,"Could not copy display data",0);}
 IOReturn rc=set(av,1,data);CFRelease(data);CFRelease(av);
 if(rc)return fail(l,"Mac display refresh failed",rc);
 refreshedUSB=l->usbID;memcpy(refreshedSource,original,128);return 0;
}
static int dock_state(LenovoDockState*out, int configure) {
 memset(out,0,sizeof(*out));out->connected=lenovo_dock_connected();if(!out->connected)return 0;
 Link l={.state=out,.usbID=dock_id()};if(openlink(&l))return -1;
 int result=-1,enabled=0;uint8_t identity[16],cap[4];
 uint8_t cfg[4],mode=0,ports[5],edid[128];
 if(rd(&l,0x500,identity,16)||rd(&l,0x4b0,cap,4))goto done;
 const uint8_t oui[]={0x90,0xcc,0x24},fw[]={5,5,6};
 if(memcmp(identity,oui,3)||identity[7]!=0x53||identity[8]!=0x22||memcmp(identity+10,fw,3)||!(cap[0]&4)){
  fail(&l,"This controller or firmware has not been verified",0);goto done;
 }
 if(command(&l,2))goto done;
 const uint8_t magic[]={'P','R','I','U','S'};uint32_t n=5,offset=0;
 if(wr(&l,0x4c0,magic,5)||wr(&l,0x4b8,&n,4)||wr(&l,0x4bc,&offset,4)||command(&l,1))goto done;
 enabled=1;
 if(memread(&l,0x1700,cfg,4)||memread(&l,0x1740,&mode,1)||memread(&l,0x1821,ports,5)||memread(&l,0x1600,edid,128))goto done;
 const uint8_t signature[]={0x20,0,0x87,0x83};
 if(memcmp(cfg,signature,4)||(mode!=2&&mode!=3)){fail(&l,"Dock configuration differs from the tested layout",mode);goto done;}
 out->mode=mode;out->monitors=ports[0]&15;
 if(out->monitors!=2){result=0;goto done;}
 const uint8_t widths[]={0x07,0x80,0x07,0x80};
 if(mode==3 && memcmp(ports+1,widths,4)){fail(&l,"The two monitors must each use 1920 pixels",0);goto done;}
 if(mode==3 && configure){
  // The only configuration write allowed: one byte in volatile RAM.
  uint8_t desired=2;uint32_t at=0x1740,one=1;
  if(wr(&l,0x4c0,&desired,1)||wr(&l,0x4bc,&at,4)||wr(&l,0x4b8,&one,4)||command(&l,0x21))goto done;
  if(memread(&l,0x1740,&mode,1)||mode!=2){fail(&l,"Split setting readback failed",mode);goto done;}
  out->mode=mode;out->changed=1;
 }
 for(int off=54;off<126;off+=18)if(edid[off]||edid[off+1]){
  int w=edid[off+2]+((edid[off+4]&0xf0)<<4),h=edid[off+5]+((edid[off+7]&0xf0)<<4);
  if(w==3840&&h==1080)out->wide=1;
 }
 result=0;
 done:
 if(enabled){char saved[256];memcpy(saved,out->error,256);int closeResult=command(&l,2);if(result<0)memcpy(out->error,saved,256);else if(closeResult)result=-1;}
 if(configure && result==0 && out->mode==2 && out->monitors==2 && !out->wide){
  if(refresh_host_edid(&l,edid))result=-1;else out->wide=1;
 }
 if(l.device)CFRelease(l.device);return result;
}
int lenovo_dock_prepare(LenovoDockState*out) { return dock_state(out,1); }
int lenovo_dock_check(LenovoDockState*out) { return dock_state(out,0); }
