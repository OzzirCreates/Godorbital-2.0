#[compute]
#version 460
/**
 * JONSWAP Wave Spectrum Generation Shader
 * 
 * DESCRIPTION:
 * ------------
 * Generates a 2D texture representing the JONSWAP wave spectra
 * with Hasselmann directional spreading for realistic ocean waves.
 * This forms the basis for FFT-based ocean simulation.
 *
 * THEORY:
 * -------
 * JONSWAP (Joint North Sea Wave Project) spectrum is an empirical
 * model that describes how wave energy is distributed across different
 * frequencies and directions. It's widely used in oceanography.
 * 
 * Sources: 
 * - Jerry Tessendorf - Simulating Ocean Water
 * - Christopher J. Horvath - Empirical Directional Wave Spectra for Computer Graphics
 */

// Mathematical and physical constants
#define PI (3.141592653589793)
#define G  (9.81)  // Gravitational acceleration (m/s²)

// Work group configuration
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Output spectrum texture array (one layer per cascade)
layout(rgba16f, set = 0, binding = 0) restrict writeonly uniform image2DArray spectrum;

// Push constants for wave parameters
layout(push_constant) restrict readonly uniform PushConstants {
    ivec2 seed;              // Random seed for wave phases
    vec2 tile_length;        // Physical size of ocean tile (meters)
    float alpha;             // Phillips spectrum parameter (wave amplitude)
    float peak_frequency;    // Peak wave frequency (rad/s)
    float wind_speed;        // Wind speed (m/s)
    float angle;             // Primary wind direction (radians)
    float depth;             // Ocean depth (meters)
    float swell;             // Amount of swell waves (0-1)
    float detail;            // High frequency detail (0-1)
    float spread;            // Directional spread (0-1)
    uint cascade_index;      // Which cascade we're generating
};

// --- HELPER FUNCTIONS ---

/**
 * High quality hash function for pseudo-random numbers
 * Converts 2D integer coordinates to 2D uniform random values
 * Source: https://www.shadertoy.com/view/Xt3cDn
 */
vec2 hash(in uvec2 x) {
    // Series of integer operations to scramble bits
    uint h32 = x.y + 374761393U + x.x*3266489917U;
    h32 = 2246822519U * (h32 ^ (h32 >> 15));
    h32 = 3266489917U * (h32 ^ (h32 >> 13));
    uint n = h32 ^ (h32 >> 16);
    
    // Generate two different values
    uvec2 rz = uvec2(n, n*48271U);
    
    // Convert to normalized floats [0,1]
    return vec2((rz.xy >> 1) & uvec2(0x7FFFFFFFU)) / float(0x7FFFFFFF);
}

/** 
 * Sample from 2D normal (Gaussian) distribution
 * Uses Box-Muller transform to convert uniform → normal distribution
 * Returns two independent normal-distributed values
 */
vec2 gaussian(in vec2 x) {
    // Box-Muller transform:
    // Given two uniform random numbers u1, u2 in (0,1)
    // z0 = sqrt(-2*ln(u1)) * cos(2π*u2)
    // z1 = sqrt(-2*ln(u1)) * sin(2π*u2)
    float r = sqrt(-2.0 * log(x.x));
    float theta = 2.0*PI * x.y;
    return vec2(r*cos(theta), r*sin(theta));
}

/** 
 * Complex conjugate: (a + bi)* = (a - bi)
 * Used to ensure real-valued output after inverse FFT
 */
vec2 conj_complex(in vec2 x) {
    return vec2(x.x, -x.y);
}

// --- WAVE SPECTRUM FUNCTIONS ---

/**
 * Dispersion relation for water waves
 * Relates wave frequency ω to wavenumber k
 * Includes finite depth effects
 */
vec2 dispersion_relation(in float k) {
    float a = k*depth;                    // Dimensionless depth
    float b = tanh(a);                    // Hyperbolic tangent for depth effect
    
    // Deep water: ω² = gk
    // Finite depth: ω² = gk*tanh(kh)
    float dispersion_relation = sqrt(G*k*b);
    
    // Derivative dω/dk (needed for energy conservation)
    float d_dispersion_relation = 0.5*G * (b + a*(1.0 - b*b)) / dispersion_relation;

    return vec2(dispersion_relation, d_dispersion_relation);
}

/** 
 * Normalization factor for Longuet-Higgins directional function
 * Ensures the directional distribution integrates to 1
 * Note: Original derivation forgotten :)
 */
float longuet_higgins_normalization(in float s) {
    float a = sqrt(s);
    // Piecewise approximation for efficiency
    return (s < 0.4) 
        ? (0.5/PI) + s*(0.220636+s*(-0.109+s*0.090))  // Taylor series for small s
        : inversesqrt(PI)*(a*0.5 + (1.0/a)*0.0625);   // Asymptotic for large s
}

/**
 * Longuet-Higgins directional spreading function
 * Models how wave energy spreads across directions
 * Higher s = more focused, lower s = more spread
 */
float longuet_higgins_function(in float s, in float theta) {
    // cos²ˢ(θ/2) distribution
    return longuet_higgins_normalization(s) * pow(abs(cos(theta*0.5)), 2.0*s);
}

/**
 * Hasselmann directional spread model
 * Empirically-based directional spreading that varies with frequency
 * More realistic than constant spreading
 */
float hasselmann_directional_spread(in float w, in float w_p, in float wind_speed, in float theta) {
    float p = w / w_p;  // Frequency ratio
    
    // Shaping parameter s varies with frequency
    // Lower frequencies spread more, higher frequencies are more focused
    float s = (w <= w_p) 
        ? 6.97*pow(abs(p), 4.06)                                           // Below peak
        : 9.77*pow(abs(p), -2.33 - 1.45*(wind_speed*w_p/G - 1.17));      // Above peak
        
    // Swell parameter adds broader spreading for long-traveled waves
    float s_xi = 16.0 * tanh(w_p / w) * swell*swell;
    
    // Apply directional function centered on wind angle
    return longuet_higgins_function(s + s_xi, theta - angle);
}

/**
 * TMA (Texel-MARSEN-ARSLOE) spectrum
 * JONSWAP spectrum modified for finite depth water
 * Combines empirical wave spectrum with depth attenuation
 */
float TMA_spectrum(in float w, in float w_p, in float alpha) {
    const float beta = 1.25;    // Phillips constant
    const float gamma = 3.3;    // Peak enhancement factor
    
    // Width of spectral peak
    float sigma = (w <= w_p) ? 0.07 : 0.09;
    
    // Peak enhancement function
    float r = exp(-(w-w_p)*(w-w_p) / (2.0 * sigma*sigma * w_p*w_p));
    
    // JONSWAP spectrum formula
    // S(ω) = αg²/ω⁵ * exp(-β(ωₚ/ω)⁴) * γʳ
    float jonswap_spectrum = (alpha * G*G) / pow(w, 5) * exp(-beta * pow(w_p/w, 4)) * pow(gamma, r);

    // Kitaigorodskii depth attenuation
    // Reduces high-frequency waves in shallow water
    float w_h = min(w * sqrt(depth / G), 2.0);  // Dimensionless depth
    float kitaigorodskii_depth_attenuation = (w_h <= 1.0) 
        ? 0.5*w_h*w_h                            // Shallow water
        : 1.0 - 0.5*(2.0-w_h)*(2.0-w_h);       // Transition to deep

    return jonswap_spectrum * kitaigorodskii_depth_attenuation;
}

/**
 * Calculate wave spectrum amplitude for a given wave vector
 * This is the main function that combines all spectrum components
 */
vec2 get_spectrum_amplitude(in ivec2 id, in ivec2 map_size) {
    // Wave vector in frequency space
    vec2 dk = 2.0*PI / tile_length;                    // Frequency resolution
    vec2 k_vec = (id - map_size*0.5)*dk;              // Center spectrum at 0
    float k = length(k_vec) + 1e-6;                   // Wavenumber magnitude (avoid div by 0)
    float theta = atan(k_vec.x, k_vec.y);             // Wave direction
    
    // Get wave frequency from dispersion relation
    vec2 dispersion = dispersion_relation(k);
    float w = dispersion[0];                          // Angular frequency
    float w_norm = dispersion[1] / k * dk.x*dk.y;     // Jacobian for energy conservation
    
    // Calculate 1D spectrum (energy vs frequency)
    float s = TMA_spectrum(w, peak_frequency, alpha);
    
    // Add variation for spherical ocean (different cascades have different distributions)
    float distribution_factor = 1.0;
    if (cascade_index > 0) {
        // Create angular variation based on cascade
        // This helps distribute waves around a spherical planet
        float cascade_angle = float(cascade_index) * (PI / 8.0);
        distribution_factor = mix(0.8, 1.2, 0.5 + 0.5 * sin(theta + cascade_angle));
    }
    
    // Calculate directional spreading
    float d = mix(
        0.5/PI,                                                            // Uniform spreading
        hasselmann_directional_spread(w, peak_frequency, wind_speed, theta), // Hasselmann model
        1.0 - spread                                                       // Blend by spread parameter
    ) * exp(-(1.0-detail)*(1.0-detail) * k*k)                            // High-k suppression
      * distribution_factor;                                               // Cascade variation
    
    // Generate random phase and amplitude
    // Amplitude follows Rayleigh distribution: sqrt(S(k) * dk²)
    return gaussian(hash(uvec2(id + seed))) * sqrt(2.0 * s * d * w_norm);
}

/**
 * Main compute shader entry point
 * Generates spectrum texture for one cascade
 */
void main() {
    // Get texture dimensions and current pixel
    const ivec2 dims = imageSize(spectrum).xy;
    const ivec3 id = ivec3(gl_GlobalInvocationID.xy, cascade_index);
    
    // Calculate spectrum at k and -k
    // We need both for Hermitian symmetry (ensures real output after IFFT)
    const ivec2 id0 = id.xy;                     // Wave vector k
    const ivec2 id1 = ivec2(mod(-id0, dims));   // Wave vector -k (wrapped)

    // Store h₀(k) and h₀*(-k) in single texel
    // This packing exploits Hermitian symmetry for efficiency
    imageStore(spectrum, id, vec4(
        get_spectrum_amplitude(id0, dims),        // h₀(k)
        conj_complex(get_spectrum_amplitude(id1, dims))  // h₀*(-k)
    ));
}