// CLAPACKShim — legacy BLAS/LAPACK entry points with int32_t-typed wrappers (specification §2).
//
// The deployment floor is iOS 15, which predates the ACCELERATE_NEW_LAPACK headers (iOS 16.4).
// The legacy CLAPACK/CBLAS symbols are therefore the ones this package calls, and Apple marks
// them deprecated. Calling them from Swift would produce deprecation warnings that
// `-warnings-as-errors` turns into failures, so every BLAS/LAPACK call in the package goes
// through this target: the implementation file suppresses the deprecation diagnostics locally
// and this header exposes plain C prototypes that Swift imports without any diagnostic.
//
// Conventions:
//   * all matrices are column-major;
//   * all dimensions, increments and pivot indices are int32_t (LAPACK indices are 32-bit);
//   * LAPACK wrappers return `info` (0 on success, < 0 for an illegal argument, > 0 for a
//     numerical failure such as a zero pivot);
//   * no wrapper retains a pointer beyond the call.

#ifndef ZTRONLP_CLAPACK_SHIM_H
#define ZTRONLP_CLAPACK_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: BLAS level 1

/// xᵀy.
double ztlp_ddot(int32_t n, const double *x, int32_t incx, const double *y, int32_t incy);
/// y ← αx + y.
void ztlp_daxpy(int32_t n, double alpha, const double *x, int32_t incx, double *y, int32_t incy);
/// x ← αx.
void ztlp_dscal(int32_t n, double alpha, double *x, int32_t incx);
/// ‖x‖₂.
double ztlp_dnrm2(int32_t n, const double *x, int32_t incx);

// MARK: BLAS levels 2 and 3

/// y ← α·op(A)·x + β·y, with op(A) = A when `transpose` is 0 and Aᵀ otherwise. A is m × n.
void ztlp_dgemv(int32_t transpose, int32_t m, int32_t n, double alpha, const double *a, int32_t lda,
                const double *x, int32_t incx, double beta, double *y, int32_t incy);
/// C ← α·op(A)·op(B) + β·C. C is m × n, op(A) is m × k, op(B) is k × n.
void ztlp_dgemm(int32_t transposeA, int32_t transposeB, int32_t m, int32_t n, int32_t k, double alpha,
                const double *a, int32_t lda, const double *b, int32_t ldb, double beta, double *c,
                int32_t ldc);
/// C ← α·A·Aᵀ + β·C (transpose == 0, A is n × k) or α·Aᵀ·A + β·C (transpose != 0, A is k × n).
/// Only the triangle selected by `upper` is referenced and written.
void ztlp_dsyrk(int32_t upper, int32_t transpose, int32_t n, int32_t k, double alpha, const double *a,
                int32_t lda, double beta, double *c, int32_t ldc);
/// Solves op(A)·x = b in place for a triangular n × n matrix A.
void ztlp_dtrsv(int32_t upper, int32_t transpose, int32_t unitDiagonal, int32_t n, const double *a,
                int32_t lda, double *x, int32_t incx);

// MARK: LAPACK — LU with partial pivoting

/// A = P·L·U in place. `ipiv` receives m∧n one-based pivot rows.
int32_t ztlp_dgetrf(int32_t m, int32_t n, double *a, int32_t lda, int32_t *ipiv);
/// Solves op(A)·X = B from the dgetrf factors; `transpose` selects Aᵀ.
int32_t ztlp_dgetrs(int32_t transpose, int32_t n, int32_t nrhs, const double *a, int32_t lda,
                    const int32_t *ipiv, double *b, int32_t ldb);
/// Reciprocal 1-norm condition estimate from the dgetrf factors. `anorm` is ‖A‖₁ of the
/// original matrix; `work` needs 4n doubles and `iwork` n int32_t.
int32_t ztlp_dgecon(int32_t n, const double *a, int32_t lda, double anorm, double *rcond, double *work,
                    int32_t *iwork);
/// Factor and solve in one call (reference solver used by the tests).
int32_t ztlp_dgesv(int32_t n, int32_t nrhs, double *a, int32_t lda, int32_t *ipiv, double *b,
                   int32_t ldb);
/// ‖A‖₁ (maximum absolute column sum) of an m × n matrix.
double ztlp_dlange_one(int32_t m, int32_t n, const double *a, int32_t lda);

// MARK: LAPACK — Cholesky

/// A = L·Lᵀ (upper == 0) or Uᵀ·U in place. Returns k > 0 when the leading minor of order k
/// is not positive definite.
int32_t ztlp_dpotrf(int32_t upper, int32_t n, double *a, int32_t lda);
/// Solves A·X = B from the dpotrf factor.
int32_t ztlp_dpotrs(int32_t upper, int32_t n, int32_t nrhs, const double *a, int32_t lda, double *b,
                    int32_t ldb);

// MARK: LAPACK — QR

/// A = Q·R in place (Householder reflectors below the diagonal, scalar factors in `tau`).
/// `work` needs `lwork` ≥ n doubles; pass lwork = -1 to query the optimal size in work[0].
int32_t ztlp_dgeqrf(int32_t m, int32_t n, double *a, int32_t lda, double *tau, double *work,
                    int32_t lwork);
/// C ← op(Q)·C (left != 0) or C·op(Q), with Q from dgeqrf.
int32_t ztlp_dormqr(int32_t left, int32_t transpose, int32_t m, int32_t n, int32_t k, const double *a,
                    int32_t lda, const double *tau, double *c, int32_t ldc, double *work,
                    int32_t lwork);
/// Solves op(A)·X = B for a triangular A, checking for exact singularity.
int32_t ztlp_dtrtrs(int32_t upper, int32_t transpose, int32_t unitDiagonal, int32_t n, int32_t nrhs,
                    const double *a, int32_t lda, double *b, int32_t ldb);

#ifdef __cplusplus
}
#endif

#endif  // ZTRONLP_CLAPACK_SHIM_H
