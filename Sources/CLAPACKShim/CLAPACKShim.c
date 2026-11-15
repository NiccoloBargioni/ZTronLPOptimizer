// CLAPACKShim — implementation. See include/CLAPACKShim.h for the rationale.
//
// Accelerate is included here, and only here, with the deprecation diagnostics switched off
// for the legacy CLAPACK/CBLAS interface (specification §2). ACCELERATE_NEW_LAPACK is
// deliberately left undefined: the new headers require iOS 16.4.

#include "CLAPACKShim.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#include <Accelerate/Accelerate.h>

// The legacy interface types LAPACK integers as __CLPK_integer, which is a 32-bit int on
// every 64-bit Apple platform. The wrappers rely on that, so make it a compile-time fact.
_Static_assert(sizeof(__CLPK_integer) == sizeof(int32_t), "legacy CLAPACK integers must be 32-bit");
_Static_assert(sizeof(int) == sizeof(int32_t), "CBLAS ints must be 32-bit");

// MARK: BLAS level 1

double ztlp_ddot(int32_t n, const double *x, int32_t incx, const double *y, int32_t incy) {
    return cblas_ddot(n, x, incx, y, incy);
}

void ztlp_daxpy(int32_t n, double alpha, const double *x, int32_t incx, double *y, int32_t incy) {
    cblas_daxpy(n, alpha, x, incx, y, incy);
}

void ztlp_dscal(int32_t n, double alpha, double *x, int32_t incx) {
    cblas_dscal(n, alpha, x, incx);
}

double ztlp_dnrm2(int32_t n, const double *x, int32_t incx) {
    return cblas_dnrm2(n, x, incx);
}

// MARK: BLAS levels 2 and 3

void ztlp_dgemv(int32_t transpose, int32_t m, int32_t n, double alpha, const double *a, int32_t lda,
                const double *x, int32_t incx, double beta, double *y, int32_t incy) {
    cblas_dgemv(CblasColMajor, transpose ? CblasTrans : CblasNoTrans, m, n, alpha, a, lda, x, incx,
                beta, y, incy);
}

void ztlp_dgemm(int32_t transposeA, int32_t transposeB, int32_t m, int32_t n, int32_t k, double alpha,
                const double *a, int32_t lda, const double *b, int32_t ldb, double beta, double *c,
                int32_t ldc) {
    cblas_dgemm(CblasColMajor, transposeA ? CblasTrans : CblasNoTrans,
                transposeB ? CblasTrans : CblasNoTrans, m, n, k, alpha, a, lda, b, ldb, beta, c, ldc);
}

void ztlp_dsyrk(int32_t upper, int32_t transpose, int32_t n, int32_t k, double alpha, const double *a,
                int32_t lda, double beta, double *c, int32_t ldc) {
    cblas_dsyrk(CblasColMajor, upper ? CblasUpper : CblasLower, transpose ? CblasTrans : CblasNoTrans,
                n, k, alpha, a, lda, beta, c, ldc);
}

void ztlp_dtrsv(int32_t upper, int32_t transpose, int32_t unitDiagonal, int32_t n, const double *a,
                int32_t lda, double *x, int32_t incx) {
    cblas_dtrsv(CblasColMajor, upper ? CblasUpper : CblasLower, transpose ? CblasTrans : CblasNoTrans,
                unitDiagonal ? CblasUnit : CblasNonUnit, n, a, lda, x, incx);
}

// MARK: LAPACK — LU with partial pivoting

int32_t ztlp_dgetrf(int32_t m, int32_t n, double *a, int32_t lda, int32_t *ipiv) {
    __CLPK_integer m_ = m, n_ = n, lda_ = lda, info = 0;
    dgetrf_(&m_, &n_, a, &lda_, (__CLPK_integer *)ipiv, &info);
    return (int32_t)info;
}

int32_t ztlp_dgetrs(int32_t transpose, int32_t n, int32_t nrhs, const double *a, int32_t lda,
                    const int32_t *ipiv, double *b, int32_t ldb) {
    char trans = transpose ? 'T' : 'N';
    __CLPK_integer n_ = n, nrhs_ = nrhs, lda_ = lda, ldb_ = ldb, info = 0;
    dgetrs_(&trans, &n_, &nrhs_, (double *)a, &lda_, (__CLPK_integer *)ipiv, b, &ldb_, &info);
    return (int32_t)info;
}

int32_t ztlp_dgecon(int32_t n, const double *a, int32_t lda, double anorm, double *rcond, double *work,
                    int32_t *iwork) {
    char norm = '1';
    __CLPK_integer n_ = n, lda_ = lda, info = 0;
    dgecon_(&norm, &n_, (double *)a, &lda_, &anorm, rcond, work, (__CLPK_integer *)iwork, &info);
    return (int32_t)info;
}

int32_t ztlp_dgesv(int32_t n, int32_t nrhs, double *a, int32_t lda, int32_t *ipiv, double *b,
                   int32_t ldb) {
    __CLPK_integer n_ = n, nrhs_ = nrhs, lda_ = lda, ldb_ = ldb, info = 0;
    dgesv_(&n_, &nrhs_, a, &lda_, (__CLPK_integer *)ipiv, b, &ldb_, &info);
    return (int32_t)info;
}

double ztlp_dlange_one(int32_t m, int32_t n, const double *a, int32_t lda) {
    char norm = '1';
    __CLPK_integer m_ = m, n_ = n, lda_ = lda;
    // The '1' norm does not reference the work array.
    return dlange_(&norm, &m_, &n_, (double *)a, &lda_, (double *)0);
}

// MARK: LAPACK — Cholesky

int32_t ztlp_dpotrf(int32_t upper, int32_t n, double *a, int32_t lda) {
    char uplo = upper ? 'U' : 'L';
    __CLPK_integer n_ = n, lda_ = lda, info = 0;
    dpotrf_(&uplo, &n_, a, &lda_, &info);
    return (int32_t)info;
}

int32_t ztlp_dpotrs(int32_t upper, int32_t n, int32_t nrhs, const double *a, int32_t lda, double *b,
                    int32_t ldb) {
    char uplo = upper ? 'U' : 'L';
    __CLPK_integer n_ = n, nrhs_ = nrhs, lda_ = lda, ldb_ = ldb, info = 0;
    dpotrs_(&uplo, &n_, &nrhs_, (double *)a, &lda_, b, &ldb_, &info);
    return (int32_t)info;
}

// MARK: LAPACK — QR

int32_t ztlp_dgeqrf(int32_t m, int32_t n, double *a, int32_t lda, double *tau, double *work,
                    int32_t lwork) {
    __CLPK_integer m_ = m, n_ = n, lda_ = lda, lwork_ = lwork, info = 0;
    dgeqrf_(&m_, &n_, a, &lda_, tau, work, &lwork_, &info);
    return (int32_t)info;
}

int32_t ztlp_dormqr(int32_t left, int32_t transpose, int32_t m, int32_t n, int32_t k, const double *a,
                    int32_t lda, const double *tau, double *c, int32_t ldc, double *work,
                    int32_t lwork) {
    char side = left ? 'L' : 'R';
    char trans = transpose ? 'T' : 'N';
    __CLPK_integer m_ = m, n_ = n, k_ = k, lda_ = lda, ldc_ = ldc, lwork_ = lwork, info = 0;
    dormqr_(&side, &trans, &m_, &n_, &k_, (double *)a, &lda_, (double *)tau, c, &ldc_, work, &lwork_,
            &info);
    return (int32_t)info;
}

int32_t ztlp_dtrtrs(int32_t upper, int32_t transpose, int32_t unitDiagonal, int32_t n, int32_t nrhs,
                    const double *a, int32_t lda, double *b, int32_t ldb) {
    char uplo = upper ? 'U' : 'L';
    char trans = transpose ? 'T' : 'N';
    char diag = unitDiagonal ? 'U' : 'N';
    __CLPK_integer n_ = n, nrhs_ = nrhs, lda_ = lda, ldb_ = ldb, info = 0;
    dtrtrs_(&uplo, &trans, &diag, &n_, &nrhs_, (double *)a, &lda_, b, &ldb_, &info);
    return (int32_t)info;
}

#pragma clang diagnostic pop
