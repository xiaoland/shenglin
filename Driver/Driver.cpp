#include <aspl/Driver.hpp>
#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <climits>
#include <cstring>
#include <mutex>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

namespace {

constexpr UInt32 SampleRate = 48000;
constexpr UInt32 Channels = 2;
constexpr UInt32 RingFrames = SampleRate;
constexpr UInt32 MaxPushFrames = 2048;
// 留出一个最大供音包的余量，读取周期才能跨越两次分批供音之间的间隔。
constexpr UInt32 LatencyFrames = MaxPushFrames;
constexpr AudioObjectPropertySelector AudioPush = 'NAMP';
constexpr AudioObjectPropertySelector DeviceMute = 'NAMD';
constexpr AudioObjectPropertySelector DeviceList = 'NADS';
constexpr AudioObjectPropertySelector Diagnostics = 'NAMT';
constexpr AudioObjectPropertySelector ClientDiagnostics = 'NAMC';
constexpr AudioObjectPropertySelector AudioTrace = 'NAMA';
constexpr const char* DevicePrefix = "local.nearbyaudio.virtual-microphone.";
constexpr UInt32 TraceSlots = 128;

struct TraceBatchHeader {
    UInt32 magic = 'NATR';
    UInt32 version = 1;
    uint64_t lostBlocks = 0;
    UInt32 blockCount = 0;
    UInt32 reserved = 0;
};

struct TraceBlockHeader {
    uint64_t sequence;
    uint64_t hostTime;
    int64_t sampleTime;
    UInt32 pid;
    UInt32 clientID;
    UInt32 sampleRate;
    UInt32 channels;
    UInt32 frames;
    UInt32 muted;
};
static_assert(sizeof(TraceBatchHeader) == 24 && sizeof(TraceBlockHeader) == 48);

class Microphone final : public aspl::IORequestHandler {
public:
    struct Counters {
        uint64_t staleFrames;
        uint64_t primingFrames;
        uint64_t aheadFrames;
        uint64_t maxGapFrames;
        uint64_t realignments;
    };
    struct ClientSnapshot {
        uint64_t key;
        uint64_t readFrames;
        uint64_t aheadFrames;
        uint64_t staleFrames;
        uint64_t primingFrames;
        uint64_t blockedFrames;
        uint64_t timestampSkips;
    };
    static constexpr size_t MaxClients = 16;

    explicit Microphone(UInt32 sampleRate = SampleRate, UInt32 channels = Channels)
        : sampleRate_(sampleRate), channels_(channels), ringFrames_(sampleRate),
          ring_(new std::atomic<uint32_t>[sampleRate * channels]()), trace_(new TraceSlot[TraceSlots]) {
        mach_timebase_info_data_t timebase{};
        mach_timebase_info(&timebase);
        expiryTicks_ = 250000000ULL * timebase.denom / timebase.numer;
    }

    void Push(CFPropertyListRef value) {
        std::lock_guard lock(pushMutex_);
        if (!value || CFGetTypeID(value) != CFDataGetTypeID()) return;
        auto data = static_cast<CFDataRef>(value);
        const CFIndex length = CFDataGetLength(data);
        if (length <= 0 || length % (channels_ * sizeof(Float32)) != 0 ||
            length > MaxPushFrames * channels_ * sizeof(Float32)) return;
        const UInt32 frames = UInt32(length / (channels_ * sizeof(Float32)));
        const auto* bytes = CFDataGetBytePtr(data);
        const uint64_t now = mach_absolute_time();
        const uint64_t previous = lastPush_.load(std::memory_order_acquire);
        const uint64_t first = written_.load(std::memory_order_relaxed);
        if (previous && now - previous > expiryTicks_) {
            firstFreshFrame_.store(first, std::memory_order_release);
            offset_.store(INT64_MIN, std::memory_order_release);
        }
        for (UInt32 frame = 0; frame < frames; ++frame) {
            for (UInt32 channel = 0; channel < channels_; ++channel) {
                uint32_t bits;
                std::memcpy(&bits, bytes + (frame * channels_ + channel) * sizeof(bits), sizeof(bits));
                ring_[((first + frame) % ringFrames_) * channels_ + channel].store(bits, std::memory_order_relaxed);
            }
        }
        written_.store(first + frames, std::memory_order_release);
        lastPush_.store(now, std::memory_order_release);
    }

    void SetMute(bool muted) { muted_.store(muted, std::memory_order_release); }
    bool IsMuted() const { return muted_.load(std::memory_order_acquire); }
    Counters GetCounters() const {
        return {staleFrames_.load(), primingFrames_.load(), aheadFrames_.load(),
            maxGapFrames_.load(), realignments_.load()};
    }
    std::array<ClientSnapshot, MaxClients> GetClientCounters() const {
        std::array<ClientSnapshot, MaxClients> result{};
        for (size_t i = 0; i < MaxClients; ++i) {
            const auto& item = clients_[i];
            result[i] = {item.key.load(), item.readFrames.load(), item.aheadFrames.load(),
                         item.staleFrames.load(), item.primingFrames.load(),
                         item.blockedFrames.load(), item.timestampSkips.load()};
        }
        return result;
    }

    CFDataRef DrainTrace() {
        std::lock_guard lock(traceDrainMutex_);
        const auto newest = traceSequence_.load(std::memory_order_acquire);
        auto first = drainedTraceSequence_ + 1;
        TraceBatchHeader batch;
        if (newest >= first + TraceSlots) {
            batch.lostBlocks = newest - first - TraceSlots + 1;
            first = newest - TraceSlots + 1;
        }
        std::vector<UInt8> data(sizeof(batch));
        auto drained = first - 1;
        for (auto sequence = first; sequence <= newest; ++sequence) {
            auto& slot = trace_[sequence % TraceSlots];
            const auto before = slot.version.load(std::memory_order_acquire);
            if (before < sequence * 2) break;
            drained = sequence;
            if (before != sequence * 2) { ++batch.lostBlocks; continue; }
            TraceBlockHeader header{sequence, slot.hostTime.load(), slot.sampleTime.load(),
                slot.pid.load(), slot.clientID.load(), sampleRate_, channels_,
                slot.frames.load(), slot.muted.load()};
            if (header.frames > MaxPushFrames) { ++batch.lostBlocks; continue; }
            const auto offset = data.size();
            data.resize(offset + sizeof(header) + header.frames * channels_ * sizeof(Float32));
            std::memcpy(data.data() + offset, &header, sizeof(header));
            auto* output = data.data() + offset + sizeof(header);
            for (UInt32 sample = 0; sample < header.frames * channels_; ++sample) {
                const auto bits = slot.samples[sample].load(std::memory_order_relaxed);
                std::memcpy(output + sample * sizeof(bits), &bits, sizeof(bits));
            }
            if (slot.version.load(std::memory_order_acquire) != before) {
                data.resize(offset);
                ++batch.lostBlocks;
                continue;
            }
            ++batch.blockCount;
        }
        drainedTraceSequence_ = drained;
        std::memcpy(data.data(), &batch, sizeof(batch));
        return CFDataCreate(kCFAllocatorDefault, data.data(), CFIndex(data.size()));
    }

    void OnReadClientInput(const std::shared_ptr<aspl::Client>& client,
                           const std::shared_ptr<aspl::Stream>&,
                           Float64, Float64 timestamp, void* bytes, UInt32 bytesCount) override {
        std::memset(bytes, 0, bytesCount);
        auto record = [&, this] { RecordTrace(client, timestamp, bytes, bytesCount); };
        struct OnExit { decltype(record)& action; ~OnExit() { action(); } } onExit{record};
        if (IsMuted()) return;
        if (bytesCount % (channels_ * sizeof(Float32)) != 0 || timestamp < 0) return;
        const UInt32 frames = bytesCount / (channels_ * sizeof(Float32));
        auto* clientCounter = CounterFor(client);
        if (clientCounter) {
            clientCounter->readFrames.fetch_add(frames, std::memory_order_relaxed);
            const auto previous = clientCounter->lastTimestampEnd.exchange(int64_t(timestamp) + frames);
            if (previous != INT64_MIN && previous != int64_t(timestamp))
                clientCounter->timestampSkips.fetch_add(1, std::memory_order_relaxed);
        }
        const uint64_t now = mach_absolute_time();
        const uint64_t pushed = lastPush_.load(std::memory_order_acquire);
        if (!pushed || now - pushed > expiryTicks_) {
            if (clientCounter) clientCounter->staleFrames.fetch_add(frames, std::memory_order_relaxed);
            RecordGap(frames, staleFrames_);
            return;
        }
        const uint64_t written = written_.load(std::memory_order_acquire);
        const uint64_t fresh = firstFreshFrame_.load(std::memory_order_acquire);
        const int64_t time = int64_t(timestamp);
        int64_t offset = offset_.load(std::memory_order_acquire);
        int64_t first = time + offset;
        const bool ahead = first >= 0 && uint64_t(first) + frames > written;
        if (offset == INT64_MIN || first < 0 || uint64_t(first) < fresh ||
            (uint64_t(first) <= written && written - uint64_t(first) > ringFrames_) ||
            ahead) {
            // 断源后只用重新供给的样本填满缓冲，不能重播上一次会话的音频。
            if (written < fresh || written - fresh < frames + LatencyFrames) {
                if (clientCounter) (ahead ? clientCounter->aheadFrames : clientCounter->primingFrames)
                    .fetch_add(frames, std::memory_order_relaxed);
                RecordGap(frames, ahead ? aheadFrames_ : primingFrames_);
                return;
            }
            const auto candidate = std::max(written - frames - LatencyFrames,
                                            lastDeliveredEnd_.load(std::memory_order_acquire));
            if (candidate + frames > written) {
                if (clientCounter) {
                    clientCounter->aheadFrames.fetch_add(frames, std::memory_order_relaxed);
                    clientCounter->blockedFrames.fetch_add(frames, std::memory_order_relaxed);
                }
                RecordGap(frames, aheadFrames_);
                return;
            }
            offset = int64_t(candidate) - time;
            offset_.store(offset, std::memory_order_release);
            realignments_.fetch_add(1, std::memory_order_relaxed);
            first = time + offset;
        }
        if (uint64_t(first) + frames > written) {
            if (clientCounter) clientCounter->aheadFrames.fetch_add(frames, std::memory_order_relaxed);
            RecordGap(frames, aheadFrames_);
            return;
        }
        gapFrames_.store(0, std::memory_order_relaxed);
        auto delivered = lastDeliveredEnd_.load(std::memory_order_relaxed);
        const auto end = uint64_t(first) + frames;
        while (end > delivered && !lastDeliveredEnd_.compare_exchange_weak(delivered, end, std::memory_order_release)) {}
        auto* output = static_cast<uint8_t*>(bytes);
        for (UInt32 frame = 0; frame < frames; ++frame) {
            for (UInt32 channel = 0; channel < channels_; ++channel) {
                const uint32_t bits = ring_[((uint64_t(first) + frame) % ringFrames_) * channels_ + channel]
                                          .load(std::memory_order_relaxed);
                std::memcpy(output + (frame * channels_ + channel) * sizeof(bits), &bits, sizeof(bits));
            }
        }
    }

private:
    struct TraceSlot {
        std::atomic<uint64_t> version{0}, hostTime{0};
        std::atomic<int64_t> sampleTime{0};
        std::atomic<UInt32> pid{0}, clientID{0}, frames{0}, muted{0};
        std::array<std::atomic<uint32_t>, MaxPushFrames * Channels> samples{};
    };

    void RecordTrace(const std::shared_ptr<aspl::Client>& client, Float64 timestamp,
                     const void* bytes, UInt32 bytesCount) {
        if (!bytes || bytesCount == 0 || bytesCount % (channels_ * sizeof(Float32)) != 0) return;
        const auto* input = static_cast<const UInt8*>(bytes);
        const UInt32 totalFrames = bytesCount / (channels_ * sizeof(Float32));
        for (UInt32 firstFrame = 0; firstFrame < totalFrames; firstFrame += MaxPushFrames) {
            const auto count = std::min(MaxPushFrames, totalFrames - firstFrame);
            const auto sequence = traceSequence_.fetch_add(1, std::memory_order_relaxed) + 1;
            auto& slot = trace_[sequence % TraceSlots];
            slot.version.store(sequence * 2 - 1, std::memory_order_release);
            slot.hostTime.store(mach_absolute_time(), std::memory_order_relaxed);
            slot.sampleTime.store(int64_t(timestamp) + firstFrame, std::memory_order_relaxed);
            slot.pid.store(client ? UInt32(client->GetProcessID()) : 0, std::memory_order_relaxed);
            slot.clientID.store(client ? client->GetClientID() : 0, std::memory_order_relaxed);
            slot.frames.store(count, std::memory_order_relaxed);
            slot.muted.store(IsMuted(), std::memory_order_relaxed);
            for (UInt32 sample = 0; sample < count * channels_; ++sample) {
                uint32_t bits;
                std::memcpy(&bits, input + (firstFrame * channels_ + sample) * sizeof(bits), sizeof(bits));
                slot.samples[sample].store(bits, std::memory_order_relaxed);
            }
            slot.version.store(sequence * 2, std::memory_order_release);
        }
    }

    struct ClientCounter {
        std::atomic<uint64_t> key{0}, readFrames{0}, aheadFrames{0}, staleFrames{0}, primingFrames{0},
            blockedFrames{0}, timestampSkips{0};
        std::atomic<int64_t> lastTimestampEnd{INT64_MIN};
    };
    ClientCounter* CounterFor(const std::shared_ptr<aspl::Client>& client) {
        if (!client) return nullptr;
        const auto key = ((uint64_t(uint32_t(client->GetProcessID())) + 1) << 32) | client->GetClientID();
        for (auto& counter : clients_) {
            auto known = counter.key.load(std::memory_order_acquire);
            if (known == key) return &counter;
            if (!known && counter.key.compare_exchange_strong(known, key, std::memory_order_acq_rel)) return &counter;
        }
        return nullptr;
    }
    void RecordGap(UInt32 frames, std::atomic<uint64_t>& counter) {
        counter.fetch_add(frames, std::memory_order_relaxed);
        const auto gap = gapFrames_.fetch_add(frames, std::memory_order_relaxed) + frames;
        auto maximum = maxGapFrames_.load(std::memory_order_relaxed);
        while (gap > maximum && !maxGapFrames_.compare_exchange_weak(maximum, gap, std::memory_order_relaxed)) {}
    }
    std::mutex pushMutex_;
    const UInt32 sampleRate_;
    const UInt32 channels_;
    const UInt32 ringFrames_;
    // 新设备及音频服务重启后保持静音，直到控制端明确应用状态。
    std::atomic<bool> muted_{true};
    std::unique_ptr<std::atomic<uint32_t>[]> ring_;
    std::unique_ptr<TraceSlot[]> trace_;
    std::atomic<uint64_t> traceSequence_{0};
    std::mutex traceDrainMutex_;
    uint64_t drainedTraceSequence_ = 0;
    std::atomic<uint64_t> written_{0};
    std::atomic<uint64_t> firstFreshFrame_{0};
    std::atomic<uint64_t> lastPush_{0};
    std::atomic<int64_t> offset_{INT64_MIN};
    std::atomic<uint64_t> lastDeliveredEnd_{0};
    std::atomic<uint64_t> staleFrames_{0}, primingFrames_{0}, aheadFrames_{0};
    std::atomic<uint64_t> gapFrames_{0}, maxGapFrames_{0}, realignments_{0};
    std::array<ClientCounter, MaxClients> clients_{};
    uint64_t expiryTicks_ = 0;
};

std::shared_ptr<aspl::Device> CreateDevice(std::shared_ptr<aspl::Context> context,
                                           const std::string& bundle, const std::string& name,
                                           UInt32 sampleRate = SampleRate, UInt32 channels = Channels) {
    aspl::DeviceParameters parameters;
    parameters.Name = "Nearby · " + name;
    parameters.Manufacturer = "Nearby Audio";
    parameters.DeviceUID = std::string(DevicePrefix) + bundle;
    parameters.ModelUID = parameters.DeviceUID;
    parameters.SampleRate = sampleRate;
    parameters.ChannelCount = channels;
    parameters.Latency = LatencyFrames;
    auto device = std::make_shared<aspl::Device>(context, parameters);
    aspl::StreamParameters stream;
    stream.Direction = aspl::Direction::Input;
    stream.Format = { .mSampleRate = Float64(sampleRate), .mFormatID = kAudioFormatLinearPCM,
                      .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian |
                                      kAudioFormatFlagIsPacked,
                      .mBytesPerPacket = channels * UInt32(sizeof(Float32)), .mFramesPerPacket = 1,
                      .mBytesPerFrame = channels * UInt32(sizeof(Float32)), .mChannelsPerFrame = channels,
                      .mBitsPerChannel = 32 };
    device->AddStreamAsync(stream);
    device->SetCanBeDefaultDevice(false);
    device->SetCanBeDefaultSystemDevice(false);
    auto microphone = std::make_shared<Microphone>(sampleRate, channels);
    auto empty = []() -> CFPropertyListRef { return CFDataCreate(kCFAllocatorDefault, nullptr, 0); };
    device->RegisterCustomProperty(AudioPush, empty,
        [microphone](CFPropertyListRef data) { microphone->Push(data); });
    device->RegisterCustomProperty(DeviceMute,
        [microphone]() -> CFPropertyListRef {
            UInt32 value = microphone->IsMuted();
            return CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(&value), sizeof(value));
        },
        [microphone](CFPropertyListRef value) {
            if (!value || CFGetTypeID(value) != CFDataGetTypeID()) return;
            auto data = static_cast<CFDataRef>(value);
            if (CFDataGetLength(data) != sizeof(UInt32)) return;
            UInt32 muted;
            std::memcpy(&muted, CFDataGetBytePtr(data), sizeof(muted));
            if (muted <= 1) microphone->SetMute(muted);
        });
    device->RegisterCustomProperty(Diagnostics,
        [microphone]() -> CFPropertyListRef {
            const auto counters = microphone->GetCounters();
            return CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(&counters), sizeof(counters));
        }, [](CFPropertyListRef) {});
    device->RegisterCustomProperty(ClientDiagnostics,
        [microphone]() -> CFPropertyListRef {
            const auto counters = microphone->GetClientCounters();
            return CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(counters.data()), sizeof(counters));
        }, [](CFPropertyListRef) {});
    device->RegisterCustomProperty(AudioTrace,
        [microphone]() -> CFPropertyListRef { return microphone->DrainTrace(); },
        [](CFPropertyListRef) {});
    device->SetIOHandler(microphone);
    return device;
}

class MicrophonePlugin final : public aspl::Plugin {
public:
    struct DeviceSpec {
        std::string name;
        UInt32 sampleRate;
        UInt32 channels;
    };

    explicit MicrophonePlugin(std::shared_ptr<aspl::Context> context)
        : aspl::Plugin(context), context_(context), storage_(context) {
        RegisterCustomProperty(DeviceList,
            [this]() -> CFPropertyListRef {
                std::lock_guard lock(mutex_);
                return CFDataCreate(nullptr, configuration_.data(), configuration_.size());
            }, [](CFPropertyListRef) {});
    }

    OSStatus Configure(CFPropertyListRef value, bool persist) {
        if (!value || CFGetTypeID(value) != CFDataGetTypeID()) return kAudioHardwareIllegalOperationError;
        auto data = static_cast<CFDataRef>(value);
        if (CFDataGetLength(data) > 32768) return kAudioHardwareBadPropertySizeError;
        auto list = CFPropertyListCreateWithData(nullptr, data, kCFPropertyListImmutable, nullptr, nullptr);
        if (!list) return kAudioHardwareIllegalOperationError;
        std::map<std::string, DeviceSpec> requested;
        bool valid = CFGetTypeID(list) == CFArrayGetTypeID();
        auto array = static_cast<CFArrayRef>(list);
        if (valid) valid = CFArrayGetCount(array) <= 32;
        for (CFIndex i = 0; valid && i < CFArrayGetCount(array); ++i) {
            auto item = CFArrayGetValueAtIndex(array, i);
            if (CFGetTypeID(item) != CFDictionaryGetTypeID()) { valid = false; break; }
            auto dict = static_cast<CFDictionaryRef>(item);
            auto bundle = String(CFDictionaryGetValue(dict, CFSTR("bundle")), 255);
            auto name = String(CFDictionaryGetValue(dict, CFSTR("name")), 160);
            UInt32 sampleRate = SampleRate, channels = Channels;
            auto rateValue = CFDictionaryGetValue(dict, CFSTR("sampleRate"));
            auto channelValue = CFDictionaryGetValue(dict, CFSTR("channels"));
            if ((rateValue == nullptr) != (channelValue == nullptr)) { valid = false; break; }
            if (rateValue) {
                if (CFGetTypeID(rateValue) != CFNumberGetTypeID() ||
                    CFGetTypeID(channelValue) != CFNumberGetTypeID()) { valid = false; break; }
                int rate = 0, count = 0;
                if (!CFNumberGetValue(static_cast<CFNumberRef>(rateValue), kCFNumberIntType, &rate) ||
                    !CFNumberGetValue(static_cast<CFNumberRef>(channelValue), kCFNumberIntType, &count) ||
                    rate < 8000 || rate > 192000 || count < 1 || count > 2) { valid = false; break; }
                sampleRate = UInt32(rate);
                channels = UInt32(count);
            }
            valid = !bundle.empty() && !name.empty() &&
                bundle.find_first_not_of("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-") == std::string::npos &&
                requested.emplace(bundle, DeviceSpec{name, sampleRate, channels}).second;
        }
        CFRelease(list);
        if (!valid) return kAudioHardwareIllegalOperationError;
        std::lock_guard lock(mutex_);
        // 先保存成功，再发布设备；重启后恢复相同 UID，不依赖 GUI 的启动顺序。
        if (persist && !storage_.WriteCustom("DedicatedMicrophones", data)) return kAudioHardwareUnspecifiedError;
        for (auto it = devices_.begin(); it != devices_.end();) {
            const auto wanted = requested.find(it->first);
            const auto old = specs_.find(it->first);
            if (wanted == requested.end() || old == specs_.end() ||
                old->second.sampleRate != wanted->second.sampleRate ||
                old->second.channels != wanted->second.channels) {
                it->second->SetIsAlive(false);
                RemoveDevice(it->second);
                it = devices_.erase(it);
            } else ++it;
        }
        for (const auto& [bundle, spec] : requested) {
            if (!devices_.count(bundle)) {
                auto device = CreateDevice(context_, bundle, spec.name, spec.sampleRate, spec.channels);
                devices_.emplace(bundle, device);
                AddDevice(device);
            }
        }
        specs_ = requested;
        configuration_.assign(CFDataGetBytePtr(data), CFDataGetBytePtr(data) + CFDataGetLength(data));
        return noErr;
    }

    OSStatus Restore() {
        auto [data, found] = storage_.ReadCustom("DedicatedMicrophones");
        if (!found) return noErr;
        const auto status = Configure(data, false);
        CFRelease(data);
        return status;
    }

    OSStatus SetPropertyData(AudioObjectID objectID, pid_t pid,
        const AudioObjectPropertyAddress* address, UInt32 qualifierSize, const void* qualifier,
        UInt32 size, const void* data) override {
        if (address && address->mSelector == DeviceList) {
            if (size != sizeof(CFPropertyListRef) || !data) return kAudioHardwareBadPropertySizeError;
            return Configure(*static_cast<const CFPropertyListRef*>(data), true);
        }
        return aspl::Plugin::SetPropertyData(objectID, pid, address, qualifierSize, qualifier, size, data);
    }
private:
    static std::string String(const void* value, size_t maxBytes) {
        if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return {};
        std::vector<char> bytes(maxBytes + 1);
        if (!CFStringGetCString(static_cast<CFStringRef>(value), bytes.data(), bytes.size(), kCFStringEncodingUTF8)) return {};
        return bytes.data();
    }
    std::shared_ptr<aspl::Context> context_;
    aspl::Storage storage_;
    std::mutex mutex_;
    std::map<std::string, std::shared_ptr<aspl::Device>> devices_;
    std::map<std::string, DeviceSpec> specs_;
    std::vector<UInt8> configuration_;
};

class MicrophoneDriver final : public aspl::Driver {
public:
    MicrophoneDriver(std::shared_ptr<aspl::Context> context, std::shared_ptr<MicrophonePlugin> plugin)
        : aspl::Driver(context, plugin), plugin_(plugin) {}
    OSStatus Initialize() override { return plugin_->Restore(); }
private:
    std::shared_ptr<MicrophonePlugin> plugin_;
};

std::shared_ptr<aspl::Driver> CreateDriver() {
    auto context = std::make_shared<aspl::Context>();
    return std::make_shared<MicrophoneDriver>(context, std::make_shared<MicrophonePlugin>(context));
}

} // namespace

extern "C" void* NearbyAudioDriverCreate(CFAllocatorRef, CFUUIDRef typeUUID) {
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) return nullptr;
    static auto driver = CreateDriver();
    return driver->GetReference();
}
