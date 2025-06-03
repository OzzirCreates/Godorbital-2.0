shader_type spatial;
render_mode blend_add, depth_draw_always, cull_back, unshaded;

// Planet and atmosphere parameters
uniform float planet_radius = 100.0;  // Match your planet size in current scene
uniform float atmosphere_height = 25.0; // About 25% of planet radius

// Light parameters
uniform vec3 sun_position = vec3(500.0, 0.0, 0.0);
uniform float sun_intensity = 30.0;
uniform vec3 sun_color: source_color = vec3(1.0, 0.98, 0.9);

// Wavelength-based scattering parameters (RGB wavelengths in nm)
uniform vec3 wavelengths = vec3(700.0, 530.0, 440.0); // Red, green, blue wavelengths
uniform float scattering_strength = 0.5;
uniform float density = 10.0;

// Mie scattering parameters
uniform vec3 mie_color: source_color = vec3(0.9, 0.9, 0.9);
uniform float mie_coefficient = 0.7;
uniform float mie_scale_height = 0.1;
uniform float mie_density = 1.2;
uniform float mie_direction = 0.758;

// Optimization parameters
uniform int primary_steps = 24;
uniform int light_steps = 256;
uniform float intensity_factor = 3.0;

// Additional parameters
uniform bool u_clip_mode = false;
uniform sampler2D u_depth_texture : hint_depth_texture;

// Varying variables
varying vec3 v_vertex_pos;
varying vec3 v_planet_center_viewspace;
varying vec3 v_sun_center_viewspace;

// Ray-sphere intersection
vec2 ray_sphere_intersect(vec3 ray_origin, vec3 ray_dir, vec3 sphere_center, float sphere_radius) {
    vec3 oc = ray_origin - sphere_center;
    float a = dot(ray_dir, ray_dir);
    float b = 2.0 * dot(oc, ray_dir);
    float c = dot(oc, oc) - sphere_radius * sphere_radius;
    float discriminant = b * b - 4.0 * a * c;

    if (discriminant < 0.0) {
        return vec2(-1.0);
    }

    float sqrt_discriminant = sqrt(discriminant);
    float t1 = (-b - sqrt_discriminant) / (2.0 * a);
    float t2 = (-b + sqrt_discriminant) / (2.0 * a);

    return vec2(t1, t2);
}

// Calculate wavelength-dependent Rayleigh scattering coefficient
vec3 calculate_rayleigh_coef(vec3 lambda) {
    // Wavelength (lambda) in nm
    // Rayleigh scattering is proportional to (1/lambda)^4
    return vec3(
        pow(400.0 / lambda.r, 4.0),
        pow(400.0 / lambda.g, 4.0),
        pow(400.0 / lambda.b, 4.0)
    ) * scattering_strength;
}

// Calculate atmospheric density at given height
float calculate_density(float height, float scale_height) {
    // Exponential density falloff
    return exp(-height / (scale_height * atmosphere_height));
}

// Calculate the optical depth (extinction) along a ray
vec4 calculate_optical_depth(vec3 ray_origin, vec3 ray_dir, float ray_length,
                            vec3 planet_center, int steps, vec3 rayleigh_coef) {
    float step_size = ray_length / float(steps);

    vec3 rayleigh_depth = vec3(0.0);
    float mie_depth = 0.0;

    for (int i = 0; i < steps; i++) {
        vec3 sample_point = ray_origin + ray_dir * (float(i) + 0.5) * step_size;
        float height = length(sample_point - planet_center) - planet_radius;

        // Skip points below surface
        if (height < 0.0) continue;

        // Base density at this height
        float h_density = calculate_density(height, 0.25); // Base density

        // Accumulate densities scaled by respective height scales
        rayleigh_depth += rayleigh_coef * h_density * step_size;
        mie_depth += calculate_density(height, mie_scale_height) * step_size;
    }

    return vec4(rayleigh_depth, mie_depth);
}

// Calculate the Rayleigh phase function
float rayleigh_phase(float cos_angle) {
    return 3.0 / (16.0 * 3.14159) * (1.0 + cos_angle * cos_angle);
}

// Calculate the Mie phase function (Henyey-Greenstein approximation)
float mie_phase(float cos_angle) {
    float g = mie_direction;
    float g2 = g * g;

    return 3.0 / (8.0 * 3.14159) * ((1.0 - g2) * (1.0 + cos_angle * cos_angle)) /
           (pow(1.0 + g2 - 2.0 * g * cos_angle, 1.5) * (2.0 + g2));
}

void vertex() {
    v_vertex_pos = VERTEX;

    // For fullscreen quad mode
    if (u_clip_mode) {
        POSITION = vec4(VERTEX.x, VERTEX.y, 0.0, 1.0);
    }

    // Calculate planet and sun positions in view space
    vec4 world_pos = MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
    v_planet_center_viewspace = (VIEW_MATRIX * world_pos).xyz;
    v_sun_center_viewspace = (VIEW_MATRIX * vec4(sun_position, 1.0)).xyz;
}

void fragment() {
    // Setup ray for atmosphere traversal
    vec3 ray_origin;
    vec3 ray_dir;

    if (u_clip_mode) {
        // Near mode - screen-space ray from camera through pixel
        ray_origin = vec3(0.0);

        // Reconstruct position from depth
        float depth = texture(u_depth_texture, SCREEN_UV).r;
        vec4 clip_pos = vec4(SCREEN_UV * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
        vec4 view_pos = INV_PROJECTION_MATRIX * clip_pos;
        view_pos /= view_pos.w;

        ray_dir = normalize(view_pos.xyz - ray_origin);
    } else {
        // Far mode - ray from camera through vertex
        ray_origin = vec3(0.0, 0.0, 0.0);
        ray_dir = normalize(v_vertex_pos - ray_origin);
    }

    // Calculate atmosphere parameters
    float atmosphere_radius = planet_radius + atmosphere_height;
    vec3 planet_center = v_planet_center_viewspace;

    // Get sun direction in view space
    vec3 sun_dir = normalize(v_sun_center_viewspace - planet_center);

    // Ray-sphere intersections
    vec2 atmosphere_intersection = ray_sphere_intersect(ray_origin, ray_dir, planet_center, atmosphere_radius);
    vec2 planet_intersection = ray_sphere_intersect(ray_origin, ray_dir, planet_center, planet_radius);

    // No intersection with atmosphere, skip rendering
    if (abs(atmosphere_intersection.x - atmosphere_intersection.y) < 0.0001) {
        discard;
    }

    // Calculate ray march parameters
    float ray_start = max(atmosphere_intersection.x, 0.0);
    float ray_end = atmosphere_intersection.y;

    // If ray hits planet, use that as the end point
    if (planet_intersection.x > 0.0 && planet_intersection.x < ray_end) {
        ray_end = planet_intersection.x;
    }

    // Depth testing using actual scene depth
    if (!u_clip_mode) {
        float linear_depth = texture(u_depth_texture, SCREEN_UV).r;
        vec4 clip_pos = vec4(SCREEN_UV * 2.0 - 1.0, linear_depth * 2.0 - 1.0, 1.0);
        vec4 view_pos = INV_PROJECTION_MATRIX * clip_pos;
        view_pos /= view_pos.w;
        float scene_depth = length(view_pos.xyz);

        // If scene geometry is in front of atmosphere end, adjust accordingly
        float atmo_end_dist = ray_origin.z + ray_dir.z * ray_end;
        if (scene_depth < atmo_end_dist) {
            ray_end = (scene_depth - ray_origin.z) / ray_dir.z;
        }
    }

    // Cosine of angle between view ray and sun direction
    float view_sun_cos = dot(ray_dir, sun_dir);

    // Phase functions
    float rayleigh_phase_value = rayleigh_phase(view_sun_cos);
    float mie_phase_value = mie_phase(view_sun_cos);

    // Calculate wavelength-based Rayleigh scattering coefficients
    vec3 rayleigh_coef = calculate_rayleigh_coef(wavelengths) * density;

    // Ray march through atmosphere
    vec3 total_rayleigh = vec3(0.0);
    vec3 total_mie = vec3(0.0);

    float step_size = (ray_end - ray_start) / float(primary_steps);

    // Apply subtle dithering to reduce banding
    float dither = fract(sin(dot(SCREEN_UV, vec2(12.9898, 78.233))) * 43758.5453) * 0.5;
    ray_start += dither * step_size * 0.5;

    for (int i = 0; i < primary_steps; i++) {
        // Current sample point
        vec3 sample_pos = ray_origin + ray_dir * (ray_start + (float(i) + 0.5) * step_size);
        float height = length(sample_pos - planet_center) - planet_radius;

        // Skip if below planet surface
        if (height < 0.0) continue;

        // Calculate densities at current height
        float rayleigh_density_at_height = calculate_density(height, 0.25) * density;
        float mie_density_at_height = calculate_density(height, mie_scale_height) * mie_density;

        // Light ray from current sample to sun
        vec2 light_intersect = ray_sphere_intersect(
            sample_pos, sun_dir, planet_center, atmosphere_radius);
        float light_ray_length = light_intersect.y;

        if (light_ray_length < 0.0) {
            light_ray_length = atmosphere_height * 2.0;
        }

        // Calculate optical depth for light ray
        vec4 light_optical_depth = calculate_optical_depth(
            sample_pos, sun_dir, light_ray_length, planet_center, light_steps, rayleigh_coef);

        // Calculate optical depth for view ray up to this point
        vec4 view_optical_depth = calculate_optical_depth(
            ray_origin, ray_dir, ray_start + float(i) * step_size, planet_center, i+1, rayleigh_coef);

        // Total optical depth
        vec3 rayleigh_total_depth = view_optical_depth.rgb + light_optical_depth.rgb;
        float mie_total_depth = view_optical_depth.a + light_optical_depth.a;

        // Calculate transmittance (light that reaches the sample point and then the camera)
        vec3 transmittance = exp(
            -rayleigh_total_depth -
            mie_coefficient * mie_color * mie_total_depth
        );

        // Accumulate scattered light scaled by density and transmittance
        total_rayleigh += rayleigh_density_at_height * transmittance * step_size * vec3(1.0);
        total_mie += mie_density_at_height * transmittance * step_size;
    }

    // Calculate final scattered light scaled by coefficients, phase functions, and sun parameters
    vec3 rayleigh_scatter = rayleigh_coef * rayleigh_phase_value * total_rayleigh;
    vec3 mie_scatter = mie_color * mie_coefficient * mie_phase_value * total_mie;

    // Combine scattering components and apply sun parameters
    vec3 atmosphere_color = (rayleigh_scatter + mie_scatter) * sun_color * sun_intensity;

    // Enhance sunset/sunrise colors when sun is near tangent to the planet
    float rim_factor = 1.0 - abs(dot(ray_dir, normalize(planet_center)));
    rim_factor = pow(rim_factor, 4.0); // Sharpen the rim effect

    // Orange-red rim effect like in your reference image
    vec3 rim_color = vec3(1.0, 0.4, 0.1) * rim_factor * 1.5;
    atmosphere_color += rim_color * intensity_factor;

    // Apply intensity factor
    atmosphere_color *= intensity_factor;

    // Apply a soft exposure curve for HDR
    atmosphere_color = vec3(1.0) - exp(-atmosphere_color);

    // Output
    ALBEDO = atmosphere_color;
    ALPHA = clamp(length(atmosphere_color) * 0.8, 0.0, 1.0);
}