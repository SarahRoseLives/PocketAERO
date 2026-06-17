#pragma once

#include <complex>

namespace dedective {

// IIR DC-removal filter for complex IQ samples.
// Transfer function: H(z) = (1 - z^-1) / (1 - alpha * z^-1)
// This creates a very narrow notch at DC (0 Hz) while passing everything else.
// alpha close to 1.0 → narrower notch, less signal distortion.

class DCBlocker {
public:
    explicit DCBlocker(float alpha = 0.9999f) : alpha_(alpha) {}

    std::complex<float> process(std::complex<float> x) noexcept {
        auto y = x - x_prev_ + alpha_ * y_prev_;
        x_prev_ = x;
        y_prev_ = y;
        return y;
    }

    void reset() noexcept {
        x_prev_ = {};
        y_prev_ = {};
    }

private:
    float alpha_;
    std::complex<float> x_prev_{};
    std::complex<float> y_prev_{};
};

} // namespace dedective
