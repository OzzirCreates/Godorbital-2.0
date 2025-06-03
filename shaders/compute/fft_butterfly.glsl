#[compute]
#version 460
/** 
 * FFT Butterfly Factor Precomputation Shader
 * 
 * DESCRIPTION:
 * ------------
 * Precomputes the butterfly factors (twiddle factors) for a Stockham FFT kernel.
 * These factors are used to perform the complex rotations needed in the FFT algorithm.
 * By precomputing them, we avoid expensive trigonometric calculations during the actual FFT.
 * 
 * WHAT ARE BUTTERFLY FACTORS?
 * ---------------------------
 * In FFT algorithms, "butterfly" operations combine pairs of values using complex
 * multiplication by "twiddle factors" (powers of the complex roots of unity).
 * The name comes from the butterfly-like pattern in FFT diagrams.
 * 
 * STOCKHAM FFT:
 * -------------
 * Stockham FFT is an auto-sorting variant that doesn't require bit reversal.
 * It uses a different indexing pattern than Cooley-Tukey FFT but is more
 * GPU-friendly due to better memory access patterns.
 */

// Mathematical constant PI
#define PI (3.141592653589793)

// Compute shader work group configuration
// 64 threads per work group in X, 1 in Y and Z
layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// Output buffer for butterfly factors
layout(std430, set = 0, binding = 0) restrict writeonly buffer FFTBuffer {
    // 2D array of butterfly factors
    // Dimensions: [num_stages][map_size] where num_stages = log2(map_size)
    // Each vec4 contains:
    // .xy = read indices for the butterfly operation
    // .zw = complex twiddle factor (real, imaginary)
    vec4 butterfly[];
};

/** 
 * Calculate e^(j*x) where j is the imaginary unit
 * Returns complex number as vec2(real, imaginary)
 * Uses Euler's formula: e^(jx) = cos(x) + j*sin(x)
 * @param x - angle in radians (must be >= 0)
 */
vec2 exp_complex(in float x) {
    return vec2(cos(x), sin(x));
}

// Macro to access butterfly array with 2D indexing
// Converts (column, stage) coordinates to linear array index
#define BUTTERFLY(col, stage) (butterfly[(stage)*map_size + (col)])

void main() {
    // Calculate FFT size from dispatch dimensions
    // map_size is the total FFT size (must be power of 2)
    // NumWorkGroups * WorkGroupSize * 2 because each butterfly operates on pairs
    const uint map_size = gl_NumWorkGroups.x * gl_WorkGroupSize.x * 2;
    
    // Get current thread's position
    const uint col = gl_GlobalInvocationID.x;   // Column index (0 to map_size-1)
    const uint stage = gl_GlobalInvocationID.y; // FFT stage (0 to log2(map_size)-1)

    // Calculate parameters for this stage
    // stride: distance between butterfly pairs (doubles each stage: 1, 2, 4, 8...)
    uint stride = 1 << stage;
    // mid: half the number of butterflies in each group
    uint mid = map_size >> (stage + 1);

    // Decompose column index for Stockham addressing
    // i: which butterfly group (0 to mid-1)
    // j: position within the butterfly group (0 to stride-1)
    uint i = col >> stage;      // Equivalent to col / stride
    uint j = col % stride;      // Position within stride

    // Calculate twiddle factor for this butterfly
    // Angle = -2π * j / (2 * stride) = -π * j / stride
    // Negative because we're using DIT (decimation in time)
    vec2 twiddle_factor = exp_complex(PI / float(stride) * float(j));
    
    // Calculate read indices for the butterfly operation
    // In Stockham FFT, we read from one buffer and write to another
    // r0: index of first element in butterfly pair
    // r1: index of second element in butterfly pair
    uint r0 = stride*(i +   0) + j;  // First element of pair
    uint r1 = stride*(i + mid) + j;  // Second element (offset by mid groups)
    
    // Calculate write indices for next stage
    // w0: where to write the sum (top output of butterfly)
    // w1: where to write the difference (bottom output of butterfly)
    uint w0 = stride*(2*i + 0) + j;  // Even position in next stage
    uint w1 = stride*(2*i + 1) + j;  // Odd position in next stage

    // Convert indices to float for storage
    // We store as float because GLSL doesn't support uint in vec4 directly
    // These will be converted back to uint in the FFT compute shader
    vec2 read_indices = vec2(uintBitsToFloat(r0), uintBitsToFloat(r1));

    // Store butterfly data for this position
    // For the "sum" output (w0): use positive twiddle factor
    BUTTERFLY(w0, stage) = vec4(read_indices,  twiddle_factor);
    // For the "difference" output (w1): use negative twiddle factor
    // This implements the butterfly operation: X[k] ± W*X[k+N/2]
    BUTTERFLY(w1, stage) = vec4(read_indices, -twiddle_factor);
}