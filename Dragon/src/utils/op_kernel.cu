#ifdef WITH_CUDA

#include <cmath>

#include "core/context_cuda.h"
#include "core/tensor.h"
#include "utils/cuda_device.h"
#include "utils/op_kernel.h"
#include "utils/math_functions.h"

namespace dragon {

namespace kernel {

template <typename T>
__global__ void _Empty() { }

template<> void Empty<float, CUDAContext>() {
    _Empty<float> << <1, 1 >> >();
    CUDA_POST_KERNEL_CHECK;
}

template<> void Empty<float16, CUDAContext>() {
    _Empty<float> << <1, 1 >> >();
     CUDA_POST_KERNEL_CHECK;
}

/******************** activation.dropout ********************/

template<typename T>
__global__ void _Dropout(const int count, 
                         const uint32_t thresh, 
                         const T scale, 
                         const T* x, 
                         const uint32_t* mask,
                         T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        y[idx] = x[idx] * (mask[idx] > thresh) * scale;
    }
}

template<> void Dropout<float, CUDAContext>(const int count, 
                                            float prob, 
                                            float scale,
                                            const float* x, 
                                            uint32_t* mask,
                                            float* y, 
                                            CUDAContext* context) {
    uint32_t thresh = static_cast<uint32_t>(UINT_MAX * prob);
    math::RandomUniform<uint32_t, CUDAContext>(count, float(0), float(UINT_MAX), mask);
    _Dropout<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                thresh, 
                                                                 scale, 
                                                                     x, 
                                                                  mask,
                                                                    y);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _DropoutGrad(const int count, 
                             const uint32_t thresh, 
                             const T scale,
                             const T* dy, 
                             const uint32_t* mask,
                             T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        dx[idx] = dy[idx] * (mask[idx] > thresh) * scale;
    }
}

template<> void DropoutGrad<float, CUDAContext>(const int count, 
                                                float prob, 
                                                float scale, 
                                                const float* dy, 
                                                const uint32_t* mask,
                                                float* dx) {
    uint32_t thresh = static_cast<uint32_t>(UINT_MAX * prob);
    _DropoutGrad<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                    thresh, 
                                                                     scale, 
                                                                        dy, 
                                                                      mask,
                                                                       dx);
    CUDA_POST_KERNEL_CHECK;
}

/******************** activation.relu ********************/

template <typename T>
__global__ void _Relu(const int count, const T* x, const float slope, T* y) {
    CUDA_KERNEL_LOOP(i, count) {
        y[i] = x[i] > 0 ? x[i] : x[i] * slope;
    }
}

template<> void Relu<float, CUDAContext>(const int count, 
                                         const float* x, 
                                         const float slope, 
                                         float* y) {
    _Relu<float> << < GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, x, slope, y);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _ReluHalf(const int count, const half* x, const float slope, half* y) {
    const half kSlope = __float2half(slope);
    const half kZero = __float2half(0.0);
    CUDA_KERNEL_LOOP(i, count) {
#if __CUDA_ARCH__ >= 530
        y[i] = __hgt(x[i], kZero) ? x[i] : __hmul(x[i], kSlope);
#endif
    }
}

template<> void Relu<float16, CUDAContext>(const int count, 
                                           const float16* x, 
                                           const float slope, 
                                           float16* y) {
    _ReluHalf<half> << < GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                       reinterpret_cast<const half*>(x), 
                                                                  slope, 
                                            reinterpret_cast<half*>(y));
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _ReluGrad(const int count, 
                          const T* dy, 
                          const T* y, 
                          const float slope, 
                          T* dx) {
    CUDA_KERNEL_LOOP(i, count){
        dx[i] = dy[i] * ((y[i] > 0) + slope * (y[i] <= 0));
    }
}

template<> void ReluGrad<float, CUDAContext>(const int count, 
                                             const float* dy, 
                                             const float* y, 
                                             const float slope, 
                                             float* dx) {
    _ReluGrad<float> << < GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                      dy, 
                                                                       y, 
                                                                   slope, 
                                                                     dx);
    CUDA_POST_KERNEL_CHECK;
}

/******************** activation.sigmoid ********************/

template <typename T>
__device__ T _SigmoidUnit(const T x) { 
    return T(1) / (T(1) + exp(-x)); 
}

template <typename T>
__global__ void _Sigmoid(const int n, const T* x, T* y) {
    CUDA_KERNEL_LOOP(i, n) {
        y[i] = _SigmoidUnit<T>(x[i]);
    }
}

template<> void Sigmoid<float, CUDAContext>(const int count, const float* x, float* y) {
    _Sigmoid<float> << < GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, x, y);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _SigmoidGrad(const int count, const T* dy, const T* y, T* dx) {
    CUDA_KERNEL_LOOP(i, count) {
        dx[i] = dy[i] * y[i] * (1 - y[i]);
    }
}

template<> void SigmoidGrad<float, CUDAContext>(const int count, 
                                                const float* dy, 
                                                const float* y, 
                                                float* dx) {
    _SigmoidGrad<float> << < GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, dy, y, dx);
    CUDA_POST_KERNEL_CHECK;
}

/******************** activation.softmax ********************/

template <typename T>
__global__ void _SoftmaxMaxClass(const int outer_dim, 
                                 const int classes,
                                 const int inner_dim, 
                                 const T* x, 
                                 T* scale) {
    CUDA_KERNEL_LOOP(idx, outer_dim * inner_dim) {
        int o_idx = idx / inner_dim;
        int i_idx = idx % inner_dim;
        T max_val = -FLT_MAX;
        for (int c = 0; c < classes; c++)
            max_val = max(x[(o_idx * classes + c) * inner_dim + i_idx], max_val);
        scale[idx] = max_val;
    }
}

template <typename T>
__global__ void _SoftmaxSubtract(const int count, 
                                 const int classes,
                                 const int inner_dim, 
                                 const T* scale, 
                                 T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        int o_idx = idx / inner_dim / classes;
        int i_idx = idx % inner_dim;
        y[idx] -= scale[o_idx * inner_dim + i_idx];
    }
}

template <typename T>
__global__ void _SoftmaxExp(const int count, T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        y[idx] = std::exp(y[idx]);
    }
}

template <typename T>
__global__ void _SoftmaxSumClass(const int outer_dim, 
                                 const int classes,
                                 const int inner_dim, 
                                 const T* y, 
                                 T* scale) {
    CUDA_KERNEL_LOOP(idx, outer_dim * inner_dim) {
        int o_idx = idx / inner_dim;
        int i_idx = idx % inner_dim;
        T sum = 0;
        for (int c = 0; c < classes; c++)
            sum += y[(o_idx * classes + c) * inner_dim + i_idx];
        scale[idx] = sum;
    }
}

template <typename T>
 __global__ void _SoftmaxDiv(const int count, 
                             const int classes, 
                             const int inner_dim,
                             const T* scale, 
                             T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        int o_idx = idx / inner_dim / classes;
        int i_idx = idx % inner_dim;
        y[idx] /= scale[o_idx * inner_dim + i_idx];
    }
}

template<> void Softmax<float, CUDAContext>(const int count, 
                                            const int classes, 
                                            const int outer_dim, 
                                            const int inner_dim,
                                            const float* sum_multiplier, 
                                            const float* x, 
                                            float* scale, 
                                            float* y,
                                            CUDAContext* context) {
    const int num_preds = inner_dim * outer_dim;
    _SoftmaxMaxClass<float> << <GET_BLOCKS(num_preds), CUDA_NUM_THREADS >> >(outer_dim, 
                                                                               classes, 
                                                                             inner_dim, 
                                                                                     x, 
                                                                                scale);
    _SoftmaxSubtract<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                       classes, 
                                                                     inner_dim, 
                                                                         scale, 
                                                                            y);
    _SoftmaxExp<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, y);
    _SoftmaxSumClass<float> << <GET_BLOCKS(num_preds), CUDA_NUM_THREADS >> >(outer_dim, 
                                                                               classes, 
                                                                             inner_dim, 
                                                                                     y, 
                                                                                scale);
    _SoftmaxDiv<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                  classes, 
                                                                inner_dim, 
                                                                    scale, 
                                                                       y);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _SoftmaxDot(const int outer_dim, 
                            const int classes, 
                            const int inner_dim,
                            const T* dy, 
                            const T* y, 
                            T* scale) {
    CUDA_KERNEL_LOOP(idx, outer_dim * inner_dim) {
        int o_idx = idx / inner_dim;
        int i_idx = idx % inner_dim;
        T dot = 0;
        for (int c = 0; c < classes; c++)
            dot += (y[(o_idx * classes + c) * inner_dim + i_idx] * 
                   dy[(o_idx * classes + c) * inner_dim + i_idx]);
        scale[idx] = dot;
    }
}

template<> void SoftmaxGrad<float, CUDAContext>(const int count, 
                                                const int classes, 
                                                const int outer_dim, 
                                                const int inner_dim,
                                                const float* sum_multiplier, 
                                                const float* dy, 
                                                const float* y, 
                                                float* scale, 
                                                float* dx) {
    const int num_preds = inner_dim * outer_dim;
    _SoftmaxDot<float> << <GET_BLOCKS(num_preds), CUDA_NUM_THREADS >> >(outer_dim,
                                                                          classes, 
                                                                        inner_dim, 
                                                                               dy, 
                                                                                y, 
                                                                           scale);
    _SoftmaxSubtract<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                       classes, 
                                                                     inner_dim, 
                                                                         scale, 
                                                                           dx);
    math::Mul<float, CUDAContext>(count, dx, y, dx);
    CUDA_POST_KERNEL_CHECK;
}

/******************** activation.tanh ********************/

template <typename T>
__global__ void _Tanh(const int count, const T* x, T* y) {
    CUDA_KERNEL_LOOP(i, count) {
        y[i] = std::tanh(x[i]);
    }
}

template<> void Tanh<float, CUDAContext>(const int count, const float* x, float* y) {
    _Tanh<float> << < GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, x, y);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _TanhGrad(const int count, const T* dy, const T* y, T* dx) {
    CUDA_KERNEL_LOOP(i, count) {
        dx[i] = dy[i] * (1 - y[i] * y[i]);
    }
}

template<> void TanhGrad<float, CUDAContext>(const int count, 
                                             const float* dy, 
                                             const float* y, 
                                             float* dx) {
    _TanhGrad<float> << < GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, dy, y, dx);
    CUDA_POST_KERNEL_CHECK;
}

/******************** arithmetic.bias_add ********************/

template <typename T>
__global__ void _BiasAddNCHW(const int count, 
                             const int dim, 
                             const int inner_dim,
                             const T* bias, 
                             T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int bias_idx = (idx / inner_dim) % dim;
        y[idx] += bias[bias_idx];
    }
}

template<> void BiasAdd<float, CUDAContext>(const int count, 
                                            const int outer_dim, 
                                            const int dim, 
                                            const int inner_dim,
                                            const string& format, 
                                            const float* bias, 
                                            const float* bias_multiplier, 
                                            float* y) {
    if (format == "NCHW") {
        _BiasAddNCHW<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                           dim, 
                                                                     inner_dim, 
                                                                          bias, 
                                                                            y);
    } else { NOT_IMPLEMENTED; }
}

/******************** arithmetic.clip ********************/

template <typename T>
__global__ void _Clip(const int count, 
                      const T low, 
                      const T high, 
                      const T* x,
                      T* mask,
                      T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        mask[idx] = 1.0;
        if (x[idx] > high || x[idx] < low) mask[idx] = 0.0;
        y[idx] = x[idx] > high ? high : x[idx];
        y[idx] = x[idx] < low ? low : x[idx];
    }
}

template <> void Clip<float, CUDAContext>(const int count,
                                          const float low,
                                          const float high,
                                          const float* x,
                                          float* mask,
                                          float* y) {
    _Clip<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                low, 
                                                               high, 
                                                                  x,
                                                               mask,
                                                                 y);
}

/******************** arithmetic.scale ********************/

template <typename T>
__global__ void _ScaleWithoutBias(const int n, 
                                  const T* x, 
                                  const T* scale,
                                  const int scale_dim, 
                                  const int inner_dim, 
                                  T* y) {
    CUDA_KERNEL_LOOP(idx, n) {
        const int scale_idx = (idx / inner_dim) % scale_dim;
         y[idx] = x[idx] * scale[scale_idx];
    }
}

template <typename T>
__global__ void _ScaleWithBias(const int n, 
                               const T* x, 
                               const T* scale, 
                               const T* bias, 
                               const int scale_dim, 
                               const int inner_dim, 
                               T* y) {
    CUDA_KERNEL_LOOP(idx, n) {
        const int scale_idx = (idx / inner_dim) % scale_dim;
        y[idx] = x[idx] * scale[scale_idx] + bias[scale_idx];
    }
}

template<> void Scale<float, CUDAContext>(const int axis, 
                                          Tensor* x, 
                                          Tensor* gamma,
                                          Tensor* beta, 
                                          Tensor* BMul, 
                                          Tensor* y) {
    const int count = x->count();
    const int inner_dim = x->count(axis + gamma->ndim());
    const int scale_dim = gamma->count();
    auto* Xdata = x->data<float, CUDAContext>();
    auto* Ydata = y->mutable_data<float, CUDAContext>();
    auto* Sdata = gamma->data<float, CUDAContext>();
    auto* Bdata = beta != nullptr ? 
                          beta->data<float, CUDAContext>() : 
                          nullptr;
    if (Bdata != nullptr)
        _ScaleWithBias<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                           Xdata, 
                                                                           Sdata, 
                                                                           Bdata, 
                                                                       scale_dim, 
                                                                       inner_dim, 
                                                                          Ydata);
    else _ScaleWithoutBias<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                               Xdata, 
                                                                               Sdata, 
                                                                           scale_dim, 
                                                                           inner_dim, 
                                                                              Ydata);
}

template <typename T>
__global__ void _ScaleWithoutBiasHalf(const int n, 
                                      const half* x, 
                                      const half* scale,
                                      const int scale_dim, 
                                      const int inner_dim, 
                                      half* y) {
    CUDA_KERNEL_LOOP(idx, n) {
#if __CUDA_ARCH__ >= 530
        const int scale_idx = (idx / inner_dim) % scale_dim;
        y[idx] = __hmul(x[idx], scale[scale_idx]);
#endif
    }
}

template <typename T>
__global__ void _ScaleWithBiasHalf(const int n, 
                                   const half* x, 
                                   const half* scale, 
                                   const half* bias, 
                                   const int scale_dim, 
                                   const int inner_dim, 
                                   half* y) {
    CUDA_KERNEL_LOOP(idx, n) {
#if __CUDA_ARCH__ >= 530
        const int scale_idx = (idx / inner_dim) % scale_dim;
        y[idx] = __hadd(__hmul(x[idx], scale[scale_idx]), bias[scale_idx]);
#endif
    }
}

template<> void Scale<float16, CUDAContext>(const int axis, 
                                            Tensor* x, 
                                            Tensor* gamma,
                                            Tensor* beta, 
                                            Tensor* BMul, 
                                            Tensor* y) {
    const int count = x->count();
    const int inner_dim = x->count(axis + gamma->ndim());
    const int scale_dim = gamma->count();
    auto* Xdata = x->data<float16, CUDAContext>();
    auto* Ydata = y->mutable_data<float16, CUDAContext>();
    auto* Sdata = gamma->data<float16, CUDAContext>();
    auto* Bdata = beta != nullptr ? 
                          beta->data<float16, CUDAContext>() :
                          nullptr;
    if (Bdata != nullptr)
        _ScaleWithBiasHalf<half> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                               reinterpret_cast<const half*>(Xdata),
                                               reinterpret_cast<const half*>(Sdata),
                                               reinterpret_cast<const half*>(Bdata),
                                                                          scale_dim, 
                                                                          inner_dim, 
                                                    reinterpret_cast<half*>(Ydata));
    else _ScaleWithoutBiasHalf<half> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                   reinterpret_cast<const half*>(Xdata),
                                                   reinterpret_cast<const half*>(Sdata),
                                                                              scale_dim, 
                                                                              inner_dim, 
                                                        reinterpret_cast<half*>(Ydata));
}

template <> void ScaleGrad<float, CUDAContext>(const int axis, 
                                               Tensor* dy, 
                                               Tensor* gamma, 
                                               Tensor* dx) {
    const int count = dx->count();
    const int inner_dim = dx->count(axis + gamma->ndim());
    const int scale_dim = gamma->count();
    auto* dYdata = dy->data<float, CUDAContext>();
    auto* dXdata = dx->mutable_data<float, CUDAContext>();
    auto* Sdata = gamma->data<float, CUDAContext>();
    _ScaleWithoutBias<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                         dYdata, 
                                                                          Sdata, 
                                                                      scale_dim, 
                                                                      inner_dim, 
                                                                        dXdata);
}

/******************** common.argmax ********************/

template <typename T>
__global__ void _Argmax(const int count, 
                        const int axis_dim, 
                        const int inner_dim, 
                        const T* x, 
                        T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        T max_val = -FLT_MAX;
        int max_idx = -1;
        for (int j = 0; j < axis_dim; ++j) {
            const T val = x[(idx / inner_dim * axis_dim + j) 
                                * inner_dim + idx % inner_dim];
            if (val > max_val) {
                max_val = val;
                max_idx = j;
            }
        }
        y[idx] = max_idx;
    }
}

template<> void Argmax<float, CUDAContext>(const int count, 
                                           const int axis_dim, 
                                           const int inner_dim, 
                                           const int top_k, 
                                           const float* x, 
                                           float* y) {
    CHECK_EQ(top_k, 1) << "top_k > 1 is not implemented with CUDA";
    _Argmax<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                             axis_dim, 
                                                            inner_dim, 
                                                                    x, 
                                                                   y);
    CUDA_POST_KERNEL_CHECK;
}

/******************** common.at ********************/

template <typename T>
__global__ void _CanonicalAxis(const int count, const int dim, T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        if (y[idx] < 0) y[idx] += dim;
    }
}

template <> void CanonicalAxis<float, CUDAContext>(const int count, const int dim, float* y) {
    _CanonicalAxis<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, dim, y);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _At(const int count, 
                    const int outer_dim, 
                    const int inner_dim,
                    const int x_slice_dim, 
                    const int y_slice_dim, 
                    const T* indices, 
                    const T* x, 
                    T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int outer_idx = idx / inner_dim / y_slice_dim;
        const int slice_idx = idx % inner_dim;
        const int y_idx_offset = (idx / inner_dim) % y_slice_dim;
        const int x_idx_offset = indices[y_idx_offset];
        const int x_idx = (outer_idx * x_slice_dim + x_idx_offset)
                                     * inner_dim + slice_idx;
        y[idx] = x[x_idx];
    }
}

template <> void At<float, CUDAContext>(const int count, 
                                        const int outer_dim, 
                                        const int inner_dim,
                                        const int x_slice_dim, 
                                        const int y_slice_dim, 
                                        const float* indices,
                                        const float* x, 
                                        float* y, 
                                        CUDAContext* context) {
    _At<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                        outer_dim, 
                                                        inner_dim, 
                                                      x_slice_dim, 
                                                      y_slice_dim,
                                                          indices, 
                                                                x, 
                                                               y);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _AtGrad(const int count, 
                        const int outer_dim, 
                        const int inner_dim,
                        const int x_slice_dim, 
                        const int y_slice_dim, 
                        const T* indices, 
                        const T* dy, 
                        T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int outer_idx = idx / inner_dim / y_slice_dim;
        const int slice_idx = idx % inner_dim;
        const int y_idx_offset = (idx / inner_dim) % y_slice_dim;
        const int x_idx_offset = indices[y_idx_offset];
        const int x_idx = (outer_idx * x_slice_dim + x_idx_offset)
                                     * inner_dim + slice_idx;
        atomicAdd(dx + x_idx, dy[idx]);
    }
}

template <> void AtGrad<float, CUDAContext>(const int count, 
                                            const int outer_dim, 
                                            const int inner_dim,
                                            const int x_slice_dim, 
                                            const int y_slice_dim, 
                                            const float* indices,
                                            const float* dy, 
                                            float* dx, 
                                            CUDAContext* context) {
    _AtGrad<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                            outer_dim, 
                                                            inner_dim, 
                                                          x_slice_dim, 
                                                          y_slice_dim,
                                                              indices, 
                                                                   dy, 
                                                                  dx);
    CUDA_POST_KERNEL_CHECK;
}

/******************** common.concat ********************/

template <typename T>
__global__ void _Concat(const int count, 
                        const int outer_dim, 
                        const int inner_dim,
                        const int x_concat_dim, 
                        const int y_concat_dim, 
                        const int concat_offset, 
                        const T* x, 
                        T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int tmp = x_concat_dim * inner_dim;
        const int outer_idx = idx / tmp;
        const int concat_idx = idx % tmp;
        const int y_idx = (outer_idx * y_concat_dim + concat_offset) 
                                     * inner_dim + concat_idx;
        y[y_idx] = x[idx];
    }
}

template <> void Concat<float, CUDAContext>(const int count, 
                                            const int outer_dim, 
                                            const int inner_dim,
                                            const int x_concat_dim, 
                                            const int y_concat_dim, 
                                            const int concat_offset,
                                            const float* x, 
                                            float* y, 
                                            CUDAContext* context) {
    _Concat<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                            outer_dim, 
                                                            inner_dim, 
                                                         x_concat_dim, 
                                                         y_concat_dim,
                                                        concat_offset, 
                                                                    x, 
                                                                   y);
    CUDA_POST_KERNEL_CHECK;
}

template <> void Concat<float16, CUDAContext>(const int count, 
                                              const int outer_dim, 
                                              const int inner_dim,
                                              const int x_concat_dim, 
                                              const int y_concat_dim, 
                                              const int concat_offset,
                                              const float16* x, 
                                              float16* y, 
                                              CUDAContext* context) {
    _Concat<half> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                           outer_dim, 
                                                           inner_dim, 
                                                        x_concat_dim, 
                                                        y_concat_dim,
                                                       concat_offset, 
                                    reinterpret_cast<const half*>(x),
                                         reinterpret_cast<half*>(y));
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _ConcatGrad(const int count, 
                            const int outer_dim, 
                            const int inner_dim,
                            const int x_concat_dim, 
                            const int y_concat_dim, 
                            const int concat_offset, 
                            const T* dy, 
                            T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int tmp = x_concat_dim * inner_dim;
        const int outer_idx = idx / tmp;
        const int concat_idx = idx % tmp;
        const int y_idx = (outer_idx * y_concat_dim + concat_offset)
                                     * inner_dim + concat_idx;
        dx[idx] = dy[y_idx];
    }
}

template <> void ConcatGrad<float, CUDAContext>(const int count, 
                                                const int outer_dim, 
                                                const int inner_dim,
                                                const int x_concat_dim, 
                                                const int y_concat_dim, 
                                                const int concat_offset,
                                                const float* dy, 
                                                float* dx, 
                                                CUDAContext* context) {
    _ConcatGrad<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                outer_dim, 
                                                                inner_dim, 
                                                             x_concat_dim, 
                                                             y_concat_dim,
                                                            concat_offset, 
                                                                       dy, 
                                                                      dx);
    CUDA_POST_KERNEL_CHECK;
}

template <> void ConcatGrad<float16, CUDAContext>(const int count, 
                                                  const int outer_dim, 
                                                  const int inner_dim,
                                                  const int x_concat_dim, 
                                                  const int y_concat_dim, 
                                                  const int concat_offset,
                                                  const float16* dy, 
                                                  float16* dx, 
                                                  CUDAContext* context) {
    _ConcatGrad<half> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                               outer_dim, 
                                                               inner_dim, 
                                                            x_concat_dim, 
                                                            y_concat_dim,
                                                           concat_offset, 
                                       reinterpret_cast<const half*>(dy),
                                            reinterpret_cast<half*>(dx));
    CUDA_POST_KERNEL_CHECK;
}

/******************** common.crop ********************/

template<typename T>
__global__ void _Crop2D(const int count, 
                        const int x_w_dim, 
                        const int y_w_dim, 
                        const int x_h_offset,
                        const int x_w_offset,
                        const T* x, 
                        T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int y_w = idx % y_w_dim;
        const int y_h = (idx / y_w_dim);
        y[idx] = x[(y_h + x_h_offset) * x_w_dim + x_w_offset + y_w];
    }
}

template<> void Crop2D<float, CUDAContext>(vector<TIndex> idxs,
                                           const vector<TIndex>& offsets,
                                           const int cur_dim,
                                           Tensor* x,
                                           Tensor* y,
                                           CUDAContext* context) {
    TIndex inner_dim = 1;
    for (int i = 0; i < 2; i++) inner_dim *= y->dim(cur_dim + i);
    TIndex x_w_dim = x->dim(cur_dim + 1), y_w_dim = y->dim(cur_dim + 1);
    TIndex x_h_offset = offsets[cur_dim], x_w_offset = offsets[cur_dim + 1];

    auto* Xdata = x->data<float, CUDAContext>();
    auto* Ydata = y->mutable_data<float, CUDAContext>();
    Xdata += x->offset(idxs);
    Ydata += y->offset(idxs);

    _Crop2D<float> << <GET_BLOCKS(inner_dim), CUDA_NUM_THREADS >> >(inner_dim,
                                                                      x_w_dim,
                                                                      y_w_dim,
                                                                   x_h_offset,
                                                                   x_w_offset,
                                                                        Xdata,
                                                                       Ydata);
    CUDA_POST_KERNEL_CHECK;
}

template<typename T>
__global__ void _Crop2DGrad(const int count, 
                            const int x_w_dim, 
                            const int y_w_dim, 
                            const int x_h_offset,
                            const int x_w_offset,
                            const T* dy, 
                            T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int y_w = idx % y_w_dim;
        const int y_h = (idx / y_w_dim);
        dx[(y_h + x_h_offset) * x_w_dim + x_w_offset + y_w] = dy[idx];
    }
}

template<> void Crop2DGrad<float, CUDAContext>(vector<TIndex> idxs,
                                               const vector<TIndex>& offsets,
                                               const int cur_dim,
                                               Tensor* dy,
                                               Tensor* dx,
                                               CUDAContext* context) {
    TIndex inner_dim = 1;
    for (int i = 0; i < 2; i++) inner_dim *= dy->dim(cur_dim + i);
    TIndex x_w_dim = dx->dim(cur_dim + 1), y_w_dim = dy->dim(cur_dim + 1);
    TIndex x_h_offset = offsets[cur_dim], x_w_offset = offsets[cur_dim + 1];

    auto* dYdata = dy->data<float, CUDAContext>();
    auto* dXdata = dx->mutable_data<float, CUDAContext>();
    dYdata += dy->offset(idxs);
    dXdata += dx->offset(idxs);

    _Crop2DGrad<float> << <GET_BLOCKS(inner_dim), CUDA_NUM_THREADS >> >(inner_dim,
                                                                          x_w_dim,
                                                                          y_w_dim,
                                                                       x_h_offset,
                                                                       x_w_offset,
                                                                           dYdata,
                                                                          dXdata);
    CUDA_POST_KERNEL_CHECK;
}

/******************** common.reduce ********************/

template <typename T>
__global__ void _Sum(const int count, 
                     const int axis_dim,
                     const int inner_dim, 
                     const T* x, 
                     float* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        T sum_val = 0.0;
        for (int j = 0; j < axis_dim; j++)
            sum_val += x[(idx / inner_dim * axis_dim + j) 
                          * inner_dim + idx % inner_dim];
        y[idx] = sum_val;
   }
}

template<> void Sum<float, CUDAContext>(
        const int count, const int axis_dim,
        const int inner_dim, const float* x, float* y){
    _Sum<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                          axis_dim, 
                                                         inner_dim, 
                                                                 x, 
                                                                y);
     CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _SumGrad(const int count, 
                         const int axis_dim,
                         const int inner_dim, 
                         const T coeff, 
                         const T* dy, 
                         float* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        for (int j = 0; j < axis_dim; j++)
            dx[(idx / inner_dim * axis_dim + j) 
                    * inner_dim + idx % inner_dim] = dy[idx] * coeff;
    }
}

template<> void SumGrad<float, CUDAContext>(const int count, 
                                            const int axis_dim, 
                                            const int inner_dim, 
                                            const float coeff, 
                                            const float* dy, 
                                            float* dx) {
    _SumGrad<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                              axis_dim, 
                                                             inner_dim,
                                                                 coeff, 
                                                                    dy, 
                                                                   dx);
    CUDA_POST_KERNEL_CHECK;
}

/******************** common.slice ********************/

template <typename T>
    __global__ void _Slice(const int count, const int outer_dim, const int inner_dim,
        const int x_slice_dim, const int y_slice_dim, const int slice_offset, const T* x, T* y){
        CUDA_KERNEL_LOOP(idx, count) {
            const int tmp = y_slice_dim * inner_dim;
            const int outer_idx = idx / tmp;
            const int slice_idx = idx % tmp;
            const int x_idx = (outer_idx * x_slice_dim + slice_offset)
                * inner_dim + slice_idx;
            y[idx] = x[x_idx];
        }
}

template <> void Slice<float, CUDAContext>(const int count, 
                                           const int outer_dim, 
                                           const int inner_dim,
                                           const int x_slice_dim, 
                                           const int y_slice_dim, 
                                           const int slice_offset,
                                           const float* x, 
                                           float* y, 
                                           CUDAContext* context) {
    _Slice<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                           outer_dim, 
                                                           inner_dim, 
                                                         x_slice_dim, 
                                                         y_slice_dim, 
                                                        slice_offset, 
                                                                   x, 
                                                                  y);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _SliceGrad(const int count, 
                           const int outer_dim, 
                           const int inner_dim,
                           const int x_slice_dim, 
                           const int y_slice_dim, 
                           const int slice_offset, 
                           const T* dy, 
                           T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int tmp = y_slice_dim * inner_dim;
        const int outer_idx = idx / tmp;
        const int slice_idx = idx % tmp;
        const int x_idx = (outer_idx * x_slice_dim + slice_offset)
                                     * inner_dim + slice_idx;
        dx[x_idx] = dy[idx];
    }
}

template <> void SliceGrad<float, CUDAContext>(const int count, 
                                               const int outer_dim, 
                                               const int inner_dim,
                                               const int x_slice_dim, 
                                               const int y_slice_dim, 
                                               const int slice_offset,
                                               const float* dy, 
                                               float* dx, 
                                               CUDAContext* context) {
    _SliceGrad<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                               outer_dim, 
                                                               inner_dim, 
                                                             x_slice_dim, 
                                                             y_slice_dim,
                                                            slice_offset, 
                                                                      dy, 
                                                                     dx);
    CUDA_POST_KERNEL_CHECK;
}

/******************** common.tile ********************/

template <typename T>
__global__ void _Tile(const int count, 
                      const int inner_dim, 
                      const int multiple, 
                      const int dim, 
                      const T* x, 
                      T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int d = idx % inner_dim;
        const int b = (idx / inner_dim / multiple) % dim;
        const int n = idx / inner_dim / multiple / dim;
        const int x_idx = (n * dim + b) * inner_dim + d;
        y[idx] = x[x_idx];
    }
}

template <> void Tile<float, CUDAContext>(const int count, 
                                          const int outer_dim, 
                                          const int inner_dim,
                                          const int dim,
                                          const int multiple, 
                                          const float* x, 
                                          float* y, 
                                          CUDAContext* context) {
    _Tile<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                          inner_dim, 
                                                           multiple, 
                                                                dim, 
                                                                  x, 
                                                                 y);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _TileGrad(const int count, 
                          const int inner_dim,
                          const int multiple, 
                          const int dim, 
                          const T* dy, 
                          T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int d = idx % inner_dim;
        const int b = (idx / inner_dim) % dim;
        const int n = idx / inner_dim / dim;
        int y_idx = (n * multiple * dim + b) * inner_dim + d;
        dx[idx] = 0;
        for (int t = 0; t < multiple; t++) {
            dx[idx] += dy[y_idx];
            dy += dim * inner_dim;
        }
    }
}

template <> void TileGrad<float, CUDAContext>(const int count, 
                                              const int outer_dim, 
                                              const int inner_dim, 
                                              const int dim,
                                              const int multiple, 
                                              const float* dy, 
                                              float* dx, 
                                              CUDAContext* context) {
    _TileGrad<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                        inner_dim / dim, 
                                                               multiple, 
                                                                    dim, 
                                                                     dy, 
                                                                    dx);
    CUDA_POST_KERNEL_CHECK;
}

/******************** common.transpose ********************/

template <typename T>
__global__ void _Transpose(const int count, 
                           const int ndim, 
                           const int* order, 
                           const int* old_steps, 
                           const int* new_steps, 
                           const T* x, 
                           T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
       int x_idx = 0, y_idx = idx;
       for (int j = 0; j < ndim; ++j) {
           int k = order[j];
           x_idx += (y_idx / new_steps[j]) * old_steps[k];
           y_idx %= new_steps[j];
       }
       y[idx] = x[x_idx];
   }
}

template <> void Transpose<float, CUDAContext>(const int count, 
                                               const int ndim, 
                                               const int* order, 
                                               const int* old_steps,
                                               const int* new_steps, 
                                               const float* x, 
                                               float* y) {
    _Transpose<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                    ndim, 
                                                                   order, 
                                                               old_steps, 
                                                               new_steps, 
                                                                       x, 
                                                                      y);
    CUDA_POST_KERNEL_CHECK;
}

template <> void Transpose<float16, CUDAContext>(const int count, 
                                                 const int ndim, 
                                                 const int* order, 
                                                 const int* old_steps,
                                                 const int* new_steps, 
                                                 const float16* x, 
                                                 float16* y) {
    _Transpose<half> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                   ndim, 
                                                                  order, 
                                                              old_steps, 
                                                              new_steps, 
                                       reinterpret_cast<const half*>(x),
                                            reinterpret_cast<half*>(y));
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _TransposeGrad(const int count, 
                               const int ndim, 
                               const int* order,
                               const int* old_steps, 
                               const int* new_steps,
                               const T* dy, 
                               T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        int x_idx = 0, y_idx = idx;
        for (int j = 0; j < ndim; ++j) {
            int k = order[j];
            x_idx += (y_idx / new_steps[j]) * old_steps[k];
            y_idx %= new_steps[j];
        }
        dx[x_idx] = dy[idx];
    }
}

template <> void TransposeGrad<float, CUDAContext>(const int count, 
                                                   const int ndim,
                                                   const int* order, 
                                                   const int* old_steps,
                                                   const int* new_steps, 
                                                   const float* dy, 
                                                   float* dx) {
    _TransposeGrad<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                        ndim, 
                                                                       order, 
                                                                   old_steps, 
                                                                   new_steps, 
                                                                          dy, 
                                                                         dx);
    CUDA_POST_KERNEL_CHECK;
}

template <> void TransposeGrad<float16, CUDAContext>(const int count, 
                                                     const int ndim,
                                                     const int* order, 
                                                     const int* old_steps,
                                                     const int* new_steps, 
                                                     const float16* dy, 
                                                     float16* dx) {
    _TransposeGrad<half> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                       ndim, 
                                                                      order, 
                                                                  old_steps, 
                                                                  new_steps, 
                                          reinterpret_cast<const half*>(dy),
                                               reinterpret_cast<half*>(dx));
    CUDA_POST_KERNEL_CHECK;
}

/******************** common.utils ********************/

template <typename T>
__global__ void _OneHot(const int count,
                        const int depth, 
                        const int on_value, 
                        const float* x,
                        float* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int val = x[idx];
        y[idx * depth + val] = on_value;
    }
}


template <> void OneHot<float, CUDAContext>(const int count,
                                            const int depth,
                                            const int on_value,
                                            const float* x,
                                            float* y) {
    _OneHot<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count,
                                                                depth,
                                                             on_value,
                                                                    x,
                                                                   y);
    CUDA_POST_KERNEL_CHECK;
}

/******************** loss.l1_loss ********************/

template <typename T>
__global__ void _AbsGrad(const int count, const T* dy, T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
       const T val = dy[idx];
       //    val > 0: 1 | val == 0: 0 | val < 0: -1
       dx[idx] = (val > T(0)) - (val < T(0));
    }
}

template<> void AbsGrad<float, CUDAContext>(const int count, const float* dy, float* dx) {
    _AbsGrad<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, dy, dx);
    CUDA_POST_KERNEL_CHECK;
}

/******************** loss.sigmoid_cross_entropy_loss ********************/

template <typename T>
__global__ void _SigmoidCrossEntropy(const int count, 
                                     const T* x, 
                                     const T* targets,
                                     T* loss) {
    CUDA_KERNEL_LOOP(idx, count) {
        loss[idx] = std::log(1 + std::exp(x[idx] - 2 * x[idx] * (x[idx] >= 0))) 
                       + x[idx] * ((x[idx] >= 0) - targets[idx]);
    }
}

template <> void SigmoidCrossEntropy<float, CUDAContext>(const int count, 
                                                         const float* x, 
                                                         const float* targets, 
                                                         float* loss) {
    _SigmoidCrossEntropy<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                                 x, 
                                                                           targets, 
                                                                             loss);
     CUDA_POST_KERNEL_CHECK;
}

/******************** loss.smooth_l1_loss ********************/

template <typename T>
__global__ void _SmoothL1(const int count, const float sigma2, const T* x, T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        const T val = x[idx];
        const T abs_val = abs(val);
        if (abs_val < 1.0 / sigma2) y[idx] = 0.5 * val * val *sigma2;
        else y[idx] = abs_val - 0.5 / sigma2;
    }
}

template<> void SmoothL1<float, CUDAContext>(const int count, 
                                             const float sigma2, 
                                             const float* x, 
                                             float* y) {
    _SmoothL1<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, sigma2, x, y);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _SmoothL1Grad(const int count, const float sigma2, const T* dy, T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        const T val = dy[idx];
        const T abs_val = abs(val);
        if (abs_val < 1.0 / sigma2) dx[idx] = val * sigma2;
        //    val > 0: 1 | val == 0: 0 | val < 0: -1
        else dx[idx] = (val > T(0)) - (val < T(0));
    }
}

template<> void SmoothL1Grad<float, CUDAContext>(const int count, 
                                                 const float sigma2, 
                                                 const float* dy, 
                                                 float* dx) {
    _SmoothL1Grad<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, sigma2, dy, dx);
    CUDA_POST_KERNEL_CHECK;
}

/******************** loss.softmax_cross_entropy_loss ********************/

template <typename T>
__global__ void _SoftmaxCrossEntropy(const int count, 
                                     const T* prob, 
                                     const T* labels, 
                                     T* loss) {
    CUDA_KERNEL_LOOP(idx, count) {
        loss[idx] = - labels[idx] * log(max(prob[idx], FLT_MIN));
    }
}

template <> void SoftmaxCrossEntropy<float, CUDAContext>(const int count, 
                                                         const float* prob, 
                                                         const float* labels, 
                                                         float* loss) {
    _SoftmaxCrossEntropy<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                              prob, 
                                                                            labels, 
                                                                             loss);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _SoftmaxCrossEntropyGrad(const int count, 
                                         const T* prob, 
                                         const T* labels, 
                                         T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        dx[idx] = prob[idx] - (labels[idx] > 0);
    }
}

template <> void SoftmaxCrossEntropyGrad<float, CUDAContext>(const int count, 
                                                             const float* prob, 
                                                             const float* labels, 
                                                             float* dx) {
    _SoftmaxCrossEntropyGrad<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                                  prob, 
                                                                                labels, 
                                                                                   dx);
    CUDA_POST_KERNEL_CHECK;
}

/******************** loss.softmax_loss ********************/

template <typename T>
__global__ void _SparseSoftmaxCrossEntropy(const int count, 
                                           const T* prob, 
                                           const T* labels, 
                                           T* loss,
                                           const int classes, 
                                           const int inner_dim, 
                                           const int* ignores, 
                                           const int ignore_num, 
                                           T* valid) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int o_idx = idx / inner_dim;
        const int i_idx = idx % inner_dim;
        const int label = labels[o_idx * inner_dim + i_idx];
        int k;
        for (k = 0; k < ignore_num; k++) {
            if (label == ignores[k]) {
                loss[idx] = valid[idx] = 0;
                break;
            }
        }
        if (k == ignore_num) {
            loss[idx] = -log(max(prob[(o_idx * classes + label) * 
                                        inner_dim + i_idx], FLT_MIN));
            valid[idx] = 1;
        }
    }
}

template <> void SparseSoftmaxCrossEntropy<float, CUDAContext>(const int count, 
                                                               const int classes, 
                                                               const int outer_dim, 
                                                               const int inner_dim,
                                                               const float* prob, 
                                                               const float* labels, 
                                                               float* loss, 
                                                               float* valid, 
                                                               Tensor* ignore) {
    const int* ignores = ignore->count() > 0 ?
                         ignore->data<int, CUDAContext>() : 
                         nullptr;
    const int num_preds = outer_dim * inner_dim;
    _SparseSoftmaxCrossEntropy<float> << <GET_BLOCKS(num_preds), CUDA_NUM_THREADS >> >(num_preds, 
                                                                                            prob, 
                                                                                          labels, 
                                                                                            loss,
                                                                                         classes, 
                                                                                       inner_dim, 
                                                                                         ignores, 
                                                                                 ignore->count(), 
                                                                                          valid);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _SoftmaxLossGrad(const int count, 
                                 const T* prob, 
                                 const T* labels, 
                                 T* dx, 
                                 const int classes, 
                                 const int inner_dim, 
                                 const int* ignores, 
                                 const int ignore_num, 
                                 T* valid) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int o_idx = idx / inner_dim;
        const int i_idx = idx % inner_dim;
        const int label = labels[o_idx * inner_dim + i_idx];
        int k;
        for (k = 0; k < ignore_num; k++) 
                if (label == ignores[k]) break;
        if (k != ignore_num) {
                for (int c = 0; c < classes; c++)
                    dx[(o_idx * classes + c) * inner_dim + i_idx] = 0;
                valid[idx] = 0;
        } else {
                dx[(o_idx * classes + label) * inner_dim + i_idx] -= 1;
                valid[idx] = 1;
        }
    }
}

template<> void SoftmaxLossGrad<float, CUDAContext>(const int count, 
                                                    const int classes, 
                                                    const int outer_dim, 
                                                    const int inner_dim, 
                                                    const float* labels, 
                                                    const float* prob, 
                                                    float* valid, 
                                                    Tensor* ignore, 
                                                    float* dXdata) {
    const int* ignores = ignore->count() > 0 ? 
                         ignore->data <int, CUDAContext >() : 
                         nullptr;
    const int num_preds = outer_dim * inner_dim;
    _SoftmaxLossGrad<float> << <GET_BLOCKS(num_preds), CUDA_NUM_THREADS >> >(num_preds, 
                                                                                  prob, 
                                                                                labels, 
                                                                                dXdata,
                                                                               classes, 
                                                                             inner_dim, 
                                                                               ignores, 
                                                                       ignore->count(), 
                                                                                valid);
    CUDA_POST_KERNEL_CHECK;
}

/******************** recurrent.lstm_uint ********************/

template <typename T>
__global__ void _LSTMUnitAct(const int count, 
                             const int channels, 
                             const int g_offset,
                             const int x_offset, 
                             const T* x,
                             T* x_act) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int ch_4 = idx % x_offset;
        if (ch_4 < g_offset) x_act[idx] = _SigmoidUnit<float>(x[idx]);
        else x_act[idx] = std::tanh(x[idx]);
    }
}

template <typename T>
__global__ void _LSTMUnit(const int count, 
                          const int channels,
                          const int o_offset, 
                          const int g_offset, 
                          const int x_offset,
                          const T* c_1, 
                          T* x_act, 
                          const T* cont, 
                          T* c, 
                          T* h) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int n = idx / channels;
        const int ch = idx % channels;
        T* x_act_  = x_act + n * x_offset;
        const T i = x_act_[ch];
        if (cont != nullptr && cont[n] != T(1)) 
            x_act_[channels + ch] *= cont[n];
        const T f = x_act_[channels + ch];
        const T o = x_act_[o_offset + ch];
        const T g = x_act_[g_offset + ch];
        const T c_ = c[idx] = f * c_1[idx] + i * g;
        h[idx] = o * std::tanh(c_);
    }
}

template <> void LSTMUnit<float, CUDAContext>(const int count, 
                                              const int num, 
                                              const int channels,
                                              const float* c_1, 
                                              const float* x, 
                                              const float* cont,
                                              float* x_act, 
                                              float* c, 
                                              float* h) {
    const int o_offset = 2 * channels, g_offset = 3 * channels;
    const int x_offset = 4 * channels, y_count = count / 4;
    _LSTMUnitAct<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                  channels, 
                                                                  g_offset, 
                                                                  x_offset, 
                                                                         x, 
                                                                    x_act);
    _LSTMUnit<float> << <GET_BLOCKS(y_count), CUDA_NUM_THREADS >> >(y_count, 
                                                                   channels, 
                                                                   o_offset, 
                                                                   g_offset, 
                                                                   x_offset,
                                                                        c_1, 
                                                                      x_act, 
                                                                       cont, 
                                                                          c, 
                                                                         h);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _LSTMUnitGrad(const int count, 
                              const int channels,
                              const int o_offset, 
                              const int g_offset, 
                              const int x_offset,
                              const T* c_1, 
                              const T* x_act, 
                              const T* c, 
                              const T* dc, 
                              const T* dh, 
                              T* dc_1, 
                              T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int n = idx / channels;
        const int ch = idx % channels;
        const T* x_act_ = x_act + n * x_offset;
        T* dx_ = dx + n * x_offset;
        const T i = x_act_[ch];
        const T f = x_act_[channels + ch];
        const T o = x_act_[o_offset + ch];
        const T g = x_act_[g_offset + ch];
        T* p_di = dx_ + ch;
        T* p_df = dx_ + channels + ch;
        T* p_do = dx_ + o_offset + ch;
        T* p_dg = dx_ + g_offset + ch;
        const T tanh_c_t = tanh(c[idx]);
        const T dc_1_sum_term = dh[idx] * o * (1 - tanh_c_t * tanh_c_t) + dc[idx];
        dc_1[idx] = dc_1_sum_term * f;
        *p_di = dc_1_sum_term * g;
        *p_df = dc_1_sum_term * c_1[idx];
        *p_do = dh[idx] * tanh_c_t;
        *p_dg = dc_1_sum_term * i;
    }
}

template <typename T>
__global__ void _LSTMUnitGradAct(const int count, 
                                 const int channels, 
                                 const int g_offset,
                                 const int x_offset, 
                                 const T* x_act, 
                                 T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int ch_4 = idx % x_offset;
        const T x_act_ = x_act[idx];
        if (ch_4 < g_offset) dx[idx] = dx[idx] * x_act_ * (T(1) - x_act_);
        else  dx[idx] = dx[idx] * (T(1) - x_act_ * x_act_);
    }
}

template <> void LSTMUnitGrad<float, CUDAContext>(const int count, 
                                                  const int num, 
                                                  const int channels,
                                                  const float* c_1, 
                                                  const float* x_act,
                                                  const float* c, 
                                                  const float* dc, 
                                                  const float* dh,
                                                  float* dc_1, 
                                                  float* dx) {
    const int o_offset = 2 * channels, g_offset = 3 * channels;
    const int x_offset = 4 * channels, y_count = count / 4;
    _LSTMUnitGrad<float> << <GET_BLOCKS(y_count), CUDA_NUM_THREADS >> >(y_count, 
                                                                       channels, 
                                                                       o_offset, 
                                                                       g_offset, 
                                                                       x_offset,
                                                                            c_1, 
                                                                          x_act, 
                                                                              c, 
                                                                             dc, 
                                                                             dh, 
                                                                           dc_1, 
                                                                            dx);
    _LSTMUnitGradAct<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                      channels, 
                                                                      g_offset,
                                                                      x_offset, 
                                                                         x_act, 
                                                                           dx);
    CUDA_POST_KERNEL_CHECK;
}

/******************** update.adam_update ********************/

template <typename T>
__global__ void _AdamUpdate(const int n, 
                            T* g, 
                            T* m, 
                            T* v,
                            const T beta1, 
                            const T beta2, 
                            const T eps, 
                            const T lr) {
    CUDA_KERNEL_LOOP(i, n) {
        T gi = g[i];
        T mi = m[i] = m[i] * beta1 + gi * (1 - beta1);
        T vi = v[i] = v[i] * beta2 + gi * gi * (1 - beta2);
        g[i] = lr * mi / (sqrt(vi) + eps);
    }
}

template <> void AdamUpdate<float, CUDAContext>(Tensor* x, 
                                                Tensor* m, 
                                                Tensor* v, 
                                                Tensor* t,
                                                const float beta1, 
                                                const float beta2, 
                                                const float eps, 
                                                const float lr) {
    TIndex count = x->count();
    auto* Xdata = x->mutable_data<float, CUDAContext>();
    auto* Mdata = m->mutable_data<float, CUDAContext>();
    auto* Vdata = v->mutable_data<float, CUDAContext>();
    _AdamUpdate<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                    Xdata, 
                                                                    Mdata, 
                                                                    Vdata, 
                                                                    beta1, 
                                                                    beta2, 
                                                                      eps, 
                                                                      lr);
    CUDA_POST_KERNEL_CHECK;
}

/******************** update.nesterov_update ********************/

template <typename T>
__global__ void _NesterovUpdate(const int n, 
                               T* g, 
                               T* h,
                               const T momentum,
                               const T lr) {
    CUDA_KERNEL_LOOP(i, n) {
        T hi = h[i];
        T hi_new = h[i] = momentum * hi + lr * g[i];
        g[i] = (1 + momentum) * hi_new - momentum * hi;
    }
}
template <> void NesterovUpdate<float, CUDAContext>(const int count,
                                                    float* x,
                                                    float* h,
                                                    Tensor* t,
                                                    const float momentum,
                                                    const float lr,
                                                    CUDAContext* ctx) {
    _NesterovUpdate<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count,
                                                                            x, 
                                                                            h, 
                                                                     momentum,
                                                                          lr);
    CUDA_POST_KERNEL_CHECK;
}

/******************** update.rmsprop_update ********************/

template <typename T>
__global__ void _RMSPropUpdate(const int n, 
                               T* g, 
                               T* h,
                               const T decay, 
                               const T eps, 
                               const T lr) {
    CUDA_KERNEL_LOOP(i, n) {
        T gi = g[i];
        T hi = h[i] = decay * h[i] + (1 - decay) * gi * gi;
        g[i] = lr * g[i] / (sqrt(hi) + eps);
    }
}

template <> void RMSPropUpdate<float, CUDAContext>(const int count,
                                                   float* x, 
                                                   float* h,
                                                   Tensor* t,
                                                   const float decay, 
                                                   const float eps, 
                                                   const float lr) {
    _RMSPropUpdate<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                           x, 
                                                                           h, 
                                                                       decay, 
                                                                         eps, 
                                                                         lr);
    CUDA_POST_KERNEL_CHECK;
}

/******************** utils.cast ********************/

template <typename T>
__global__ void _FloatToHalfKernel(const int count, const float* x, half* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        y[idx] = __float2half(x[idx]);
    }
}

template <> void Float2Half<float, CUDAContext>(const int count, 
                                                const float* x, 
                                                float16* y) {
    _FloatToHalfKernel<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                               x, 
                                                     reinterpret_cast<half*>(y));
     CUDA_POST_KERNEL_CHECK;
}

/******************** utils.compare ********************/

template <typename T>
__global__ void _Equal(const int count, const T* a, const T* b, T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        y[idx] = fabs(a[idx] - b[idx]) < FLT_EPSILON ? 1.0 : 0.0;
    }
}

template <> void Equal<float, CUDAContext>(const int count, 
                                           const float* a,
                                           const float* b, 
                                           float* y) {
    _Equal<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, a, b, y);
     CUDA_POST_KERNEL_CHECK;
}

/******************** utils.memory_data ********************/

template <typename Tx, typename Ty>
__global__ void _MemoryData(const int count, 
                            const int num, 
                            const int channels, 
                            const int height, 
                            const int width, 
                            const Tx* x, 
                            Ty* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int w = idx % width;
        const int h = (idx / width) % height;
        const int c = (idx / width / height) % channels;
        const int n = idx / width / height / channels;
        const int x_idx = ((n * height + h) * width + w) * channels + c;
        if (c == 0) y[idx] = x[x_idx] - 102.9801;
        else if (c == 1) y[idx] = x[x_idx] - 115.9465;
        else y[idx] = x[x_idx] - 122.7717;
    }
}

template <typename Tx, typename Ty>
__global__ void _MemoryDataHalf(const int count, 
                                const int num, 
                                const int channels, 
                                const int height, 
                                const int width, 
                                const Tx* x, 
                                Ty* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int w = idx % width;
        const int h = (idx / width) % height;
        const int c = (idx / width / height) % channels;
        const int n = idx / width / height / channels;
        const int x_idx = ((n * height + h) * width + w) * channels + c;
        if (c == 0) y[idx] = __float2half(x[x_idx] - 102.9801);
        else if (c == 1) y[idx] = __float2half(x[x_idx] - 115.9465);
        else y[idx] = __float2half(x[x_idx] - 122.7717);
    }
}

template <> void MemoryData<float, float, CUDAContext>(const int count, 
                                                       const int num, 
                                                       const int channels, 
                                                       const int height, 
                                                       const int width, 
                                                       const float* x, 
                                                       float* y) {
    _MemoryData<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                      num, 
                                                                 channels, 
                                                                   height, 
                                                                    width, 
                                                                        x, 
                                                                       y);
    CUDA_POST_KERNEL_CHECK;
}

template <> void MemoryData<uint8_t, float, CUDAContext>(const int count, 
                                                       const int num, 
                                                       const int channels, 
                                                       const int height, 
                                                       const int width, 
                                                       const uint8_t* x, 
                                                       float* y) {
    _MemoryData<uint8_t, float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                               num, 
                                                                          channels, 
                                                                            height, 
                                                                             width, 
                                                                                 x, 
                                                                                y);
    CUDA_POST_KERNEL_CHECK;
}

template <> void MemoryData<float, float16, CUDAContext>(const int count, 
                                                         const int num, 
                                                         const int channels, 
                                                         const int height, 
                                                         const int width, 
                                                         const float* x, 
                                                         float16* y) {
    _MemoryDataHalf<float, half> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                                num, 
                                                                           channels, 
                                                                             height, 
                                                                              width, 
                                                                                  x, 
                                                        reinterpret_cast<half*>(y));
    CUDA_POST_KERNEL_CHECK;
}

template <> void MemoryData<uint8_t, float16, CUDAContext>(const int count, 
                                                           const int num, 
                                                           const int channels, 
                                                           const int height, 
                                                           const int width, 
                                                           const uint8_t* x, 
                                                           float16* y) {
    _MemoryDataHalf<uint8_t, half> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                                  num, 
                                                                             channels, 
                                                                               height, 
                                                                                width, 
                                                                                    x, 
                                                          reinterpret_cast<half*>(y));
    CUDA_POST_KERNEL_CHECK;
}

/******************** vision.conv ********************/

template<typename T>
__global__ void _Im2Col(const int count, 
                        const int height, const int width,
                        const int kernel_h, const int kernel_w, 
                        const int stride_h, const int stride_w, 
                        const int pad_h, const int pad_w,
                        const int dilation_h, const int dilation_w,
                        const int col_h, const int col_w, 
                        const T* im,
                        T* col) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int h_idx = idx / col_w;
        const int im_c = h_idx / col_h;
        const int h = h_idx % col_h;
        const int w = idx % col_w;
        const int c = im_c * kernel_h * kernel_w;
        const int im_h_off = h * stride_h - pad_h;
        const int im_w_off = w * stride_w - pad_w;

        //  compute the first col pos of a roll convolution
        T* col_ptr = col;
        col_ptr += ((c * col_h + h) * col_w + w);

        //  compute the first im pos of a roll convolution
        const T* im_ptr = im;
        im_ptr += ((im_c * height + im_h_off) * width + im_w_off);

        for (int i = 0; i < kernel_h; ++i) {
            for (int j = 0; j < kernel_w; ++j) {
                //  compute the current im pos
                int im_h = i * dilation_h + im_h_off;
                int im_w = j * dilation_w + im_w_off;
                *col_ptr = (im_h >= 0 && im_w >= 0 && im_h < height && im_w < width) ?
                           im_ptr[i * dilation_h * width + j * dilation_w] : 0;
                col_ptr += (col_h * col_w);
            }
        }
    }
}

template <> void Im2Col<float, CUDAContext>(const int channels, 
                                            const int height, const int width,
                                            const int kernel_h, const int kernel_w, 
                                            const int stride_h, const int stride_w, 
                                            const int pad_h, const int pad_w,
                                            const int dilation_h, const int dilation_w, 
                                            const float* im,
                                            float* col) {
    const int col_h = (height + 2 * pad_h - (dilation_h * (kernel_h - 1) + 1)) / stride_h + 1;
    const int col_w = (width + 2 * pad_w - (dilation_w * (kernel_w - 1) + 1)) / stride_w + 1;
    const int count = (channels * col_h * col_w);
    _Im2Col<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                        height, width, 
                                                   kernel_h, kernel_w, 
                                                   stride_h, stride_w, 
                                                         pad_h, pad_w,
                                               dilation_h, dilation_w, 
                                                         col_h, col_w, 
                                                                   im,
                                                                 col);
    CUDA_POST_KERNEL_CHECK;
}

template<typename T>
__global__ void _Col2Im(const int count, 
                        const int height, const int width,
                        const int kernel_h, const int kernel_w, 
                        const int stride_h, const int stride_w, 
                        const int pad_h, const int pad_w,
                        const int dilation_h, const int dilation_w,
                        const int col_h, const int col_w, 
                        const T* col,
                        T* im) {
    CUDA_KERNEL_LOOP(idx, count) {
        T val = 0;
        const int im_w = idx % width + pad_w;
        const int im_h = (idx / width) % height + pad_h;
        const int im_c = idx / (width * height);
        const int ex_kernel_h = (kernel_h - 1) * dilation_h + 1;
        const int ex_kernel_w = (kernel_w - 1) * dilation_w + 1;
        const int w_start = (im_w < ex_kernel_w) ? 0 : (im_w - ex_kernel_w) / stride_w + 1;

        //    redundant pixels will be ignored when conv
        //    note to clip them by min(x,col_w)
        const int w_end = min(im_w / stride_w + 1, col_w);
        const int h_start = (im_h < ex_kernel_h) ? 0 : (im_h - ex_kernel_h) / stride_h + 1;
        const int h_end = min(im_h / stride_h + 1, col_h);

        for (int h = h_start; h < h_end; ++h) {
            for (int w = w_start; w < w_end; ++w) {
                int kh_off = (im_h - h * stride_h);
                int kw_off = (im_w - w * stride_w);
                //    only the serval im pixels used in dilated-conv
                //    ignore the corresponding col pixels
                if (kh_off % dilation_h == 0 && kw_off % dilation_w == 0) {
                    kh_off /= dilation_h;
                    kw_off /= dilation_w;
                    int c = (im_c * kernel_h + kh_off) * kernel_w + kw_off;
                    val += col[(c * col_h + h) * col_w + w];
                }
            }
        }
        im[idx] = val;
    }
}

template <> void Col2Im<float, CUDAContext>(const int channels, 
                                            const int height, const int width,
                                            const int kernel_h, const int kernel_w, 
                                            const int stride_h, const int stride_w, 
                                            const int pad_h, const int pad_w,
                                            const int dilation_h, const int dilation_w, 
                                            const float* col,
                                            float* im) {
    const int col_h = (height + 2 * pad_h - (dilation_h * (kernel_h - 1) + 1)) / stride_h + 1;
    const int col_w = (width + 2 * pad_w - (dilation_w * (kernel_w - 1) + 1)) / stride_w + 1;
    const int count = (channels * height * width);
    _Col2Im<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                        height, width, 
                                                   kernel_h, kernel_w, 
                                                   stride_h, stride_w,
                                                         pad_h, pad_w,
                                               dilation_h, dilation_w, 
                                                         col_h, col_w,
                                                                  col,
                                                                  im);
    CUDA_POST_KERNEL_CHECK;
}

/******************** vision.nn_resize ********************/

template <typename T>
__global__ void _NNResize(const int count, 
                          const float h_scale, 
                          const float w_scale,
                          const int num, const int channels, 
                          const int h_in, const int w_in, 
                          const int h_out, const int w_out, 
                          const T* x, 
                          T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int w = idx % w_out;
        const int h = (idx / w_out) % h_out;
        const int in_h = min(int(floorf(h * h_scale)), h_in - 1);
        const int in_w = min(int(floorf(w * w_scale)), w_in - 1);
        const int c = (idx / w_out / h_out) % channels;
        const int n = idx / w_out / h_out / channels;
        const int x_idx = ((n * channels + c) * h_in + in_h) * w_in + in_w;
        y[idx] = x[x_idx];
    }
}

template <> void NNResize<float, CUDAContext>(const int count, 
                                              const int num, const int channels,
                                              const int h_in, const int w_in, 
                                              const int h_out, const int w_out,
                                              const float* x, float* y) {
    const float h_scale = (float)h_in / h_out;
    const float w_scale = (float)w_in / w_out;
    _NNResize<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                h_scale, 
                                                                w_scale, 
                                                          num, channels, 
                                                             h_in, w_in, 
                                                           h_out, w_out, 
                                                                      x, 
                                                                     y);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
 __global__ void _NNResizeGrad(const int count, 
                               const float h_scale, const float w_scale,
                               const int num, const int channels, 
                               const int h_in, const int w_in,
                               const int h_out, const int w_out, 
                               const T* dy, 
                               T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int w = idx % w_in;
        const int h = (idx / w_in) % h_in;
        const int out_h = min(int(floorf(h * h_scale)), h_out - 1);
        const int out_w = min(int(floorf(w * w_scale)), w_out - 1);
        const int c = (idx / w_in / h_in) % channels;
        const int n = idx / w_in / h_in / channels;
        const int x_idx = ((n * channels + c) * h_out + out_h) * w_out + out_w;
        atomicAdd(dx + x_idx, dy[idx]);
    }
}

template <> void NNResizeGrad<float, CUDAContext>(const int count,
                                                  const int num, 
                                                  const int channels,
                                                  const int h_in, const int w_in, 
                                                  const int h_out, const int w_out,
                                                  const float* dy, float* dx) {
    const float h_scale = (float)h_out / h_in;
    const float w_scale = (float)w_out / w_in;
    _NNResizeGrad<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                    h_scale, 
                                                                    w_scale, 
                                                              num, channels, 
                                                                 h_in, w_in, 
                                                               h_out, w_out, 
                                                                         dy, 
                                                                        dx);
    CUDA_POST_KERNEL_CHECK;
}

/******************** vision.pooling ********************/

template<typename T>
__global__ void _MAXPooling(const int count, 
                            const int num, const int channels,
                            const int height, const int width, 
                            const int pool_height, const int pool_width,
                            const int kernel_h, const int kernel_w, 
                            const int stride_h, const int stride_w, 
                            const int pad_h, const int pad_w, 
                            const T* x,
                            int* mask,
                            T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int pw = idx % pool_width;
        const int ph = (idx / pool_width) % pool_height;
        const int pc = (idx / pool_width / pool_height) % channels;
        const int pn = (idx / pool_width / pool_height / channels);

        int start_h = ph * stride_h - pad_h;
        int start_w = pw * stride_w - pad_w;
        const int end_h = min(start_h + kernel_h, height);
        const int end_w = min(start_w + kernel_w, width);

        start_h = max(start_h, 0);
        start_w = max(start_w, 0);

        T max_val = -FLT_MAX;
        int max_idx = -1;
        const T* x_ptr = x + (pn * channels + pc) * height * width;

        for (int h = start_h; h < end_h; ++h) {
            for (int w = start_w; w < end_w; ++w) {
                if (x_ptr[h * width + w] > max_val) {
                    max_idx = h * width + w;
                    max_val = x_ptr[max_idx];
                }
            }
        }
        y[idx] = max_val;
        mask[idx] = max_idx;
    }
}

template<> void MAXPooling<float, CUDAContext>(const int count, 
                                               const int num, const int channels,
                                               const int height, const int width, 
                                               const int pool_height, const int pool_width,
                                               const int kernel_h, const int kernel_w, 
                                               const int stride_h, const int stride_w, 
                                               const int pad_h, const int pad_w,
                                               const float* x, 
                                               int* mask, 
                                               float* y) {
    _MAXPooling<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                             num, channels, height, width, 
                                                  pool_height, pool_width, 
                                                       kernel_h, kernel_w, 
                                                       stride_h, stride_w, 
                                                             pad_h, pad_w, 
                                                                        x,
                                                                     mask,
                                                                       y); 

    CUDA_POST_KERNEL_CHECK;
}

template<typename T>
__global__ void _AVEPooling(const int count, 
                            const int num, const int channels,
                            const int height, const int width, 
                            const int pool_height, const int pool_width,
                            const int kernel_h, const int kernel_w, 
                            const int stride_h, const int stride_w, 
                            const int pad_h, const int pad_w, 
                            const T* x,
                            T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int pw = idx % pool_width;
        const int ph = (idx / pool_width) % pool_height;
        const int pc = (idx / pool_width / pool_height) % channels;
        const int pn = (idx / pool_width / pool_height / channels);

        int start_h = ph * stride_h - pad_h;
        int start_w = pw * stride_w - pad_w;
        int end_h = min(start_h + kernel_h, height + pad_h);
        int end_w = min(start_w + kernel_w, width + pad_w);

        start_h = max(start_h, 0);
        start_w = max(start_w, 0);
        end_h = min(end_h, height);
        end_w = min(end_w, width);

        const T* x_ptr = x + (pn * channels + pc) * height * width;
        const int pooling_size = (end_h - start_h) * (end_w - start_w);
        T avg_val = 0;

        for (int h = start_h; h < end_h; ++h) {
            for (int w = start_w; w < end_w; ++w) {
                avg_val += x_ptr[h * width + w];
            }
        }
        y[idx] = avg_val / pooling_size;
    }
}

template<> void AVEPooling<float, CUDAContext>(const int count, 
                                               const int num, const int channels,
                                               const int height, const int width, 
                                               const int pool_height, const int pool_width,
                                               const int kernel_h, const int kernel_w, 
                                               const int stride_h, const int stride_w, 
                                               const int pad_h, const int pad_w,
                                               const float* x, 
                                               float* y) {
    _AVEPooling<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                             num, channels, height, width, 
                                                  pool_height, pool_width,
                                                       kernel_h, kernel_w, 
                                                       stride_h, stride_w, 
                                                             pad_h, pad_w, 
                                                                        x,
                                                                       y);
    CUDA_POST_KERNEL_CHECK; 
}

template<typename T>
__global__ void _MAXPoolingGrad(const int count, 
                                const int num, const int channels,
                                const int height, const int width, 
                                const int pool_height, const int pool_width,
                                const int kernel_h, const int kernel_w, 
                                const int stride_h, const int stride_w,
                                const int pad_h, const int pad_w, 
                                const T* dy,
                                const int* mask,
                                T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int w = idx % width;
        const int h = (idx / width) % height;
        const int c = (idx / width / height) % channels;
        const int n = idx / width / height / channels;

        //    allow overlapping
        const int start_ph = (h + pad_h < kernel_h) ? 0 : (h + pad_h - kernel_h) / stride_h + 1;
        const int start_pw = (w + pad_w < kernel_w) ? 0 : (w + pad_w - kernel_w) / stride_w + 1;

        //    allow clip
        const int end_ph = min((h + pad_h) / stride_h + 1, pool_height);
        const int end_pw = min((w + pad_w) / stride_w + 1, pool_width);

        T diff = 0;
        const int offset = (n * channels + c) * pool_height * pool_width;
        const T* y_ptr = dy + offset;
        const int* mask_ptr = mask + offset;

        for (int ph = start_ph; ph < end_ph; ++ph) {
            for (int pw = start_pw; pw < end_pw; ++pw) {
                if (mask_ptr[ph * pool_width + pw] == (h * width + w)) {
                    diff += y_ptr[ph * pool_width + pw];
                }
            }
        }
        dx[idx] = diff;
    }
}

template<> void MAXPoolingGrad<float, CUDAContext>(const int count, 
                                                   const int num, const int channels,
                                                   const int height, const int width, 
                                                   const int pool_height, const int pool_width,
                                                   const int kernel_h, const int kernel_w, 
                                                   const int stride_h, const int stride_w, 
                                                   const int pad_h, const int pad_w,
                                                   const float* dy, 
                                                   const int* mask, 
                                                   float* dx) {
    _MAXPoolingGrad<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                 num, channels, height, width, 
                                                      pool_height, pool_width,
                                                           kernel_h, kernel_w, 
                                                           stride_h, stride_w, 
                                                                 pad_h, pad_w, 
                                                                           dy,
                                                                         mask,
                                                                          dx);
    CUDA_POST_KERNEL_CHECK;
}

template<typename T>
__global__ void _AVEPoolingGrad(const int count, 
                                const int num, const int channels,
                                const int height, const int width, 
                                const int pool_height, const int pool_width,
                                const int kernel_h, const int kernel_w, 
                                const int stride_h, const int stride_w,
                                const int pad_h, const int pad_w, 
                                const T* dy,
                                T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        const int w = idx % width;
        const int h = (idx / width) % height;
        const int c = (idx / width / height) % channels;
        const int n = idx / width / height / channels;

        const int start_ph = (h + pad_h < kernel_h) ? 0 : (h + pad_h - kernel_h) / stride_h + 1;
        const int start_pw = (w + pad_w<kernel_w) ? 0 : (w + pad_w - kernel_w) / stride_w + 1;
        const int end_ph = min(h / stride_h + 1, pool_height);
        const int end_pw = min(w / stride_w + 1, pool_width);

        T diff = 0;
        const T* y_ptr = dy + (n * channels + c) * pool_height * pool_width;

        for (int ph = start_ph; ph < end_ph; ++ph) {
            for (int pw = start_pw; pw < end_pw; ++pw) {
                int start_h = ph * stride_h - pad_h;
                int start_w = pw * stride_w - pad_w;
                int end_h = min(start_h + kernel_h, height + pad_h);
                int end_w = min(start_w + kernel_w, width + pad_w);
                int pooling_size = (end_h - start_h) * (end_w - start_w);
                diff += (y_ptr[ph * pool_width + pw] / pooling_size);
            }
        }
        dx[idx] = diff;
    }
}

template<> void AVEPoolingGrad<float, CUDAContext>(const int count, 
                                                   const int num, const int channels,
                                                   const int height, const int width, 
                                                   const int pool_height, const int pool_width,
                                                   const int kernel_h, const int kernel_w, 
                                                   const int stride_h, const int stride_w, 
                                                   const int pad_h, const int pad_w,
                                                   const float* dy,
                                                   float* dx) {
    _AVEPoolingGrad<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                 num, channels, height, width, 
                                                      pool_height, pool_width,
                                                           kernel_h, kernel_w, 
                                                           stride_h, stride_w, 
                                                                 pad_h, pad_w, 
                                                                           dy,
                                                                          dx);
    CUDA_POST_KERNEL_CHECK;
}


/******************** vision.roi_pooling ********************/

template <typename T>
__global__ void _ROIPooling(const int count, 
                            const T spatial_scale, 
                            const int channels, 
                            const int height, const int width,
                            const int pool_h, const int pool_w, 
                            const T* x,
                            const T* roi,
                            int* mask,
                            T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        int pw = idx % pool_w;
        int ph = (idx / pool_w) % pool_h;
        int c = (idx / pool_w / pool_h) % channels;
        int n = idx / pool_w / pool_h / channels;

        roi += n * 5;
        int im_idx = roi[0];

        int x1 = round(roi[1] * spatial_scale);
        int y1 = round(roi[2] * spatial_scale);
        int x2 = round(roi[3] * spatial_scale);
        int y2 = round(roi[4] * spatial_scale);

        int roi_height = max(y2 - y1 + 1, 1);
        int roi_width = max(x2 - x1 + 1, 1);

        const float bin_size_h = (float)roi_height / (float)pool_h;
        const float bin_size_w = (float)roi_width / (float)pool_w;

        int start_h = floor(bin_size_h * ph);
        int start_w = floor(bin_size_w * pw);
        int end_h = ceil(bin_size_h * (ph + 1));
        int end_w = ceil(bin_size_w * (pw + 1));

        start_h = min(max(start_h + y1, 0), height);
        start_w = min(max(start_w + x1, 0), width);
        end_h = min(max(end_h + y1, 0), height);
        end_w = min(max(end_w + x1, 0), width);

        bool is_empty = (end_h <= start_h) || (end_w <= start_w);
        float max_val = is_empty ? 0 : -FLT_MAX;
        int max_idx = -1;
        x += ((im_idx * channels + c) * height * width);

        for (int h = start_h; h < end_h; ++h) {
            for (int w = start_w; w < end_w; ++w) {
                const int x_idx = h * width + w;
                if (x[x_idx] > max_val) {
                    max_val = x[x_idx];
                    max_idx = x_idx;
                }
            }    //end w
        }    // end h

        y[idx] = max_val;
        mask[idx] = max_idx;
    }
}

template<> void ROIPooling<float, CUDAContext>(const float spatial_scale, 
                                               const int pool_h, const int pool_w,
                                               Tensor* x,
                                               Tensor* roi,
                                               Tensor* mask,
                                               Tensor* y) {
    auto* Xdata = x->data<float, CUDAContext>();
    auto* Rdata = roi->data<float, CUDAContext>();
    auto* Ydata = y->mutable_data<float, CUDAContext>();
    auto* Mdata = mask->mutable_data<int, CUDAContext>();
    TIndex channels = x->dim(1), count = y->count();
    TIndex height = x->dim(2), width = x->dim(3);
    _ROIPooling<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                            spatial_scale, 
                                                                 channels, 
                                                            height, width,
                                                           pool_h, pool_w,
                                                                    Xdata,
                                                                    Rdata,
                                                                    Mdata,
                                                                   Ydata);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _ROIPoolingGrad(const int count, 
                                const int num_rois, 
                                const T spatial_scale, 
                                const int channels, 
                                const int height, const int width,
                                const int pool_h, const int pool_w, 
                                const T* dy,
                                const T* roi,
                                const int* mask,
                                T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        int w = idx % width;
        int h = (idx / width) % height;
        int c = (idx / width / height) % channels;
        int im_idx = idx / width / height / channels;

        T diff = 0;

        for (int n = 0; n < num_rois; ++n) {
            const T* cur_roi = roi + n * 5;
            const int im_idx_spec = cur_roi[0];

            //    ignore wrong im_batch_idx
            if (im_idx != im_idx_spec) continue;

            int x1 = round(cur_roi[1] * spatial_scale);
            int y1 = round(cur_roi[2] * spatial_scale);
            int x2 = round(cur_roi[3] * spatial_scale);
            int y2 = round(cur_roi[4] * spatial_scale);

            const bool is_in = (w >= x1 && w <= x2 && h >= y1 && h <= y2);

            if (!is_in) continue;

            int roi_height = max(y2 - y1 + 1, 1);
            int roi_width = max(x2 - x1 + 1, 1);

            const float bin_size_h = (float)roi_height / (float)pool_h;
            const float bin_size_w = (float)roi_width / (float)pool_w;

            int start_ph = floor((h - y1) / bin_size_h);
            int start_pw = floor((w - x1) / bin_size_w);
            int end_ph = ceil((h + 1 - y1) / bin_size_h);
            int end_pw = ceil((w + 1 - x1) / bin_size_w);

            start_ph = min(max(start_ph, 0), pool_h);
            start_pw = min(max(start_pw, 0), pool_w);
            end_ph = min(max(end_ph, 0), pool_h);
            end_pw = min(max(end_pw, 0), pool_w);

            int y_offset = (n * channels + c) * pool_h * pool_w;
            const T* dy_off = dy + y_offset;
            const int* mask_off = mask + y_offset;

            for (int ph = start_ph; ph < end_ph; ++ph) {
                for (int pw = start_pw; pw < end_pw; ++pw) {
                    int pool_idx = ph * pool_w + pw;
                    if (mask_off[pool_idx] == (h * width + w)) {
                        diff += dy_off[pool_idx];
                    }
                }    //    end pw
            }    // end ph
        }    //    end n
        dx[idx] = diff;
    }
}

template<> void ROIPoolingGrad<float, CUDAContext>(const float spatial_scale, 
                                                   const int pool_h, const int pool_w,
                                                   Tensor* dy,
                                                   Tensor* roi,
                                                   Tensor* mask,
                                                   Tensor* dx) {
    auto* dYdata = dy->data<float, CUDAContext>();
    auto* Rdata = roi->data<float, CUDAContext>();
    auto* Mdata = mask->data<int, CUDAContext>();
    auto* dXdata = dx->mutable_data<float, CUDAContext>();
    TIndex channels = dx->dim(1), count = dx->count();
    TIndex height = dx->dim(2), width = dx->dim(3);
    _ROIPoolingGrad<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                  roi->dim(0), 
                                                                spatial_scale, 
                                                                     channels, 
                                                                height, width,
                                                               pool_h, pool_w,
                                                                       dYdata,
                                                                        Rdata,
                                                                        Mdata,
                                                                      dXdata);
    CUDA_POST_KERNEL_CHECK;
}

/******************** vision.roi_align ********************/

template <typename T>
__global__ void _ROIAlign(const int count, 
                          const float spatial_scale, 
                          const int channels, 
                          const int height, const int width,
                          const int pool_h, const int pool_w, 
                          const T* x,
                          const T* roi,
                          T* mask_h,
                          T* mask_w,
                          T* y) {
    CUDA_KERNEL_LOOP(idx, count) {
        int pw = idx % pool_w;
        int ph = (idx / pool_w) % pool_h;
        int c = (idx / pool_w / pool_h) % channels;
        int n = idx / pool_w / pool_h / channels;

        roi += n * 5;
        int im_idx = roi[0];

        T x1 = roi[1] * spatial_scale;
        T y1 = roi[2] * spatial_scale;
        T x2 = roi[3] * spatial_scale;
        T y2 = roi[4] * spatial_scale;

        T roi_height = max(y2 - y1, T(1));
        T roi_width = max(x2 - x1, T(1));

        const T bin_size_h = roi_height / pool_h;
        const T bin_size_w = roi_width / pool_w;

        T start_h = bin_size_h * ph;
        T start_w = bin_size_w * pw;
        T end_h = bin_size_h * (ph + 1);
        T end_w = bin_size_w * (pw + 1);

        start_h = max(start_h + y1, T(0));
        start_w = max(start_w + x1, T(0));
        end_h = max(end_h + y1, T(0));
        end_w = max(end_w + x1, T(0));

        start_h = min(start_h, T(height));
        start_w = min(start_w, T(width));
        end_h = min(end_h, T(height));
        end_w = min(end_w, T(width));

        bool is_empty = (end_h <= start_h) || (end_w <= start_w);
        T max_val = is_empty ? 0 : -FLT_MAX;
        T max_h = -1, max_w = -1;
        x += ((im_idx * channels + c) * height * width);

        for (T h = start_h; h < end_h; ++h) {
            for (T w = start_w; w < end_w; ++w) {
                if (int(ceil(h)) == height) h = height - 1;
                if (int(ceil(w)) == width) w = width - 1;

                int h1 = h, h2 = int(ceil(h));
                int w1 = int(w), w2 = int(ceil(w));

                T q11 = x[h1 * width + w1];
                T q21 = x[h2 * width + w1];
                T q12 = x[h1 * width + w2];
                T q22 = x[h2 * width + w2];

                T val;

                if (h1 == h2) {
                    if (w1 == w2) val = q11;
                    else val = q11 * (w2 - w) + q12 * (w - w1);
                } else if (w1 == w2) {
                    val = q11 * (h2 - h) + q21 * (h - h1);
                } else {
                    val = q11 * (h2 - h) * (w2 - w) +
                    q12 * (h2 - h) * (w - w1) +
                    q21 * (h - h1) * (w2 - w) +
                    q22 * (h - h1) * (w - w1);
                }

                if (val > max_val) {
                    max_val = val;
                    max_h = h;
                    max_w = w;
                }
            }    //end w
        }    // end h
        y[idx] = max_val;
        mask_h[idx] = max_h;
        mask_w[idx] = max_w;
    }
}

template<> void ROIAlign<float, CUDAContext>(const float spatial_scale, 
                                             const int pool_h, const int pool_w,
                                             Tensor* x,
                                             Tensor* roi,
                                             Tensor* mask_h, Tensor* mask_w,
                                             Tensor* y) {
    auto* Xdata = x->data<float, CUDAContext>();
    auto* Rdata = roi->data<float, CUDAContext>();
    auto* Ydata = y->mutable_data<float, CUDAContext>();
    auto* MHdata = mask_h->mutable_data<float, CUDAContext>();
    auto* MWdata = mask_w->mutable_data<float, CUDAContext>();
    TIndex channels = x->dim(1), count = y->count();
    TIndex height = x->dim(2), width = x->dim(3);
    _ROIAlign<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                          spatial_scale, 
                                                               channels, 
                                                          height, width,
                                                         pool_h, pool_w,
                                                                  Xdata,
                                                                  Rdata,
                                                         MHdata, MWdata,
                                                                 Ydata);
    CUDA_POST_KERNEL_CHECK;
}

template <typename T>
__global__ void _ROIAlignGrad(const int count, 
                              const int num_rois, 
                              const T spatial_scale, 
                              const int channels, 
                              const int height, const int width,
                              const int pool_h, const int pool_w, 
                              const T* dy,
                              const T* roi,
                              const T* mask_h, const T* mask_w,
                              T* dx) {
    CUDA_KERNEL_LOOP(idx, count) {
        int w = idx % width;
        int h = (idx / width) % height;
        int c = (idx / width / height) % channels;
        int im_idx = idx / width / height / channels;

        T diff = 0;

        for (int n = 0; n < num_rois; n++) {
            const T* cur_roi = roi + n * 5;
            const int im_idx_spec = cur_roi[0];

            //    ignore wrong im_batch_idx
            if (im_idx != im_idx_spec) continue;

            T x1 = cur_roi[1] * spatial_scale;
            T y1 = cur_roi[2] * spatial_scale;
            T x2 = cur_roi[3] * spatial_scale;
            T y2 = cur_roi[4] * spatial_scale;

            const bool is_in = (w + 1 > x1 && w < x2 + 1 && h + 1 > y1 && h < y2 + 1);
            if (!is_in) continue;

            T roi_height = max(y2 - y1, T(1));
            T roi_width = max(x2 - x1, T(1));

            const T bin_size_h = roi_height / pool_h;
            const T bin_size_w = roi_width / pool_w;

            int start_ph = ceil((h - 1 - y1) / bin_size_h - 1);
            int end_ph = ceil((h + 1 - y1) / bin_size_h);
            int start_pw = ceil((w - 1 - x1) / bin_size_w - 1);
            int end_pw = ceil((w + 1 - x1) / bin_size_w);

            start_ph = min(max(start_ph, 0), pool_h);
            start_pw = min(max(start_pw, 0), pool_w);
            end_ph = min(max(end_ph, 0), pool_h);
            end_pw = min(max(end_pw, 0), pool_w);

            int y_offset = (n * channels + c) * pool_h * pool_w;
            const T* dy_off = dy + y_offset;
            const T* mask_h_off = mask_h + y_offset;
            const T* mask_w_off = mask_w + y_offset;

            for (int ph = start_ph; ph < end_ph; ++ph) {
                for (int pw = start_pw; pw < end_pw; ++pw) {
                    T mh = mask_h_off[ph * pool_w + pw];
                    T mw = mask_w_off[ph * pool_w + pw];
                    int h1 = int(mh), h2 = int(ceil(mh));
                    int w1 = int(mw), w2 = int(ceil(mw));
                    if (h1 <= h && h <= h2 && w1 <= w && w <= w2) {
                        T gradient_factor = 1.0;
                        if (h == h1) gradient_factor *= h2 - mh;
                        else gradient_factor *= mh - h1;
                        if (w == w1) gradient_factor *= w2 - mw;
                        else gradient_factor *= mw - w1;
                        diff += dy_off[ph * pool_w + pw] * gradient_factor;
                    }
                }    //    end pw
            }    // end ph
        }    //    end n
        dx[idx] = diff;
    }
}

template<> void ROIAlignGrad<float, CUDAContext>(const float spatial_scale, 
                                                 const int pool_h, const int pool_w,
                                                 Tensor* dy,
                                                 Tensor* roi,
                                                 Tensor* mask_h, Tensor* mask_w,
                                                 Tensor* dx) {
    auto* dYdata = dy->data<float, CUDAContext>();
    auto* Rdata = roi->data<float, CUDAContext>();
    auto* MHdata = mask_h->data<float, CUDAContext>();
    auto* MWdata = mask_w->data<float, CUDAContext>();
    auto* dXdata = dx->mutable_data<float, CUDAContext>();
    TIndex channels = dx->dim(1), count = dx->count();
    TIndex height = dx->dim(2), width = dx->dim(3);
    _ROIAlignGrad<float> << <GET_BLOCKS(count), CUDA_NUM_THREADS >> >(count, 
                                                                roi->dim(0), 
                                                              spatial_scale, 
                                                                   channels, 
                                                              height, width,
                                                             pool_h, pool_w,
                                                                     dYdata,
                                                                      Rdata,
                                                             MHdata, MWdata,
                                                                    dXdata);
    CUDA_POST_KERNEL_CHECK;
}

}    // namespace kernel

}    // namespace dragon

#endif // WITH_CUDA