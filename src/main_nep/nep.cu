/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, Mikko Ervasti, and Ari Harju
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/

/*----------------------------------------------------------------------------80
The neuroevolution potential (NEP)
Ref: Zheyong Fan et al., in preparation.
------------------------------------------------------------------------------*/

#include "dataset.cuh"
#include "mic.cuh"
#include "nep.cuh"
#include "parameters.cuh"
#include "utilities/error.cuh"
#include "utilities/gpu_vector.cuh"

const int SIZE_BOX_AND_INVERSE_BOX = 18;  // (3 * 3) * 2
const int MAX_NUM_NEURONS_PER_LAYER = 50; // largest ANN: input-50-50-output
const int MAX_NUM_N = 13;                 // n_max+1 = 12+1
const int MAX_NUM_L = 7;                  // L_max+1 = 6+1
const int MAX_DIM = MAX_NUM_N * MAX_NUM_L;
__constant__ float c_parameters[10000]; // less than 64 KB maximum

static __device__ void find_fc(float rc, float rcinv, float d12, float& fc)
{
  if (d12 < rc) {
    float x = d12 * rcinv;
    fc = 0.5f * cos(3.1415927f * x) + 0.5f;
  } else {
    fc = 0.0f;
  }
}

static __device__ void find_fc_and_fcp(float rc, float rcinv, float d12, float& fc, float& fcp)
{
  if (d12 < rc) {
    float x = d12 * rcinv;
    fc = 0.5f * cos(3.1415927f * x) + 0.5f;
    fcp = -1.5707963f * sin(3.1415927f * x);
    fcp *= rcinv;
  } else {
    fc = 0.0f;
    fcp = 0.0f;
  }
}

static __device__ __forceinline__ void
find_fn(const int n_max, const float rcinv, const float d12, const float fc12, float* fn)
{
  float x = 2.0f * (d12 * rcinv - 1.0f) * (d12 * rcinv - 1.0f) - 1.0f;
  fn[0] = 1.0f;
  fn[1] = x;
  for (int m = 2; m <= n_max; ++m) {
    fn[m] = 2.0f * x * fn[m - 1] - fn[m - 2];
  }
  for (int m = 0; m <= n_max; ++m) {
    fn[m] = (fn[m] + 1.0f) * 0.5f * fc12;
  }
}

static __device__ __forceinline__ void find_fn_and_fnp(
  const int n_max,
  const float rcinv,
  const float d12,
  const float fc12,
  const float fcp12,
  float* fn,
  float* fnp)
{
  float x = 2.0f * (d12 * rcinv - 1.0f) * (d12 * rcinv - 1.0f) - 1.0f;
  fn[0] = 1.0f;
  fnp[0] = 0.0f;
  fn[1] = x;
  fnp[1] = 1.0f;
  float u0 = 1.0f;
  float u1 = 2.0f * x;
  float u2;
  for (int m = 2; m <= n_max; ++m) {
    fn[m] = 2.0f * x * fn[m - 1] - fn[m - 2];
    fnp[m] = m * u1;
    u2 = 2.0f * x * u1 - u0;
    u0 = u1;
    u1 = u2;
  }
  for (int m = 0; m <= n_max; ++m) {
    fn[m] = (fn[m] + 1.0f) * 0.5f;
    fnp[m] *= 2.0f * (d12 * rcinv - 1.0f) * rcinv;
    fnp[m] = fnp[m] * fc12 + fn[m] * fcp12;
    fn[m] *= fc12;
  }
}

static __device__ __forceinline__ void
find_poly_cos(const int L_max, const float x, float* poly_cos)
{
  poly_cos[0] = 0.079577471545948f;
  poly_cos[1] = 0.238732414637843f * x;
  float x2 = x * x;
  poly_cos[2] = 0.596831036594608f * x2 - 0.198943678864869f;
  float x3 = x2 * x;
  poly_cos[3] = 1.392605752054084f * x3 - 0.835563451232451f * x;
  float x4 = x3 * x;
  poly_cos[4] = 3.133362942121690f * x4 - 2.685739664675734f * x2 + 0.268573966467573f;
  float x5 = x4 * x;
  poly_cos[5] = 6.893398472667717f * x5 - 7.659331636297464f * x3 + 1.641285350635171f * x;
  float x6 = x5 * x;
  poly_cos[6] = 14.935696690780054f * x6 - 20.366859123790981f * x4 + 6.788953041263660f * x2 -
                0.323283478155412f;
}

static __device__ __forceinline__ void
find_poly_cos_and_der(const int L_max, const float x, float* poly_cos, float* poly_cos_der)
{
  poly_cos[0] = 0.079577471545948f;
  poly_cos[1] = 0.238732414637843f * x;
  poly_cos_der[0] = 0.0f;
  poly_cos_der[1] = 0.238732414637843f;
  poly_cos_der[2] = 1.193662073189215f * x;
  float x2 = x * x;
  poly_cos[2] = 0.596831036594608f * x2 - 0.198943678864869f;
  poly_cos_der[3] = 4.177817256162252f * x2 - 0.835563451232451f;
  float x3 = x2 * x;
  poly_cos[3] = 1.392605752054084f * x3 - 0.835563451232451f * x;
  poly_cos_der[4] = 12.533451768486758f * x3 - 5.371479329351468f * x;
  float x4 = x3 * x;
  poly_cos[4] = 3.133362942121690f * x4 - 2.685739664675734f * x2 + 0.268573966467573f;
  poly_cos_der[5] = 34.466992363338584f * x4 - 22.977994908892391f * x2 + 1.641285350635171f;
  float x5 = x4 * x;
  poly_cos[5] = 6.893398472667717f * x5 - 7.659331636297464f * x3 + 1.641285350635171f * x;
  poly_cos_der[6] = 89.614180144680319f * x5 - 81.467436495163923f * x3 + 13.577906082527321f * x;
  float x6 = x5 * x;
  poly_cos[6] = 14.935696690780054f * x6 - 20.366859123790981f * x4 + 6.788953041263660f * x2 -
                0.323283478155412f;
}

static __global__ void find_descriptors_radial(
  const int N,
  const int* Na,
  const int* Na_sum,
  const int* g_NN,
  const int* g_NL,
  const NEP2::ParaMB paramb,
  const float* __restrict__ g_atomic_number,
  const float* __restrict__ g_x,
  const float* __restrict__ g_y,
  const float* __restrict__ g_z,
  const float* __restrict__ g_box,
  float* g_descriptors)
{
  int N1 = Na_sum[blockIdx.x];
  int N2 = N1 + Na[blockIdx.x];
  int n1 = N1 + threadIdx.x;
  if (n1 < N2) {
    const float* __restrict__ h = g_box + SIZE_BOX_AND_INVERSE_BOX * blockIdx.x;
    float atomic_number_n1 = g_atomic_number[n1];
    int neighbor_number = g_NN[n1];
    float x1 = g_x[n1];
    float y1 = g_y[n1];
    float z1 = g_z[n1];
    float q[MAX_DIM] = {0.0f};
    for (int i1 = 0; i1 < neighbor_number; ++i1) {
      int n2 = g_NL[n1 + N * i1];
      float x12 = g_x[n2] - x1;
      float y12 = g_y[n2] - y1;
      float z12 = g_z[n2] - z1;
      dev_apply_mic(h, x12, y12, z12);
      float d12 = sqrt(x12 * x12 + y12 * y12 + z12 * z12);
      float fc12;
      find_fc(paramb.rc_radial, paramb.rcinv_radial, d12, fc12);
      fc12 *= atomic_number_n1 * g_atomic_number[n2];
      float fn12[MAX_NUM_N];
      find_fn(paramb.n_max_radial, paramb.rcinv_radial, d12, fc12, fn12);
      for (int n = 0; n <= paramb.n_max_radial; ++n) {
        q[n] += fn12[n];
      }
    }
    for (int n = 0; n <= paramb.n_max_radial; ++n) {
      g_descriptors[n1 + n * N] = q[n];
    }
  }
}

static __global__ void find_descriptors_angular(
  const int N,
  const int* Na,
  const int* Na_sum,
  const int* g_NN,
  const int* g_NL,
  NEP2::ParaMB paramb,
  const float* __restrict__ g_atomic_number,
  const float* __restrict__ g_x,
  const float* __restrict__ g_y,
  const float* __restrict__ g_z,
  const float* __restrict__ g_box,
  float* g_descriptors)
{
  int N1 = Na_sum[blockIdx.x];
  int N2 = N1 + Na[blockIdx.x];
  int n1 = N1 + threadIdx.x;
  if (n1 < N2) {
    const float* __restrict__ h = g_box + SIZE_BOX_AND_INVERSE_BOX * blockIdx.x;
    float atomic_number_n1 = g_atomic_number[n1];
    int neighbor_number = g_NN[n1];
    float x1 = g_x[n1];
    float y1 = g_y[n1];
    float z1 = g_z[n1];
    float q[MAX_DIM] = {0.0f};
    for (int i1 = 0; i1 < neighbor_number; ++i1) {
      int n2 = g_NL[n1 + N * i1];
      float x12 = g_x[n2] - x1;
      float y12 = g_y[n2] - y1;
      float z12 = g_z[n2] - z1;
      dev_apply_mic(h, x12, y12, z12);
      float d12 = sqrt(x12 * x12 + y12 * y12 + z12 * z12);
      float fc12;
      find_fc(paramb.rc_angular, paramb.rcinv_angular, d12, fc12);
      fc12 *= atomic_number_n1 * g_atomic_number[n2];
      float fn12[MAX_NUM_N];
      find_fn(paramb.n_max_angular, paramb.rcinv_angular, d12, fc12, fn12);
      for (int i2 = 0; i2 < neighbor_number; ++i2) {
        int n3 = g_NL[n1 + N * i2];
        float x13 = g_x[n3] - x1;
        float y13 = g_y[n3] - y1;
        float z13 = g_z[n3] - z1;
        dev_apply_mic(h, x13, y13, z13);
        float d13 = sqrt(x13 * x13 + y13 * y13 + z13 * z13);
        float fc13;
        find_fc(paramb.rc_angular, paramb.rcinv_angular, d13, fc13);
        fc13 *= atomic_number_n1 * g_atomic_number[n3];
        float cos123 = (x12 * x13 + y12 * y13 + z12 * z13) / (d12 * d13);
        float poly_cos[MAX_NUM_L];
        find_poly_cos(paramb.L_max, cos123, poly_cos);
        for (int n = 0; n <= paramb.n_max_angular; ++n) {
          for (int l = 1; l <= paramb.L_max; ++l) {
            q[(paramb.n_max_radial + 1) + (l - 1) * (paramb.n_max_angular + 1) + n] +=
              fn12[n] * fc13 * poly_cos[l];
          }
        }
      }
    }
    for (int n = 0; n <= paramb.n_max_angular; ++n) {
      for (int l = 1; l <= paramb.L_max; ++l) {
        int index = (paramb.n_max_radial + 1) + (l - 1) * (paramb.n_max_angular + 1) + n;
        g_descriptors[n1 + index * N] = q[index];
      }
    }
  }
}

void __global__ find_max_min(const int N, const float* g_q, float* g_q_scaler, float* g_q_min)
{
  const int tid = threadIdx.x;
  const int bid = blockIdx.x;
  __shared__ float s_max[1024];
  __shared__ float s_min[1024];
  s_max[tid] = -1000000.0f; // a small number
  s_min[tid] = +1000000.0f; // a large number
  const int stride = 1024;
  const int number_of_rounds = (N - 1) / stride + 1;
  for (int round = 0; round < number_of_rounds; ++round) {
    const int n = round * stride + tid;
    if (n < N) {
      const int m = n + N * bid;
      float q = g_q[m];
      if (q > s_max[tid]) {
        s_max[tid] = q;
      }
      if (q < s_min[tid]) {
        s_min[tid] = q;
      }
    }
  }
  __syncthreads();
  for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1) {
    if (tid < offset) {
      if (s_max[tid] < s_max[tid + offset]) {
        s_max[tid] = s_max[tid + offset];
      }
      if (s_min[tid] > s_min[tid + offset]) {
        s_min[tid] = s_min[tid + offset];
      }
    }
    __syncthreads();
  }
  if (tid == 0) {
    g_q_scaler[bid] = 1.0f / (s_max[0] - s_min[0]);
    g_q_min[bid] = s_min[0];
  }
}

void __global__ normalize_descriptors(
  NEP2::ANN annmb, const int N, const float* g_q_scaler, const float* g_q_min, float* g_q)
{
  int n1 = blockDim.x * blockIdx.x + threadIdx.x;
  if (n1 < N) {
    for (int d = 0; d < annmb.dim; ++d) {
      g_q[n1 + d * N] = (g_q[n1 + d * N] - g_q_min[d]) * g_q_scaler[d];
    }
  }
}

NEP2::NEP2(char* input_dir, Parameters& para, Dataset& dataset)
{
  paramb.rc_radial = para.rc_radial;
  paramb.rcinv_radial = 1.0f / paramb.rc_radial;
  paramb.rc_angular = para.rc_angular;
  paramb.rcinv_angular = 1.0f / paramb.rc_angular;
  annmb.dim = (para.n_max_radial + 1) + (para.n_max_angular + 1) * para.L_max;
  annmb.num_neurons1 = para.num_neurons1;
  annmb.num_neurons2 = para.num_neurons2;
  annmb.num_para = (annmb.dim + 1) * annmb.num_neurons1;
  annmb.num_para += (annmb.num_neurons1 + 1) * annmb.num_neurons2;
  annmb.num_para += (annmb.num_neurons2 == 0 ? annmb.num_neurons1 : annmb.num_neurons2) + 1;
  paramb.n_max_radial = para.n_max_radial;
  paramb.n_max_angular = para.n_max_angular;
  paramb.L_max = para.L_max;
  nep_data.f12x.resize(dataset.N * dataset.max_NN_angular);
  nep_data.f12y.resize(dataset.N * dataset.max_NN_angular);
  nep_data.f12z.resize(dataset.N * dataset.max_NN_angular);
  nep_data.descriptors.resize(dataset.N * annmb.dim);
  nep_data.Fp.resize(dataset.N * annmb.dim);

  // use radial neighbor list
  find_descriptors_radial<<<dataset.Nc, dataset.max_Na>>>(
    dataset.N, dataset.Na.data(), dataset.Na_sum.data(), dataset.NN_radial.data(),
    dataset.NL_radial.data(), paramb, dataset.atomic_number.data(), dataset.r.data(),
    dataset.r.data() + dataset.N, dataset.r.data() + dataset.N * 2, dataset.h.data(),
    nep_data.descriptors.data());
  CUDA_CHECK_KERNEL

  // use angular neighbor list
  find_descriptors_angular<<<dataset.Nc, dataset.max_Na>>>(
    dataset.N, dataset.Na.data(), dataset.Na_sum.data(), dataset.NN_angular.data(),
    dataset.NL_angular.data(), paramb, dataset.atomic_number.data(), dataset.r.data(),
    dataset.r.data() + dataset.N, dataset.r.data() + dataset.N * 2, dataset.h.data(),
    nep_data.descriptors.data());
  CUDA_CHECK_KERNEL

  // output descriptors
  char file_descriptors[200];
  strcpy(file_descriptors, input_dir);
  strcat(file_descriptors, "/descriptors.out");
  FILE* fid = my_fopen(file_descriptors, "w");
  std::vector<float> descriptors(dataset.N * annmb.dim);
  nep_data.descriptors.copy_to_host(descriptors.data());
  for (int n = 0; n < dataset.N; ++n) {
    for (int d = 0; d < annmb.dim; ++d) {
      fprintf(fid, "%g ", descriptors[d * dataset.N + n]);
    }
    fprintf(fid, "\n");
  }
  fclose(fid);

  para.q_scaler.resize(annmb.dim, Memory_Type::managed);
  para.q_min.resize(annmb.dim, Memory_Type::managed);
  find_max_min<<<annmb.dim, 1024>>>(
    dataset.N, nep_data.descriptors.data(), para.q_scaler.data(), para.q_min.data());
  CUDA_CHECK_KERNEL
  normalize_descriptors<<<(dataset.N - 1) / 64 + 1, 64>>>(
    annmb, dataset.N, para.q_scaler.data(), para.q_min.data(), nep_data.descriptors.data());
  CUDA_CHECK_KERNEL
}

void NEP2::update_potential(const float* parameters, ANN& ann)
{
  ann.w0 = parameters;
  ann.b0 = ann.w0 + ann.num_neurons1 * ann.dim;
  ann.w1 = ann.b0 + ann.num_neurons1;
  if (ann.num_neurons2 == 0) {
    ann.b1 = ann.w1 + ann.num_neurons1;
  } else {
    ann.b1 = ann.w1 + ann.num_neurons1 * ann.num_neurons2;
    ann.w2 = ann.b1 + ann.num_neurons2;
    ann.b2 = ann.w2 + ann.num_neurons2;
  }
}

static __device__ void
apply_ann_one_layer(const NEP2::ANN& ann, float* q, float& energy, float* energy_derivative)
{
  for (int n = 0; n < ann.num_neurons1; ++n) {
    float w0_times_q = 0.0f;
    for (int d = 0; d < ann.dim; ++d) {
      w0_times_q += ann.w0[n * ann.dim + d] * q[d];
    }
    float x1 = tanh(w0_times_q - ann.b0[n]);
    energy += ann.w1[n] * x1;
    for (int d = 0; d < ann.dim; ++d) {
      float y1 = (1.0f - x1 * x1) * ann.w0[n * ann.dim + d];
      energy_derivative[d] += ann.w1[n] * y1;
    }
  }
  energy -= ann.b1[0];
}

static __device__ void
apply_ann(const NEP2::ANN& ann, float* q, float& energy, float* energy_derivative)
{
  // energy
  float x1[MAX_NUM_NEURONS_PER_LAYER] = {0.0f}; // states of the 1st hidden layer neurons
  float x2[MAX_NUM_NEURONS_PER_LAYER] = {0.0f}; // states of the 2nd hidden layer neurons
  for (int n = 0; n < ann.num_neurons1; ++n) {
    float w0_times_q = 0.0f;
    for (int d = 0; d < ann.dim; ++d) {
      w0_times_q += ann.w0[n * ann.dim + d] * q[d];
    }
    x1[n] = tanh(w0_times_q - ann.b0[n]);
  }
  for (int n = 0; n < ann.num_neurons2; ++n) {
    for (int m = 0; m < ann.num_neurons1; ++m) {
      x2[n] += ann.w1[n * ann.num_neurons1 + m] * x1[m];
    }
    x2[n] = tanh(x2[n] - ann.b1[n]);
    energy += ann.w2[n] * x2[n];
  }
  energy -= ann.b2[0];
  // energy gradient (compute it component by component)
  for (int d = 0; d < ann.dim; ++d) {
    float y2[MAX_NUM_NEURONS_PER_LAYER] = {0.0f};
    for (int n1 = 0; n1 < ann.num_neurons1; ++n1) {
      float y1 = (1.0f - x1[n1] * x1[n1]) * ann.w0[n1 * ann.dim + d];
      for (int n2 = 0; n2 < ann.num_neurons2; ++n2) {
        y2[n2] += ann.w1[n2 * ann.num_neurons1 + n1] * y1;
      }
    }
    for (int n2 = 0; n2 < ann.num_neurons2; ++n2) {
      energy_derivative[d] += ann.w2[n2] * (y2[n2] * (1.0f - x2[n2] * x2[n2]));
    }
  }
}

static __global__ void apply_ann(
  const int N,
  const int* Na,
  const int* Na_sum,
  const NEP2::ParaMB paramb,
  const NEP2::ANN annmb,
  const float* __restrict__ g_descriptors,
  const float* __restrict__ g_q_scaler,
  float* g_pe,
  float* g_Fp)
{
  int N1 = Na_sum[blockIdx.x];
  int N2 = N1 + Na[blockIdx.x];
  int n1 = N1 + threadIdx.x;
  if (n1 < N2) {
    // get descriptors
    float q[MAX_DIM] = {0.0f};
    for (int d = 0; d < annmb.dim; ++d) {
      q[d] = g_descriptors[n1 + d * N];
    }
    // get energy and energy gradient
    float F = 0.0f, Fp[MAX_DIM] = {0.0f};
    if (annmb.num_neurons2 == 0) {
      apply_ann_one_layer(annmb, q, F, Fp);
    } else {
      apply_ann(annmb, q, F, Fp);
    }
    g_pe[n1] = F;
    for (int d = 0; d < annmb.dim; ++d) {
      g_Fp[n1 + d * N] = Fp[d] * g_q_scaler[d];
    }
  }
}

static __global__ void find_force_radial(
  const int N,
  const int* Na,
  const int* Na_sum,
  const int* g_NN,
  const int* g_NL,
  const NEP2::ParaMB paramb,
  const NEP2::ANN annmb,
  const float* __restrict__ g_atomic_number,
  const float* __restrict__ g_x,
  const float* __restrict__ g_y,
  const float* __restrict__ g_z,
  const float* __restrict__ g_box,
  const float* __restrict__ g_Fp,
  float* g_fx,
  float* g_fy,
  float* g_fz,
  float* g_virial)
{
  int N1 = Na_sum[blockIdx.x];
  int N2 = N1 + Na[blockIdx.x];
  int n1 = N1 + threadIdx.x;
  if (n1 < N2) {
    const float* __restrict__ h = g_box + SIZE_BOX_AND_INVERSE_BOX * blockIdx.x;
    int neighbor_number = g_NN[n1];
    float s_fx = 0.0f;
    float s_fy = 0.0f;
    float s_fz = 0.0f;
    float s_virial_xx = 0.0f;
    float s_virial_yy = 0.0f;
    float s_virial_zz = 0.0f;
    float s_virial_xy = 0.0f;
    float s_virial_yz = 0.0f;
    float s_virial_zx = 0.0f;
    float atomic_number_n1 = g_atomic_number[n1];
    float x1 = g_x[n1];
    float y1 = g_y[n1];
    float z1 = g_z[n1];
    for (int i1 = 0; i1 < neighbor_number; ++i1) {
      int index = i1 * N + n1;
      int n2 = g_NL[index];
      float atomic_number_n12 = atomic_number_n1 * g_atomic_number[n2];
      float r12[3] = {g_x[n2] - x1, g_y[n2] - y1, g_z[n2] - z1};
      dev_apply_mic(h, r12[0], r12[1], r12[2]);
      float d12 = sqrt(r12[0] * r12[0] + r12[1] * r12[1] + r12[2] * r12[2]);
      float d12inv = 1.0f / d12;
      float fc12, fcp12;
      find_fc_and_fcp(paramb.rc_radial, paramb.rcinv_radial, d12, fc12, fcp12);
      float fn12[MAX_NUM_N];
      float fnp12[MAX_NUM_N];
      find_fn_and_fnp(paramb.n_max_radial, paramb.rcinv_radial, d12, fc12, fcp12, fn12, fnp12);
      float f12[3] = {0.0f};
      float f21[3] = {0.0f};
      for (int n = 0; n <= paramb.n_max_radial; ++n) {
        float tmp12 = g_Fp[n1 + n * N] * fnp12[n] * atomic_number_n12 * d12inv;
        float tmp21 = g_Fp[n2 + n * N] * fnp12[n] * atomic_number_n12 * d12inv;
        for (int d = 0; d < 3; ++d) {
          f12[d] += tmp12 * r12[d];
          f21[d] -= tmp21 * r12[d];
        }
      }
      s_fx += f12[0] - f21[0];
      s_fy += f12[1] - f21[1];
      s_fz += f12[2] - f21[2];
      s_virial_xx += r12[0] * f12[0];
      s_virial_yy += r12[1] * f12[1];
      s_virial_zz += r12[2] * f12[2];
      s_virial_xy += r12[0] * f12[1];
      s_virial_yz += r12[1] * f12[2];
      s_virial_zx += r12[2] * f12[0];
    }
    g_fx[n1] = s_fx;
    g_fy[n1] = s_fy;
    g_fz[n1] = s_fz;
    g_virial[n1] = s_virial_xx;
    g_virial[n1 + N] = s_virial_yy;
    g_virial[n1 + N * 2] = s_virial_zz;
    g_virial[n1 + N * 3] = s_virial_xy;
    g_virial[n1 + N * 4] = s_virial_yz;
    g_virial[n1 + N * 5] = s_virial_zx;
  }
}

static __global__ void find_partial_force_angular(
  const int N,
  const int* Na,
  const int* Na_sum,
  const int* g_NN,
  const int* g_NL,
  const NEP2::ParaMB paramb,
  const NEP2::ANN annmb,
  const float* __restrict__ g_atomic_number,
  const float* __restrict__ g_x,
  const float* __restrict__ g_y,
  const float* __restrict__ g_z,
  const float* __restrict__ g_box,
  const float* __restrict__ g_Fp,
  float* g_f12x,
  float* g_f12y,
  float* g_f12z)
{
  int N1 = Na_sum[blockIdx.x];
  int N2 = N1 + Na[blockIdx.x];
  int n1 = N1 + threadIdx.x;
  if (n1 < N2) {
    const float* __restrict__ h = g_box + SIZE_BOX_AND_INVERSE_BOX * blockIdx.x;
    int neighbor_number = g_NN[n1];
    float atomic_number_n1 = g_atomic_number[n1];
    float x1 = g_x[n1];
    float y1 = g_y[n1];
    float z1 = g_z[n1];
    float Fp[MAX_DIM] = {0.0f};
    for (int d = 0; d < annmb.dim; ++d) {
      Fp[d] = g_Fp[n1 + d * N];
    }
    for (int i1 = 0; i1 < neighbor_number; ++i1) {
      int index = i1 * N + n1;
      int n2 = g_NL[index];
      float r12[3] = {g_x[n2] - x1, g_y[n2] - y1, g_z[n2] - z1};
      dev_apply_mic(h, r12[0], r12[1], r12[2]);
      float d12 = sqrt(r12[0] * r12[0] + r12[1] * r12[1] + r12[2] * r12[2]);
      float d12inv = 1.0f / d12;
      float fc12, fcp12;
      find_fc_and_fcp(paramb.rc_angular, paramb.rcinv_angular, d12, fc12, fcp12);
      float atomic_number_n12 = atomic_number_n1 * g_atomic_number[n2];
      fc12 *= atomic_number_n12;
      fcp12 *= atomic_number_n12;
      float fn12[MAX_NUM_N];
      float fnp12[MAX_NUM_N];
      find_fn_and_fnp(paramb.n_max_angular, paramb.rcinv_angular, d12, fc12, fcp12, fn12, fnp12);
      float f12[3] = {0.0f};
      for (int i2 = 0; i2 < neighbor_number; ++i2) {
        int n3 = g_NL[n1 + N * i2];
        float x13 = g_x[n3] - x1;
        float y13 = g_y[n3] - y1;
        float z13 = g_z[n3] - z1;
        dev_apply_mic(h, x13, y13, z13);
        float d13 = sqrt(x13 * x13 + y13 * y13 + z13 * z13);
        float d13inv = 1.0f / d13;
        float fc13;
        find_fc(paramb.rc_angular, paramb.rcinv_angular, d13, fc13);
        fc13 *= atomic_number_n1 * g_atomic_number[n3];
        float cos123 = (r12[0] * x13 + r12[1] * y13 + r12[2] * z13) / (d12 * d13);
        float fn13[MAX_NUM_N];
        find_fn(paramb.n_max_angular, paramb.rcinv_angular, d13, fc13, fn13);
        float poly_cos[MAX_NUM_L];
        float poly_cos_der[MAX_NUM_L];
        find_poly_cos_and_der(paramb.L_max, cos123, poly_cos, poly_cos_der);
        float cos_der[3] = {
          x13 * d13inv - r12[0] * d12inv * cos123, y13 * d13inv - r12[1] * d12inv * cos123,
          z13 * d13inv - r12[2] * d12inv * cos123};
        for (int n = 0; n <= paramb.n_max_angular; ++n) {
          float tmp_n_a = (fnp12[n] * fn13[0] + fnp12[0] * fn13[n]) * d12inv;
          float tmp_n_b = (fn12[n] * fn13[0] + fn12[0] * fn13[n]) * d12inv;
          for (int l = 1; l <= paramb.L_max; ++l) {
            int nl = (paramb.n_max_radial + 1) + (l - 1) * (paramb.n_max_angular + 1) + n;
            float tmp_nl_a = Fp[nl] * tmp_n_a * poly_cos[l];
            float tmp_nl_b = Fp[nl] * tmp_n_b * poly_cos_der[l];
            for (int d = 0; d < 3; ++d) {
              f12[d] += tmp_nl_a * r12[d] + tmp_nl_b * cos_der[d];
            }
          }
        }
      }
      g_f12x[index] = f12[0];
      g_f12y[index] = f12[1];
      g_f12z[index] = f12[2];
    }
  }
}

static __global__ void find_force_manybody(
  const int N,
  const int* Na,
  const int* Na_sum,
  const int* g_neighbor_number,
  const int* g_neighbor_list,
  const float* __restrict__ g_f12x,
  const float* __restrict__ g_f12y,
  const float* __restrict__ g_f12z,
  const float* __restrict__ g_x,
  const float* __restrict__ g_y,
  const float* __restrict__ g_z,
  const float* __restrict__ g_box,
  float* g_fx,
  float* g_fy,
  float* g_fz,
  float* g_virial)
{
  int N1 = Na_sum[blockIdx.x];
  int N2 = N1 + Na[blockIdx.x];
  int n1 = N1 + threadIdx.x;
  if (n1 < N2) {
    float s_fx = 0.0f;
    float s_fy = 0.0f;
    float s_fz = 0.0f;
    float s_virial_xx = 0.0f;
    float s_virial_yy = 0.0f;
    float s_virial_zz = 0.0f;
    float s_virial_xy = 0.0f;
    float s_virial_yz = 0.0f;
    float s_virial_zx = 0.0f;
    const float* __restrict__ h = g_box + SIZE_BOX_AND_INVERSE_BOX * blockIdx.x;
    int neighbor_number = g_neighbor_number[n1];
    float x1 = g_x[n1];
    float y1 = g_y[n1];
    float z1 = g_z[n1];
    for (int i1 = 0; i1 < neighbor_number; ++i1) {
      int index = i1 * N + n1;
      int n2 = g_neighbor_list[index];
      int neighbor_number_2 = g_neighbor_number[n2];
      float x12 = g_x[n2] - x1;
      float y12 = g_y[n2] - y1;
      float z12 = g_z[n2] - z1;
      dev_apply_mic(h, x12, y12, z12);
      float f12x = g_f12x[index];
      float f12y = g_f12y[index];
      float f12z = g_f12z[index];
      int offset = 0;
      for (int k = 0; k < neighbor_number_2; ++k) {
        if (n1 == g_neighbor_list[n2 + N * k]) {
          offset = k;
          break;
        }
      }
      index = offset * N + n2;
      float f21x = g_f12x[index];
      float f21y = g_f12y[index];
      float f21z = g_f12z[index];
      s_fx += f12x - f21x;
      s_fy += f12y - f21y;
      s_fz += f12z - f21z;
      s_virial_xx += x12 * f21x;
      s_virial_yy += y12 * f21y;
      s_virial_zz += z12 * f21z;
      s_virial_xy += x12 * f21y;
      s_virial_yz += y12 * f21z;
      s_virial_zx += z12 * f21x;
    }
    g_fx[n1] += s_fx;
    g_fy[n1] += s_fy;
    g_fz[n1] += s_fz;
    g_virial[n1] += s_virial_xx;
    g_virial[n1 + N] += s_virial_yy;
    g_virial[n1 + N * 2] += s_virial_zz;
    g_virial[n1 + N * 3] += s_virial_xy;
    g_virial[n1 + N * 4] += s_virial_yz;
    g_virial[n1 + N * 5] += s_virial_zx;
  }
}

void NEP2::find_force(
  Parameters& para,
  const int configuration_start,
  const int configuration_end,
  const float* parameters,
  Dataset& dataset)
{
  CHECK(cudaMemcpyToSymbol(c_parameters, parameters, sizeof(float) * annmb.num_para));
  float* address_c_parameters;
  CHECK(cudaGetSymbolAddress((void**)&address_c_parameters, c_parameters));
  update_potential(address_c_parameters, annmb);

  apply_ann<<<configuration_end - configuration_start, dataset.max_Na>>>(
    dataset.N, dataset.Na.data() + configuration_start, dataset.Na_sum.data() + configuration_start,
    paramb, annmb, nep_data.descriptors.data(), para.q_scaler.data(), dataset.pe.data(),
    nep_data.Fp.data());
  CUDA_CHECK_KERNEL

  // use radial neighbor list
  find_force_radial<<<configuration_end - configuration_start, dataset.max_Na>>>(
    dataset.N, dataset.Na.data() + configuration_start, dataset.Na_sum.data() + configuration_start,
    dataset.NN_radial.data(), dataset.NL_radial.data(), paramb, annmb, dataset.atomic_number.data(),
    dataset.r.data(), dataset.r.data() + dataset.N, dataset.r.data() + dataset.N * 2,
    dataset.h.data(), nep_data.Fp.data(), dataset.force.data(), dataset.force.data() + dataset.N,
    dataset.force.data() + dataset.N * 2, dataset.virial.data());
  CUDA_CHECK_KERNEL

  // use angular neighbor list
  find_partial_force_angular<<<configuration_end - configuration_start, dataset.max_Na>>>(
    dataset.N, dataset.Na.data() + configuration_start, dataset.Na_sum.data() + configuration_start,
    dataset.NN_angular.data(), dataset.NL_angular.data(), paramb, annmb,
    dataset.atomic_number.data(), dataset.r.data(), dataset.r.data() + dataset.N,
    dataset.r.data() + dataset.N * 2, dataset.h.data(), nep_data.Fp.data(), nep_data.f12x.data(),
    nep_data.f12y.data(), nep_data.f12z.data());
  CUDA_CHECK_KERNEL

  // use angular neighbor list
  find_force_manybody<<<configuration_end - configuration_start, dataset.max_Na>>>(
    dataset.N, dataset.Na.data() + configuration_start, dataset.Na_sum.data() + configuration_start,
    dataset.NN_angular.data(), dataset.NL_angular.data(), nep_data.f12x.data(),
    nep_data.f12y.data(), nep_data.f12z.data(), dataset.r.data(), dataset.r.data() + dataset.N,
    dataset.r.data() + dataset.N * 2, dataset.h.data(), dataset.force.data(),
    dataset.force.data() + dataset.N, dataset.force.data() + dataset.N * 2, dataset.virial.data());
  CUDA_CHECK_KERNEL
}
