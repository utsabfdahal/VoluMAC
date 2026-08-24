#include "SoftwareVolumeEngine.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>
#include <new>
#include <vector>

namespace {

constexpr UInt32 channelCount = 2;
constexpr uint64_t ringCapacityFrames = 32768;
constexpr uint64_t primeFrames = 512;

constexpr AudioObjectPropertyAddress propertyAddress(
    AudioObjectPropertySelector selector,
    AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
    AudioObjectPropertyElement element = kAudioObjectPropertyElementMain) noexcept {
    return {selector, scope, element};
}

struct Engine {
    Engine(AudioObjectID input, AudioObjectID output)
        : inputDeviceID(input), outputDeviceID(output),
          ring(std::make_unique<Float32[]>(ringCapacityFrames * channelCount)) {
        std::memset(ring.get(), 0, sizeof(Float32) * ringCapacityFrames * channelCount);
    }

    AudioObjectID inputDeviceID = kAudioObjectUnknown;
    AudioObjectID outputDeviceID = kAudioObjectUnknown;
    AudioDeviceIOProcID inputIOProcID = nullptr;
    AudioDeviceIOProcID outputIOProcID = nullptr;
    std::unique_ptr<Float32[]> ring;
    std::atomic<uint64_t> writeFrame {0};
    std::atomic<uint64_t> readFrame {0};
    std::atomic<Float32> targetGain {0.25F};
    Float32 currentGain = 0.25F;
    bool primed = false;
    std::atomic<bool> running {false};
    std::atomic<uint64_t> callbacks {0};
    std::atomic<uint64_t> nonSilentFrames {0};
    std::atomic<Float32> inputPeak {0};
    std::atomic<Float32> outputPeak {0};
};

bool supportedFormat(const AudioStreamBasicDescription& format) noexcept {
    return format.mFormatID == kAudioFormatLinearPCM
        && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        && format.mBitsPerChannel == 32
        && format.mChannelsPerFrame > 0
        && format.mBytesPerFrame > 0;
}

OSStatus validateScopedStreams(
    AudioObjectID deviceID,
    AudioObjectPropertyScope scope,
    Float64 *sampleRate) {
    auto address = propertyAddress(kAudioDevicePropertyStreams, scope);
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nullptr, &size);
    if (status != noErr) return status;
    if (size < sizeof(AudioObjectID)) return kAudioHardwareBadDeviceError;

    std::vector<AudioObjectID> streams(size / sizeof(AudioObjectID));
    status = AudioObjectGetPropertyData(deviceID, &address, 0, nullptr, &size, streams.data());
    if (status != noErr) return status;

    bool foundChannels = false;
    for (const auto streamID : streams) {
        AudioStreamBasicDescription format {};
        size = sizeof(format);
        address = propertyAddress(kAudioStreamPropertyVirtualFormat);
        status = AudioObjectGetPropertyData(streamID, &address, 0, nullptr, &size, &format);
        if (status != noErr) return status;
        if (!supportedFormat(format)) return kAudioHardwareUnsupportedOperationError;
        if (format.mChannelsPerFrame >= channelCount) foundChannels = true;
        if (*sampleRate == 0) *sampleRate = format.mSampleRate;
        else if (std::abs(*sampleRate - format.mSampleRate) > 0.5) {
            return kAudioHardwareUnsupportedOperationError;
        }
    }
    return foundChannels ? noErr : kAudioHardwareUnsupportedOperationError;
}

void updatePeak(std::atomic<Float32>& destination, Float32 value) noexcept {
    Float32 observed = destination.load(std::memory_order_relaxed);
    while (observed < value
           && !destination.compare_exchange_weak(observed, value,
                                                  std::memory_order_relaxed,
                                                  std::memory_order_relaxed)) {}
}

UInt32 frameCount(const AudioBuffer& buffer) noexcept {
    if (buffer.mNumberChannels == 0) return 0;
    return buffer.mDataByteSize
        / (buffer.mNumberChannels * static_cast<UInt32>(sizeof(Float32)));
}

std::array<Float32, 2> readStereoFrame(
    const AudioBufferList* input,
    UInt32 frame) noexcept {
    if (input->mNumberBuffers == 1) {
        const auto& buffer = input->mBuffers[0];
        if (buffer.mData == nullptr || frame >= frameCount(buffer)) return {0, 0};
        const auto* source = static_cast<const Float32*>(buffer.mData)
            + frame * buffer.mNumberChannels;
        if (buffer.mNumberChannels == 1) return {source[0], source[0]};
        return {source[0], source[1]};
    }
    const auto& leftBuffer = input->mBuffers[0];
    const auto& rightBuffer = input->mBuffers[1];
    if (leftBuffer.mData == nullptr || rightBuffer.mData == nullptr
        || frame >= frameCount(leftBuffer) || frame >= frameCount(rightBuffer)) return {0, 0};
    const auto* left = static_cast<const Float32*>(leftBuffer.mData)
        + frame * leftBuffer.mNumberChannels;
    const auto* right = static_cast<const Float32*>(rightBuffer.mData)
        + frame * rightBuffer.mNumberChannels;
    return {left[0], right[0]};
}

void writeStereoFrame(
    AudioBufferList* output,
    UInt32 frame,
    Float32 left,
    Float32 right) noexcept {
    if (output->mNumberBuffers == 1) {
        auto& buffer = output->mBuffers[0];
        if (buffer.mData == nullptr || frame >= frameCount(buffer)) return;
        auto* destination = static_cast<Float32*>(buffer.mData)
            + frame * buffer.mNumberChannels;
        destination[0] = left;
        if (buffer.mNumberChannels > 1) destination[1] = right;
        return;
    }
    auto& leftBuffer = output->mBuffers[0];
    auto& rightBuffer = output->mBuffers[1];
    if (leftBuffer.mData == nullptr || rightBuffer.mData == nullptr
        || frame >= frameCount(leftBuffer) || frame >= frameCount(rightBuffer)) return;
    auto* leftDestination = static_cast<Float32*>(leftBuffer.mData)
        + frame * leftBuffer.mNumberChannels;
    auto* rightDestination = static_cast<Float32*>(rightBuffer.mData)
        + frame * rightBuffer.mNumberChannels;
    leftDestination[0] = left;
    rightDestination[0] = right;
}

OSStatus duplexIOProc(AudioObjectID,
                      const AudioTimeStamp*,
                      const AudioBufferList* input,
                      const AudioTimeStamp*,
                      AudioBufferList* output,
                      const AudioTimeStamp*,
                      void* clientData) noexcept {
    auto* engine = static_cast<Engine*>(clientData);
    if (engine == nullptr || input == nullptr || output == nullptr
        || input->mNumberBuffers == 0 || output->mNumberBuffers == 0) return noErr;

    engine->callbacks.fetch_add(1, std::memory_order_relaxed);
    for (UInt32 index = 0; index < output->mNumberBuffers; ++index) {
        auto& buffer = output->mBuffers[index];
        if (buffer.mData != nullptr) std::memset(buffer.mData, 0, buffer.mDataByteSize);
    }

    const UInt32 frames = std::min(
        frameCount(input->mBuffers[0]),
        frameCount(output->mBuffers[0]));
    if (frames == 0) return noErr;

    const Float32 startGain = engine->currentGain;
    const Float32 targetGain = std::clamp(
        engine->targetGain.load(std::memory_order_relaxed), 0.0F, 1.0F);
    const Float32 gainStep = (targetGain - startGain) / static_cast<Float32>(frames);
    Float32 inputPeak = 0;
    Float32 outputPeak = 0;

    for (UInt32 frame = 0; frame < frames; ++frame) {
        const auto samples = readStereoFrame(input, frame);
        const Float32 gain = startGain + gainStep * static_cast<Float32>(frame + 1);
        const Float32 left = samples[0] * gain;
        const Float32 right = samples[1] * gain;
        writeStereoFrame(output, frame, left, right);
        inputPeak = std::max({inputPeak, std::abs(samples[0]), std::abs(samples[1])});
        outputPeak = std::max({outputPeak, std::abs(left), std::abs(right)});
    }

    engine->currentGain = targetGain;
    if (inputPeak > 0.000001F) {
        engine->nonSilentFrames.fetch_add(frames, std::memory_order_relaxed);
    }
    updatePeak(engine->inputPeak, inputPeak);
    updatePeak(engine->outputPeak, outputPeak);
    return noErr;
}

OSStatus inputIOProc(AudioObjectID,
                     const AudioTimeStamp*,
                     const AudioBufferList* input,
                     const AudioTimeStamp*,
                     AudioBufferList*,
                     const AudioTimeStamp*,
                     void* clientData) noexcept {
    auto* engine = static_cast<Engine*>(clientData);
    if (engine == nullptr || input == nullptr || input->mNumberBuffers == 0) return noErr;

    engine->callbacks.fetch_add(1, std::memory_order_relaxed);
    UInt32 frames = frameCount(input->mBuffers[0]);
    if (frames == 0) return noErr;

    uint64_t write = engine->writeFrame.load(std::memory_order_relaxed);
    const uint64_t read = engine->readFrame.load(std::memory_order_acquire);
    const uint64_t used = write - read;
    const uint64_t free = used < ringCapacityFrames ? ringCapacityFrames - used : 0;
    frames = static_cast<UInt32>(std::min<uint64_t>(frames, free));
    if (frames == 0) return noErr;

    const Float32 startGain = engine->currentGain;
    const Float32 targetGain = std::clamp(
        engine->targetGain.load(std::memory_order_relaxed), 0.0F, 1.0F);
    const Float32 gainStep = (targetGain - startGain) / static_cast<Float32>(frames);
    Float32 inputPeak = 0;

    for (UInt32 frame = 0; frame < frames; ++frame) {
        const auto samples = readStereoFrame(input, frame);
        const Float32 gain = startGain + gainStep * static_cast<Float32>(frame + 1);
        const uint64_t ringFrame = (write + frame) % ringCapacityFrames;
        engine->ring[ringFrame * channelCount] = samples[0] * gain;
        engine->ring[ringFrame * channelCount + 1] = samples[1] * gain;
        inputPeak = std::max({inputPeak, std::abs(samples[0]), std::abs(samples[1])});
    }

    engine->currentGain = targetGain;
    engine->writeFrame.store(write + frames, std::memory_order_release);
    if (inputPeak > 0.000001F) {
        engine->nonSilentFrames.fetch_add(frames, std::memory_order_relaxed);
    }
    updatePeak(engine->inputPeak, inputPeak);
    return noErr;
}

OSStatus outputIOProc(AudioObjectID,
                      const AudioTimeStamp*,
                      const AudioBufferList*,
                      const AudioTimeStamp*,
                      AudioBufferList* output,
                      const AudioTimeStamp*,
                      void* clientData) noexcept {
    auto* engine = static_cast<Engine*>(clientData);
    if (engine == nullptr || output == nullptr || output->mNumberBuffers == 0) return noErr;

    for (UInt32 index = 0; index < output->mNumberBuffers; ++index) {
        auto& buffer = output->mBuffers[index];
        if (buffer.mData != nullptr) std::memset(buffer.mData, 0, buffer.mDataByteSize);
    }

    const UInt32 requestedFrames = frameCount(output->mBuffers[0]);
    if (requestedFrames == 0) return noErr;

    uint64_t read = engine->readFrame.load(std::memory_order_relaxed);
    const uint64_t write = engine->writeFrame.load(std::memory_order_acquire);
    uint64_t available = write - read;
    if (!engine->primed) {
        if (available < primeFrames) return noErr;
        engine->primed = true;
    }

    const UInt32 frames = static_cast<UInt32>(
        std::min<uint64_t>(requestedFrames, available));
    Float32 outputPeak = 0;
    for (UInt32 frame = 0; frame < frames; ++frame) {
        const uint64_t ringFrame = (read + frame) % ringCapacityFrames;
        const Float32 left = engine->ring[ringFrame * channelCount];
        const Float32 right = engine->ring[ringFrame * channelCount + 1];
        writeStereoFrame(output, frame, left, right);
        outputPeak = std::max({outputPeak, std::abs(left), std::abs(right)});
    }

    engine->readFrame.store(read + frames, std::memory_order_release);
    if (frames < requestedFrames) engine->primed = false;
    updatePeak(engine->outputPeak, outputPeak);
    return noErr;
}

} // namespace

OSStatus DAVolumeEngineCreate(
    AudioObjectID inputDeviceID,
    AudioObjectID outputDeviceID,
    DAVolumeEngineRef *outEngine) {
    if (outEngine == nullptr
        || inputDeviceID == kAudioObjectUnknown
        || outputDeviceID == kAudioObjectUnknown) return kAudioHardwareIllegalOperationError;
    *outEngine = nullptr;

    Float64 inputRate = 0;
    Float64 outputRate = 0;
    OSStatus status = validateScopedStreams(
        inputDeviceID, kAudioObjectPropertyScopeInput, &inputRate);
    if (status != noErr) return status;
    status = validateScopedStreams(
        outputDeviceID, kAudioObjectPropertyScopeOutput, &outputRate);
    if (status != noErr) return status;
    if (std::abs(inputRate - outputRate) > 0.5) return kAudioHardwareUnsupportedOperationError;

    auto* engine = new (std::nothrow) Engine(inputDeviceID, outputDeviceID);
    if (engine == nullptr || engine->ring == nullptr) {
        delete engine;
        return kAudioHardwareUnspecifiedError;
    }
    *outEngine = engine;
    return noErr;
}

OSStatus DAVolumeEngineStart(DAVolumeEngineRef reference) {
    auto* engine = static_cast<Engine*>(reference);
    if (engine == nullptr) return kAudioHardwareIllegalOperationError;
    if (engine->running.load(std::memory_order_acquire)) return noErr;

    if (engine->inputDeviceID == engine->outputDeviceID) {
        OSStatus status = AudioDeviceCreateIOProcID(
            engine->inputDeviceID, duplexIOProc, engine, &engine->inputIOProcID);
        if (status != noErr) return status;
        status = AudioDeviceStart(engine->inputDeviceID, engine->inputIOProcID);
        if (status != noErr) {
            AudioDeviceDestroyIOProcID(engine->inputDeviceID, engine->inputIOProcID);
            engine->inputIOProcID = nullptr;
            return status;
        }
        engine->running.store(true, std::memory_order_release);
        return noErr;
    }

    OSStatus status = AudioDeviceCreateIOProcID(
        engine->outputDeviceID, outputIOProc, engine, &engine->outputIOProcID);
    if (status != noErr) return status;
    status = AudioDeviceStart(engine->outputDeviceID, engine->outputIOProcID);
    if (status != noErr) {
        AudioDeviceDestroyIOProcID(engine->outputDeviceID, engine->outputIOProcID);
        engine->outputIOProcID = nullptr;
        return status;
    }

    status = AudioDeviceCreateIOProcID(
        engine->inputDeviceID, inputIOProc, engine, &engine->inputIOProcID);
    if (status == noErr) {
        status = AudioDeviceStart(engine->inputDeviceID, engine->inputIOProcID);
    }
    if (status != noErr) {
        if (engine->inputIOProcID != nullptr) {
            AudioDeviceDestroyIOProcID(engine->inputDeviceID, engine->inputIOProcID);
            engine->inputIOProcID = nullptr;
        }
        AudioDeviceStop(engine->outputDeviceID, engine->outputIOProcID);
        AudioDeviceDestroyIOProcID(engine->outputDeviceID, engine->outputIOProcID);
        engine->outputIOProcID = nullptr;
        return status;
    }

    engine->running.store(true, std::memory_order_release);
    return noErr;
}

void DAVolumeEngineStop(DAVolumeEngineRef reference) {
    auto* engine = static_cast<Engine*>(reference);
    if (engine == nullptr || !engine->running.exchange(false, std::memory_order_acq_rel)) return;

    AudioDeviceStop(engine->inputDeviceID, engine->inputIOProcID);
    AudioDeviceDestroyIOProcID(engine->inputDeviceID, engine->inputIOProcID);
    engine->inputIOProcID = nullptr;
    if (engine->inputDeviceID == engine->outputDeviceID) return;
    AudioDeviceStop(engine->outputDeviceID, engine->outputIOProcID);
    AudioDeviceDestroyIOProcID(engine->outputDeviceID, engine->outputIOProcID);
    engine->outputIOProcID = nullptr;
}

void DAVolumeEngineDestroy(DAVolumeEngineRef reference) {
    auto* engine = static_cast<Engine*>(reference);
    if (engine == nullptr) return;
    DAVolumeEngineStop(reference);
    delete engine;
}

void DAVolumeEngineSetGain(DAVolumeEngineRef reference, Float32 gain) {
    auto* engine = static_cast<Engine*>(reference);
    if (engine == nullptr) return;
    const Float32 clampedGain = std::clamp(gain, 0.0F, 1.0F);
    engine->targetGain.store(clampedGain, std::memory_order_relaxed);
    if (!engine->running.load(std::memory_order_acquire)) {
        engine->currentGain = clampedGain;
    }
}

bool DAVolumeEngineIsRunning(DAVolumeEngineRef reference) {
    auto* engine = static_cast<Engine*>(reference);
    return engine != nullptr && engine->running.load(std::memory_order_acquire);
}

uint64_t DAVolumeEngineCallbackCount(DAVolumeEngineRef reference) {
    auto* engine = static_cast<Engine*>(reference);
    return engine == nullptr ? 0 : engine->callbacks.load(std::memory_order_relaxed);
}

uint64_t DAVolumeEngineNonSilentFrameCount(DAVolumeEngineRef reference) {
    auto* engine = static_cast<Engine*>(reference);
    return engine == nullptr ? 0 : engine->nonSilentFrames.load(std::memory_order_relaxed);
}

Float32 DAVolumeEngineInputPeak(DAVolumeEngineRef reference) {
    auto* engine = static_cast<Engine*>(reference);
    return engine == nullptr ? 0 : engine->inputPeak.load(std::memory_order_relaxed);
}

Float32 DAVolumeEngineOutputPeak(DAVolumeEngineRef reference) {
    auto* engine = static_cast<Engine*>(reference);
    return engine == nullptr ? 0 : engine->outputPeak.load(std::memory_order_relaxed);
}
