#include "pointwise_scores.cuh"
#include "split_properties_helpers.cuh"

#include <catboost/cuda/cuda_util/kernel/instructions.cuh>
#include <catboost/cuda/cuda_util/kernel/random_gen.cuh>
#include <catboost/cuda/cuda_util/kernel/kernel_helpers.cuh>

#include <cmath>
#include <exception>
#include <cfloat>


namespace NKernel {

    class TSolarScoreCalcer {
    public:
        __host__ __device__ TSolarScoreCalcer(float) {
        }

        __forceinline__ __device__ void NextFeature(TCBinFeature) {
            Score = 0;
        }

        __forceinline__ __device__ void AddLeaf(double sum, double weight) {
            Score += (weight > 1e-20f ? (-sum * sum) * (1 + 2 * log(weight + 1.0)) / weight : 0);
        }

        __forceinline__ __device__ double GetScore() {
            return Score;
        }

    private:
        float Lambda = 0;
        float Score = 0;
    };


    class TL2ScoreCalcer {
    public:
        __host__ __device__ TL2ScoreCalcer(float) {

        }

        __forceinline__ __device__ void NextFeature(TCBinFeature) {
            Score = 0;
        }

        __forceinline__ __device__ void AddLeaf(double sum, double weight) {
            Score += (weight > 1e-20f ? (-sum * sum) / weight : 0);
        }

        __forceinline__ __device__ double GetScore() {
            return Score;
        }

    private:
        float Score = 0;
    };

    class TLOOL2ScoreCalcer {
    public:
        __host__ __device__ TLOOL2ScoreCalcer(float) {

        }

        __forceinline__ __device__ void NextFeature(TCBinFeature) {
            Score = 0;
        }

        __forceinline__ __device__ void AddLeaf(double sum, double weight) {
            float adjust = weight > 1 ? weight / (weight - 1) : 0;
            adjust = adjust * adjust;
            Score += (weight > 0 ? adjust * (-sum * sum) / weight : 0);
        }

        __forceinline__ __device__ double GetScore() {
            return Score;
        }

    private:
        float Score = 0;
    };

    class TSatL2ScoreCalcer {
    public:
        __host__ __device__ TSatL2ScoreCalcer(float) {

        }

        __forceinline__ __device__ void NextFeature(TCBinFeature) {
            Score = 0;
        }

        __forceinline__ __device__ void AddLeaf(double sum, double weight) {
            float adjust = weight > 2 ? weight * (weight - 2)/(weight * weight - 3 * weight + 1) : 0;
            Score += (weight > 0 ? adjust * ((-sum * sum) / weight)  : 0);
        }

        __forceinline__ __device__ double GetScore() {
            return Score;
        }

    private:
        float Score = 0;
    };



    class TCorrelationScoreCalcer {
    public:
        __host__ __device__ TCorrelationScoreCalcer(float lambda,
                                                    bool normalize,
                                                    float scoreStdDev,
                                                    ui64 globalSeed
        )
                : Lambda(lambda)
                , Normalize(normalize)
                , ScoreStdDev(scoreStdDev)
                , GlobalSeed(globalSeed) {

        }


        __forceinline__ __device__ void NextFeature(TCBinFeature bf) {
            FeatureId = bf.FeatureId;
            Score = 0;
            DenumSqr = 1e-20f;
        }

        __forceinline__ __device__ void AddLeaf(double sum, double weight) {
            double lambda = Normalize ? Lambda * weight : Lambda;

            const float mu =  weight > 0 ? (sum / (weight + lambda)) : 0.0f;
            Score +=  sum * mu;
            DenumSqr += weight * mu * mu;
        }

        __forceinline__ __device__ float GetScore() {
            float score = DenumSqr > 1e-15f ? -Score / sqrt(DenumSqr) : FLT_MAX;
            if (ScoreStdDev) {
                ui64 seed = GlobalSeed + FeatureId;
                AdvanceSeed(&seed, 4);
                score += NextNormal(&seed) * ScoreStdDev;
            }
            return score;
        }

    private:
        float Lambda;
        bool Normalize;
        float ScoreStdDev;
        ui64 GlobalSeed;

        int FeatureId = 0;
        float Score = 0;
        float DenumSqr = 0;
    };




    template <int BLOCK_SIZE>
    __global__ void FindOptimalSplitSolarImpl(const TCBinFeature* bf,
                                              int binFeatureCount,
                                              const float* binSums,
                                              const TPartitionStatistics* parts,
                                              int pCount, int foldCount,
                                              TBestSplitProperties* result)
    {
        float bestScore = FLT_MAX;
        int bestIndex = 0;
        int tid = threadIdx.x;
        result += blockIdx.x;

         TPartOffsetsHelper helper(foldCount);

        for (int i = blockIdx.x * BLOCK_SIZE; i < binFeatureCount; i += BLOCK_SIZE * gridDim.x) {
            if (i + tid >= binFeatureCount) {
                break;
            }

            const float* current = binSums + 2 * (i + tid);

            float score = 0;

            for (int leaf = 0; leaf < pCount; leaf++) {

                float leftTotalWeight = 0;
                float rightTotalWeight = 0;

                float leftScore = 0;
                float rightScore = 0;

                #pragma unroll 4
                for (int fold = 0; fold < foldCount; fold += 2) {

                    TPartitionStatistics partLearn = LdgWithFallback(parts, helper.GetDataPartitionOffset(leaf, fold));
                    TPartitionStatistics partTest = LdgWithFallback(parts, helper.GetDataPartitionOffset(leaf, fold + 1));


                    float weightEstimateLeft = current[(size_t)binFeatureCount * helper.GetHistogramOffset(leaf, fold) * 2];
                    float weightEstimateRight = partLearn.Weight - weightEstimateLeft;

                    float sumEstimateLeft = current[(size_t)binFeatureCount * helper.GetHistogramOffset(leaf, fold) * 2 + 1];
                    float sumEstimateRight = partLearn.Sum - sumEstimateLeft;


                    float weightTestLeft = current[(size_t)binFeatureCount * helper.GetHistogramOffset(leaf, fold + 1) * 2];
                    float weightTestRight = partTest.Weight - weightTestLeft;

                    float sumTestLeft = current[(size_t)binFeatureCount * helper.GetHistogramOffset(leaf, fold + 1) * 2 + 1];
                    float sumTestRight = partTest.Sum - sumTestLeft;


                    {
                        const float mu = weightEstimateLeft > 0.0f ? (sumEstimateLeft / (weightEstimateLeft + 1e-15f)) : 0;
                        leftScore += -2 * mu * sumTestLeft + weightTestLeft * mu * mu;
                        leftTotalWeight += weightTestLeft;
                    }

                    {
                        const float mu =  weightEstimateRight > 0.0f ? (sumEstimateRight / (weightEstimateRight + 1e-15f)) : 0;
                        rightTotalWeight += weightTestRight;
                        rightScore += -2 * mu * sumTestRight + weightTestRight * mu * mu;
                    }
                }

                score += leftTotalWeight > 2 ? leftScore * (1 + 2 * log(leftTotalWeight + 1)) : 0;
                score += rightTotalWeight > 2 ? rightScore * (1 + 2 * log(rightTotalWeight + 1)) : 0;
            }

            if (score < bestScore) {
                bestScore = score;
                bestIndex = i + tid;
            }
        }

        __shared__ float scores[BLOCK_SIZE];
        scores[tid] = bestScore;
        __shared__ int indices[BLOCK_SIZE];
        indices[tid] = bestIndex;
        __syncthreads();

        for (ui32 s = BLOCK_SIZE >> 1; s > 0; s >>= 1) {
            if (tid < s) {
            if ( scores[tid] > scores[tid + s] ||
                (scores[tid] == scores[tid + s] && indices[tid] > indices[tid + s]) ) {
                    scores[tid] = scores[tid + s];
                    indices[tid] = indices[tid + s];
                }
            }
            __syncthreads();
        }

        if (!tid) {
            result->FeatureId = bf[indices[0]].FeatureId;
            result->BinId = bf[indices[0]].BinId;
            result->Score = scores[0];
        }
    }





    class TDirectHistLoader {
    public:
        __forceinline__ __device__ TDirectHistLoader(const float* binSums,
                                      TPartOffsetsHelper& helper,
                                     int binFeatureId,
                                     int /* leaf count*/,
                                     int binFeatureCount)
                : BinSums(binSums + 2 * binFeatureId)
                , Helper(helper)
                , BinFeatureCount(binFeatureCount) {

        }

        __forceinline__ __device__ float LoadWeight(int leaf) {
            return BinSums[(size_t)BinFeatureCount * Helper.GetHistogramOffset(leaf, 0) * 2];
        }

        __forceinline__ __device__ float LoadSum(int leaf) {
            return BinSums[(size_t)BinFeatureCount * Helper.GetHistogramOffset(leaf, 0) * 2 + 1];
        }
    private:
        const float* BinSums;
         TPartOffsetsHelper& Helper;
        int BinFeatureCount;
    };


    class TGatheredByLeavesHistLoader {
    public:
        __forceinline__ __device__ TGatheredByLeavesHistLoader(const float* binSums,
                                                                TPartOffsetsHelper&,
                                                               int binFeatureId,
                                                               int leafCount,
                                                               int /*binFeatureCount*/)
                : BinSums(binSums)
                , LeafCount(leafCount)
                , FeatureId(binFeatureId) {

        }

        __forceinline__ __device__ int GetOffset(int leaf) {
            return 2 * (FeatureId * LeafCount + leaf);
        }

        __forceinline__ __device__ float LoadWeight(int leaf) {
            return BinSums[GetOffset(leaf)];
        }

        __forceinline__ __device__ float LoadSum(int leaf) {
            return BinSums[GetOffset(leaf) + 1];
        }

    private:
        const float* BinSums;
        int LeafCount;
        int FeatureId;
    };

    template <int BLOCK_SIZE,
            class THistLoader,
            class TScoreCalcer>
    __global__ void FindOptimalSplitSingleFoldImpl(const TCBinFeature* bf,
                                                   int binFeatureCount,
                                                   const float* binSums,
                                                   const TPartitionStatistics* parts,
                                                   int pCount,
                                                   TScoreCalcer calcer,
                                                   TBestSplitProperties* result) {
        float bestScore = FLT_MAX;
        int bestIndex = 0;
        int tid = threadIdx.x;
        result += blockIdx.x;

         TPartOffsetsHelper helper(1);

        for (int i = blockIdx.x * BLOCK_SIZE; i < binFeatureCount; i += BLOCK_SIZE * gridDim.x) {
            if (i + tid >= binFeatureCount) {
                break;
            }
            calcer.NextFeature(bf[i + tid]);

            THistLoader histLoader(binSums,
                                   helper,
                                   i + tid,
                                   pCount,
                                   binFeatureCount);

            for (int leaf = 0; leaf < pCount; leaf++) {
                TPartitionStatistics part = LdgWithFallback(parts, helper.GetDataPartitionOffset(leaf, 0));

                float weightLeft = histLoader.LoadWeight(leaf);
                float weightRight = max(part.Weight - weightLeft, 0.0f);

                float sumLeft = histLoader.LoadSum(leaf);
                float sumRight = static_cast<float>(part.Sum - sumLeft);

                calcer.AddLeaf(sumLeft, weightLeft);
                calcer.AddLeaf(sumRight, weightRight);
            }
            const float score = calcer.GetScore();

            if (score < bestScore) {
                bestScore = score;
                bestIndex = i + tid;
            }
        }

        __shared__ float scores[BLOCK_SIZE];
        scores[tid] = bestScore;
        __shared__ int indices[BLOCK_SIZE];
        indices[tid] = bestIndex;
        __syncthreads();

        for (ui32 s = BLOCK_SIZE >> 1; s > 0; s >>= 1) {
            if (tid < s) {
                if ( scores[tid] > scores[tid + s] ||
                     (scores[tid] == scores[tid + s] && indices[tid] > indices[tid + s]) ) {
                    scores[tid] = scores[tid + s];
                    indices[tid] = indices[tid + s];
                }
            }
            __syncthreads();
        }

        if (!tid) {
            result->FeatureId = bf[indices[0]].FeatureId;
            result->BinId = bf[indices[0]].BinId;
            result->Score = scores[0];
        }
    }





    template <int BLOCK_SIZE>
    __global__ void FindOptimalSplitCorrelationImpl(const TCBinFeature* bf, int binFeatureCount, const float* binSums,
                                                    const TPartitionStatistics* parts, int pCount, int foldCount,
                                                    double l2, bool normalize,
                                                    double scoreStdDev, ui64 globalSeed,
                                                    TBestSplitProperties* result)
    {
        float bestScore = FLT_MAX;
        int bestIndex = 0;
        int tid = threadIdx.x;
        result += blockIdx.x;
        TPartOffsetsHelper helper(foldCount);



        for (int i = blockIdx.x * BLOCK_SIZE; i < binFeatureCount; i += BLOCK_SIZE * gridDim.x) {
            if (i + tid >= binFeatureCount) {
                break;
            }

            float score = 0;
            float denumSqr = 1e-20f;
            const float* current = binSums + 2 * (i + tid);

            for (int leaf = 0; leaf < pCount; leaf++) {

                #pragma unroll 4
                for (int fold = 0; fold < foldCount; fold += 2) {

                    TPartitionStatistics partLearn = LdgWithFallback(parts, helper.GetDataPartitionOffset(leaf, fold));
                    TPartitionStatistics partTest = LdgWithFallback(parts, helper.GetDataPartitionOffset(leaf, fold + 1));


                    float weightEstimateLeft = current[(size_t)binFeatureCount * helper.GetHistogramOffset(leaf, fold) * 2];
                    float weightEstimateRight = max(partLearn.Weight - weightEstimateLeft, 0.0f);

                    float sumEstimateLeft = current[(size_t)binFeatureCount * helper.GetHistogramOffset(leaf, fold) * 2 + 1];
                    float sumEstimateRight = partLearn.Sum - sumEstimateLeft;


                    float weightTestLeft = current[(size_t)binFeatureCount * helper.GetHistogramOffset(leaf, fold + 1) * 2];
                    float weightTestRight = max(partTest.Weight - weightTestLeft, 0.0f);

                    float sumTestLeft = current[(size_t)binFeatureCount * helper.GetHistogramOffset(leaf, fold + 1) * 2 + 1];
                    float sumTestRight = partTest.Sum - sumTestLeft;


                    {
                        double lambda = normalize ? l2 * weightEstimateLeft : l2;

                        const float mu =  weightEstimateLeft > 0 ? (sumEstimateLeft / (weightEstimateLeft + lambda)) : 0;
                        score += sumTestLeft * mu;
                        denumSqr += weightTestLeft * mu * mu;
                    }

                    {
                        double lambda = normalize ? l2 * weightEstimateRight : l2;

                        const float mu =  weightEstimateRight > 0 ? (sumEstimateRight / (weightEstimateRight + lambda)) : 0;
                        score += sumTestRight * mu;
                        denumSqr += weightTestRight * mu * mu;
                    }
                }
            }

            score = denumSqr > 1e-15f ? -score / sqrt(denumSqr) : FLT_MAX;
            float tmp = score;
            if (scoreStdDev) {
                ui64 seed = globalSeed + bf[i + tid].FeatureId;
                AdvanceSeed(&seed, 4);

                tmp += NextNormal(&seed) * scoreStdDev;
            }
            if (tmp < bestScore) {
                bestScore = tmp;
                bestIndex = i + tid;
            }
        }

        __shared__ float scores[BLOCK_SIZE];
        scores[tid] = bestScore;
        __shared__ int indices[BLOCK_SIZE];
        indices[tid] = bestIndex;
        __syncthreads();

        for (ui32 s = BLOCK_SIZE >> 1; s > 0; s >>= 1) {
            if (tid < s) {
                if (scores[tid] > scores[tid + s] ||
                    (scores[tid] == scores[tid + s] && indices[tid] > indices[tid + s]) ) {
                    scores[tid] = scores[tid + s];
                    indices[tid] = indices[tid + s];
                }
            }
            __syncthreads();
        }

        if (!tid) {
            result->FeatureId = bf[indices[0]].FeatureId;
            result->BinId = bf[indices[0]].BinId;
            result->Score = scores[0];
        }
    }




    void FindOptimalSplitDynamic(const TCBinFeature* binaryFeatures,ui32 binaryFeatureCount,
                                 const float* splits, const TPartitionStatistics* parts, ui32 pCount, ui32 foldCount,
                                 TBestSplitProperties* result, ui32 resultSize,
                                 EScoreFunction scoreFunction, double l2, bool normalize,
                                 double scoreStdDev, ui64 seed,
                                 TCudaStream stream) {
        const int blockSize = 128;
        switch (scoreFunction)
        {
            case  EScoreFunction::SolarL2: {
                FindOptimalSplitSolarImpl<blockSize> << < resultSize, blockSize, 0, stream >> > (binaryFeatures, binaryFeatureCount, splits, parts, pCount, foldCount, result);
                break;
            }
            case  EScoreFunction::Correlation:
            case  EScoreFunction::NewtonCorrelation: {
                FindOptimalSplitCorrelationImpl<blockSize> << < resultSize, blockSize, 0, stream >> > (binaryFeatures, binaryFeatureCount, splits, parts, pCount, foldCount, l2, normalize, scoreStdDev, seed, result);
                break;
            }
            default: {
                throw std::exception();
            }
        }
    }

    template <class TLoader>
    void FindOptimalSplitPlain(const TCBinFeature* binaryFeatures,ui32 binaryFeatureCount,
                               const float* splits, const TPartitionStatistics* parts, ui32 pCount,
                               TBestSplitProperties* result, ui32 resultSize,
                               EScoreFunction scoreFunction, double l2, bool normalize,
                               double scoreStdDev, ui64 seed,
                               TCudaStream stream) {
        const int blockSize = 128;
        #define RUN() \
        FindOptimalSplitSingleFoldImpl<blockSize, TLoader, TScoreCalcer> << < resultSize, blockSize, 0, stream >> > (binaryFeatures, binaryFeatureCount, splits, parts, pCount, scoreCalcer, result);


        switch (scoreFunction)
        {
            case  EScoreFunction::SolarL2: {
                using TScoreCalcer = TSolarScoreCalcer;
                TScoreCalcer scoreCalcer(static_cast<float>(l2));
                RUN()
                break;
            }
            case  EScoreFunction::SatL2: {
                using TScoreCalcer = TSatL2ScoreCalcer;
                TScoreCalcer scoreCalcer(static_cast<float>(l2));
                RUN()
                break;
            }
            case  EScoreFunction::LOOL2: {
                using TScoreCalcer = TLOOL2ScoreCalcer;
                TScoreCalcer scoreCalcer(static_cast<float>(l2));
                RUN()
                break;
            }
            case EScoreFunction::L2:
            case EScoreFunction::NewtonL2: {
                using TScoreCalcer = TL2ScoreCalcer;
                TScoreCalcer scoreCalcer(static_cast<float>(l2));
                RUN()
                break;
            }
            case  EScoreFunction::Correlation:
            case  EScoreFunction::NewtonCorrelation: {
                using TScoreCalcer = TCorrelationScoreCalcer;
                TCorrelationScoreCalcer scoreCalcer(static_cast<float>(l2),
                                                    normalize,
                                                    static_cast<float>(scoreStdDev),
                                                    seed);
                RUN()
                break;
            }
            default: {
                throw std::exception();
            }
        }
        #undef RUN
    }


    void FindOptimalSplit(const TCBinFeature* binaryFeatures,ui32 binaryFeatureCount,
                          const float* splits, const TPartitionStatistics* parts, ui32 pCount, ui32 foldCount,
                          TBestSplitProperties* result, ui32 resultSize,
                          EScoreFunction scoreFunction, double l2, bool normalize,
                          double scoreStdDev, ui64 seed, bool gatheredByLeaves,
                          TCudaStream stream)
    {

        if (binaryFeatureCount > 0) {
            if (foldCount == 1) {
                if (gatheredByLeaves) {
                    using THistLoader = TGatheredByLeavesHistLoader;
                    FindOptimalSplitPlain<THistLoader>(binaryFeatures, binaryFeatureCount, splits, parts, pCount, result, resultSize, scoreFunction, l2, normalize, scoreStdDev, seed, stream);
                } else {
                    using THistLoader = TDirectHistLoader;
                    FindOptimalSplitPlain<THistLoader>(binaryFeatures, binaryFeatureCount, splits, parts, pCount, result, resultSize, scoreFunction, l2, normalize, scoreStdDev, seed, stream);
                }
            } else {
                FindOptimalSplitDynamic(binaryFeatures, binaryFeatureCount, splits, parts, pCount, foldCount, result, resultSize, scoreFunction, l2, normalize, scoreStdDev, seed, stream);
            }
        }
    }


    template <int BLOCK_SIZE, int HIST_COUNT>
    __global__ void GatherHistogramsByLeavesImpl(const int binFeatureCount,
                                                 const float* histogram,
                                                 const int histCount,
                                                 const int leafCount,
                                                 const int foldCount,
                                                 float* result) {

        const int featuresPerBlock = BLOCK_SIZE / leafCount;
        const int featureId = blockIdx.x * featuresPerBlock + threadIdx.x / leafCount;
        const int leafId = threadIdx.x & (leafCount - 1);

        const int foldId = blockIdx.y;
        TPartOffsetsHelper helper(gridDim.y);

        if (featureId < binFeatureCount) {
            float leafVals[HIST_COUNT];
            #pragma unroll
            for (int histId = 0; histId < HIST_COUNT; ++histId) {
                leafVals[histId] = LdgWithFallback(histogram,
                                                   (featureId + (size_t)binFeatureCount * helper.GetHistogramOffset(leafId, foldId)) * HIST_COUNT + histId);
            }

            #pragma unroll
            for (int histId = 0; histId < HIST_COUNT; ++histId) {
                const  ui64 idx = ((size_t)featureId * leafCount * foldCount + leafId * foldCount + foldId) * HIST_COUNT + histId;
                result[idx] = leafVals[histId];
            }
        }
    }

    bool GatherHistogramByLeaves(const float* histogram,
                                 const ui32 binFeatureCount,
                                 const ui32 histCount,
                                 const ui32 leafCount,
                                 const ui32 foldCount,
                                 float* result,
                                 TCudaStream stream
    )
    {
        const int blockSize = 1024;
        dim3 numBlocks;
        numBlocks.x = (binFeatureCount + (blockSize / leafCount) - 1) / (blockSize / leafCount);
        numBlocks.y = foldCount;
        numBlocks.z = 1;

        switch (histCount) {
            case 1: {
                GatherHistogramsByLeavesImpl<blockSize, 1> <<<numBlocks, blockSize, 0, stream>>>(binFeatureCount, histogram, histCount, leafCount, foldCount, result);
                return true;
            }
            case 2: {
                GatherHistogramsByLeavesImpl<blockSize, 2> <<<numBlocks, blockSize, 0, stream>>>(binFeatureCount, histogram, histCount, leafCount, foldCount, result);
                return true;
            }
            case 4: {
                GatherHistogramsByLeavesImpl<blockSize, 4> <<<numBlocks, blockSize, 0, stream>>>(binFeatureCount, histogram, histCount, leafCount, foldCount, result);
                return true;
            }
            default: {
                return false;
            }
        }
    }

    template <int BLOCK_SIZE>
    __global__ void PartitionUpdateImpl(const float* target,
                                        const float* weights,
                                        const float* counts,
                                        const struct TDataPartition* parts,
                                        struct TPartitionStatistics* partStats)
    {
        const int tid = threadIdx.x;
        parts += blockIdx.x;
        partStats += blockIdx.x;
        const int size = parts->Size;

        __shared__ volatile double localBuffer[BLOCK_SIZE];

        double tmp = 0;

        if (weights != 0) {
            localBuffer[tid] = ComputeSum<BLOCK_SIZE>(weights + parts->Offset, size);
            __syncthreads();
            tmp =  Reduce<double, BLOCK_SIZE>(localBuffer);
        }

        if (tid == 0)
        {
            partStats->Weight = tmp;
        }
        tmp =  0;
        __syncthreads();

        if (target != 0) {
            localBuffer[tid] = ComputeSum<BLOCK_SIZE>(target + parts->Offset, size);
            __syncthreads();
            tmp = Reduce<double, BLOCK_SIZE>(localBuffer);
        }

        if (tid == 0)
        {
             partStats->Sum = tmp;
        }

        tmp  = 0;
        __syncthreads();

        if (counts != 0) {
            localBuffer[tid] = ComputeSum<BLOCK_SIZE>(counts + parts->Offset, size);
            __syncthreads();
            tmp =  Reduce<double, BLOCK_SIZE>(localBuffer);
        } else {
           tmp = size;
        }

        if (tid == 0)
        {
            partStats->Count = tmp;
        }

    }

    void UpdatePartitionProps(const float* target,
                              const float* weights,
                              const float* counts,
                              const struct TDataPartition* parts,
                              struct TPartitionStatistics* partStats,
                              int partsCount,
                              TCudaStream stream
    )
    {
        const int blockSize = 1024;
        if (partsCount) {
            PartitionUpdateImpl<blockSize> << < partsCount, blockSize, 0, stream >> > (target, weights, counts, parts, partStats);
        }
    }



}
