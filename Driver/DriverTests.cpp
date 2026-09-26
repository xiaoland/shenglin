#include "Driver.cpp"

#include <cassert>
#include <thread>

int main() {
    auto driver = CreateDriver();
    auto device = driver->GetPlugin()->GetDeviceByIndex(0);
    assert(device && device->GetDeviceUID() == "local.nearbyaudio.virtual-microphone");
    assert(device->GetStreamCount(aspl::Direction::Input) == 1);
    assert(device->GetStreamCount(aspl::Direction::Output) == 0);

    Microphone mic;
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
    mic.OnReadClientInput(first, stream, 0, 1000, a.data(), sizeof(a));
    mic.OnReadClientInput(second, stream, 0, 1000, b.data(), sizeof(b));
    assert(a[0] == 0.25f && b[0] == 0.25f);

    MuteCommand mute{101, 1};
    CFDataRef muteData = CFDataCreate(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(&mute), sizeof(mute));
    AudioObjectPropertyAddress muteAddress{ClientMute, kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain};
    assert(device->HasProperty(device->GetID(), getpid(), &muteAddress));
    assert(device->SetPropertyData(device->GetID(), getpid(), &muteAddress,
                                   0, nullptr, sizeof(muteData), &muteData) == noErr);
    mic.SetMute(muteData);
    CFRelease(muteData);
    mic.OnProcessClientInput(first, stream, 0, 1000, a.data(), 480, Channels);
    mic.OnProcessClientInput(second, stream, 0, 1000, b.data(), 480, Channels);
    assert(a[0] == 0.0f && a.back() == 0.0f);
    assert(b[0] == 0.25f && b.back() == 0.25f);

    MuteCommand unmute{101, 0};
    CFDataRef unmuteData = CFDataCreate(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(&unmute), sizeof(unmute));
    mic.SetMute(unmuteData);
    CFRelease(unmuteData);
    mic.OnReadClientInput(first, stream, 0, 1000, a.data(), sizeof(a));
    mic.OnProcessClientInput(first, stream, 0, 1000, a.data(), 480, Channels);
    assert(a[0] == 0.25f && a.back() == 0.25f);

    mic.OnReadClientInput(second, stream, 0, 1960, b.data(), sizeof(b));
    assert(b[0] == 0.0f && b.back() == 0.0f);

    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    mic.OnReadClientInput(second, stream, 0, 1480, b.data(), sizeof(b));
    assert(b[0] == 0.0f && b.back() == 0.0f);
    feed = CFDataCreate(kCFAllocatorDefault,
        reinterpret_cast<const UInt8*>(supplied.data()), sizeof(supplied));
    mic.Push(feed);
    CFRelease(feed);
    mic.OnReadClientInput(second, stream, 0, 10000, b.data(), sizeof(b));
    assert(b[0] == 0.25f && b.back() == 0.25f);
}
