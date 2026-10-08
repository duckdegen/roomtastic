// SPDX-License-Identifier: GPL-3.0-only
#ifndef ROOMTASTIC_DSP_H
#define ROOMTASTIC_DSP_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Non-realtime POSIX bridge (Darwin shm_open is variadic and unavailable in Swift).
// Returns a read-only shared-clock descriptor, or -1; caller closes the descriptor.
int rt_open_shared_clock(void);


typedef struct RTBuffer RTBuffer;
typedef struct RTProcessor RTProcessor;
typedef struct RTClock RTClock;
typedef struct RTAtomic64 RTAtomic64;

// Lock-free publication for Swift/CoreAudio callback state. Creation/destruction
// are non-realtime; load/store are sequentially consistent for clock snapshots.
RTAtomic64* rt_atomic_create(uint64_t value);
void rt_atomic_destroy(RTAtomic64* value);
uint64_t rt_atomic_load(const RTAtomic64* value);
void rt_atomic_store(RTAtomic64* value, uint64_t next);
typedef struct RTResampler RTResampler;

// All create functions return NULL on invalid bounds/allocation failure.
// Audio samples are interleaved Float32, nominally in [-1, 1].
// SPSC: exactly one writing thread and one reading thread. Destruction/reset
// require BOTH threads stopped. Capacity never grows. Full queues drop new
// frames, never overwrite unread samples. Timestamps are absolute frame indices.
// Writes discard frames older than the read deadline or last accepted timestamp;
// return is the number accepted, NOT an offset for retrying a partially late write.
// Reads always initialize the entire destination (silence for gaps), advance the
// deadline, and return the number of actual frames copied. Rewinding cannot replay.
RTBuffer* rt_buffer_create(uint32_t capacityFrames, uint32_t channels);
void rt_buffer_destroy(RTBuffer* buffer);
uint32_t rt_buffer_write(RTBuffer* buffer, const float* interleaved, uint32_t frames, uint64_t firstFrame);
uint32_t rt_buffer_read(RTBuffer* buffer, float* interleaved, uint32_t frames, uint64_t firstFrame);
void rt_buffer_reset(RTBuffer* buffer);

// Configure/process/reset belong to one processing thread. Only controls may be
// changed concurrently. No processing/control call allocates or takes a lock.
// Empty FIR means unity. Otherwise FIR must be finite, odd and symmetric (linear
// phase). Bypass retains explicit delay AND FIR group delay (taps-1)/2.
// Worst-case peak headroom must be <=1 for BOTH wet and bypass paths:
// 10^(gainDB/20)*(abs(left)+abs(right))*max(1,sum(abs(fir))) <= 1.
// Invalid configuration returns 0 and fades closed. Valid configuration returns 1
// and crossfades through silence before replacing history/coefficients. Controls
// use a 5ms smoothing ramp; volume is clamped to [0,1], nonfinite means silence.
RTProcessor* rt_processor_create(double sampleRate, uint32_t maxDelayFrames, uint32_t maxFIRTaps);
void rt_processor_destroy(RTProcessor* processor);
int rt_processor_configure(RTProcessor* processor, double left, double right, double gainDB,
                           uint32_t delayFrames, const float* fir, uint32_t taps);
void rt_processor_set_controls(RTProcessor* processor, float volume, int muted, int bypass);
void rt_processor_process(RTProcessor* processor, const float* stereo, float* mono, uint32_t frames);
void rt_processor_reset(RTProcessor* processor);

// Clock is thread-confined. Returns device actual rate / nominal rate, bounded to
// [0.999,1.001]. Nonmonotonic timestamps or implausible jumps restart acquisition
// at 1.0. Use hardware-correlated host/sample timestamps, NOT callback wall time.
RTClock* rt_clock_create(double nominalRate);
void rt_clock_destroy(RTClock* clock);
double rt_clock_update(RTClock* clock, double deviceSampleTime, double hostSeconds);

// Streaming nominal-rate conversion and adaptive resampling.
// 32-tap, 1024-phase low-pass windowed sinc; 16 input-frame lookahead; bounded FIFO.
// inputPerOutput must be [0.9,1.12], including 44.1/48k conversion plus drift:
// sourceRate/sinkRate * sourceClockRatio/sinkClockRatio.
// consumed reports the prefix retained; return is output frames produced. Loop
// over the unconsumed input if output fills. Null input is permitted only with
// inputFrames=0 (drain); no extrapolated tail is invented. Input/output must not
// overlap. Invalid arguments consume/produce nothing. Reset is stopped-only.
RTResampler* rt_resampler_create(uint32_t capacityFrames);
void rt_resampler_destroy(RTResampler* resampler);
uint32_t rt_resampler_process(RTResampler* resampler, const float* stereo, uint32_t inputFrames,
                             float* output, uint32_t outputCapacity, double inputPerOutput,
                             uint32_t* consumed);
void rt_resampler_reset(RTResampler* resampler);
#ifdef __cplusplus
}
#endif
#endif
