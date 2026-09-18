// ETExternalProcessor.c

#include "ETExternalProcessor.h"

#include <string.h>

void ETExternalProcessor_Clear(ETExternalProcessor *processor)
{
    if (processor == NULL) return;
    memset(processor, 0, sizeof(*processor));
}

int32_t ETExternalProcessor_Process(const ETExternalProcessor *processor,
                                    float *planar,
                                    uint32_t channels,
                                    uint32_t frames,
                                    double sampleRate,
                                    double sampleTime)
{
    if (processor == NULL || processor->process == NULL) return 0;
    if (planar == NULL || channels == 0 || frames == 0) return -1;
    if (processor->maxFrames && frames > processor->maxFrames) return -2;
    if (processor->maxChannels && channels > processor->maxChannels) return -3;
    return processor->process(processor->context, planar, channels, frames,
                              sampleRate, sampleTime);
}

uint32_t ETExternalProcessor_Latency(const ETExternalProcessor *processor)
{
    if (processor == NULL || processor->latency == NULL) return 0;
    return processor->latency(processor->context);
}

double ETExternalProcessor_TailTime(const ETExternalProcessor *processor)
{
    if (processor == NULL || processor->tailTime == NULL) return 0.0;
    return processor->tailTime(processor->context);
}
