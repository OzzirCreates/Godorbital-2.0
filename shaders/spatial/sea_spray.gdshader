shader_type spatial;
// Render modes for spray particles
render_mode cull_back,         // Only render front faces
           unshaded,           // No lighting calculations (faster)
           shadows_disabled;   // Don't cast shadows
/**
 * Sea Spray Shader
 * 
 * PRIMARY SOURCES:
 * ----------------
 * Based on GodotOceanWaves implementation:
 * - Original repository: https://github.com/2Retr0/GodotOceanWaves
 * - Fork/adaptation: https://github.com/krautdev/GodotOceanWaves
 * - Tutorial video: https://www.youtube.com/watch?v=waVAmgsC_4Q&t=14s
 * 
 * DESCRIPTION:
 * ------------
 * Handles the opacity and billboarding for the sea spray mesh.
 * This shader creates billboard particles that fade and dissolve over time.
 * 
 * FEATURES:
 * - Billboard rendering for particles to always face camera
 * - Dissolve effect using noise texture
 * - Distance-based fading
 * - Integration with global water and foam colors
 * 
 * NOTE: This is not a full PBR shader since it doesn't apply any lighting to particles
 * for performance reasons (unshaded render mode).
 */

// Global color settings shared with water shader
global uniform vec4 water_color : source_color;  // Base water color
global uniform vec4 foam_color : source_color;   // Foam/spray color

// Particle appearance settings
uniform float max_alpha : hint_range(0, 1) = 0.666;              // Maximum opacity of spray
uniform sampler2D albedo_texture : source_color, repeat_enable;   // Spray particle texture
uniform sampler2D dissolve_texture : source_color, repeat_enable; // Noise texture for dissolve effect

// Variables passed from vertex to fragment shader
varying float dissolve_factor;  // How much the particle has dissolved (0-1)
varying float alpha_fade;       // Fade value from particle system

void vertex() {
    // Billboard transformation - makes the sprite always face the camera
    // Step 1: Extract camera basis vectors from inverse view matrix
    // These represent the camera's right, up, and forward directions
    MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
        normalize(INV_VIEW_MATRIX[0]),  // Camera right vector
        normalize(INV_VIEW_MATRIX[1]),  // Camera up vector
        normalize(INV_VIEW_MATRIX[2]),  // Camera forward vector
        MODEL_MATRIX[3]                 // Keep original position
    );
    
    // Step 2: Apply the original scale from the model matrix
    // This preserves the particle size while billboarding
    MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
        vec4(length(MODEL_MATRIX[0].xyz),0,0,0),  // X scale
        vec4(0,length(MODEL_MATRIX[1].xyz),0,0),  // Y scale
        vec4(0,0,length(MODEL_MATRIX[2].xyz),0),  // Z scale
        vec4(0,0,0,1)                             // No translation
    );
    
    // Pass particle-specific data to fragment shader
    // INSTANCE_CUSTOM is set by the particle system
    dissolve_factor = INSTANCE_CUSTOM.z;  // Z component: dissolve progress
    alpha_fade = INSTANCE_CUSTOM.w;       // W component: fade multiplier
}

void fragment() {
    // Sample the spray texture
    vec4 albedo_tex = texture(albedo_texture, UV);
    
    // Apply foam color with brightness boost
    // The multiplier vec3(1.65,1.75,1.65) makes spray brighter than regular foam
    ALBEDO = albedo_tex.rgb * foam_color.rgb * vec3(1.65, 1.75, 1.65);

    // Calculate distance-based fading
    // exp() creates smooth exponential falloff
    // Particles become more transparent with distance
    float distance_fade = 1.0 - exp(-length(VERTEX.xz) * 0.04);
    
    // Start with base alpha from texture and max_alpha setting
    ALPHA = albedo_tex.a * max_alpha;
    
    // Apply distance fade
    ALPHA *= distance_fade;
    
    // Apply dissolve effect
    // This creates an erosion effect using noise texture
    ALPHA *= max(
        (alpha_fade + dissolve_factor) * 0.5 -           // Base dissolve threshold
        texture(dissolve_texture, UV + vec2(TIME*0.35)).x,  // Animated noise (scrolls over time)
        0.0  // Clamp to non-negative
    );
}