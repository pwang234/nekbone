
#include <stdio.h>
#include <algorithm>
#include "cuda_runtime.h"
#include "cuda_util.h"
#include "cublas_v2.h"
#include "ld_functions.h"
#include "sm_utils.inl"
#include "thrust/device_ptr.h"
#include "thrust/reduce.h"
#include "mpi.h"
#include "cuda_profiler_api.h"

#include "cgcuda.h"

#define WARP_SIZE 32

#define NO_COMM_MASK 0
#define BOUNDARY_ONLY 1
#define INTERIOR_ONLY 2

//#define DEBUG
cublasHandle_t cublas_handle;
//extern cublasHandle_t cublas_ctx;
cudaStream_t stream[2];

//#define TIME_AX

//#define AOS

#include <sys/time.h>

class CTimer
{
protected:
  timeval start,end;
public:
  void Start() {gettimeofday(&start, NULL);}
  double GetET() {
    gettimeofday(&end,NULL);
    double et=(end.tv_sec+end.tv_usec*0.000001)-(start.tv_sec+start.tv_usec*0.000001);
    return et;
  }
};

bool nonZero(uint i) { return (i > 0); }

CTimer timer, timer1, timer2;
static float time_comm = 0, time_gs = 0;
#ifdef TIME_AX
static float timeax[10] = {0,0,0,0,0,0,0,0,0,0};
#endif

struct comm_data {
  uint n;      /* number of messages */
  uint *p;     /* message source/dest proc */
  uint *size;  /* size of message */
  uint total;  /* sum of message sizes */
};

struct mpi_comm_wrapper 
{
 MPI_Comm mpi_comm;
 uint id;
 uint np;
};

struct gpu_map 
{
  uint size_from;
  uint size_to;
  uint* d_offsets;
  uint* d_indices_from;
  uint* d_indices_from_COO;
  uint* d_indices_to;
};

struct gpu_domain
{
  double *d_x; 
  double *d_f; 
  double *d_g; // metric terms
  double *d_c;
  double *d_r;
  double *d_w;
  double *d_p; 
  double *d_z;
  double *d_dxm1; // differentiation matrix D
  double *d_dxtm1; // D^T
  double *d_temp; // temporary array
  double *d_mask; // mask data

  double *reduced_value;
  cudaEvent_t reduced_value_event;

  int nx1; 
  int ny1; 
  int nz1; 
  int nelt; 
  int ldim; 
  int nxyz;
  int nid;
  int niter;
  int mask_length;

  struct gpu_map local_map[2];
  uint* d_flagged_primaries;
  int flagged_primaries_size;

  // MPI communication 
  struct comm_data comm_struct[2];
  struct gpu_map comm_map[2];

  // Mpi buffer
  uint buffer_size;
  double* h_buffer;
  double* d_buffer;

  // Mpi requests
  MPI_Request* req; 
  mpi_comm_wrapper comm;
};

static gpu_domain gpu_dom;
static uint *d_send_mask;
static uint *d_sendcell_mask;

void init_comm_struct(comm_data* comm_struct, uint n, const uint* p, const uint* size, uint total)
{
  comm_struct->p = (uint*) malloc(2*n*sizeof(uint));
  comm_struct->size = comm_struct->p + n;

  for (int i=0;i<n;i++)
  {
    (comm_struct->p)[i] = p[i];
    (comm_struct->size)[i] = size[i];
  }

  comm_struct->n = n;
  comm_struct->total = total;
}

void fill_gpu_maps(gpu_map* cuda_map, const uint* map)
{
  cudaCheckError();
  const uint* orig = map;

  // First compute the size of the map_indices_to and map_indices_from arrays
  // TODO: Can probably get that from "nz" array
  uint size_from_tmp = 0;
  uint size_to_tmp = 0;
  while( *map++ != -(uint)1 )                                              
  {
    *map++;  
    size_from_tmp++;
    do { size_to_tmp++; } while( (*map++) != -(uint)1 ); 
  } 
#ifdef DEBUG
  printf("size_from = %d, size_to=%d\n",size_from_tmp,size_to_tmp);
#endif

  // Fill host arrays first
  uint* h_map_offsets = (uint*) malloc((size_from_tmp+1)*sizeof(uint));
  uint* h_map_indices_from = (uint*) malloc(size_from_tmp*sizeof(uint));
  uint* h_map_indices_to = (uint*) malloc(size_to_tmp*sizeof(uint));
  uint* h_map_indices_from_COO = (uint*) malloc(size_to_tmp*sizeof(uint));

  uint i,j;
  uint count_from=0;
  uint count_to=0;
  h_map_offsets[0] = 0;

  cudaCheckError();
  map = orig;
  while((i=*map++)!=-(uint)1) 
  { 
    uint row_length = 0;
    h_map_indices_from[count_from++] = i;
    j=*map++; 
    do 
    { 
      h_map_indices_to[count_to] = j;
      h_map_indices_from_COO[count_to++] = i;
      row_length++;
    }
    while((j=*map++)!=-(uint)1);
  
    h_map_offsets[count_from] = count_to; 
  } 

  cudaCheckError();
  cudaMalloc((void **) &(cuda_map->d_offsets), (size_from_tmp+1)*sizeof(uint));
  cudaMalloc((void **) &(cuda_map->d_indices_from), size_from_tmp*sizeof(uint));
  cudaMalloc((void **) &(cuda_map->d_indices_to), size_to_tmp*sizeof(uint));
  cudaMalloc((void **) &(cuda_map->d_indices_from_COO), size_to_tmp*sizeof(uint));

  cudaMemcpy(cuda_map->d_offsets, h_map_offsets, (size_from_tmp+1)*sizeof(uint), cudaMemcpyHostToDevice);
  cudaMemcpy(cuda_map->d_indices_from, h_map_indices_from, size_from_tmp*sizeof(uint), cudaMemcpyHostToDevice);
  cudaMemcpy(cuda_map->d_indices_to, h_map_indices_to, size_to_tmp*sizeof(uint), cudaMemcpyHostToDevice);
  cudaMemcpy(cuda_map->d_indices_from_COO, h_map_indices_from_COO, size_to_tmp*sizeof(uint), cudaMemcpyHostToDevice);

  cuda_map->size_from = size_from_tmp;
  cuda_map->size_to = size_to_tmp;
  cudaCheckError();

  free(h_map_offsets);
  free(h_map_indices_from);
  free(h_map_indices_to);
  free(h_map_indices_from_COO);
}

void fill_flagged_primaries_map(uint** d_flagged_primaries, const uint* flagged_primaries)
{
//  cudaMalloc((void **) d_flagged_primaries, (size_from_tmp+1)*sizeof(uint));
}

template <typename T>
__global__
void local_init_kernel(T* __restrict__ out,  const uint* __restrict__ flagged_primaries, int size  )
{
  for (int tid = blockDim.x*blockIdx.x + threadIdx.x; tid < size; tid+= gridDim.x * blockDim.x) 
  {
    out[flagged_primaries[tid]] = 0.;
  }
}


template <typename T, int comm_mask>
__global__
void local_gather_mask_kernel(T* __restrict__ out, const T* __restrict__ in, 
                         const uint* __restrict__ offsets, 
                         const uint* __restrict__ map_indices_from, 
                         const uint* __restrict__ map_indices_to, int size,
                         uint* send_mask)
{
  for (int tid = blockDim.x*blockIdx.x + threadIdx.x; tid < size; tid+= gridDim.x * blockDim.x) 
  {
    if (comm_mask == BOUNDARY_ONLY) { 
      if (send_mask[tid] == 0) continue;
    } else if (comm_mask == INTERIOR_ONLY) { 
      if (send_mask[tid] == 1) continue;
    }
    uint store_loc = map_indices_from[tid];
    T t = out[store_loc]; 
    for (int i=offsets[tid];i<offsets[tid+1];i++)
    {
      t += in[map_indices_to[i]];
    }
    out[store_loc] = t;
  }
}

template <typename T>
__global__
void local_gather_kernel(T* __restrict__ out, const T* __restrict__ in, 
                         const uint* __restrict__ offsets, 
                         const uint* __restrict__ map_indices_from, 
                         const uint* __restrict__ map_indices_to, int size)
{
  for (int tid = blockDim.x*blockIdx.x + threadIdx.x; tid < size; tid+= gridDim.x * blockDim.x) 
  {
    uint store_loc = map_indices_from[tid];
    T t = out[store_loc]; 
    for (int i=offsets[tid];i<offsets[tid+1];i++)
    {
      t += in[map_indices_to[i]];
    }
    out[store_loc] = t;
  }
}


template <typename T>
__global__
void local_scatter_kernel(T* __restrict__ out, const T* __restrict__ in, 
                          const uint* __restrict__ offsets, 
                          const uint* __restrict__ map_indices_from, 
                          const uint* __restrict__ map_indices_to, int size  )
{
  for (int tid = blockDim.x*blockIdx.x + threadIdx.x; tid < size; tid+= gridDim.x * blockDim.x) 
  {
    T t = in[map_indices_from[tid]]; 
    for (int i=offsets[tid];i<offsets[tid+1];i++)
    {
      out[map_indices_to[i]] = t;  
    }
  }
}


template <typename T>
__global__
void local_scatter_kernel_COO(T* __restrict__ out, const T* __restrict__ in,  const uint* __restrict__ map_indices_from_COO, const uint* __restrict__ map_indices_to, int size  )
{
  for (int tid = blockDim.x*blockIdx.x + threadIdx.x; tid < size; tid+= gridDim.x * blockDim.x) 
  {
    T t = in[map_indices_from_COO[tid]]; 
    out[map_indices_to[tid]] = t;  
  }
}

void local_init_cuda(double* out, uint* flagged_primaries, int flagged_primaries_size)
{

  const int cta_size= 128;
  const int grid_size = min(4096,(flagged_primaries_size+cta_size-1)/cta_size);
  cudaCheckError();
  local_init_kernel<<<grid_size,cta_size>>>(out,flagged_primaries,flagged_primaries_size);
  cudaCheckError();
}

void local_gather_cuda(double* out, const double* in,  gpu_map* map, int comm_mask, cudaStream_t stream)
{
  cudaCheckError();

  const int cta_size= 128;
  // const int grid_size = min(4096,(map->size_from+cta_size-1)/cta_size);
  const int grid_size = (map->size_from+cta_size-1)/cta_size;
  switch (comm_mask) {
  case NO_COMM_MASK: 
    local_gather_mask_kernel<double,NO_COMM_MASK><<<grid_size,cta_size,0,stream>>>
      (out,in,map->d_offsets,
       map->d_indices_from,map->d_indices_to,map->size_from,
       d_send_mask);
    break;
  case BOUNDARY_ONLY: 
    local_gather_mask_kernel<double,BOUNDARY_ONLY><<<grid_size,cta_size,0,stream>>>
      (out,in,map->d_offsets,
       map->d_indices_from,map->d_indices_to,map->size_from,
       d_send_mask);
    break;
  case INTERIOR_ONLY: 
    local_gather_mask_kernel<double,INTERIOR_ONLY><<<grid_size,cta_size,0,stream>>>
      (out,in,map->d_offsets,
       map->d_indices_from,map->d_indices_to,map->size_from,
       d_send_mask);
    break;
  default: 
    printf("invalid mask value!\n");
    exit(1);
  }
  
  cudaCheckError();
}

void local_scatter_cuda(double* out, double* in, gpu_map* map, cudaStream_t stream)
{
  cudaCheckError();

  const int cta_size= 128;
  const int grid_size = min(4096,(map->size_from+cta_size-1)/cta_size);
  local_scatter_kernel<<<grid_size,cta_size,0,stream>>>(out,in,map->d_offsets,
                                               map->d_indices_from,map->d_indices_to,map->size_from );
  cudaCheckError();
}


#if 0
  /*
   * Copy data to the GPU
  */
  void copyTo(int nelt, int nxyz, double *u) {

    cudaCheckError();
    cudaMemcpy(d_u, u, nelt*nxyz*sizeof(double), cudaMemcpyHostToDevice);
    cudaCheckError();

    return; 
  }


  /*
   * Copy data from the GPU
  */
template<typename T>
  void copyFrom(int n, T *vec, T *d_vec) {

    cudaCheckError();
    cudaMemcpy(vec, d_vec, n*sizeof(T), cudaMemcpyDeviceToHost);
    cudaCheckError();

    return;
  }
#endif


  /*
   * Stacked Matrix multiply
  */
  __global__ void gsmxm(double *a, int n1, double *b, int n2, double *c, int n3, int nlvl) {
    int id= blockDim.x*blockIdx.x+ threadIdx.x;
   
    int aSize= n1*n2; 
    int cSize= n1*n3; 
    int lvl = id/cSize;
    int rank = id % cSize;
    int row = rank % n1;
    int col = rank / n1;

    if (id < cSize*nlvl) {
      c[id] = 0.0;

      int k;
      for (k = 0; k < n2; k++) {
        c[id] += a[lvl*aSize+k*n1+row]*b[col*n2+k];
      }
    }

    return;
  }


  /*
   * Add two vectors
  */
  __global__ void gadd2(double *a, double *b, int n) {
    int id= blockDim.x*blockIdx.x+ threadIdx.x;

    if (id < n) {
      a[id] += b[id];
    }

    return;
  }


  /*
   * Perform geometry scaling
  */
  __global__ void geom(int n, double *ur, double *us, double *ut, double *g) {
    int id= blockDim.x*blockIdx.x+ threadIdx.x;

    if (id < n) {
      double wr = g[id*6+0]*ur[id] + g[id*6+1]*us[id] + g[id*6+2]*ut[id];
      double ws = g[id*6+1]*ur[id] + g[id*6+3]*us[id] + g[id*6+4]*ut[id];
      double wt = g[id*6+2]*ur[id] + g[id*6+4]*us[id] + g[id*6+5]*ut[id];
      ur[id] = wr;
      us[id] = ws;
      ut[id] = wt;
    }

    return;
  }

template<int p, int p_sq, int p_cube, int p_cube_padded, int pts_per_thread, int slab_size, int cta_size, int num_ctas, int comm_mask>
__global__
__launch_bounds__(cta_size,num_ctas)
void ax_cuda_kernel_v9_shared_D(const double* __restrict__ u_global, 
                                double* __restrict__ w, 
                                const double* __restrict__ g, 
                                const double* __restrict__ dxm1, 
                                const double* __restrict__ dxtm1, int n_cells, 
                                uint *sendcell_mask)
{
  int tid = threadIdx.x;
  __shared__ double temp[cta_size];
  __shared__ double s_dxm1[p_sq];
  __shared__ double s_dxtm1[p_sq];

  //for (int cell_id=blockIdx.x; cell_id < n_cells; cell_id += gridDim.x)
  int cell_id = blockIdx.x;
  {
    if (comm_mask == BOUNDARY_ONLY) {
      if (sendcell_mask[cell_id] == 0) return;
    } else if (comm_mask == INTERIOR_ONLY) {
      if (sendcell_mask[cell_id] == 1) return;
    }
    // Load u in shared for the entire cell
    int offset = cell_id*p_cube;

    int tid_mod_p = tid%p;
    int tid_div_p = tid/p;
    int tid_mod_p_sq = tid%p_sq;
    int tid_div_p_sq = tid/p_sq;

    double u[pts_per_thread];
    #pragma unroll
    for (int k=0;k<pts_per_thread;k++)
    {
      int pt_id = k*cta_size + tid;

      u[k] = ld_functions::ld_cg(&u_global[offset + pt_id]);
    }

    // Store dxm1 and dxtm1 in shared memory
    if (tid < p_sq)
    {
      s_dxm1[tid] = ld_functions::ld_cg(&dxm1[tid]);
      s_dxtm1[tid] = ld_functions::ld_cg(&dxtm1[tid]);
    }


    // Initialize wa to 0.
    double wa[pts_per_thread];
    #pragma unroll
    for (int k=0;k<pts_per_thread;k++)
      wa[k] = 0.;

    // Now compute w for one slab at a time
    #pragma unroll
    for (int k=0;k<pts_per_thread;k++)
    {
      int pt_id = k*cta_size + tid;
      //int pt_id_div_p = pt_id/p;
      //int pt_id_mod_p = pt_id%p;
      int pt_id_div_p_sq = pt_id/p_sq;
      //int pt_id_mod_p_sq = pt_id%p_sq;

      double ur, us, ut;

      // Load first slab in shared memory
      __syncthreads();
      temp[tid] = u[k];
      __syncthreads();
      

      //  Now that data is loaded in shared, compute ur
      {
        int s_offset = tid_div_p*p;
        int d_offset  = tid_mod_p;

        ur = 0.;
        #pragma unroll
        for (int i=0;i<p;i++)
          ur += s_dxm1[d_offset + p*i]*temp[s_offset + i];
          //ur += __ldg(&dxm1[d_offset + p*i])*temp[s_offset + i];
      }

      // Compute us
      {
        int plane = tid_div_p_sq;
        int s_offset = plane*p_sq + tid_mod_p;
        int d_offset = p*( (tid-plane*p_sq)/p);

        us = 0.;
        #pragma unroll
        for (int i=0;i<p;i++)
          us += temp[s_offset + p*i]*s_dxtm1[d_offset + i];
         // us += temp[s_offset + p*i]*__ldg(&dxtm1[d_offset + i]);
      }


      // Load all slabs in shared, one by one to compute ut
      ut = 0.;
      #pragma unroll
      for (int k2=0;k2<pts_per_thread;k2++)
      {
        int i_start = k2*slab_size;

        // Load in shared
        __syncthreads();
        temp[tid] = u[k2];
        __syncthreads();

        // Compute ut
        int s_offset = tid_mod_p_sq;
        int d_offset = pt_id_div_p_sq*p;

        #pragma unroll
        for (int icount=0;icount<slab_size;icount++)
        {
          //ut += temp[s_offset + p_sq*icount]*__ldg(&dxtm1[d_offset + i_start]);
          ut += temp[s_offset + p_sq*icount]*s_dxtm1[d_offset + i_start];
          i_start++;
        }
      }

      // Transform
      {


        /*
        int offset = (cell_id*p_cube + pt_id)*6;
        //TODO: Switch to SOA
        double metric[6];
        #pragma unroll
        for (int i=0;i<6;i++)
          metric[i] = g[offset+i];

        */

        // AoS version
#ifdef AOS
        int offset = cell_id*p_cube + pt_id;
        //TODO: Switch to SOA
        double metric[6];
        #pragma unroll
        for (int i=0;i<6;i++)
          metric[i] = g[offset+i*n_cells*p_cube];
#else
        int offset = (cell_id*p_cube + pt_id)*6;
        double metric[6];
        #pragma unroll
        for (int i=0;i<6;i++)
          metric[i] = g[offset+i];
#endif
          //metric[i] = ld_functions::ld_cg(&g[offset+i*n_cells*p_cube]);
          //metric[i] = g[offset+i*n_cells*p_cube];

          //metric[i] = ld_functions::ld_cg(&g[offset+i]);
          //metric[i] = g[offset+i];


        // SOA HACK
        /*
        int offset = cell_id*p_cube + pt_id;

        //TODO: Switch to SOA
        double metric[6];
        #pragma unroll
        for (int i=0;i<6;i++)
        {
          //metric[i] = g[offset];
          metric[i] = ld_functions::ld_cg(&g[offset]);
          offset += n_cells*p_cube;
        }
        */



          //metric[i] = ld_functions::ld_cg(&(g[offset+i]));

        double wr = metric[0]*ur + metric[1]*us + metric[2]*ut;
        double ws = metric[1]*ur + metric[3]*us + metric[4]*ut;
        double wt = metric[2]*ur + metric[4]*us + metric[5]*ut;

        ur = wr;
        us = ws;
        ut = wt;
      }

      // Store ur in shared memory
      __syncthreads();
      temp[tid] = ur;
      __syncthreads();

      // Now that data is loaded in shared, compute wa

      {
        int d_offset  = tid_mod_p;
        int s_offset = tid_div_p*p;

        #pragma unroll
        for (int i=0;i<p;i++)
          wa[k] += s_dxtm1[d_offset+p*i]*temp[s_offset + i];
          //wa[k] += __ldg(&dxtm1[d_offset+p*i])*temp[s_offset + i];
      }

      __syncthreads();
      temp[tid] = us;
      __syncthreads();

      // Compute us
      {

        int plane = tid_div_p_sq;
        int s_offset = plane*p_sq + tid_mod_p;
        int d_offset = p*( (tid-plane*p_sq)/p);

        #pragma unroll
        for (int i=0;i<p;i++)
          wa[k] += temp[s_offset + p*i]*s_dxm1[d_offset + i];
          //wa[k] += temp[s_offset + p*i]*__ldg(&dxm1[d_offset + i]);
      }

      __syncthreads();
      // Store ut in shared memory
      temp[tid] = ut;
      __syncthreads();

      #pragma unroll
      for (int k2=0;k2<pts_per_thread;k2++)
      {
        int i_start = k*slab_size;
        int pt_id_2 = k2*cta_size + tid;
        int plane = pt_id_2/p_sq;

        int s_offset = tid_mod_p_sq;
        int d_offset = plane*p;

        #pragma unroll
        for (int i_count=0; i_count < slab_size; i_count++)
        {
          wa[k2] += temp[s_offset + p_sq*i_count]*s_dxm1[d_offset + i_start];
          //wa[k2] += temp[s_offset + p_sq*i_count]*__ldg(&dxm1[d_offset + i_start]);
          i_start++;
        }
      }
      __syncthreads();

    } // Loop over k

    #pragma unroll
    for (int k=0;k<pts_per_thread;k++)
    {
      int pt_id = k*cta_size + tid;
      w[offset + pt_id] = wa[k];
    }
  } // Loop over blocks

}


void axcuda_e(double *w, double *u, double *g, double *dxm1, double *dxtm1, 
              int nx1, int ny1, int nz1, int nelt, int ldim, int comm_mask, cudaStream_t stream)
{
      if ( nx1 != ny1 || nx1 != nz1)
      {
        printf("non-cubic elements not supported in Cuda version\n");
        exit(1);
      }

      if ( nx1 != 12 && nx1 != 9 )
      {
        printf("Current implementation only tested for polynomial orders 9 and 12, exiting");
        exit(1);
      }

      if ( nx1 == 9 )
      {
        const int grid_size = nelt;
        const int p = 9;
        const int p_sq = 9*9;
        const int p_cube = 9*9*9;
        const int p_cube_padded = p_cube;

        const int cta_size = 243;
        const int pts_per_thread = 3;  // 6*288 = 12*12*12
        const int slab_size = 3;

        const int num_ctas = 4;
        switch (comm_mask) {
        case NO_COMM_MASK:
          ax_cuda_kernel_v9_shared_D<p,p_sq,p_cube,p_cube_padded,pts_per_thread,slab_size,cta_size,num_ctas,NO_COMM_MASK>
            <<<grid_size,cta_size,0,stream>>>(u, w, g, dxm1, dxtm1, nelt, d_sendcell_mask);
          break;
        case BOUNDARY_ONLY: 
          ax_cuda_kernel_v9_shared_D<p,p_sq,p_cube,p_cube_padded,pts_per_thread,slab_size,cta_size,num_ctas,BOUNDARY_ONLY>
            <<<grid_size,cta_size,0,stream>>>(u, w, g, dxm1, dxtm1, nelt, d_sendcell_mask);
          break;
        case INTERIOR_ONLY: 
          ax_cuda_kernel_v9_shared_D<p,p_sq,p_cube,p_cube_padded,pts_per_thread,slab_size,cta_size,num_ctas,INTERIOR_ONLY>
            <<<grid_size,cta_size,0,stream>>>(u, w, g, dxm1, dxtm1, nelt, d_sendcell_mask);
          break;
        }
      }

      if ( nx1 == 12 )
      {
        // 12x12x12 case
        const int p = 12;
        const int p_sq = 12*12;
        const int p_cube = 12*12*12;
        const int p_cube_padded = p_cube;

        // We could play with this
        const int grid_size = nelt;

        // BEST CONFIG
        const int cta_size = 576;
        const int pts_per_thread = 3;  // 6*288 = 12*12*12
        const int slab_size = 4;
        const int num_ctas = 2;

        switch (comm_mask) {
        case NO_COMM_MASK:
          ax_cuda_kernel_v9_shared_D<p,p_sq,p_cube,p_cube_padded,pts_per_thread,slab_size,cta_size,num_ctas,NO_COMM_MASK>
            <<<grid_size,cta_size,0,stream>>>(u, w, g, dxm1, dxtm1, nelt, d_sendcell_mask);
          break;
        case BOUNDARY_ONLY: 
          ax_cuda_kernel_v9_shared_D<p,p_sq,p_cube,p_cube_padded,pts_per_thread,slab_size,cta_size,num_ctas,BOUNDARY_ONLY>
            <<<grid_size,cta_size,0,stream>>>(u, w, g, dxm1, dxtm1, nelt, d_sendcell_mask);
          break;
        case INTERIOR_ONLY: 
          ax_cuda_kernel_v9_shared_D<p,p_sq,p_cube,p_cube_padded,pts_per_thread,slab_size,cta_size,num_ctas,INTERIOR_ONLY>
            <<<grid_size,cta_size,0,stream>>>(u, w, g, dxm1, dxtm1, nelt, d_sendcell_mask);
          break;
        }
      }

      return;
}


int exec_mpi_recvs(double *buf, 
                 const mpi_comm_wrapper* comm,
                 const struct comm_data *c, MPI_Request* req)
{
  const uint *p, *pe, *size=c->size;
  int send_size = 0;

  for(p=c->p, pe=p+c->n ; p!=pe ; ++p) 
  {
    size_t len = *(size++);
    MPI_Irecv(buf,len,MPI_DOUBLE,*p,*p,comm->mpi_comm,req++);
    buf += len;
    send_size += len;
  }

  return send_size;
}

int exec_mpi_sends(double *buf, 
                 const mpi_comm_wrapper* comm,
                 const struct comm_data *c, MPI_Request* req)
{
  const uint *p, *pe, *size=c->size;
  int send_size=0;
  for(p=c->p, pe=p+c->n; p!=pe; ++p) 
  {
    size_t len = *(size++);
    MPI_Isend(buf, len, MPI_DOUBLE, *p, comm->id, comm->mpi_comm, req++);

    buf += len;
    send_size+=len;
  }
  return send_size;
}

void exec_mpi_wait(MPI_Request* req, int n)
{
  MPI_Waitall(n,req,MPI_STATUSES_IGNORE);
}


void exec_mpi_reduce_sum(double *val, double* output,
                 const mpi_comm_wrapper* comm)
{
  MPI_Allreduce(val, output, 1, MPI_DOUBLE, MPI_SUM, comm->mpi_comm);
}


void gs_op_cuda(double* w, int dom, int op, int in_transpose)
{
  cudaDeviceSynchronize();
  timer.Start();
  cudaCheckError();
  bool transpose = (in_transpose!=0);

  const unsigned recv = 0^transpose, send = 1^transpose;

  local_gather_cuda(w,w,&(gpu_dom.local_map[0^transpose]), NO_COMM_MASK, NULL);

  cudaCheckError();
  //local_init_cuda(w,gpu_dom.d_flagged_primaries,gpu_dom.flagged_primaries_size);

  cudaCheckError();
  
  if (gpu_dom.comm.np > 1)
  {
    cudaDeviceSynchronize();
    timer1.Start();
    // Post mpi receives
    int recv_size = exec_mpi_recvs(gpu_dom.h_buffer, &(gpu_dom.comm), &(gpu_dom.comm_struct[recv]), gpu_dom.req);

    // Fill send buffer
    local_scatter_cuda(gpu_dom.d_buffer+recv_size, w, &(gpu_dom.comm_map[send]), NULL);

    // Copy buffer from device to host
    cudaMemcpy(gpu_dom.h_buffer+recv_size, gpu_dom.d_buffer+recv_size, 
               gpu_dom.comm_map[send].size_to*sizeof(double), cudaMemcpyDeviceToHost);

    // Send host buffer
    int send_size = exec_mpi_sends( gpu_dom.h_buffer+recv_size, &(gpu_dom.comm), &(gpu_dom.comm_struct[send]), 
                    &(gpu_dom.req[gpu_dom.comm_struct[recv].n ]));

    // Wait for mpi communication to terminate
    exec_mpi_wait(gpu_dom.req, gpu_dom.comm_struct[0].n+gpu_dom.comm_struct[1].n);
    time_comm += timer.GetET();

    // Copy buffer from host to device
    cudaMemcpy(gpu_dom.d_buffer, gpu_dom.h_buffer, recv_size*sizeof(double), cudaMemcpyHostToDevice);

    // Gather from buffer
    local_gather_cuda(w, gpu_dom.d_buffer, &(gpu_dom.comm_map[recv]), NO_COMM_MASK, NULL );
  }

  local_scatter_cuda(w, w, &(gpu_dom.local_map[1^transpose]), NULL);
  cudaDeviceSynchronize();
  time_gs += timer.GetET();
}

void gs_op_cuda_mpi(double* w, int dom, int op, int in_transpose)
{
//   cudaDeviceSynchronize();
//   timer.Start();
  cudaCheckError();
  bool transpose = (in_transpose!=0);

  const unsigned recv = 0^transpose, send = 1^transpose;

  // Post mpi receives
  int recv_size = exec_mpi_recvs(gpu_dom.h_buffer, &(gpu_dom.comm), &(gpu_dom.comm_struct[recv]), gpu_dom.req);

  local_gather_cuda(w,w,&(gpu_dom.local_map[0^transpose]),BOUNDARY_ONLY,stream[0]);

//   cudaCheckError();

  // Fill send buffer
  local_scatter_cuda(gpu_dom.d_buffer+recv_size, w, &(gpu_dom.comm_map[send]), stream[0]);
  cudaStreamSynchronize(stream[0]);

  local_gather_cuda(w,w,&(gpu_dom.local_map[0^transpose]),INTERIOR_ONLY,stream[1]);

  // Copy buffer from device to host
  cudaMemcpyAsync(gpu_dom.h_buffer+recv_size, gpu_dom.d_buffer+recv_size, 
                  gpu_dom.comm_map[send].size_to*sizeof(double), cudaMemcpyDeviceToHost, stream[0]);
  cudaStreamSynchronize(stream[0]);
  // Send host buffer
  int send_size = exec_mpi_sends( gpu_dom.h_buffer+recv_size, &(gpu_dom.comm), &(gpu_dom.comm_struct[send]), 
                                  &(gpu_dom.req[gpu_dom.comm_struct[recv].n ]));

  // Wait for mpi communication to terminate
  exec_mpi_wait(gpu_dom.req, gpu_dom.comm_struct[0].n+gpu_dom.comm_struct[1].n);

  // Copy buffer from host to device
  cudaMemcpyAsync(gpu_dom.d_buffer, gpu_dom.h_buffer, recv_size*sizeof(double), cudaMemcpyHostToDevice,stream[0]);
  cudaDeviceSynchronize();
  // Gather from buffer
  local_gather_cuda(w, gpu_dom.d_buffer, &(gpu_dom.comm_map[recv]), NO_COMM_MASK, NULL );

  local_scatter_cuda(w, w, &(gpu_dom.local_map[1^transpose]), NULL);
//   cudaDeviceSynchronize();
//   time_gs += timer.GetET();
}


void add2s2_cuda(double *a, double *b, double c1, int n)
{
  cublasDaxpy(cublas_handle, n, &c1, b, 1, a, 1);
  cudaCheckError();
}


__global__ void add2s1_kernel(double *a, double *b, double c1, int n)
{
  int tid = blockIdx.x*blockDim.x + threadIdx.x;
  if (threadIdx.x < n) {
    a[tid] = c1*a[tid] + b[tid];
  }
}

void add2s1_cuda(double *a, double *b, double c1, int n)
{

 // TODO: should probably merge into single kernel

//   double one = 1.;
//   cublasDscal(cublas_handle, n, &c1, a, 1); 
//   cudaCheckError();
//   cublasDaxpy(cublas_handle, n, &one, b, 1, a, 1);
//   cudaCheckError();

  int block = 256;
  int grid = (n + block - 1) / block;
  add2s1_kernel<<<grid, block>>>(a, b, c1, n);
  cudaCheckError();
}

__global__
void mask_kernel(double* w, int size, double* mask)
{
  int tid = threadIdx.x + blockDim.x*blockIdx.x;
  int nthreads = blockDim.x*gridDim.x;
  int i, j;
  for (i = tid; i < size; i += nthreads){
    j = ((int) mask[i]) - 1;
    w[j] = 0.;
  }
}

void mask_cuda(double *w, int nid, double* mask, int mask_length)
{
  if (1 || nid == 0)
  {
    int block = 128;
    int grid = (mask_length + block - 1) / block;
    mask_kernel<<<grid,block>>>(w,mask_length, mask);
  }
}

void rzero_cuda(double *a, int n)
{
  double zero = 0.;
  cudaCheckError();
  cublasDscal(cublas_handle, n, &zero, a, 1);
  cudaCheckError();
}

void copy_cuda(double *a, double* b, int n)
{
  cudaCheckError();
  cublasDcopy(cublas_handle, n, b, 1, a, 1); 
  cudaCheckError();
}


__forceinline__ __device__
double __shfl_down_double(double a, unsigned int delta)
{
  return __hiloint2double(__shfl_down(__double2hiint(a), delta),
                          __shfl_down(__double2loint(a), delta));
}

#define GLSC3_BLOCK 256

__forceinline__ __device__
double breduce(volatile double *buf)
{
  int wid = threadIdx.x / WARP_SIZE;
  int laneid = threadIdx.x % WARP_SIZE;
  double a = buf[threadIdx.x];
  #pragma unroll 5
  for (int i = WARP_SIZE/2; i >= 1; i = i >> 1) {
    double b = __shfl_down_double(a, i);
    a += b;
  }
  if (laneid == 0)
    buf[wid] = a;
  __syncthreads();
  if (wid == 0) {
    if (laneid < GLSC3_BLOCK/WARP_SIZE)
      a = buf[laneid];
    else
      a = 0;
    for (int i = GLSC3_BLOCK/WARP_SIZE/2; i >= 1; i = i >> 1) {
      double b = __shfl_down_double(a, i);
      a += b;
    }
  }
  return a;
}


__global__ 
void glsc3_cuda_kernel(double* a, double* b, double* mult, double* result, int n)
{
  __shared__ double smem[GLSC3_BLOCK];
  int tid = blockIdx.x*blockDim.x+threadIdx.x;
  if (tid < n)
  {
    smem[threadIdx.x] = a[tid]*b[tid]*mult[tid];
  } else {
    smem[threadIdx.x] = 0;
  }
  __syncthreads();
  double sum = breduce(smem);
  if (threadIdx.x == 0)
    result[blockIdx.x] = sum;
}


double glsc3_cuda(double *a, double* b, double* mult,  int n)
{
  cudaCheckError();

  int block = GLSC3_BLOCK;
  int grid = (n+block-1)/block;

  glsc3_cuda_kernel<<<grid,block>>>(a,b,mult,gpu_dom.d_temp,n);

  double glsc3 = thrust::reduce((thrust::device_ptr<double>)gpu_dom.d_temp,
                                (thrust::device_ptr<double>)(gpu_dom.d_temp+grid));
 
  exec_mpi_reduce_sum(&glsc3,&glsc3,&(gpu_dom.comm));

  cudaCheckError();
  return glsc3;
}


// __global__
// void glsc3_cuda_kernel(double* a, double* b, double* mult, double* result, int n)
// {
//   int tid = blockIdx.x*blockDim.x+threadIdx.x;
//   while (tid < n)
//   {
//     result[tid] = a[tid]*b[tid]*mult[tid];
//     tid += gridDim.x*blockDim.x;
//   }
// }

// double glsc3_cuda(double *a, double* b, double* mult,  int n)
// {
//   cudaCheckError();

//   double glsc3;
//   // TODO: This could be made faster by having a single kernel followed by reduction across block,
//   // instead of writing to global memory
//   int cta_size = 128;
//   int grid_size=min(4096,( (n+cta_size-1)/cta_size));

//   glsc3_cuda_kernel<<<grid_size,cta_size>>>(a,b,mult,gpu_dom.d_temp,n);

//   thrust::device_ptr<double> beg(gpu_dom.d_temp);
//   glsc3 = thrust::reduce(beg,beg+n);

//   // printf("before reduce %e\n",glsc3);

//   exec_mpi_reduce_sum(&glsc3,&glsc3,&(gpu_dom.comm));

//   //printf("after educe %e\n",glsc3);

//   cudaCheckError();
//   return glsc3;
// }


void solveM_cuda(double *z, double* r, int n)
{
  copy_cuda(z,r,n);
}

void axcuda_no_overlap(double* w, double* u, double *g, double *dxm1, double* dxtm1,
            int nx1, int ny1, int nz1, int nelt, int ldim, int nid, 
	    double* mask, int mask_length, double* flop_a)
{

  axcuda_e(w,u,g,dxm1,dxtm1,nx1,ny1,nz1,nelt,ldim,NO_COMM_MASK,NULL);

  // TODO: Currently, parameters dom and op are ignored
  gs_op_cuda(w,1,1,0); 

  int n = nx1*ny1*nz1*nelt;
  add2s2_cuda(w,u,.1,n);
  mask_cuda(w,nid, mask, mask_length);

  int nxyz = nx1*ny1*nz1;
  *flop_a += (19*nxyz+12*nx1*nxyz)*nelt;
}

void axcuda_part_overlap(double* w, double* u, double *g, double *dxm1, double* dxtm1,
            int nx1, int ny1, int nz1, int nelt, int ldim, int nid, 
	    double* mask, int mask_length, double* flop_a)
{

  axcuda_e(w,u,g,dxm1,dxtm1,nx1,ny1,nz1,nelt,ldim,NO_COMM_MASK,NULL);

  // TODO: Currently, parameters dom and op are ignored
  if (gpu_dom.comm.np > 1) {
    gs_op_cuda_mpi(w,1,1,0);
  } else  {
    gs_op_cuda(w,1,1,0); 
  }

  int n = nx1*ny1*nz1*nelt;
  add2s2_cuda(w,u,.1,n);
  mask_cuda(w,nid, mask, mask_length);

  int nxyz = nx1*ny1*nz1;
  *flop_a += (19*nxyz+12*nx1*nxyz)*nelt;
}

void axcuda_tot_overlap(double* w, double* u, double *g, double *dxm1, double* dxtm1,
            int nx1, int ny1, int nz1, int nelt, int ldim, int nid, 
	    double* mask, int mask_length, double* flop_a)
{
#ifdef TIME_AX
  timer.Start();
#endif
  axcuda_e(w,u,g,dxm1,dxtm1,nx1,ny1,nz1,nelt,ldim,BOUNDARY_ONLY,NULL);
#ifdef TIME_AX
  cudaDeviceSynchronize();
  timeax[1] += timer.GetET();
  timer.Start();
#endif

  int in_transpose = 0;
  bool transpose = (in_transpose!=0);

  const unsigned recv = 0^transpose, send = 1^transpose;

  // Post mpi receives
  int recv_size = exec_mpi_recvs(gpu_dom.h_buffer, &(gpu_dom.comm), &(gpu_dom.comm_struct[recv]), gpu_dom.req);

  local_gather_cuda(w, w, &(gpu_dom.local_map[0^transpose]), BOUNDARY_ONLY, NULL);

  // Fill send buffer
  local_scatter_cuda(gpu_dom.d_buffer+recv_size, w, &(gpu_dom.comm_map[send]), NULL);
#ifdef TIME_AX
  cudaDeviceSynchronize();
  timeax[2] += timer.GetET();
  timer.Start();
#endif

  // interior points kernels: Ax and gather
  axcuda_e(w,u,g,dxm1,dxtm1,nx1,ny1,nz1,nelt,ldim,INTERIOR_ONLY,stream[1]);
  local_gather_cuda(w,w,&(gpu_dom.local_map[0^transpose]),INTERIOR_ONLY,stream[1]);

  // Copy buffer from device to host
  cudaMemcpyAsync(gpu_dom.h_buffer+recv_size, gpu_dom.d_buffer+recv_size, 
                  gpu_dom.comm_map[send].size_to*sizeof(double), cudaMemcpyDeviceToHost, stream[0]);
  cudaStreamSynchronize(stream[0]);

  // Send host buffer
  int send_size = exec_mpi_sends( gpu_dom.h_buffer+recv_size, &(gpu_dom.comm), &(gpu_dom.comm_struct[send]), 
                                  &(gpu_dom.req[gpu_dom.comm_struct[recv].n ]));


  // Wait for mpi communication to terminate, overlaps w/ interior points kernels
  exec_mpi_wait(gpu_dom.req, gpu_dom.comm_struct[0].n+gpu_dom.comm_struct[1].n);

  // Copy buffer from host to device, overlaps with interior points kernels
  cudaMemcpyAsync(gpu_dom.d_buffer, gpu_dom.h_buffer, recv_size*sizeof(double), cudaMemcpyHostToDevice,stream[0]);

  // Gather from buffer
  local_gather_cuda(w, gpu_dom.d_buffer, &(gpu_dom.comm_map[recv]), NO_COMM_MASK, stream[0]);
#ifdef TIME_AX
  cudaDeviceSynchronize();
  timeax[3] += timer.GetET();
  timer.Start();
#endif

  local_scatter_cuda(w, w, &(gpu_dom.local_map[1^transpose]), NULL);
#ifdef TIME_AX
  cudaDeviceSynchronize();
  timeax[4] += timer.GetET();
  timer.Start();
#endif

  int n = nx1*ny1*nz1*nelt;
  add2s2_cuda(w,u,.1,n);
  mask_cuda(w,nid, mask, mask_length);

  int nxyz = nx1*ny1*nz1;
  *flop_a += (19*nxyz+12*nx1*nxyz)*nelt;
#ifdef TIME_AX
  cudaDeviceSynchronize();
  timeax[5] += timer.GetET();
#endif
}


extern "C"
{
  void gs_setup_cuda(const uint* map_local_0, const uint* map_local_1, const uint* flagged_primaries)
  {
    // Initialize data required for gather-scatter operation
    fill_gpu_maps( &(gpu_dom.local_map[0]), map_local_0);
    fill_gpu_maps( &(gpu_dom.local_map[1]), map_local_1);

    fill_flagged_primaries_map(&(gpu_dom.d_flagged_primaries),flagged_primaries);

  }

  void gs_comm_setup_cuda(const uint comm_0_n, const uint* comm_0_p, const uint* comm_0_size, const uint comm_0_total,
                          const uint comm_1_n, const uint* comm_1_p, const uint* comm_1_size, const uint comm_1_total,
                          const uint* map_comm_0, const uint* map_comm_1,
                          uint buffer_size,
                          const MPI_Comm* mpi_comm,
                          int comm_id,
                          int comm_np)
  {
    // Duplicate the MPI communicator
    MPI_Comm_dup( (*mpi_comm), &(gpu_dom.comm.mpi_comm) );
    gpu_dom.comm.id = comm_id;
    gpu_dom.comm.np = comm_np;

//     printf("******** P(%d): recv n = %d, tot = %d, send n = %d, tot = %d\n", 
//            comm_id, comm_0_n, comm_0_total, comm_1_n, comm_1_total);
//     for (int i = 0; i < comm_0_n; i++)
//       printf("P(%d): recv %d size: %d\n", comm_id, i, comm_0_size[i]);
//     for (int i = 0; i < comm_1_n; i++)
//       printf("P(%d): send %d size: %d\n", comm_id, i, comm_1_size[i]);
    if (gpu_dom.comm.np > 1)
    {
      // Initialize the communication structure
      init_comm_struct( &(gpu_dom.comm_struct[0]), comm_0_n, comm_0_p, comm_0_size, comm_0_total);
      init_comm_struct( &(gpu_dom.comm_struct[1]), comm_1_n, comm_1_p, comm_1_size, comm_1_total);
      cudaCheckError();

      // Create the MPI gather-scatter maps
      fill_gpu_maps( &(gpu_dom.comm_map[0]), map_comm_0);
      fill_gpu_maps( &(gpu_dom.comm_map[1]), map_comm_1);
      cudaCheckError();

      // Allocate the send and receive buffers on host and device
      gpu_dom.buffer_size = buffer_size;
      gpu_dom.h_buffer= (double*) malloc( (buffer_size)*sizeof(double));
      cudaMalloc((double **) &(gpu_dom.d_buffer), buffer_size*sizeof(double));
      cudaCheckError();

      // Create the array of MPI requests
      gpu_dom.req = (MPI_Request*) malloc( (comm_0_n+comm_1_n)*sizeof(MPI_Request));
      cudaCheckError();
    }
  }

  void cg_cuda_set_device_(int* nid)
  {
    int gpu_count;
    cudaGetDeviceCount(&gpu_count);
    int device_id = (*nid)%gpu_count;
    cudaSetDevice(device_id);
    printf("rank %d selecting gpu %d\n",*nid,device_id);

  }

  void cg_cuda_init_(double* x, double* f, double* g, double* c, double* r, double* w, double* p, double* z, 
                     double* cmask,
                     int* nx1, int* ny1, int* nz1, int* nelt, int* ldim, double* dxm1, double* dxtm1, 
                     int* niter, double* flop_cg, const int *gsh_handle, int* nid)
  {
//     if (gpu_dom.comm.id == 53)
//     printf("P(%d): local gather size_from = %d, scatter size_from = %d, send size_from = %d, recv size_from = %d\n", 
//            gpu_dom.comm.id,
//            gpu_dom.local_map[0].size_from, gpu_dom.local_map[1].size_from,
//            gpu_dom.comm_map[0].size_from, gpu_dom.comm_map[1].size_from);
    for (int i = 0; i < 2; i++) {
      cudaStreamCreate(&stream[i]);
      //stream[i] = NULL;
    }
    uint* local_indices_from = (uint*)malloc(gpu_dom.local_map[0].size_from*sizeof(uint));
    uint* comm_indices_from = (uint*)malloc(gpu_dom.comm_map[1].size_from*sizeof(uint));
    cudaMemcpy(local_indices_from, gpu_dom.local_map[0].d_indices_from, 
               gpu_dom.local_map[0].size_from*sizeof(uint), cudaMemcpyDeviceToHost);
    cudaMemcpy(comm_indices_from, gpu_dom.comm_map[1].d_indices_from,
               gpu_dom.comm_map[1].size_from*sizeof(uint), cudaMemcpyDeviceToHost);

//     if (gpu_dom.comm.id == 1) {
//     printf("local:\n");
//     for (int i = 0; i < gpu_dom.local_map[0].size_from; i++) {
//       printf("(%d,%d) ", local_indices_from[i], local_indices_from[i] / 1728);
//     }
//     printf("\n\n");
//     printf("comm:\n");
//     for (int j = 0; j < gpu_dom.comm_map[1].size_from; j++) {
//       printf("(%d,%d) ", comm_indices_from[j], comm_indices_from[j] / 1728);
//     }
//     printf("\n\n");
//     }
    // 
    // setup send point mask
    //
    {
      uint *send_mask = (uint*)malloc(sizeof(uint)*gpu_dom.local_map[0].size_from);
      memset(send_mask, 0, sizeof(uint)*gpu_dom.local_map[0].size_from);
      cudaMalloc(&d_send_mask, sizeof(uint)*gpu_dom.local_map[0].size_from);

      for (int i = 0; i < gpu_dom.local_map[0].size_from; i++) {
        int ind = local_indices_from[i];
        if (std::binary_search(comm_indices_from, comm_indices_from+gpu_dom.comm_map[1].size_from, ind)) {
          send_mask[i] = 1;
        }
      }
      cudaMemcpy(d_send_mask, send_mask, gpu_dom.local_map[0].size_from*sizeof(uint),
                 cudaMemcpyHostToDevice);
//       if (gpu_dom.comm.id == 53)
//       printf("P(%d): send_mask = %d\n", gpu_dom.comm.id,
//              std::count_if(send_mask, send_mask+gpu_dom.local_map[0].size_from, nonZero));
      free(send_mask);
    }

    //
    // setup cell mask
    // 
    {
      uint *sendcell_mask = (uint*)malloc(sizeof(uint)*(*nelt));
      memset(sendcell_mask, 0, sizeof(uint)*(*nelt));
      cudaMalloc(&d_sendcell_mask, sizeof(uint)*(*nelt));


      int nxyz = (*nx1)*(*ny1)*(*nz1);
      for (int i = 0; i < gpu_dom.comm_map[1].size_from; i++) {
        sendcell_mask[comm_indices_from[i]/nxyz] = 1;
      }
      cudaMemcpy(d_sendcell_mask, sendcell_mask, sizeof(uint)*(*nelt),
                 cudaMemcpyHostToDevice);
//       if (gpu_dom.comm.id == 53)
//       printf("P(%d): sendcell_mask = %d, nelt = %d\n", gpu_dom.comm.id,
//              std::count_if(sendcell_mask, sendcell_mask+(*nelt), nonZero), *nelt);
      free(sendcell_mask);
    }

    free(local_indices_from);
    free(comm_indices_from);
    


    // Initialize gpu_dom structure
    // Note: the gsh structure on the GPU is already initialized, since gs_cuda_setup is called in the proxy_setupds function in driver.f

    gpu_dom.nid = (*nid);
    gpu_dom.nx1 = (*nx1);
    gpu_dom.ny1 = (*ny1);
    gpu_dom.nz1 = (*nz1);
    gpu_dom.ldim= (*ldim);
    gpu_dom.nelt = (*nelt);
    gpu_dom.niter = (*niter);
    gpu_dom.mask_length = (int) cmask[1];
    //printf("mask_length = %d \n", gpu_dom.mask_length);

    int nxyz = (*nx1)*(*ny1)*(*nz1);
    
    // Initializing the Cublas library 
    if (cublas_handle==NULL)
      cublasCreate(&cublas_handle);

    cudaEventCreateWithFlags(&(gpu_dom.reduced_value_event),cudaEventDisableTiming);
    cudaCheckError();

    // malloc GPU memory for u, w, ur, us, ut, g, dxm1, dxtm1 
    cudaMalloc((void **)&gpu_dom.d_w, gpu_dom.nelt*nxyz*sizeof(double));
    cudaMalloc((void **)&gpu_dom.d_f, gpu_dom.nelt*nxyz*sizeof(double));
    cudaMalloc((void **)&gpu_dom.d_c, gpu_dom.nelt*nxyz*sizeof(double));
    cudaMalloc((void **)&gpu_dom.d_r, gpu_dom.nelt*nxyz*sizeof(double));
    cudaMalloc((void **)&gpu_dom.d_p, gpu_dom.nelt*nxyz*sizeof(double));
    cudaMalloc((void **)&gpu_dom.d_z, gpu_dom.nelt*nxyz*sizeof(double));
    cudaMalloc((void **)&gpu_dom.d_x, gpu_dom.nelt*nxyz*sizeof(double));
    cudaMalloc((void **)&gpu_dom.d_temp, gpu_dom.nelt*nxyz*sizeof(double));
    cudaMalloc((void **)&gpu_dom.d_g, gpu_dom.nelt*nxyz*2*gpu_dom.ldim*sizeof(double));
    cudaMalloc((void **)&gpu_dom.d_dxm1, gpu_dom.nx1*gpu_dom.nx1*sizeof(double));
    cudaMalloc((void **)&gpu_dom.d_dxtm1, gpu_dom.nx1*gpu_dom.nx1*sizeof(double));
    cudaMalloc((void **)&gpu_dom.d_mask, gpu_dom.mask_length*sizeof(double));
    
    cudaMallocHost(&gpu_dom.reduced_value,sizeof(double));

    cudaCheckError();

    // copy data to the GPU

    cudaMemcpy(gpu_dom.d_w, w, gpu_dom.nelt*nxyz*sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpy(gpu_dom.d_f, f, gpu_dom.nelt*nxyz*sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpy(gpu_dom.d_c, c, gpu_dom.nelt*nxyz*sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpy(gpu_dom.d_r, r, gpu_dom.nelt*nxyz*sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpy(gpu_dom.d_p, p, gpu_dom.nelt*nxyz*sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpy(gpu_dom.d_z, z, gpu_dom.nelt*nxyz*sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpy(gpu_dom.d_x, x, gpu_dom.nelt*nxyz*sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpy(gpu_dom.d_p, p, gpu_dom.nelt*nxyz*sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpy(gpu_dom.d_mask, cmask+2, gpu_dom.mask_length*sizeof(double), cudaMemcpyHostToDevice);


    // Switch to AoS for d_g
#ifdef AOS
    double* g_tmp = (double*) malloc(gpu_dom.nelt*nxyz*2*gpu_dom.ldim*sizeof(double));
    int lt = nxyz*gpu_dom.nelt;
    for (int i=0;i<lt;i++)
      for (int j=0;j<6;j++)
        g_tmp[j*lt+i] = g[i*6+j];
    cudaMemcpy(gpu_dom.d_g, g_tmp, gpu_dom.nelt*nxyz*2*gpu_dom.ldim*sizeof(double), cudaMemcpyHostToDevice);
#else
    cudaMemcpy(gpu_dom.d_g, g, gpu_dom.nelt*nxyz*2*gpu_dom.ldim*sizeof(double), cudaMemcpyHostToDevice);
#endif

    cudaMemcpy(gpu_dom.d_dxm1, dxm1, gpu_dom.nx1*gpu_dom.nx1*sizeof(double), cudaMemcpyHostToDevice);
    cudaMemcpy(gpu_dom.d_dxtm1, dxtm1, gpu_dom.nx1*gpu_dom.nx1*sizeof(double), cudaMemcpyHostToDevice);



    cudaCheckError();

    return;
  }


  __global__ void init_t(double *t1, double *t2, double *t3, int n)
  {
    int tid = blockIdx.x*blockDim.x + threadIdx.x;
    if (tid < n) {
      t1[tid] = 1.0;
      t2[tid] = 1.0;
      t3[tid] = 1.0;
    }
  }

  void cg_cuda_(double* r, int* copy_to_cpu, double *flop_cg, double *flop_a)
  {
    cudaProfilerStart();
    cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
    cudaDeviceSetSharedMemConfig(cudaSharedMemBankSizeEightByte);

    int n = gpu_dom.nx1 * gpu_dom.ny1 * gpu_dom.nz1 * gpu_dom.nelt;
    double pap = 0.0;

    // set machine tolerances
    double one = 1.;
    double eps = 1.e-20;

    if (one+eps == one) 
      eps = 1.e-14;
    if (one+eps == one) 
      eps = 1.e-7;
    double rtz1 = 1.0;

    cudaCheckError();
    rzero_cuda(gpu_dom.d_x, n);
    copy_cuda(gpu_dom.d_r, gpu_dom.d_f, n);

    // Zero out Dirichlet conditions
    mask_cuda(gpu_dom.d_r, gpu_dom.nid, gpu_dom.d_mask, gpu_dom.mask_length);

    double rnorm = sqrt(glsc3_cuda(gpu_dom.d_r, gpu_dom.d_c, gpu_dom.d_r, n));

//     double *t1, *t2, *t3;
//     cudaMalloc(&t1, n*sizeof(double));
//     cudaMalloc(&t2, n*sizeof(double));
//     cudaMalloc(&t3, n*sizeof(double));
//     {
//       int block = 256;
//       int grid = (n + block - 1) / block;
//       init_t<<<grid, block>>>(t1, t2, t3, n);
//     }
//     double t = glsc3_cuda(t1, t2, t3, n);
//     printf("t = %f, n = %d\n", t, n);
//     cudaFree(t1);
//     cudaFree(t2);
//     cudaFree(t3);
      
    int iter = 0;
    if (gpu_dom.nid==0) 
      printf("cg:%4d %11.4e\n",iter,rnorm);

    int miter = gpu_dom.niter;
    double alpha, beta;

    for (iter=1; iter <= miter; iter++)
    {
       solveM_cuda(gpu_dom.d_z, gpu_dom.d_r, n);

       double rtz2=rtz1;
       rtz1 = glsc3_cuda(gpu_dom.d_r, gpu_dom.d_c, gpu_dom.d_z, n);

       beta = rtz1/rtz2;
       if (iter==1) 
         beta=0.0;

       add2s1_cuda(gpu_dom.d_p, gpu_dom.d_z, beta, n);
       
       if (gpu_dom.comm.np == 1) {
         axcuda_no_overlap(gpu_dom.d_w, gpu_dom.d_p, gpu_dom.d_g, gpu_dom.d_dxm1, gpu_dom.d_dxtm1, gpu_dom.nx1, gpu_dom.ny1, gpu_dom.nz1, gpu_dom.nelt, gpu_dom.ldim, gpu_dom.nid, gpu_dom.d_mask, gpu_dom.mask_length, flop_a);         
       } else {
#ifdef TIME_AX
         cudaDeviceSynchronize();
         timer2.Start();
#endif
         axcuda_tot_overlap(gpu_dom.d_w, gpu_dom.d_p, gpu_dom.d_g, gpu_dom.d_dxm1, gpu_dom.d_dxtm1, gpu_dom.nx1, gpu_dom.ny1, gpu_dom.nz1, gpu_dom.nelt, gpu_dom.ldim, gpu_dom.nid, gpu_dom.d_mask, gpu_dom.mask_length, flop_a);
#ifdef TIME_AX
         cudaDeviceSynchronize();
         timeax[0] += timer2.GetET();
#endif
       }

       pap = glsc3_cuda(gpu_dom.d_w, gpu_dom.d_c, gpu_dom.d_p, n);
       alpha=rtz1/pap;
       double alphm = -alpha;

       add2s2_cuda(gpu_dom.d_x, gpu_dom.d_p, alpha, n);
       add2s2_cuda(gpu_dom.d_r, gpu_dom.d_w, alphm, n);

       double rtr = glsc3_cuda(gpu_dom.d_r, gpu_dom.d_c, gpu_dom.d_r, n);

       rnorm = sqrt(rtr);
    }

    *flop_cg += miter*15.0*n + 3.0*n;

    if (gpu_dom.nid==0) 
      printf("cg:%4d %11.4e %11.4e %11.4e %11.4e\n",iter,rnorm,alpha,beta,pap);

    if ((*copy_to_cpu)==1)
      cudaMemcpy(r, gpu_dom.d_r, n*sizeof(double), cudaMemcpyDeviceToHost);
//     if (gpu_dom.comm.id == 0) 
//     printf("P(%d): time_gs = %f ms, time_comm = %f ms\n", 
//            gpu_dom.nid, time_gs*1e3, time_comm*1e3);


    cudaProfilerStop();
  }

  void cg_cuda_free_() 
  {
//     {
//     float maxtime;
//     MPI_Allreduce(timeax, &maxtime, 1, MPI_FLOAT, MPI_MAX, gpu_dom.comm.mpi_comm);
//     if (fabs(timeax[0] - maxtime) < 1e-5 || gpu_dom.comm.id == 0) {
//     printf("P(%d): timeax = %f, %f, %f, %f, %f, %f\n",
//            gpu_dom.comm.id, timeax[0]*1e3, timeax[1]*1e3, 
//            timeax[2]*1e3, timeax[3]*1e3, timeax[4]*1e3, timeax[5]*1e3);
//     printf("P(%d): local gather size_from = %d, scatter size_from = %d, send size_from = %d, recv size_from = %d\n", 
//            gpu_dom.comm.id,
//            gpu_dom.local_map[0].size_from, gpu_dom.local_map[1].size_from,
//            gpu_dom.comm_map[0].size_from, gpu_dom.comm_map[1].size_from);
//     }
//     }

    for (int i = 0; i < 2; i++)
      cudaStreamDestroy(stream[i]);

    cudaFree(d_send_mask);
    cudaFree(d_sendcell_mask);

    /* free GPU memory for u, w, ur, us, ut, g, dxm1, dxtm1  */

    cudaCheckError();

    cudaFree(gpu_dom.local_map[0].d_offsets);
    cudaFree(gpu_dom.local_map[0].d_indices_from);
    cudaFree(gpu_dom.local_map[0].d_indices_from_COO);
    cudaFree(gpu_dom.local_map[0].d_indices_to);

    cudaFree(gpu_dom.local_map[1].d_offsets);
    cudaFree(gpu_dom.local_map[1].d_indices_from);
    cudaFree(gpu_dom.local_map[1].d_indices_from_COO);
    cudaFree(gpu_dom.local_map[1].d_indices_to);

    cudaFree(gpu_dom.comm_map[0].d_offsets);
    cudaFree(gpu_dom.comm_map[0].d_indices_from);
    cudaFree(gpu_dom.comm_map[0].d_indices_from_COO);
    cudaFree(gpu_dom.comm_map[0].d_indices_to);

    cudaFree(gpu_dom.comm_map[1].d_offsets);
    cudaFree(gpu_dom.comm_map[1].d_indices_from);
    cudaFree(gpu_dom.comm_map[1].d_indices_from_COO);
    cudaFree(gpu_dom.comm_map[1].d_indices_to);

    cudaCheckError();
    cudaFree(gpu_dom.d_w);
    cudaCheckError();
    cudaFree(gpu_dom.d_p);
    cudaCheckError();
    cudaFree(gpu_dom.d_g);
    cudaCheckError();
    cudaFree(gpu_dom.d_dxm1);
    cudaCheckError();
    cudaFree(gpu_dom.d_dxtm1);
    cudaCheckError();
    cudaFree(gpu_dom.d_mask);
    cudaCheckError();


    return;
  }

} // extern C





