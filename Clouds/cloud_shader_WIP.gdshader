shader_type spatial;
render_mode blend_add, unshaded, cull_disabled, depth_draw_opaque, depth_test_disabled;

uniform sampler3D noise3d_tex;
uniform int steps = 64;
uniform float density_multiplier = 5.0;
uniform float cloud_threshold = 0.25;
uniform vec3 cloud_color: source_color = vec3(1.0);
uniform vec3 light_direction = vec3(0.2, 1.0, 0.1);
uniform float time = 0.0;
uniform float near_plane_offset = 0.5;
uniform float camera_distance = 0.0;
uniform float player_altitude = 0.0;

// Planet parameters
uniform float planet_radius = 100.0;
uniform float cloud_layer_height = 20.0;
uniform float cloud_scale = 1.0;
uniform float rotation_speed = 0.1;

// Consistent epsilon value throughout the shader
const float EPSILON = 0.5;

// Simple noise sampling
float sample_noise(vec3 pos) {
    return texture(noise3d_tex, pos).r;
}

// 2D rotation function
vec2 rotate_2d(vec2 v, float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return vec2(v.x * c - v.y * s, v.x * s + v.y * c);
}

// Sample planetary clouds at a given position
float sample_planetary_clouds(vec3 pos) {
    // Calculate position in relation to planet center
    float dist_to_center = length(pos);

    // Convert position to spherical coordinates (normalized)
    vec3 normalized_pos = pos / dist_to_center;

    // Add rotation based on time - rotate around Y-axis
    vec2 rotated = rotate_2d(vec2(normalized_pos.x, normalized_pos.z), time * rotation_speed);
    normalized_pos.x = rotated.x;
    normalized_pos.z = rotated.y;

    // Base noise sampling position with consistent coordinates
    vec3 noise_pos = normalized_pos * (0.5 / cloud_scale);

    // Use time for animation
    noise_pos.x += time * 0.01;
    noise_pos.z += time * 0.02;

    // Sample basic noise at different frequencies
    float base_noise = sample_noise(noise_pos);
    float detail_noise = sample_noise(noise_pos * 2.0 + vec3(0.0, time * 0.05, 0.0));
    float local_detail = sample_noise(normalized_pos * 5.0 + vec3(time * 0.03, 0.0, time * 0.04));

    // Blend details consistently
    float cloud_density = base_noise * 0.6 + detail_noise * 0.3 + local_detail * 0.1;

    // Apply height falloff - more clouds in middle of layer
    float height_normalized = (dist_to_center - planet_radius) / cloud_layer_height;
    float height_falloff = 1.0 - abs(height_normalized * 2.0 - 1.0);
    height_falloff = smoothstep(0.0, 1.0, height_falloff);

    // Add latitude bands for Earth-like appearance
    float latitude = acos(normalized_pos.y);
    float latitude_bands = smoothstep(0.3, 0.7, abs(sin(latitude * 3.0)));

    // Combine all factors
    float final_density = cloud_density * height_falloff * (0.5 + 0.5 * latitude_bands);

    // Use a slightly softer threshold but not too soft
    return smoothstep(cloud_threshold - 0.05, cloud_threshold + 0.1, final_density);
}

// Improved Ray-Sphere intersection helper function
bool ray_sphere_intersect(vec3 ray_origin, vec3 ray_dir, vec3 sphere_center, float sphere_radius,
                          out float t1, out float t2) {
    vec3 oc = ray_origin - sphere_center;
    float b = dot(oc, ray_dir);
    float c = dot(oc, oc) - sphere_radius * sphere_radius;
    float discriminant = b * b - c;

    // No intersection
    if (discriminant < 0.0) {
        return false;
    }

    float sqrt_disc = sqrt(discriminant);
    t1 = -b - sqrt_disc;
    t2 = -b + sqrt_disc;

    return true;
}

void fragment() {
    // Set default output values
    ALBEDO = vec3(0.0);
    ALPHA = 0.0;

    // Ray setup
    vec3 ray_origin = (INV_VIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    vec3 ray_dir = normalize((INV_VIEW_MATRIX * vec4(normalize(VIEW), 0.0)).xyz);

    // Variables for ray marching
    float t_near = 0.0;
    float t_far = 10000.0;
    vec3 planet_center = vec3(0.0, 0.0, 0.0); // Assuming planet is at origin

    // Calculate distance to center
    float dist_to_center = length(ray_origin);

    // Determine if camera is inside the cloud layer
    bool inside_cloud_layer = (dist_to_center >= planet_radius &&
                              dist_to_center <= planet_radius + cloud_layer_height);

    // Outer cloud sphere
    float t_outer_1 = 0.0;
    float t_outer_2 = 0.0;
    float outer_radius = planet_radius + cloud_layer_height;
    bool hit_outer = ray_sphere_intersect(ray_origin, ray_dir, planet_center, outer_radius, t_outer_1, t_outer_2);

    // Inner planet sphere
    float t_inner_1 = 0.0;
    float t_inner_2 = 0.0;
    bool hit_inner = ray_sphere_intersect(ray_origin, ray_dir, planet_center, planet_radius, t_inner_1, t_inner_2);

    // Only proceed if we hit the cloud layer or are inside it
    bool should_render = hit_outer || inside_cloud_layer;

    if (should_render) {
        // Calculate appropriate near and far bounds for ray marching
        if (inside_cloud_layer) {
            // Camera is inside the cloud layer
            t_near = max(near_plane_offset, EPSILON); // Use dynamic near plane offset

            if (hit_outer) {
                // Exit through outer boundary
                t_far = t_outer_2 > 0.0 ? t_outer_2 : t_far;
            }

            if (hit_inner) {
                // Or hit the planet surface
                t_far = min(t_far, t_inner_1 > 0.0 ? t_inner_1 : t_far);
            }
        } else {
            // Camera is outside the cloud layer

            // Enter through outer boundary with improved minimum distance
            t_near = max(max(near_plane_offset, EPSILON), t_outer_1);

            // Exit through far side of outer boundary
            t_far = t_outer_2;

            if (hit_inner && t_inner_1 > t_near) {
                // Unless we hit the planet first
                t_far = min(t_far, t_inner_1);
            }
        }

        // Calculate dynamic step size based on camera distance
        float distance_factor = max(1.0, min(5.0, camera_distance / (planet_radius * 2.0)));
        int adjusted_steps = max(32, int(float(steps) / distance_factor));

        // Ensure t_near < t_far and has minimum separation
        float min_separation = max(0.1, player_altitude * 0.01);
        t_near = max(t_near, 0.1);

        if (t_near < t_far - min_separation) {
            // Fixed step size - no dynamic adjustment
            float step_size = (t_far - t_near) / float(adjusted_steps);
            float t = t_near;

            // Add jitter to reduce banding
            float jitter = fract(sin(dot(FRAGCOORD.xy, vec2(12.9898, 78.233))) * 43758.5453);
            t += jitter * step_size * 0.5;

            // Accumulation variables
            vec3 total_light = vec3(0.0);
            float transmittance = 1.0;

            // Main ray march loop
            for (int i = 0; i < adjusted_steps; i++) {
                if (transmittance < 0.01) break;

                vec3 pos = ray_origin + ray_dir * t;
                float dist_to_center = length(pos);

                // Sample clouds if we're in the layer
                if (dist_to_center >= planet_radius && dist_to_center <= planet_radius + cloud_layer_height) {
                    float density = sample_planetary_clouds(pos) * density_multiplier * step_size;

                    if (density > 0.001) {
                        // Simple lighting
                        float light_energy = 0.03; // Ambient

                        // Directional light - dot product with normalized position (not ray direction)
                        float sun_dot = max(0.0, dot(normalize(pos), normalize(light_direction)));
                        light_energy += sun_dot * 0.5;

                        // Local illumination variation
                        float local_light = sample_noise(pos * 0.1 + vec3(time * 0.02, 0.0, time * 0.03));
                        light_energy = mix(light_energy, local_light * 0.7 + 0.4, 0.15);

                        // Calculate cloud color
                        vec3 cloud_brightness = cloud_color * light_energy;

                        // Accumulate
                        total_light += cloud_brightness * density * transmittance;
                        transmittance *= exp(-density);
                    }
                }

                t += step_size;
            }

            // Final output with higher minimum alpha
            ALBEDO = total_light;

            // Use a higher minimum alpha for clouds to ensure visibility
            float min_alpha = 0.05;
            ALPHA = max(min_alpha, 1.0 - transmittance);

            // If we're looking at clouds, they should have meaningful alpha
            if (length(total_light) > 0.01) {
                ALPHA = max(0.2, ALPHA);
            }

            // Set depth to be slightly in front of other geometry
            DEPTH = 0.999;
        }
    }
}