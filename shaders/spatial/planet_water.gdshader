shader_type spatial;
// Render modes define how Godot should render this shader
render_mode world_vertex_coords, // Use world space coordinates instead of local space
           shadows_disabled,     // Don't cast shadows (improves performance for water)
           cull_disabled,        // Render both sides of faces (needed for waves)
           specular_schlick_ggx, // Use Schlick-GGX specular model for realistic highlights
           depth_draw_opaque,    // Draw to depth buffer as opaque (for proper sorting)
           sss_mode_skin;        // Use skin subsurface scattering mode for water translucency
/**
 * Planet Water Shader
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
 * 1. Water lighting model based on:
 *    "Wakes, Explosions and Lighting: Interactive Water Simulation in Atlas" (GDC 2019)
 *    Source: https://gpuopen.com/gdc-presentations/2019/gdc-2019-agtd6-interactive-water-simulation-in-atlas.pdf
 * 
 * 2. Bicubic B-spline filtering implementation from:
 *    "Fast Third-Order Texture Filtering" - GPU Gems 2, Chapter 20
 *    Source: https://developer.nvidia.com/gpugems/gpugems2/part-iii-high-quality-rendering/chapter-20-fast-third-order-texture-filtering
 * 
 * 3. GGX distribution implementation reference:
 *    Godot Engine source code
 *    Source: https://github.com/godotengine/godot/blob/7b56111c297f24304eb911fe75082d8cdc3d4141/drivers/gles3/shaders/scene.glsl#L995
 * 
 * 4. Additional water rendering techniques inspired by:
 *    - Sea of Thieves water rendering (subsurface scattering approach)
 *    - Various real-time ocean rendering papers and talks
 */

// Maximum number of wave cascades (different frequency wave layers)
#define MAX_CASCADES 8    // I am unsure how to generalize this.
// Fresnel reflectance value for air-to-water interface (based on index of refraction 1.33)
#define REFLECTANCE  0.02 // Reflectance from air to water (eta=1.33).

// Global uniforms shared across multiple shaders
global uniform vec4 water_color;  // Base color of the water (RGBA)
global uniform vec4 foam_color;   // Color of foam on wave peaks (RGBA)

// Material properties
uniform float roughness : hint_range(0.0, 1.0) = 0.4;        // Surface roughness (0=mirror, 1=diffuse)
uniform float normal_strength : hint_range(0.0, 1.0) = 1.0;  // Strength of wave normal mapping

// Wave cascade data group
group_uniforms cascade_data;
// Each cascade has different scales packed into vec4:
// xy = UV scale (how stretched the texture is)
// z = displacement scale (height of waves)
// w = normal scale (bumpiness strength)
uniform vec4 map_scales[MAX_CASCADES];               
global uniform uint num_cascades;                    // How many cascades are actually used
global uniform sampler2DArray displacements;         // Array texture with displacement maps
global uniform sampler2DArray normals : hint_normal; // Array texture with normal maps

// Tidal effect uniforms for planetary-scale water
uniform vec3 moon_position = vec3(0.0, 0.0, 0.0);    // Position of moon in world space
uniform vec3 planet_position = vec3(0.0, 0.0, 0.0);  // Center of planet
uniform float planet_radius = 1000.0;                 // Radius of the planet
uniform float tidal_strength = 10.0;                  // How strong tidal effects are
uniform bool enable_tides = true;                     // Toggle tidal effects on/off

// Variables passed from vertex to fragment shader
varying float wave_height;   // Height of the wave at this vertex
varying float foam_factor;   // How much foam should appear (0-1)
varying float fresnel;       // Fresnel reflection factor

// Function to calculate tidal effect based on moon position
vec3 calculate_tidal_displacement(vec3 position) {
    // Early exit if tides are disabled
    if (!enable_tides) return vec3(0.0);

    // Calculate vector from planet center to moon
    vec3 to_moon = moon_position - planet_position;
    float moon_dist = length(to_moon);      // Distance to moon
    to_moon = normalize(to_moon);            // Direction to moon (normalized)

    // Get position relative to planet center and normalize it
    vec3 rel_pos = position - planet_position;
    vec3 pos_dir = normalize(rel_pos);

    // Calculate how aligned this point is with the moon direction
    // dot product gives us cos(angle), where 1 = facing moon, -1 = opposite side
    float alignment = dot(pos_dir, to_moon);

    // Create dual-bulge tidal pattern using spherical harmonic
    // This formula (3x²-1)/2 creates two bulges:
    // - One facing the moon (alignment = 1)
    // - One on opposite side (alignment = -1)
    // And low tide at 90° angles (alignment = 0)
    float tide_factor = (3.0 * alignment * alignment - 1.0) * 0.5;

    // Scale tidal effect by distance (closer moon = stronger tides)
    // Using inverse cube law for tidal forces
    float dist_scale = planet_radius / max(moon_dist, planet_radius);
    dist_scale = dist_scale * dist_scale * dist_scale; // Cubic falloff

    // Apply tidal displacement
    // Mostly vertical (y) with very small horizontal components
    // to preserve the wave patterns
    return vec3(
        pos_dir.x * tide_factor * 0.05,  // 5% horizontal displacement
        pos_dir.y * tide_factor,          // Full vertical displacement
        pos_dir.z * tide_factor * 0.05   // 5% horizontal displacement
    ) * tidal_strength * planet_radius * 0.02 * dist_scale;
}

// Vertex shader: runs once per vertex to transform positions
void vertex() {
    // Use world XZ coordinates as texture coordinates
    UV = VERTEX.xz;
    
    // Calculate distance-based LOD factor
    // This fades out wave detail at extreme distances (>15km)
    // exp() creates smooth exponential falloff
    float distance_factor = min(exp(-(length(VERTEX.xz - CAMERA_POSITION_WORLD.xz) - 15000.0)*0.007), 1.0);

    // Accumulate displacement from all wave cascades
    vec3 displacement = vec3(0);
    for (uint i = 0U; i < num_cascades; ++i) {
        vec4 scales = map_scales[i];
        // Sample displacement texture for this cascade
        // xy component scales UV coordinates
        // z component scales the displacement amount
        displacement += texture(displacements, vec3(UV*scales.xy, float(i))).xyz * scales.z;
    }

    // Add tidal displacement on top of wave displacement
    if (enable_tides) {
        vec3 tidal_displacement = calculate_tidal_displacement(VERTEX);
        displacement += tidal_displacement;
    }

    // For spherical planets, transform displacement to surface normal space
    if (true) { // Replace with is_sphere uniform if available
        // Calculate normal vector at this point on sphere
        vec3 normal = normalize(VERTEX - planet_position);

        // Build tangent space basis vectors
        // Tangent: perpendicular to normal and "up" vector
        vec3 tangent = normalize(cross(normal, vec3(0.0, 1.0, 0.0)));
        // Handle edge case where normal is parallel to up vector
        if (length(tangent) < 0.1) tangent = normalize(cross(normal, vec3(1.0, 0.0, 0.0)));
        // Bitangent: perpendicular to both normal and tangent
        vec3 bitangent = normalize(cross(normal, tangent));

        // Transform displacement from world space to local tangent space
        // This ensures waves displace along the surface normal
        vec3 local_displacement =
            tangent * displacement.x +    // X displacement along tangent
            normal * displacement.y +      // Y displacement along normal (height)
            bitangent * displacement.z;    // Z displacement along bitangent

        displacement = local_displacement;
    }

    // Apply displacement to vertex position with distance fade
    VERTEX += displacement * distance_factor;
    
    // Store wave height for foam calculation in fragment shader
    // Project displacement onto surface normal to get actual height
    wave_height = dot(displacement, normalize(VERTEX - planet_position));
}

/** 
 * Calculate filter weights for cubic B-spline interpolation
 * Used for smooth texture filtering
 * @param a - fractional part of texture coordinate
 */
vec4 cubic_weights(float a) {
    float a2 = a*a;      // a squared
    float a3 = a2*a;     // a cubed

    // B-spline basis functions
    float w0 =-a3     + a2*3.0 - a*3.0 + 1.0;  // Weight for sample -1
    float w1 = a3*3.0 - a2*6.0         + 4.0;  // Weight for sample 0
    float w2 =-a3*3.0 + a2*3.0 + a*3.0 + 1.0;  // Weight for sample +1
    float w3 = a3;                               // Weight for sample +2
    
    // Normalize weights (sum = 6)
    return vec4(w0, w1, w2, w3) / 6.0;
}

/** 
 * Performs bicubic B-spline filtering on texture array
 * Provides smoother interpolation than bilinear filtering
 * Essential for high-quality normal map sampling
 */
vec4 texture_bicubic(in sampler2DArray sampler, in vec3 uvw) {
    // Get texture dimensions for pixel-perfect sampling
    vec2 dims = vec2(textureSize(sampler, 0).xy);
    vec2 dims_inv = 1.0 / dims;
    
    // Convert normalized UVs to texel coordinates
    uvw.xy = uvw.xy*dims + 0.5;

    // Get fractional parts for interpolation
    vec2 fuv = fract(uvw.xy);
    
    // Calculate cubic weights for both axes
    vec4 wx = cubic_weights(fuv.x);
    vec4 wy = cubic_weights(fuv.y);

    // Optimize texture fetches by combining weights
    // This reduces 16 texture samples to 4
    vec4 g = vec4(wx.xz + wx.yw, wy.xz + wy.yw);
    vec4 h = (vec4(wx.yw, wy.yw) / g + vec2(-1.5, 0.5).xyxy + floor(uvw.xy).xxyy)*dims_inv.xxyy;
    vec2 w = g.xz / (g.xz + g.yw);
    
    // Perform 4 bilinear samples and blend
    return mix(
        mix(texture(sampler, vec3(h.yw, uvw.z)), texture(sampler, vec3(h.xw, uvw.z)), w.x),
        mix(texture(sampler, vec3(h.yz, uvw.z)), texture(sampler, vec3(h.xz, uvw.z)), w.x), w.y);
}

// Fragment shader: runs once per pixel to determine color
void fragment() {
    // Get texture resolution for quality decisions
    float map_size = float(textureSize(normals, 0).x);
    
    // Distance from camera for LOD
    float dist = length(VERTEX.xz);
    
    // Accumulate normal/foam data from all cascades
    vec3 gradient = vec3(0);
    for (uint i = 0U; i < num_cascades; ++i) {
        vec4 scales = map_scales[i];
        vec3 coords = vec3(UV*scales.xy, float(i));
        
        // Calculate pixels per meter for this cascade
        // Higher ppm = more detail = use better filtering
        float ppm = map_size * min(scales.x, scales.y);
        
        // Blend between bicubic (high quality) and bilinear (fast) filtering
        // based on how much detail is visible
        gradient += mix(
            texture_bicubic(normals, coords),  // High quality
            texture(normals, coords),          // Fast
            min(1.0, ppm*0.1)                  // Blend factor
        ).xyw * vec3(scales.ww, 1.0);          // Apply normal scale
    }
    
    // Define water colors for subtle moonlit effect
    vec3 deep_blue = vec3(0.05, 0.08, 0.15);      // Deep water color
    vec3 surface_blue = vec3(0.08, 0.15, 0.22);   // Surface water color
    vec3 moonlight_glow = vec3(0.12, 0.2, 0.3);  // Moonlight reflection color
    
    // Calculate foam based on wave gradient with distance fade
    // smoothstep creates smooth 0-1 transition
    // exp creates exponential distance falloff
    foam_factor = smoothstep(0.0, 1.0, gradient.z*0.75) * exp(-dist*0.0075);
    
    // Mix water color with foam color based on foam factor
    ALBEDO = mix(water_color.rgb, foam_color.rgb, foam_factor);

    // Reduce normal strength with distance to blend with terrain
    gradient *= mix(0.015, normal_strength, exp(-dist*0.0175));
    
    // Convert gradient to normal vector in view space
    // gradient.x and gradient.y are derivatives, so we reconstruct normal
    NORMAL = (VIEW_MATRIX * vec4(normalize(vec3(-gradient.x, 1.0, -gradient.y)), 0.0)).xyz;

    // Calculate Fresnel effect (more reflection at glancing angles)
    // This formula approximates Schlick's Fresnel equation
    fresnel = mix(
        pow(1.0 - dot(VIEW, NORMAL), 5.0*exp(-2.69*roughness)) / (1.0 + 22.7*pow(roughness, 1.5)), 
        1.0, 
        REFLECTANCE
    );
    
    // Foam increases roughness (less reflective)
    ROUGHNESS = (1.0 - fresnel) * foam_factor + 0.4;
}

// Smith masking-shadowing function for microfacet BRDF
// Accounts for surface self-shadowing at grazing angles
float smith_masking_shadowing(in float cos_theta, in float alpha) {
    // Approximate tangent using cos without expensive trig functions
    float a = cos_theta / (alpha * sqrt(1.0 - cos_theta*cos_theta));
    float a_sq = a*a;
    
    // Fitted polynomial approximation for Smith G1 function
    return a < 1.6 ? (1.0 - 1.259*a + 0.396*a_sq) / (3.535*a + 2.181*a_sq) : 0.0;
}

// GGX microfacet distribution function
// Models how microfacets are oriented on the surface
float ggx_distribution(in float cos_theta, in float alpha) {
    float a_sq = alpha*alpha;
    float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
    // Returns probability of microfacets facing halfway vector
    return a_sq / (PI * d*d);
}

// Calculate Snell's window effect (total internal reflection)
// Currently unused but kept for potential underwater rendering
float snells_window(vec3 normal, vec3 view, float ior) {
    float cos_theta = dot(normal, view);
    // Check if viewing angle exceeds critical angle for total internal reflection
    return step(sqrt(1.0 - cos_theta * cos_theta) * ior, 1.0);
}

// Per-light shading calculation
void light() {
    // Calculate halfway vector between light and view
    vec3 halfway = normalize(LIGHT + VIEW);
    
    // Clamp dot products to avoid negative values
    float dot_nl = max(dot(NORMAL, LIGHT), 2e-5);  // Normal · Light
    float dot_nv = max(dot(NORMAL, VIEW), 1e-5);   // Normal · View

    // --- SPECULAR LIGHTING ---
    // Calculate masking and shadowing terms
    float light_mask = smith_masking_shadowing(roughness, dot_nv);
    float view_mask = smith_masking_shadowing(roughness, dot_nl);
    
    // Microfacet distribution
    float microfacet_distribution = ggx_distribution(dot(NORMAL, halfway), roughness);
    
    // Geometric attenuation factor
    float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);
    
    // Final specular calculation with normalization
    SPECULAR_LIGHT += fresnel * microfacet_distribution * geometric_attenuation / (4.0 * dot_nv + 0.1) * ATTENUATION;

    // --- DIFFUSE LIGHTING with SUBSURFACE SCATTERING ---
    // Sea of Thieves-style subsurface scattering
    vec3 sss_modifier = vec3(0.2, 1.3, 1.1); // Color shift for turquoise look
    
    // Height-based SSS: light scatters more through wave peaks
    float sss_height = 1.2 * max(0.0, wave_height + 2.5) * 
                       pow(max(dot(LIGHT, -VIEW), 0.0), 3.0) *  // Back-lighting
                       pow(0.5 - 0.5 * dot(LIGHT, NORMAL), 2.0); // Edge lighting
    
    // Near-surface SSS: creates glow when viewing at shallow angles
    float sss_near = 0.6 * pow(dot_nv, 1.7);
    
    // Standard Lambertian diffuse
    float lambertian = 0.2 * dot_nl;

    // Combine all diffuse components
    DIFFUSE_LIGHT += mix(
        (sss_height + sss_near) * sss_modifier / (0.10 + light_mask) + lambertian,  // Water lighting
        foam_color.rgb,  // Foam is simply diffuse
        foam_factor      // Blend based on foam amount
    ) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
}