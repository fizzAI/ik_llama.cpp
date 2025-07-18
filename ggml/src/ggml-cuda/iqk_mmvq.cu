//
// Copyright (C) 2024 Iwan Kawrakow
// MIT license
// SPDX-License-Identifier: MIT
//

#include "iqk_mmvq.cuh"

typedef void (*vec_dot_q_cuda_t)(const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float *);

template<>
struct ggml_cuda_type_traits<GGML_TYPE_IQ1_M_R4> {
    static constexpr int qk = 32;
    static constexpr int qr = 2;
    static constexpr int qi = 4;
};

//  Reminder:
//    constexpr int qk  = ggml_cuda_type_traits<type>::qk;
//    constexpr int qi  = ggml_cuda_type_traits<type>::qi;
//    constexpr int vdr = get_vdr_mmvq(type);

// QI4_XS = 256/(4*2) = 32
// vdr = 4, qi = 32 -> qi/vdr = 8, kqs = 4*(tid%8),  blocks_per_iter = 4*1*32/32 = 4
// vdr = 2, qi = 32 -> qi/vdr =16, kqs = 2*(tid%16), blocks_per_iter = 2*1*32/32 = 2
namespace {
template <ggml_type type, int vdr, vec_dot_q_cuda_t vec_dot_q_cuda, int ncols_y, int n_interleaved = 1>
__device__ void iqk_mul_mat_vec_q(
    const void * __restrict__ vx, const void * __restrict__ vy, float * __restrict__ dst,
    const int ncols_x, const int nrows_x, const int nrows_y, const int nrows_dst, const int64_t row_size) {

    constexpr int qk  = ggml_cuda_type_traits<type>::qk;
    constexpr int qi  = ggml_cuda_type_traits<type>::qi;

#if defined(GGML_USE_HIPBLAS) && defined(__HIP_PLATFORM_AMD__) && (defined(RDNA2) || defined(RDNA3))
    constexpr int nwarps              = 1;
    constexpr int rows_per_cuda_block = n_interleaved;
#else
    constexpr int nwarps              = n_interleaved == 1 ? ncols_y <= 4 ? 4 : 2 : 1;
    constexpr int rows_per_cuda_block = n_interleaved == 1 ? ncols_y == 1 ? 1 : 2 : n_interleaved;
#endif // defined(GGML_USE_HIPBLAS) && defined(__HIP_PLATFORM_AMD__) && !defined(RDNA2) && !defined(RDNA3)

    const     int tid = WARP_SIZE*threadIdx.y + threadIdx.x;
    const     int row0 = rows_per_cuda_block*blockIdx.x;
    const     int blocks_per_row_x = ncols_x / qk;
    const     int blocks_per_col_y = nrows_y / QK8_1;
    constexpr int blocks_per_iter = vdr * nwarps*WARP_SIZE / qi;

// partial sum for each thread
    float tmp[ncols_y][rows_per_cuda_block] = {0.0f};

    const block_q8_1 * y = (const block_q8_1 *) vy;

    for (int kbx = tid / (qi/vdr); kbx < blocks_per_row_x; kbx += blocks_per_iter) {
        const int kby = kbx * (qk/QK8_1); // y block index that aligns with kbx

        // x block quant index when casting the quants to int
        const int kqs = vdr * (tid % (qi/vdr));

#pragma unroll
        for (int j = 0; j < ncols_y; ++j) {
            if constexpr (n_interleaved == 1) {
#pragma unroll
                for (int i = 0; i < rows_per_cuda_block; ++i) {
                    vec_dot_q_cuda((const void *)((const char *)vx + (row0 + i)*row_size),
                            &y[j*blocks_per_col_y + kby], kbx, kqs, &tmp[j][i]);
                }
            } else {
                vec_dot_q_cuda((const void *)((const char *)vx + row0*row_size),
                    &y[j*blocks_per_col_y + kby], kbx, kqs, tmp[j]);
            }
        }
    }

    __shared__ float tmp_shared[nwarps-1 > 0 ? nwarps-1 : 1][ncols_y][rows_per_cuda_block][WARP_SIZE];
    if (threadIdx.y > 0) {
#pragma unroll
        for (int j = 0; j < ncols_y; ++j) {
#pragma unroll
            for (int i = 0; i < rows_per_cuda_block; ++i) {
                tmp_shared[threadIdx.y-1][j][i][threadIdx.x] = tmp[j][i];
            }
        }
    }
    __syncthreads();
    if (threadIdx.y > 0) {
        return;
    }

    // sum up partial sums and write back result
#pragma unroll
    for (int j = 0; j < ncols_y; ++j) {
#pragma unroll
        for (int i = 0; i < rows_per_cuda_block; ++i) {
#pragma unroll
            for (int l = 0; l < nwarps-1; ++l) {
                tmp[j][i] += tmp_shared[l][j][i][threadIdx.x];
            }
            tmp[j][i] = warp_reduce_sum(tmp[j][i]);
        }

        if (threadIdx.x < rows_per_cuda_block && (rows_per_cuda_block == 1 || row0 + threadIdx.x < nrows_dst)) {
            dst[j*nrows_dst + row0 + threadIdx.x] = tmp[j][threadIdx.x];
        }
    }
}

template <ggml_type type, int vdr, vec_dot_q_cuda_t vec_dot_q_cuda, int ncols_y, int n_interleaved = 1>
#if !(defined(GGML_USE_HIPBLAS) && defined(__HIP_PLATFORM_AMD__))
// tell the compiler to use as many registers as it wants, see nwarps definition below
__launch_bounds__((ncols_y <= 4 ? 4 : 2)*WARP_SIZE, 1)
#endif // !(defined(GGML_USE_HIPBLAS) && defined(__HIP_PLATFORM_AMD__))
__global__ void iqk_mul_mat_vec_q(
    const void * __restrict__ vx, const void * __restrict__ vy, float * __restrict__ dst, const char * __restrict__ ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int nrows_dst, const int64_t row_size,
    const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, const int64_t ids_nb0) {
    int i2 = blockIdx.y;
    int i02 = ids_data ? *(const int *)(ids_data + i2*ids_nb0) : i2;
    if (i02 < 0) return;
    const char * cx = (const char *)vx + i02*nb02;
    const char * cy = (const char *)vy + i2*nb12;
    char * cdst = (char *)dst + i2*nb2;
    iqk_mul_mat_vec_q<type, vdr, vec_dot_q_cuda, ncols_y, n_interleaved>(cx, cy, (float *)cdst, ncols_x, nrows_x, nrows_y, nrows_dst, row_size);
}

template <ggml_type type, int vdr, vec_dot_q_cuda_t vec_dot_q_cuda, int n_interleaved = 1>
void iqk_mul_mat_vec_q_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    GGML_ASSERT(ncols_x % ggml_blck_size(type) == 0);
    //GGML_ASSERT(ncols_y <= MMVQ_MAX_BATCH_SIZE);

    int id = ggml_cuda_get_device();

    int64_t nwarps = 1;
    int64_t rows_per_cuda_block = n_interleaved;

    if (ggml_cuda_info().devices[id].cc < CC_RDNA2) { // NVIDIA and AMD older than RDNA2
        switch(ncols_y) {
            case 1:
                nwarps = n_interleaved == 1 ? 4 : 1;
                rows_per_cuda_block = n_interleaved == 1 ? 1 : n_interleaved;
                break;
            case 2:
            case 3:
            case 4:
                nwarps = n_interleaved == 1 ? 4 : 1;
                rows_per_cuda_block = n_interleaved == 1 ? 2 : n_interleaved;
                break;
            case 5:
            case 6:
            case 7:
            case 8:
                nwarps = n_interleaved == 1 ? 2 : 1;
                rows_per_cuda_block = n_interleaved == 1 ? 2 : n_interleaved;
                break;
            default:
                GGML_ASSERT(false);
                break;
        }
    }
    const int64_t nblocks = (nrows_x + rows_per_cuda_block - 1) / rows_per_cuda_block;
    const dim3 block_nums(nblocks, ne2, 1);
    const dim3 block_dims(WARP_SIZE, nwarps, 1);

    const int64_t row_size = ggml_row_size(type, ncols_x);

    switch (ncols_y) {
        case 1:
            iqk_mul_mat_vec_q<type, vdr, vec_dot_q_cuda, 1, n_interleaved><<<block_nums, block_dims, 0, stream>>>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, nrows_dst, row_size, nb02, nb12, nb2, ids_nb0);
            break;
        case 2:
            iqk_mul_mat_vec_q<type, vdr, vec_dot_q_cuda, 2, n_interleaved><<<block_nums, block_dims, 0, stream>>>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, nrows_dst, row_size, nb02, nb12, nb2, ids_nb0);
            break;
        case 3:
            iqk_mul_mat_vec_q<type, vdr, vec_dot_q_cuda, 3, n_interleaved><<<block_nums, block_dims, 0, stream>>>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, nrows_dst, row_size, nb02, nb12, nb2, ids_nb0);
            break;
        case 4:
            iqk_mul_mat_vec_q<type, vdr, vec_dot_q_cuda, 4, n_interleaved><<<block_nums, block_dims, 0, stream>>>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, nrows_dst, row_size, nb02, nb12, nb2, ids_nb0);
            break;
        case 5:
            iqk_mul_mat_vec_q<type, vdr, vec_dot_q_cuda, 5, n_interleaved><<<block_nums, block_dims, 0, stream>>>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, nrows_dst, row_size, nb02, nb12, nb2, ids_nb0);
            break;
        case 6:
            iqk_mul_mat_vec_q<type, vdr, vec_dot_q_cuda, 6, n_interleaved><<<block_nums, block_dims, 0, stream>>>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, nrows_dst, row_size, nb02, nb12, nb2, ids_nb0);
            break;
        case 7:
            iqk_mul_mat_vec_q<type, vdr, vec_dot_q_cuda, 7, n_interleaved><<<block_nums, block_dims, 0, stream>>>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, nrows_dst, row_size, nb02, nb12, nb2, ids_nb0);
            break;
        case 8:
            iqk_mul_mat_vec_q<type, vdr, vec_dot_q_cuda, 8, n_interleaved><<<block_nums, block_dims, 0, stream>>>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, nrows_dst, row_size, nb02, nb12, nb2, ids_nb0);
            break;
        default:
            GGML_ASSERT(false);
            break;
    }
}

__device__ __forceinline__ void get_int_from_table_16_shift(const uint32_t & q4, uint16_t shift, const uint8_t * all_values,
        int & val1, int & val2) {

    uint32_t aux32; const uint8_t * q8 = (const uint8_t *)&aux32;
    aux32 = q4 & 0x0f0f0f0f;
    const uint8_t * values = all_values + 16*(shift & 1);
    uint16_t v1 = values[q8[0]] | (values[q8[1]] << 8);
    uint16_t v2 = values[q8[2]] | (values[q8[3]] << 8);
    val1 = v1 | (v2 << 16);
    aux32 = (q4 >> 4) & 0x0f0f0f0f;
    values = all_values + 8*(shift & 2);
    v1 = values[q8[0]] | (values[q8[1]] << 8);
    v2 = values[q8[2]] | (values[q8[3]] << 8);
    val2 = v1 | (v2 << 16);
}

#define VDR_IQ4_K_Q8_1_MMVQ 4
#define VDR_IQ4_K_Q8_1_MMQ  4

__device__ __forceinline__ void vec_dot_iq4_k_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    const block_iq4_k * bq4 = (const block_iq4_k *) vbq + kbx;
    const uint8_t * all_values = (const uint8_t *)iq4k_values;

    // iqs is 0...28
    const int ib32 = iqs/4;
    // Why iqs/4 ?
    const int32_t  * q8 = (const int *)bq8_1[ib32].qs;
    const uint16_t * q4 = (const uint16_t *)bq4->qs + 8*ib32;
    const uint16_t extra = bq4->extra >> 2*ib32;
    int v1, v2;
    int sumi1 = 0, sumi2 = 0;
    for (int j = 0; j < 4; ++j) {
        const uint32_t aux32 = q4[2*j+0] | (q4[2*j+1] << 16);
        get_int_from_table_16_shift(aux32, extra, all_values, v1, v2);
        sumi1 = ggml_cuda_dp4a(v1, q8[j+0], sumi1);
        sumi2 = ggml_cuda_dp4a(v2, q8[j+4], sumi2);
    }
    const float d = __half2float(bq4->d) * __low2float(bq8_1[ib32].ds);
    const uint8_t sh = bq4->scales_h[ib32/2] >> 4*(ib32%2);
    const int ls1 = ((bq4->scales_l[ib32] & 0xf) | ((sh << 4) & 0x30)) - 32;
    const int ls2 = ((bq4->scales_l[ib32] >>  4) | ((sh << 2) & 0x30)) - 32;
    *result += d * (sumi1 * ls1 + sumi2 * ls2);
}

static __device__ __forceinline__ int2 get_int_from_table_16(const int & q4, const int8_t * values) {
    const int      q0_32  = (q4 >> 0) & 0x0F0F0F0F;
    const int8_t * q0_8   = (const int8_t *) &q0_32;
    const char4    val0_8 = make_char4(values[q0_8[0]], values[q0_8[1]], values[q0_8[2]], values[q0_8[3]]);

    const int      q1_32  = (q4 >> 4) & 0x0F0F0F0F;
    const int8_t * q1_8   = (const int8_t *) &q1_32;
    const char4    val1_8 = make_char4(values[q1_8[0]], values[q1_8[1]], values[q1_8[2]], values[q1_8[3]]);

    return make_int2(*((const int *) &val0_8), *((const int *) &val1_8));
}

__device__ __forceinline__ void vec_dot_iq4_k_r4_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    const block_iq4_k_r4 * bq4 = (const block_iq4_k_r4 *)vbq + kbx;

    // iqs is 0...28 in steps of 2
    const int ib16 = iqs/2;
    const float d8 = __low2float(bq8_1[ib16/2].ds);
    const int32_t  * q8 = (const int *)bq8_1[ib16/2].qs + 4*(ib16%2);

    int ib32 = ib16/2;
    int is   = ib16%2;
    int scales;
    const uint32_t * scales_l = (const uint32_t *)bq4->scales_l;
    const uint32_t * scales_h = (const uint32_t *)bq4->scales_h;
    scales = __vsub4(((scales_l[2*(ib32%4)+is] >> 4*(ib32/4)) & 0x0f0f0f0f) | (((scales_h[2*(ib32%2)+is] >> 2*(ib32/2)) & 0x03030303) << 4), 0x20202020);
    const int8_t * s8 = (const int8_t *)&scales;
    int2 val1;
    const int * q4 = (const int *)bq4->qs + 16*ib32;
    for (int i = 0; i < 4; ++i) {
        auto values1 = iq4k_values + (((bq4->extra[i+4*is] >> ib32) & 1) << 4);
        int sumi1 = 0;
        val1  = get_int_from_table_16(q4[i+4*is+0], values1);
        sumi1 = ggml_cuda_dp4a(val1.x, q8[0], ggml_cuda_dp4a(val1.y, q8[2], sumi1));
        val1  = get_int_from_table_16(q4[i+4*is+8], values1);
        sumi1 = ggml_cuda_dp4a(val1.x, q8[1], ggml_cuda_dp4a(val1.y, q8[3], sumi1));
        const float d = __half2float(bq4->d[i]) * d8;
        result[i] += d * sumi1 * s8[i];
    }
}

__device__ __forceinline__ void vec_dot_iq4_ks_r4_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    const float * dptr = (const float *)vbq;
    const block_iq4_ks_r4 * bq4 = (const block_iq4_ks_r4 *)(dptr + 4) + kbx;

    // iqs is 0...28 in steps of 2
    const int ib16 = iqs/2;
    const float d8 = __low2float(bq8_1[ib16/2].ds);
    const int32_t  * q8 = (const int *)bq8_1[ib16/2].qs + 4*(ib16%2);

    int ib32 = ib16/2;
    int is   = ib16%2;
    const uint32_t * scales32 = (const uint32_t *)bq4->scales;
    int scales = __vsub4(scales32[ib32] & 0xfefefefe, 0x7f7f7f7f);
    const int8_t * s8 = (const int8_t *)&scales;
    int2 val;
    const int * q4 = (const int *)bq4->qs + 16*ib32;
    for (int i = 0; i < 4; ++i) {
        auto values = iq4k_values + ((bq4->scales[4*ib32+i] & 1) << 4);
        int sumi = 0;
        val  = get_int_from_table_16(q4[i+4*is+0], values);
        sumi = ggml_cuda_dp4a(val.x, q8[0], ggml_cuda_dp4a(val.y, q8[2], sumi));
        val  = get_int_from_table_16(q4[i+4*is+8], values);
        sumi = ggml_cuda_dp4a(val.x, q8[1], ggml_cuda_dp4a(val.y, q8[3], sumi));
        const float d = dptr[i] * d8;
        result[i] += d * sumi * s8[i];
    }
}

__device__ __forceinline__ void vec_dot_iq1_s_r4_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    const half * dptr = (const half *)vbq;
    const block_iq1_s_r4 * bq1 = (const block_iq1_s_r4 *)(dptr + 4) + kbx;

    // iqs is 0 or 2
    const float d8 = __low2float(bq8_1->ds);
    const int32_t  * q8 = (const int *)bq8_1->qs;

    int32_t grid32[2];
    const int * igrid = (const int *)grid32;

    int minus = 0;
    for (int k = 0; k < 4; ++k) minus = ggml_cuda_dp4a(0x01010101, q8[4*(iqs/2)+k], minus);

    for (int i = 0; i < 4; ++i) {
        float dl = __half2float(dptr[i])*(2*((bq1->qh[i] >> 12) & 7) + 1) * d8;
        float ml = dl * (bq1->qh[i] & 0x8000 ? -1-IQ1S_DELTA : -1+IQ1S_DELTA);
        grid32[0] = iq1s_grid_gpu[bq1->qs[4*iqs+i] | (((bq1->qh[i] >> 3*iqs) & 7) << 8)];
        grid32[1] = (grid32[0] >> 4) & 0x0f0f0f0f;
        grid32[0] &= 0x0f0f0f0f;
        int sumi = ggml_cuda_dp4a(igrid[0], q8[4*(iqs/2)+0], ggml_cuda_dp4a(igrid[1], q8[4*(iqs/2)+1], 0));
        grid32[0] = iq1s_grid_gpu[bq1->qs[4*iqs+i+4] | (((bq1->qh[i] >> (3*iqs+3)) & 7) << 8)];
        grid32[1] = (grid32[0] >> 4) & 0x0f0f0f0f;
        grid32[0] &= 0x0f0f0f0f;
        sumi = ggml_cuda_dp4a(igrid[0], q8[4*(iqs/2)+2], ggml_cuda_dp4a(igrid[1], q8[4*(iqs/2)+3], sumi));
        result[i] += dl * sumi + ml * minus;
    }
}

__device__ __forceinline__ void vec_dot_iq1_m_r4_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    const half * dptr = (const half *)vbq;
    const block_iq1_m_r4 * bq1 = (const block_iq1_m_r4 *)(dptr + 4) + kbx;

    // iqs is 0 or 2
    const float d8 = __low2float(bq8_1->ds);
    const int32_t  * q8 = (const int *)bq8_1->qs;

    int32_t grid32[2];
    const int * igrid = (const int *)grid32;

    int minus1 = ggml_cuda_dp4a(0x01010101, q8[4*(iqs/2)+0], ggml_cuda_dp4a(0x01010101, q8[4*(iqs/2)+1], 0));
    int minus2 = ggml_cuda_dp4a(0x01010101, q8[4*(iqs/2)+2], ggml_cuda_dp4a(0x01010101, q8[4*(iqs/2)+3], 0));

    for (int i = 0; i < 4; ++i) {
        float dl = __half2float(dptr[i])*((bq1->scales[i] >> 4*(iqs/2)) & 0xf) * d8;
        float ml1 = dl * (bq1->qh[4*(iqs/2)+i] & 0x08 ? -1-IQ1M_DELTA : -1+IQ1M_DELTA);
        float ml2 = dl * (bq1->qh[4*(iqs/2)+i] & 0x80 ? -1-IQ1M_DELTA : -1+IQ1M_DELTA);
        grid32[0] = iq1s_grid_gpu[bq1->qs[4*iqs+i] | ((bq1->qh[4*(iqs/2)+i] & 0x07) << 8)];
        grid32[1] = (grid32[0] >> 4) & 0x0f0f0f0f;
        grid32[0] &= 0x0f0f0f0f;
        int sumi = ggml_cuda_dp4a(igrid[0], q8[4*(iqs/2)+0], ggml_cuda_dp4a(igrid[1], q8[4*(iqs/2)+1], 0));
        grid32[0] = iq1s_grid_gpu[bq1->qs[4*iqs+i+4] | ((bq1->qh[4*(iqs/2)+i] & 0x70) << 4)];
        grid32[1] = (grid32[0] >> 4) & 0x0f0f0f0f;
        grid32[0] &= 0x0f0f0f0f;
        sumi = ggml_cuda_dp4a(igrid[0], q8[4*(iqs/2)+2], ggml_cuda_dp4a(igrid[1], q8[4*(iqs/2)+3], sumi));
        result[i] += dl * sumi + ml1 * minus1 + ml2*minus2;
    }
}

#define VDR_IQ4_KS_Q8_1_MMVQ 4
#define VDR_IQ4_KS_Q8_1_MMQ  4

__device__ __forceinline__ void vec_dot_iq4_ks_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    float scale = *(const float *)vbq;
    const block_iq4_ks * bq4 = (const block_iq4_ks *)((const char *)vbq + sizeof(float)) + kbx;
    const uint8_t * all_values = (const uint8_t *)iq4k_values;

    // iqs is 0...28
    const int ib32 = iqs/4; // Why iqs/4 ?
    const int32_t  * q8 = (const int *)bq8_1[ib32].qs;
    const uint32_t * q4 = (const uint32_t *)bq4->qs + 4*ib32;
    const float dl = scale * ((bq4->scales[ib32] & 254) - 127);
    int v1, v2;
    int sumi = 0;
    for (int j = 0; j < 4; ++j) {
        get_int_from_table_16_shift(q4[j], bq4->scales[ib32] & 1, all_values, v1, v2);
        sumi = ggml_cuda_dp4a(v1, q8[j+0], sumi);
        sumi = ggml_cuda_dp4a(v2, q8[j+4], sumi);
    }
    *result += dl * __low2float(bq8_1[ib32].ds) * sumi;
}

__device__ __forceinline__ void vec_dot_iq4_kt_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    constexpr uint32_t ka = 0xCBAC1FED;
    constexpr uint32_t km = 0x3f3f3f3f;

    float scale = *(const float *)vbq;
    const block_iq4_kt * bq4 = (const block_iq4_kt *)((const char *)vbq + sizeof(float)) + kbx;

    // iqs is 0...28
    const int ib32 = iqs/4; // Why iqs/4 ?
    const int32_t  * q8 = (const int *)bq8_1[ib32].qs;
    //const int8_t  * q8 = bq8_1[ib32].qs;
    const int ls = (bq4->qs[ib32] & 0xff) >> 1;
    const float dl = scale * (ls - 64);
    const uint32_t idx0 = ((bq4->qs[ib32] & 1) << 15) + 4096;
    auto ql = (const uint8_t *)(bq4->qs + 8);
    auto qh = ql + 64;
    ql += 8*ib32;
    qh += 8*(ib32%4);
    const int shift1 = 8 - 4*(ib32/4);
    int sumi = 0;
    for (int j = 0; j < 8; ++j) {
        const uint32_t sh = bq4->qs[ib32] >> (8 + 3*j);
        uint32_t val = ql[j] + ((qh[j] << shift1) & 0xf00) + ((sh & 7) << 12) + idx0;
        int v4 = 0;
        for (int k = 0; k < 4; ++k) {
            val *= ka;
            //int s = val & km;
            //sumi += q8[4*j+k] * ggml_cuda_dp4a(s, 0x01010101, -126);
            v4 |= (ggml_cuda_dp4a(val & km, 0x01010101, -126) & 0xff) << 8*k;
        }
        sumi = ggml_cuda_dp4a(v4, q8[j], sumi);
    }
    *result += dl * __low2float(bq8_1[ib32].ds) * sumi;
}

__device__ __forceinline__ void vec_dot_iq2_kt_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    constexpr uint32_t ka = 0xCBAC1FED;
    constexpr uint32_t km = 0x3f3f3f3f;

    float scale = *(const float *)vbq;
    const block_iq2_kt * bq2 = (const block_iq2_kt *)((const char *)vbq + sizeof(float)) + kbx;

    // iqs is 0...28
    const int ib32 = iqs/4;
    const int32_t  * q8 = (const int *)bq8_1[ib32].qs;
    const int ls = iq4k_values[(bq2->scales[ib32%4] >> 4*(ib32/4)) & 0xf];
    const float dl = scale * ls * 1.05f;
    auto ql = (const uint16_t *)bq2->ql;
    int sumi = 0;
    for (int j = 0; j < 4; ++j) {
        uint32_t val = ql[4*ib32+j] + 4096;
        int v4 = 0;
        for (int k = 0; k < 4; ++k) {
            val *= ka;
            v4 |= (ggml_cuda_dp4a(val & km, 0x01010101, -126) & 0xff) << 8*k;
        }
        sumi = ggml_cuda_dp4a(v4, q8[2*j+0], sumi);
        v4 = 0;
        for (int k = 0; k < 4; ++k) {
            val *= ka;
            v4 |= (ggml_cuda_dp4a(val & km, 0x01010101, -126) & 0xff) << 8*k;
        }
        sumi = ggml_cuda_dp4a(v4, q8[2*j+1], sumi);
    }
    *result += dl * __low2float(bq8_1[ib32].ds) * sumi;
}

__device__ __forceinline__ void vec_dot_iq3_kt_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    constexpr uint32_t ka = 0xCBAC1FED;
    constexpr uint32_t km = 0x3f3f3f3f;

    float scale = *(const float *)vbq;
    const block_iq3_kt * bq3 = (const block_iq3_kt *)((const char *)vbq + sizeof(float)) + kbx;

    // iqs is 0...28
    const int ib32 = iqs/4;
    const int32_t  * q8 = (const int *)bq8_1[ib32].qs;
    const int ls = (bq3->scales[ib32%4] >> 4*(ib32/4)) & 0xf;
    const float dl = scale * ls * 1.015f;
    auto ql = (const uint16_t *)bq3->ql;
    uint32_t mask = 0x01010101 << ib32;
    const uint32_t * qh = (const uint32_t *)bq3->qh;
    int sumi = 0;
    for (int j = 0; j < 4; ++j) {
        uint32_t val = ql[4*ib32+j] + 4096;
        int v4 = 0;
        for (int k = 0; k < 4; ++k) {
            val *= ka;
            int8_t q = std::abs(ggml_cuda_dp4a(val & km, 0x01010101, -126));
            v4 |= q << 8*k;
        }
        uint32_t signs = __vcmpne4(qh[2*j+0] & mask, 0);
        v4 = __vsub4(v4 ^ signs, signs);
        sumi = ggml_cuda_dp4a(v4, q8[2*j+0], sumi);
        v4 = 0;
        for (int k = 0; k < 4; ++k) {
            val *= ka;
            int8_t q = std::abs(ggml_cuda_dp4a(val & km, 0x01010101, -126));
            v4 |= q << 8*k;
        }
        signs = __vcmpne4(qh[2*j+1] & mask, 0);
        v4 = __vsub4(v4 ^ signs, signs);
        sumi = ggml_cuda_dp4a(v4, q8[2*j+1], sumi);
    }
    *result += dl * __low2float(bq8_1[ib32].ds) * sumi;
}

#define VDR_IQ4_KSS_Q8_1_MMVQ 4
#define VDR_IQ4_KSS_Q8_1_MMQ  4

__device__ __forceinline__ void vec_dot_iq4_kss_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    float scale = *(const float *)vbq;
    const block_iq4_kss * bq4 = (const block_iq4_kss *)((const char *)vbq + sizeof(float)) + kbx;
    const uint8_t * all_values = (const uint8_t *)iq4k_values;

    // iqs is 0...28
    const int ib32 = iqs/4; // Why iqs/4 ?
    const int32_t  * q8 = (const int *)bq8_1[ib32].qs;
    const uint32_t * q4 = (const uint32_t *)bq4->qs + 4*ib32;
    uint32_t s32 = (q4[0] & 0x00010001) | ((q4[1] & 0x00010001) << 2) | ((q4[2] & 0x00010001) << 4) | ((q4[3] & 0x00010001) << 6);
    uint8_t ls = (s32 | (s32 >> 15)) & 0xff;
    const float dl = scale * ((ls & 254) - 127);
    int v1, v2;
    int sumi = 0;
    for (int j = 0; j < 4; ++j) {
        uint32_t aux32 = q4[j] & 0xfffefffe;
        aux32 ^= (aux32 >> 1);
        get_int_from_table_16_shift(aux32, ls & 1, all_values, v1, v2);
        sumi = ggml_cuda_dp4a(v1, q8[j+0], sumi);
        sumi = ggml_cuda_dp4a(v2, q8[j+4], sumi);
    }
    *result += dl * __low2float(bq8_1[ib32].ds) * sumi;
}

#define VDR_IQ5_K_Q8_1_MMVQ 4
#define VDR_IQ5_K_Q8_1_MMQ  4

__device__ __forceinline__ int int_from_table(const uint8_t * a8, const uint8_t * values) {
    uint16_t v1 = values[a8[0]] | (values[a8[1]] << 8);
    uint16_t v2 = values[a8[2]] | (values[a8[3]] << 8);
    return v1 | (v2 << 16);
}

__device__ __forceinline__ void vec_dot_iq5_k_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    const block_iq5_k * bq5 = (const block_iq5_k *) vbq + kbx;
    const uint8_t * all_values = (const uint8_t *)iq5nl_values;

    int i4 = iqs/4;  // 0...7.  Blocks of 16 index is 4*(i4/2) + (i4%2) + (0 and 2)

    const int32_t  * q8_1 = (const int *)bq8_1[2*(i4/2)+0].qs + 4*(i4%2);
    const int32_t  * q8_2 = (const int *)bq8_1[2*(i4/2)+1].qs + 4*(i4%2);
    const uint32_t * q4 = (const uint32_t *)bq5->qs + 8*(i4/2) + 4*(i4%2);
    const uint32_t * qh = (const uint32_t *)bq5->qh + 4*(i4%2);
    const uint16_t extra = bq5->extra >> (4*(i4/2) + (i4%2));
    const uint8_t * values1 = all_values + 32*(extra & 1);
    const uint8_t * values2 = all_values +  8*(extra & 4);
    uint32_t aux32[2];
    const uint8_t * a8 = (const uint8_t *)aux32;
    int v1, v2;
    int sumi1 = 0, sumi2 = 0;
    for (int j = 0; j < 4; ++j) {
        uint32_t h = qh[j] >> 2*(i4/2);
        aux32[0] = ((q4[j] >> 0) & 0x0f0f0f0f) | ((h << 4) & 0x10101010);
        aux32[1] = ((q4[j] >> 4) & 0x0f0f0f0f) | ((h << 3) & 0x10101010);
        v1 = int_from_table(a8+0, values1);
        v2 = int_from_table(a8+4, values2);
        sumi1 = ggml_cuda_dp4a(v1, q8_1[j], sumi1);
        sumi2 = ggml_cuda_dp4a(v2, q8_2[j], sumi2);
    }
    const float d5 = __half2float(bq5->d);
    const uint8_t sh = bq5->scales_h[i4/2] >> 2*(i4%2);
    const int ls1 = (((bq5->scales_l[2*(i4/2)+0] >> 4*(i4%2)) & 0xf) | ((sh << 4) & 0x30)) - 32;
    const int ls2 = (((bq5->scales_l[2*(i4/2)+1] >> 4*(i4%2)) & 0xf) | ((sh << 0) & 0x30)) - 32;
    *result += d5 * (__low2float(bq8_1[2*(i4/2)+0].ds) * sumi1 * ls1 + __low2float(bq8_1[2*(i4/2)+1].ds) * sumi2 * ls2);
}

__device__ __forceinline__ void vec_dot_iq5_k_r4_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    const block_iq5_k_r4 * bq5 = (const block_iq5_k_r4 *)vbq + kbx;

    // iqs is 0...28 in steps of 2
    const int ib16 = iqs/2;
    const float d8 = __low2float(bq8_1[ib16/2].ds);
    const int32_t  * q8 = (const int *)bq8_1[ib16/2].qs + 4*(ib16%2);

    int ib32 = ib16/2;
    int is   = ib16%2;
    int scales;
    const uint32_t * scales_l = (const uint32_t *)bq5->scales_l;
    const uint32_t * scales_h = (const uint32_t *)bq5->scales_h;
    scales = __vsub4(((scales_l[2*(ib32%4)+is] >> 4*(ib32/4)) & 0x0f0f0f0f) | (((scales_h[2*(ib32%2)+is] >> 2*(ib32/2)) & 0x03030303) << 4), 0x20202020);
    const int8_t * s8 = (const int8_t *)&scales;
    int2 val1;
    const int * q4 = (const int *)bq5->qs + 16*ib32;
    const int * qh = (const int *)bq5->qh +  4*ib32;
    int aux32[2];
    const uint8_t * aux8 = (const uint8_t *)aux32;
    for (int i = 0; i < 4; ++i) {
        auto values1 = iq5nl_values + (((bq5->extra[i+4*is] >> ib32) & 1) << 5);
        int sumi1 = 0;
        aux32[0] = ((q4[i+4*is+0] >> 0) & 0x0f0f0f0f) | (((qh[i] >> (2*is+0)) & 0x01010101) << 4);
        aux32[1] = ((q4[i+4*is+0] >> 4) & 0x0f0f0f0f) | (((qh[i] >> (2*is+1)) & 0x01010101) << 4);
        val1.x  = int_from_table(aux8+0, (const uint8_t *)values1);
        val1.y  = int_from_table(aux8+4, (const uint8_t *)values1);
        sumi1 = ggml_cuda_dp4a(val1.x, q8[0], ggml_cuda_dp4a(val1.y, q8[2], sumi1));
        aux32[0] = ((q4[i+4*is+8] >> 0) & 0x0f0f0f0f) | (((qh[i] >> (2*is+4)) & 0x01010101) << 4);
        aux32[1] = ((q4[i+4*is+8] >> 4) & 0x0f0f0f0f) | (((qh[i] >> (2*is+5)) & 0x01010101) << 4);
        val1.x  = int_from_table(aux8+0, (const uint8_t *)values1);
        val1.y  = int_from_table(aux8+4, (const uint8_t *)values1);
        sumi1 = ggml_cuda_dp4a(val1.x, q8[1], ggml_cuda_dp4a(val1.y, q8[3], sumi1));
        const float d = __half2float(bq5->d[i]) * d8;
        result[i] += d * sumi1 * s8[i];
    }
}

__device__ __forceinline__ void vec_dot_iq5_ks_r4_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    const float * dptr = (const float *)vbq;
    const block_iq5_ks_r4 * bq5 = (const block_iq5_ks_r4 *)(dptr + 4) + kbx;

    // iqs is 0...28 in steps of 2
    const int ib16 = iqs/2;
    const float d8 = __low2float(bq8_1[ib16/2].ds);
    const int32_t  * q8 = (const int *)bq8_1[ib16/2].qs + 4*(ib16%2);

    int ib32 = ib16/2;
    int is   = ib16%2;
    const uint32_t * scales32 = (const uint32_t *)bq5->scales;
    int scales = __vsub4(scales32[ib32] & 0xfefefefe, 0x7f7f7f7f);
    const int8_t * s8 = (const int8_t *)&scales;
    int2 val;
    const int * q4 = (const int *)bq5->qs + 16*ib32;
    const int * qh = (const int *)bq5->qh +  4*ib32;
    int aux32[2];
    const uint8_t * aux8 = (const uint8_t *)aux32;
    for (int i = 0; i < 4; ++i) {
        auto values = iq5nl_values + ((bq5->scales[4*ib32+i] & 1) << 5);
        int sumi = 0;
        aux32[0] = ((q4[i+4*is+0] >> 0) & 0x0f0f0f0f) | (((qh[i] >> (2*is+0)) & 0x01010101) << 4);
        aux32[1] = ((q4[i+4*is+0] >> 4) & 0x0f0f0f0f) | (((qh[i] >> (2*is+1)) & 0x01010101) << 4);
        val.x  = int_from_table(aux8+0, (const uint8_t *)values);
        val.y  = int_from_table(aux8+4, (const uint8_t *)values);
        sumi = ggml_cuda_dp4a(val.x, q8[0], ggml_cuda_dp4a(val.y, q8[2], sumi));
        aux32[0] = ((q4[i+4*is+8] >> 0) & 0x0f0f0f0f) | (((qh[i] >> (2*is+4)) & 0x01010101) << 4);
        aux32[1] = ((q4[i+4*is+8] >> 4) & 0x0f0f0f0f) | (((qh[i] >> (2*is+5)) & 0x01010101) << 4);
        val.x  = int_from_table(aux8+0, (const uint8_t *)values);
        val.y  = int_from_table(aux8+4, (const uint8_t *)values);
        sumi = ggml_cuda_dp4a(val.x, q8[1], ggml_cuda_dp4a(val.y, q8[3], sumi));
        result[i] += dptr[i] * d8 * sumi * s8[i];
    }
}

__device__ __forceinline__ void vec_dot_iq5_ks_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    float scale = *(const float *)vbq;
    const block_iq5_ks * bq5 = (const block_iq5_ks *)((const char *)vbq + sizeof(float)) + kbx;
    const uint8_t * all_values = (const uint8_t *)iq5nl_values;

    int i4 = iqs/4;  // 0...7.  Blocks of 16 index is 4*(i4/2) + (i4%2) + (0 and 2)

    const int32_t  * q8_1 = (const int *)bq8_1[2*(i4/2)+0].qs + 4*(i4%2);
    const int32_t  * q8_2 = (const int *)bq8_1[2*(i4/2)+1].qs + 4*(i4%2);
    const uint32_t * q4 = (const uint32_t *)bq5->qs + 8*(i4/2) + 4*(i4%2);
    const uint32_t * qh = (const uint32_t *)bq5->qh + 4*(i4%2);
    const uint8_t * values1 = all_values + ((bq5->scales[2*(i4/2)+0] & 1) << 5);
    const uint8_t * values2 = all_values + ((bq5->scales[2*(i4/2)+1] & 1) << 5);
    uint32_t aux32[2];
    const uint8_t * a8 = (const uint8_t *)aux32;
    int v1, v2;
    int sumi1 = 0, sumi2 = 0;
    for (int j = 0; j < 4; ++j) {
        uint32_t h = qh[j] >> 2*(i4/2);
        aux32[0] = ((q4[j] >> 0) & 0x0f0f0f0f) | ((h << 4) & 0x10101010);
        aux32[1] = ((q4[j] >> 4) & 0x0f0f0f0f) | ((h << 3) & 0x10101010);
        v1 = int_from_table(a8+0, values1);
        v2 = int_from_table(a8+4, values2);
        sumi1 = ggml_cuda_dp4a(v1, q8_1[j], sumi1);
        sumi2 = ggml_cuda_dp4a(v2, q8_2[j], sumi2);
    }
    const int ls1 = (bq5->scales[2*(i4/2)+0] & 254) - 127;
    const int ls2 = (bq5->scales[2*(i4/2)+1] & 254) - 127;
    *result += scale * (__low2float(bq8_1[2*(i4/2)+0].ds) * sumi1 * ls1 + __low2float(bq8_1[2*(i4/2)+1].ds) * sumi2 * ls2);
}

__device__ __forceinline__ void vec_dot_iq3_k_r4_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    const block_iq3_k_r4 * bq3 = (const block_iq3_k_r4 *)vbq + kbx;

    // iqs is 0...30 in steps of 2
    const int ib16 = iqs/2;
    const float d8 = __low2float(bq8_1[ib16/2].ds);
    const int32_t  * q8 = (const int *)bq8_1[ib16/2].qs + 4*(ib16%2);

    int ib32 = ib16/2;
    int is   = ib16%2;
    int scales[2];
    const uint32_t * scales_l = (const uint32_t *)bq3->scales_l;
    const uint32_t * scales_h = (const uint32_t *)bq3->scales_h;

    scales[0] = (((scales_l[2*(ib32%4)+is] >> 4*(ib32/4)) & 0x0f0f0f0f) << 1) | 0x01010101;
    scales[1] = (scales_h[is] >> ib32) & 0x01010101;
    // This is not faster. Why?
    //scales[1] = __vcmpeq4((scales_h[is] >> ib32) & 0x01010101, 0x01010101);
    //scales[0] = __vsub4(scales[0] ^ scales[1], scales[1]);
    const int8_t * s8 = (const int8_t *)scales;
    int2 val1;
    const int * q2 = (const int *)bq3->qs + 8*ib32 + 4*is;
    const int * qh = (const int *)bq3->qh + 4*ib32;
    int aux32[2];
    const uint8_t * aux8 = (const uint8_t *)aux32;
    for (int i = 0; i < 4; ++i) {
        auto values1 = iq3nl_values + (((bq3->extra[i+4*is] >> ib32) & 1) << 3);
        int sumi1 = 0;
        int h = qh[i] >> 4*is;
        aux32[0] = ((q2[i] >> 0) & 0x03030303) | ((h << 2) & 0x04040404);
        aux32[1] = ((q2[i] >> 2) & 0x03030303) | ((h << 1) & 0x04040404);
        val1.x  = int_from_table(aux8+0, (const uint8_t *)values1);
        val1.y  = int_from_table(aux8+4, (const uint8_t *)values1);
        sumi1 = ggml_cuda_dp4a(val1.x, q8[0], ggml_cuda_dp4a(val1.y, q8[1], sumi1));
        aux32[0] = ((q2[i] >> 4) & 0x03030303) | ((h >> 0) & 0x04040404);
        aux32[1] = ((q2[i] >> 6) & 0x03030303) | ((h >> 1) & 0x04040404);
        val1.x  = int_from_table(aux8+0, (const uint8_t *)values1);
        val1.y  = int_from_table(aux8+4, (const uint8_t *)values1);
        sumi1 = ggml_cuda_dp4a(val1.x, q8[2], ggml_cuda_dp4a(val1.y, q8[3], sumi1));
        const float d = __half2float(bq3->d[i]) * d8;
        result[i] += d * sumi1 * s8[i] * (s8[i+4] ? -1 : 1);
        //result[i] += d * sumi1 * s8[i];
    }
}

#define VDR_IQ6_K_Q8_1_MMVQ 4
#define VDR_IQ6_K_Q8_1_MMQ  4

__device__ __forceinline__ void vec_dot_iq6_k_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    const block_iq6_k * bq6 = (const block_iq6_k *) vbq + kbx;
    const uint8_t * all_values = (const uint8_t *)iq6nl_values;

    int i4 = iqs/4;  // 0...7.  Blocks of 16 index is 4*(i4/2) + (i4%2) + (0 and 2)
                     //         Blocks of 32 index is 2*(i4/2) + 0 or 1

    const int32_t  * q8_1 = (const int *)bq8_1[2*(i4/2)+0].qs + 4*(i4%2);
    const int32_t  * q8_2 = (const int *)bq8_1[2*(i4/2)+1].qs + 4*(i4%2);
    const uint32_t * q4 = (const uint32_t *)bq6->qs + 8*(i4/2) + 4*(i4%2);
    const uint32_t * qh = (const uint32_t *)bq6->qh + 8*(i4/4) + 4*(i4%2);
    const uint16_t extra = bq6->extra >> (4*(i4/2) + (i4%2));
    const uint8_t * values1 = all_values + 64*(extra & 1);
    const uint8_t * values2 = all_values + 16*(extra & 4);
    uint32_t aux32[2];
    const uint8_t * a8 = (const uint8_t *)aux32;
    int v1, v2;
    int sumi1 = 0, sumi2 = 0;
    for (int j = 0; j < 4; ++j) {
        uint32_t h = qh[j] >> 4*((i4/2)%2);
        aux32[0] = ((q4[j] >> 0) & 0x0f0f0f0f) | ((h << 4) & 0x30303030);
        aux32[1] = ((q4[j] >> 4) & 0x0f0f0f0f) | ((h << 2) & 0x30303030);
        v1 = int_from_table(a8+0, values1);
        v2 = int_from_table(a8+4, values2);
        sumi1 = ggml_cuda_dp4a(v1, q8_1[j], sumi1);
        sumi2 = ggml_cuda_dp4a(v2, q8_2[j], sumi2);
    }
    const float d6 = __half2float(bq6->d);
    *result += d6 * (__low2float(bq8_1[2*(i4/2)+0].ds) * sumi1 * bq6->scales[4*(i4/2)+(i4%2)] + __low2float(bq8_1[2*(i4/2)+1].ds) * sumi2 * bq6->scales[4*(i4/2)+(i4%2)+2]);
}

static const __device__ uint32_t iq2k_table[512] = {
    0xe1e1e1e1, 0xe1e1e1f3, 0xe1e1e101, 0xe1e1e111, 0xe1e1f3e1, 0xe1e1f3f3, 0xe1e1f301, 0xe1e1f311,
    0xe1e101e1, 0xe1e101f3, 0xe1e10101, 0xe1e10111, 0xe1e111e1, 0xe1e111f3, 0xe1e11101, 0xe1e11111,
    0xe1f3e1e1, 0xe1f3e1f3, 0xe1f3e101, 0xe1f3e111, 0xe1f3f3e1, 0xe1f3f3f3, 0xe1f3f301, 0xe1f3f311,
    0xe1f301e1, 0xe1f301f3, 0xe1f30101, 0xe1f30111, 0xe1f311e1, 0xe1f311f3, 0xe1f31101, 0xe1f31111,
    0xe101e1e1, 0xe101e1f3, 0xe101e101, 0xe101e111, 0xe101f3e1, 0xe101f3f3, 0xe101f301, 0xe101f311,
    0xe10101e1, 0xe10101f3, 0xe1010101, 0xe1010111, 0xe10111e1, 0xe10111f3, 0xe1011101, 0xe1011111,
    0xe111e1e1, 0xe111e1f3, 0xe111e101, 0xe111e111, 0xe111f3e1, 0xe111f3f3, 0xe111f301, 0xe111f311,
    0xe11101e1, 0xe11101f3, 0xe1110101, 0xe1110111, 0xe11111e1, 0xe11111f3, 0xe1111101, 0xe1111111,
    0xf3e1e1e1, 0xf3e1e1f3, 0xf3e1e101, 0xf3e1e111, 0xf3e1f3e1, 0xf3e1f3f3, 0xf3e1f301, 0xf3e1f311,
    0xf3e101e1, 0xf3e101f3, 0xf3e10101, 0xf3e10111, 0xf3e111e1, 0xf3e111f3, 0xf3e11101, 0xf3e11111,
    0xf3f3e1e1, 0xf3f3e1f3, 0xf3f3e101, 0xf3f3e111, 0xf3f3f3e1, 0xf3f3f3f3, 0xf3f3f301, 0xf3f3f311,
    0xf3f301e1, 0xf3f301f3, 0xf3f30101, 0xf3f30111, 0xf3f311e1, 0xf3f311f3, 0xf3f31101, 0xf3f31111,
    0xf301e1e1, 0xf301e1f3, 0xf301e101, 0xf301e111, 0xf301f3e1, 0xf301f3f3, 0xf301f301, 0xf301f311,
    0xf30101e1, 0xf30101f3, 0xf3010101, 0xf3010111, 0xf30111e1, 0xf30111f3, 0xf3011101, 0xf3011111,
    0xf311e1e1, 0xf311e1f3, 0xf311e101, 0xf311e111, 0xf311f3e1, 0xf311f3f3, 0xf311f301, 0xf311f311,
    0xf31101e1, 0xf31101f3, 0xf3110101, 0xf3110111, 0xf31111e1, 0xf31111f3, 0xf3111101, 0xf3111111,
    0x01e1e1e1, 0x01e1e1f3, 0x01e1e101, 0x01e1e111, 0x01e1f3e1, 0x01e1f3f3, 0x01e1f301, 0x01e1f311,
    0x01e101e1, 0x01e101f3, 0x01e10101, 0x01e10111, 0x01e111e1, 0x01e111f3, 0x01e11101, 0x01e11111,
    0x01f3e1e1, 0x01f3e1f3, 0x01f3e101, 0x01f3e111, 0x01f3f3e1, 0x01f3f3f3, 0x01f3f301, 0x01f3f311,
    0x01f301e1, 0x01f301f3, 0x01f30101, 0x01f30111, 0x01f311e1, 0x01f311f3, 0x01f31101, 0x01f31111,
    0x0101e1e1, 0x0101e1f3, 0x0101e101, 0x0101e111, 0x0101f3e1, 0x0101f3f3, 0x0101f301, 0x0101f311,
    0x010101e1, 0x010101f3, 0x01010101, 0x01010111, 0x010111e1, 0x010111f3, 0x01011101, 0x01011111,
    0x0111e1e1, 0x0111e1f3, 0x0111e101, 0x0111e111, 0x0111f3e1, 0x0111f3f3, 0x0111f301, 0x0111f311,
    0x011101e1, 0x011101f3, 0x01110101, 0x01110111, 0x011111e1, 0x011111f3, 0x01111101, 0x01111111,
    0x11e1e1e1, 0x11e1e1f3, 0x11e1e101, 0x11e1e111, 0x11e1f3e1, 0x11e1f3f3, 0x11e1f301, 0x11e1f311,
    0x11e101e1, 0x11e101f3, 0x11e10101, 0x11e10111, 0x11e111e1, 0x11e111f3, 0x11e11101, 0x11e11111,
    0x11f3e1e1, 0x11f3e1f3, 0x11f3e101, 0x11f3e111, 0x11f3f3e1, 0x11f3f3f3, 0x11f3f301, 0x11f3f311,
    0x11f301e1, 0x11f301f3, 0x11f30101, 0x11f30111, 0x11f311e1, 0x11f311f3, 0x11f31101, 0x11f31111,
    0x1101e1e1, 0x1101e1f3, 0x1101e101, 0x1101e111, 0x1101f3e1, 0x1101f3f3, 0x1101f301, 0x1101f311,
    0x110101e1, 0x110101f3, 0x11010101, 0x11010111, 0x110111e1, 0x110111f3, 0x11011101, 0x11011111,
    0x1111e1e1, 0x1111e1f3, 0x1111e101, 0x1111e111, 0x1111f3e1, 0x1111f3f3, 0x1111f301, 0x1111f311,
    0x111101e1, 0x111101f3, 0x11110101, 0x11110111, 0x111111e1, 0x111111f3, 0x11111101, 0x11111111,
    0xe6e6e6e6, 0xe6e6e6f8, 0xe6e6e606, 0xe6e6e616, 0xe6e6f8e6, 0xe6e6f8f8, 0xe6e6f806, 0xe6e6f816,
    0xe6e606e6, 0xe6e606f8, 0xe6e60606, 0xe6e60616, 0xe6e616e6, 0xe6e616f8, 0xe6e61606, 0xe6e61616,
    0xe6f8e6e6, 0xe6f8e6f8, 0xe6f8e606, 0xe6f8e616, 0xe6f8f8e6, 0xe6f8f8f8, 0xe6f8f806, 0xe6f8f816,
    0xe6f806e6, 0xe6f806f8, 0xe6f80606, 0xe6f80616, 0xe6f816e6, 0xe6f816f8, 0xe6f81606, 0xe6f81616,
    0xe606e6e6, 0xe606e6f8, 0xe606e606, 0xe606e616, 0xe606f8e6, 0xe606f8f8, 0xe606f806, 0xe606f816,
    0xe60606e6, 0xe60606f8, 0xe6060606, 0xe6060616, 0xe60616e6, 0xe60616f8, 0xe6061606, 0xe6061616,
    0xe616e6e6, 0xe616e6f8, 0xe616e606, 0xe616e616, 0xe616f8e6, 0xe616f8f8, 0xe616f806, 0xe616f816,
    0xe61606e6, 0xe61606f8, 0xe6160606, 0xe6160616, 0xe61616e6, 0xe61616f8, 0xe6161606, 0xe6161616,
    0xf8e6e6e6, 0xf8e6e6f8, 0xf8e6e606, 0xf8e6e616, 0xf8e6f8e6, 0xf8e6f8f8, 0xf8e6f806, 0xf8e6f816,
    0xf8e606e6, 0xf8e606f8, 0xf8e60606, 0xf8e60616, 0xf8e616e6, 0xf8e616f8, 0xf8e61606, 0xf8e61616,
    0xf8f8e6e6, 0xf8f8e6f8, 0xf8f8e606, 0xf8f8e616, 0xf8f8f8e6, 0xf8f8f8f8, 0xf8f8f806, 0xf8f8f816,
    0xf8f806e6, 0xf8f806f8, 0xf8f80606, 0xf8f80616, 0xf8f816e6, 0xf8f816f8, 0xf8f81606, 0xf8f81616,
    0xf806e6e6, 0xf806e6f8, 0xf806e606, 0xf806e616, 0xf806f8e6, 0xf806f8f8, 0xf806f806, 0xf806f816,
    0xf80606e6, 0xf80606f8, 0xf8060606, 0xf8060616, 0xf80616e6, 0xf80616f8, 0xf8061606, 0xf8061616,
    0xf816e6e6, 0xf816e6f8, 0xf816e606, 0xf816e616, 0xf816f8e6, 0xf816f8f8, 0xf816f806, 0xf816f816,
    0xf81606e6, 0xf81606f8, 0xf8160606, 0xf8160616, 0xf81616e6, 0xf81616f8, 0xf8161606, 0xf8161616,
    0x06e6e6e6, 0x06e6e6f8, 0x06e6e606, 0x06e6e616, 0x06e6f8e6, 0x06e6f8f8, 0x06e6f806, 0x06e6f816,
    0x06e606e6, 0x06e606f8, 0x06e60606, 0x06e60616, 0x06e616e6, 0x06e616f8, 0x06e61606, 0x06e61616,
    0x06f8e6e6, 0x06f8e6f8, 0x06f8e606, 0x06f8e616, 0x06f8f8e6, 0x06f8f8f8, 0x06f8f806, 0x06f8f816,
    0x06f806e6, 0x06f806f8, 0x06f80606, 0x06f80616, 0x06f816e6, 0x06f816f8, 0x06f81606, 0x06f81616,
    0x0606e6e6, 0x0606e6f8, 0x0606e606, 0x0606e616, 0x0606f8e6, 0x0606f8f8, 0x0606f806, 0x0606f816,
    0x060606e6, 0x060606f8, 0x06060606, 0x06060616, 0x060616e6, 0x060616f8, 0x06061606, 0x06061616,
    0x0616e6e6, 0x0616e6f8, 0x0616e606, 0x0616e616, 0x0616f8e6, 0x0616f8f8, 0x0616f806, 0x0616f816,
    0x061606e6, 0x061606f8, 0x06160606, 0x06160616, 0x061616e6, 0x061616f8, 0x06161606, 0x06161616,
    0x16e6e6e6, 0x16e6e6f8, 0x16e6e606, 0x16e6e616, 0x16e6f8e6, 0x16e6f8f8, 0x16e6f806, 0x16e6f816,
    0x16e606e6, 0x16e606f8, 0x16e60606, 0x16e60616, 0x16e616e6, 0x16e616f8, 0x16e61606, 0x16e61616,
    0x16f8e6e6, 0x16f8e6f8, 0x16f8e606, 0x16f8e616, 0x16f8f8e6, 0x16f8f8f8, 0x16f8f806, 0x16f8f816,
    0x16f806e6, 0x16f806f8, 0x16f80606, 0x16f80616, 0x16f816e6, 0x16f816f8, 0x16f81606, 0x16f81616,
    0x1606e6e6, 0x1606e6f8, 0x1606e606, 0x1606e616, 0x1606f8e6, 0x1606f8f8, 0x1606f806, 0x1606f816,
    0x160606e6, 0x160606f8, 0x16060606, 0x16060616, 0x160616e6, 0x160616f8, 0x16061606, 0x16061616,
    0x1616e6e6, 0x1616e6f8, 0x1616e606, 0x1616e616, 0x1616f8e6, 0x1616f8f8, 0x1616f806, 0x1616f816,
    0x161606e6, 0x161606f8, 0x16160606, 0x16160616, 0x161616e6, 0x161616f8, 0x16161606, 0x16161616,
};

__device__ __forceinline__ int int_from_table_4(const uint8_t * a8, const int * values) {
    return values[a8[0] | (a8[1] << 2) | (a8[2] << 4) | (a8[3] << 6)];
}

#define VDR_IQ2_K_Q8_1_MMVQ 4
#define VDR_IQ2_K_Q8_1_MMQ  4

__device__ __forceinline__ void vec_dot_iq2_k_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    // iqs is 0, 4, 8, 12, 16, 20, 24, 28
    // we have 16 packed quants (when cast to int)

    int i4 = iqs/4;  // 0...7. We will process q8 blocks 4*(i4/4), 4*(i4/4)+1, 4*(i4/4)+2, 4*(i4/4)+3
    const int32_t  * q8_1 = (const int *)bq8_1[4*(i4/4)+0].qs + 2*(i4%4);
    const int32_t  * q8_2 = (const int *)bq8_1[4*(i4/4)+1].qs + 2*(i4%4);
    const int32_t  * q8_3 = (const int *)bq8_1[4*(i4/4)+2].qs + 2*(i4%4);
    const int32_t  * q8_4 = (const int *)bq8_1[4*(i4/4)+3].qs + 2*(i4%4);

    const block_iq2_k * bq2 = (const block_iq2_k *) vbq + kbx;
    const uint32_t * q2 = (const uint32_t *)bq2->qs + 8*(i4/4) + 2*(i4%4);
    const uint16_t extra = bq2->extra >> (8*(i4/4) + (i4%4)/2);

    const int * all_values = (const int *)iq2k_table;
    const int * values;

    uint32_t val1 = q2[0], val2 = q2[1];

    uint32_t aux32[2];
    const uint8_t * a8 = (const uint8_t *)&aux32;
    int v1, v2;

    // Block of 16: (32*(4*(i4/4)+k)+8*(i4%4))/16 = 8*(i4/4) + 2*k + (i4%4)/2
    // -> scales_l[4*(i4/4) + k] >> 4*(((i4%4)/2)%2)

    const uint32_t * scales = (const uint32_t *)bq2->scales;
    uint32_t s32 = __vsub4((scales[i4/4] >> 4*(((i4%4)/2)%2)) & 0x0f0f0f0f, 0x08080808);
    const int8_t * s8 = (const int8_t *)&s32;

    aux32[0] = ((val1 >> 0) & 0x03030303); aux32[1] = ((val2 >> 0) & 0x03030303); values = all_values + ((extra & 0x01) << 8);
    v1 = int_from_table_4(a8 + 0, values);
    v2 = int_from_table_4(a8 + 4, values);
    int sumi1 = ggml_cuda_dp4a(v2, q8_1[1], ggml_cuda_dp4a(v1, q8_1[0], 0)) * s8[0];

    aux32[0] = ((val1 >> 2) & 0x03030303); aux32[1] = ((val2 >> 2) & 0x03030303); values = all_values + ((extra & 0x04) << 6);
    v1 = int_from_table_4(a8 + 0, values);
    v2 = int_from_table_4(a8 + 4, values);
    int sumi2 = ggml_cuda_dp4a(v2, q8_2[1], ggml_cuda_dp4a(v1, q8_2[0], 0)) * s8[1];

    aux32[0] = ((val1 >> 4) & 0x03030303); aux32[1] = ((val2 >> 4) & 0x03030303); values = all_values + ((extra & 0x10) << 4);
    v1 = int_from_table_4(a8 + 0, values);
    v2 = int_from_table_4(a8 + 4, values);
    int sumi3 = ggml_cuda_dp4a(v2, q8_3[1], ggml_cuda_dp4a(v1, q8_3[0], 0)) * s8[2];

    aux32[0] = ((val1 >> 6) & 0x03030303); aux32[1] = ((val2 >> 6) & 0x03030303); values = all_values + ((extra & 0x40) << 2);
    v1 = int_from_table_4(a8 + 0, values);
    v2 = int_from_table_4(a8 + 4, values);
    int sumi4 = ggml_cuda_dp4a(v2, q8_4[1], ggml_cuda_dp4a(v1, q8_4[0], 0)) * s8[3];

    *result += __half2float(bq2->d) * (__low2float(bq8_1[4*(i4/4)+0].ds) * sumi1
                                    +  __low2float(bq8_1[4*(i4/4)+1].ds) * sumi2
                                    +  __low2float(bq8_1[4*(i4/4)+2].ds) * sumi3
                                    +  __low2float(bq8_1[4*(i4/4)+3].ds) * sumi4);
}

#define VDR_IQ2_KS_Q8_1_MMVQ 4
#define VDR_IQ2_KS_Q8_1_MMQ  4

__device__ __forceinline__ void vec_dot_iq2_ks_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    float scale = *(const half *)vbq;
    const block_iq2_ks * bq2 = (const block_iq2_ks *)((const char *)vbq + sizeof(half)) + kbx;

    int i4 = iqs/4;  // 0...7. We will process q8 blocks 4*(i4/4), 4*(i4/4)+1, 4*(i4/4)+2, 4*(i4/4)+3
    const int32_t  * q8_1 = (const int *)bq8_1[4*(i4/4)+0].qs + 2*(i4%4);
    const int32_t  * q8_2 = (const int *)bq8_1[4*(i4/4)+1].qs + 2*(i4%4);
    const int32_t  * q8_3 = (const int *)bq8_1[4*(i4/4)+2].qs + 2*(i4%4);
    const int32_t  * q8_4 = (const int *)bq8_1[4*(i4/4)+3].qs + 2*(i4%4);

    const uint16_t * q2 = (const uint16_t *)bq2->qs + 16*(i4/4) + 4*(i4%4);
    const uint16_t extra = bq2->extra >> 4*(i4/4);

    const int * all_values = (const int *)iq2k_table;
    const int * values;

    uint32_t val1 = q2[0] | (q2[1] << 16), val2 = q2[2] | (q2[3] << 16);

    uint32_t aux32[2];
    const uint8_t * a8 = (const uint8_t *)&aux32;
    int v1, v2;

    int32_t scales32;
    const uint16_t * scales16 = (const uint16_t *)bq2->scales;
    scales32 = __vsub4((scales16[i4/4] | (scales16[i4/4] << 12)) & 0x0f0f0f0f, 0x10101010);
    int8_t * s8 = (int8_t *)&scales32;
    s8[0] += ((extra >> 4) & 0x10);
    s8[1] += ((extra >> 6) & 0x10);
    s8[2] += ((extra >> 5) & 0x10);
    s8[3] += ((extra >> 7) & 0x10);

    aux32[0] = ((val1 >> 0) & 0x03030303); aux32[1] = ((val2 >> 0) & 0x03030303); values = all_values + ((extra & 0x01) << 8);
    v1 = int_from_table_4(a8 + 0, values);
    v2 = int_from_table_4(a8 + 4, values);
    int sumi1 = ggml_cuda_dp4a(v2, q8_1[1], ggml_cuda_dp4a(v1, q8_1[0], 0)) * s8[0];

    aux32[0] = ((val1 >> 2) & 0x03030303); aux32[1] = ((val2 >> 2) & 0x03030303); values = all_values + ((extra & 0x02) << 7);
    v1 = int_from_table_4(a8 + 0, values);
    v2 = int_from_table_4(a8 + 4, values);
    int sumi2 = ggml_cuda_dp4a(v2, q8_2[1], ggml_cuda_dp4a(v1, q8_2[0], 0)) * s8[2];

    aux32[0] = ((val1 >> 4) & 0x03030303); aux32[1] = ((val2 >> 4) & 0x03030303); values = all_values + ((extra & 0x04) << 6);
    v1 = int_from_table_4(a8 + 0, values);
    v2 = int_from_table_4(a8 + 4, values);
    int sumi3 = ggml_cuda_dp4a(v2, q8_3[1], ggml_cuda_dp4a(v1, q8_3[0], 0)) * s8[1];

    aux32[0] = ((val1 >> 6) & 0x03030303); aux32[1] = ((val2 >> 6) & 0x03030303); values = all_values + ((extra & 0x08) << 5);
    v1 = int_from_table_4(a8 + 0, values);
    v2 = int_from_table_4(a8 + 4, values);
    int sumi4 = ggml_cuda_dp4a(v2, q8_4[1], ggml_cuda_dp4a(v1, q8_4[0], 0)) * s8[3];

    *result += scale * (__low2float(bq8_1[4*(i4/4)+0].ds) * sumi1
                     +  __low2float(bq8_1[4*(i4/4)+1].ds) * sumi2
                     +  __low2float(bq8_1[4*(i4/4)+2].ds) * sumi3
                     +  __low2float(bq8_1[4*(i4/4)+3].ds) * sumi4);
}

__device__ __forceinline__ void vec_dot_iq2_k_r4_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    const block_iq2_k_r4 * bq2 = (const block_iq2_k_r4 *)vbq + kbx;

    // iqs is 0...30 in steps of 2
    const int ib16 = iqs/2;
    const float d8 = __low2float(bq8_1[ib16/2].ds);
    const int32_t  * q8 = (const int *)bq8_1[ib16/2].qs + 4*(ib16%2);

    int ib32 = ib16/2;
    int is   = ib16%2;
    const int * scales_l = (const int *)bq2->scales;

    const int * all_values = (const int *)iq2k_table;

    int scales = __vsub4(((scales_l[2*(ib32%4)+is] >> 4*(ib32/4)) & 0x0f0f0f0f), 0x08080808);
    const int8_t * s8 = (const int8_t *)&scales;
    int2 val1;
    const int * q2 = (const int *)bq2->qs + 8*ib32 + 4*is;
    int aux32[2];
    const uint8_t * aux8 = (const uint8_t *)aux32;
#pragma unroll
    for (int i = 0; i < 4; ++i) {
        auto values1 = all_values + (((bq2->extra[i+4*is] >> ib32) & 1) << 8);
        int sumi1 = 0;
        aux32[0] = ((q2[i] >> 0) & 0x03030303);
        aux32[1] = ((q2[i] >> 2) & 0x03030303);
        val1.x  = int_from_table_4(aux8+0, values1);
        val1.y  = int_from_table_4(aux8+4, values1);
        sumi1 = ggml_cuda_dp4a(val1.x, q8[0], ggml_cuda_dp4a(val1.y, q8[1], sumi1));
        aux32[0] = ((q2[i] >> 4) & 0x03030303);
        aux32[1] = ((q2[i] >> 6) & 0x03030303);
        val1.x  = int_from_table_4(aux8+0, values1);
        val1.y  = int_from_table_4(aux8+4, values1);
        sumi1 = ggml_cuda_dp4a(val1.x, q8[2], ggml_cuda_dp4a(val1.y, q8[3], sumi1));
        const float d = __half2float(bq2->d[i]) * d8;
        result[i] += d * sumi1 * s8[i];
    }
}

#define VDR_IQ3_K_Q8_1_MMVQ 4
#define VDR_IQ3_K_Q8_1_MMQ  4

static const __device__ uint16_t iq3k_table[128] = {
    0xc1c1, 0xc1d8, 0xc1e9, 0xc1f6, 0xc101, 0xc10d, 0xc11c, 0xc12f, 0xd8c1, 0xd8d8, 0xd8e9, 0xd8f6, 0xd801, 0xd80d, 0xd81c, 0xd82f,
    0xe9c1, 0xe9d8, 0xe9e9, 0xe9f6, 0xe901, 0xe90d, 0xe91c, 0xe92f, 0xf6c1, 0xf6d8, 0xf6e9, 0xf6f6, 0xf601, 0xf60d, 0xf61c, 0xf62f,
    0x01c1, 0x01d8, 0x01e9, 0x01f6, 0x0101, 0x010d, 0x011c, 0x012f, 0x0dc1, 0x0dd8, 0x0de9, 0x0df6, 0x0d01, 0x0d0d, 0x0d1c, 0x0d2f,
    0x1cc1, 0x1cd8, 0x1ce9, 0x1cf6, 0x1c01, 0x1c0d, 0x1c1c, 0x1c2f, 0x2fc1, 0x2fd8, 0x2fe9, 0x2ff6, 0x2f01, 0x2f0d, 0x2f1c, 0x2f2f,
    0xc5c5, 0xc5dc, 0xc5ed, 0xc5fa, 0xc505, 0xc511, 0xc520, 0xc533, 0xdcc5, 0xdcdc, 0xdced, 0xdcfa, 0xdc05, 0xdc11, 0xdc20, 0xdc33,
    0xedc5, 0xeddc, 0xeded, 0xedfa, 0xed05, 0xed11, 0xed20, 0xed33, 0xfac5, 0xfadc, 0xfaed, 0xfafa, 0xfa05, 0xfa11, 0xfa20, 0xfa33,
    0x05c5, 0x05dc, 0x05ed, 0x05fa, 0x0505, 0x0511, 0x0520, 0x0533, 0x11c5, 0x11dc, 0x11ed, 0x11fa, 0x1105, 0x1111, 0x1120, 0x1133,
    0x20c5, 0x20dc, 0x20ed, 0x20fa, 0x2005, 0x2011, 0x2020, 0x2033, 0x33c5, 0x33dc, 0x33ed, 0x33fa, 0x3305, 0x3311, 0x3320, 0x3333,
};

__device__ __forceinline__ int int_from_table_2(const uint8_t * a8, const uint16_t * values) {
    return values[a8[0] | (a8[1] << 3)] | (values[a8[2] | (a8[3] << 3)] << 16);
}

__device__ __forceinline__ void vec_dot_iq3_k_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iiqs, float * result) {
    const block_iq3_k * bq3 = (const block_iq3_k *) vbq + kbx;

    int iqs = iiqs/4;
    const int ib128 = iqs/4;  // 0 or 1. 0 works on quants 0...127, 1 on quants 128...255
                              // Each thread processes 8 quants in each of the 4 32-blocks
    const int il8   = iqs%4;  // 0...3. 0 works on quants 0...7, 1 on quants 8...15, 2 on 16...23, 3 on 24...31
    const int shift = 4*(il8/2);

    const uint16_t * ql = (const uint16_t *)bq3->qs + 16*ib128 + 4*il8;
    const uint16_t * qh = (const uint16_t *)bq3->qh + 4*il8;

    uint32_t aux32;
    const uint8_t * aux8 = (const uint8_t *)&aux32;

    const int hshift = 4*(1-ib128);
    const uint16_t sh = bq3->scales_h >> (8*ib128 + il8/2);

    const uint8_t extra = bq3->extra >> (8*ib128 + il8/2);
    const uint16_t * values1 = iq3k_table + ((extra << 6) & 0x40);
    const uint16_t * values2 = iq3k_table + ((extra << 5) & 0x40);
    const uint16_t * values3 = iq3k_table + ((extra << 4) & 0x40);
    const uint16_t * values4 = iq3k_table + ((extra << 3) & 0x40);

    const int * q8;
    int sumi[4] = {0, 0, 0, 0};
    int v;
    for (int i = 0; i < 2; ++i) {
        uint32_t vl = ql[2*i+0] | (ql[2*i+1] << 16);
        uint32_t vh = ((qh[2*i+0] | (qh[2*i+1] << 16)) << hshift) >> 2;

        q8 = (const int *)bq8_1[4*ib128+0].qs + 2*il8;
        aux32 = (vl & 0x03030303) | (vh & 0x04040404);
        v = int_from_table_2(aux8, values1);
        sumi[0] = ggml_cuda_dp4a(v, q8[i], sumi[0]);
        vl >>= 2; vh >>= 1;

        q8 += sizeof(block_q8_1)/4;
        aux32 = (vl & 0x03030303) | (vh & 0x04040404);
        v = int_from_table_2(aux8, values2);
        sumi[1] = ggml_cuda_dp4a(v, q8[i], sumi[1]);
        vl >>= 2; vh >>= 1;

        q8 += sizeof(block_q8_1)/4;
        aux32 = (vl & 0x03030303) | (vh & 0x04040404);
        v = int_from_table_2(aux8, values3);
        sumi[2] = ggml_cuda_dp4a(v, q8[i], sumi[2]);
        vl >>= 2; vh >>= 1;

        q8 += sizeof(block_q8_1)/4;
        aux32 = (vl & 0x03030303) | (vh & 0x04040404);
        v = int_from_table_2(aux8, values4);
        sumi[3] = ggml_cuda_dp4a(v, q8[i], sumi[3]);

    }
    const float d = __half2float(bq3->d);
    const uint16_t * sl16 = (const uint16_t *)bq3->scales_l + 2*ib128;
    aux32 = ((((sl16[0] | (sl16[1] << 16)) >> shift) & 0x0f0f0f0f) << 1) | 0x01010101;
    *result += d * (__low2float(bq8_1[4*ib128+0].ds) * aux8[0] * (sh & 0x01 ? -1 : 1) * sumi[0] +
                    __low2float(bq8_1[4*ib128+1].ds) * aux8[1] * (sh & 0x04 ? -1 : 1) * sumi[1] +
                    __low2float(bq8_1[4*ib128+2].ds) * aux8[2] * (sh & 0x10 ? -1 : 1) * sumi[2] +
                    __low2float(bq8_1[4*ib128+3].ds) * aux8[3] * (sh & 0x40 ? -1 : 1) * sumi[3]);

}

__device__ __forceinline__ void vec_dot_iq3_ks_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iiqs, float * result) {

    float d = __half2float(*(const half *)vbq);
    const block_iq3_ks * bq3 = (const block_iq3_ks *)((const char *)vbq + sizeof(half)) + kbx;

    int iqs = iiqs/4;
    const int ib128 = iqs/4;  // 0 or 1. 0 works on quants 0...127, 1 on quants 128...255
                              // Each thread processes 8 quants in each of the 4 32-blocks
    const int il8   = iqs%4;  // 0...3. 0 works on quants 0...7, 1 on quants 8...15, 2 on 16...23, 3 on 24...31
    const int shift = 4*(il8/2);

    const uint16_t * ql = (const uint16_t *)bq3->qs + 16*ib128 + 4*il8;
    const uint16_t * qh = (const uint16_t *)bq3->qh + 4*il8;

    int32_t aux32;
    const uint8_t * aux8 = (const uint8_t *)&aux32;

    uint16_t extra = bq3->extra >> 4*ib128;
    uint16_t extra_v = extra >> 8;

    const uint16_t * values1 = iq3k_table + ((extra_v << 6) & 0x40);
    const uint16_t * values2 = iq3k_table + ((extra_v << 5) & 0x40);
    const uint16_t * values3 = iq3k_table + ((extra_v << 4) & 0x40);
    const uint16_t * values4 = iq3k_table + ((extra_v << 3) & 0x40);

    const int * q8;
    int sumi[4] = {0, 0, 0, 0};
    int v;
    for (int i = 0; i < 2; ++i) {
        uint32_t vl = ql[2*i+0] | (ql[2*i+1] << 16);
        uint32_t vh = ((qh[2*i+0] | (qh[2*i+1] << 16)) >> 4*ib128) << 2;

        q8 = (const int *)bq8_1[4*ib128+0].qs + 2*il8;
        aux32 = (vl & 0x03030303) | (vh & 0x04040404);
        v = int_from_table_2(aux8, values1);
        sumi[0] = ggml_cuda_dp4a(v, q8[i], sumi[0]);
        vl >>= 2; vh >>= 1;

        q8 += sizeof(block_q8_1)/4;
        aux32 = (vl & 0x03030303) | (vh & 0x04040404);
        v = int_from_table_2(aux8, values2);
        sumi[1] = ggml_cuda_dp4a(v, q8[i], sumi[1]);
        vl >>= 2; vh >>= 1;

        q8 += sizeof(block_q8_1)/4;
        aux32 = (vl & 0x03030303) | (vh & 0x04040404);
        v = int_from_table_2(aux8, values3);
        sumi[2] = ggml_cuda_dp4a(v, q8[i], sumi[2]);
        vl >>= 2; vh >>= 1;

        q8 += sizeof(block_q8_1)/4;
        aux32 = (vl & 0x03030303) | (vh & 0x04040404);
        v = int_from_table_2(aux8, values4);
        sumi[3] = ggml_cuda_dp4a(v, q8[i], sumi[3]);

    }
    const uint16_t * sl16 = (const uint16_t *)bq3->scales;
    aux32 = __vsub4(((sl16[0] | (sl16[1] << 16)) >> 4*ib128) & 0x0f0f0f0f, 0x10101010);
    const int8_t * a8 = (const int8_t *)&aux32;
    *result += d * (__low2float(bq8_1[4*ib128+0].ds) * (a8[0] + ((extra << 4) & 0x10)) * sumi[0] +
                    __low2float(bq8_1[4*ib128+1].ds) * (a8[1] + ((extra << 3) & 0x10)) * sumi[1] +
                    __low2float(bq8_1[4*ib128+2].ds) * (a8[2] + ((extra << 2) & 0x10)) * sumi[2] +
                    __low2float(bq8_1[4*ib128+3].ds) * (a8[3] + ((extra << 1) & 0x10)) * sumi[3]);

}

__device__ __forceinline__ void vec_dot_iq1_bn_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    half d16; memcpy(&d16, vbq, sizeof(d16));
    float scale = d16;
    const block_iq1_bn * bq1 = (const block_iq1_bn *)((const char *)vbq + sizeof(d16)) + kbx;

    // iqs is 0 or 1

    int sumi = 0;
#if __CUDA_ARCH__ >= MIN_CC_DP4A // lowest compute capability for integer intrinsics
    uint16_t mult[2];
    mult[1] = iqs == 0 ? 27 : 3;
    mult[0] = mult[1] + (mult[1] << 1);
    const int * q8 = (const int *)bq8_1[iqs].qs;
    int val[4];
    for (int l = 0; l < 2; ++l) {
        int8_t * a = (int8_t *)val;
        const int i16 = 2*iqs + l;
        for (int k = 0; k < 3; ++k) {
            uint16_t q = bq1->ql[3*i16+k];
            for (int j = 4; j >= 0; --j) {
                uint16_t v = q & 0xff;
                v += v << 1;
                a[j] = v >> 8;
                q += q << 1;
            }
            a += 5;
        }
        uint16_t v = (mult[l]*bq1->extra) & 0xff;
        v += v << 1;
        *a = v >> 8;
        sumi = __dp4a(val[0], q8[4*l+0], __dp4a(val[1], q8[4*l+1], __dp4a(val[2], q8[4*l+2], __dp4a(val[3], q8[4*l+3], sumi))));
    }
    float2 d8 = __half22float2(bq8_1[iqs].ds);
    *result += scale * (d8.x * sumi - d8.y);
#else
    static const uint16_t k_mult[5] = {81, 27, 9, 3, 1};
    const int8_t * q8 = bq8_1[iqs].qs;
    for (int l = 0; l < 2; ++l) {
        const int i16 = 2*iqs + l;
        for (int k = 0; k < 3; ++k) {
            uint8_t q = bq1->ql[3*i16+k];
            for (int j = 0; j < 5; ++j) {
                uint8_t v = k_mult[j]*q;
                int8_t vs = (v + (v >> 1)) >> 7;
                sumi += q8[j]*(vs - 1);
            }
            q8 += 5;
        }
        uint8_t v = k_mult[i16]*bq1->extra;
        int8_t vs = (v + (v >> 1)) >> 7;
        sumi += q8[0]*(vs - 1);
        q8++;
    }
    *result += scale * __low2float(bq8_1[iqs].ds) * sumi;
#endif
}

__device__ __forceinline__ void vec_dot_iq2_bn_q8_1(
    const void * __restrict__ vbq, const block_q8_1 * __restrict__ bq8_1, const int & kbx, const int & iqs, float * result) {

    float scale = *(const float *)vbq;
    const block_iq2_bn * bq2 = (const block_iq2_bn *)((const char *)vbq + sizeof(float)) + kbx;

    // iqs is 0 or 1

#if __CUDA_ARCH__ >= MIN_CC_DP4A // lowest compute capability for integer intrinsics
    auto qs  = (const int *)bq2->qs + 2*iqs;
    auto q8l = (const int *)bq8_1[0].qs + 2*iqs;
    auto q8h = (const int *)bq8_1[1].qs + 2*iqs;
    int sumi1 = 0, sumi2 = 0, sumi3 = 0, sumi4 = 0;
    for (int j = 0; j < 2; ++j) {
        int vl = qs[j];
        int vh = qs[j] >> 4;
        sumi1 = __dp4a(vl & 0x03030303, q8l[j+0], sumi1);
        sumi2 = __dp4a(vl & 0x0c0c0c0c, q8l[j+4], sumi2);
        sumi3 = __dp4a(vh & 0x03030303, q8h[j+0], sumi3);
        sumi4 = __dp4a(vh & 0x0c0c0c0c, q8h[j+4], sumi4);
    }
    auto d8l = __half22float2(bq8_1[0].ds);
    auto d8h = __half22float2(bq8_1[1].ds);
    *result += scale * (d8l.x * (sumi1 + 0.25f*sumi2) + d8h.x * (sumi3 + 0.25f * sumi4) - 0.5f*d8l.y - 0.5f*d8h.y);
#else
    int sumi1 = 0, sumi2 = 0, sumi3 = 0, sumi4 = 0;
    auto q8l = bq8_1[0].qs + 8*iqs;
    auto q8h = bq8_1[1].qs + 8*iqs;
    auto qs  = bq2->qs + 8*iqs;
    for (int j = 0; j < 8; ++j) {
        sumi1 += q8l[j+ 0] * (qs[j] & 0x03);
        sumi2 += q8l[j+16] * (qs[j] & 0x0c);
        sumi3 += q8h[j+ 0] * (qs[j] & 0x30);
        sumi4 += q8h[j+16] * (qs[j] & 0xc0);
    }
    auto d8l = __half22float2(bq8_1[0].ds);
    auto d8h = __half22float2(bq8_1[1].ds);
    *result += scale * (d8l.x * (sumi1 + 0.25f*sumi2) + 0.0625f * d8h.x*(sumi3 + 0.25f*sumi4) - 0.5f*d8l.y - 0.5f*d8h.y);
#endif
}

} // namespace

void mul_mat_vec_iq2_k_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ2_K, VDR_IQ2_K_Q8_1_MMVQ, vec_dot_iq2_k_q8_1>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq3_k_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ3_K, VDR_IQ3_K_Q8_1_MMVQ, vec_dot_iq3_k_q8_1>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq4_k_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ4_K, VDR_IQ4_K_Q8_1_MMVQ, vec_dot_iq4_k_q8_1>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq4_k_r4_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ4_K_R4, 2, vec_dot_iq4_k_r4_q8_1, 4>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq4_ks_r4_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ4_KS_R4, 2, vec_dot_iq4_ks_r4_q8_1, 4>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq1_s_r4_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ1_S_R4, 2, vec_dot_iq1_s_r4_q8_1, 4>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq1_m_r4_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ1_M_R4, 2, vec_dot_iq1_m_r4_q8_1, 4>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq5_k_r4_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ5_K_R4, 2, vec_dot_iq5_k_r4_q8_1, 4>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq5_ks_r4_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ5_KS_R4, 2, vec_dot_iq5_ks_r4_q8_1, 4>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq2_k_r4_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ2_K_R4, 2, vec_dot_iq2_k_r4_q8_1, 4>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq3_k_r4_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ3_K_R4, 2, vec_dot_iq3_k_r4_q8_1, 4>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq4_ks_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ4_KS, VDR_IQ4_KS_Q8_1_MMVQ, vec_dot_iq4_ks_q8_1>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq3_ks_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ3_KS, VDR_IQ3_K_Q8_1_MMVQ, vec_dot_iq3_ks_q8_1>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq4_kt_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ4_KT, VDR_IQ4_KS_Q8_1_MMVQ, vec_dot_iq4_kt_q8_1>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq2_kt_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ2_KT, VDR_IQ4_KS_Q8_1_MMVQ, vec_dot_iq2_kt_q8_1>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq3_kt_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ3_KT, VDR_IQ4_KS_Q8_1_MMVQ, vec_dot_iq3_kt_q8_1>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq4_kss_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ4_KSS, VDR_IQ4_KSS_Q8_1_MMVQ, vec_dot_iq4_kss_q8_1>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq2_ks_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ2_KS, VDR_IQ2_KS_Q8_1_MMVQ, vec_dot_iq2_ks_q8_1>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq5_k_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ5_K, VDR_IQ5_K_Q8_1_MMVQ, vec_dot_iq5_k_q8_1>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq5_ks_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ5_KS, VDR_IQ5_K_Q8_1_MMVQ, vec_dot_iq5_ks_q8_1>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq6_k_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {

    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ6_K, VDR_IQ6_K_Q8_1_MMVQ, vec_dot_iq6_k_q8_1>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq1_bn_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {
    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ1_BN, 1, vec_dot_iq1_bn_q8_1>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}

void mul_mat_vec_iq2_bn_q8_1_cuda(
    const void * vx, const void * vy, float * dst, const char * ids_data,
    const int ncols_x, const int nrows_x, const int nrows_y, const int ncols_y, const int nrows_dst,
    const int ne2, const uint64_t nb02, const uint64_t nb12, const uint64_t nb2, int64_t ids_nb0, cudaStream_t stream) {
    iqk_mul_mat_vec_q_cuda<GGML_TYPE_IQ2_BN, 1, vec_dot_iq2_bn_q8_1>(vx, vy, dst, ids_data, ncols_x, nrows_x, nrows_y, ncols_y, nrows_dst, ne2, nb02, nb12, nb2, ids_nb0, stream);
}
