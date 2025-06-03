shader_type particles;
// Disable velocity-based particle movement (we control position manually)
render_mode disable_velocity;
/**
 * Sea Spray Particle Shader
 * 
 * PRIMARY SOURCES:
 * ----------------
 * Based on GodotOceanWaves implementation:
 * - Original repository: https://github.com/2Retr0/GodotOceanWaves
 * - Fork/adaptation: https://github.com/krautdev/GodotOceanWaves
 * - Tutorial video: https://www.youtube.com/watch?v=waVAmgsC_4Q&t=14s
 * 
 * ADDITIONAL REFERENCES:
 * ----------------------
 * 1. Hash function implementation from:
 *    Shadertoy - "Hash without Sine" by Dave_Hoskins
 *    Source: https://www.shadertoy.com/view/Xt3cDn
 * 
 * 2. Exponential impulse function from:
 *    Inigo Quilez - "Useful little functions"
 *    Source: https://iquilezles.org/articles/functions/
 * 
 * DESCRIPTION:
 * ------------
 * Handles where sea spray particles should spawn and determines their animation.
 * Particles spawn based on wave foam intensity and surface normal direction,
 * following the displacement maps during their lifetime for realistic motion.
 * 
 * FEATURES:
 * - Dynamic particle spawning based on foam intensity
 * - Particles follow wave displacement during lifetime
 * - Parabolic trajectory for splash-like motion
 * - Size and scale animation over particle lifetime
 * - Normal-based filtering to spawn only on wave peaks
 */

// Maximum number of wave cascades (must match water shader)
#define MAX_CASCADES      8
// Gravity constant (unused but kept for reference)
#define G                 (vec3(0, -9.81, 0))

// Convenience macros for accessing particle data stored in matrices
// Godot stores particle data in transform matrices and custom data vectors
#define POSITION          (TRANSFORM[3].xyz)    // Particle position (4th column of transform)
#define START_POS         (USERDATA1.xyz)       // Initial spawn position
#define START_TIME        (USERDATA1.w)         // When particle actually starts
#define PARTICLE_SCALE    (USERDATA2.xyz)       // Size of particle
#define PARTICLE_LIFETIME (USERDATA2.w)         // How long particle lives
#define SCALE_FACTOR      (USERDATA3.z)         // Foam/normal based scale multiplier
#define HAS_STARTED       (USERDATA3.w)         // Flag: has particle initialized?

// Particle system configuration
uniform uint num_particles;                            // Total particles in system
uniform vec3 particle_scale;                           // Base scale for all particles
uniform float lifetime = 3.0;                          // Maximum particle lifetime
uniform float lifetime_randomness : hint_range(0.0, 1.0) = 0.25; // Lifetime variation

// Wave data (same as water shader)
group_uniforms cascade_data;
uniform vec4 map_scales[MAX_CASCADES];                 // Scale factors for each cascade
global uniform uint num_cascades;                      // Active cascade count
global uniform sampler2DArray displacements;           // Displacement textures
global uniform sampler2DArray normals : hint_normal;   // Normal textures

// High-quality hash function for randomness
// Produces 3 random values from 2 integer inputs
vec3 hash32(uvec2 p) {
    // Multiple rounds of integer hashing
    p = 1103515245U * ((p >> 1U) ^ p.yx);
    uint h32 = 1103515245U * (p.x ^ (p.y>>3U));
    uint n = h32 ^ (h32 >> 16U);
    
    // Generate 3 different values using different multipliers
    uvec3 rz = uvec3(n, n*16807U, n*48271U);
    
    // Convert to normalized floats [0,1]
    return vec3((rz >> 1U) & uvec3(0x7FFFFFFFU)) / float(0x7FFFFFFF);
}

// Helper function to set transform matrix scale
void set_scale(inout mat4 transform, in vec3 scale) {
    // Normalize each axis then multiply by desired scale
    transform[0].xyz = normalize(transform[0].xyz) * scale.x;  // X axis
    transform[1].xyz = normalize(transform[1].xyz) * scale.y;  // Y axis
    transform[2].xyz = normalize(transform[2].xyz) * scale.z;  // Z axis
}

// Called when particle system starts or restarts
void start() {
    // RESTART_POSITION is true when a particle needs initialization
    if (RESTART_POSITION) {
        // Calculate grid dimensions for particle distribution
        // sqrt gives us a square grid (e.g., 100 particles = 10x10 grid)
        uint t = uint(sqrt(float(num_particles)));
        
        // Generate random values for this particle
        // Using particle number and time for seed ensures uniqueness
        vec3 rand = hash32(uvec2(NUMBER, 1U) + uint(TIME) + RANDOM_SEED);

        // Calculate grid position for even distribution
        // This creates a uniform grid of potential spawn points
        vec2 coords = (vec2(uvec2(INDEX / t, INDEX % t)) / (float(t) - 1.0) - 0.5) * 10.0;
        
        // Set initial position in emitter space
        TRANSFORM[3].xyz = vec3(coords.x, 0, coords.y);
        
        // Transform to world space using emitter's transform
        TRANSFORM = EMISSION_TRANSFORM * TRANSFORM;

        // Store random values and calculate lifetime
        CUSTOM.z = rand.x;  // Used for general randomness
        PARTICLE_LIFETIME = lifetime - lifetime*lifetime_randomness*rand.y;
        
        // Store spawn position and delayed start time
        START_POS = POSITION;
        START_TIME = TIME + rand.z*(LIFETIME - PARTICLE_LIFETIME);  // Random delay

        // Mark as not started and hide particle
        HAS_STARTED = 0.0;
        POSITION = vec3(0,-1e10,0);  // Move far below to hide
        set_scale(TRANSFORM, vec3(1e-3));  // Make tiny
        // Actual initialization happens when START_TIME is reached
    }
}

// Exponential impulse function for smooth animations
// Creates a sharp rise followed by smooth decay
float exp_impulse(float x, float k) {
    float h = k*x;
    return h * exp(1.0 - h);
}

// Called every frame for each particle
void process() {
    // Check if particle lifetime has expired
    if (TIME > START_TIME + PARTICLE_LIFETIME) {
        ACTIVE = false;  // Deactivate particle
    } 
    // Check if it's time to start this particle
    else if (TIME >= START_TIME) {
        // First-time initialization when particle starts
        if (HAS_STARTED == 0.0) {
            // Sample wave data at spawn position
            vec3 gradient = vec3(0);
            for (uint i = 0U; i < num_cascades; ++i) {
                // Accumulate normal/foam data from all cascades
                gradient += texture(normals, vec3(START_POS.xz*map_scales[i].xy, float(i))).xyw;
            }
            
            // Reconstruct surface normal from gradient
            vec3 normal = normalize(vec3(-gradient.x, 1.0, -gradient.y));
            float foam = gradient.z;  // Foam intensity
            
            // Calculate spawn factors based on surface conditions
            // Only spawn on near-vertical surfaces (wave peaks)
            float normal_factor = mix(0.25, 1.0, min((normal.y - 0.92) / (0.99 - 0.92), 1.0));
            // Only spawn where foam is intense
            float foam_factor = mix(0.25, 1.0, min((foam - 0.9) / (1.0 - 0.9), 1.0));

            // Activate particle only if conditions are met
            ACTIVE = normal_factor >= 0.0 && normal_factor <= 1.0 && foam > 0.9;
            
            // Store combined scale factor
            SCALE_FACTOR = normal_factor*foam_factor;
            
            // Calculate initial particle scale
            // Base scale depends on foam amount
            PARTICLE_SCALE = vec3(foam_factor * (float(ACTIVE) + 1e-3));
            // Flatten based on surface angle (flatter on slopes)
            PARTICLE_SCALE *= vec3(1, normal_factor, 1);
            // Apply global scale
            PARTICLE_SCALE *= particle_scale;
            
            // Mark as initialized
            HAS_STARTED = 1.0;
        }

        // Update active particles
        if (ACTIVE) {
            // Calculate normalized lifetime progress (0 to 1)
            float t = (TIME - START_TIME) / PARTICLE_LIFETIME;
            
            // Store animation progress for mesh shader
            // exp_impulse creates splash-like fade in/out
            CUSTOM.a = exp_impulse(t, 10.0);

            // --- PARTICLE POSITION UPDATE ---
            // Sample current wave displacement to follow waves
            vec3 displacement = vec3(0);
            for (uint i = 0U; i < num_cascades; ++i) {
                vec3 scales = map_scales[i].xyz;
                // Get displacement at original spawn position
                displacement += texture(displacements, vec3(START_POS.xz*scales.xy, float(i))).xyz * scales.z;
            }
            
            // Reduce horizontal movement to prevent jittering
            displacement *= vec3(0.75, 1.0, 0.75);
            
            // Add parabolic trajectory for realistic splash motion
            // Particle rises then falls over lifetime
            // -5.0*pow(2.5*t - 0.45, 2.0) creates parabola peaking at t=0.18
            displacement += vec3(0, -5.0*pow(2.5*t - 0.45, 2.0)*SCALE_FACTOR + 0.5, 0);
            
            // Update position: start position + wave following + trajectory
            POSITION = START_POS + displacement;

            // --- PARTICLE SCALE ANIMATION ---
            // Smaller lifetime = smaller particle
            float size = PARTICLE_LIFETIME / lifetime;
            vec3 scale_modifier = vec3(size*size);
            
            // Vertical stretch using impulse function (quick stretch then shrink)
            scale_modifier.y *= exp_impulse(t, 3.0);
            // Horizontal growth using logarithm (gradual expansion)
            scale_modifier.xz *= vec2(log(1.0 + t));
            
            // Apply final scale
            set_scale(TRANSFORM, PARTICLE_SCALE*scale_modifier);
        }
    }
}