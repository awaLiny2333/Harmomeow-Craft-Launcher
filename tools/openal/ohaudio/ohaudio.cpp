/* OHAudio backend for OpenAL Soft, for OpenHarmony (OHOS).
 *
 * OHAudio is the OHOS-recommended native audio API (OpenSL ES is deprecated).
 * Playback renders directly in the pull callback (model used by oboe/coreaudio);
 * capture pushes into a ring buffer consumed by the app thread.
 */

#include "config.h"

#include "ohaudio.h"

#include <algorithm>
#include <cstdint>
#include <cstring>

#include "alnumeric.h"
#include "core/device.h"
#include "core/logging.h"
#include "ringbuffer.h"

#include <ohaudio/native_audiostream_base.h>
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>
#include <ohaudio/native_audiocapturer.h>

/* hilog NDK, declared manually: hilog/log.h defines a C `LogLevel` that would
 * conflict with OpenAL's `enum class LogLevel`. Values: LOG_APP=0, LOG_INFO=4. */
extern "C" int OH_LOG_Print(int type, int level, unsigned int domain, const char *tag,
    const char *fmt, ...);
#define MEOW_OHLOG(fmt, ...) OH_LOG_Print(0, 4, 0, "MeowOHAudio", fmt, ##__VA_ARGS__)


namespace {

constexpr char device_name[] = "OHAudio";


OH_AudioStream_SampleFormat ToOHAudioFormat(DevFmtType type) noexcept
{
    switch(type)
    {
    case DevFmtUByte: return AUDIOSTREAM_SAMPLE_U8;
    case DevFmtShort: return AUDIOSTREAM_SAMPLE_S16LE;
    case DevFmtInt:   return AUDIOSTREAM_SAMPLE_S32LE;
    case DevFmtFloat: return AUDIOSTREAM_SAMPLE_F32LE;
    case DevFmtByte:
    case DevFmtUShort:
    case DevFmtUInt:
        break;
    }
    return AUDIOSTREAM_SAMPLE_S16LE;
}

DevFmtType FromOHAudioFormat(OH_AudioStream_SampleFormat fmt) noexcept
{
    switch(fmt)
    {
    case AUDIOSTREAM_SAMPLE_U8:    return DevFmtUByte;
    case AUDIOSTREAM_SAMPLE_S16LE: return DevFmtShort;
    case AUDIOSTREAM_SAMPLE_S24LE:
    case AUDIOSTREAM_SAMPLE_S32LE: return DevFmtInt;
    case AUDIOSTREAM_SAMPLE_F32LE: return DevFmtFloat;
    default: break;
    }
    return DevFmtShort;
}

OH_AudioChannelLayout ToOHAudioLayout(DevFmtChannels chans) noexcept
{
    switch(chans)
    {
    case DevFmtMono:   return CH_LAYOUT_MONO;
    case DevFmtStereo: return CH_LAYOUT_STEREO;
    default: break;
    }
    return CH_LAYOUT_STEREO;
}


struct OHAudioPlayback final : public BackendBase {
    OHAudioPlayback(DeviceBase *device) noexcept : BackendBase{device} { }
    ~OHAudioPlayback() override;

    OH_AudioRenderer *mRenderer{nullptr};

    static OH_AudioData_Callback_Result writeDataC(OH_AudioRenderer *renderer, void *userData,
        void *audioData, int32_t audioDataSize) noexcept;
    static void errorC(OH_AudioRenderer *renderer, void *userData,
        OH_AudioStream_Result error) noexcept;

    void open(std::string_view name) override;
    bool reset() override;
    void start() override;
    void stop() override;
};


OHAudioPlayback::~OHAudioPlayback()
{
    if(mRenderer)
    {
        OH_AudioRenderer_Stop(mRenderer);
        OH_AudioRenderer_Release(mRenderer);
    }
    mRenderer = nullptr;
}

OH_AudioData_Callback_Result OHAudioPlayback::writeDataC(OH_AudioRenderer*, void *userData,
    void *audioData, int32_t audioDataSize) noexcept
{
    auto *self = static_cast<OHAudioPlayback*>(userData);
    const uint frameSize{self->mDevice->frameSizeFromFmt()};
    if(frameSize == 0 || !self->mDevice->Connected.load(std::memory_order_acquire))
    {
        std::memset(audioData, 0, static_cast<size_t>(audioDataSize));
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }

    const uint numFrames{static_cast<uint>(audioDataSize) / frameSize};
    self->mDevice->renderSamples(audioData, numFrames, self->mDevice->channelsFromFmt());
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
}

void OHAudioPlayback::errorC(OH_AudioRenderer*, void *userData, OH_AudioStream_Result error) noexcept
{
    auto *self = static_cast<OHAudioPlayback*>(userData);
    self->mDevice->handleDisconnect("OHAudio renderer error: 0x{:x}", int(error));
}


void OHAudioPlayback::open(std::string_view name)
{
    if(name.empty())
        name = device_name;
    else if(name != device_name)
        throw al::backend_exception{al::backend_error::NoDevice, "Device name \"{}\" not found",
            name};

    mDeviceName.assign(name);
}

bool OHAudioPlayback::reset()
{
    if(mRenderer)
    {
        OH_AudioRenderer_Stop(mRenderer);
        OH_AudioRenderer_Release(mRenderer);
        mRenderer = nullptr;
    }

    OH_AudioStreamBuilder *builder{nullptr};
    OH_AudioStream_Result result{OH_AudioStreamBuilder_Create(&builder,
        AUDIOSTREAM_TYPE_RENDERER)};
    if(result != AUDIOSTREAM_SUCCESS)
        throw al::backend_exception{al::backend_error::DeviceError,
            "Failed to create OHAudio renderer builder: 0x{:x}", int(result)};

    OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_GAME);
    OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
    OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST);
    OH_AudioStreamBuilder_SetRendererInterruptMode(builder, AUDIOSTREAM_INTERRUPT_MODE_SHARE);

    if(mDevice->Flags.test(FrequencyRequest))
        OH_AudioStreamBuilder_SetSamplingRate(builder, static_cast<int32_t>(mDevice->mSampleRate));
    if(mDevice->Flags.test(ChannelsRequest))
    {
        if(mDevice->FmtChans == DevFmtMono)
        {
            OH_AudioStreamBuilder_SetChannelCount(builder, 1);
            OH_AudioStreamBuilder_SetChannelLayout(builder, CH_LAYOUT_MONO);
        }
        else if(mDevice->FmtChans == DevFmtStereo)
        {
            OH_AudioStreamBuilder_SetChannelCount(builder, 2);
            OH_AudioStreamBuilder_SetChannelLayout(builder, CH_LAYOUT_STEREO);
        }
    }
    if(mDevice->Flags.test(SampleTypeRequest))
        OH_AudioStreamBuilder_SetSampleFormat(builder, ToOHAudioFormat(mDevice->FmtType));

    /* Request a 10ms callback period (FAST accepts 5/10/15/20ms); ignored if it
     * does not fit the latency mode. */
    if(mDevice->mSampleRate > 0)
        OH_AudioStreamBuilder_SetFrameSizeInCallback(builder,
            static_cast<int32_t>(mDevice->mSampleRate / 100));

    OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder, &OHAudioPlayback::writeDataC,
        this);
    OH_AudioStreamBuilder_SetRendererErrorCallback(builder, &OHAudioPlayback::errorC, this);

    result = OH_AudioStreamBuilder_GenerateRenderer(builder, &mRenderer);
    OH_AudioStreamBuilder_Destroy(builder);
    builder = nullptr;
    if(result != AUDIOSTREAM_SUCCESS)
        throw al::backend_exception{al::backend_error::DeviceError,
            "Failed to generate OHAudio renderer: 0x{:x}", int(result)};

    int32_t rate{0}, chans{0}, frameSize{0};
    OH_AudioStream_SampleFormat format{AUDIOSTREAM_SAMPLE_S16LE};
    OH_AudioRenderer_GetSamplingRate(mRenderer, &rate);
    OH_AudioRenderer_GetChannelCount(mRenderer, &chans);
    OH_AudioRenderer_GetSampleFormat(mRenderer, &format);
    OH_AudioRenderer_GetFrameSizeInCallback(mRenderer, &frameSize);

    if(rate > 0)
        mDevice->mSampleRate = static_cast<uint>(rate);
    if(chans >= 2)
        mDevice->FmtChans = DevFmtStereo;
    else if(chans == 1)
        mDevice->FmtChans = DevFmtMono;
    else
        throw al::backend_exception{al::backend_error::DeviceError,
            "Got unhandled channel count: {}", chans};
    mDevice->FmtType = FromOHAudioFormat(format);
    setDefaultWFXChannelOrder();

    mDevice->mUpdateSize = std::max(mDevice->mSampleRate / 100,
        static_cast<uint>(frameSize > 0 ? frameSize : 0));
    mDevice->mBufferSize = std::max(mDevice->mUpdateSize * 2, mDevice->mUpdateSize);

    /* One-time bring-up diagnostic; ERR is the only level shown by default. */
    static bool probed = false;
    if(!probed)
    {
        probed = true;
        OH_AudioStream_FastStatus fast{AUDIOSTREAM_FASTSTATUS_NORMAL};
        OH_AudioRenderer_GetFastStatus(mRenderer, &fast);
        int32_t latencyMs{-1};
        OH_AudioRenderer_GetLatency(mRenderer, AUDIOSTREAM_LATENCY_TYPE_ALL, &latencyMs);
        MEOW_OHLOG(
            "probe: %{public}u hz %{public}d ch fmt=0x%{public}x cbFrames=%{public}d update=%{public}u buffer=%{public}u fast=%{public}d latency=%{public}d ms",
            mDevice->mSampleRate, chans, int(format), frameSize,
            mDevice->mUpdateSize, mDevice->mBufferSize, int(fast), latencyMs);
    }

    return true;
}

void OHAudioPlayback::start()
{
    const OH_AudioStream_Result result{OH_AudioRenderer_Start(mRenderer)};
    if(result != AUDIOSTREAM_SUCCESS)
        throw al::backend_exception{al::backend_error::DeviceError,
            "Failed to start OHAudio renderer: 0x{:x}", int(result)};
}

void OHAudioPlayback::stop()
{
    OH_AudioRenderer_Stop(mRenderer);
    OH_AudioRenderer_Flush(mRenderer);
}


struct OHAudioCapture final : public BackendBase {
    OHAudioCapture(DeviceBase *device) noexcept : BackendBase{device} { }
    ~OHAudioCapture() override;

    OH_AudioCapturer *mCapturer{nullptr};
    RingBufferPtr mRing{nullptr};
    uint mFrameSize{0};

    static void readDataC(OH_AudioCapturer *capturer, void *userData, void *audioData,
        int32_t audioDataSize) noexcept;
    static void errorC(OH_AudioCapturer *capturer, void *userData,
        OH_AudioStream_Result error) noexcept;

    void open(std::string_view name) override;
    void start() override;
    void stop() override;
    void captureSamples(std::byte *buffer, uint samples) override;
    uint availableSamples() override;
};


OHAudioCapture::~OHAudioCapture()
{
    if(mCapturer)
    {
        OH_AudioCapturer_Stop(mCapturer);
        OH_AudioCapturer_Release(mCapturer);
    }
    mCapturer = nullptr;
}

void OHAudioCapture::readDataC(OH_AudioCapturer*, void *userData, void *audioData,
    int32_t audioDataSize) noexcept
{
    auto *self = static_cast<OHAudioCapture*>(userData);
    if(self->mFrameSize == 0)
        return;
    self->mRing->write(audioData, static_cast<size_t>(audioDataSize) / self->mFrameSize);
}

void OHAudioCapture::errorC(OH_AudioCapturer*, void *userData, OH_AudioStream_Result error) noexcept
{
    auto *self = static_cast<OHAudioCapture*>(userData);
    self->mDevice->handleDisconnect("OHAudio capturer error: 0x{:x}", int(error));
}


void OHAudioCapture::open(std::string_view name)
{
    if(name.empty())
        name = device_name;
    else if(name != device_name)
        throw al::backend_exception{al::backend_error::NoDevice, "Device name \"{}\" not found",
            name};

    if(mDevice->FmtChans != DevFmtMono && mDevice->FmtChans != DevFmtStereo)
        throw al::backend_exception{al::backend_error::DeviceError,
            "{} channel capture not supported", int(mDevice->FmtChans)};

    OH_AudioStreamBuilder *builder{nullptr};
    OH_AudioStream_Result result{OH_AudioStreamBuilder_Create(&builder,
        AUDIOSTREAM_TYPE_CAPTURER)};
    if(result != AUDIOSTREAM_SUCCESS)
        throw al::backend_exception{al::backend_error::DeviceError,
            "Failed to create OHAudio capturer builder: 0x{:x}", int(result)};

    OH_AudioStreamBuilder_SetCapturerInfo(builder, AUDIOSTREAM_SOURCE_TYPE_MIC);
    OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW);
    OH_AudioStreamBuilder_SetSamplingRate(builder, static_cast<int32_t>(mDevice->mSampleRate));
    OH_AudioStreamBuilder_SetChannelCount(builder, (mDevice->FmtChans == DevFmtMono) ? 1 : 2);
    OH_AudioStreamBuilder_SetChannelLayout(builder, ToOHAudioLayout(mDevice->FmtChans));
    OH_AudioStreamBuilder_SetSampleFormat(builder, ToOHAudioFormat(mDevice->FmtType));
    OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST);

    OH_AudioStreamBuilder_SetCapturerReadDataCallback(builder, &OHAudioCapture::readDataC, this);
    OH_AudioStreamBuilder_SetCapturerErrorCallback(builder, &OHAudioCapture::errorC, this);

    result = OH_AudioStreamBuilder_GenerateCapturer(builder, &mCapturer);
    OH_AudioStreamBuilder_Destroy(builder);
    builder = nullptr;
    if(result != AUDIOSTREAM_SUCCESS)
        throw al::backend_exception{al::backend_error::DeviceError,
            "Failed to generate OHAudio capturer: 0x{:x}", int(result)};

    int32_t rate{0}, chans{0};
    OH_AudioStream_SampleFormat format{AUDIOSTREAM_SAMPLE_S16LE};
    OH_AudioCapturer_GetSamplingRate(mCapturer, &rate);
    OH_AudioCapturer_GetChannelCount(mCapturer, &chans);
    OH_AudioCapturer_GetSampleFormat(mCapturer, &format);

    if(rate > 0)
        mDevice->mSampleRate = static_cast<uint>(rate);
    if(chans >= 2)
        mDevice->FmtChans = DevFmtStereo;
    else if(chans == 1)
        mDevice->FmtChans = DevFmtMono;
    else
        throw al::backend_exception{al::backend_error::DeviceError,
            "Got unhandled channel count: {}", chans};
    mDevice->FmtType = FromOHAudioFormat(format);
    setDefaultWFXChannelOrder();

    mDevice->mUpdateSize = std::max(mDevice->mSampleRate / 100, 1u);
    mDevice->mBufferSize = std::max(mDevice->mUpdateSize * 2, mDevice->mUpdateSize);
    mFrameSize = mDevice->frameSizeFromFmt();
    mRing = RingBuffer::Create(std::max(mDevice->mBufferSize, mDevice->mSampleRate/10), mFrameSize, 0);

    mDeviceName.assign(name);
}

void OHAudioCapture::start()
{
    const OH_AudioStream_Result result{OH_AudioCapturer_Start(mCapturer)};
    if(result != AUDIOSTREAM_SUCCESS)
        throw al::backend_exception{al::backend_error::DeviceError,
            "Failed to start OHAudio capturer: 0x{:x}", int(result)};
}

void OHAudioCapture::stop()
{
    OH_AudioCapturer_Stop(mCapturer);
    OH_AudioCapturer_Flush(mCapturer);
}

uint OHAudioCapture::availableSamples()
{ return static_cast<uint>(mRing->readSpace()); }

void OHAudioCapture::captureSamples(std::byte *buffer, uint samples)
{ mRing->read(buffer, samples); }

} // namespace

bool OHAudioBackendFactory::init() { return true; }

bool OHAudioBackendFactory::querySupport(BackendType type)
{ return type == BackendType::Playback || type == BackendType::Capture; }

std::vector<std::string> OHAudioBackendFactory::enumerate(BackendType type)
{
    switch(type)
    {
    case BackendType::Playback:
    case BackendType::Capture:
        return std::vector<std::string>{std::string{device_name}};
    }
    return std::vector<std::string>{};
}

BackendPtr OHAudioBackendFactory::createBackend(DeviceBase *device, BackendType type)
{
    if(type == BackendType::Playback)
        return BackendPtr{new OHAudioPlayback{device}};
    if(type == BackendType::Capture)
        return BackendPtr{new OHAudioCapture{device}};
    return BackendPtr{};
}

BackendFactory &OHAudioBackendFactory::getFactory()
{
    static OHAudioBackendFactory factory{};
    return factory;
}
