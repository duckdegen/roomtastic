// SPDX-License-Identifier: GPL-3.0-only
// Standalone runner, not a SwiftPM test target:
// xcrun clang++ -std=c++17 -O2 -pthread -framework Accelerate \
//   -ISources/RoomtasticDSP/include Sources/RoomtasticDSP/RoomtasticDSP.cpp \
//   Tests/RoomtasticDSPTests/DSPTests.cpp -o /tmp/roomtastic-dsp-tests
#include "RoomtasticDSP.h"
#include <algorithm>
#include <atomic>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <limits>
#include <new>
#include <thread>
#include <vector>

static thread_local bool forbidAllocation = false;
void* operator new(std::size_t n) {
    if (forbidAllocation) std::abort();
    if (void* p = std::malloc(n ? n : 1)) return p;
    throw std::bad_alloc();
}
void* operator new[](std::size_t n) { return ::operator new(n); }
void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t) noexcept { std::free(p); }

static void bufferDeadlines() {
    RTBuffer* b = rt_buffer_create(4, 2);
    assert(b);
    float input[] = {1, -1, .5f, -.5f, .25f, -.25f, .125f, -.125f};
    float out[12];
    assert(rt_buffer_read(b, out, 4, 0) == 0);
    for (int i = 0; i < 8; ++i) assert(out[i] == 0);
    assert(rt_buffer_write(b, input, 4, 0) == 0); // late cannot return later
    assert(rt_buffer_write(b, input, 4, 6) == 4);
    assert(rt_buffer_write(b, input, 1, 10) == 0); // full cannot overwrite
    assert(rt_buffer_read(b, out, 6, 4) == 4);
    for (int i = 0; i < 4; ++i) assert(out[i] == 0);
    for (int i = 0; i < 8; ++i) assert(out[i + 4] == input[i]);
    assert(rt_buffer_read(b, out, 4, 6) == 0); // rewind cannot replay
    assert(rt_buffer_write(b, input, 4, 8) == 2); // partially late packet
    assert(rt_buffer_read(b, out, 2, 10) == 2);
    for (int i = 0; i < 4; ++i) assert(out[i] == input[i + 4]);
    assert(rt_buffer_write(b, input, 1, 9) == 0);
    rt_buffer_reset(b);
    assert(rt_buffer_write(b, input, 4, 0) == 4);
    assert(rt_buffer_read(b, out, 4, 0) == 4);
    assert(rt_buffer_read(b, out, 1, UINT64_MAX) == 0 && out[0] == 0);
    rt_buffer_destroy(b);
}

static void bufferConcurrent() {
    RTBuffer* b = rt_buffer_create(127, 2);
    assert(b);
    constexpr uint32_t total = 100000;
    std::atomic<uint32_t> offered{0}, acknowledged{0};
    std::thread producer([&] {
        for (uint32_t frame = 0; frame < total; ++frame) {
            while (acknowledged.load(std::memory_order_acquire) != frame) std::this_thread::yield();
            float sample[] = {float(frame + 1), -float(frame + 1)};
            assert(rt_buffer_write(b, sample, 1, frame) == 1);
            offered.store(frame + 1, std::memory_order_release);
        }
    });
    for (uint32_t frame = 0; frame < total; ++frame) {
        while (offered.load(std::memory_order_acquire) != frame + 1) std::this_thread::yield();
        float sample[2];
        assert(rt_buffer_read(b, sample, 1, frame) == 1);
        assert(sample[0] == float(frame + 1) && sample[1] == -float(frame + 1));
        acknowledged.store(frame + 1, std::memory_order_release);
    }
    producer.join();
    rt_buffer_destroy(b);
}

static void bufferConcurrentUnderflow() {
    RTBuffer* b = rt_buffer_create(31, 2);
    assert(b);
    constexpr uint32_t total = 100000;
    std::thread producer([&] {
        for (uint32_t frame = 0; frame < total; ++frame) {
            float sample[] = {float(frame + 1), -float(frame + 1)};
            rt_buffer_write(b, sample, 1, frame);
        }
    });
    for (uint32_t frame = 0; frame < total; ++frame) {
        float sample[2];
        const uint32_t actual = rt_buffer_read(b, sample, 1, frame);
        assert(actual <= 1);
        if (actual) assert(sample[0] == float(frame + 1) && sample[1] == -float(frame + 1));
        else assert(sample[0] == 0 && sample[1] == 0);
    }
    producer.join();
    float sample[2];
    assert(rt_buffer_read(b, sample, 1, total) == 0);
    rt_buffer_destroy(b);
}

static void processorLatencyAndSafety() {
    RTProcessor* p = rt_processor_create(48000, 128, 129);
    assert(p);
    const float fir[] = {0, 1, 0};
    assert(rt_processor_configure(p, 1, 0, 0, 7, fir, 3));
    std::vector<float> input(2048 * 2), output(2048);
    rt_processor_process(p, input.data(), output.data(), 1024); // finish startup ramp
    input[0] = 1;
    rt_processor_process(p, input.data(), output.data(), 128);
    for (int i = 0; i < 128; ++i) assert(output[i] == (i == 8 ? 1 : 0));
    input[0] = 0;
    rt_processor_set_controls(p, 1, 0, 1);
    rt_processor_process(p, input.data(), output.data(), 1024);
    input[0] = 1;
    rt_processor_process(p, input.data(), output.data(), 128);
    for (int i = 0; i < 128; ++i) assert(output[i] == (i == 8 ? 1 : 0));
    // Invalid gain must close the old configuration, not silently leave it active.
    assert(!rt_processor_configure(p, 1, 1, 0, 0, nullptr, 0));
    std::fill(input.begin(), input.end(), 1);
    rt_processor_process(p, input.data(), output.data(), 2048);
    for (int i = 1024; i < 2048; ++i) assert(output[i] == 0);
    assert(rt_processor_configure(p, .5, .5, 0, 0, nullptr, 0));
    rt_processor_process(p, input.data(), output.data(), 2048);
    assert(output.back() == 1);
    rt_processor_set_controls(p, 1, 1, 0);
    rt_processor_process(p, input.data(), output.data(), 2048);
    assert(output.front() > .9f && output.front() < 1); // not an abrupt mute
    for (int i = 1; i < 512; ++i) assert(std::abs(output[i] - output[i - 1]) <= 1.0f / 240 + 1e-5f);
    assert(output.back() == 0);
    const float asymmetric[] = {0, .5f, .25f};
    assert(!rt_processor_configure(p, 1, 0, 0, 0, asymmetric, 3));
    const float nonfinite[] = {std::numeric_limits<float>::quiet_NaN()};
    assert(!rt_processor_configure(p, 1, 0, 0, 0, nonfinite, 1));
    assert(rt_processor_configure(p, 1, 0, 0, 0, nullptr, 0));
    rt_processor_set_controls(p, 1, 0, 0);
    rt_processor_reset(p);
    std::fill(input.begin(), input.end(), std::numeric_limits<float>::infinity());
    rt_processor_process(p, input.data(), output.data(), 2048);
    for (float x : output) assert(x == 0);
    rt_processor_destroy(p);
}

static void clockDriftAndRecovery() {
    RTClock* c = rt_clock_create(48000);
    assert(c);
    double ratio = 0;
    for (int i = 0; i <= 4000; ++i) ratio = rt_clock_update(c, i * 480.0 * 1.0005, i * .01);
    assert(std::abs(ratio - 1.0005) < 1e-6);
    assert(rt_clock_update(c, 0, 0) == 1);
    for (int i = 1; i <= 4000; ++i) ratio = rt_clock_update(c, i * 480.0 * .9995, i * .01);
    assert(std::abs(ratio - .9995) < 1e-6);
    assert(rt_clock_update(c, std::numeric_limits<double>::quiet_NaN(), 41) == 1);
    for (int i = 0; i <= 4000; ++i) ratio = rt_clock_update(c, i * 480.0 * 1.005, i * .01);
    assert(ratio == 1.001);
    rt_clock_destroy(c);
}

static std::vector<float> resampleChunks(const std::vector<float>& input, uint32_t chunk, double ratio) {
    RTResampler* r = rt_resampler_create(128);
    assert(r);
    std::vector<float> result;
    float output[74];
    uint32_t offset = 0;
    while (offset < input.size() / 2) {
        uint32_t left = std::min(chunk, uint32_t(input.size() / 2) - offset);
        while (left) {
            uint32_t consumed = 0;
            const uint32_t produced = rt_resampler_process(r, input.data() + offset * 2, left, output, 37, ratio, &consumed);
            assert(consumed || produced);
            result.insert(result.end(), output, output + produced * 2);
            offset += consumed; left -= consumed;
        }
    }
    for (;;) {
        uint32_t consumed = 1;
        const uint32_t produced = rt_resampler_process(r, nullptr, 0, output, 37, ratio, &consumed);
        assert(consumed == 0);
        result.insert(result.end(), output, output + produced * 2);
        if (!produced) break;
    }
    rt_resampler_destroy(r);
    return result;
}
static void resamplerContinuity() {
    constexpr double pi = 3.14159265358979323846;
    std::vector<float> input(4800 * 2);
    for (int i = 0; i < 4800; ++i) {
        input[i * 2] = float(.5 * std::sin(2 * pi * 1000 * i / 48000));
        input[i * 2 + 1] = -input[i * 2];
    }
    const double ratio = 48000.0 / 44100;
    auto single = resampleChunks(input, 4800, ratio);
    auto chunked = resampleChunks(input, 13, ratio);
    assert(single == chunked); // phase/history must survive arbitrary callback splits
    assert(std::abs(double(single.size() / 2) - (4800 - 16) / ratio) < 2);
    double squaredError = 0;
    for (size_t i = 100; i < single.size() / 2; ++i) {
        const double expected = .5 * std::sin(2 * pi * 1000 * i / 44100);
        squaredError += std::pow(single[i * 2] - expected, 2);
        assert(single[i * 2 + 1] == -single[i * 2]);
    }
    assert(std::sqrt(squaredError / (single.size() / 2 - 100)) < .001);
    RTResampler* r = rt_resampler_create(128);
    float out[64]; uint32_t consumed = 99;
    assert(rt_resampler_process(r, input.data(), 32, out, 32, 2, &consumed) == 0 && consumed == 0);
    rt_resampler_destroy(r);
}

static void callbackAllocationGuard() {
    RTBuffer* b = rt_buffer_create(1024, 2);
    RTProcessor* p = rt_processor_create(48000, 1024, 2049);
    RTResampler* r = rt_resampler_create(1024);
    RTClock* c = rt_clock_create(48000);
    assert(b && p && r && c);
    float input[1024] = {}, stereo[1024] = {}, mono[512] = {};
    const float fir[] = {.25f, .5f, .25f};
    assert(rt_processor_configure(p, .5, .5, 0, 32, fir, 3));
    // Warm Accelerate once before trapping C++ heap allocation.
    rt_processor_process(p, input, mono, 512);
    forbidAllocation = true;
    for (uint32_t i = 0; i < 16; ++i) {
        rt_buffer_write(b, input, 512, uint64_t(i) * 512);
        rt_buffer_read(b, stereo, 512, uint64_t(i) * 512);
        rt_processor_set_controls(p, .5, 0, i & 1);
        assert(rt_processor_configure(p, .5, .5, 0, i, fir, 3));
        rt_processor_process(p, stereo, mono, 512);
        uint32_t consumed;
        rt_resampler_process(r, stereo, 512, input, 512, 1.0005, &consumed);
        rt_clock_update(c, i * 512, double(i) * 512 / 48000);
    }
    forbidAllocation = false;
    rt_buffer_destroy(b); rt_processor_destroy(p); rt_resampler_destroy(r); rt_clock_destroy(c);
}
static void mixedApplicationHeadroom() {
    RTProcessor* p = rt_processor_create(48000, 0, 1);
    assert(p && rt_processor_configure(p, 1, 0, 0, 0, nullptr, 0));
    rt_processor_set_controls(p, 0.25f, 0, 0);
    std::vector<float> input(1024), output(512);
    for (size_t i = 0; i < 512; ++i) input[2 * i] = 1.6f;
    rt_processor_process(p, input.data(), output.data(), 512);
    assert(std::abs(output.back() - 0.4f) < 0.00002f);
    rt_processor_destroy(p);
}

int main() {
    bufferDeadlines(); bufferConcurrent(); bufferConcurrentUnderflow();
    processorLatencyAndSafety(); mixedApplicationHeadroom(); clockDriftAndRecovery(); resamplerContinuity(); callbackAllocationGuard();
    std::puts("Roomtastic DSP regression scenarios passed");
}
