#[compute]
#version 460
/**
 * Wave Spectrum Time Modulation Shader
 * 
 * DESCRIPTION:
 * ------------
 * Modulates the JONSWAP wave spectra texture in time and calculates
 * spatial derivatives needed for surface reconstruction.
 * This animates the ocean waves and prepares data for FFT.
 *
 * THEORY:
 * -------
 * Ocean waves evolve over time according to the dispersion relation.
 * Each Fourier component rotates in complex plane at its own frequency.
 * We also calculate derivatives to get surface normals and foam.
 * 
 * Sources: 
 * - Jerry Tessendorf - Simulating Ocean Water
 * - Robert Matusiak - Implementing Fast Fourier Transform Algorithms
 */

// Constants
#define PI          (3.141592653589793)
#define G           (9.81)         // Gravitational acceleration
#define NUM_SPECTRA (4U)           // Number of output spectra

// Work group configuration
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Input: Wave spectrum from spectrum_compute
layout(rgba16f, set = 0, binding = 0) restrict readonly uniform image2DArray spectrum;

// Output: Time-evolved spectra ready for FFT
layout(std430, set = 1, binding = 0) restrict writeonly buffer FFTBuffer {
    // Packed wave data: height + derivatives
    // Layout: [cascade][spectrum][row][column]
    vec2 data[];
};

// Push constants
layout(push_constant) restrict readonly uniform PushConstants {
    vec2 tile_length;      // Physical size of ocean tile
    float depth;           // Ocean depth
    float time;            // Current simulation time
    uint cascade_index;    // Which cascade we're processing
};

/** 
 * Complex exponential: e^(ix) = cos(x) + i*sin(x)
 * Used for time evolution of waves
 */
vec2 exp_complex(in float x) {
    return vec2(cos(x), sin(x));
}

/** 
 * Complex multiplication: (a + bi)(c + di)
 * Returns (ac - bd) + i(ad + bc)
 */
vec2 mul_complex(in vec2 a, in vec2 b) {
    return vec2(
        a.x*b.x - a.y*b.y,  // Real part
        a.x*b.y + a.y*b.x   // Imaginary part
    );
}

/** 
 * Complex conjugate: (a + bi)* = (a - bi)
 */
vec2 conj_complex(in vec2 x) {
    x.y *= -1;
    return x;
}

/**
 * Dispersion relation for water waves
 * ω² = gk*tanh(kh) where h is depth
 * For deep water: ω² = gk
 */
float dispersion_relation(in float k) {
    return sqrt(G*k*tanh(k*depth));
}

// Macro for accessing output buffer with clear indexing
#define FFT_DATA(id, layer) (data[\
    (id.z)*map_size*map_size*NUM_SPECTRA*2 +  /* Cascade offset */\
    (layer)*map_size*map_size +               /* Spectrum layer */\
    (id.y)*map_size +                         /* Row */\
    (id.x)                                    /* Column */\
])

void main() {
    // Get dimensions and thread position
    const uint map_size = gl_NumWorkGroups.x * gl_WorkGroupSize.x;
    const uint num_stages = findMSB(map_size); // log2(map_size)
    const ivec2 dims = imageSize(spectrum).xy;
    const ivec3 id = ivec3(gl_GlobalInvocationID.xy, cascade_index);

    // Calculate wave vector k in world space
    vec2 k_vec = (id.xy - dims*0.5)*2.0*PI / tile_length;
    float k = length(k_vec) + 1e-6;  // Wavenumber magnitude
    vec2 k_unit = k_vec / k;         // Unit direction

    // === WAVE SPECTRUM TIME EVOLUTION ===
    
    // Load initial spectrum h₀(k) and h₀*(-k)
    vec4 h0 = imageLoad(spectrum, id);
    // h0.xy = h₀(k)
    // h0.zw = h₀*(-k)
    
    // Calculate phase change due to time
    float dispersion = dispersion_relation(k) * time;
    vec2 modulation = exp_complex(dispersion);  // e^(iωt)
    
    // Time evolution formula:
    // h(k,t) = h₀(k)*e^(iωt) + h₀*(-k)*e^(-iωt)
    // This ensures real-valued height field
    vec2 h = mul_complex(h0.xy, modulation) +                    // Forward wave
             mul_complex(h0.zw, conj_complex(modulation));       // Backward wave
             
    // Helper for derivatives: ih = i*h = (-h.y, h.x)
    vec2 h_inv = vec2(-h.y, h.x);

    // === WAVE DISPLACEMENT CALCULATION ===
    // Displacement includes both vertical (y) and horizontal (x,z) components
    
    // Horizontal displacement formula: D_horizontal = i*k̂*h(k)/k
    // This creates the "choppy" wave effect
    vec2 hx = h_inv * k_unit.y;  // X displacement
    vec2 hy = h;                  // Y displacement (height)
    vec2 hz = h_inv * k_unit.x;  // Z displacement

    // === WAVE GRADIENT CALCULATION ===
    // Gradients are needed for surface normals and foam generation
    // Note: k vectors are accessed .yx instead of .xy (coordinate system quirk)
    
    // Height gradients: ∂h/∂x and ∂h/∂z
    vec2 dhy_dx = h_inv * k_vec.y;  // ∂h/∂x = ik_x * h
    vec2 dhy_dz = h_inv * k_vec.x;  // ∂h/∂z = ik_z * h
    
    // Horizontal displacement gradients (for Jacobian calculation)
    vec2 dhx_dx = -h * k_vec.y * k_unit.y;  // ∂hx/∂x
    vec2 dhz_dz = -h * k_vec.x * k_unit.x;  // ∂hz/∂z
    vec2 dhz_dx = -h * k_vec.y * k_unit.x;  // ∂hz/∂x (cross derivative)

    // === PACK DATA FOR FFT ===
    // Pack two real spectra into one complex FFT using Hermitian symmetry
    // This halves the number of FFTs needed
    
    // Spectrum 0: height_x (real) + height_y (imaginary)
    FFT_DATA(id, 0) = vec2(
        hx.x - hy.y,     // Real part: Re(hx) - Im(hy)
        hx.y + hy.x      // Imag part: Im(hx) + Re(hy)
    );
    
    // Spectrum 1: height_z (real) + dhy/dx (imaginary)
    FFT_DATA(id, 1) = vec2(
        hz.x - dhy_dx.y,     // Real part: Re(hz) - Im(dhy/dx)
        hz.y + dhy_dx.x      // Imag part: Im(hz) + Re(dhy/dx)
    );
    
    // Spectrum 2: dhy/dz (real) + dhx/dx (imaginary)
    FFT_DATA(id, 2) = vec2(
        dhy_dz.x - dhx_dx.y, // Real part: Re(dhy/dz) - Im(dhx/dx)
        dhy_dz.y + dhx_dx.x  // Imag part: Im(dhy/dz) + Re(dhx/dx)
    );
    
    // Spectrum 3: dhz/dz (real) + dhz/dx (imaginary)
    FFT_DATA(id, 3) = vec2(
        dhz_dz.x - dhz_dx.y, // Real part: Re(dhz/dz) - Im(dhz/dx)
        dhz_dz.y + dhz_dx.x  // Imag part: Im(dhz/dz) + Re(dhz/dx)
    );
}