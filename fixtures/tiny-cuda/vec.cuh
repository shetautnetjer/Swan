// A small CUDA library: a device helper used by two kernels.
#pragma once

__device__ inline float scale(float x, float k) { return x * k; }

void launch_add(const float* a, const float* b, float* out, int n);
void launch_scaled(const float* a, float* out, float k, int n);
