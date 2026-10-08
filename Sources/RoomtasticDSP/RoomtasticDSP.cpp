// SPDX-License-Identifier: GPL-3.0-only
#include "RoomtasticDSP.h"
#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <limits>
#include <new>
#include <vector>
#include <fcntl.h>
#include <sys/mman.h>

int rt_open_shared_clock(void) { return shm_open("/cliairplay-ptp", O_RDONLY, 0); }

namespace {
constexpr uint32_t maxCapacity = 1u << 22;
constexpr double rtPi = 3.14159265358979323846;
static_assert(std::atomic<uint64_t>::is_always_lock_free, "Realtime publication requires lock-free UInt64");
static_assert(std::atomic<uint32_t>::is_always_lock_free, "Realtime controls require lock-free UInt32");
float clean(float x) { return std::isfinite(x) ? std::clamp(x, -1.0f, 1.0f) : 0.0f; }
float finiteSample(float x) { return std::isfinite(x) ? x : 0.0f; }
float approach(float value, float target, float step) {
    return value < target ? std::min(target, value + step) : std::max(target, value - step);
}
}

struct RTAtomic64 { std::atomic<uint64_t> value; explicit RTAtomic64(uint64_t x) : value(x) {} };
RTAtomic64* rt_atomic_create(uint64_t x) { return new (std::nothrow) RTAtomic64(x); }
void rt_atomic_destroy(RTAtomic64* x) { delete x; }
uint64_t rt_atomic_load(const RTAtomic64* x) { return x ? x->value.load(std::memory_order_seq_cst) : 0; }
void rt_atomic_store(RTAtomic64* x, uint64_t next) { if (x) x->value.store(next, std::memory_order_seq_cst); }

struct RTBuffer {
    const uint32_t capacity, channels;
    std::vector<float> samples;
    std::vector<uint64_t> timestamps;
    alignas(64) std::atomic<uint64_t> head{0};
    alignas(64) std::atomic<uint64_t> tail{0};
    alignas(64) std::atomic<uint64_t> deadline{0};
    uint64_t lastWritten = 0;
    bool hasWritten = false;
    RTBuffer(uint32_t c, uint32_t n) : capacity(c), channels(n), samples(size_t(c) * n), timestamps(c) {}
};
RTBuffer* rt_buffer_create(uint32_t capacity, uint32_t channels) {
    if (!capacity || capacity > maxCapacity || !channels || channels > 32) return nullptr;
    try { return new RTBuffer(capacity, channels); } catch (...) { return nullptr; }
}
void rt_buffer_destroy(RTBuffer* b) { delete b; }
void rt_buffer_reset(RTBuffer* b) {
    if (!b) return;
    b->head.store(0, std::memory_order_relaxed);
    b->tail.store(0, std::memory_order_relaxed);
    b->deadline.store(0, std::memory_order_relaxed);
    b->hasWritten = false;
    b->lastWritten = 0;
}
uint32_t rt_buffer_write(RTBuffer* b, const float* input, uint32_t frames, uint64_t first) {
    if (!b || !input || first > UINT64_MAX - frames) return 0;
    uint64_t head = b->head.load(std::memory_order_relaxed);
    uint32_t written = 0;
    for (uint32_t i = 0; i < frames; ++i) {
        const uint64_t stamp = first + i;
        if (stamp < b->deadline.load(std::memory_order_acquire) || (b->hasWritten && stamp <= b->lastWritten)) continue;
        if (head - b->tail.load(std::memory_order_acquire) >= b->capacity) break;
        const size_t index = head % b->capacity;
        std::memcpy(b->samples.data() + index * b->channels, input + size_t(i) * b->channels, sizeof(float) * b->channels);
        b->timestamps[index] = stamp;
        b->lastWritten = stamp;
        b->hasWritten = true;
        ++head;
        ++written;
        b->head.store(head, std::memory_order_release);
    }
    return written;
}
uint32_t rt_buffer_read(RTBuffer* b, float* output, uint32_t frames, uint64_t first) {
    if (!b || !output) return 0;
    std::fill_n(output, size_t(frames) * b->channels, 0.0f);
    if (first > UINT64_MAX - frames) return 0;
    const uint64_t previous = b->deadline.load(std::memory_order_relaxed);
    const uint64_t end = first + frames;
    b->deadline.store(std::max(previous, end), std::memory_order_release);
    uint64_t tail = b->tail.load(std::memory_order_relaxed);
    uint32_t copied = 0;
    for (uint32_t i = 0; i < frames; ++i) {
        const uint64_t requested = first + i;
        if (requested < previous) continue;
        while (tail != b->head.load(std::memory_order_acquire)) {
            const size_t index = tail % b->capacity;
            const uint64_t stamp = b->timestamps[index];
            if (stamp > requested) break;
            if (stamp == requested) {
                std::memcpy(output + size_t(i) * b->channels, b->samples.data() + index * b->channels, sizeof(float) * b->channels);
                ++copied;
            }
            ++tail;
            b->tail.store(tail, std::memory_order_release);
            if (stamp == requested) break;
        }
    }
    return copied;
}

struct RTProcessor {
    const uint32_t maxDelay, maxTaps, delayCapacity;
    const float rampStep;
    std::vector<float> coefficients, pendingCoefficients, history, wetDelay, dryDelay;
    uint32_t taps = 1, pendingTaps = 1, delay = 0, pendingDelay = 0, cursor = 0, delayCursor = 0;
    float left = 0, right = 0, pendingLeft = 0, pendingRight = 0;
    float transition = 0, volume = 0, bypass = 0;
    bool configured = false, pending = false, valid = false;
    // Packed controls provide one coherent snapshot (16-bit volume + flags).
    std::atomic<uint32_t> controls{65535};
    RTProcessor(double rate, uint32_t d, uint32_t t)
        : maxDelay(d), maxTaps(t), delayCapacity(d + t / 2 + 1), rampStep(float(1.0 / std::max(1.0, rate * .005))),
          coefficients(t), pendingCoefficients(t), history(size_t(t) * 2), wetDelay(delayCapacity), dryDelay(delayCapacity) {}
    void clearHistory() {
        std::fill(history.begin(), history.end(), 0.0f);
        std::fill(wetDelay.begin(), wetDelay.end(), 0.0f);
        std::fill(dryDelay.begin(), dryDelay.end(), 0.0f);
        cursor = delayCursor = 0;
    }
    void install() {
        coefficients.swap(pendingCoefficients);
        taps = pendingTaps; delay = pendingDelay; left = pendingLeft; right = pendingRight;
        clearHistory(); pending = false; configured = true; valid = true;
    }
};
RTProcessor* rt_processor_create(double rate, uint32_t maxDelay, uint32_t maxTaps) {
    if (!std::isfinite(rate) || rate < 8000 || rate > 384000 || maxDelay > maxCapacity || !maxTaps || maxTaps > 65535) return nullptr;
    try { return new RTProcessor(rate, maxDelay, maxTaps); } catch (...) { return nullptr; }
}
void rt_processor_destroy(RTProcessor* p) { delete p; }
int rt_processor_configure(RTProcessor* p, double left, double right, double gainDB, uint32_t delay, const float* fir, uint32_t taps) {
    if (!p) return 0;
    auto reject = [p]() { p->valid = false; p->pending = false; return 0; };
    if (!std::isfinite(left) || !std::isfinite(right) || !std::isfinite(gainDB) || gainDB < -120 || gainDB > 24 ||
        delay > p->maxDelay || taps > p->maxTaps || (taps && (!fir || !(taps & 1)))) return reject();
    double norm = taps ? 0 : 1;
    for (uint32_t i = 0; i < taps; ++i) {
        if (!std::isfinite(fir[i])) return reject();
        norm += std::abs(double(fir[i]));
        if (std::abs(double(fir[i]) - fir[taps - 1 - i]) > 1e-6 * std::max(1.0, std::abs(double(fir[i])))) return reject();
    }
    const double gain = std::pow(10.0, gainDB / 20.0);
    if ((std::abs(left) + std::abs(right)) * gain * std::max(1.0, norm) > 1.000001) return reject();
    p->pendingTaps = std::max(1u, taps);
    p->pendingDelay = delay;
    p->pendingLeft = float(left * gain);
    p->pendingRight = float(right * gain);
    if (taps) for (uint32_t i = 0; i < taps; ++i) p->pendingCoefficients[i] = fir[taps - 1 - i];
    else p->pendingCoefficients[0] = 1;
    p->pending = true;
    if (!p->configured || p->transition == 0) p->install();
    return 1;
}
void rt_processor_set_controls(RTProcessor* p, float volume, int muted, int bypass) {
    if (!p) return;
    volume = std::isfinite(volume) ? std::clamp(volume, 0.0f, 1.0f) : 0;
    const uint32_t packed = uint32_t(std::lround(volume * 65535)) | (muted ? 1u << 16 : 0) | (bypass ? 1u << 17 : 0);
    p->controls.store(packed, std::memory_order_release);
}
void rt_processor_process(RTProcessor* p, const float* stereo, float* mono, uint32_t frames) {
    if (!mono) return;
    if (!p || !stereo) { std::fill_n(mono, frames, 0.0f); return; }
    const uint32_t controls = p->controls.load(std::memory_order_acquire);
    const float targetVolume = controls & (1u << 16) ? 0 : float(controls & 65535) / 65535;
    const float targetBypass = controls & (1u << 17) ? 1 : 0;
    for (uint32_t i = 0; i < frames; ++i) {
        p->transition = approach(p->transition, p->pending || !p->valid ? 0.0f : 1.0f, p->rampStep);
        if (p->pending && p->transition == 0) p->install();
        p->volume = approach(p->volume, targetVolume, p->rampStep);
        p->bypass = approach(p->bypass, targetBypass, p->rampStep);
        // Mixed application streams may exceed full scale before master attenuation.
        const float input = finiteSample(stereo[size_t(i) * 2]) * p->left + finiteSample(stereo[size_t(i) * 2 + 1]) * p->right;
        p->history[p->cursor] = p->history[p->cursor + p->maxTaps] = input;
        p->cursor = (p->cursor + 1) % p->maxTaps;
        float wet = 0;
        vDSP_dotpr(p->history.data() + p->cursor + p->maxTaps - p->taps, 1, p->coefficients.data(), 1, &wet, p->taps);
        p->wetDelay[p->delayCursor] = wet;
        p->dryDelay[p->delayCursor] = input;
        const uint32_t wetIndex = (p->delayCursor + p->delayCapacity - p->delay) % p->delayCapacity;
        const uint32_t dryIndex = (p->delayCursor + p->delayCapacity - p->delay - (p->taps - 1) / 2) % p->delayCapacity;
        const float corrected = p->wetDelay[wetIndex];
        const float bypassed = p->dryDelay[dryIndex];
        mono[i] = clean((corrected + (bypassed - corrected) * p->bypass) * p->volume * p->transition);
        p->delayCursor = (p->delayCursor + 1) % p->delayCapacity;
    }
}
void rt_processor_reset(RTProcessor* p) {
    if (!p) return;
    if (p->pending) p->install();
    else p->clearHistory();
    p->transition = p->volume = 0;
    p->bypass = p->controls.load(std::memory_order_acquire) & (1u << 17) ? 1 : 0;
}

struct RTClock {
    double nominal, previousSample = 0, previousHost = 0, anchorSample = 0, anchorHost = 0, ratio = 1;
    bool initialized = false;
    explicit RTClock(double rate) : nominal(rate) {}
    void anchor(double sample, double host) { previousSample = anchorSample = sample; previousHost = anchorHost = host; ratio = 1; initialized = true; }
};
RTClock* rt_clock_create(double nominal) {
    if (!std::isfinite(nominal) || nominal < 8000 || nominal > 384000) return nullptr;
    return new (std::nothrow) RTClock(nominal);
}
void rt_clock_destroy(RTClock* c) { delete c; }
double rt_clock_update(RTClock* c, double sample, double host) {
    if (!c) return 1;
    if (!std::isfinite(sample) || !std::isfinite(host)) { c->initialized = false; c->ratio = 1; return 1; }
    if (!c->initialized) { c->anchor(sample, host); return 1; }
    const double dt = host - c->previousHost, ds = sample - c->previousSample;
    if (dt <= 0 || dt > 2 || ds <= 0 || !std::isfinite(ds) || std::abs(ds - dt * c->nominal) > c->nominal * .02) {
        c->anchor(sample, host); return 1;
    }
    c->previousSample = sample; c->previousHost = host;
    const double window = host - c->anchorHost;
    if (window >= .25) {
        const double estimate = (sample - c->anchorSample) / (window * c->nominal);
        if (!std::isfinite(estimate) || std::abs(estimate - 1) > .01) { c->anchor(sample, host); return 1; }
        const double alpha = -std::expm1(-window / 2.0);
        c->ratio = std::clamp(c->ratio + alpha * (estimate - c->ratio), .999, 1.001);
        c->anchorSample = sample; c->anchorHost = host;
    }
    return c->ratio;
}

double rt_sync_ratio(double sourceRate, double sinkRate, double sourceRatio,
                     double sinkRatio, double error) {
    if (!std::isfinite(sourceRate) || !std::isfinite(sinkRate) ||
        !std::isfinite(sourceRatio) || !std::isfinite(sinkRatio) || !std::isfinite(error) ||
        sourceRate <= 0 || sinkRate <= 0 || sourceRatio <= 0 || sinkRatio <= 0) return 0;
    return sourceRate / sinkRate * sourceRatio / sinkRatio *
        (1 + std::clamp(error / 2.0, -.002, .002));
}

struct RTResampler {
    static constexpr int taps = 32, phases = 1024;
    uint32_t capacity;
    std::vector<float> samples, bank;
    uint64_t base = 0, end = 0;
    double position = 0;
    explicit RTResampler(uint32_t c) : capacity(c), samples(size_t(c) * 2), bank(size_t(taps) * phases) {
        for (int phase = 0; phase < phases; ++phase) {
            const double fraction = double(phase) / phases;
            double total = 0;
            for (int k = 0; k < taps; ++k) {
                const double distance = k - 15 - fraction;
                const double sinc = std::abs(distance) < 1e-12 ? .86 : std::sin(rtPi * .86 * distance) / (rtPi * distance);
                const double window = .42 + .5 * std::cos(rtPi * distance / 16) + .08 * std::cos(2 * rtPi * distance / 16);
                const double value = std::abs(distance) <= 16 ? sinc * window : 0;
                bank[size_t(phase) * taps + k] = float(value); total += value;
            }
            for (int k = 0; k < taps; ++k) bank[size_t(phase) * taps + k] /= float(total);
        }
    }
};
RTResampler* rt_resampler_create(uint32_t capacity) {
    if (capacity < 64 || capacity > maxCapacity) return nullptr;
    try { return new RTResampler(capacity); } catch (...) { return nullptr; }
}
void rt_resampler_destroy(RTResampler* r) { delete r; }
double rt_resampler_position(const RTResampler* r) { return r ? r->position : 0; }
void rt_resampler_reset(RTResampler* r) { if (r) { r->base = r->end = 0; r->position = 0; } }
uint32_t rt_resampler_process(RTResampler* r, const float* input, uint32_t inputFrames, float* output,
                             uint32_t outputCapacity, double ratio, uint32_t* consumed) {
    if (consumed) *consumed = 0;
    if (!r || !consumed || (!input && inputFrames) || (!output && outputCapacity) || !std::isfinite(ratio) || ratio < .9 || ratio > 1.12) return 0;
    uint32_t produced = 0;
    for (;;) {
        while (*consumed < inputFrames && r->end - r->base < r->capacity) {
            const size_t index = (r->end % r->capacity) * 2;
            r->samples[index] = clean(input[size_t(*consumed) * 2]);
            r->samples[index + 1] = clean(input[size_t(*consumed) * 2 + 1]);
            ++r->end; ++*consumed;
        }
        if (produced == outputCapacity || r->position + 16 >= double(r->end)) break;
        const uint64_t center = uint64_t(r->position);
        const int phase = std::min(RTResampler::phases - 1, int((r->position - double(center)) * RTResampler::phases));
        const float* coeff = r->bank.data() + size_t(phase) * RTResampler::taps;
        float left = 0, right = 0;
        for (int k = 0; k < RTResampler::taps; ++k) {
            if (center < uint64_t(15 - std::min(k, 15))) continue;
            const uint64_t frame = k < 15 ? center - uint64_t(15 - k) : center + uint64_t(k - 15);
            const size_t index = (frame % r->capacity) * 2;
            left += r->samples[index] * coeff[k]; right += r->samples[index + 1] * coeff[k];
        }
        output[size_t(produced) * 2] = left;
        output[size_t(produced) * 2 + 1] = right;
        ++produced;
        r->position += ratio;
        const uint64_t next = uint64_t(r->position);
        r->base = next > 15 ? next - 15 : 0;
    }
    return produced;
}
