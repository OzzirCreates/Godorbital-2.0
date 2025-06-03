#[compute]
#version 460
/** 
 * Stockham FFT Compute Shader
 * 
 * DESCRIPTION:
 * ------------
 * A coalesced decimation-in-time Stockham FFT kernel.
 * This shader performs the actual Fast Fourier Transform on rows of data.
 * It uses precomputed butterfly factors and shared memory for efficiency.
 * 
 * ALGORITHM:
 * ----------
 * Stockham FFT is an auto-sorting FFT variant that avoids bit-reversal by
 * using a different indexing pattern. It alternates between two buffers
 * (ping-pong pattern) to maintain data ordering.
 * 
 * Source: http://wwwa.pikara.ne.jp/okojisan/otfft-en/stockham3.html
 */

// Mathematical and configuration constants
#define PI           (3.141592653589793)
#define MAX_MAP_SIZE (1024U)              // Maximum supported FFT size
#define NUM_SPECTRA  (4U)                 // Number of wave spectra processed

// Work group configuration - processes one row at a time
// MAX_MAP_SIZE threads to handle the largest possible row
layout(local_size_x = MAX_MAP_SIZE, local_size_y = 1, local_size_z = 1) in;

// Input: Precomputed butterfly factors from fft_butterfly.glsl
layout(std430, set = 0, binding = 0) restrict readonly buffer ButterflyFactorBuffer {
    // Butterfly factors for each stage and position
    // .xy = read indices, .zw = twiddle factor (complex)
    vec4 butterfly[]; // Dimensions: [log2(map_size)][map_size]
};

// Input/Output: FFT data buffer
layout(std430, set = 0, binding = 1) restrict buffer FFTBuffer {
    // Complex valued data arranged as:
    // [cascade][spectrum][row][column] with 2 buffers for input/output
    // Total size: map_size × map_size × num_spectra × 2 × num_cascades
    vec2 data[];
};

// Push constants for per-dispatch configuration
layout(push_constant) restrict readonly uniform PushConstants {
    uint cascade_index;  // Which wave cascade we're processing
};

// Shared memory for fast row processing
// "Ping-pong" buffer: alternates between two halves for reading/writing
// Size is 2*MAX_MAP_SIZE to hold both buffers
shared vec2 row_shared[2 * MAX_MAP_SIZE];

/** 
 * Complex multiplication: (a0 + j*a1)(b0 + j*b1)
 * Returns (a0*b0 - a1*b1) + j*(a0*b1 + a1*b0)
 * where j is the imaginary unit
 */
vec2 mul_complex(in vec2 a, in vec2 b) {
    return vec2(
        a.x*b.x - a.y*b.y,  // Real part: Re(a)*Re(b) - Im(a)*Im(b)
        a.x*b.y + a.y*b.x   // Imaginary part: Re(a)*Im(b) + Im(a)*Re(b)
    );
}

// Macros for accessing different data structures with clear indexing

// Access shared memory with ping-pong buffer index
// pingpong: 0 or 1 to select which half of the buffer
#define ROW_SHARED(col, pingpong) (row_shared[(pingpong)*MAX_MAP_SIZE + (col)])

// Access butterfly factors for specific stage and column
#define BUTTERFLY(col, stage) (butterfly[(stage)*map_size + (col)])

// Access input data from first buffer (before transpose)
// id = (column, row, cascade), layer = spectrum index
#define DATA_IN(id, layer) (data[\
    (id.z)*map_size*map_size*NUM_SPECTRA*2 +                             /* Cascade offset */\
    0 +                                                                   /* Input buffer */\
    (layer)*map_size*map_size +                                          /* Spectrum offset */\
    (id.y)*map_size +                                                     /* Row offset */\
    (id.x)                                                                /* Column */\
])

// Access output data in second buffer (after transpose)
// Layout is transposed: rows and columns are swapped
#define DATA_OUT(id, layer) (data[\
    (id.z)*map_size*map_size*NUM_SPECTRA*2 +                             /* Cascade offset */\
    NUM_SPECTRA*map_size*map_size +                                      /* Output buffer offset */\
    (layer)*map_size*map_size +                                          /* Spectrum offset */\
    (id.y)*map_size +                                                     /* Row offset */\
    (id.x)                                                                /* Column */\
])

void main() {
    // Calculate actual FFT size from dispatch dimensions
    const uint map_size = gl_NumWorkGroups.y * gl_WorkGroupSize.y;
    
    // Number of FFT stages = log2(map_size)
    // findMSB returns position of most significant bit, which equals log2 for powers of 2
    const uint num_stages = findMSB(map_size);
    
    // Get current thread's position
    const uvec3 id = uvec3(
        gl_GlobalInvocationID.x,    // Column (0 to map_size-1)
        gl_GlobalInvocationID.y,    // Row (0 to map_size-1)
        cascade_index               // Wave cascade being processed
    );
    const uint col = id.x;
    
    // Which spectrum (0-3) this thread processes
    const uint spectrum = gl_GlobalInvocationID.z;
    
    // Early exit for threads beyond map size (when map_size < MAX_MAP_SIZE)
    if (gl_LocalInvocationID.x >= map_size) return;

    // Load initial data into shared memory
    // Each thread loads one complex value for its column
    ROW_SHARED(col, 0) = DATA_IN(id, spectrum);
    
    // Perform FFT stages
    for (uint stage = 0U; stage < num_stages; ++stage) {
        // Synchronize all threads before reading shared memory
        barrier();
        
        // Ping-pong buffer indices
        // We alternate between reading from one half and writing to the other
        uvec2 buf_idx = uvec2(
            stage % 2,       // Read buffer index (0 or 1)
            (stage + 1) % 2  // Write buffer index (opposite of read)
        );
        
        // Get butterfly data for this column and stage
        vec4 butterfly_data = BUTTERFLY(col, stage);

        // Extract butterfly parameters
        // Read indices were stored as floats, convert back to uint
        uvec2 read_indices = uvec2(floatBitsToUint(butterfly_data.xy));
        vec2 twiddle_factor = butterfly_data.zw;  // Complex twiddle factor

        // Perform butterfly operation
        // Read the two values that will be combined
        vec2 upper = ROW_SHARED(read_indices[0], buf_idx[0]);
        vec2 lower = ROW_SHARED(read_indices[1], buf_idx[0]);
        
        // Butterfly computation: upper + twiddle * lower
        // This is the core FFT operation that combines pairs of values
        ROW_SHARED(col, buf_idx[1]) = upper + mul_complex(lower, twiddle_factor);
    }
    
    // Write final result to output buffer
    // The result is in the buffer that was written to in the last stage
    // num_stages % 2 determines which buffer contains the final result
    DATA_OUT(id, spectrum) = ROW_SHARED(col, num_stages % 2);
}