#[compute]
#version 460
/** 
 * FFT Unpacking and Surface Generation Shader
 * 
 * DESCRIPTION:
 * ------------
 * Unpacks the IFFT outputs from the modulation stage and creates
 * the output displacement and normal maps for ocean wave rendering.
 * This is the final stage of the FFT ocean simulation pipeline.
 * 
 * PROCESS:
 * --------
 * 1. Reads complex FFT results containing wave height and derivatives
 * 2. Applies inverse FFT shift to correct positioning
 * 3. Calculates surface normals from height gradients
 * 4. Computes foam generation based on wave compression (Jacobian)
 * 5. Outputs displacement and normal maps for rendering
 */

// Configuration constants
#define TILE_SIZE   (16U)    // Size of thread tiles for cache efficiency
#define NUM_SPECTRA (4U)     // Number of wave spectra (height + 3 derivatives)

// Work group configuration - 2D tiles with Z for parallel processing
layout(local_size_x = TILE_SIZE, local_size_y = TILE_SIZE, local_size_z = 2) in;

// Output textures for rendering
layout(rgba16f, set = 0, binding = 0) restrict writeonly uniform image2DArray displacement_map;
layout(rgba16f, set = 0, binding = 1) restrict uniform image2DArray normal_map;

// Input: FFT results from modulation stage
layout(std430, set = 1, binding = 0) restrict buffer FFTBuffer {
    // Complex wave data after IFFT
    // Contains wave height and spatial derivatives
    vec2 data[]; // [cascade][spectrum][row][column]
};

// Push constants for foam generation parameters
layout(push_constant) restrict readonly uniform PushConstants {
    uint cascade_index;      // Which wave cascade we're processing
    float whitecap;          // Threshold for foam generation (wave breaking)
    float foam_grow_rate;    // How quickly foam appears
    float foam_decay_rate;   // How quickly foam dissipates
};

// Shared memory tile for caching FFT data
// Improves memory access patterns by loading data once per tile
shared vec2 tile[NUM_SPECTRA][TILE_SIZE][TILE_SIZE];

// Macro to access FFT data after inverse transform
// Note: Assumes FFT doesn't transpose a second time, so we read from output buffer
#define FFT_DATA(id, layer) (data[\
    (id.z)*map_size*map_size*NUM_SPECTRA*2 +     /* Cascade offset */\
    NUM_SPECTRA*map_size*map_size +              /* Output buffer (after FFT) */\
    (layer)*map_size*map_size +                  /* Spectrum layer */\
    (id).y*map_size +                            /* Row */\
    (id).x                                       /* Column */\
])

void main() {
    // Calculate map dimensions from dispatch size
    const uint map_size = gl_NumWorkGroups.x * gl_WorkGroupSize.x;
    
    // Thread position within work group
    const uvec3 id_local = gl_LocalInvocationID;
    
    // Global position in the displacement/normal maps
    const ivec3 id = ivec3(
        gl_GlobalInvocationID.x,    // X coordinate
        gl_GlobalInvocationID.y,    // Y coordinate
        cascade_index               // Wave cascade layer
    );
    
    // Inverse FFT shift correction
    // IFFT results are shifted by half the domain, this corrects it
    // Creates a checkerboard pattern: +1 for even positions, -1 for odd
    // Equivalent to: (-1)^x * (-1)^y
    const float sign_shift = -2*((id.x & 1) ^ (id.y & 1)) + 1;

    // Load FFT data into shared memory tile
    // Each thread in Z dimension loads 2 spectra
    // Z=0 loads spectra 0,1; Z=1 loads spectra 2,3
    tile[id_local.z*2][id_local.y][id_local.x] = FFT_DATA(id, id_local.z*2);
    tile[id_local.z*2 + 1][id_local.y][id_local.x] = FFT_DATA(id, id_local.z*2 + 1);
    
    // Synchronize to ensure all tile data is loaded
    barrier();

    // Split work between threads: half process displacement, half process normals
    switch (id_local.z) {
        case 0:
            // --- DISPLACEMENT MAP GENERATION ---
            // Extract wave height components from FFT results
            // These represent the actual 3D displacement of the water surface
            
            // Horizontal displacement in X direction
            float hx = tile[0][id_local.y][id_local.x].x;
            // Vertical displacement (wave height)
            float hy = tile[0][id_local.y][id_local.x].y;
            // Horizontal displacement in Z direction
            float hz = tile[1][id_local.y][id_local.x].x;
            
            // Store displacement with sign correction
            // Alpha channel is unused (set to 0)
            imageStore(displacement_map, id, vec4(hx, hy, hz, 0) * sign_shift);
            break;
            
        case 1:
            // --- NORMAL MAP AND FOAM GENERATION ---
            // Extract spatial derivatives for normal calculation
            
            // Height derivatives (gradients)
            float dhy_dx = tile[1][id_local.y][id_local.x].y * sign_shift;  // ∂h/∂x
            float dhy_dz = tile[2][id_local.y][id_local.x].x * sign_shift;  // ∂h/∂z
            
            // Horizontal displacement derivatives (for Jacobian)
            float dhx_dx = tile[2][id_local.y][id_local.x].y * sign_shift;  // ∂hx/∂x
            float dhz_dz = tile[3][id_local.y][id_local.x].x * sign_shift;  // ∂hz/∂z
            float dhz_dx = tile[3][id_local.y][id_local.x].y * sign_shift;  // ∂hz/∂x

            // Calculate Jacobian determinant
            // Jacobian measures area compression/expansion of the surface
            // When Jacobian < 0, waves are compressing and breaking (whitecaps form)
            float jacobian = (1.0 + dhx_dx) * (1.0 + dhz_dz) - dhz_dx*dhz_dx;
            
            // Foam generation based on wave breaking
            // Negative Jacobian below threshold indicates breaking waves
            float foam_factor = -min(0, jacobian - whitecap);
            
            // Update foam with temporal evolution
            // Get previous foam amount from alpha channel
            float foam = imageLoad(normal_map, id).a;
            // Exponential decay over time
            foam *= exp(-foam_decay_rate);
            // Add new foam from breaking waves
            foam += foam_factor * foam_grow_rate;
            // Clamp to valid range
            foam = clamp(foam, 0.0, 1.0);

            // Calculate surface gradient for normal mapping
            // Normalize by surface stretching to maintain proper slopes
            vec2 gradient = vec2(dhy_dx, dhy_dz) / (1.0 + abs(vec2(dhx_dx, dhz_dz)));
            
            // Store normal map data:
            // RG: gradient (used to compute normal in fragment shader)
            // B: horizontal stretching factor (dhx_dx)
            // A: foam amount
            imageStore(normal_map, id, vec4(gradient, dhx_dx, foam));
            break;
    }
}