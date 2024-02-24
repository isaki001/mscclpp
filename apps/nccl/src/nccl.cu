// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#include <algorithm>
#include <mscclpp/concurrency_device.hpp>
#include <mscclpp/core.hpp>
#include <mscclpp/sm_channel.hpp>
#include <mscclpp/sm_channel_device.hpp>
#include <unordered_map>
#include <vector>

#include "nccl.h"

#define NCCL_API extern "C" __attribute__((visibility("default")))

#define CUDACHECK(cmd)                                                                      \
  do {                                                                                      \
    cudaError_t e = cmd;                                                                    \
    if (e != cudaSuccess) {                                                                 \
      printf("Failed: Cuda error %s:%d '%s'\n", __FILE__, __LINE__, cudaGetErrorString(e)); \
      exit(EXIT_FAILURE);                                                                   \
    }                                                                                       \
  } while (0)

#define NUM_CHANNELS_PER_CONNECTION 32

#if defined(__HIP_PLATFORM_AMD__)
#define WARP_SIZE 64
#else
#define WARP_SIZE 32
#endif

template <typename To, typename From>
__forceinline__ __device__ To bit_cast(const From& src) {
  static_assert(sizeof(To) == sizeof(From), "Size mismatch for bit_cast");

  union {
    From f;
    To t;
  } u;
  u.f = src;
  return u.t;
}

template <typename T>
__forceinline__ __device__ T add_elements(T a, T b) {
  return a + b;
}

template <>
__forceinline__ __device__ __half2 add_elements(__half2 a, __half2 b) {
  return __hadd2(a, b);
}

template <typename T>
__forceinline__ __device__ int4 add_vectors_helper(int4 a, int4 b) {
  int4 ret;
  ret.w = bit_cast<int, T>(add_elements(bit_cast<T, int>(a.w), bit_cast<T, int>(b.w)));
  ret.x = bit_cast<int, T>(add_elements(bit_cast<T, int>(a.x), bit_cast<T, int>(b.x)));
  ret.y = bit_cast<int, T>(add_elements(bit_cast<T, int>(a.y), bit_cast<T, int>(b.y)));
  ret.z = bit_cast<int, T>(add_elements(bit_cast<T, int>(a.z), bit_cast<T, int>(b.z)));
  return ret;
}

template <typename T>
__forceinline__ __device__ int4 add_vectors(int4 a, int4 b) {
  return add_vectors_helper<T>(a, b);
}

template <>
__forceinline__ __device__ int4 add_vectors<__half>(int4 a, int4 b) {
  return add_vectors_helper<__half2>(a, b);
}

template <typename T>
__forceinline__ __device__ uint2 add_vectors_helper(uint2 a, uint2 b) {
  uint2 ret;
  ret.x = bit_cast<int, T>(add_elements(bit_cast<T, int>(a.x), bit_cast<T, int>(b.x)));
  ret.y = bit_cast<int, T>(add_elements(bit_cast<T, int>(a.y), bit_cast<T, int>(b.y)));
  return ret;
}

template <typename T>
__forceinline__ __device__ uint2 add_vectors(uint2 a, uint2 b) {
  return add_vectors_helper<T>(a, b);
}

template <>
__forceinline__ __device__ uint2 add_vectors<__half>(uint2 a, uint2 b) {
  return add_vectors_helper<__half2>(a, b);
}

template <typename T>
__forceinline__ __device__ int add_vectors_helper(int a, int b) {
  return bit_cast<int, T>(add_elements(bit_cast<T, int>(a), bit_cast<T, int>(b)));
}

template <typename T>
__forceinline__ __device__ int add_vectors(int a, int b) {
  return add_vectors_helper<T>(a, b);
}

template <>
__forceinline__ __device__ int add_vectors<__half>(int a, int b) {
  return add_vectors_helper<__half2>(a, b);
}

template <typename T>
__forceinline__ __device__ uint32_t add_vectors_helper(uint32_t a, uint32_t b) {
  return bit_cast<uint32_t, T>(add_elements(bit_cast<T, uint32_t>(a), bit_cast<T, uint32_t>(b)));
}

template <typename T>
__forceinline__ __device__ uint32_t add_vectors(uint32_t a, uint32_t b) {
  return add_vectors_helper<T>(a, b);
}

template <>
__forceinline__ __device__ uint32_t add_vectors<__half>(uint32_t a, uint32_t b) {
  return add_vectors_helper<__half2>(a, b);
}

template <typename T>
__forceinline__ __device__ void vectorSum(T* dst, T* src, size_t nElem, int blockId, int nBlocks) {
  size_t nInt4 = nElem / 4;
  size_t nLastInts = nElem % 4;
  int4* dst4 = (int4*)dst;
  int4* src4 = (int4*)src;
  for (size_t i = threadIdx.x + blockId * blockDim.x; i < nInt4; i += blockDim.x * nBlocks) {
    dst4[i] = add_vectors<T>(dst4[i], src4[i]);
  }
  if (nLastInts > 0) {
    int* dstLast = ((int*)dst) + nInt4 * 4;
    int* srcLast = ((int*)src) + nInt4 * 4;
    for (size_t i = threadIdx.x + blockId * blockDim.x; i < nLastInts; i += blockDim.x * nBlocks) {
      dstLast[i] = add_vectors<T>(dstLast[i], srcLast[i]);
    }
  }
}

template <typename T>
__forceinline__ __device__ void vectorSum(T* dst, T* src, size_t nElem) {
  vectorSum(dst, src, nElem, blockIdx.x, gridDim.x);
}

// TODO:
static const int nRanksPerNode = 8;
// Only use scratch buffer for message size less then 1MB
static const int scratchSize = 1024 * 1024 * 8;

// static const mscclpp::Transport IBs[] = {mscclpp::Transport::IB0, mscclpp::Transport::IB1, mscclpp::Transport::IB2,
//                             mscclpp::Transport::IB3, mscclpp::Transport::IB4, mscclpp::Transport::IB5,
//                             mscclpp::Transport::IB6, mscclpp::Transport::IB7};

__constant__ mscclpp::DeviceHandle<mscclpp::SmChannel> constSmChannels[256];
__constant__ mscclpp::DeviceHandle<mscclpp::SmChannel> constSmOutChannels[256];
__device__ mscclpp::DeviceSyncer deviceSyncer;

struct channelKey {
  const void* sendbuff;
  const void* recvbuff;
  size_t bytes;
  bool operator==(const channelKey& other) const {
    return sendbuff == other.sendbuff && recvbuff == other.recvbuff && bytes == other.bytes;
  }
};

namespace std {
template <>
struct hash<channelKey> {
  std::size_t operator()(const channelKey& k) const {
    return std::hash<const void*>()(k.sendbuff) ^ std::hash<const void*>()(k.recvbuff) ^ std::hash<size_t>()(k.bytes);
  }
};
}  // namespace std

struct ChannelInfo {
  std::vector<mscclpp::SmChannel> smChannels;
  std::vector<mscclpp::SmChannel> smOutChannels;
  /*std::vector<mscclpp::DeviceHandle<mscclpp::SmChannel>> smChannelDeviceHandles;
  std::vector<mscclpp::DeviceHandle<mscclpp::SmChannel>> smOutChannelDeviceHandles;*/
  void* smChannelDeviceHandles;
  void* smOutChannelDeviceHandles;  
};

struct ncclComm {
  std::shared_ptr<mscclpp::Communicator> comm;
  std::vector<std::shared_ptr<mscclpp::Connection>> connections;
  std::vector<std::shared_ptr<mscclpp::SmDevice2DeviceSemaphore>> smSemaphores;

  std::unordered_map<channelKey, ChannelInfo> channelInfos;
  std::shared_ptr<char> scratchBuff;
  std::vector<mscclpp::RegisteredMemory> remoteScratchRegMemories;
};

cudaError_t allreduce(int* buff, int* scratch, void* resultBuff, int rank, int nRanksPerNode, int worldSize,
                      size_t nelems, cudaStream_t stream);

#include <mscclpp/packet_device.hpp>
#include <mscclpp/sm_channel_device.hpp>

// extern __constant__ mscclpp::SmChannelDeviceHandle *constSmChannels;
__device__ uint64_t globalFlag;

template <typename T>
__global__ void allreduce6(T* buff, T* scratch, T* resultBuff, int rank, int nRanksPerNode, int worldSize,
                           size_t nelems) {
  // This version of allreduce only works for single nodes
  if (worldSize != nRanksPerNode) return;
  nelems = nelems / (sizeof(int) / sizeof(T));
  const int nPeers = nRanksPerNode - 1;
  const int nPkts = nelems / 2;
  const int nelemsPerRank = nelems / worldSize;
  const int nPktsPerRank = nelemsPerRank / 2;
  // flag for packets. Initially 1
  const uint32_t flag = (uint32_t)globalFlag + 1;
  // thread block & channel info
  const int nBlocksPerPeer = gridDim.x / nPeers;
  const int localBlockIdx = blockIdx.x % nBlocksPerPeer;
  const int peerIdx = blockIdx.x / nBlocksPerPeer;
  const int remoteRank = peerIdx < rank ? peerIdx : peerIdx + 1;
  if (threadIdx.x == 0 && blockIdx.x == 0) {
    globalFlag += 1;
  }
}

template <typename T>
__global__ void allreduce1(T* src, T* dst, int rank, int nranks, size_t nelems) {
  const size_t chunkSize = nelems / nranks;
  if (nranks == 1) return;
  const int nPeer = nranks - 1;
  const size_t indexOffset = rank * chunkSize;
  const size_t vectorSize = sizeof(int4) / sizeof(T);
  const size_t indexOffset4 = indexOffset / vectorSize;
  int4* src4 = (int4*)src;
  int4* dst4 = (int4*)dst;
  const int tid = threadIdx.x + blockIdx.x * blockDim.x;

}

template <typename T>
__global__ void allreduce7(T* buff, T* scratch, T* resultBuff, int rank, int nRanksPerNode, int worldSize,
                           size_t nelems) {
  // This version of allreduce only works for single nodes
  if (worldSize != nRanksPerNode) return;
  nelems = nelems / (sizeof(int) / sizeof(T));
  if (threadIdx.x == 0 && blockIdx.x == 0) {
    globalFlag += 1;
  }
}

template <typename T>
cudaError_t allreduce(T* buff, T* scratch, T* resultBuff, int rank, int nRanksPerNode, int worldSize, size_t nelems,
                      cudaStream_t stream) {
  if (sizeof(T) * nelems <= (1 << 20)) {
#if defined(__HIP_PLATFORM_AMD__)
    int nBlocks = 28;
    int nThreadsPerBlock = 1024;
    if (nelems >= 8192) {
      nBlocks = 56;
      nThreadsPerBlock = (nelems <= 76800) ? 512 : 1024;
    }
    allreduce7<<<nBlocks, nThreadsPerBlock, 0, stream>>>(buff, scratch, resultBuff, rank, nRanksPerNode, worldSize,
                                                         nelems);
#else
    allreduce6<<<21, 512, 0, stream>>>(buff, scratch, resultBuff, rank, nRanksPerNode, worldSize, nelems);
#endif
  } else {
    allreduce1<<<24, 1024, 0, stream>>>(buff, resultBuff, rank, worldSize, nelems);
  }
  return cudaGetLastError();
}

__global__ void __launch_bounds__(1024, 1)
    allgather5(size_t rank, [[maybe_unused]] size_t worldSize, size_t nRanksPerNode, size_t nelemsPerGPU, void* smChannel) {
  const size_t nBlock = gridDim.x;
  if (blockIdx.x >= nBlock) return;

  const size_t tid = threadIdx.x + blockIdx.x * blockDim.x;
  const size_t lid = tid % WARP_SIZE;
  const size_t wid = tid / WARP_SIZE;

  const size_t nThread = blockDim.x * nBlock;
  const size_t nWarp = nThread / WARP_SIZE;
  const size_t nPeer = nRanksPerNode - 1;
  const size_t chanOffset = nPeer * blockIdx.x;
  mscclpp::DeviceHandle<mscclpp::SmChannel> *constSmChannels =  (mscclpp::DeviceHandle<mscclpp::SmChannel>*) smChannel;
  auto smChans = constSmChannels + chanOffset;

  if (wid < nPeer && lid == 0) {
    smChans[wid].relaxedSignal();
    smChans[wid].wait();
  }
  __syncthreads();
  const size_t bytesPerGPU = nelemsPerGPU * sizeof(int);
  const size_t bytes = bytesPerGPU * nPeer;
  size_t unitBytesPerThread;
  if (bytes >= nThread * 64) {
    unitBytesPerThread = 64;
  } else {
    unitBytesPerThread = 16;
  }
  const size_t unitBytesPerWarp = unitBytesPerThread * WARP_SIZE;
  const size_t unitBytes = unitBytesPerWarp * nWarp;
  const size_t nLoop = bytes / unitBytes;

  if (nLoop > 0) {
    // First loop unrolling
    const size_t peerIdx = wid % nPeer;
    const size_t remoteRankLocalIndex = (peerIdx < rank ? peerIdx : peerIdx + 1);
    const size_t offset = bytesPerGPU * remoteRankLocalIndex + (wid / nPeer) * unitBytesPerWarp;
    smChans[peerIdx].get<16, false>(offset, unitBytesPerWarp, lid, WARP_SIZE);
  }

  for (size_t i = 1; i < nLoop; ++i) {
    const size_t gWid = wid + i * nWarp;
    const size_t peerIdx = gWid % nPeer;
    const size_t remoteRankLocalIndex = (peerIdx < rank ? peerIdx : peerIdx + 1);
    const size_t offset = bytesPerGPU * remoteRankLocalIndex + (gWid / nPeer) * unitBytesPerWarp;
    smChans[peerIdx].get<16, false>(offset, unitBytesPerWarp, lid, WARP_SIZE);
  }

  if (bytes % unitBytes > 0) {
    const size_t gWid = wid + nLoop * nWarp;
    const size_t peerIdx = gWid % nPeer;
    const size_t remoteRankLocalIndex = (peerIdx < rank ? peerIdx : peerIdx + 1);
    const size_t offsetWithinRank = (gWid / nPeer) * unitBytesPerWarp;
    const size_t offset = bytesPerGPU * remoteRankLocalIndex + offsetWithinRank;
    const size_t remainBytes = (offsetWithinRank + unitBytesPerWarp > bytesPerGPU)
                                   ? ((bytesPerGPU > offsetWithinRank) ? (bytesPerGPU - offsetWithinRank) : 0)
                                   : unitBytesPerWarp;
    if (remainBytes > 0) {
      smChans[peerIdx].get<16, true>(offset, remainBytes, lid, WARP_SIZE);
    }
  }
}

template <typename T>
cudaError_t allgather(T* buff, T* scratch, T* resultBuff, int rank, int nRanksPerNode, int worldSize, size_t nelems,
                      cudaStream_t stream, void* smChannel) {
  cudaError_t err = cudaMemcpyAsync(resultBuff + nelems * rank, buff, nelems * sizeof(T), cudaMemcpyDeviceToDevice, stream);
  if (err != cudaSuccess) return err;
  allgather5<<<24, 1024, 0, stream>>>(rank, worldSize, nRanksPerNode, nelems, smChannel);
  return cudaGetLastError();
}

static size_t ncclTypeSize(ncclDataType_t type) {
  switch (type) {
    case ncclInt8:
    case ncclUint8:
      return 1;
    case ncclFloat16:
      return 2;
    case ncclInt32:
    case ncclUint32:
      return 4;
    case ncclInt64:
    case ncclUint64:
      return 8;
    case ncclFloat32:
      return 4;
    case ncclFloat64:
      return 8;
#if defined(__CUDA_BF16_TYPES_EXIST__)
    case ncclBfloat16:
      return 2;
#endif  // defined(__CUDA_BF16_TYPES_EXIST__)
#if defined(__CUDA_FP8_TYPES_EXIST__)
    case ncclFp8E4M3:
    case ncclFp8E5M2:
      return 1;
#endif  // defined(__CUDA_FP8_TYPES_EXIST__)
    case ncclNumTypes:
      return 0;
  }
  return 0;
}

static mscclpp::Transport getTransport(int rank, int peerRank) {
  // if (rank / nRanksPerNode == peerRank / nRanksPerNode) {
  //   return mscclpp::Transport::CudaIpc;
  // } else {
  //   return IBs[rank % nRanksPerNode];
  // }
  return mscclpp::Transport::CudaIpc;
}

static std::vector<mscclpp::RegisteredMemory> setupRemoteMemories(std::shared_ptr<mscclpp::Communicator> comm, int rank,
                                                                  void* buff, size_t bytes,
                                                                  mscclpp::TransportFlags transport) {
  std::vector<mscclpp::RegisteredMemory> remoteMemories;
  mscclpp::RegisteredMemory memory = comm->registerMemory(buff, bytes, transport);
  std::vector<mscclpp::NonblockingFuture<mscclpp::RegisteredMemory>> remoteRegMemoryFutures;
  for (int i = 0; i < comm->bootstrap()->getNranks(); i++) {
    if (i == rank) continue;
    remoteRegMemoryFutures.push_back(comm->recvMemoryOnSetup(i, 0));
    comm->sendMemoryOnSetup(memory, i, 0);
  }
  comm->setup();
  std::transform(remoteRegMemoryFutures.begin(), remoteRegMemoryFutures.end(), std::back_inserter(remoteMemories),
                 [](const auto& future) { return future.get(); });
  return remoteMemories;
}

static std::vector<mscclpp::SmChannel> setupSmChannels(ncclComm_t comm,
                                                       const std::vector<mscclpp::RegisteredMemory>& remoteMemories,
                                                       void* src) {
  std::vector<mscclpp::SmChannel> channels;
  std::vector<std::shared_ptr<mscclpp::SmDevice2DeviceSemaphore>>& smSemaphores = comm->smSemaphores;
  size_t nConnections = comm->connections.size();
  for (size_t idx = 0; idx < NUM_CHANNELS_PER_CONNECTION; ++idx) {
    for (size_t cid = 0; cid < nConnections; ++cid) {
      if (comm->connections[cid]->transport() == mscclpp::Transport::CudaIpc) {
        channels.emplace_back(smSemaphores[idx * nConnections + cid], remoteMemories[cid], src, nullptr);
      }
    }
  }
  return channels;
}

NCCL_API ncclResult_t ncclGetVersion(int* version) {
  if (version == nullptr) return ncclInvalidArgument;
  *version = MSCCLPP_VERSION;
  return ncclSuccess;
}

NCCL_API ncclResult_t ncclGetUniqueId(ncclUniqueId* uniqueId) {
  if (uniqueId == nullptr) return ncclInvalidArgument;
  if (MSCCLPP_UNIQUE_ID_BYTES != NCCL_UNIQUE_ID_BYTES) return ncclInternalError;
  mscclpp::UniqueId id = mscclpp::TcpBootstrap::createUniqueId();
  memcpy(uniqueId, &id, sizeof(ncclUniqueId));
  return ncclSuccess;
}

NCCL_API ncclResult_t ncclCommInitRankConfig(ncclComm_t* comm, int nranks, ncclUniqueId commId, int rank,
                                             ncclConfig_t* config) {
  // TODO: implement this function
  return ncclInternalError;
}

NCCL_API ncclResult_t ncclCommInitRank(ncclComm_t* comm, int nranks, ncclUniqueId commId, int rank) {
  if (comm == nullptr) return ncclInvalidArgument;
  if (nranks < 0 || rank < 0 || rank >= nranks) return ncclInvalidArgument;
  std::shared_ptr<mscclpp::TcpBootstrap> bootstrap = std::make_shared<mscclpp::TcpBootstrap>(rank, nranks);
  mscclpp::UniqueId id;
  memcpy(id.data(), &commId, sizeof(ncclUniqueId));
  bootstrap->initialize(id);
  std::shared_ptr<mscclpp::Communicator> mscclppComm = std::make_shared<mscclpp::Communicator>(bootstrap);
  std::vector<mscclpp::NonblockingFuture<std::shared_ptr<mscclpp::Connection>>> connectionFutures;

  for (int i = 0; i < mscclppComm->bootstrap()->getNranks(); i++) {
    if (i == rank) continue;
    mscclpp::Transport transport = getTransport(rank, i);
    connectionFutures.push_back(mscclppComm->connectOnSetup(i, 0, transport));
  }
  mscclppComm->setup();

  std::vector<std::shared_ptr<mscclpp::Connection>> connections;
  std::transform(connectionFutures.begin(), connectionFutures.end(), std::back_inserter(connections),
                 [](const auto& future) { return future.get(); });

  std::vector<std::shared_ptr<mscclpp::SmDevice2DeviceSemaphore>> smSemaphores;
  for (size_t idx = 0; idx < NUM_CHANNELS_PER_CONNECTION; ++idx) {
    for (size_t cid = 0; cid < connections.size(); ++cid) {
      if (connections[cid]->transport() == mscclpp::Transport::CudaIpc) {
        smSemaphores.emplace_back(
            std::make_shared<mscclpp::SmDevice2DeviceSemaphore>(*(mscclppComm), connections[cid]));
      }
    }
  }
  mscclppComm->setup();

  ncclComm* commPtr = new ncclComm();
  commPtr->comm = mscclppComm;
  commPtr->connections = std::move(connections);
  commPtr->smSemaphores = std::move(smSemaphores);
  // using scratch buffer for message size less then 1MB
  commPtr->scratchBuff = mscclpp::allocExtSharedCuda<char>(scratchSize);
  commPtr->remoteScratchRegMemories =
      setupRemoteMemories(commPtr->comm, rank, commPtr->scratchBuff.get(), scratchSize, mscclpp::Transport::CudaIpc);

  *comm = commPtr;
  return ncclSuccess;
}

NCCL_API ncclResult_t ncclCommInitAll(ncclComm_t* comm, int ndev, const int* devlist) {
  // TODO: implement this function
  return ncclInternalError;
}

NCCL_API ncclResult_t ncclCommFinalize(ncclComm_t comm) {
  comm->comm->bootstrap()->barrier();
  return ncclSuccess;
}

NCCL_API ncclResult_t ncclCommDestroy(ncclComm_t comm) {
  if (comm == nullptr) return ncclInvalidArgument;
  delete comm;
  return ncclSuccess;
}

NCCL_API ncclResult_t ncclCommAbort(ncclComm_t comm) {
  // TODO: implement this function
  return ncclSuccess;
}

NCCL_API ncclResult_t ncclCommSplit(ncclComm_t comm, int color, int key, ncclComm_t* newcomm, ncclConfig_t* config) {
  // TODO: implement this function
  return ncclInternalError;
}

NCCL_API const char* ncclGetErrorString(ncclResult_t result) {
  switch (result) {
    case ncclSuccess:
      return "no error";
    case ncclUnhandledCudaError:
      return "unhandled cuda error (run with NCCL_DEBUG=INFO for details)";
    case ncclSystemError:
      return "unhandled system error (run with NCCL_DEBUG=INFO for details)";
    case ncclInternalError:
      return "internal error - please report this issue to the NCCL developers";
    case ncclInvalidArgument:
      return "invalid argument (run with NCCL_DEBUG=WARN for details)";
    case ncclInvalidUsage:
      return "invalid usage (run with NCCL_DEBUG=WARN for details)";
    case ncclRemoteError:
      return "remote process exited or there was a network error";
    case ncclInProgress:
      return "NCCL operation in progress";
    default:
      return "unknown result code";
  }
}

NCCL_API const char* ncclGetLastError(ncclComm_t comm) {
  // TODO: implement this function
  return nullptr;
}

NCCL_API ncclResult_t ncclCommGetAsyncError(ncclComm_t comm, ncclResult_t* asyncError) {
  if (asyncError == nullptr) return ncclInvalidArgument;
  *asyncError = ncclSuccess;
  return ncclSuccess;
}

NCCL_API ncclResult_t ncclCommCount(const ncclComm_t comm, int* count) {
  if (comm == nullptr || count == nullptr) return ncclInvalidArgument;
  *count = comm->comm->bootstrap()->getNranks();
  return ncclSuccess;
}

NCCL_API ncclResult_t ncclCommCuDevice(const ncclComm_t comm, int* device) {
  if (comm == nullptr || device == nullptr) return ncclInvalidArgument;
  *device = comm->comm->bootstrap()->getRank();
  return ncclSuccess;
}

NCCL_API ncclResult_t ncclCommUserRank(const ncclComm_t comm, int* rank) {
  if (comm == nullptr || rank == nullptr) return ncclInvalidArgument;
  *rank = comm->comm->bootstrap()->getRank();
  return ncclSuccess;
}

NCCL_API ncclResult_t ncclRedOpCreatePreMulSum(ncclRedOp_t* op, void* scalar, ncclDataType_t datatype,
                                               ncclScalarResidence_t residence, ncclComm_t comm) {
  // TODO: implement this function
  return ncclInternalError;
}

NCCL_API ncclResult_t ncclRedOpDestroy(ncclRedOp_t op, ncclComm_t comm) {
  // TODO: implement this function
  return ncclInternalError;
}

NCCL_API ncclResult_t ncclReduce(const void* sendbuff, void* recvbuff, size_t count, ncclDataType_t datatype,
                                 ncclRedOp_t op, int root, ncclComm_t comm, cudaStream_t stream) {
  // TODO: implement this function
  return ncclInternalError;
}

NCCL_API ncclResult_t ncclBcast(void* buff, size_t count, ncclDataType_t datatype, int root, ncclComm_t comm,
                                cudaStream_t stream) {
  // TODO: implement this function
  return ncclInternalError;
}

NCCL_API ncclResult_t ncclBroadcast(const void* sendbuff, void* recvbuff, size_t count, ncclDataType_t datatype,
                                    int root, ncclComm_t comm, cudaStream_t stream) {
  // TODO: implement this function
  return ncclInternalError;
}

NCCL_API ncclResult_t ncclAllReduce(const void* sendbuff, void* recvbuff, size_t count, ncclDataType_t datatype,
                                    ncclRedOp_t op, ncclComm_t comm, cudaStream_t stream) {
  size_t bytes = count * ncclTypeSize(datatype);
  if (sendbuff == nullptr || recvbuff == nullptr || bytes == 0 || comm == nullptr) return ncclInvalidArgument;
  int rank = comm->comm->bootstrap()->getRank();
  channelKey key{sendbuff, recvbuff, bytes};
  /*if (bytes <= 1 << 20) {
    auto it = comm->channelInfos.find(key);
    if (it == comm->channelInfos.end()) {
      std::vector<mscclpp::SmChannel> channels =
          setupSmChannels(comm, comm->remoteScratchRegMemories, const_cast<void*>(sendbuff));
      std::vector<mscclpp::DeviceHandle<mscclpp::SmChannel>> smChannelDeviceHandles;
      std::transform(channels.begin(), channels.end(), std::back_inserter(smChannelDeviceHandles),
                     [](const mscclpp::SmChannel& smChannel) { return mscclpp::deviceHandle(smChannel); });
      ChannelInfo channelInfo{channels, {}, smChannelDeviceHandles, {}};
      it = comm->channelInfos.emplace(key, channelInfo).first;
    }
    CUDACHECK(cudaMemcpyToSymbolAsync(
        constSmChannels, it->second.smChannelDeviceHandles.data(),
        sizeof(mscclpp::DeviceHandle<mscclpp::SmChannel>) * it->second.smChannelDeviceHandles.size(), 0,
        cudaMemcpyHostToDevice, stream));
  } else {
    auto it = comm->channelInfos.find(key);
    if (it == comm->channelInfos.end()) {
      std::vector<mscclpp::RegisteredMemory> remoteMemories =
          setupRemoteMemories(comm->comm, rank, const_cast<void*>(sendbuff), bytes, mscclpp::Transport::CudaIpc);
      std::vector<mscclpp::SmChannel> channels = setupSmChannels(comm, remoteMemories, const_cast<void*>(sendbuff));
      std::vector<mscclpp::DeviceHandle<mscclpp::SmChannel>> smChannelDeviceHandles;
      std::transform(channels.begin(), channels.end(), std::back_inserter(smChannelDeviceHandles),
                     [](const mscclpp::SmChannel& smChannel) { return mscclpp::deviceHandle(smChannel); });
      ChannelInfo channelInfo{channels, {}, smChannelDeviceHandles, {}};
      it = comm->channelInfos.emplace(key, channelInfo).first;
      if (sendbuff != recvbuff) {
        std::vector<mscclpp::RegisteredMemory> remoteMemories =
            setupRemoteMemories(comm->comm, rank, recvbuff, bytes, mscclpp::Transport::CudaIpc);
        std::vector<mscclpp::SmChannel> outChannels = setupSmChannels(comm, remoteMemories, recvbuff);
        it->second.smOutChannels = outChannels;
        std::transform(outChannels.begin(), outChannels.end(), std::back_inserter(it->second.smOutChannelDeviceHandles),
                       [](const mscclpp::SmChannel& smChannel) { return mscclpp::deviceHandle(smChannel); });
      }
    }
    CUDACHECK(cudaMemcpyToSymbolAsync(
        constSmChannels, it->second.smChannelDeviceHandles.data(),
        sizeof(mscclpp::DeviceHandle<mscclpp::SmChannel>) * it->second.smChannelDeviceHandles.size(), 0,
        cudaMemcpyHostToDevice, stream));
    if (sendbuff != recvbuff) {
      CUDACHECK(cudaMemcpyToSymbolAsync(
          constSmOutChannels, it->second.smOutChannelDeviceHandles.data(),
          sizeof(mscclpp::DeviceHandle<mscclpp::SmChannel>) * it->second.smOutChannelDeviceHandles.size(), 0,
          cudaMemcpyHostToDevice, stream));
    } else {
      CUDACHECK(cudaMemcpyToSymbolAsync(
          constSmOutChannels, it->second.smChannelDeviceHandles.data(),
          sizeof(mscclpp::DeviceHandle<mscclpp::SmChannel>) * it->second.smChannelDeviceHandles.size(), 0,
          cudaMemcpyHostToDevice, stream));
    }
  }

  switch (datatype) {
    case ncclFloat16:
      CUDACHECK(allreduce((half*)sendbuff, (half*)comm->scratchBuff.get(), (half*)recvbuff, rank, nRanksPerNode,
                          comm->comm->bootstrap()->getNranks(), count, stream));
      break;
    case ncclFloat32:
      CUDACHECK(allreduce((float*)sendbuff, (float*)comm->scratchBuff.get(), (float*)recvbuff,
                          comm->comm->bootstrap()->getRank(), nRanksPerNode, comm->comm->bootstrap()->getNranks(),
                          count, stream));
      break;
    case ncclInt32:
    case ncclUint32:
      CUDACHECK(allreduce((int*)sendbuff, (int*)comm->scratchBuff.get(), (int*)recvbuff,
                          comm->comm->bootstrap()->getRank(), nRanksPerNode, comm->comm->bootstrap()->getNranks(),
                          count, stream));
      break;
    default:
      return ncclInvalidArgument;
  }*/
  return ncclSuccess;
}

NCCL_API ncclResult_t ncclReduceScatter(const void* sendbuff, void* recvbuff, size_t recvcount, ncclDataType_t datatype,
                                        ncclRedOp_t op, ncclComm_t comm, cudaStream_t stream) {
  // TODO: implement this function
  return ncclInternalError;
}

NCCL_API ncclResult_t ncclAllGather(const void* sendbuff, void* recvbuff, size_t sendcount, ncclDataType_t datatype,
                                    ncclComm_t comm, cudaStream_t stream) {
  size_t bytes = sendcount * ncclTypeSize(datatype);
  if (sendbuff == nullptr || recvbuff == nullptr || bytes == 0 || comm == nullptr) return ncclInvalidArgument;
  int rank = comm->comm->bootstrap()->getRank();
  int nRank = comm->comm->bootstrap()->getNranks();
  channelKey key{sendbuff, recvbuff, bytes};

  mscclpp::DeviceHandle<mscclpp::SmChannel> *constSmChannels;
  mscclpp::DeviceHandle<mscclpp::SmChannel> *constSmOutChannels;

  auto it = comm->channelInfos.find(key);
  if (it == comm->channelInfos.end()) {
    std::vector<mscclpp::RegisteredMemory> remoteMemories =
        setupRemoteMemories(comm->comm, rank, const_cast<void*>(recvbuff), bytes * nRank,
                            mscclpp::Transport::CudaIpc);
    std::vector<mscclpp::SmChannel> channels =
        setupSmChannels(comm, remoteMemories, const_cast<void*>(recvbuff));
    std::vector<mscclpp::DeviceHandle<mscclpp::SmChannel>> smChannelDeviceHandles;
    std::transform(channels.begin(), channels.end(), std::back_inserter(smChannelDeviceHandles),
                   [](const mscclpp::SmChannel& smChannel) { return mscclpp::deviceHandle(smChannel); });
  
    mscclpp::AvoidCudaGraphCaptureGuard cgcGuard;
    cudaMalloc((void**)&constSmChannels, sizeof(mscclpp::DeviceHandle<mscclpp::SmChannel>) * smChannelDeviceHandles.size());
    cudaMemcpy(constSmChannels, smChannelDeviceHandles.data(), sizeof(mscclpp::DeviceHandle<mscclpp::SmChannel>) * smChannelDeviceHandles.size(), cudaMemcpyHostToDevice);
    ChannelInfo channelInfo{channels, {}, constSmChannels, {}};
    it = comm->channelInfos.emplace(key, channelInfo).first;

  } else {
	constSmChannels = (mscclpp::DeviceHandle<mscclpp::SmChannel> *) it->second.smChannelDeviceHandles;	
  }

  // TODO: if sendbuff and recvbuff don't change, we can avoid copying smChannelDeviceHandles to device
  /*CUDACHECK(cudaMemcpyToSymbolAsync(
      constSmChannels, it->second.smChannelDeviceHandles.data(),
      sizeof(mscclpp::DeviceHandle<mscclpp::SmChannel>) * it->second.smChannelDeviceHandles.size(), 0,
      cudaMemcpyHostToDevice, stream));*/
  CUDACHECK(allgather((int*)sendbuff, (int*)comm->scratchBuff.get(), (int*)recvbuff,
                      rank, nRanksPerNode, nRank, bytes / sizeof(int), stream, constSmChannels));
  return ncclSuccess;
}

NCCL_API ncclResult_t ncclSend(const void* sendbuff, size_t count, ncclDataType_t datatype, int peer, ncclComm_t comm,
                               cudaStream_t stream) {
  // TODO: implement this function
  return ncclInternalError;
}

NCCL_API ncclResult_t ncclRecv(void* recvbuff, size_t count, ncclDataType_t datatype, int peer, ncclComm_t comm,
                               cudaStream_t stream) {
  // TODO: implement this function
  return ncclInternalError;
}

NCCL_API ncclResult_t ncclAllToAll(const void* sendbuff, void* recvbuff, size_t count, ncclDataType_t datatype,
                                   ncclComm_t comm, cudaStream_t stream) {
  // TODO: implement this function
  return ncclInternalError;
}

NCCL_API ncclResult_t ncclGroupStart() {
  // Do nothing
  return ncclSuccess;
}

NCCL_API ncclResult_t ncclGroupEnd() {
  // Do nothing
  return ncclSuccess;
}
