// ETJSFXHost.cpp

#include "ETJSFXHost.h"
#include "ysfx.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

struct ETJSFX {
    ysfx_config_t *config = nullptr;
    ysfx_t *effect = nullptr;
    uint32_t maxFrames = 0;
    uint32_t currentFrames = 0;
    std::vector<uint32_t> sliders;
    std::string log;
};

static void copyError(char *destination, size_t capacity, const std::string &message)
{
    if (!destination || capacity == 0) return;
    std::snprintf(destination, capacity, "%s", message.c_str());
}

static void reportLog(intptr_t userdata, ysfx_log_level level, const char *message)
{
    auto *host = reinterpret_cast<ETJSFX *>(userdata);
    if (!host || !message || level < ysfx_log_warning) return;
    if (!host->log.empty()) host->log += '\n';
    host->log += message;
}

static int32_t processJSFX(void *context, float *planar, uint32_t channels,
                           uint32_t frames, double sampleRate, double sampleTime)
{
    auto *host = static_cast<ETJSFX *>(context);
    if (!host || !host->effect || !planar || channels == 0 ||
        channels > ysfx_max_channels || frames == 0 || frames > host->maxFrames)
        return -1;

    // samplesblock must describe this exact callback. ysfx_set_block_size only
    // updates the EEL variable; it performs no allocation or compilation.
    if (host->currentFrames != frames) {
        ysfx_set_block_size(host->effect, frames);
        host->currentFrames = frames;
    }

    ysfx_time_info_t time{};
    time.playback_state = ysfx_playback_playing;
    time.time_position = sampleTime / std::max(1.0, sampleRate);
    time.time_signature[0] = 4;
    time.time_signature[1] = 4;
    time.tempo = 120.0;
    ysfx_set_time_info(host->effect, &time);

    const float *inputs[ysfx_max_channels]{};
    float *outputs[ysfx_max_channels]{};
    for (uint32_t channel = 0; channel < channels; ++channel) {
        float *samples = planar + channel * frames;
        inputs[channel] = samples;
        outputs[channel] = samples;
    }
    ysfx_process_float(host->effect, inputs, outputs, channels, channels, frames);
    return 0;
}

static void resetJSFX(void *context)
{
    auto *host = static_cast<ETJSFX *>(context);
    if (host && host->effect) ysfx_init(host->effect);
}

static uint32_t latencyJSFX(void *context)
{
    auto *host = static_cast<ETJSFX *>(context);
    if (!host || !host->effect) return 0;
    return static_cast<uint32_t>(std::max(0.0, std::ceil(ysfx_get_pdc_delay(host->effect))));
}

static double tailJSFX(void *) { return 0.0; }

ETJSFX *ETJSFX_Create(const char *path, const char *importRoot,
                      double sampleRate, uint32_t maxFrames,
                      char *error, size_t errorCapacity)
{
    if (!path || !path[0] || maxFrames == 0) {
        copyError(error, errorCapacity, "Invalid JSFX path or block size.");
        return nullptr;
    }

    ETJSFX *host = new ETJSFX;
    host->maxFrames = maxFrames;
    host->currentFrames = maxFrames;
    host->config = ysfx_config_new();
    if (!host->config) {
        copyError(error, errorCapacity, "Could not create the JSFX runtime.");
        delete host;
        return nullptr;
    }
    ysfx_set_user_data(host->config, reinterpret_cast<intptr_t>(host));
    ysfx_set_log_reporter(host->config, reportLog);
    if (importRoot && importRoot[0]) ysfx_set_import_root(host->config, importRoot);
    ysfx_register_builtin_audio_formats(host->config);

    host->effect = ysfx_new(host->config);
    if (!host->effect || !ysfx_load_file(host->effect, path, 0)) {
        copyError(error, errorCapacity,
                  host->log.empty() ? "Could not load the JSFX source." : host->log);
        ETJSFX_Destroy(host);
        return nullptr;
    }
    // Serialization is intentionally deferred until file access/state streams
    // are exposed safely. @gfx remains compiled when the ysfx build enables it.
    if (!ysfx_compile(host->effect, ysfx_compile_no_serialize)) {
        copyError(error, errorCapacity,
                  host->log.empty() ? "Could not compile the JSFX source." : host->log);
        ETJSFX_Destroy(host);
        return nullptr;
    }

    ysfx_set_sample_rate(host->effect, sampleRate);
    ysfx_set_block_size(host->effect, maxFrames);
    ysfx_set_midi_capacity(host->effect, 4096, true);
    ysfx_init(host->effect);
    for (uint32_t index = 0; index < ysfx_max_sliders; ++index)
        if (ysfx_slider_exists(host->effect, index)) host->sliders.push_back(index);
    return host;
}

void ETJSFX_Destroy(ETJSFX *host)
{
    if (!host) return;
    if (host->effect) ysfx_free(host->effect);
    if (host->config) ysfx_config_free(host->config);
    delete host;
}

ETExternalProcessor ETJSFX_Processor(ETJSFX *host)
{
    ETExternalProcessor descriptor{};
    descriptor.context = host;
    descriptor.process = processJSFX;
    descriptor.reset = resetJSFX;
    descriptor.latency = latencyJSFX;
    descriptor.tailTime = tailJSFX;
    descriptor.maxFrames = host ? host->maxFrames : 0;
    descriptor.maxChannels = ysfx_max_channels;
    return descriptor;
}

void ETJSFX_Configure(ETJSFX *host, double sampleRate, uint32_t maxFrames)
{
    if (!host || !host->effect || maxFrames == 0) return;
    host->maxFrames = maxFrames;
    host->currentFrames = maxFrames;
    ysfx_set_sample_rate(host->effect, sampleRate);
    ysfx_set_block_size(host->effect, maxFrames);
    ysfx_init(host->effect);
}

const char *ETJSFX_Name(const ETJSFX *host)
{
    return host && host->effect ? ysfx_get_name(host->effect) : nullptr;
}

const char *ETJSFX_Author(const ETJSFX *host)
{
    return host && host->effect ? ysfx_get_author(host->effect) : nullptr;
}

uint32_t ETJSFX_SliderCount(const ETJSFX *host)
{
    return host ? static_cast<uint32_t>(host->sliders.size()) : 0;
}

bool ETJSFX_SliderInfo(ETJSFX *host, uint32_t ordinal, uint32_t *index,
                       const char **name, double *value, double *minimum,
                       double *maximum, double *step, bool *visible)
{
    if (!host || !host->effect || ordinal >= host->sliders.size()) return false;
    uint32_t slider = host->sliders[ordinal];
    ysfx_slider_range_t range{};
    if (!ysfx_slider_get_range(host->effect, slider, &range)) return false;
    if (index) *index = slider;
    if (name) *name = ysfx_slider_get_name(host->effect, slider);
    if (value) *value = ysfx_slider_get_value(host->effect, slider);
    if (minimum) *minimum = range.min;
    if (maximum) *maximum = range.max;
    if (step) *step = range.inc;
    if (visible) *visible = ysfx_slider_is_initially_visible(host->effect, slider);
    return true;
}

void ETJSFX_SetSlider(ETJSFX *host, uint32_t index, double value)
{
    if (host && host->effect) ysfx_slider_set_value(host->effect, index, value);
}

double ETJSFX_GetSlider(ETJSFX *host, uint32_t index)
{
    return host && host->effect ? ysfx_slider_get_value(host->effect, index) : 0.0;
}
