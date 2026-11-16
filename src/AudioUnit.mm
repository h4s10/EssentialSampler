// Native AUv2 instrument adapter. DSP and state are shared with VST3/standalone.
#import <Cocoa/Cocoa.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioToolbox/AUCocoaUIView.h>
#include "Editor.hpp"
#include "State.hpp"
#include <array>
#include <atomic>
#include <cstring>
#include <limits>
#include <mutex>

namespace au {
using namespace hasio;
constexpr OSType subtype='HsLp', manufacturer='Hasi';
constexpr AudioUnitPropertyID editorContextProperty=64000;
constexpr size_t eventCapacity=4096;
struct Context {
    std::shared_ptr<Model> model=std::make_shared<Model>();
    std::mutex mutex; // UI and close only; never used by render.
    AudioUnit instance=nullptr;
};
struct Event {
    int64_t offset=0; uint64_t order=0; uint32_t id=0,duration=0;
    float value=0,end=0; uint8_t kind=0,status=0,a=0,b=0; bool currentRenderOnly=false;
};
// Bounded multi-producer / single-consumer queue. Host MIDI and automation can
// arrive on different threads. No allocation, mutex or object destruction in render.
template<class T,size_t N> class Queue {
    struct Slot { std::atomic<size_t> sequence; T value{}; };
    std::array<Slot,N> slots; std::atomic<size_t> write{0}; size_t read=0;
public:
    Queue(){for(size_t i=0;i<N;++i)slots[i].sequence=i;}
    bool push(T value) {
        size_t pos=write.load(std::memory_order_relaxed);
        for(;;){auto& s=slots[pos%N];auto seq=s.sequence.load(std::memory_order_acquire);
            auto diff=static_cast<intptr_t>(seq)-static_cast<intptr_t>(pos);
            if(diff==0){if(write.compare_exchange_weak(pos,pos+1,std::memory_order_relaxed)){
                s.value=value;s.sequence.store(pos+1,std::memory_order_release);return true;}}
            else if(diff<0)return false;else pos=write.load(std::memory_order_relaxed);
        }
    }
    bool pop(T& value){auto& s=slots[read%N];if(s.sequence.load(std::memory_order_acquire)!=read+1)return false;
        value=s.value;s.sequence.store(read+N,std::memory_order_release);++read;return true;}
};
struct Notify { AURenderCallback proc; void* user; };
struct Callbacks { HostCallbackInfo host{}; std::vector<Notify> render; };
// Single render reader; snapshots are reclaimed only by a control-thread writer.
class CallbackStore {
    std::mutex mutex; std::vector<std::unique_ptr<Callbacks>> owned;
    std::atomic<Callbacks*> current{nullptr}, pinned{nullptr};
public:
    CallbackStore(){owned.push_back(std::make_unique<Callbacks>());current=owned.back().get();}
    template<class F> void update(F f){std::lock_guard<std::mutex> lock(mutex);
        auto next=std::make_unique<Callbacks>(*current.load());f(*next);auto* p=next.get();owned.push_back(std::move(next));current.store(p);
        auto* used=pinned.load();owned.erase(std::remove_if(owned.begin(),owned.end(),[&](const auto& x){return x.get()!=p&&x.get()!=used;}),owned.end());}
    Callbacks* pin(){Callbacks* p;do {p=current.load();pinned.store(p);}while(p!=current.load());return p;}
    void unpin(){pinned.store(nullptr);}
    HostCallbackInfo host(){std::lock_guard<std::mutex> lock(mutex);return current.load()->host;}
};
struct Listener { AudioUnitPropertyID id; AudioUnitPropertyListenerProc proc; void* user; };
struct Ramp { bool active=false; uint32_t duration=0,elapsed=0; float start=0,end=0; uint64_t generation=0; };
struct Unit {
    std::shared_ptr<Context> context=std::make_shared<Context>();
    Engine engine;
    AudioStreamBasicDescription format{48000,kAudioFormatLinearPCM,kAudioFormatFlagsNativeFloatPacked|kAudioFormatFlagIsNonInterleaved,4,1,4,2,32,0};
    UInt32 maxFrames=4096,allocateBuffers=1,offline=0;
    std::atomic<bool> initialized{false}; std::atomic<OSStatus> lastError{noErr};
    Queue<Event,eventCapacity> queue,scheduled; std::atomic<bool> overflow{false}; std::atomic<uint64_t> eventOrder{0}; std::array<Event,eventCapacity> pending{}; size_t pendingCount=0;
    std::array<Ramp,ParamCount> ramps{}; std::array<std::atomic<uint64_t>,ParamCount> generations{};
    std::vector<float> left,right,interleaved;
    double lastTime=0; UInt32 lastFrames=0; bool cached=false,cachedSilent=true;
    CallbackStore callbacks; std::mutex listenersMutex;std::vector<Listener> listeners;
    NSString* presetName=@"Default";
    explicit Unit(AudioUnit instance){context->instance=instance;}
    ~Unit(){std::lock_guard<std::mutex> lock(context->mutex);context->instance=nullptr;context->model->stopPreviewNotes();}
    Model& model(){return *context->model;}
    void notify(AudioUnitPropertyID id,AudioUnitScope scope=0,AudioUnitElement element=0){
        std::vector<Listener> copy;{std::lock_guard<std::mutex> lock(listenersMutex);copy=listeners;}
        for(auto& l:copy)if(l.id==id)l.proc(l.user,context->instance,id,scope,element);
    }
    OSStatus enqueue(Event e){e.order=eventOrder.fetch_add(1,std::memory_order_relaxed);if((e.currentRenderOnly?scheduled:queue).push(e))return noErr;overflow=true;return kAudioUnitErr_CannotDoInCurrentContext;}
    void reset(){engine.allNotesOff();pendingCount=0;Event e;while(queue.pop(e)){}while(scheduled.pop(e)){}overflow=false;ramps={};cached=false;
        Note n;while(model().notes.pop(n)){}model().playhead=-1;model().activeVoices=0;model().meter=0;}
};
struct Handle { AudioComponentPlugInInterface api; Unit* unit=nullptr; };
static Unit& unit(void* self){return *static_cast<Handle*>(self)->unit;}
static bool validParam(uint32_t id){return id<ParamCount&&id!=LegacyCrossfade;}
static bool discrete(uint32_t id){return id==ModeId||id==Root||id==KeepSpeed||id==SyncLength||id==DistEnabled||id==DistType||id==ChorusEnabled;}
static const char* const* labels(uint32_t id,int& count){
    if(id==ModeId){count=5;return modeNames;}if(id==DistType){count=6;return distortionNames;}
    if(id==SyncLength){count=lengthCount;return lengthNames;}count=0;return nullptr;
}
static AudioUnitParameterUnit paramUnit(uint32_t id){switch(id){
    case Root:return kAudioUnitParameterUnit_MIDINoteNumber;
    case Tune:return kAudioUnitParameterUnit_RelativeSemiTones;
    case Gain:return kAudioUnitParameterUnit_Decibels;
    case Attack:case Release:case FadeIn:case FadeOut:case ChorusDelay:return kAudioUnitParameterUnit_Milliseconds;
    case ChorusRate:return kAudioUnitParameterUnit_Hertz;
    case Tempo:return kAudioUnitParameterUnit_BPM;
    case KeepSpeed:case DistEnabled:case ChorusEnabled:return kAudioUnitParameterUnit_Boolean;
    case ModeId:case DistType:case SyncLength:return kAudioUnitParameterUnit_Indexed;
    case DistAmount:case DistTone:case DistMix:case ChorusDepth:case ChorusWidth:case ChorusFeedback:case ChorusMix:return kAudioUnitParameterUnit_Percent;
    case PlaybackRate:return kAudioUnitParameterUnit_Rate;
    default:return kAudioUnitParameterUnit_Generic;}}
static OSStatus parameterAddress(uint32_t id,UInt32 scope,UInt32 elem){if(scope!=0)return kAudioUnitErr_InvalidScope;if(elem!=0)return kAudioUnitErr_InvalidElement;return validParam(id)?noErr:kAudioUnitErr_InvalidParameter;}
static OSStatus propertyInfo(void* self,UInt32 id,UInt32 scope,UInt32 elem,UInt32* size,Boolean* writable){
    UInt32 n=0;Boolean w=false;
    switch(id){
        case kAudioUnitProperty_ElementCount:
            if(scope!=0&&scope!=1&&scope!=2)return kAudioUnitErr_InvalidScope;if(elem)return kAudioUnitErr_InvalidElement;n=sizeof(UInt32);break;
        case kAudioUnitProperty_StreamFormat:case kAudioUnitProperty_SampleRate:
            if(scope!=kAudioUnitScope_Output&&scope!=kAudioUnitScope_Global)return kAudioUnitErr_InvalidScope;
            if(elem)return kAudioUnitErr_InvalidElement;n=id==kAudioUnitProperty_StreamFormat?sizeof(AudioStreamBasicDescription):sizeof(Float64);w=true;break;
        case kAudioUnitProperty_AudioChannelLayout:case kAudioUnitProperty_SupportedChannelLayoutTags:case kAudioUnitProperty_ShouldAllocateBuffer:
            if(scope!=kAudioUnitScope_Output)return kAudioUnitErr_InvalidScope;if(elem)return kAudioUnitErr_InvalidElement;
            n=id==kAudioUnitProperty_AudioChannelLayout?offsetof(AudioChannelLayout,mChannelDescriptions):sizeof(UInt32);w=id!=kAudioUnitProperty_SupportedChannelLayoutTags;break;
        case kAudioUnitProperty_ParameterInfo:case kAudioUnitProperty_ParameterValueStrings:
            if(scope!=0)return kAudioUnitErr_InvalidScope;if(!validParam(elem))return kAudioUnitErr_InvalidParameter;
            if(id==kAudioUnitProperty_ParameterValueStrings){int count;labels(elem,count);if(!count)return kAudioUnitErr_InvalidProperty;n=sizeof(CFArrayRef);}else n=sizeof(AudioUnitParameterInfo);break;
        default:
            if(scope!=0)return kAudioUnitErr_InvalidScope;if(elem)return kAudioUnitErr_InvalidElement;
            switch(id){
                case kAudioUnitProperty_ClassInfo:case kAudioUnitProperty_ClassInfoFromDocument:n=sizeof(CFDictionaryRef);w=true;break;
                case kAudioUnitProperty_ParameterList:n=(ParamCount-1)*sizeof(AudioUnitParameterID);break;
                case kAudioUnitProperty_MaximumFramesPerSlice:case kAudioUnitProperty_OfflineRender:n=sizeof(UInt32);w=true;break;
                case kAudioUnitProperty_LastRenderError:n=sizeof(OSStatus);break;
                case kAudioUnitProperty_Latency:n=sizeof(Float64);break;
                case kAudioUnitProperty_SupportedNumChannels:n=sizeof(AUChannelInfo);break;
                case kAudioUnitProperty_HostCallbacks:n=sizeof(HostCallbackInfo);w=true;break;
                case kAudioUnitProperty_CocoaUI:n=sizeof(AudioUnitCocoaViewInfo);break;
                case kAudioUnitProperty_FactoryPresets:n=sizeof(CFArrayRef);break;
                case kAudioUnitProperty_PresentPreset:n=sizeof(AUPreset);w=true;break;
                case kAudioUnitProperty_ParameterIDName:n=sizeof(AudioUnitParameterIDName);break;
                case kAudioUnitProperty_ParameterStringFromValue:n=sizeof(AudioUnitParameterStringFromValue);break;
                case kAudioUnitProperty_ParameterValueFromString:n=sizeof(AudioUnitParameterValueFromString);break;
                case kMusicDeviceProperty_InstrumentCount:n=sizeof(UInt32);break;
                case editorContextProperty:n=sizeof(std::shared_ptr<Context>);break;
                default:return kAudioUnitErr_InvalidProperty;
            }
    }
    if(size)*size=n;if(writable)*writable=w;return noErr;
}
static OSStatus getProperty(void* self,UInt32 id,UInt32 scope,UInt32 elem,void* out,UInt32* size){@autoreleasepool{try{
    UInt32 needed=0;auto status=propertyInfo(self,id,scope,elem,&needed,nullptr);if(status)return status;
    if(!out||!size)return paramErr;if(*size<needed)return kAudioUnitErr_InvalidPropertyValue;*size=needed;auto& u=unit(self);
    auto write=[&](const auto& v){std::memcpy(out,&v,sizeof(v));};
    switch(id){
        case kAudioUnitProperty_ElementCount:write(UInt32(scope==kAudioUnitScope_Input?0:1));break;
        case kAudioUnitProperty_StreamFormat:write(u.format);break;
        case kAudioUnitProperty_SampleRate:write(u.format.mSampleRate);break;
        case kAudioUnitProperty_MaximumFramesPerSlice:write(u.maxFrames);break;
        case kAudioUnitProperty_OfflineRender:write(u.offline);break;
        case kAudioUnitProperty_ShouldAllocateBuffer:write(u.allocateBuffers);break;
        case kAudioUnitProperty_LastRenderError:write(u.lastError.exchange(noErr));break;
        case kAudioUnitProperty_Latency:write(Float64(Engine::latencySamples()/u.format.mSampleRate));break;
        case kAudioUnitProperty_SupportedNumChannels:write(AUChannelInfo{0,2});break;
        case kAudioUnitProperty_SupportedChannelLayoutTags:write(AudioChannelLayoutTag(kAudioChannelLayoutTag_Stereo));break;
        case kAudioUnitProperty_AudioChannelLayout:{auto* v=static_cast<AudioChannelLayout*>(out);std::memset(out,0,needed);v->mChannelLayoutTag=kAudioChannelLayoutTag_Stereo;break;}
        case kMusicDeviceProperty_InstrumentCount:write(UInt32(0));break;
        case kAudioUnitProperty_HostCallbacks:write(u.callbacks.host());break;
        case kAudioUnitProperty_ParameterList:{auto* ids=static_cast<UInt32*>(out);for(uint32_t p=0;p<ParamCount;++p)if(validParam(p))*ids++=p;break;}
        case kAudioUnitProperty_ParameterInfo:{AudioUnitParameterInfo p{};strlcpy(p.name,paramNames[elem],sizeof(p.name));p.cfNameString=CFStringCreateWithCString(nullptr,paramNames[elem],kCFStringEncodingUTF8);
            p.unit=paramUnit(elem);p.minValue=plain(elem,0);p.maxValue=plain(elem,1);p.defaultValue=plain(elem,defaults[elem]);
            p.flags=kAudioUnitParameterFlag_IsReadable|kAudioUnitParameterFlag_IsWritable|kAudioUnitParameterFlag_HasCFNameString|kAudioUnitParameterFlag_CFNameRelease;
            if(!discrete(elem))p.flags|=kAudioUnitParameterFlag_CanRamp;write(p);break;}
        case kAudioUnitProperty_ParameterValueStrings:{int count;auto names=labels(elem,count);NSMutableArray* a=[NSMutableArray array];for(int i=0;i<count;++i)[a addObject:@(names[i])];CFArrayRef result=(__bridge_retained CFArrayRef)a;write(result);break;}
        case kAudioUnitProperty_ParameterIDName:{auto* v=static_cast<AudioUnitParameterIDName*>(out);if(!validParam(v->inID))return kAudioUnitErr_InvalidParameter;
            NSString* name=@(paramNames[v->inID]);if(v->inDesiredLength>=0&&v->inDesiredLength<(SInt32)name.length)name=[name substringToIndex:v->inDesiredLength];v->outName=(__bridge_retained CFStringRef)name;break;}
        case kAudioUnitProperty_ParameterStringFromValue:{auto* v=static_cast<AudioUnitParameterStringFromValue*>(out);if(!validParam(v->inParamID))return kAudioUnitErr_InvalidParameter;
            auto p=v->inParamID;double value=v->inValue?*v->inValue:plain(p,u.model().params[p]);if(!std::isfinite(value))return kAudioUnitErr_InvalidPropertyValue;
            int count;auto names=labels(p,count);NSString* str=names?@(names[std::clamp((int)std::round(std::clamp(value,0.0,double(count-1))),0,count-1)]):[NSString stringWithFormat:@"%.3f",value];v->outString=(__bridge_retained CFStringRef)str;break;}
        case kAudioUnitProperty_ParameterValueFromString:{auto* v=static_cast<AudioUnitParameterValueFromString*>(out);if(!validParam(v->inParamID)||!v->inString||CFGetTypeID(v->inString)!=CFStringGetTypeID())return kAudioUnitErr_InvalidParameter;
            NSString* str=(__bridge NSString*)v->inString;int count;auto names=labels(v->inParamID,count);bool found=false;
            for(int i=0;i<count;++i)if([str caseInsensitiveCompare:@(names[i])]==NSOrderedSame){v->outValue=i;found=true;break;}
            if(!found){double d;NSScanner* scan=[NSScanner scannerWithString:str];if(![scan scanDouble:&d]||!scan.isAtEnd||!std::isfinite(d))return kAudioUnitErr_InvalidPropertyValue;v->outValue=plain(v->inParamID,normalized(v->inParamID,d));}break;}
        case kAudioUnitProperty_ClassInfo:case kAudioUnitProperty_ClassInfoFromDocument:{auto bytes=saveState(u.model());NSDictionary* d=@{@"version":@0,@"type":@(kAudioUnitType_MusicDevice),@"subtype":@(subtype),@"manufacturer":@(manufacturer),@"name":u.presetName,@"data":[NSData dataWithBytes:bytes.data() length:bytes.size()]};CFDictionaryRef state=(__bridge_retained CFDictionaryRef)d;write(state);break;}
        case kAudioUnitProperty_FactoryPresets:{CFArrayRef empty=CFArrayCreate(nullptr,nullptr,0,&kCFTypeArrayCallBacks);write(empty);break;}
        case kAudioUnitProperty_PresentPreset:{AUPreset p{-1,(__bridge_retained CFStringRef)u.presetName};write(p);break;}
        case kAudioUnitProperty_CocoaUI:{NSBundle* bundle=[NSBundle bundleForClass:NSClassFromString(@"HasioLoopAUViewFactory")];if(!bundle)return kAudioUnitErr_InvalidPropertyValue;
            AudioUnitCocoaViewInfo v{(__bridge_retained CFURLRef)bundle.bundleURL,{CFStringCreateCopy(nullptr,CFSTR("HasioLoopAUViewFactory"))}};write(v);break;}
        case editorContextProperty:*static_cast<std::shared_ptr<Context>*>(out)=u.context;break;
        default:return kAudioUnitErr_InvalidProperty;
    }return noErr;
}catch(...){return kAudioUnitErr_FailedInitialization;}}}
static bool validFormat(const AudioStreamBasicDescription& f){
    auto base=kAudioFormatFlagsNativeFloatPacked;bool planar=f.mFormatFlags&kAudioFormatFlagIsNonInterleaved;
    return std::isfinite(f.mSampleRate)&&f.mSampleRate>=8000&&f.mSampleRate<=384000&&f.mFormatID==kAudioFormatLinearPCM&&
        f.mChannelsPerFrame==2&&f.mBitsPerChannel==32&&f.mFramesPerPacket==1&&f.mBytesPerFrame==(planar?4u:8u)&&f.mBytesPerPacket==f.mBytesPerFrame&&
        (f.mFormatFlags&~kAudioFormatFlagIsNonInterleaved)==base;
}
static OSStatus setProperty(void* self,UInt32 id,UInt32 scope,UInt32 elem,const void* data,UInt32 size){@autoreleasepool{try{
    UInt32 needed;Boolean writable;auto status=propertyInfo(self,id,scope,elem,&needed,&writable);if(status)return status;if(!writable)return kAudioUnitErr_PropertyNotWritable;
    if(!data||size!=needed)return kAudioUnitErr_InvalidPropertyValue;auto& u=unit(self);
    switch(id){
        case kAudioUnitProperty_StreamFormat:case kAudioUnitProperty_SampleRate:{if(u.initialized)return kAudioUnitErr_Initialized;
            auto f=u.format;if(id==kAudioUnitProperty_StreamFormat)std::memcpy(&f,data,sizeof(f));else std::memcpy(&f.mSampleRate,data,sizeof(Float64));
            if(!validFormat(f))return kAudioUnitErr_FormatNotSupported;u.format=f;u.notify(kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output);u.notify(kAudioUnitProperty_SampleRate,kAudioUnitScope_Output);u.notify(kAudioUnitProperty_Latency);return noErr;}
        case kAudioUnitProperty_MaximumFramesPerSlice:if(u.initialized)return kAudioUnitErr_Initialized;
            if(*(const UInt32*)data<1||*(const UInt32*)data>65536)return kAudioUnitErr_InvalidPropertyValue;u.maxFrames=*(const UInt32*)data;break;
        case kAudioUnitProperty_OfflineRender:if(*(const UInt32*)data>1)return kAudioUnitErr_InvalidPropertyValue;u.offline=*(const UInt32*)data;break;
        case kAudioUnitProperty_ShouldAllocateBuffer:if(u.initialized)return kAudioUnitErr_Initialized;if(*(const UInt32*)data>1)return kAudioUnitErr_InvalidPropertyValue;u.allocateBuffers=*(const UInt32*)data;break;
        case kAudioUnitProperty_AudioChannelLayout:if(((const AudioChannelLayout*)data)->mChannelLayoutTag!=kAudioChannelLayoutTag_Stereo)return kAudioUnitErr_FormatNotSupported;break;
        case kAudioUnitProperty_HostCallbacks:{auto h=*(const HostCallbackInfo*)data;u.callbacks.update([&](Callbacks& c){c.host=h;});break;}
        case kAudioUnitProperty_ClassInfo:case kAudioUnitProperty_ClassInfoFromDocument:{CFDictionaryRef ref=*(const CFDictionaryRef*)data;if(!ref||CFGetTypeID(ref)!=CFDictionaryGetTypeID())return kAudioUnitErr_InvalidPropertyValue;
            NSDictionary* d=(__bridge NSDictionary*)ref;
            for(NSString* key in @[@"version",@"type",@"subtype",@"manufacturer"]){if(![d[key] isKindOfClass:NSNumber.class])return kAudioUnitErr_InvalidPropertyValue;}
            if([d[@"version"] intValue]!=0||[d[@"type"] unsignedIntValue]!=kAudioUnitType_MusicDevice||[d[@"subtype"] unsignedIntValue]!=subtype||[d[@"manufacturer"] unsignedIntValue]!=manufacturer||![d[@"data"] isKindOfClass:NSData.class])return kAudioUnitErr_InvalidPropertyValue;
            NSData* bytes=d[@"data"];if(!loadState(u.model(),static_cast<const uint8_t*>(bytes.bytes),bytes.length))return kAudioUnitErr_InvalidPropertyValue;
            u.presetName=[d[@"name"] isKindOfClass:NSString.class]?[d[@"name"] copy]:@"User";
            for(auto& g:u.generations)++g;
            if(u.context->instance){AudioUnitParameter p{u.context->instance,kAUParameterListener_AnyParameter,kAudioUnitScope_Global,0};AUParameterListenerNotify(nullptr,nullptr,&p);}
            u.notify(kAudioUnitProperty_PresentPreset);break;}
        case kAudioUnitProperty_PresentPreset:{auto p=*(const AUPreset*)data;if(p.presetNumber>=0||!p.presetName||CFGetTypeID(p.presetName)!=CFStringGetTypeID())return kAudioUnitErr_InvalidPropertyValue;u.presetName=[(__bridge NSString*)p.presetName copy];break;}
        default:return kAudioUnitErr_InvalidProperty;
    }u.notify(id,scope,elem);return noErr;
}catch(...){return kAudioUnitErr_FailedInitialization;}}}
static OSStatus getParameter(void* self,UInt32 id,UInt32 scope,UInt32 elem,Float32* value){auto s=parameterAddress(id,scope,elem);if(s)return s;if(!value)return paramErr;*value=plain(id,unit(self).model().params[id]);return noErr;}
static OSStatus setParameter(void* self,UInt32 id,UInt32 scope,UInt32 elem,Float32 value,UInt32 offset){auto s=parameterAddress(id,scope,elem);if(s)return s;if(!std::isfinite(value))return kAudioUnitErr_InvalidParameterValue;
    auto& u=unit(self);if(!offset){u.model().params[id]=normalized(id,value);++u.generations[id];return noErr;}
    Event e;e.currentRenderOnly=true;e.kind=1;e.id=id;e.value=value;e.offset=offset;return u.enqueue(e);
}
static OSStatus schedule(void* self,const AudioUnitParameterEvent* events,UInt32 count){if(!events&&count)return paramErr;
    // Validate the entire batch before accepting any part of it.
    for(UInt32 i=0;i<count;++i){auto& p=events[i];auto s=parameterAddress(p.parameter,p.scope,p.element);if(s)return s;
        if(p.eventType==kParameterEvent_Immediate){if(!std::isfinite(p.eventValues.immediate.value))return kAudioUnitErr_InvalidParameterValue;}
        else if(p.eventType==kParameterEvent_Ramped){if(discrete(p.parameter)||!std::isfinite(p.eventValues.ramp.startValue)||!std::isfinite(p.eventValues.ramp.endValue))return kAudioUnitErr_InvalidParameterValue;}
        else return kAudioUnitErr_InvalidParameterValue;
    }
    for(UInt32 i=0;i<count;++i){auto& p=events[i];Event e;e.currentRenderOnly=true;e.kind=1;e.id=p.parameter;
        if(p.eventType==kParameterEvent_Immediate){e.offset=p.eventValues.immediate.bufferOffset;e.value=p.eventValues.immediate.value;}
        else{e.kind=2;e.offset=p.eventValues.ramp.startBufferOffset;e.duration=p.eventValues.ramp.durationInFrames;e.value=p.eventValues.ramp.startValue;e.end=p.eventValues.ramp.endValue;}
        auto s=unit(self).enqueue(e);if(s)return s;
    }return noErr;
}
static OSStatus midi(void* self,UInt32 status,UInt32 a,UInt32 b,UInt32 offset){if(status>255||a>127||b>127)return paramErr;
    Event e;e.status=status;e.a=a;e.b=b;e.offset=offset;return unit(self).enqueue(e);
}
static OSStatus sysex(void*,const UInt8*,UInt32){return noErr;}
static OSStatus initialize(void* self){try{auto& u=unit(self);if(u.initialized)return noErr;
    u.left.resize(u.maxFrames);u.right.resize(u.maxFrames);u.interleaved.resize(u.maxFrames*2);u.engine.prepare(u.format.mSampleRate);u.reset();u.initialized=true;return noErr;
}catch(...){return kAudioUnitErr_FailedInitialization;}}
static OSStatus uninitialize(void* self){auto& u=unit(self);u.initialized=false;u.reset();return noErr;}
static OSStatus reset(void* self,UInt32 scope,UInt32 elem){if(scope!=0&&scope!=2)return kAudioUnitErr_InvalidScope;if(elem)return kAudioUnitErr_InvalidElement;unit(self).reset();return noErr;}
static void apply(Unit& u,const Event& e){
    if(e.kind){auto& r=u.ramps[e.id];r={};
        if(e.kind==2&&e.duration){r.active=true;r.duration=e.duration;r.elapsed=(uint32_t)std::min<int64_t>(e.duration,std::max<int64_t>(0,-e.offset));r.start=e.value;r.end=e.end;r.generation=u.generations[e.id];u.model().params[e.id]=normalized(e.id,r.start+(r.end-r.start)*double(r.elapsed)/r.duration);}
        else u.model().params[e.id]=normalized(e.id,e.kind==2?e.end:e.value);
    }else{int channel=e.status&15;switch(e.status&0xf0){
        case 0x90:if(e.b)u.engine.noteOn(e.a,e.b/127.f,-1,channel);else u.engine.noteOff(e.a,-1,channel);break;
        case 0x80:u.engine.noteOff(e.a,-1,channel);break;
        case 0xb0:if(e.a==120||e.a==123)u.engine.stopChannel(channel);break;
    }}
}
static OSStatus render(void* self,AudioUnitRenderActionFlags* flags,const AudioTimeStamp* ts,UInt32 bus,UInt32 frames,AudioBufferList* buffers){
    auto& u=unit(self);auto fail=[&](OSStatus s){u.lastError=s;return s;};
    if(!u.initialized)return fail(kAudioUnitErr_Uninitialized);if(bus)return fail(kAudioUnitErr_InvalidElement);
    if(frames>u.maxFrames)return fail(kAudioUnitErr_TooManyFramesToProcess);if(!ts||!buffers)return fail(paramErr);
    bool planar=u.format.mFormatFlags&kAudioFormatFlagIsNonInterleaved;UInt32 count=planar?2:1,channels=planar?1:2;
    if(buffers->mNumberBuffers!=count)return fail(kAudioUnitErr_FormatNotSupported);
    for(UInt32 i=0;i<count;++i){auto& b=buffers->mBuffers[i];if(b.mNumberChannels!=channels)return fail(kAudioUnitErr_FormatNotSupported);
        if((b.mData&&b.mDataByteSize<frames*channels*4)||(!b.mData&&!u.allocateBuffers))return fail(kAudioUnitErr_InvalidPropertyValue);}
    AudioUnitRenderActionFlags local=flags?*flags:0;
    auto* callbacks=u.callbacks.pin();
    local|=kAudioUnitRenderAction_PreRender;for(auto& n:callbacks->render)n.proc(n.user,&local,ts,bus,frames,buffers);local&=~kAudioUnitRenderAction_PreRender;
    bool repeat=u.cached&&(ts->mFlags&kAudioTimeStampSampleTimeValid)&&ts->mSampleTime==u.lastTime&&frames==u.lastFrames;
    // Scheduled parameters belong only to this render call, including cached pulls.
    u.ramps={};
    if(repeat||!frames){Event discarded;while(u.scheduled.pop(discarded)){};}
    if(!repeat&&frames){
        auto& h=callbacks->host;double bpm=0,beat=0,down=0;Float32 numerator=4;UInt32 denominator=4,offset=0;
        if(h.beatAndTempoProc&&h.beatAndTempoProc(h.hostUserData,&beat,&bpm)!=noErr)bpm=0;
        if(h.musicalTimeLocationProc&&h.musicalTimeLocationProc(h.hostUserData,&offset,&numerator,&denominator,&down)!=noErr){numerator=4;denominator=4;}
        u.model().setHostTiming(bpm,std::isfinite(numerator)&&numerator>0&&numerator<=64?(int)numerator:4,denominator<=64?(int)denominator:4);
        u.engine.setSample(u.model().samples.pin());u.engine.configure(u.model().settings());
        if(u.model().panic.exchange(false)){u.engine.allNotesOff();u.ramps={};}
        Note note;while(u.model().notes.pop(note))u.engine.previewEvent(note);
        Event event;
        if(u.overflow.exchange(false)){
            u.engine.allNotesOff();u.pendingCount=0;
            while(u.queue.pop(event)){}while(u.scheduled.pop(event)){}
        }
        while(u.pendingCount<eventCapacity&&u.queue.pop(event))u.pending[u.pendingCount++]=event;
        while(u.scheduled.pop(event)){
            if(u.pendingCount<eventCapacity)u.pending[u.pendingCount++]=event;
            else {u.engine.allNotesOff();u.pendingCount=0;while(u.queue.pop(event)){}while(u.scheduled.pop(event)){}break;}
        }
        std::sort(u.pending.begin(),u.pending.begin()+u.pendingCount,[](const Event&a,const Event&b){return a.offset==b.offset?a.order<b.order:a.offset<b.offset;});
        size_t cursor=0;float peak=0;u.cachedSilent=true;
        for(UInt32 frame=0;frame<frames;++frame){bool changed=false;
            // Bring ongoing ramps to this sample before MIDI creates a voice.
            for(uint32_t p=0;p<ParamCount;++p){auto& r=u.ramps[p];if(!r.active)continue;
                if(r.generation!=u.generations[p]){r.active=false;changed=true;continue;}
                double t=std::min(1.0,double(r.elapsed)/r.duration);u.model().params[p]=normalized(p,r.start+(r.end-r.start)*t);changed=true;}
            if(changed)u.engine.configure(u.model().settings());
            while(cursor<u.pendingCount&&u.pending[cursor].offset<=frame){auto& e=u.pending[cursor++];apply(u,e);
                // Events with equal offsets retain their order across both queues.
                if(e.kind)u.engine.configure(u.model().settings());}
            u.engine.render(u.left[frame],u.right[frame]);peak=std::max({peak,std::abs(u.left[frame]),std::abs(u.right[frame])});
            u.interleaved[frame*2]=u.left[frame];u.interleaved[frame*2+1]=u.right[frame];
            bool ended=false;
            for(uint32_t p=0;p<ParamCount;++p){auto& r=u.ramps[p];if(r.active&&++r.elapsed>=r.duration){
                u.model().params[p]=normalized(p,r.end);r.active=false;ended=true;}}
            if(ended)u.engine.configure(u.model().settings());
        }
        u.cachedSilent=peak==0;size_t remaining=0;for(;cursor<u.pendingCount;++cursor){auto e=u.pending[cursor];if(!e.currentRenderOnly){e.offset-=frames;u.pending[remaining++]=e;}}u.pendingCount=remaining;
        u.model().playhead=u.engine.playhead();u.model().activeVoices=u.engine.transportCount();u.model().meter=peak;u.model().samples.unpin();
        u.lastTime=ts->mSampleTime;u.lastFrames=frames;u.cached=ts->mFlags&kAudioTimeStampSampleTimeValid;
    }
    for(UInt32 i=0;i<count;++i){auto& b=buffers->mBuffers[i];float* source=planar?(i?u.right.data():u.left.data()):u.interleaved.data();
        UInt32 bytes=frames*channels*4;if(!b.mData)b.mData=source;else if(b.mData!=source)std::memcpy(b.mData,source,bytes);b.mDataByteSize=bytes;}
    if(u.cachedSilent||!frames)local|=kAudioUnitRenderAction_OutputIsSilence;else local&=~kAudioUnitRenderAction_OutputIsSilence;
    local|=kAudioUnitRenderAction_PostRender;for(auto& n:callbacks->render)n.proc(n.user,&local,ts,bus,frames,buffers);local&=~kAudioUnitRenderAction_PostRender;
    u.callbacks.unpin();if(flags)*flags=local;return noErr;
}
static OSStatus addListener(void* self,UInt32 id,AudioUnitPropertyListenerProc proc,void* user){if(!proc)return paramErr;auto& u=unit(self);std::lock_guard<std::mutex> lock(u.listenersMutex);
    for(auto& l:u.listeners)if(l.id==id&&l.proc==proc&&l.user==user)return noErr;u.listeners.push_back({id,proc,user});return noErr;}
static OSStatus removeListenerData(void* self,UInt32 id,AudioUnitPropertyListenerProc proc,void* user){auto& u=unit(self);std::lock_guard<std::mutex> lock(u.listenersMutex);auto& v=u.listeners;
    v.erase(std::remove_if(v.begin(),v.end(),[&](auto& l){return l.id==id&&l.proc==proc&&l.user==user;}),v.end());return noErr;}
static OSStatus removeListener(void* self,UInt32 id,AudioUnitPropertyListenerProc proc){auto& u=unit(self);std::lock_guard<std::mutex> lock(u.listenersMutex);auto& v=u.listeners;
    v.erase(std::remove_if(v.begin(),v.end(),[&](auto& l){return l.id==id&&l.proc==proc;}),v.end());return noErr;}
static OSStatus addNotify(void* self,AURenderCallback proc,void* user){if(!proc)return paramErr;unit(self).callbacks.update([&](Callbacks& c){for(auto& n:c.render)if(n.proc==proc&&n.user==user)return;c.render.push_back({proc,user});});return noErr;}
static OSStatus removeNotify(void* self,AURenderCallback proc,void* user){unit(self).callbacks.update([&](Callbacks& c){auto& v=c.render;v.erase(std::remove_if(v.begin(),v.end(),[&](auto& n){return n.proc==proc&&n.user==user;}),v.end());});return noErr;}
static OSStatus open(void* self,AudioComponentInstance instance){try{static_cast<Handle*>(self)->unit=new Unit(instance);return noErr;}catch(...){return kAudioUnitErr_FailedInitialization;}}
static OSStatus close(void* self){auto* h=static_cast<Handle*>(self);delete h->unit;delete h;return noErr;}
static AudioComponentMethod lookup(SInt16 selector){
#define METHOD(key,fn) case key:return reinterpret_cast<AudioComponentMethod>(fn)
    switch(selector){METHOD(kAudioUnitInitializeSelect,initialize);METHOD(kAudioUnitUninitializeSelect,uninitialize);
        METHOD(kAudioUnitGetPropertyInfoSelect,propertyInfo);METHOD(kAudioUnitGetPropertySelect,getProperty);METHOD(kAudioUnitSetPropertySelect,setProperty);
        METHOD(kAudioUnitGetParameterSelect,getParameter);METHOD(kAudioUnitSetParameterSelect,setParameter);METHOD(kAudioUnitScheduleParametersSelect,schedule);
        METHOD(kAudioUnitRenderSelect,render);METHOD(kAudioUnitResetSelect,reset);
        METHOD(kAudioUnitAddPropertyListenerSelect,addListener);METHOD(kAudioUnitRemovePropertyListenerSelect,removeListener);METHOD(kAudioUnitRemovePropertyListenerWithUserDataSelect,removeListenerData);
        METHOD(kAudioUnitAddRenderNotifySelect,addNotify);METHOD(kAudioUnitRemoveRenderNotifySelect,removeNotify);
        METHOD(kMusicDeviceMIDIEventSelect,midi);METHOD(kMusicDeviceSysExSelect,sysex);default:return nullptr;}
#undef METHOD
}
} // namespace au
extern "C" __attribute__((visibility("default"))) AudioComponentPlugInInterface* HasioLoopAUFactory(const AudioComponentDescription* description){
    if(!description||description->componentType!=kAudioUnitType_MusicDevice||description->componentSubType!=au::subtype||description->componentManufacturer!=au::manufacturer)return nullptr;
    try{auto* h=new au::Handle;h->api={au::open,au::close,au::lookup,nullptr};return &h->api;}catch(...){return nullptr;}
}

@interface HasioLoopAUContainer : NSView
- (instancetype)initWithContext:(std::shared_ptr<au::Context>)context;
@end
@implementation HasioLoopAUContainer { HLView* _editor; std::shared_ptr<au::Context> _context; }
- (instancetype)initWithContext:(std::shared_ptr<au::Context>)context {
    if((self=[super initWithFrame:NSMakeRect(0,0,hasio::editorWidth,hasio::editorHeight)])){
        _context=context;_editor=[[HLView alloc]initWithModel:context->model];[_editor setHosted:YES];[self addSubview:_editor];
        std::weak_ptr<au::Context> weak=context;
        auto gesture=[weak](uint32_t id,AudioUnitEventType type){if(auto c=weak.lock()){std::lock_guard<std::mutex> lock(c->mutex);if(!c->instance)return;
            AudioUnitEvent event{};event.mEventType=type;event.mArgument.mParameter={c->instance,id,0,0};AUEventListenerNotify(nullptr,nullptr,&event);}};
        [_editor setBeginEdit:[gesture](uint32_t id){gesture(id,kAudioUnitEvent_BeginParameterChangeGesture);}
            change:[weak](uint32_t id,double v){if(auto c=weak.lock()){std::lock_guard<std::mutex> lock(c->mutex);if(c->instance){AudioUnitParameter p{c->instance,id,0,0};AUParameterSet(nullptr,nullptr,&p,hasio::plain(id,v),0);}}}
            end:[gesture](uint32_t id){gesture(id,kAudioUnitEvent_EndParameterChangeGesture);}
            dirty:[weak]{if(auto c=weak.lock()){std::lock_guard<std::mutex> lock(c->mutex);if(c->instance){AudioUnitEvent event{};event.mEventType=kAudioUnitEvent_PropertyChange;event.mArgument.mProperty={c->instance,kAudioUnitProperty_ClassInfo,0,0};AUEventListenerNotify(nullptr,nullptr,&event);}}}];
    }return self;
}
- (void)dealloc {[_editor detach];}
- (void)viewWillMoveToWindow:(NSWindow*)newWindow {if(!newWindow)[_editor stopNotes];[super viewWillMoveToWindow:newWindow];}
@end
__attribute__((visibility("default")))
@interface HasioLoopAUViewFactory : NSObject <AUCocoaUIBase>
@end
@implementation HasioLoopAUViewFactory
- (unsigned)interfaceVersion {return 0;}
- (NSString*)description {return @"Hasio Loop";}
- (NSView*)uiViewForAudioUnit:(AudioUnit)unit withSize:(NSSize)size {
    std::shared_ptr<au::Context> context;UInt32 bytes=sizeof(context);
    if(AudioUnitGetProperty(unit,au::editorContextProperty,0,0,&context,&bytes)!=noErr||!context)return nil;
    return [[HasioLoopAUContainer alloc]initWithContext:context];
}
@end
