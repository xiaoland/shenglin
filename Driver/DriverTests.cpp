#include "Driver.cpp"

#include <cassert>
#include <thread>

int main() {
    auto driver = CreateDriver();
    auto plugin = std::static_pointer_cast<MicrophonePlugin>(driver->GetPlugin());
    assert(plugin->GetDeviceCount() == 0);
    auto configure = [&](const char* xml) {
        auto data = CFDataCreate(nullptr, reinterpret_cast<const UInt8*>(xml), std::strlen(xml));
        auto result = plugin->Configure(data, false);
        CFRelease(data);
        return result;
    };
    assert(configure("<plist><array><dict><key>bundle</key><string>test.a</string><key>name</key><string>A</string></dict><dict><key>bundle</key><string>test.b</string><key>name</key><string>B</string></dict></array></plist>") == noErr);
    assert(plugin->GetDeviceCount() == 2);
    auto device = plugin->GetDeviceByIndex(0);
    assert(device && device->GetDeviceUID() == std::string(DevicePrefix) + "test.a");
    assert(device->GetStreamCount(aspl::Direction::Input) == 1);
    assert(device->GetStreamCount(aspl::Direction::Output) == 0);
    assert(!device->GetCanBeDefaultDevice());
    assert(configure("<plist><array><dict><key>bundle</key><string>test.a</string><key>name</key><string>A</string><key>sampleRate</key><integer>44100</integer><key>channels</key><integer>1</integer></dict><dict><key>bundle</key><string>test.b</string><key>name</key><string>B</string><key>sampleRate</key><integer>48000</integer><key>channels</key><integer>2</integer></dict></array></plist>") == noErr);
    auto findDevice = [&](const char* bundle) {
        for (UInt32 i = 0; i < plugin->GetDeviceCount(); ++i) {
            auto item = plugin->GetDeviceByIndex(i);
            if (item->GetDeviceUID() == std::string(DevicePrefix) + bundle) return item;
        }
        return std::shared_ptr<aspl::Device>{};
    };
    auto monoDevice = findDevice("test.a");
    auto stereoDevice = findDevice("test.b");
    assert(monoDevice && stereoDevice);
    assert(monoDevice->GetDeviceUID() == std::string(DevicePrefix) + "test.a");
    assert(monoDevice->GetID() != device->GetID());
    assert(monoDevice->GetNominalSampleRate() == 44100);
    assert(monoDevice->GetStreamByIndex(aspl::Direction::Input, 0)->GetChannelCount() == 1);
    assert(stereoDevice->GetNominalSampleRate() == 48000);
    assert(stereoDevice->GetStreamByIndex(aspl::Direction::Input, 0)->GetChannelCount() == 2);
    assert(configure("<plist><array><dict><key>bundle</key><string>test.a</string><key>name</key><string>A</string><key>sampleRate</key><integer>44100</integer><key>channels</key><integer>1</integer></dict><dict><key>bundle</key><string>test.b</string><key>name</key><string>B</string><key>sampleRate</key><integer>48000</integer><key>channels</key><integer>2</integer></dict></array></plist>") == noErr);
    assert(findDevice("test.a")->GetID() == monoDevice->GetID());
    assert(configure("<plist><dict/></plist>") != noErr);
    assert(plugin->GetDeviceCount() == 2);
    assert(configure("<plist><array><dict><key>bundle</key><string>test.a</string><key>name</key><string>A</string></dict></array></plist>") == noErr);
    assert(plugin->GetDeviceCount() == 1 && plugin->GetDeviceByIndex(0)->GetDeviceUID() == device->GetDeviceUID());

    Microphone mono(44100, 1);
    mono.SetMute(false);
    std::array<Float32, 1024> monoSamples;
    monoSamples.fill(0.3f);
    auto monoFeed = CFDataCreate(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(monoSamples.data()), sizeof(monoSamples));
    for (int i = 0; i < 3; ++i) mono.Push(monoFeed);
    CFRelease(monoFeed);
    std::array<Float32, 441> monoOutput{};
    mono.OnReadClientInput(nullptr, nullptr, 0, 0, monoOutput.data(), sizeof(monoOutput));
    for (auto sample : monoOutput) assert(sample == 0.3f);
    auto trace = mono.DrainTrace();
    assert(CFDataGetLength(trace) == sizeof(TraceBatchHeader) + sizeof(TraceBlockHeader) + sizeof(monoOutput));
    TraceBatchHeader traceBatch;
    TraceBlockHeader traceBlock;
    std::memcpy(&traceBatch, CFDataGetBytePtr(trace), sizeof(traceBatch));
    std::memcpy(&traceBlock, CFDataGetBytePtr(trace) + sizeof(traceBatch), sizeof(traceBlock));
    assert(traceBatch.blockCount == 1 && traceBatch.lostBlocks == 0);
    assert(traceBlock.sampleRate == 44100 && traceBlock.channels == 1 && traceBlock.frames == 441);
    assert(traceBlock.sampleTime == 0 && traceBlock.muted == 0);
    Float32 tracedSample;
    std::memcpy(&tracedSample, CFDataGetBytePtr(trace) + sizeof(traceBatch) + sizeof(traceBlock), sizeof(tracedSample));
    assert(tracedSample == 0.3f);
    CFRelease(trace);
    trace = mono.DrainTrace();
    std::memcpy(&traceBatch, CFDataGetBytePtr(trace), sizeof(traceBatch));
    assert(traceBatch.blockCount == 0);
    CFRelease(trace);

    Microphone mic;
    assert(mic.IsMuted());
    mic.SetMute(false);
    std::array<Float32, 480 * Channels> a{}, b{};
    a.fill(1.0f);
    mic.OnReadClientInput(nullptr, nullptr, 0, 0, a.data(), sizeof(a));
    assert(a[0] == 0.0f && a.back() == 0.0f);
    std::array<Float32, 1024 * Channels> supplied;
    supplied.fill(0.25f);
    CFDataRef feed = CFDataCreate(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(supplied.data()), sizeof(supplied));
    AudioObjectPropertyAddress pushAddress{AudioPush, kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain};
    assert(device->HasProperty(device->GetID(), getpid(), &pushAddress));
    assert(device->SetPropertyData(device->GetID(), getpid(), &pushAddress,
                                   0, nullptr, sizeof(feed), &feed) == noErr);
    mic.Push(feed);
    mic.Push(feed);
    mic.Push(feed);
    CFRelease(feed);

    aspl::ClientInfo firstInfo, secondInfo;
    firstInfo.ClientID = 1;
    firstInfo.ProcessID = 101;
    secondInfo.ClientID = 2;
    secondInfo.ProcessID = 202;
    auto first = std::make_shared<aspl::Client>(firstInfo);
    auto second = std::make_shared<aspl::Client>(secondInfo);
    auto context = std::make_shared<aspl::Context>();
    auto testDevice = std::make_shared<aspl::Device>(context);
    auto stream = std::make_shared<aspl::Stream>(context, testDevice);
    // 最大供音包之间有多个读取周期；有效供源不应周期性断音。
    Microphone burst;
    burst.SetMute(false);
    std::array<Float32, 2048 * Channels> packet;
    packet.fill(0.75f);
    feed = CFDataCreate(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(packet.data()), sizeof(packet));
    burst.Push(feed);
    burst.Push(feed);
    unsigned nextPush = 2048;
    for (unsigned timestamp = 0; timestamp < 16384; timestamp += 480) {
        if (timestamp >= nextPush) {
            burst.Push(feed);
            nextPush += 2048;
        }
        burst.OnReadClientInput(first, stream, 0, timestamp, a.data(), sizeof(a));
        for (auto sample : a) assert(sample == 0.75f);
    }
    CFRelease(feed);

    // An underrun must resume as soon as one new block exists beyond the last delivered frame.
    Microphone resumed;
    resumed.SetMute(false);
    supplied.fill(0.4f);
    feed = CFDataCreate(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(supplied.data()), sizeof(supplied));
    for (int i = 0; i < 4; ++i) resumed.Push(feed);
    for (unsigned t = 0; t <= 3072; t += 1024)
        resumed.OnReadClientInput(first, stream, 0, t, supplied.data(), sizeof(supplied));
    assert(supplied[0] == 0.0f);
    resumed.Push(feed);
    resumed.OnReadClientInput(first, stream, 0, 4096, supplied.data(), sizeof(supplied));
    assert(supplied[0] == 0.4f);
    CFRelease(feed);

    // Three missed 1024-frame pushes exhaust the 2048-frame safety margin.
    // Once the producer resumes at the same rate, reads must recover instead of staying silent.
    Microphone interrupted;
    interrupted.SetMute(false);
    supplied.fill(0.6f);
    feed = CFDataCreate(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(supplied.data()), sizeof(supplied));
    for (int i = 0; i < 4; ++i) interrupted.Push(feed);
    for (unsigned t = 0; t <= 2048; t += 1024) {
        interrupted.OnReadClientInput(first, stream, 0, t, supplied.data(), sizeof(supplied));
        assert(supplied[0] == 0.6f);
    }
    interrupted.OnReadClientInput(first, stream, 0, 3072, supplied.data(), sizeof(supplied));
    assert(supplied[0] == 0.0f);
    bool recovered = false;
    for (unsigned t = 4096; t <= 8192; t += 1024) {
        std::array<Float32, 1024 * Channels> next;
        next.fill(0.6f);
        auto nextFeed = CFDataCreate(kCFAllocatorDefault,
            reinterpret_cast<const UInt8*>(next.data()), sizeof(next));
        interrupted.Push(nextFeed);
        CFRelease(nextFeed);
        interrupted.OnReadClientInput(first, stream, 0, t, supplied.data(), sizeof(supplied));
        recovered |= supplied[0] == 0.6f;
    }
    assert(recovered);
    assert(interrupted.GetCounters().aheadFrames >= 1024);
    CFRelease(feed);

    mic.OnReadClientInput(first, stream, 0, 1000, a.data(), sizeof(a));
    mic.OnReadClientInput(second, stream, 0, 1000, b.data(), sizeof(b));
    assert(a[0] == 0.25f && b[0] == 0.25f);

    // 静音作用于整个专用设备；另一设备的同时间线仍独立供音。
    mic.SetMute(true);
    mic.OnReadClientInput(first, stream, 0, 1000, a.data(), sizeof(a));
    burst.OnReadClientInput(second, stream, 0, 16000, b.data(), sizeof(b));
    assert(a[0] == 0.0f && a.back() == 0.0f);
    assert(b[0] == 0.75f && b.back() == 0.75f);
    mic.SetMute(false);
    mic.OnReadClientInput(first, stream, 0, 1000, a.data(), sizeof(a));
    assert(a[0] == 0.25f && a.back() == 0.25f);

    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    mic.OnReadClientInput(second, stream, 0, 1480, b.data(), sizeof(b));
    assert(b[0] == 0.0f && b.back() == 0.0f);
    supplied.fill(0.5f);
    feed = CFDataCreate(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(supplied.data()), sizeof(supplied));
    mic.Push(feed);
    mic.OnReadClientInput(second, stream, 0, 10000, b.data(), sizeof(b));
    assert(b[0] == 0.0f && b.back() == 0.0f);
    mic.Push(feed);
    mic.Push(feed);
    CFRelease(feed);
    mic.OnReadClientInput(second, stream, 0, 10480, b.data(), sizeof(b));
    assert(b[0] == 0.5f && b.back() == 0.5f);
}
