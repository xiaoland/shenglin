#include <aspl/Driver.hpp>
#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>

#include <array>
#include <atomic>
#include <climits>
#include <cstring>
#include <mutex>

namespace {

constexpr UInt32 SampleRate = 48000;
constexpr UInt32 Channels = 2;
constexpr UInt32 RingFrames = SampleRate;
constexpr UInt32 LatencyFrames = 512;
constexpr AudioObjectPropertySelector AudioPush = 'NAMP';
constexpr AudioObjectPropertySelector ClientMute = 'NAMM';

struct MuteCommand {
    int32_t pid;
    uint32_t muted;
};

class Microphone final : public aspl::IORequestHandler {
public:
    Microphone() {
        mach_timebase_info_data_t timebase{};
        mach_timebase_info(&timebase);
        expiryTicks_ = 250000000ULL * timebase.denom / timebase.numer;
    }

    void Push(CFPropertyListRef value) {
        std::lock_guard lock(pushMutex_);
        if (!value || CFGetTypeID(value) != CFDataGetTypeID()) return;
        auto data = static_cast<CFDataRef>(value);
        const CFIndex length = CFDataGetLength(data);
        if (length <= 0 || length % (Channels * sizeof(Float32)) != 0 ||
            length > 2048 * Channels * sizeof(Float32)) return;
        const UInt32 frames = UInt32(length / (Channels * sizeof(Float32)));
        const auto* bytes = CFDataGetBytePtr(data);
        const uint64_t now = mach_absolute_time();
        const uint64_t previous = lastPush_.load(std::memory_order_acquire);
        if (previous && now - previous > expiryTicks_) offset_.store(INT64_MIN, std::memory_order_release);
        const uint64_t first = written_.load(std::memory_order_relaxed);
        for (UInt32 frame = 0; frame < frames; ++frame) {
            for (UInt32 channel = 0; channel < Channels; ++channel) {
                uint32_t bits;
                std::memcpy(&bits, bytes + (frame * Channels + channel) * sizeof(bits), sizeof(bits));
                ring_[((first + frame) % RingFrames) * Channels + channel].store(bits, std::memory_order_relaxed);
            }
        }
        written_.store(first + frames, std::memory_order_release);
        lastPush_.store(now, std::memory_order_release);
    }

    void SetMute(CFPropertyListRef value) {
        std::lock_guard lock(muteMutex_);
        if (!value || CFGetTypeID(value) != CFDataGetTypeID()) return;
        auto data = static_cast<CFDataRef>(value);
        if (CFDataGetLength(data) != sizeof(MuteCommand)) return;
        MuteCommand command;
        std::memcpy(&command, CFDataGetBytePtr(data), sizeof(command));
        if (command.pid <= 0 || command.muted > 1) return;
        if (command.muted) {
            for (auto& pid : mutedPIDs_) {
                if (pid.load(std::memory_order_acquire) == command.pid) return;
            }
            for (auto& pid : mutedPIDs_) {
                int32_t empty = 0;
                if (pid.compare_exchange_strong(empty, command.pid, std::memory_order_release)) return;
            }
        } else {
            for (auto& pid : mutedPIDs_) {
                int32_t expected = command.pid;
                pid.compare_exchange_strong(expected, 0, std::memory_order_release);
            }
        }
    }

    void OnReadClientInput(const std::shared_ptr<aspl::Client>&,
                           const std::shared_ptr<aspl::Stream>&,
                           Float64, Float64 timestamp, void* bytes, UInt32 bytesCount) override {
        std::memset(bytes, 0, bytesCount);
        if (bytesCount % (Channels * sizeof(Float32)) != 0 || timestamp < 0) return;
        const UInt32 frames = bytesCount / (Channels * sizeof(Float32));
        const uint64_t now = mach_absolute_time();
        const uint64_t pushed = lastPush_.load(std::memory_order_acquire);
        if (!pushed || now - pushed > expiryTicks_) return;
        const uint64_t written = written_.load(std::memory_order_acquire);
        const int64_t time = int64_t(timestamp);
        int64_t offset = offset_.load(std::memory_order_acquire);
        int64_t first = time + offset;
        if (offset == INT64_MIN || first < 0 ||
            (uint64_t(first) <= written && written - uint64_t(first) > RingFrames) ||
            (first >= 0 && uint64_t(first) + frames > written + LatencyFrames * 2)) {
            if (written < frames + LatencyFrames) return;
            offset = int64_t(written - frames - LatencyFrames) - time;
            offset_.store(offset, std::memory_order_release);
            first = time + offset;
        }
        if (uint64_t(first) + frames > written) return;
        auto* output = static_cast<uint8_t*>(bytes);
        for (UInt32 frame = 0; frame < frames; ++frame) {
            for (UInt32 channel = 0; channel < Channels; ++channel) {
                const uint32_t bits = ring_[((uint64_t(first) + frame) % RingFrames) * Channels + channel]
                                          .load(std::memory_order_relaxed);
                std::memcpy(output + (frame * Channels + channel) * sizeof(bits), &bits, sizeof(bits));
            }
        }
    }

    void OnProcessClientInput(const std::shared_ptr<aspl::Client>& client,
                              const std::shared_ptr<aspl::Stream>& stream,
                              Float64, Float64, Float32* frames,
                              UInt32 frameCount, UInt32 channelCount) override {
        const int32_t pid = client ? client->GetProcessID() : 0;
        bool muted = pid <= 0;
        for (const auto& entry : mutedPIDs_) {
            muted |= entry.load(std::memory_order_acquire) == pid;
        }
        if (muted) std::memset(frames, 0, frameCount * channelCount * sizeof(Float32));
        else stream->ApplyProcessing(frames, frameCount, channelCount);
    }

private:
    std::mutex pushMutex_;
    std::mutex muteMutex_;
    std::array<std::atomic<uint32_t>, RingFrames * Channels> ring_{};
    std::array<std::atomic<int32_t>, 64> mutedPIDs_{};
    std::atomic<uint64_t> written_{0};
    std::atomic<uint64_t> lastPush_{0};
    std::atomic<int64_t> offset_{INT64_MIN};
    uint64_t expiryTicks_ = 0;
};

std::shared_ptr<aspl::Driver> CreateDriver() {
    auto context = std::make_shared<aspl::Context>();
    aspl::DeviceParameters parameters;
    parameters.Name = "Nearby Audio Microphone";
    parameters.Manufacturer = "Nearby Audio";
    parameters.DeviceUID = "local.nearbyaudio.virtual-microphone";
    parameters.ModelUID = parameters.DeviceUID;
    parameters.SampleRate = SampleRate;
    parameters.ChannelCount = Channels;
    auto device = std::make_shared<aspl::Device>(context, parameters);
    aspl::StreamParameters stream;
    stream.Direction = aspl::Direction::Input;
    stream.Format = { .mSampleRate = SampleRate, .mFormatID = kAudioFormatLinearPCM,
                      .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian |
                                      kAudioFormatFlagIsPacked,
                      .mBytesPerPacket = Channels * sizeof(Float32), .mFramesPerPacket = 1,
                      .mBytesPerFrame = Channels * sizeof(Float32), .mChannelsPerFrame = Channels,
                      .mBitsPerChannel = 32 };
    device->AddStreamAsync(stream);
    auto microphone = std::make_shared<Microphone>();
    auto empty = []() -> CFPropertyListRef { return CFDataCreate(kCFAllocatorDefault, nullptr, 0); };
    device->RegisterCustomProperty(AudioPush, empty,
        [microphone](CFPropertyListRef data) { microphone->Push(data); });
    device->RegisterCustomProperty(ClientMute, empty,
        [microphone](CFPropertyListRef data) { microphone->SetMute(data); });
    device->SetIOHandler(microphone);
    auto plugin = std::make_shared<aspl::Plugin>(context);
    plugin->AddDevice(device);
    return std::make_shared<aspl::Driver>(context, plugin);
}

} // namespace

extern "C" void* NearbyAudioDriverCreate(CFAllocatorRef, CFUUIDRef typeUUID) {
    if (!CFEqual(typeUUID, kAudioServerPlugInTypeUUID)) return nullptr;
    static auto driver = CreateDriver();
    return driver->GetReference();
}
