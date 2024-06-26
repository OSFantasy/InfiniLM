#include <cub/block/block_load.cuh>
#include <cub/block/block_reduce.cuh>

// assert BLOCK_SIZE >= blockDim.x
template<unsigned int BLOCK_SIZE, class Tdata>
static __device__ void padding(
    Tdata *__restrict__ o_,
    unsigned int const stride_o,
    Tdata const *__restrict__ x_,
    unsigned int const stride_x,
    Tdata const *__restrict__ w_,
    float const epsilon) {
    auto o = o_ + blockIdx.x * stride_o + threadIdx.x;
    auto x = x_[blockIdx.x * stride_x + threadIdx.x];
    auto w = w_[threadIdx.x];

    using BlockOp = cub::BlockReduce<float, BLOCK_SIZE>;
    __shared__ typename BlockOp::TempStorage temp_storage;
    auto acc = BlockOp(temp_storage).Reduce(x * x, cub::Sum());

    __shared__ Tdata rms;
    if (threadIdx.x == 0) {
        rms = Tdata(rsqrtf(acc / float(blockDim.x) + epsilon));
    }
    __syncthreads();

    *o = rms * x * w;
}

template<unsigned int BLOCK_SIZE, unsigned int ITEMS_PER_THREAD, class Tdata>
static __device__ void folding(
    Tdata *__restrict__ o,
    unsigned int const stride_o,
    Tdata const *__restrict__ x,
    unsigned int const stride_x,
    Tdata const *__restrict__ w,
    float const epsilon,
    unsigned int const items_size) {
    o += blockIdx.x * stride_o;
    x += blockIdx.x * stride_x;

    float thread_data[ITEMS_PER_THREAD];
    {
        using BlockOp = cub::BlockLoad<float, BLOCK_SIZE, ITEMS_PER_THREAD>;
        __shared__ typename BlockOp::TempStorage temp_storage;
        BlockOp(temp_storage).Load(x, thread_data, items_size, 0.f);
    }

    float squared[ITEMS_PER_THREAD];
#pragma unroll
    for (unsigned int i = 0; i < ITEMS_PER_THREAD; ++i) {
        squared[i] = thread_data[i] * thread_data[i];
    }

    float acc;
    {
        using BlockOp = cub::BlockReduce<float, BLOCK_SIZE>;
        __shared__ typename BlockOp::TempStorage temp_storage;
        acc = BlockOp(temp_storage).Reduce(squared, cub::Sum());
    }

    __shared__ Tdata rms;
    if (threadIdx.x == 0) {
        rms = Tdata(rsqrtf(acc / float(items_size) + epsilon));
    }
    __syncthreads();

#pragma unroll
    for (unsigned int i = 0; i < ITEMS_PER_THREAD; ++i) {
        if (auto j = i + threadIdx.x * ITEMS_PER_THREAD; j < items_size) {
            o[j] = Tdata(float(rms) * float(thread_data[i]) * float(w[j]));
        }
    }
}
