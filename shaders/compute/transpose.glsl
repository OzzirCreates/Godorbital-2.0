#[compute]
#version 460
/** 
 * Memory-Efficient Matrix Transpose Shader
 * 
 * DESCRIPTION:
 * ------------
 * A coalesced matrix transpose kernel optimized for GPU memory access patterns.
 * Transposes the FFT data between row and column passes.
 * 
 * WHY TRANSPOSE?
 * --------------
 * 2D FFT requires transforms along both rows and columns.
 * GPUs prefer accessing contiguous memory (coalesced access).
 * By transposing between passes, we always transform along rows,
 * maintaining optimal memory access patterns.
 * 
 * ALGORITHM:
 * ----------
 * Uses shared memory tiles to avoid bank conflicts and ensure
 * coalesced global memory access in both read and write operations.
 * 
 * Source: https://developer.nvidia.com/blog/efficient-matrix-transpose-cuda-cc/
 */

// Configuration constants
#define TILE_SIZE   (32U)     // Size of shared memory tile (32x32)
#define NUM_SPECTRA (4U)      // Number of wave spectra

// Work group configuration - one tile per work group
layout(local_size_x = TILE_SIZE, local_size_y = TILE_SIZE, local_size_z = 1) in;

// Input: Butterfly factors (unused here but part of FFT pipeline)
layout(std430, set = 0, binding = 0) restrict readonly buffer ButterflyFactorBuffer {
    vec4 butterfly[]; // For consistency with FFT shaders
}; 

// Input/Output: FFT data to transpose
layout(std430, set = 0, binding = 1) restrict buffer FFTBuffer {
    // Data layout: [cascade][in/out][spectrum][row][column]
    vec2 data[];
};

// Push constants
layout(push_constant) restrict readonly uniform PushConstants {
    uint cascade_index;  // Which wave cascade we're processing
};

// Shared memory tile for fast transpose
// Extra column (+1) prevents bank conflicts on some GPU architectures
// Bank conflicts occur when multiple threads access the same memory bank
shared vec2 tile[TILE_SIZE][TILE_SIZE+1];

// Macros for data access with clear indexing

// Read from output buffer (data after FFT row pass)
#define DATA_IN(id, layer) (data[\
    (id.z)*map_size*map_size*NUM_SPECTRA*2 +      /* Cascade offset */\
    NUM_SPECTRA*map_size*map_size +               /* Output buffer */\
    (layer)*map_size*map_size +                   /* Spectrum layer */\
    (id.y)*map_size +                             /* Row */\
    (id.x)                                        /* Column */\
])

// Write to input buffer (prepare for FFT column pass)
#define DATA_OUT(id, layer) (data[\
    (id.z)*map_size*map_size*NUM_SPECTRA*2 +      /* Cascade offset */\
    0 +                                           /* Input buffer */\
    (layer)*map_size*map_size +                   /* Spectrum layer */\
    (id.y)*map_size +                             /* Row */\
    (id.x)                                        /* Column */\
])

void main() {
    // Calculate map dimensions from work group dispatch
    const uint map_size = gl_NumWorkGroups.x * gl_WorkGroupSize.x;
    
    // Work group (tile) position in the grid
    const uvec2 id_block = gl_WorkGroupID.xy;
    
    // Thread position within the work group
    const uvec2 id_local = gl_LocalInvocationID.xy;
    
    // Which spectrum this thread processes
    const uint spectrum = gl_GlobalInvocationID.z;

    // === PHASE 1: Load tile from global memory ===
    
    // Calculate global position for this thread
    uvec3 id = uvec3(gl_GlobalInvocationID.xy, cascade_index);
    
    // Each thread loads one element into shared memory
    // This read is coalesced because threads access consecutive addresses
    tile[id_local.y][id_local.x] = DATA_IN(id, spectrum);
    
    // Synchronize to ensure all threads have loaded their data
    barrier();

    // === PHASE 2: Write transposed tile to global memory ===
    
    // Calculate transposed position
    // Swap block coordinates to transpose at tile level
    id.xy = id_block.yx * TILE_SIZE + id_local.xy;
    
    // Write from shared memory with transposed indices
    // Reading from tile[x][y] instead of tile[y][x] performs transpose
    // This write is also coalesced because of the block coordinate swap
    DATA_OUT(id, spectrum) = tile[id_local.x][id_local.y];
    
    // The result: data that was in row-major order is now in column-major order
    // Next FFT pass can process "columns" by reading "rows" for optimal performance
}