#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <libproc.h>
#import <stdatomic.h>
#import <signal.h>

static volatile sig_atomic_t stopping=0;
static void Stop(int signal) { stopping=1; }
static void Check(OSStatus status,NSString *operation) {
    if (status) @throw [NSException exceptionWithName:@"CoreAudio"
        reason:[NSString stringWithFormat:@"%@: %d",operation,(int)status] userInfo:nil];
}
static AudioObjectPropertyAddress Address(AudioObjectPropertySelector selector,AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){selector,scope,kAudioObjectPropertyElementMain};
}
static AudioObjectID DefaultOutput(void) {
    AudioObjectID device=0;UInt32 size=sizeof(device);
    AudioObjectPropertyAddress address=Address(kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal);
    Check(AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,0,NULL,&size,&device),@"default output");
    return device;
}
static NSDictionary *OutputState(AudioObjectID device) {
    CFStringRef uid=NULL;UInt32 size=sizeof(uid);
    AudioObjectPropertyAddress address=Address(kAudioDevicePropertyDeviceUID,kAudioObjectPropertyScopeGlobal);
    Check(AudioObjectGetPropertyData(device,&address,0,NULL,&size,&uid),@"output UID");
    NSString *identifier=CFBridgingRelease(uid);
    Float32 volume=0;size=sizeof(volume);
    address=Address(kAudioDevicePropertyVolumeScalar,kAudioObjectPropertyScopeOutput);
    OSStatus status=AudioObjectGetPropertyData(device,&address,0,NULL,&size,&volume);
    return @{@"object":@(device),@"uid":identifier,@"volumeStatus":@(status),
             @"volume":status?NSNull.null:@(volume)};
}
static void Emit(NSDictionary *record) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    fwrite(data.bytes,1,data.length,stdout);putchar('\n');fflush(stdout);
}
static BOOL Apply(const AudioBufferList *input,AudioBufferList *output,float gain) {
    if (!output) return NO;
    for (UInt32 i=0;i<output->mNumberBuffers;i++)
        if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData,0,output->mBuffers[i].mDataByteSize);
    if (!input || input->mNumberBuffers!=1 || output->mNumberBuffers!=1) return NO;
    const AudioBuffer *source=&input->mBuffers[0];AudioBuffer *target=&output->mBuffers[0];
    if (!source->mData || !target->mData || source->mNumberChannels!=2 || target->mNumberChannels!=2 ||
        source->mDataByteSize!=target->mDataByteSize || source->mDataByteSize%(2*sizeof(float))) return NO;
    const float *in=source->mData;float *out=target->mData;
    for (UInt32 i=0;i<source->mDataByteSize/sizeof(float);i++) out[i]=in[i]*gain;
    return YES;
}
static int Run(pid_t pid,int seconds,float gain) {
    AudioObjectID process=0,tap=0,aggregate=0,device=0;
    AudioDeviceIOProcID io=NULL;BOOL started=NO;int result=0;
    __block _Atomic unsigned long callbacks=0,invalid=0;
    __block UInt32 inCount=0,outCount=0,inChannels=0,outChannels=0,inBytes=0,outBytes=0;
    NSDictionary *before=nil;
    @try {
        char path[PROC_PIDPATHINFO_MAXSIZE]={0};
        if (pid<=0 || seconds<1 || seconds>120 || !isfinite(gain) || gain<0 || gain>1 ||
            proc_pidpath(pid,path,sizeof(path))<=0 || strcmp(path,"/usr/bin/afplay"))
            @throw [NSException exceptionWithName:@"Target" reason:@"仅允许指定的 afplay 合成音源，时长 1..120 秒，增益 0..1" userInfo:nil];
        AudioObjectPropertyAddress address=Address(kAudioHardwarePropertyTranslatePIDToProcessObject,kAudioObjectPropertyScopeGlobal);
        UInt32 size=sizeof(process);
        Check(AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,sizeof(pid),&pid,&size,&process),@"source process");
        device=DefaultOutput();before=OutputState(device);
        address=Address(kAudioDevicePropertyStreams,kAudioObjectPropertyScopeInput);size=0;
        Check(AudioObjectGetPropertyDataSize(device,&address,0,NULL,&size),@"physical input streams");
        if (size) @throw [NSException exceptionWithName:@"Route" reason:@"本实验只接受没有物理输入流的默认输出设备" userInfo:nil];
        NSString *uid=before[@"uid"];
        CATapDescription *description=[[CATapDescription alloc] initWithProcesses:@[@(process)] andDeviceUID:uid withStream:0];
        description.name=@"声邻独立音源重放实验";description.privateTap=YES;
        // 仅读取期间抑制原声；实验退出后由系统恢复源进程到硬件的播放路径。
        description.muteBehavior=CATapMutedWhenTapped;
        Check(AudioHardwareCreateProcessTap(description,&tap),@"create tap");
        AudioStreamBasicDescription format={0};size=sizeof(format);
        address=Address(kAudioTapPropertyFormat,kAudioObjectPropertyScopeGlobal);
        Check(AudioObjectGetPropertyData(tap,&address,0,NULL,&size,&format),@"tap format");
        if (format.mFormatID!=kAudioFormatLinearPCM || !(format.mFormatFlags&kAudioFormatFlagIsFloat) ||
            (format.mFormatFlags&kAudioFormatFlagIsNonInterleaved) || format.mBitsPerChannel!=32 || format.mChannelsPerFrame!=2)
            @throw [NSException exceptionWithName:@"Format" reason:@"本实验只支持双声道交错 Float32" userInfo:nil];
        NSDictionary *composition=@{@kAudioAggregateDeviceNameKey:@"声邻重放实验（临时）",
            @kAudioAggregateDeviceUIDKey:NSUUID.UUID.UUIDString,@kAudioAggregateDeviceIsPrivateKey:@YES,
            @kAudioAggregateDeviceMainSubDeviceKey:uid,
            @kAudioAggregateDeviceSubDeviceListKey:@[@{@kAudioSubDeviceUIDKey:uid}],
            @kAudioAggregateDeviceTapAutoStartKey:@YES,
            @kAudioAggregateDeviceTapListKey:@[@{@kAudioSubTapUIDKey:description.UUID.UUIDString,
                @kAudioSubTapDriftCompensationKey:@YES}]};
        Check(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)composition,&aggregate),@"create aggregate");
        Check(AudioDeviceCreateIOProcIDWithBlock(&io,aggregate,NULL,
            ^(const AudioTimeStamp *now,const AudioBufferList *input,const AudioTimeStamp *inputTime,
              AudioBufferList *output,const AudioTimeStamp *outputTime) {
                if (!Apply(input,output,gain)) {
                    inCount=input?input->mNumberBuffers:0;outCount=output?output->mNumberBuffers:0;
                    if (inCount) { inChannels=input->mBuffers[0].mNumberChannels;inBytes=input->mBuffers[0].mDataByteSize; }
                    if (outCount) { outChannels=output->mBuffers[0].mNumberChannels;outBytes=output->mBuffers[0].mDataByteSize; }
                    atomic_fetch_add(&invalid,1);
                }
                atomic_fetch_add(&callbacks,1);
            }),@"create IO callback");
        Check(AudioDeviceStart(aggregate,io),@"start relay");started=YES;
        signal(SIGINT,Stop);signal(SIGTERM,Stop);
        Emit(@{@"event":@"ready",@"time":@(NSDate.date.timeIntervalSince1970),@"pid":@(getpid()),
            @"targetPID":@(pid),@"targetObject":@(process),@"tap":@(tap),@"aggregate":@(aggregate),
            @"gain":@(gain),@"sampleRate":@(format.mSampleRate),@"outputBefore":before});
        NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
        while (!stopping && [end timeIntervalSinceNow]>0 && !atomic_load(&invalid)) {
            if (DefaultOutput()!=device) @throw [NSException exceptionWithName:@"Route" reason:@"默认路由变化，结束实验" userInfo:nil];
            usleep(50000);
        }
        if (!atomic_load(&callbacks) || atomic_load(&invalid)) result=1;
    } @catch (NSException *error) { Emit(@{@"event":@"error",@"message":error.reason});result=1; }
    @finally {
        if (started) AudioDeviceStop(aggregate,io);
        if (io) AudioDeviceDestroyIOProcID(aggregate,io);
        if (aggregate) AudioHardwareDestroyAggregateDevice(aggregate);
        if (tap) AudioHardwareDestroyProcessTap(tap);
    }
    Emit(@{@"event":@"finished",@"time":@(NSDate.date.timeIntervalSince1970),@"result":@(result),
        @"callbacks":@(atomic_load(&callbacks)),@"invalidBuffers":@(atomic_load(&invalid)),
        @"bufferShape":@[@(inCount),@(outCount),@(inChannels),@(outChannels),@(inBytes),@(outBytes)],
        @"outputAfter":OutputState(DefaultOutput())});
    return result;
}
int main(int argc,char **argv) {
    @autoreleasepool {
        if (argc==2 && !strcmp(argv[1],"--self-test")) {
            float in[4]={.002,-.002,.001,-.001},out[4]={0};
            AudioBufferList input={1,{{2,sizeof(in),in}}},output={1,{{2,sizeof(out),out}}};
            assert(Apply(&input,&output,.2));assert(fabs(out[0]-.0004)<1e-9);assert(in[0]==.002f);
            assert(Apply(&input,&output,0));assert(out[0]==0);
            output.mBuffers[0].mNumberChannels=1;assert(!Apply(&input,&output,.2));
            puts("通过：立体声增益、零增益与格式拒绝。");return 0;
        }
        NSDictionary *config=NSBundle.mainBundle.infoDictionary;
        if (!config[@"ProbeTargetPID"]) return 2;
        NSURL *folder=NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent;
        if (!freopen([[folder URLByAppendingPathComponent:@"relay.jsonl"] fileSystemRepresentation],"w",stdout)) return 1;
        NSApplication *app=NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            @autoreleasepool { exit(Run([config[@"ProbeTargetPID"] intValue],
                [config[@"ProbeDuration"] intValue],[config[@"ProbeGain"] floatValue])); }
        });
        [app run];return 0;
    }
}
