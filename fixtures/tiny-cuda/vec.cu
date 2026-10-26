#include "vec.cuh"

__global__ void add_kernel(const float* a, const float* b, float* out, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) out[i] = a[i] + b[i];
}

__global__ void scaled_kernel(const float* a, float* out, float k, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) out[i] = scale(a[i], k);
}

void launch_add(const float* a, const float* b, float* out, int n) {
    add_kernel<<<(n + 255) / 256, 256>>>(a, b, out, n);
}

void launch_scaled(const float* a, float* out, float k, int n) {
    scaled_kernel<<<(n + 255) / 256, 256>>>(a, out, k, n);
}
