// 只读取或供给 声邻虚拟设备的合成样本，不访问物理麦克风。
#include <AudioUnit/AudioUnit.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <thread>
#include <array>
#include <mach/mach_time.h>
#include <unistd.h>

namespace {
AudioUnit unit = nullptr;
std::atomic<unsigned long long> samples{0}, nonzero{0}, errors{0};
std::atomic<unsigned long long> zeroFrames{0}, zeroRun{0}, maxZeroRun{0};
std::atomic<float> peak{0};
UInt32 inputChannels = 2;
struct LevelBin { unsigned long long hostTime; UInt32 frames; float rms; UInt32 zeroFrames; };
std::array<LevelBin, 16384> levels{};
std::atomic<size_t> levelCount{0};
std::atomic<long long> firstSampleTime{-1}, lastSampleEnd{-1};
std::atomic<unsigned long long> sampleTimeSkips{0}, callbackFrames{0};

void Check(OSStatus status, const char* operation) {
    if (status == noErr) return;
    std::fprintf(stderr, "%s 失败：%d\n", operation, status);
    std::exit(1);
}

AudioObjectID Device(const char* name, bool plugin = false) {
    if (std::strcmp(name, "default-input") == 0) {
        AudioObjectPropertyAddress address{kAudioHardwarePropertyDefaultInputDevice,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioObjectID device = kAudioObjectUnknown;
        UInt32 size = sizeof(device);
        Check(AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr,
                                         &size, &device), "查找物理麦克风");
        return device;
    }
    CFStringRef uid = CFStringCreateWithCString(nullptr, name, kCFStringEncodingUTF8);
    AudioObjectPropertyAddress address{plugin ? kAudioHardwarePropertyTranslateBundleIDToPlugIn : kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    Check(AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(uid),
                                    &uid, &size, &device), "查找虚拟麦克风");
    CFRelease(uid);
    if (device == kAudioObjectUnknown) {
        std::fputs("声邻 HAL 驱动未安装。\n", stderr);
        std::exit(1);
    }
    return device;
}

void SetData(AudioObjectID device, UInt32 selector, const void* bytes, size_t count) {
    auto data = CFDataCreate(nullptr, static_cast<const UInt8*>(bytes), count);
    if (!data) std::exit(1);
    AudioObjectPropertyAddress address{selector, kAudioObjectPropertyScopeGlobal, 0};
    const auto status = AudioObjectSetPropertyData(device, &address, 0, nullptr, sizeof(data), &data);
    CFRelease(data);
    Check(status, "写入驱动属性");
}

OSStatus Input(void*, AudioUnitRenderActionFlags* flags, const AudioTimeStamp* time,
               UInt32, UInt32 frames, AudioBufferList*) {
    if (frames > 8192) { errors.fetch_add(1); return kAudio_ParamError; }
    if (time->mFlags & kAudioTimeStampSampleTimeValid) {
        const auto start = static_cast<long long>(time->mSampleTime);
        auto previous = lastSampleEnd.exchange(start + frames);
        if (previous < 0) firstSampleTime.store(start);
        else if (previous != start) sampleTimeSkips.fetch_add(1);
    }
    callbackFrames.fetch_add(frames);
    float data[8192 * 2]{};
    AudioBufferList list{};
    list.mNumberBuffers = 1;
    list.mBuffers[0] = {inputChannels, frames * inputChannels * UInt32(sizeof(float)), data};
    const auto status = AudioUnitRender(unit, flags, time, 1, frames, &list);
    if (status != noErr) { errors.fetch_add(1); return status; }
    unsigned long long hits = 0;
    unsigned long long zeros = 0;
    auto run = zeroRun.load(std::memory_order_relaxed);
    auto maximumRun = maxZeroRun.load(std::memory_order_relaxed);
    float maximum = 0;
    double energy = 0;
    for (UInt32 i = 0; i < frames * inputChannels; ++i) {
        const float value = std::fabs(data[i]);
        hits += value > 0.01f;
        maximum = std::max(maximum, value);
        energy += double(data[i]) * data[i];
    }
    for (UInt32 frame = 0; frame < frames; ++frame) {
        bool silent = true;
        for (UInt32 channel = 0; channel < inputChannels; ++channel) {
            silent &= std::fabs(data[frame * inputChannels + channel]) <= 0.01f;
        }
        if (silent) {
            ++zeros;
            maximumRun = std::max(maximumRun, ++run);
        } else run = 0;
    }
    zeroFrames.fetch_add(zeros, std::memory_order_relaxed);
    zeroRun.store(run, std::memory_order_relaxed);
    auto previousRun = maxZeroRun.load(std::memory_order_relaxed);
    while (maximumRun > previousRun && !maxZeroRun.compare_exchange_weak(previousRun, maximumRun, std::memory_order_relaxed)) {}
    const auto bin = levelCount.fetch_add(1, std::memory_order_relaxed);
    if (bin < levels.size()) levels[bin] = {mach_absolute_time(), frames,
        float(std::sqrt(energy / (frames * inputChannels))), UInt32(zeros)};
    auto previous = peak.load();
    while (maximum > previous && !peak.compare_exchange_weak(previous, maximum)) {}
    samples.fetch_add(frames * inputChannels, std::memory_order_relaxed);
    nonzero.fetch_add(hits, std::memory_order_relaxed);
    return noErr;
}

void Read(AudioObjectID device, UInt32 channels = 2) {
    inputChannels = channels;
    AudioComponentDescription description{kAudioUnitType_Output, kAudioUnitSubType_HALOutput,
        kAudioUnitManufacturer_Apple, 0, 0};
    auto component = AudioComponentFindNext(nullptr, &description);
    if (!component) std::exit(1);
    Check(AudioComponentInstanceNew(component, &unit), "创建 AUHAL");
    UInt32 enabled = 1, disabled = 0;
    Check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input,
                              1, &enabled, sizeof(enabled)), "启用输入");
    Check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output,
                              0, &disabled, sizeof(disabled)), "关闭输出");
    Check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
                              0, &device, sizeof(device)), "选择虚拟设备");
    AudioStreamBasicDescription format{48000, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
        channels * 4, 1, channels * 4, channels, 32, 0};
    Check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                              1, &format, sizeof(format)), "设置样本格式");
    AURenderCallbackStruct callback{Input, nullptr};
    Check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
                              kAudioUnitScope_Global, 0, &callback, sizeof(callback)), "设置回调");
    Check(AudioUnitInitialize(unit), "初始化 AUHAL");
    Check(AudioOutputUnitStart(unit), "启动输入");
    std::cout << "ready " << getpid() << ' ' << device << std::endl;
    std::string command;
    while (std::getline(std::cin, command)) {
        if (command == "stats") {
            std::cout << samples.exchange(0) << ' ' << nonzero.exchange(0)
                      << ' ' << errors.exchange(0) << ' ' << zeroFrames.exchange(0)
                      << ' ' << maxZeroRun.exchange(0) << std::endl;
        } else if (command == "peak") {
            std::cout << peak.exchange(0) << std::endl;
        } else if (command == "timing") {
            std::cout << firstSampleTime.load() << ' ' << lastSampleEnd.load() << ' '
                      << callbackFrames.load() << ' ' << sampleTimeSkips.load() << std::endl;
        } else if (command == "bins") {
            Check(AudioOutputUnitStop(unit), "结束连续性采样");
            const auto count = std::min(levelCount.load(), levels.size());
            mach_timebase_info_data_t scale{};
            mach_timebase_info(&scale);
            std::cout << "bins " << count << std::endl;
            for (size_t i = 0; i < count; ++i) {
                const auto& bin = levels[i];
                std::cout << bin.hostTime * scale.numer / scale.denom / 1000 << ' '
                          << bin.frames << ' ' << bin.rms << ' ' << bin.zeroFrames << '\n';
            }
            std::cout.flush();
            break;
        } else if (command == "self 0" || command == "self 1") {
            UInt32 mute = command.back() == '1';
            AudioObjectPropertyAddress address{kAudioHardwarePropertyProcessInputMute,
                kAudioObjectPropertyScopeGlobal, 0};
            Check(AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr,
                                            sizeof(mute), &mute), "设置本进程静音");
            std::cout << "ok" << std::endl;
        } else if (command == "quit") break;
        else { std::fputs("未知读取命令\n", stderr); std::exit(2); }
    }
    if (command != "bins") Check(AudioOutputUnitStop(unit), "停止输入");
    Check(AudioUnitUninitialize(unit), "结束 AUHAL");
    Check(AudioComponentInstanceDispose(unit), "释放 AUHAL");
}
} // namespace

int main(int argc, char** argv) {
    if (argc < 2) return 2;
    if (std::strcmp(argv[1], "configure") == 0 && argc == 3) {
        std::ifstream file(argv[2], std::ios::binary);
        if (!file) return 2;
        std::vector<char> data((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
        SetData(Device("local.shenglin.driver", true), 'NADS', data.data(), data.size());
        return 0;
    }
    if (std::strcmp(argv[1], "configuration") == 0 && argc == 2) {
        auto plugin = Device("local.shenglin.driver", true);
        AudioObjectPropertyAddress address{'NADS', kAudioObjectPropertyScopeGlobal, 0};
        CFDataRef data = nullptr;
        UInt32 size = sizeof(data);
        Check(AudioObjectGetPropertyData(plugin, &address, 0, nullptr, &size, &data), "读取设备配置");
        if (!data) return 1;
        std::cout.write(reinterpret_cast<const char*>(CFDataGetBytePtr(data)), CFDataGetLength(data));
        CFRelease(data);
        return 0;
    }
    if (argc < 3) return 2;
    auto device = Device(argv[2]);
    if (std::strcmp(argv[1], "read") == 0 && argc == 3)
        Read(device, std::strcmp(argv[2], "default-input") == 0 ? 1 : 2);
    else if (std::strcmp(argv[1], "read-mono") == 0 && argc == 3)
        Read(device, 1);
    else if (std::strcmp(argv[1], "metrics") == 0 && argc == 3) {
        AudioObjectPropertyAddress address{'NAMT', kAudioObjectPropertyScopeGlobal, 0};
        CFDataRef data = nullptr;
        UInt32 size = sizeof(data);
        Check(AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &data), "读取连续性计数");
        struct Counters { uint64_t stale, priming, ahead, maxGap, realignments; } counters{};
        if (!data || CFDataGetLength(data) != sizeof(counters)) return 1;
        std::memcpy(&counters, CFDataGetBytePtr(data), sizeof(counters));
        CFRelease(data);
        std::cout << "{\"staleFrames\":" << counters.stale
                  << ",\"primingFrames\":" << counters.priming
                  << ",\"aheadFrames\":" << counters.ahead
                  << ",\"maxGapFrames\":" << counters.maxGap
                  << ",\"realignments\":" << counters.realignments << "}\n";
    }
    else if (std::strcmp(argv[1], "client-metrics") == 0 && argc == 3) {
        AudioObjectPropertyAddress address{'NAMC', kAudioObjectPropertyScopeGlobal, 0};
        CFDataRef data = nullptr;
        UInt32 size = sizeof(data);
        Check(AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &data), "读取客户端计数");
        struct ClientCounters { uint64_t key, read, ahead, stale, priming, blocked, timeSkips; };
        if (!data || CFDataGetLength(data) % sizeof(ClientCounters)) return 1;
        auto counters = reinterpret_cast<const ClientCounters*>(CFDataGetBytePtr(data));
        std::cout << '[';
        for (CFIndex i = 0, count = CFDataGetLength(data) / sizeof(ClientCounters); i < count; ++i) {
            if (!counters[i].key) continue;
            if (i) std::cout << ',';
            std::cout << "{\"pid\":" << uint32_t((counters[i].key >> 32) - 1)
                      << ",\"clientID\":" << uint32_t(counters[i].key)
                      << ",\"readFrames\":" << counters[i].read
                      << ",\"aheadFrames\":" << counters[i].ahead
                      << ",\"staleFrames\":" << counters[i].stale
                      << ",\"primingFrames\":" << counters[i].priming
                      << ",\"blockedFrames\":" << counters[i].blocked
                      << ",\"timestampSkips\":" << counters[i].timeSkips << '}';
        }
        std::cout << "]\n";
        CFRelease(data);
    }
    else if (std::strcmp(argv[1], "mute") == 0 && argc == 4) {
        if (std::strcmp(argv[3], "0") && std::strcmp(argv[3], "1")) return 2;
        uint32_t muted = argv[3][0] == '1';
        SetData(device, 'NAMD', &muted, sizeof(muted));
    } else if (std::strcmp(argv[1], "feed") == 0 && argc == 3) {
        float data[960 * 2];
        for (auto& sample : data) sample = 0.25f;
        auto deadline = std::chrono::steady_clock::now();
        for (;;) {
            SetData(device, 'NAMP', data, sizeof(data));
            deadline += std::chrono::milliseconds(20);
            std::this_thread::sleep_until(deadline);
        }
    } else return 2;
}
