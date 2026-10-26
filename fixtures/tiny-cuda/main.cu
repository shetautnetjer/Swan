#include <cuda_runtime.h>
#include "vec.cuh"

int main() {
    const int n = 1024;
    float *a, *b, *out;
    cudaMalloc(&a, n * sizeof(float));
    cudaMalloc(&b, n * sizeof(float));
    cudaMalloc(&out, n * sizeof(float));
    launch_add(a, b, out, n);
    launch_scaled(out, out, 2.0f, n);
    cudaDeviceSynchronize();
    cudaFree(a);
    cudaFree(b);
    cudaFree(out);
    return 0;
}
