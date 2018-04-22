#pragma once

#include <catboost/cuda/cuda_lib/cuda_kernel_buffer.h>
#include <catboost/cuda/cuda_lib/cuda_buffer.h>
#include <catboost/cuda/cuda_lib/kernel.h>
#include <catboost/cuda/cuda_util/kernel/scan.cuh>
#include <catboost/libs/helpers/exception.h>

namespace NKernelHost {
    template <typename T>
    class TScanVectorKernel: public TKernelBase<NKernel::TScanKernelContext<T>, false> {
    private:
        TCudaBufferPtr<const T> Input;
        TCudaBufferPtr<T> Output;
        bool Inclusive;
        bool IsNonNegativeSegmentedScan;

    public:
        using TKernelContext = NKernel::TScanKernelContext<T>;
        Y_SAVELOAD_DEFINE(Input, Output, Inclusive, IsNonNegativeSegmentedScan);

        THolder<TKernelContext> PrepareContext(IMemoryManager& memoryManager) const {
            auto context = MakeHolder<TKernelContext>();
            context->NumParts = NKernel::ScanVectorTempSize<T>((ui32)Input.Size(), Inclusive);
            //TODO(noxoomo): make temp memory more robust
            context->PartResults = memoryManager.Allocate<char>(context->NumParts).Get();
            return context;
        }

        TScanVectorKernel() = default;

        TScanVectorKernel(TCudaBufferPtr<const T> input,
                          TCudaBufferPtr<T> output,
                          bool inclusive,
                          bool nonNegativeSegmented)
            : Input(input)
            , Output(output)
            , Inclusive(inclusive)
            , IsNonNegativeSegmentedScan(nonNegativeSegmented)
        {
        }

        void Run(const TCudaStream& stream, TKernelContext& context) {
            if (IsNonNegativeSegmentedScan) {
                CB_ENSURE(Inclusive, "Error: fast exclusive scan currently not working via simple operator transformation");
                CUDA_SAFE_CALL(NKernel::SegmentedScanNonNegativeVector<T>(Input.Get(), Output.Get(),
                                                                          (ui32)Input.Size(), Inclusive,
                                                                          context, stream.GetStream()));
            } else {
                //scan is done by cub.
                CUDA_SAFE_CALL(NKernel::ScanVector<T>(Input.Get(), Output.Get(),
                                                      (ui32)Input.Size(),
                                                      Inclusive, context,
                                                      stream.GetStream()));
            }
        }
    };

    template <typename T>
    class TNonNegativeSegmentedScanAndScatterVectorKernel: public TKernelBase<NKernel::TScanKernelContext<T>, false> {
    private:
        TCudaBufferPtr<const T> Input;
        TCudaBufferPtr<const ui32> Indices;
        TCudaBufferPtr<T> Output;
        bool Inclusive;

    public:
        using TKernelContext = NKernel::TScanKernelContext<T>;
        Y_SAVELOAD_DEFINE(Input, Indices, Output, Inclusive);

        THolder<TKernelContext> PrepareContext(IMemoryManager& memoryManager) const {
            auto context = MakeHolder<TKernelContext>();
            context->NumParts = NKernel::ScanVectorTempSize<T>((ui32)Input.Size(), Inclusive);
            context->PartResults = memoryManager.Allocate<char>(context->NumParts).Get();
            return context;
        }

        TNonNegativeSegmentedScanAndScatterVectorKernel() = default;

        TNonNegativeSegmentedScanAndScatterVectorKernel(TCudaBufferPtr<const T> input,
                                                        TCudaBufferPtr<const ui32> indices,
                                                        TCudaBufferPtr<T> output,
                                                        bool inclusive)
            : Input(input)
            , Indices(indices)
            , Output(output)
            , Inclusive(inclusive)
        {
        }

        void Run(const TCudaStream& stream, TKernelContext& context) {
            NKernel::SegmentedScanAndScatterNonNegativeVector<T>(Input.Get(), Indices.Get(), Output.Get(),
                                                                 (ui32)Input.Size(), Inclusive,
                                                                 context, stream.GetStream());
        }
    };
}

template <typename T, class TMapping>
inline void ScanVector(const TCudaBuffer<T, TMapping>& input, TCudaBuffer<T, TMapping>& output,
                       bool inclusive = false, ui32 streamId = 0) {
    using TKernel = NKernelHost::TScanVectorKernel<T>;
    LaunchKernels<TKernel>(input.NonEmptyDevices(), streamId, input, output, inclusive, false);
}

//TODO(noxoomo): we should be able to run exclusive also
template <typename T, class TMapping>
inline void InclusiveSegmentedScanNonNegativeVector(const TCudaBuffer<T, TMapping>& input,
                                                    TCudaBuffer<T, TMapping>& output,
                                                    ui32 streamId = 0) {
    using TKernel = NKernelHost::TScanVectorKernel<T>;
    LaunchKernels<TKernel>(input.NonEmptyDevices(), streamId, input, output, true, true);
}

//Not the safest way…
template <typename T, class TMapping, class TUi32 = ui32>
inline void SegmentedScanAndScatterNonNegativeVector(const TCudaBuffer<T, TMapping>& inputWithSignMasks,
                                                     const TCudaBuffer<TUi32, TMapping>& indices,
                                                     TCudaBuffer<T, TMapping>& output,
                                                     bool inclusive = false,
                                                     ui32 streamId = 0) {
    using TKernel = NKernelHost::TNonNegativeSegmentedScanAndScatterVectorKernel<T>;
    LaunchKernels<TKernel>(inputWithSignMasks.NonEmptyDevices(), streamId, inputWithSignMasks, indices, output, inclusive);
}
