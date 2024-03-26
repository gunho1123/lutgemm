#include "tests.h"


// void t_matmul_useCublas(float* output, lutGEMM::nQWeight_fp16 nqW, float* input, int n) {
//     lutGEMM::kernel::cublas_gemm_ex(nqW.getDequantiedWeight(), input, output, nqW.mSize, nqW.kSize, n);
// }


#include <cublas_v2.h>
#include <cuda.h>
#include <cuda_fp16.h>



template <typename T, typename S>
inline cublasStatus_t cublas_gemm_ex(T *A,  T *B,  S *C,
                                    int m, int n, int k);
                                    
template<int M, int N, int K, int NUM_BITS, int A_GROUP_SIZE=K>
class batch_lutgemm_fp16{
public:
    static const int num_groups = K/A_GROUP_SIZE;
    float     qW[K   ][NUM_BITS][M][N]; // (-1, 1) 
    uint32_t  bW[K/32][NUM_BITS][M][N]; // bit packed
    float     alpha[num_groups][NUM_BITS][M][N];
    //float    q_bias[num_groups][N];

    float   weight[K][M][N];           // float weight
    float    input[M][K];
    float   output[M][N];


    __half* d_weight_fp16;
    __half*  d_input;

    __half* d_cu_output;
    __half* d_nq_output;

    lutGEMM::nQWeight_fp16 nqW;

    double run(bool run_cublas=true, bool run_lutgemm=false, bool run_gptq=false, int iter=16){
        alloc_cuda();
        makeRandomInput();
        makeRandomWeight();
        makeRandomAlpha();
        dequantizeFrom_qW();
        copy_cpuToCuda();

        nqW.parsing((uint32_t*)bW, (float*)alpha, K, N, M, NUM_BITS, false, num_groups);
        cudaDeviceSynchronize();

        double meanError = checkErr();
        //double meanError = 0;
        cudaDeviceSynchronize();

        if(run_cublas) cublas_latency(M, N, K, d_input, d_weight_fp16, d_cu_output, iter);
        //if(run_lutgemm) lutgemm_latency(nqW, M, N, K, d_input, d_weight_fp16, d_cu_output, iter);
        if(run_lutgemm) batch_lutgemm_latency(nqW, M, N, K, d_input, d_weight_fp16, d_cu_output, iter);

        free_cuda();
        return meanError;
    }

    void lutgemm_latency(lutGEMM::nQWeight_fp16 &nqW, int m, int n, int k, __half* A, __half *B, __half *C, int iter=64){
        timer tm;

        lutGEMM::matmul((void*)C, (void*)A, nqW, m);
        cudaDeviceSynchronize();

        for(int i=0;i<iter;i++){
            tm.start();
            lutGEMM::matmul((void*)C, (void*)A, nqW, m);
            cudaDeviceSynchronize();
            tm.end();
        }
        printf("latency min : %.5fms, max : %.5fms, avg:%.5f\n", tm.min(), tm.max(), tm.mean());
    }

    void batch_lutgemm_latency(lutGEMM::nQWeight_fp16 &nqW, int m, int n, int k, __half* A, __half *B, __half *C, int iter=64){
        timer tm;

        lutGEMM::matmul_batch_lutgemm((void*)C, (void*)A, nqW, m);
        cudaDeviceSynchronize();

        for(int i=0;i<iter;i++){
            tm.start();
            lutGEMM::matmul_batch_lutgemm((void*)C, (void*)A, nqW, m);
            cudaDeviceSynchronize();
            tm.end();
        }
        printf("latency min : %.5fms, max : %.5fms, avg:%.5f\n", tm.min(), tm.max(), tm.mean());
    }

    void cublas_latency(int m, int n, int k, __half* A, __half *B, __half *C, int iter=64){
        timer tm;
        float th = 0;
        cublas_gemm_ex(A, B, C,
                            m, n, k);
        cudaDeviceSynchronize();
        for (int i = 0; i < iter; ++i) {
            tm.start();
            cublasStatus_t success;
            success = cublas_gemm_ex(A, B, C,
                                    m, n, k);
            cudaDeviceSynchronize();
            tm.end();

        }
            printf("latency min : %.5fms, max : %.5fms, avg:%.5f\n", tm.min(), tm.max(), tm.mean());

    }


    double checkErr(){
        //cublas_gemm_ex(d_input, d_weight_fp16, d_cu_output, M, N, K);
        matmul_cpu();
        cudaMemset(d_nq_output, 0, sizeof(float) * M * N);
        lutGEMM::matmul_batch_lutgemm(d_nq_output, d_input, nqW, M);
        cudaDeviceSynchronize();
        return checkOutputMeanError(d_cu_output, d_nq_output);
    }

    double checkOutputMeanError(__half *o1, __half *o2){
        double err=0;
        for(int m=0;m<M;m++){
            for(int n=0;n<N;n++){
                err += std::abs(float(output[m][n]) - float(o2[m*N + n]));
                if(n>500) printf("%f %f\n", float(output[m][n]), float(o2[m*N + n]));
            }
            printf("=================================\n");
        }
        return err/M/N;
    }

    void matmul_cpu(){
        for(int m=0;m<M;m++){
            for(int n=0;n<N;n++){
                output[m][n] = 0;
                for(int k=0;k<K;k++){
                    output[m][n] += input[m][k] * weight[k][m][n];
                }
            }
        }
    }

    /*void makeRandomInput(){
        for(int m=0;m<M;m++)
            for(int k=0;k<K;k++)
                input[m][k] = rand_fp32(); // (-1.0, 1.0) / 2^b
    }*/
    void makeRandomInput(){
        for(int k=0;k<K;k++){
            float temp = rand_fp32();
            for(int m=0;m<M;m++){
                input[m][k] = temp;
            }
        }
    }

    void makeRandomAlpha(){
        for(int g=0;g<num_groups;g++)
            for(int m=0;m<M;m++){
                for(int n=0;n<N;n++){
                    //q_bias[g][n] = rand_fp32()/(1<< NUM_BITS);
                    for(int b=0;b<NUM_BITS;b++)
                        //alpha[g][b][m][n] = rand_fp32()/(1<<b); // (-1.0, 1.0) / 2^b
                        alpha[g][b][m][n] = 1; // (-1.0, 1.0) / 2^b
                }
            }
    }

    /*void makeRandomWeight(){
        for(int m=0;m<M;m++){
            for(int n=0;n<N;n++){
                for(int b=0;b<NUM_BITS;b++){
                    for(int k=0;k<K;k+=32){  //32 단위
                        uint32_t s=0;
                        for(int t=0;t<32;t++){
                            if(rand_bool()){
                                    s |= 1<<t;
                                    qW[k + t][b][m][n] = +1;
                            } else  qW[k + t][b][m][n] = -1;
                        }
                        bW[k/32][b][m][n] = s;
                    }
                }
            }
        }
    }*/
    void makeRandomWeight(){
        for(int n=0;n<N;n++){
            for(int b=0;b<NUM_BITS;b++){
                for(int k=0;k<K;k+=32){  //32 단위
                    uint32_t s=0;
                    for(int t=0;t<32;t++){
                        if(rand_bool()){
                                s |= 1<<t;
                                qW[k + t][b][0][n] = +1;
                                qW[k + t][b][1][n] = +1;
                        } else  {
                            qW[k + t][b][0][n] = -1;
                            qW[k + t][b][1][n] = -1;
                        }
                    }
                    bW[k/32][b][0][n] = s;
                    bW[k/32][b][1][n] = s;
                }
            }
        }
    }

    void dequantizeFrom_qW(){
        for(int m=0;m<M;m++){
            for(int n=0;n<N;n++){
                for(int k=0;k<K;k++){  //32 단위
                    //weight[k][n] = q_bias[k/A_GROUP_SIZE][n];
                    weight[k][m][n] = 0;
                    for(int b=0;b<NUM_BITS;b++){
                        weight[k][m][n] += alpha[k/A_GROUP_SIZE][b][m][n] * qW[k][b][m][n]; 
                    }
                }
            }
        }
    }

    void alloc_cuda(){
        cudaMallocManaged(&d_input    , sizeof(float) * M * K);   
        cudaMallocManaged(&d_weight_fp16, sizeof(float) * K * M * N);   

        cudaMallocManaged(&d_cu_output, sizeof(float) * M * N);       
        cudaMallocManaged(&d_nq_output, sizeof(float) * M * N);


    }
    
    void free_cuda(){
        cudaFree(d_input);
        cudaFree(d_weight_fp16);
        cudaFree(d_cu_output);
        cudaFree(d_nq_output);

    }
    void copy_cpuToCuda(){
        fhCpy(d_input , (float*)input  ,M * K);
        fhCpy(d_weight_fp16, (float*)weight ,K * M * N);

        cudaDeviceSynchronize();
    }

    void hfCpy(float* a, __half* b, int size){
       for(int i=0;i<size;i++) a[i] = float(b[i]);
    }
    void fhCpy(__half* a, float* b, int size){
       for(int i=0;i<size;i++) a[i] = __float2half(b[i]);
    }

};

const int H = 512;
TEST(batch_lutgemm_fp16, layer_175b){
    double total_error = 0;
    int e_cnt = 0;

    printf("----------------------------------------------------------------\n");
    printf("Warm up done.\n");
    printf("----------------------------------------------------------------\n");
    printf("M = 1, N = %d, K = %d\n", H, H);
    printf("LUT-GEMM [INT4, FP16, FP16]\n");
    { auto t = std::make_shared<batch_lutgemm_fp16<2, H, H, 4, 128>>(); total_error += t->run(false, true, false); e_cnt++; } 
    printf("%.5f\n", total_error);

}




template <typename T, typename S>
inline cublasStatus_t cublas_gemm_ex(T *A,  T *B,  S *C,
                                    int m, int n, int k) {
    static S alpha = 1;
    static S beta  = 0;
    static cublasHandle_t handle = nullptr;
    if(handle == nullptr) cublasCreate(&handle);
    
    cudaDataType_t AType, BType, CType;
    cublasComputeType_t  ComputeType;
    if (std::is_same<T, float>::value) {
        AType = BType = CType = CUDA_R_32F;
        ComputeType = CUBLAS_COMPUTE_32F_FAST_TF32;
    } else if (std::is_same<T, __half>::value) {
        AType = BType = CType = CUDA_R_16F;
        ComputeType = CUBLAS_COMPUTE_16F;
    } else if (std::is_same<T, int8_t>::value) {
        AType = BType = CUDA_R_8I;
        CType = CUDA_R_32I;
        ComputeType = CUBLAS_COMPUTE_32I;
    } else {
        return CUBLAS_STATUS_NOT_SUPPORTED;
    }
    return cublasGemmEx(handle, CUBLAS_OP_N, CUBLAS_OP_N,
                          n, m, k, 
                          &alpha,
                          B, BType, n,
                          A, AType, k,
                          &beta,
                          C, CType, n,
                          ComputeType,
                          CUBLAS_GEMM_DFALT);
}