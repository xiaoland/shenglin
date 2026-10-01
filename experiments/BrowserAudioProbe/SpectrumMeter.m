#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <stdatomic.h>
#import <signal.h>
#import <math.h>

// 只保存两个频点的幅度，不存储 PCM；Tap 不静音、不重放、不改变默认设备。
typedef struct {
    double coefficient[2], previous[2], earlier[2];
    unsigned int frames, window;
    _Atomic double amplitude[2];
    _Atomic unsigned long completed;
} Meter;
static void Configure(Meter *meter, double rate) {
    memset(meter,0,sizeof(*meter));
    meter->window=(unsigned int)(rate/2);
    meter->coefficient[0]=2*cos(2*M_PI*440/rate);
    meter->coefficient[1]=2*cos(2*M_PI*660/rate);
}
static void Sample(Meter *meter, double sample) {
    for (int i=0;i<2;i++) {
        double current=sample+meter->coefficient[i]*meter->previous[i]-meter->earlier[i];
        meter->earlier[i]=meter->previous[i];meter->previous[i]=current;
    }
    if (++meter->frames!=meter->window) return;
    for (int i=0;i<2;i++) {
        double a=meter->previous[i],b=meter->earlier[i];
        atomic_store(&meter->amplitude[i],2*sqrt(fmax(0,a*a+b*b-meter->coefficient[i]*a*b))/meter->window);
        meter->previous[i]=meter->earlier[i]=0;
    }
    meter->frames=0;atomic_fetch_add(&meter->completed,1);
}
static volatile sig_atomic_t stopping=0;
static void Stop(int signal) { stopping=1; }
static void Require(OSStatus status, NSString *operation) {
    if (status) @throw [NSException exceptionWithName:@"CoreAudio" reason:[NSString stringWithFormat:@"%@: %d",operation,(int)status] userInfo:nil];
}
static int Measure(int argc,char **argv) {
    @autoreleasepool {
        if (argc==2 && strcmp(argv[1],"--self-test")==0) {
            Meter meter;Configure(&meter,48000);
            for (int i=0;i<24000;i++) Sample(&meter,0.002*sin(2*M_PI*440*i/48000)+0.0004*sin(2*M_PI*660*i/48000));
            assert(fabs(atomic_load(&meter.amplitude[0])-0.002)<1e-8);
            assert(fabs(atomic_load(&meter.amplitude[1])-0.0004)<1e-8);
            puts("通过：两个频点的幅度估计，包含 0.2 增益。");return 0;
        }
        if (argc!=3) { fprintf(stderr,"usage: SpectrumMeter PID seconds | --self-test\n");return 2; }
        char *pidEnd=NULL,*durationEnd=NULL;
        long requestedPID=strtol(argv[1],&pidEnd,10),seconds=strtol(argv[2],&durationEnd,10);
        if (*pidEnd || *durationEnd || requestedPID<=0 || requestedPID>INT_MAX || seconds<1 || seconds>300) return 2;
        pid_t pid=(pid_t)requestedPID;
        AudioObjectID process=0,tap=0,aggregate=0;
        AudioDeviceIOProcID io=NULL;
        BOOL started=NO;int result=0;
        @try {
            AudioObjectPropertyAddress address={kAudioHardwarePropertyTranslatePIDToProcessObject,kAudioObjectPropertyScopeGlobal,0};
            UInt32 size=sizeof(process);
            Require(AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,sizeof(pid),&pid,&size,&process),@"find process");
            if (!process) @throw [NSException exceptionWithName:@"Target" reason:@"没有找到指定 PID 的音频对象" userInfo:nil];
            fprintf(stderr,"METER_TARGET pid=%d object=%u\n",pid,process);
            CATapDescription *description=[[CATapDescription alloc] initMonoMixdownOfProcesses:@[@(process)]];
            description.name=@"声邻合成音频谱验证";description.privateTap=YES;description.muteBehavior=CATapUnmuted;
            Require(AudioHardwareCreateProcessTap(description,&tap),@"create tap");
            fprintf(stderr,"METER_TAP_CREATED object=%u\n",tap);
            AudioStreamBasicDescription format={0};
            address.mSelector=kAudioTapPropertyFormat;size=sizeof(format);
            Require(AudioObjectGetPropertyData(tap,&address,0,NULL,&size,&format),@"tap format");
            if (format.mFormatID!=kAudioFormatLinearPCM || !(format.mFormatFlags&kAudioFormatFlagIsFloat) ||
                format.mBitsPerChannel!=32 || format.mChannelsPerFrame!=1 || format.mSampleRate<8000)
                @throw [NSException exceptionWithName:@"Format" reason:@"仅支持单声道 Float32 Tap" userInfo:nil];
            NSDictionary *device=@{@kAudioAggregateDeviceNameKey:@"声邻频谱验证（临时）",
                @kAudioAggregateDeviceUIDKey:NSUUID.UUID.UUIDString,@kAudioAggregateDeviceIsPrivateKey:@YES,
                @kAudioAggregateDeviceTapAutoStartKey:@YES,@kAudioAggregateDeviceTapListKey:@[
                    @{@kAudioSubTapUIDKey:description.UUID.UUIDString,@kAudioSubTapDriftCompensationKey:@YES}]};
            Require(AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)device,&aggregate),@"create aggregate");
            fprintf(stderr,"METER_AGGREGATE_CREATED object=%u\n",aggregate);
            __block Meter meter;Configure(&meter,format.mSampleRate);
            __block _Atomic unsigned long invalidBuffers=0;
            Require(AudioDeviceCreateIOProcIDWithBlock(&io,aggregate,NULL,
                ^(const AudioTimeStamp *now,const AudioBufferList *input,const AudioTimeStamp *inputTime,AudioBufferList *output,const AudioTimeStamp *outputTime) {
                    if (!input || input->mNumberBuffers!=1 || input->mBuffers[0].mNumberChannels!=1 ||
                        !input->mBuffers[0].mData || input->mBuffers[0].mDataByteSize%sizeof(float)) {
                        atomic_fetch_add(&invalidBuffers,1);return;
                    }
                    const float *samples=input->mBuffers[0].mData;
                    for (UInt32 i=0;i<input->mBuffers[0].mDataByteSize/sizeof(float);i++) Sample(&meter,samples[i]);
                }),@"create IO callback");
            fprintf(stderr,"METER_IO_CREATED\n");
            Require(AudioDeviceStart(aggregate,io),@"start meter");started=YES;
            // 启动调用可能阻塞；此前保留信号默认行为，使调用者仍能终止探针。
            signal(SIGINT,Stop);signal(SIGTERM,Stop);
            fprintf(stderr,"METER_READY pid=%d object=%u sampleRate=%.0f\n",pid,process,format.mSampleRate);
            NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];unsigned long last=0;
            while (!stopping && [end timeIntervalSinceNow]>0) {
                unsigned long count=atomic_load(&meter.completed);
                if (count!=last) {
                    printf("{\"time\":%.6f,\"window\":%lu,\"a440\":%.9f,\"b660\":%.9f,\"invalidBuffers\":%lu}\n",
                        NSDate.date.timeIntervalSince1970,count,atomic_load(&meter.amplitude[0]),atomic_load(&meter.amplitude[1]),atomic_load(&invalidBuffers));
                    fflush(stdout);last=count;
                }
                usleep(50000);
            }
            if (!last || atomic_load(&invalidBuffers)) { fprintf(stderr,"没有有效音频数据，不能作为输出证据\n");result=1; }
        } @catch (NSException *error) { fprintf(stderr,"%s\n",error.reason.UTF8String);result=1; }
        @finally {
            if (started) AudioDeviceStop(aggregate,io);
            if (io) AudioDeviceDestroyIOProcID(aggregate,io);
            if (aggregate) AudioHardwareDestroyAggregateDevice(aggregate);
            if (tap) AudioHardwareDestroyProcessTap(tap);
        }
        return result;
    }
}

int main(int argc,char **argv) {
    @autoreleasepool {
        NSNumber *target=NSBundle.mainBundle.infoDictionary[@"ProbeTargetPID"];
        if (argc!=1 || !target) return Measure(argc,argv);
        NSString *pid=target.stringValue;
        NSString *duration=[NSBundle.mainBundle.infoDictionary[@"ProbeDuration"] stringValue];
        NSURL *folder=NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent;
        if (!freopen([[folder URLByAppendingPathComponent:@"spectrum-app.jsonl"] fileSystemRepresentation],"w",stdout) ||
            !freopen([[folder URLByAppendingPathComponent:@"spectrum-app.stderr"] fileSystemRepresentation],"w",stderr)) return 1;
        fprintf(stderr,"METER_APP bundle=%s pid=%d\n",NSBundle.mainBundle.bundleIdentifier.UTF8String,getpid());
        NSApplication *app=NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        // 系统权限提示需要正常应用身份；保持主事件循环可响应，音频启动在后台执行。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            char *arguments[]={argv[0],(char *)pid.UTF8String,(char *)duration.UTF8String,NULL};
            int result=Measure(3,arguments);
            fprintf(stderr,"METER_FINISHED result=%d\n",result);
            exit(result);
        });
        [app run];
        return 0;
    }
}
