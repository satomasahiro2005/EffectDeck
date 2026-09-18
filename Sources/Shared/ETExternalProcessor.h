// ETExternalProcessor.h
// Host-neutral, allocation-free PCM processor ABI for AU/JSFX adapters.

#ifndef ETExternalProcessor_h
#define ETExternalProcessor_h

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t (*ETExternalProcessorProcess)(
    void *context,
    float *planar,
    uint32_t channels,
    uint32_t frames,
    double sampleRate,
    double sampleTime);

typedef void (*ETExternalProcessorReset)(void *context);
typedef uint32_t (*ETExternalProcessorLatency)(void *context);
typedef double (*ETExternalProcessorTailTime)(void *context);
typedef void (*ETExternalProcessorDestroy)(void *context);

typedef struct {
    void *context;
    ETExternalProcessorProcess process;
    ETExternalProcessorReset reset;
    ETExternalProcessorLatency latency;
    ETExternalProcessorTailTime tailTime;
    ETExternalProcessorDestroy destroy;
    uint32_t maxFrames;
    uint32_t maxChannels;
} ETExternalProcessor;

/// Clear a processor descriptor without touching its context.
void ETExternalProcessor_Clear(ETExternalProcessor *processor);

/// Process one planar block. The call performs no allocation or locking.
/// A missing processor is a successful no-op.
int32_t ETExternalProcessor_Process(const ETExternalProcessor *processor,
                                    float *planar,
                                    uint32_t channels,
                                    uint32_t frames,
                                    double sampleRate,
                                    double sampleTime);

uint32_t ETExternalProcessor_Latency(const ETExternalProcessor *processor);
double ETExternalProcessor_TailTime(const ETExternalProcessor *processor);

#ifdef __cplusplus
}
#endif

#endif /* ETExternalProcessor_h */
