/* The guest's sound on the host (Mac or iOS): the default output device through an AudioUnit
   whose render callback pulls PCM straight from the virtio-snd ring. The unit
   is set to the stream's own format, and CoreAudio converts to the device. */
#include "audio_mac.h"

#include <AudioToolbox/AudioToolbox.h>
#include <TargetConditionals.h>

/* The Mac's default output device, or the iOS app's own output (the app sets its audio session to playback). */
#if TARGET_OS_IPHONE
#define HV_OUTPUT_UNIT kAudioUnitSubType_RemoteIO
#else
#define HV_OUTPUT_UNIT kAudioUnitSubType_DefaultOutput
#endif
#include <stdio.h>

static AudioComponentInstance unit;
static int unit_running;
static unsigned cur_channels, cur_format, cur_rate;
static unsigned reports;

/* What went wrong, by its OSStatus (often four characters), for the first few failures. */
static void report(const char *what, OSStatus st) {
    if (reports >= 12) return;
    reports++;
    uint32_t u = (uint32_t)st;
    char cc[5] = {(char)(u >> 24), (char)(u >> 16), (char)(u >> 8), (char)u, 0};
    int printable = 1;
    for (int i = 0; i < 4; i++) printable &= cc[i] >= 32 && cc[i] < 127;
    if (printable) fprintf(stderr, "hengevm: sound: %s failed: '%s' (%d)\n", what, cc, (int)st);
    else fprintf(stderr, "hengevm: sound: %s failed: %d\n", what, (int)st);
}

static OSStatus render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                       UInt32 frames, AudioBufferList *io) {
    (void)flags, (void)ts, (void)bus, (void)frames;
    HvVirtioSnd *d = ref;
    for (UInt32 i = 0; i < io->mNumberBuffers; i++)
        hv_virtio_snd_pull(d, io->mBuffers[i].mData, io->mBuffers[i].mDataByteSize);
    return noErr;
}

static int start(void *opaque, unsigned channels, unsigned format, unsigned rate_hz) {
    HvVirtioSnd *d = opaque;
    if (unit && (channels != cur_channels || format != cur_format || rate_hz != cur_rate)) {
        AudioOutputUnitStop(unit);
        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
        unit = NULL;
        unit_running = 0;
    }
    if (!unit) {
        AudioComponentDescription desc = {kAudioUnitType_Output, HV_OUTPUT_UNIT,
                                          kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent comp = AudioComponentFindNext(NULL, &desc);
        OSStatus made = comp ? AudioComponentInstanceNew(comp, &unit) : -1;
        if (made != noErr) {
            unit = NULL;
            report("no output unit", made);
            return -1;
        }
        unsigned bytes = format == HV_VSND_FMT_S16 ? 2 : 4;
        AudioStreamBasicDescription f = {0};
        f.mSampleRate = rate_hz;
        f.mFormatID = kAudioFormatLinearPCM;
        f.mFormatFlags = (format == HV_VSND_FMT_FLOAT ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) |
                         kAudioFormatFlagIsPacked;
        f.mBytesPerPacket = f.mBytesPerFrame = bytes * channels;
        f.mFramesPerPacket = 1;
        f.mChannelsPerFrame = channels;
        f.mBitsPerChannel = bytes * 8;
        AURenderCallbackStruct cb = {render, d};
        OSStatus st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f);
        if (st == noErr) st = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
        if (st == noErr) st = AudioUnitInitialize(unit);
        if (st != noErr) {
            fprintf(stderr, "hengevm: sound: the output device refused %u ch, format %u, %u Hz\n", channels, format, rate_hz);
            report("initialize", st);
            AudioComponentInstanceDispose(unit);
            unit = NULL;
            return -1;
        }
        cur_channels = channels, cur_format = format, cur_rate = rate_hz;
    }
    if (!unit_running) {
        OSStatus st = AudioOutputUnitStart(unit);
        if (st == noErr) unit_running = 1;
        else report("start", st); /* iOS: '!pla' during a call, or with the app's audio session inactive */
    }
    return unit_running ? 0 : -1;
}

static void stop(void *opaque) {
    (void)opaque;
    if (unit && unit_running) AudioOutputUnitStop(unit); /* waits for the render callback to finish */
    unit_running = 0;
}

/* Throw the unit away: the next start makes a new one for whatever output is current. */
static void reset_unit(void *opaque) {
    (void)opaque;
    hv_audio_detach();
}

void hv_audio_attach(HvVirtioSnd *d) {
    d->backend = (HvVirtioSndBackend){start, stop, reset_unit, d};
}

void hv_audio_detach(void) {
    if (unit) {
        AudioOutputUnitStop(unit);
        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
        unit = NULL;
    }
    unit_running = 0;
    cur_channels = cur_format = cur_rate = 0;
}
