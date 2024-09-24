// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

#ifndef NCCL_COMMON_HPP_
#define NCCL_COMMON_HPP_

#if defined(__HIP_PLATFORM_AMD__)
#define WARP_SIZE 64
#define __syncwarp() __builtin_amdgcn_wave_barrier()
#else
#define WARP_SIZE 32
#endif

constexpr int NRANKS1_PER_NODE = 4;
constexpr int NRANKS_PER_NODE = 8;
constexpr int NPEER = 7;

constexpr int SCRATCH_SIZE = 12 * 2 * 1024 * 1024 * 70;  // double buffer * 35 thread-blocks * 8 ranks * 256KB = 70MB

#endif  // NCCL_COMMON_HPP_
