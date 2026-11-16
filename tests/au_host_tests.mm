#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioToolbox/AUCocoaUIView.h>
#include "State.hpp"
#include <cassert>
#include <cstdio>
#include <dlfcn.h>
// --direct exercises the actual bundle's AUv2 dispatch interface without the OS
// component registry. It is explicitly not a substitute for auval/Logic testing.
namespace au {struct Context;}
@interface HasioLoopAUTestContainer : NSView
- (instancetype)initWithContext:(std::shared_ptr<au::Context>)context;
@end
static bool direct=false;
static AudioComponentPlugInInterface* api(AudioUnit u){return reinterpret_cast<AudioComponentPlugInInterface*>(u);}
#define HOST_CALL(name,proc,selector,signature,args) \
static OSStatus host##name signature {if(!direct)return name args;return reinterpret_cast<proc>(api(u)->Lookup(selector)) args;}
HOST_CALL(AudioUnitGetProperty,AudioUnitGetPropertyProc,kAudioUnitGetPropertySelect,(AudioUnit u,UInt32 p,UInt32 s,UInt32 e,void* v,UInt32* n),(u,p,s,e,v,n))
HOST_CALL(AudioUnitGetPropertyInfo,AudioUnitGetPropertyInfoProc,kAudioUnitGetPropertyInfoSelect,(AudioUnit u,UInt32 p,UInt32 s,UInt32 e,UInt32* n,Boolean* w),(u,p,s,e,n,w))
HOST_CALL(AudioUnitSetProperty,AudioUnitSetPropertyProc,kAudioUnitSetPropertySelect,(AudioUnit u,UInt32 p,UInt32 s,UInt32 e,const void* v,UInt32 n),(u,p,s,e,v,n))
HOST_CALL(AudioUnitGetParameter,AudioUnitGetParameterProc,kAudioUnitGetParameterSelect,(AudioUnit u,UInt32 p,UInt32 s,UInt32 e,Float32* v),(u,p,s,e,v))
HOST_CALL(AudioUnitSetParameter,AudioUnitSetParameterProc,kAudioUnitSetParameterSelect,(AudioUnit u,UInt32 p,UInt32 s,UInt32 e,Float32 v,UInt32 at),(u,p,s,e,v,at))
HOST_CALL(AudioUnitScheduleParameters,AudioUnitScheduleParametersProc,kAudioUnitScheduleParametersSelect,(AudioUnit u,const AudioUnitParameterEvent* e,UInt32 n),(u,e,n))
HOST_CALL(AudioUnitRender,AudioUnitRenderProc,kAudioUnitRenderSelect,(AudioUnit u,AudioUnitRenderActionFlags* f,const AudioTimeStamp* t,UInt32 b,UInt32 n,AudioBufferList* a),(u,f,t,b,n,a))
HOST_CALL(AudioUnitReset,AudioUnitResetProc,kAudioUnitResetSelect,(AudioUnit u,UInt32 s,UInt32 e),(u,s,e))
HOST_CALL(AudioUnitInitialize,AudioUnitInitializeProc,kAudioUnitInitializeSelect,(AudioUnit u),(u))
HOST_CALL(AudioUnitUninitialize,AudioUnitUninitializeProc,kAudioUnitUninitializeSelect,(AudioUnit u),(u))
HOST_CALL(AudioUnitAddPropertyListener,AudioUnitAddPropertyListenerProc,kAudioUnitAddPropertyListenerSelect,(AudioUnit u,UInt32 p,AudioUnitPropertyListenerProc f,void* v),(u,p,f,v))
HOST_CALL(MusicDeviceMIDIEvent,MusicDeviceMIDIEventProc,kMusicDeviceMIDIEventSelect,(AudioUnit u,UInt32 s,UInt32 a,UInt32 b,UInt32 at),(u,s,a,b,at))
static OSStatus hostDispose(AudioUnit u){return direct?api(u)->Close(u):AudioComponentInstanceDispose(u);}
HOST_CALL(AudioUnitAddRenderNotify,AudioUnitAddRenderNotifyProc,kAudioUnitAddRenderNotifySelect,(AudioUnit u,AURenderCallback f,void* v),(u,f,v))
HOST_CALL(AudioUnitRemoveRenderNotify,AudioUnitRemoveRenderNotifyProc,kAudioUnitRemoveRenderNotifySelect,(AudioUnit u,AURenderCallback f,void* v),(u,f,v))
#define AudioUnitAddRenderNotify hostAudioUnitAddRenderNotify
#define AudioUnitRemoveRenderNotify hostAudioUnitRemoveRenderNotify
#define AudioUnitGetProperty hostAudioUnitGetProperty
#define AudioUnitGetPropertyInfo hostAudioUnitGetPropertyInfo
#define AudioUnitSetProperty hostAudioUnitSetProperty
#define AudioUnitGetParameter hostAudioUnitGetParameter
#define AudioUnitSetParameter hostAudioUnitSetParameter
#define AudioUnitScheduleParameters hostAudioUnitScheduleParameters
#define AudioUnitRender hostAudioUnitRender
#define AudioUnitReset hostAudioUnitReset
#define AudioUnitInitialize hostAudioUnitInitialize
#define AudioUnitUninitialize hostAudioUnitUninitialize
#define AudioUnitAddPropertyListener hostAudioUnitAddPropertyListener
#define MusicDeviceMIDIEvent hostMusicDeviceMIDIEvent
#define AudioComponentInstanceDispose hostDispose
using namespace hasio;
static void ok(OSStatus s) { if (s) { fprintf(stderr,"AU error %d\n",(int)s); abort(); } }
template<class T> T get(AudioUnit u, AudioUnitPropertyID p, AudioUnitScope s=0, AudioUnitElement e=0) {
    T v{}; UInt32 n=sizeof(v); ok(AudioUnitGetProperty(u,p,s,e,&v,&n)); assert(n==sizeof(v)); return v;
}
template<class T> void set(AudioUnit u, AudioUnitPropertyID p,const T& v,AudioUnitScope s=0,AudioUnitElement e=0) {
    ok(AudioUnitSetProperty(u,p,s,e,&v,sizeof(v)));
}
static float param(AudioUnit u,int p) { float v; ok(AudioUnitGetParameter(u,p,0,0,&v)); return v; }
static void param(AudioUnit u,int p,float v,UInt32 at=0) { ok(AudioUnitSetParameter(u,p,0,0,v,at)); }
struct Stereo { UInt32 count=2; AudioBuffer buffers[2]{}; };
static std::vector<float> render(AudioUnit u,UInt32 n,double time,bool interleaved=false) {
    std::vector<float> a(n*2); Stereo b;
    b.count=interleaved?1:2; b.buffers[0]={interleaved?2u:1u,n*4*(interleaved?2u:1u),a.data()};
    if(!interleaved)b.buffers[1]={1,n*4,a.data()+n};
    AudioTimeStamp ts{};ts.mSampleTime=time;ts.mFlags=kAudioTimeStampSampleTimeValid;
    AudioUnitRenderActionFlags flags=0;
    ok(AudioUnitRender(u,&flags,&ts,0,n,reinterpret_cast<AudioBufferList*>(&b)));
    for(float v:a)assert(std::isfinite(v)); return a;
}
static double energy(const std::vector<float>& a,size_t first=0,size_t last=0) {
    if(!last)last=a.size();double sum=0;for(size_t i=first;i<last;++i)sum+=a[i]*a[i];return sum;
}
static OSStatus tempo(void*,Float64*beat,Float64*bpm){if(beat)*beat=0;if(bpm)*bpm=137;return noErr;}
static OSStatus meter(void*,UInt32*offset,Float32*num,UInt32*den,Float64*down){if(offset)*offset=0;if(num)*num=3;if(den)*den=4;if(down)*down=0;return noErr;}
static OSStatus scheduledChange(void* context,AudioUnitRenderActionFlags* flags,const AudioTimeStamp* time,UInt32,UInt32,AudioBufferList*) {
    if((*flags&kAudioUnitRenderAction_PreRender)&&time->mSampleTime==7000){
        AudioUnitParameterEvent e{};e.parameter=Tune;e.eventType=kParameterEvent_Immediate;e.eventValues.immediate={8,12};
        return AudioUnitScheduleParameters((AudioUnit)context,&e,1);
    }return noErr;
}
static int notifications=0;
static void changed(void*,AudioUnit,AudioUnitPropertyID,AudioUnitScope,AudioUnitElement){++notifications;}
int main(int argc,char**argv){@autoreleasepool{
    assert(argc>=2);direct=argc>2&&std::strcmp(argv[2],"--direct")==0;[NSApplication sharedApplication];
    NSString* path=[NSString stringWithUTF8String:argv[1]];
    NSBundle* bundle=[NSBundle bundleWithPath:path.stringByStandardizingPath];
    assert(bundle&&[bundle load]);
    void* lib=dlopen(bundle.executablePath.fileSystemRepresentation,RTLD_NOW|RTLD_LOCAL);assert(lib);
    auto factory=reinterpret_cast<AudioComponentFactoryFunction>(dlsym(lib,"HasioLoopAUFactory"));assert(factory);
    AudioComponentDescription d{kAudioUnitType_MusicDevice,'HsLp','Hasi',kAudioComponentFlag_SandboxSafe,0};
    AudioComponent c=nullptr;AudioUnit u=nullptr;
    if(direct){auto* h=factory(&d);assert(h);AudioComponentInstance testInstance=nullptr;ok(h->Open(h,testInstance));u=reinterpret_cast<AudioUnit>(h);}
    else{c=AudioComponentRegister(&d,CFSTR("hasio: Essential Sampler"),0x000602,factory);if(!c){fprintf(stderr,"AudioComponent registry unavailable; run --direct for ABI tests or run this host outside the sandbox.\n");return 77;}ok(AudioComponentInstanceNew(c,&u));}
    assert(get<UInt32>(u,kAudioUnitProperty_ElementCount,kAudioUnitScope_Input)==0);
    assert(get<UInt32>(u,kAudioUnitProperty_ElementCount,kAudioUnitScope_Output)==1);
    UInt32 size=0;Boolean writable=true;
    ok(AudioUnitGetPropertyInfo(u,kAudioUnitProperty_ParameterList,0,0,&size,&writable));assert(size==26*4&&!writable);
    auto info=get<AudioUnitParameterInfo>(u,kAudioUnitProperty_ParameterInfo,0,Tune);
    assert(info.minValue==-24&&info.maxValue==24&&info.unit==kAudioUnitParameterUnit_RelativeSemiTones);
    if(info.flags&kAudioUnitParameterFlag_CFNameRelease)CFRelease(info.cfNameString);
    auto names=get<CFArrayRef>(u,kAudioUnitProperty_ParameterValueStrings,0,SyncLength);assert(CFArrayGetCount(names)==9);CFRelease(names);
    assert(std::abs(param(u,Gain)+12)<.001);param(u,Tune,7);assert(param(u,Tune)==7);
    assert(AudioUnitSetParameter(u,Tune,0,0,NAN,0)!=noErr);
    assert(AudioUnitSetParameter(u,999,0,0,0,0)!=noErr);
    auto fmt=get<AudioStreamBasicDescription>(u,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output);
    assert(fmt.mChannelsPerFrame==2&&fmt.mSampleRate==48000);
    auto bad=fmt;bad.mChannelsPerFrame=3;assert(AudioUnitSetProperty(u,kAudioUnitProperty_StreamFormat,2,0,&bad,sizeof(bad))!=noErr);
    UInt32 maxFrames=4096;set(u,kAudioUnitProperty_MaximumFramesPerSlice,maxFrames);
    HostCallbackInfo callbacks{};callbacks.beatAndTempoProc=tempo;callbacks.musicalTimeLocationProc=meter;set(u,kAudioUnitProperty_HostCallbacks,callbacks);
    ok(AudioUnitAddPropertyListener(u,kAudioUnitProperty_ClassInfo,changed,nullptr));
    // Restore an embedded, constant sample: no disk dependency and a clear MIDI onset.
    Model m;auto s=std::make_shared<Sample>();s->rate=48000;s->name="AU embedded fixture";s->left.assign(24000,.4f);std::fill_n(s->left.begin(),12000,.2f);s->right.assign(24000,-.2f);s->buildPeaks();m.samples.publish(s);
    m.params[Tune]=normalized(Tune,0);m.params[Attack]=0;m.params[FadeIn]=0;m.params[FadeOut]=0;m.params[KeepSpeed]=0;
    auto raw=saveState(m);NSDictionary* preset=@{@"version":@0,@"type":@(d.componentType),@"subtype":@(d.componentSubType),@"manufacturer":@(d.componentManufacturer),@"name":@"Fixture",@"data":[NSData dataWithBytes:raw.data() length:raw.size()]};
    CFDictionaryRef state=(__bridge CFDictionaryRef)preset;set(u,kAudioUnitProperty_ClassInfo,state);assert(notifications>0);
    auto saved=get<CFDictionaryRef>(u,kAudioUnitProperty_ClassInfo);assert(CFGetTypeID(saved)==CFDictionaryGetTypeID());
    CFDataRef data=(CFDataRef)CFDictionaryGetValue(saved,CFSTR("data"));assert(data&&CFDataGetLength(data)==(CFIndex)raw.size());
    Model restored;assert(loadState(restored,CFDataGetBytePtr(data),CFDataGetLength(data)));assert(restored.samples.snapshot()->name==s->name);CFRelease(saved);
    NSDictionary* wrong=@{@"type":@(123),@"data":preset[@"data"]};state=(__bridge CFDictionaryRef)wrong;
    assert(AudioUnitSetProperty(u,kAudioUnitProperty_ClassInfo,0,0,&state,sizeof(state))!=noErr);
    ok(AudioUnitInitialize(u));assert(std::abs(get<Float64>(u,kAudioUnitProperty_Latency)-2048.0/48000)<1e-8);
    assert(AudioUnitSetProperty(u,kAudioUnitProperty_StreamFormat,2,0,&fmt,sizeof(fmt))!=noErr);
    assert(energy(render(u,256,0))==0);
    ok(MusicDeviceMIDIEvent(u,0x90,60,100,37));auto a=render(u,4096,256);
    assert(energy(a,0,2048+37)==0&&energy(a,2100,4000)>1);
    assert(a==render(u,4096,256)); // Duplicate pulls must not advance transport twice.
    param(u,Tune,12,48);render(u,64,4352);assert(param(u,Tune)==12);
    AudioUnitParameterEvent e{};e.parameter=Tune;e.eventType=kParameterEvent_Ramped;e.eventValues.ramp={0,128,0,12};
    ok(AudioUnitScheduleParameters(u,&e,1));render(u,64,4416);assert(param(u,Tune)>5.8&&param(u,Tune)<6.1);
    float midway=param(u,Tune);render(u,65,4480);assert(param(u,Tune)==midway); // Hosts must resubmit a continuing ramp.
    e.eventValues.ramp.startBufferOffset=-64;ok(AudioUnitScheduleParameters(u,&e,1));render(u,64,4545);assert(param(u,Tune)==12);
    ok(AudioUnitReset(u,0,0));assert(energy(render(u,4096,5000))==0);
    // Duplicate render notifications may schedule the same events again; they must not leak.
    ok(AudioUnitAddRenderNotify(u,scheduledChange,u));render(u,64,7000);assert(param(u,Tune)==12);
    render(u,64,7000);param(u,Tune,0);render(u,64,7064);assert(param(u,Tune)==0);ok(AudioUnitRemoveRenderNotify(u,scheduledChange,u));
    e.eventType=kParameterEvent_Immediate;e.eventValues.immediate={1000,12};ok(AudioUnitScheduleParameters(u,&e,1));render(u,64,7128);render(u,1024,7192);assert(param(u,Tune)==0);
    // A ramp scheduled before a same-offset note must affect that note's start.
    ok(AudioUnitReset(u,0,0));param(u,Start,.5);render(u,64,8300);
    e.parameter=Start;e.eventType=kParameterEvent_Ramped;e.eventValues.ramp={0,10,0,0};ok(AudioUnitScheduleParameters(u,&e,1));
    ok(MusicDeviceMIDIEvent(u,0x90,60,100,0));auto onset=render(u,4096,8364);
    assert(std::abs(onset[2100]+onset[4096+2100])<1e-5&&std::abs(onset[2100])>.01);
    ok(AudioUnitReset(u,0,0));
    // An existing attack ramp must advance before a note at the next sample.
    param(u,Attack,0);e.parameter=Attack;e.eventValues.ramp={0,64,0,100};ok(AudioUnitScheduleParameters(u,&e,1));
    ok(MusicDeviceMIDIEvent(u,0x90,60,100,1));auto attack=render(u,4096,8500);
    assert(std::abs(attack[2049])<.005&&energy(attack,2200,4000)>.01);assert(param(u,Attack)==100);
    ok(AudioUnitReset(u,0,0));param(u,Attack,0);
    // Full queues must fail safely even when the rejected message is note-off.
    for(int i=0;i<4096;++i)ok(MusicDeviceMIDIEvent(u,0x90,60,100,0));
    assert(MusicDeviceMIDIEvent(u,0x80,60,0,0)!=noErr);assert(energy(render(u,4096,9000))==0);
    Stereo owned;owned.buffers[0]={1,0,nullptr};owned.buffers[1]={1,0,nullptr};AudioTimeStamp ts{};ts.mFlags=kAudioTimeStampSampleTimeValid;ts.mSampleTime=10000;AudioUnitRenderActionFlags flags=0;
    ok(AudioUnitRender(u,&flags,&ts,0,64,(AudioBufferList*)&owned));assert(owned.buffers[0].mData&&owned.buffers[1].mData);assert(flags&kAudioUnitRenderAction_OutputIsSilence);
    assert(AudioUnitRender(u,&flags,&ts,0,4097,(AudioBufferList*)&owned)==kAudioUnitErr_TooManyFramesToProcess);
    // Host 137 BPM + 3/4 must make a one-bar one-shot finish before 1.45 s.
    state=(__bridge CFDictionaryRef)preset;set(u,kAudioUnitProperty_ClassInfo,state);
    param(u,ModeId,0);param(u,SyncLength,3);ok(AudioUnitReset(u,0,0));ok(MusicDeviceMIDIEvent(u,0x90,60,100,0));
    double middle=0,after=0;for(int block=0;block<75;++block){auto audio=render(u,1000,20000+block*1000);if(block>=40&&block<50)middle+=energy(audio);if(block>=70)after+=energy(audio);}
    assert(middle>1&&after<1e-10);
    // Channel all-notes/sound-off must leave other MIDI channels sounding.
    param(u,ModeId,1);param(u,SyncLength,0);ok(AudioUnitReset(u,0,0));
    ok(MusicDeviceMIDIEvent(u,0x90,60,100,0));ok(MusicDeviceMIDIEvent(u,0x91,60,100,0));render(u,4096,100000);
    ok(MusicDeviceMIDIEvent(u,0xb0,120,0,0));render(u,4096,104096);assert(energy(render(u,4096,108192))>1);
    ok(MusicDeviceMIDIEvent(u,0xb1,123,0,0));render(u,4096,112288);assert(energy(render(u,4096,116384))==0);
    ok(AudioUnitUninitialize(u));fmt.mFormatFlags&=~kAudioFormatFlagIsNonInterleaved;fmt.mBytesPerFrame=fmt.mBytesPerPacket=8;fmt.mSampleRate=44100;
    set(u,kAudioUnitProperty_StreamFormat,fmt,kAudioUnitScope_Output);ok(AudioUnitInitialize(u));ok(MusicDeviceMIDIEvent(u,0x90,60,100,0));assert(energy(render(u,4096,0,true))>1);
    ok(AudioUnitReset(u,0,0));
    auto ui=get<AudioUnitCocoaViewInfo>(u,kAudioUnitProperty_CocoaUI);
    Class cls=NSClassFromString((__bridge NSString*)ui.mCocoaAUViewClass[0]);assert(cls);
    id<AUCocoaUIBase> viewFactory=[[cls alloc]init];NSView* view=nil;
    if(direct){std::shared_ptr<au::Context> context;UInt32 bytes=sizeof(context);ok(AudioUnitGetProperty(u,64000,0,0,&context,&bytes));view=[NSClassFromString(@"HasioLoopAUContainer") alloc];view=[(HasioLoopAUTestContainer*)view initWithContext:context];}
    else view=[viewFactory uiViewForAudioUnit:u withSize:NSMakeSize(1280,860)];assert(view&&view.frame.size.width==1280);
    CFRelease(ui.mCocoaAUViewBundleLocation);CFRelease(ui.mCocoaAUViewClass[0]);
    ok(AudioComponentInstanceDispose(u)); // Editor must safely outlive its unit.
    [view removeFromSuperview];view=nil;
    if(argc>2&&!direct){AudioComponentValidationResult result;OSStatus status=AudioComponentValidate(c,nullptr,&result);printf("Apple validation status=%d result=%u\n",(int)status,(unsigned)result);}
    printf("AU host (%s): ",direct?"direct ABI; OS registry not tested":"public API");
    puts(" factory, physical parameters, embedded state, MIDI offsets, ramps, buffers, reset, formats and editor passed.");
}}
