#[compute]
#version 450

// Define the workgroup size
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

// Cloud data storage (3D texture)
layout(set = 0, binding = 0, rgba8) uniform image3D cloudVolume;

// Weather parameters
layout(set = 0, binding = 1) uniform WeatherParams {
    float windSpeed;
    float windDirection;
    float precipitation;
    float cloudCoverage;
    float cloudDensity;
    vec3 stormCenter;
    float stormRadius;
    float time;
    float turbulence;
    float heightGradient;
    float cloudType; // 0.0 = stratus, 0.5 = cumulus, 1.0 = cumulonimbus
    float anvil;     // For cumulonimbus anvil shape
} weather;

// Noise helpers
vec3 hash33(vec3 p) {
    p = vec3(
        dot(p, vec3(127.1, 311.7, 74.7)),
        dot(p, vec3(269.5, 183.3, 246.1)),
        dot(p, vec3(113.5, 271.9, 124.6))
    );
    return fract(sin(p) * 43758.5453123);
}

float worleyNoise(vec3 pos) {
    vec3 id = floor(pos);
    vec3 fd = fract(pos);
    
    float minDist = 1.0;
    
    for (int z = -1; z <= 1; z++) {
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                vec3 offset = vec3(float(x), float(y), float(z));
                vec3 neighbor = id + offset;
                
                // Get random point position within the cell
                vec3 randomPoint = hash33(neighbor);
                
                // Get the distance from current position to the random point
                vec3 relativePos = randomPoint + offset - fd;
                float dist = length(relativePos);
                
                minDist = min(minDist, dist);
            }
        }
    }
    
    return minDist;
}

float perlinNoise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    // Smoothing
    vec3 u = f * f * (3.0 - 2.0 * f);
    
    // Grid cell corners
    vec3 ia = i;
    vec3 ib = i + vec3(1.0, 0.0, 0.0);
    vec3 ic = i + vec3(0.0, 1.0, 0.0);
    vec3 id = i + vec3(1.0, 1.0, 0.0);
    vec3 ie = i + vec3(0.0, 0.0, 1.0);
    vec3 if_ = i + vec3(1.0, 0.0, 1.0);
    vec3 ig = i + vec3(0.0, 1.0, 1.0);
    vec3 ih = i + vec3(1.0, 1.0, 1.0);
    
    // Random gradients
    vec3 ga = normalize(hash33(ia)*2.0-1.0);
    vec3 gb = normalize(hash33(ib)*2.0-1.0);
    vec3 gc = normalize(hash33(ic)*2.0-1.0);
    vec3 gd = normalize(hash33(id)*2.0-1.0);
    vec3 ge = normalize(hash33(ie)*2.0-1.0);
    vec3 gf = normalize(hash33(if_)*2.0-1.0);
    vec3 gg = normalize(hash33(ig)*2.0-1.0);
    vec3 gh = normalize(hash33(ih)*2.0-1.0);
    
    // Gradients dot products
    float va = dot(ga, f);
    float vb = dot(gb, f - vec3(1.0, 0.0, 0.0));
    float vc = dot(gc, f - vec3(0.0, 1.0, 0.0));
    float vd = dot(gd, f - vec3(1.0, 1.0, 0.0));
    float ve = dot(ge, f - vec3(0.0, 0.0, 1.0));
    float vf = dot(gf, f - vec3(1.0, 0.0, 1.0));
    float vg = dot(gg, f - vec3(0.0, 1.0, 1.0));
    float vh = dot(gh, f - vec3(1.0, 1.0, 1.0));
    
    // Interpolate
    float x1 = mix(va, vb, u.x);
    float x2 = mix(vc, vd, u.x);
    float x3 = mix(ve, vf, u.x);
    float x4 = mix(vg, vh, u.x);
    
    float y1 = mix(x1, x2, u.y);
    float y2 = mix(x3, x4, u.y);
    
    float result = mix(y1, y2, u.z);
    
    return result * 0.5 + 0.5; // Normalize to 0-1
}

float fbm(vec3 pos, int octaves) {
    float total = 0.0;
    float amplitude = 1.0;
    float frequency = 1.0;
    float maxValue = 0.0;
    
    for(int i = 0; i < octaves; i++) {
        // Alternate between perlin and worley for more interesting shapes
        float noise = (i % 2 == 0) ? 
            perlinNoise(pos * frequency) : 
            1.0 - worleyNoise(pos * frequency * 3.0);
        
        total += noise * amplitude;
        maxValue += amplitude;
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    
    return total / maxValue;
}

// Shape functions for different cloud types
float stratusShape(vec3 worldPos, float baseNoise) {
    // Stratus are flat, horizontal layers
    float height = worldPos.y;
    float base = smoothstep(0.1, 0.3, height) * (1.0 - smoothstep(0.4, 0.6, height));
    return baseNoise * base;
}

float cumulusShape(vec3 worldPos, float baseNoise) {
    // Cumulus are puffy with flat bottoms
    float height = worldPos.y;
    float base = smoothstep(0.1, 0.2, height) * (1.0 - smoothstep(0.4, 0.8, height));
    
    // More detailed at the top
    float detailModifier = mix(0.5, 1.5, smoothstep(0.4, 0.7, height));
    return baseNoise * base * detailModifier;
}

float cumulonimbusShape(vec3 worldPos, float baseNoise, float anvilAmount) {
    // Cumulonimbus are tall with anvil tops
    float height = worldPos.y;
    float base = smoothstep(0.1, 0.2, height);
    
    // Anvil shape at the top
    float topInfluence = smoothstep(0.7, 0.8, height);
    float anvilShape = 1.0;
    
    if (topInfluence > 0.0) {
        // Create horizontal spread for the anvil
        float horizontalDist = length(worldPos.xz - vec2(0.5));
        float anvilWidth = mix(0.3, 0.7, anvilAmount * topInfluence);
        anvilShape = smoothstep(anvilWidth, anvilWidth - 0.1, horizontalDist);
    }
    
    float verticalShape = base * (1.0 - smoothstep(0.8, 0.98, height));
    return baseNoise * mix(verticalShape, anvilShape, topInfluence * anvilAmount);
}

void main() {
    // Get the current voxel position
    ivec3 pos = ivec3(gl_GlobalInvocationID.xyz);
    ivec3 volumeSize = imageSize(cloudVolume);
    
    // Skip if outside volume
    if (any(greaterThanEqual(pos, volumeSize))) {
        return;
    }
    
    // Convert to 0-1 space for easier calculations
    vec3 worldPos = vec3(pos) / vec3(volumeSize);
    
    // Apply wind movement over time
    vec3 windOffset = vec3(
        cos(weather.windDirection) * weather.windSpeed * weather.time,
        0.0,
        sin(weather.windDirection) * weather.windSpeed * weather.time
    );
    
    // Add some vertical turbulence
    float turbulenceStrength = weather.turbulence * 0.2;
    
    if (turbulenceStrength > 0.0) {
        float verticalTurbulence = perlinNoise(worldPos * 5.0 + vec3(0.0, weather.time * 0.1, 0.0)) * 2.0 - 1.0;
        windOffset.y += verticalTurbulence * turbulenceStrength * worldPos.y;
    }
    
    // Sample base cloud shape with multiple octaves of FBM
    float baseNoise = fbm(worldPos + windOffset, 5);
    
    // Adjust by height for cloud layering
    float heightInfluence = 1.0;
    
    if (weather.heightGradient > 0.0) {
        // Create layers of clouds at different heights
        float heightModifier = sin(worldPos.y * 10.0 * weather.heightGradient + weather.time * 0.2);
        heightInfluence = mix(1.0, 0.7 + 0.3 * heightModifier, weather.heightGradient);
    }
    
    baseNoise *= heightInfluence;
    
    // Apply cloud shape based on cloud type
    float cloudShape;
    if (weather.cloudType < 0.25) {
        // Stratus
        cloudShape = stratusShape(worldPos, baseNoise);
    } else if (weather.cloudType < 0.75) {
        // Cumulus
        cloudShape = cumulusShape(worldPos, baseNoise);
    } else {
        // Cumulonimbus
        cloudShape = cumulonimbusShape(worldPos, baseNoise, weather.anvil);
    }
    
    // Apply weather pattern effects
    
    // 1. Cloud coverage based on weather parameters
    // Remap the noise to create sharper edges based on coverage parameter
    float coverage = smoothstep(1.0 - weather.cloudCoverage, 1.0, cloudShape);
    
    // 2. Storm system (circular formation)
    float distanceToStorm = distance(worldPos.xz, weather.stormCenter.xz);
    float stormInfluence = 1.0 - smoothstep(0.0, weather.stormRadius, distanceToStorm);
    
    // Increase density near storm center
    float stormCloud = coverage * (1.0 + stormInfluence * 2.0 * weather.precipitation);
    
    // 3. Precipitation effect (vertical stretching for rain clouds)
    float rainCloud = mix(stormCloud, stormCloud * (1.0 - worldPos.y * 0.5), weather.precipitation);
    
    // Final cloud density
    float density = rainCloud * weather.cloudDensity;
    
    // Ensure we have valid data
    density = clamp(density, 0.0, 1.0);
    
    // Store in 3D texture
    vec4 cloudData = vec4(density, density, density, density);
    imageStore(cloudVolume, pos, cloudData);
}