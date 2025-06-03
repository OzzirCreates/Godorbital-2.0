#[compute]
#version 450

/**
 * Procedural Planet Generation Shader
 * 
 * DESCRIPTION:
 * ------------
 * Generates detailed, Earth-like planetary terrain using procedural noise functions.
 * Creates vertices, normals, and biome colors for a cube-sphere planet mesh.
 * 
 * FEATURES:
 * ---------
 * - Continental landmasses with realistic distribution
 * - Mountain ranges with erosion patterns
 * - River valleys and canyons
 * - Biome distribution based on temperature, moisture, and elevation
 * - Ocean depth variations with underwater features
 * - Atmospheric effects and seasonal variations
 * 
 * ALGORITHM:
 * ----------
 * 1. Maps cube face coordinates to sphere surface
 * 2. Generates continent masks using multi-octave noise
 * 3. Creates terrain displacement with various geological features
 * 4. Calculates surface normals from displacement
 * 5. Assigns biome colors based on climate simulation
 */

// Work group size - processes vertices in 32x32 tiles
layout(local_size_x = 32, local_size_y = 32, local_size_z = 1) in;

// Output buffers for mesh data
layout(set = 0, binding = 0, std430) restrict writeonly buffer VertexBuffer {
    vec4 vertices[];    // Vertex positions in world space
} vertex_buffer;

layout(set = 0, binding = 1, std430) restrict writeonly buffer NormalBuffer {
    vec4 normals[];     // Surface normals for lighting
} normal_buffer;

layout(set = 0, binding = 2, std430) restrict writeonly buffer ColorBuffer {
    vec4 colors[];      // Biome colors with roughness in alpha
} color_buffer;

// Uniform parameters for planet generation
layout(set = 0, binding = 3) uniform PlanetParams {
    vec4 face_normal;                // Normal vector of cube face being processed
    vec4 face_up;                    // Up direction on this face
    vec4 face_right;                 // Right direction on this face
    float base_radius;               // Planet radius in world units
    float mountain_height;           // Maximum mountain height multiplier
    float canyon_depth;              // Maximum canyon depth multiplier
    float subdivisions;              // Number of subdivisions per face edge
    float time;                      // Animation time for seasonal effects
    float continent_size;            // Scale of continental features
    float continent_edge_falloff;    // Smoothness of continent edges
    float face_index;                // Which cube face (0-5)
    float ridge_sharpness;           // Sharpness of mountain ridges
    float erosion_strength;          // Amount of erosion to apply
    float terrain_contrast;          // Overall terrain height contrast
    float feature_scale;             // Scale of terrain features
} params;

// Mathematical constant
const float PI = 3.14159265359;

/**
 * High-quality hash function for pseudo-random number generation
 * Produces 4 random values from a 3D position
 * Used as the basis for all procedural noise
 */
vec4 hash4(vec3 p) {
    // Fractional part creates periodicity
    vec4 p4 = fract(vec4(p.xyzx) * vec4(443.8975, 397.2973, 491.1871, 393.2787));
    // Self-dot product for better distribution
    p4 += dot(p4, p4.wzxy + 19.19);
    // Final mixing step
    return fract((p4.xxyz + p4.yzzw) * p4.zywx);
}

/**
 * Generate gradient vectors for 3D noise
 * Returns normalized 3D vector for Perlin-style noise
 */
vec3 gradient3D(vec3 p) {
    vec4 h = hash4(p);
    // Convert [0,1] to [-1,1] range
    vec3 g = vec3(h.xyz) * 2.0 - 1.0;
    // Normalize to unit sphere
    return normalize(g);
}

/**
 * Ultra high-quality gradient noise (Perlin noise variant)
 * Uses quintic interpolation for C2 continuity (smooth derivatives)
 * This ensures terrain doesn't have visible grid artifacts
 */
float gradientNoise3D(vec3 p) {
    // Integer and fractional parts
    vec3 i = floor(p);
    vec3 f = fract(p);
    
    // Quintic Hermite interpolation curve
    // 6t^5 - 15t^4 + 10t^3 provides C2 continuity
    vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    
    // Sample gradients at 8 corners of current grid cell
    vec3 g000 = gradient3D(i + vec3(0,0,0));
    vec3 g100 = gradient3D(i + vec3(1,0,0));
    vec3 g010 = gradient3D(i + vec3(0,1,0));
    vec3 g110 = gradient3D(i + vec3(1,1,0));
    vec3 g001 = gradient3D(i + vec3(0,0,1));
    vec3 g101 = gradient3D(i + vec3(1,0,1));
    vec3 g011 = gradient3D(i + vec3(0,1,1));
    vec3 g111 = gradient3D(i + vec3(1,1,1));
    
    // Project position onto gradients
    float n000 = dot(g000, f - vec3(0,0,0));
    float n100 = dot(g100, f - vec3(1,0,0));
    float n010 = dot(g010, f - vec3(0,1,0));
    float n110 = dot(g110, f - vec3(1,1,0));
    float n001 = dot(g001, f - vec3(0,0,1));
    float n101 = dot(g101, f - vec3(1,0,1));
    float n011 = dot(g011, f - vec3(0,1,1));
    float n111 = dot(g111, f - vec3(1,1,1));
    
    // Trilinear interpolation
    float nx00 = mix(n000, n100, u.x);
    float nx10 = mix(n010, n110, u.x);
    float nx01 = mix(n001, n101, u.x);
    float nx11 = mix(n011, n111, u.x);
    float ny0 = mix(nx00, nx10, u.y);
    float ny1 = mix(nx01, nx11, u.y);
    
    // Scale and clamp to prevent extreme values
    return clamp(mix(ny0, ny1, u.z) * 1.5, -1.0, 1.0);
}

/**
 * Erosion simulation noise
 * Creates valley-like patterns that simulate water erosion
 * Used for carving realistic valleys and canyons
 */
float erosionNoise(vec3 p, float scale) {
    float n = 0.0;
    float amp = 1.0;
    float freq = scale;
    float maxAmp = 0.0;
    
    // Multi-octave erosion pattern
    for (int i = 0; i < 5; i++) {
        float noise = gradientNoise3D(p * freq);
        // Take absolute value to create valley shapes
        noise = abs(noise);
        // Invert to make valleys (not ridges)
        noise = 0.50 - noise;
        // Square for sharper valley bottoms
        noise = noise * noise;
        
        n += noise * amp;
        maxAmp += amp;
        
        // Each octave has less influence and higher frequency
        amp *= 0.45;
        freq *= 2.2;
    }
    
    // Normalize to maintain consistent range
    return n / maxAmp;
}

/**
 * Advanced erosion function with branching patterns
 * Creates realistic dendritic (tree-like) erosion patterns
 * Simulates how water carves channels in terrain
 */
float advancedErosion(vec3 p, float scale, float strength) {
    float erosion = 0.0;
    float amp = 1.0;
    float freq = scale;
    
    // Main erosion channels (primary rivers)
    float mainChannel = gradientNoise3D(p * freq * 0.5);
    mainChannel = 1.0 - abs(mainChannel);        // Create valley shape
    mainChannel = smoothstep(0.3, 0.7, mainChannel);  // Smooth threshold
    mainChannel = pow(mainChannel, 1.5);         // Deepen channels
    erosion += mainChannel * amp;
    
    // Secondary branches (tributaries)
    amp *= 0.5;
    vec3 offset = vec3(23.7, 17.3, 31.4);  // Offset to decorrelate noise
    float secondary = gradientNoise3D(p * freq + offset);
    secondary = 1.0 - abs(secondary);
    secondary = smoothstep(0.4, 0.8, secondary);
    // Reduce secondary erosion where main channel exists
    erosion += secondary * amp * (1.0 - mainChannel * 0.5);
    
    // Fine detail erosion (small streams)
    amp *= 0.3;
    float detail = erosionNoise(p, scale * 2.0);
    erosion += detail * amp;
    
    // Apply strength and smooth the result
    erosion = smoothstep(0.0, 1.0, erosion * strength);
    
    return clamp(erosion, 0.0, 1.0);
}

/**
 * Advanced ridge noise for mountain chains
 * Creates sharp ridge lines that look like real mountain ranges
 * Based on Swiss Alps and Rockies terrain studies
 */
float advancedRidgeNoise(vec3 p, float scale) {
    float value = 0.0;
    float amplitude = 1.0;
    float frequency = scale;
    float ridgePower = params.ridge_sharpness * 0.5; // Reduced for more natural ridges
    float maxAmplitude = 0.0;
    
    // Build ridges with multiple octaves
    for (int i = 0; i < 6; i++) {
        vec3 sp = p * frequency;
        
        // Rotate each octave to avoid grid alignment artifacts
        float angle = float(i) * 0.7;
        float c = cos(angle);
        float s = sin(angle);
        sp.xz = mat2(c, -s, s, c) * sp.xz;
        
        // Ridge function: 1 - |noise|
        float n = 1.0 - abs(gradientNoise3D(sp));
        n = smoothstep(0.0, 1.0, n);    // Smooth the ridges
        n = pow(n, ridgePower);          // Sharp peaks
        
        value += n * amplitude;
        maxAmplitude += amplitude;
        
        amplitude *= 0.45;               // Faster falloff for cleaner ridges
        frequency *= 2.15;               // Increase detail
        ridgePower = mix(ridgePower, 1.5, 0.1); // Gradually soften higher octaves
    }
    
    // Normalize and add base elevation
    float normalized = value / maxAmplitude;
    return clamp(normalized * 0.8 + 0.2, 0.0, 2.0);
}

/**
 * Ultra-detailed fractal noise (fBm - Fractal Brownian Motion)
 * General-purpose noise for terrain features
 * Combines multiple octaves with configurable parameters
 */
float ultraDetailedNoise(vec3 p, float octaves, float persistence, float lacunarity, float scale) {
    float value = 0.0;
    float amplitude = 1.0;
    float frequency = scale;
    float maxValue = 0.0;
    
    int octaveCount = int(min(octaves, 8.0)); // Limit for performance
    
    for (int i = 0; i < octaveCount; i++) {
        // Offset each octave to reduce repetition
        vec3 sp = p * frequency;
        sp.x += float(i) * 17.0;
        sp.y += float(i) * -23.0;
        sp.z += float(i) * 31.0;
        
        float noiseValue;
        if (i < 4) {
            // Lower octaves: standard gradient noise
            noiseValue = gradientNoise3D(sp);
        } else {
            // Higher octaves: blend multiple samples for more detail
            noiseValue = gradientNoise3D(sp * 1.7) * 0.5 + 
                        gradientNoise3D(sp * 3.1) * 0.3 +
                        gradientNoise3D(sp * 5.3) * 0.2;
        }
        
        value += noiseValue * amplitude;
        maxValue += amplitude;
        
        amplitude *= persistence;  // Reduce amplitude each octave
        frequency *= lacunarity;   // Increase frequency each octave
    }
    
    // Normalize to [-1, 1] range
    return clamp(value / maxValue, -1.0, 1.0);
}

/**
 * Generate realistic continent masks
 * Creates Earth-like continental distributions with:
 * - 7 major continents of varying sizes
 * - Island chains and archipelagos
 * - Complex coastlines with fjords and bays
 */
float generateAdvancedContinentMask(vec3 pos) {
    // Major tectonic plates (larger, slower features)
    // Scale up by 2.5x for smaller, more numerous continents
    float majorPlates = ultraDetailedNoise(pos, 3.0, 0.5, 2.0, params.continent_size * 2.5);
    majorPlates = majorPlates * 0.5 + 0.5; // Convert from [-1,1] to [0,1]
    
    // Medium-scale features (smaller landmasses, large islands)
    float mediumFeatures = ultraDetailedNoise(
        pos + vec3(50),           // Offset to decorrelate from major plates
        4.0,                      // More octaves for detail
        0.45,                     // Persistence (roughness)
        2.2,                      // Lacunarity (frequency multiplier)
        params.continent_size * 5.0
    ) * 0.35;                     // 35% contribution
    
    // Small islands and archipelagos
    float islands = ultraDetailedNoise(
        pos + vec3(100), 
        5.0, 0.4, 2.5, 
        params.continent_size * 10.0
    ) * 0.2;                      // 20% contribution
    
    // Very small islands (atolls, volcanic islands)
    float tinyIslands = ultraDetailedNoise(
        pos + vec3(200), 
        6.0, 0.35, 2.8, 
        params.continent_size * 20.0
    ) * 0.1;                      // 10% contribution
    
    // Combine all landmass features
    float landmass = majorPlates + mediumFeatures + islands + tinyIslands;
    
    // Define sea level and transition zone
    float continentThreshold = 0.48;    // Sea level threshold
    float transitionWidth = 0.15;       // Width of coastal transition
    
    // Create smooth coastlines with smoothstep
    float mask = smoothstep(
        continentThreshold - transitionWidth,  // Start of transition (underwater)
        continentThreshold + transitionWidth,  // End of transition (fully land)
        landmass
    );
    
    // Add coastal complexity for more interesting shorelines
    float coastalDetail = ultraDetailedNoise(pos * 30.0, 4.0, 0.5, 2.0, 1.0) * 0.15;
    // Apply detail strongest near coasts (where mask ≈ 0.5)
    float coastalZone = 1.0 - abs(mask - 0.5) * 2.0;
    mask += coastalDetail * coastalZone * 0.4;
    
    // Create fjords and complex coastlines
    float fjordNoise = ultraDetailedNoise(pos * 50.0, 3.0, 0.6, 2.5, 1.0);
    // Only create fjords near the coastline and where noise is high
    if (abs(mask - 0.5) < 0.1 && fjordNoise > 0.3) {
        // Push the coastline in or out based on fjord pattern
        mask += (fjordNoise - 0.3) * 0.5 * sign(mask - 0.5);
    }
    
    return clamp(mask, 0.0, 1.0);
}

/**
 * Calculate ice coverage based on climate simulation
 * Considers latitude, temperature, and elevation
 * Creates realistic polar ice caps and mountain snow
 */
float calculateIceWeight(vec3 sphere_pos, float temperature, float absoluteElevation) {
    float latitude = sphere_pos.y;        // Y = up = polar axis
    float absLatitude = abs(latitude);    // Distance from equator
    float equatorDistance = 1.0 - absLatitude;
    
    // Optional seasonal variation
    float season = sin(params.time * 0.01) * 0.1;  // Very slow change
    float seasonalAdjust = season * (1.0 - absLatitude * 0.5); // Less effect at poles
    
    // Polar ice caps - only at extreme latitudes
    float polarIce = smoothstep(
        0.75 - seasonalAdjust,           // Start forming ice
        0.9 - seasonalAdjust * 0.5,      // Fully frozen
        absLatitude
    );
    
    // Mountain snow line calculation
    // Lower snow line at higher latitudes
    float snowLine = 0.004 -             // Base snow line elevation
                    temperature * 0.001 -  // Warmer = higher snow line
                    equatorDistance * 0.0005; // Latitude adjustment
                    
    float mountainSnow = smoothstep(
        snowLine - 0.0003,               // Start of snow
        snowLine + 0.0006,               // Full snow coverage
        absoluteElevation
    ) * (1.0 - temperature * 0.5);       // Less snow in warm areas
    
    // Permanent snow on very high peaks
    if (absoluteElevation > 0.005) {
        float highAltitudeSnow = smoothstep(0.005, 0.007, absoluteElevation) 
                                * (1.0 - temperature * 0.9);
        mountainSnow = max(mountainSnow, highAltitudeSnow);
    }
    
    // Add noise to break up uniform ice edges
    float iceNoise = ultraDetailedNoise(sphere_pos * 5.0, 2.0, 0.5, 2.0, 1.0) * 0.1;
    
    return clamp(max(polarIce, mountainSnow) + iceNoise, 0.0, 1.0);
}

/**
 * Calculate HDR (High Dynamic Range) terrain displacement
 * This is the main terrain generation function that creates all surface features
 * Returns displacement value to add to sphere radius
 */
float calculateHDRDisplacement(vec3 sphere_pos, float continent) {
    // Global scale factor for all terrain features
    float TERRAIN_SCALE = 0.2;
    
    // Base elevation with tectonic-scale features
    float baseElevation = ultraDetailedNoise(
        sphere_pos, 
        7.0,                              // Many octaves for detail
        0.6,                              // High persistence for roughness
        2.1,                              // Lacunarity
        params.feature_scale * 3.0        // Feature scale
    );
    
    // Add large-scale tectonic features
    float tectonics = ultraDetailedNoise(sphere_pos * 2.0, 4.0, 0.65, 2.0, 1.0) * 0.08;
    baseElevation = clamp(baseElevation + tectonics, -1.0, 1.0);
    
    float displacement = 0.0;
    
    // Define smooth transition zones between ocean/beach/land
    float oceanToBeach = smoothstep(0.42, 0.48, continent);
    float beachToLand = smoothstep(0.48, 0.55, continent);
    float deepOcean = smoothstep(0.3, 0.0, continent);
    
    // === OCEAN FLOOR GENERATION ===
    if (continent < 0.48) {
        // Base ocean depth
        float oceanFloorBase = -0.004 - (0.012 * deepOcean);  // Deeper in open ocean
        
        // Ocean floor detail
        float oceanFloorDetail = ultraDetailedNoise(sphere_pos * 8.0, 5.0, 0.6, 2.2, 1.0) * 0.005;
        
        // Underwater canyons (trenches)
        float underwaterCanyons = advancedErosion(sphere_pos * 6.0, 1.0, 0.5) * 0.008 * deepOcean;
        
        // Mid-ocean ridges (underwater mountain ranges)
        float oceanRidges = advancedRidgeNoise(sphere_pos * 5.0, 2.0) * 0.003 * deepOcean;
        
        // Deep ocean trenches
        float oceanTrenches = -abs(gradientNoise3D(sphere_pos * 3.0)) * 0.006 * deepOcean;
        
        // Seamounts (underwater volcanoes)
        float seamounts = max(0.0, ultraDetailedNoise(sphere_pos * 10.0, 3.0, 0.7, 2.0, 1.0) - 0.6) 
                         * 0.02 * deepOcean;
        
        // Combine ocean features
        float oceanDisplacement = oceanFloorBase + oceanFloorDetail + oceanRidges 
                                + oceanTrenches - underwaterCanyons + seamounts;
        oceanDisplacement *= (1.0 - oceanToBeach);  // Fade out near beaches
        
        displacement = oceanDisplacement;
    }
    
    // === BEACH AND COASTAL AREAS ===
    if (continent >= 0.42 && continent < 0.55) {
        // Beach base elevation
        float beachBase = mix(-0.001, 0.001, oceanToBeach);
        
        // Beach profile variation
        float beachProfile = ultraDetailedNoise(sphere_pos * 25.0, 3.0, 0.5, 2.0, 1.0) * 0.002;
        
        // Sand dunes
        float dunes = abs(sin(sphere_pos.x * 50.0 + sphere_pos.z * 50.0)) * 0.001 * oceanToBeach;
        
        // Rock formations on beaches
        float beachRocks = max(0.0, ultraDetailedNoise(sphere_pos * 40.0, 3.0, 0.6, 2.0, 1.0) - 0.7) 
                          * 0.005;
        
        // Tidal pools (small depressions)
        float tidalPools = -max(0.0, sin(ultraDetailedNoise(sphere_pos * 60.0, 2.0, 0.5, 2.0, 1.0) * 20.0)) 
                          * 0.0005 * oceanToBeach;
        
        float beachDisplacement = beachBase + beachProfile + dunes + beachRocks + tidalPools;
        
        // Blend between ocean and beach
        if (continent < 0.48) {
            displacement = mix(displacement, beachDisplacement, oceanToBeach);
        } else {
            displacement = beachDisplacement;
        }
    }
    
    // === LAND TERRAIN GENERATION ===
    if (continent >= 0.48) {
        // Base land elevation
        float landBase = 0.001 + beachToLand * 0.005;
        
        // Continental shelf and major elevation changes
        float continentalShelf = ultraDetailedNoise(sphere_pos * 0.5, 3.0, 0.6, 1.8, 1.0) 
                               * 0.04 * beachToLand;
        float regionalBase = ultraDetailedNoise(sphere_pos * 1.5, 4.0, 0.55, 2.0, 1.0) 
                           * 0.03 * beachToLand;
        float localBase = ultraDetailedNoise(sphere_pos * 4.0, 5.0, 0.5, 2.1, 1.0) 
                        * 0.02 * beachToLand;
        
        // Continental rift valleys
        float continentalRift = sin(sphere_pos.x * 2.0 + sphere_pos.z * 1.5) * 0.01 * beachToLand;
        continentalRift *= ultraDetailedNoise(sphere_pos * 0.3, 2.0, 0.5, 2.0, 1.0);
        
        float landDisplacement = landBase + continentalShelf + regionalBase 
                               + localBase + continentalRift;
        
        // How far inland (affects feature intensity)
        float inlandFactor = smoothstep(0.55, 0.7, continent);
        
        // === TERRAIN FEATURES ===
        
        // PLATEAUS AND MESAS
        float plateauNoise = ultraDetailedNoise(sphere_pos * 0.8, 3.0, 0.5, 1.8, 1.0);
        float plateauMask = smoothstep(0.3, 0.5, plateauNoise) * inlandFactor;
        if (plateauMask > 0.0) {
            float plateauHeight = 0.015 + ultraDetailedNoise(sphere_pos * 2.0, 2.0, 0.4, 2.0, 1.0) * 0.01;
            // Sharp mesa edges
            float mesaEdge = smoothstep(0.7, 0.8, plateauNoise);
            plateauHeight *= mix(0.7, 1.0, mesaEdge);
            landDisplacement += plateauHeight * plateauMask;
        }
        
        // ROLLING HILLS
        float hillsLarge = ultraDetailedNoise(sphere_pos * 3.0, 4.0, 0.55, 2.0, 1.0) * 0.02;
        float hillsMedium = ultraDetailedNoise(sphere_pos * 8.0, 4.0, 0.5, 2.1, 1.0) * 0.01;
        float hillsSmall = ultraDetailedNoise(sphere_pos * 20.0, 4.0, 0.45, 2.3, 1.0) * 0.005;
        landDisplacement += (hillsLarge + hillsMedium + hillsSmall) * inlandFactor;
        
        // MOUNTAIN RANGES
        float mountainZones = ultraDetailedNoise(sphere_pos * 1.5, 4.0, 0.6, 2.0, 1.0);
        float mountainMask = smoothstep(0.1, 0.35, mountainZones) * inlandFactor;
        
        if (mountainMask > 0.0) {
            // Natural mountain shape with slopes
            float baseShape = ultraDetailedNoise(sphere_pos * 0.8, 3.0, 0.7, 1.8, 1.0) * 0.5 + 0.5;
            baseShape = pow(baseShape, 1.5) * mountainMask;
            
            // Primary ridges
            float ridges = advancedRidgeNoise(sphere_pos * 3.0, params.feature_scale * 1.5);
            ridges = pow(ridges, 1.2);
            
            // Combine for realistic mountains
            float mountainHeight = (baseShape * 0.4 + ridges * 0.6) * mountainMask * 0.08;
            landDisplacement += mountainHeight;
            
            // Secondary ridges and details
            float secondaryRidges = advancedRidgeNoise(sphere_pos * 8.0, params.feature_scale * 3.0);
            secondaryRidges = pow(secondaryRidges, 1.0);
            landDisplacement += secondaryRidges * 0.03 * mountainMask * (1.0 - ridges * 0.3);
            
            // Mountain valleys
            float valleyNoise = gradientNoise3D(sphere_pos * 12.0);
            float valleyPattern = 1.0 - abs(valleyNoise);
            valleyPattern = smoothstep(0.3, 0.7, valleyPattern);
            float mountainValley = valleyPattern * 0.03 * mountainMask;
            
            // More erosion at lower elevations
            float erosionFactor = 1.0 - smoothstep(0.3, 0.8, mountainHeight);
            mountainValley *= (1.0 + erosionFactor * 0.5);
            landDisplacement -= mountainValley;
        }
        
        // Apply final displacement
        displacement = mix(displacement, landDisplacement, beachToLand);
    }
    
    // Apply scale and contrast
    return displacement * params.terrain_contrast * TERRAIN_SCALE;
}

/**
 * Calculate high-quality terrain normals
 * Uses finite difference method on the sphere surface
 * Essential for proper lighting and shading
 */
vec3 calculateHDRNormal(vec3 sphere_pos, float displacement) {
    // Step size for finite difference calculation
    float h = 0.0002; // Small value for accurate derivatives
    
    // Get orthogonal tangent vectors on sphere surface
    // We need these to sample neighboring points correctly
    vec3 tangent = normalize(cross(sphere_pos, vec3(0, 1, 0)));
    
    // Handle pole singularity where Y axis is parallel to position
    if (abs(sphere_pos.y) > 0.99) {
        tangent = normalize(cross(sphere_pos, vec3(1, 0, 0)));
    }
    
    // Calculate bitangent perpendicular to both normal and tangent
    vec3 bitangent = normalize(cross(sphere_pos, tangent));
    
    // Ensure perfect orthogonality
    bitangent = normalize(cross(sphere_pos, tangent));
    tangent = normalize(cross(bitangent, sphere_pos));
    
    // 5-point stencil for accurate derivatives
    float h_small = h * 0.5;
    
    // Sample positions on sphere
    vec3 p0 = sphere_pos;                                    // Center
    vec3 px1 = normalize(sphere_pos + tangent * h_small);   // +X direction
    vec3 px2 = normalize(sphere_pos - tangent * h_small);   // -X direction
    vec3 py1 = normalize(sphere_pos + bitangent * h_small); // +Y direction
    vec3 py2 = normalize(sphere_pos - bitangent * h_small); // -Y direction
    
    // Sample continent mask at each position
    float c0 = generateAdvancedContinentMask(p0);
    float cx1 = generateAdvancedContinentMask(px1);
    float cx2 = generateAdvancedContinentMask(px2);
    float cy1 = generateAdvancedContinentMask(py1);
    float cy2 = generateAdvancedContinentMask(py2);
    
    // Calculate displacement at each position
    float d0 = displacement;  // Already calculated for center
    float dx1 = calculateHDRDisplacement(px1, cx1);
    float dx2 = calculateHDRDisplacement(px2, cx2);
    float dy1 = calculateHDRDisplacement(py1, cy1);
    float dy2 = calculateHDRDisplacement(py2, cy2);
    
    // Calculate actual world positions
    vec3 pos0 = p0 * params.base_radius * (1.0 + d0);
    vec3 posx1 = px1 * params.base_radius * (1.0 + dx1);
    vec3 posx2 = px2 * params.base_radius * (1.0 + dx2);
    vec3 posy1 = py1 * params.base_radius * (1.0 + dy1);
    vec3 posy2 = py2 * params.base_radius * (1.0 + dy2);
    
    // Central difference for derivatives
    vec3 dpdx = (posx1 - posx2) / (2.0 * h_small);
    vec3 dpdy = (posy1 - posy2) / (2.0 * h_small);
    
    // Calculate normal via cross product
    vec3 normal = normalize(cross(dpdx, dpdy));
    
    // Ensure normal points outward from planet center
    if (dot(normal, sphere_pos) < 0.0) {
        normal = -normal;
    }
    
    // Add micro-detail to normal for surface texture
    vec3 detailNormal = vec3(
        gradientNoise3D(sphere_pos * 300.0),
        gradientNoise3D(sphere_pos * 300.0 + vec3(31.0)),
        gradientNoise3D(sphere_pos * 300.0 + vec3(67.0))
    ) * 0.008;  // Very subtle
    
    return normalize(normal + detailNormal);
}

/**
 * Calculate terrain slope for vegetation and erosion
 * Returns gradient magnitude at current position
 */
float calculateSlope(vec3 sphere_pos, float displacement) {
    float h = 0.0004; // Sampling distance
    
    // Get tangent vectors
    vec3 tangent = normalize(cross(sphere_pos, vec3(0, 1, 0)));
    if (abs(sphere_pos.y) > 0.99) {
        tangent = normalize(cross(sphere_pos, vec3(1, 0, 0)));
    }
    vec3 bitangent = normalize(cross(sphere_pos, tangent));
    
    // Sample neighboring points
    vec3 p0 = normalize(sphere_pos);
    vec3 px = normalize(sphere_pos + tangent * h);
    vec3 py = normalize(sphere_pos + bitangent * h);
    
    // Get displacements
    float c0 = generateAdvancedContinentMask(p0);
    float cx = generateAdvancedContinentMask(px);
    float cy = generateAdvancedContinentMask(py);
    
    float d0 = displacement;
    float dx = calculateHDRDisplacement(px, cx);
    float dy = calculateHDRDisplacement(py, cy);
    
    // Calculate gradient
    vec2 gradient = vec2(dx - d0, dy - d0) / h;
    return length(gradient);
}

/**
 * Generate Earth-like biome colors based on climate simulation
 * Considers temperature, moisture, elevation, and latitude
 * Returns color with roughness value in alpha channel
 */
vec4 generateEarthlikeBiomeColor(vec3 sphere_pos, float continent, float elevation, float displacement) {
    vec3 color = vec3(0.0);
    float roughness = 0.8;  // Default surface roughness
    
    // Use absolute elevation for consistent biome placement
    float absoluteElevation = abs(displacement);
    float heightFactor = clamp(absoluteElevation / 0.1, 0.0, 1.0);
    
    // Calculate slope for vegetation limits
    float slope = calculateSlope(sphere_pos, displacement);
    float slopeFactor = smoothstep(1.2, 0.3, slope);  // Less vegetation on steep slopes
    
    // === CLIMATE SIMULATION ===
    float latitude = sphere_pos.y;  // -1 to 1 from south to north pole
    float absLatitude = abs(latitude);
    float equatorDistance = 1.0 - absLatitude;
    
    // Temperature calculation
    float baseTemp = pow(equatorDistance, 0.6);  // Warmer at equator
    float altitude = max(0.0, absoluteElevation * 10.0);
    float temperature = baseTemp - altitude * 0.4;  // Cooler at altitude
    float tempVariation = ultraDetailedNoise(sphere_pos * 8.0, 3.0, 0.5, 2.0, 1.0) * 0.2;
    temperature = clamp(temperature + tempVariation, 0.0, 1.0);
    
    // Moisture calculation
    float baseMoisture = ultraDetailedNoise(sphere_pos * 5.0, 4.0, 0.5, 2.0, 1.0) * 0.5 + 0.5;
    float oceanDistance = smoothstep(0.3, 0.9, continent);
    float coastalMoisture = 1.0 - oceanDistance * 0.8;  // More moisture near oceans
    float moisture = baseMoisture * 0.3 + coastalMoisture * 0.5 + 0.2;
    float moistureVar = ultraDetailedNoise(sphere_pos * 10.0 + vec3(100), 3.0, 0.5, 2.0, 1.0) * 0.25;
    moisture = clamp(moisture + moistureVar, 0.0, 1.0);
    
    // Noise for biome boundaries
    float boundaryNoise = ultraDetailedNoise(sphere_pos * 50.0, 3.0, 0.5, 2.0, 1.0) * 0.08;
    
    // === OCEAN AND WATER BIOMES ===
    if (continent < 0.45) {
        float depth = clamp(-displacement / 0.015, 0.0, 1.0);
        
        // Deep ocean colors by temperature
        if (continent < 0.15) {
            vec3 tropicalDeep = vec3(0.0, 0.3, 0.6);      // Deep blue
            vec3 temperateDeep = vec3(0.0, 0.2, 0.45);    // Darker blue
            vec3 coldDeep = vec3(0.05, 0.15, 0.35);       // Gray-blue
            
            vec3 oceanColor;
            if (temperature > 0.7) {
                oceanColor = tropicalDeep;
            } else if (temperature > 0.4) {
                float t = (temperature - 0.4) / 0.3;
                oceanColor = mix(temperateDeep, tropicalDeep, t);
            } else {
                oceanColor = coldDeep;
            }
            
            color = mix(oceanColor * 1.2, oceanColor * 0.6, depth);
            roughness = 0.05;  // Very smooth water
        }
        // Shallow waters
        else if (continent < 0.25) {
            vec3 tropicalShallow = vec3(0.0, 0.85, 0.95);  // Bright turquoise
            vec3 tropicalLagoon = vec3(0.1, 0.9, 0.85);    // Light turquoise
            
            vec3 shallowColor;
            if (temperature > 0.7) {
                // Coral reef colors
                float reefNoise = ultraDetailedNoise(sphere_pos * 200.0, 2.0, 0.5, 2.0, 1.0);
                if (reefNoise > 0.6) {
                    vec3 coralColor = vec3(0.2, 0.95, 0.85);
                    shallowColor = mix(tropicalShallow, coralColor, (reefNoise - 0.6) * 2.5);
                } else {
                    shallowColor = mix(tropicalShallow, tropicalLagoon, depth);
                }
            } else {
                shallowColor = vec3(0.1, 0.6, 0.75);  // Temperate shallow
            }
            
            color = shallowColor;
            roughness = 0.1;
        }
        // Beach zones
        else {
            float beachZone = (continent - 0.25) / 0.1;
            vec3 wetSand = vec3(0.75, 0.7, 0.6);
            vec3 drySand = vec3(0.9, 0.85, 0.7);
            
            if (temperature > 0.75) {
                // Tropical beaches
                wetSand = vec3(0.9, 0.85, 0.75);
                drySand = vec3(0.98, 0.95, 0.88);
            }
            
            color = mix(wetSand, drySand, beachZone);
            roughness = mix(0.2, 0.7, beachZone);
        }
    }
    // === LAND BIOMES ===
    else {
        // Define all biome colors
        vec3 snowColor = vec3(0.98, 0.98, 1.0);
        vec3 tundraColor = vec3(0.5, 0.54, 0.44);
        vec3 borealColor = vec3(0.05, 0.35, 0.15);
        vec3 temperateForestColor = vec3(0.15, 0.55, 0.15);
        vec3 grasslandColor = vec3(0.55, 0.75, 0.25);
        vec3 savannaColor = vec3(0.85, 0.78, 0.35);
        vec3 desertColor = vec3(0.95, 0.82, 0.45);
        vec3 rainforestColor = vec3(0.01, 0.45, 0.03);
        
        // Calculate biome weights based on climate
        float snowWeight = 0.0;
        float tundraWeight = 0.0;
        float forestWeight = 0.0;
        float grassWeight = 0.0;
        float desertWeight = 0.0;
        
        // Snow - cold or high elevation
        if (temperature < 0.2 || absoluteElevation > 0.006) {
            snowWeight = 1.0;
        }
        // Tundra - cold but not frozen
        else if (temperature < 0.4 && moisture > 0.2) {
            tundraWeight = 1.0;
        }
        // Desert - hot and dry
        else if (temperature > 0.6 && moisture < 0.3) {
            desertWeight = 1.0;
        }
        // Forest - moderate temp and moisture
        else if (temperature > 0.3 && moisture > 0.5) {
            forestWeight = 1.0;
        }
        // Grassland - default
        else {
            grassWeight = 1.0;
        }
        
        // Blend biomes
        float totalWeight = snowWeight + tundraWeight + forestWeight + grassWeight + desertWeight;
        totalWeight = max(totalWeight, 0.001);
        
        color = (snowColor * snowWeight + 
                tundraColor * tundraWeight + 
                temperateForestColor * forestWeight + 
                grasslandColor * grassWeight + 
                desertColor * desertWeight) / totalWeight;
        
        // Add local variations
        vec3 localVar = vec3(
            ultraDetailedNoise(sphere_pos * 100.0, 3.0, 0.5, 2.0, 1.0),
            ultraDetailedNoise(sphere_pos * 100.0 + vec3(50), 3.0, 0.5, 2.0, 1.0),
            ultraDetailedNoise(sphere_pos * 100.0 + vec3(100), 3.0, 0.5, 2.0, 1.0)
        ) * 0.06;
        
        color = color * (1.0 + localVar);
        
        // Adjust roughness by biome
        roughness = 0.65;
        roughness -= forestWeight / totalWeight * 0.2;  // Forests are less rough
        roughness += desertWeight / totalWeight * 0.25; // Deserts are rougher
        roughness -= snowWeight / totalWeight * 0.3;    // Snow is smooth
    }
    
    // Final color adjustments
    color = clamp(color, vec3(0.0), vec3(1.0));
    
    // Atmospheric tint at high elevations
    if (absoluteElevation > 0.005) {
        float atmBlend = smoothstep(0.005, 0.008, absoluteElevation) * 0.04;
        color = mix(color, vec3(0.85, 0.88, 0.92), atmBlend);
    }
    
    // Enhance saturation
    float luminance = dot(color, vec3(0.299, 0.587, 0.114));
    color = mix(vec3(luminance), color, 1.25);
    
    // Final adjustments
    color = pow(color, vec3(0.95));  // Gamma correction
    color = color * 1.05;            // Brightness boost
    color = clamp(color, vec3(0.0), vec3(1.0));
    
    return vec4(color, roughness);
}

/**
 * Main compute shader entry point
 * Generates vertex, normal, and color data for planet mesh
 */
void main() {
    // Get thread position
    uvec2 id = gl_GlobalInvocationID.xy;
    uint subdivisions = uint(params.subdivisions);
    
    // Bounds checking
    if (id.x > subdivisions || id.y > subdivisions) {
        return;
    }
    
    // Calculate vertex index in global buffer
    uint face_idx = uint(params.face_index);
    uint verts_per_face = (subdivisions + 1) * (subdivisions + 1);
    uint vertex_id = id.y * (subdivisions + 1) + id.x + (face_idx * verts_per_face);
    
    // Additional safety check
    uint total_vertices = verts_per_face * 6;  // 6 faces on cube
    if (vertex_id >= total_vertices) {
        return;
    }
    
    // Map thread position to cube face coordinates (-1 to 1)
    float u = (float(id.x) / float(subdivisions)) * 2.0 - 1.0;
    float v = (float(id.y) / float(subdivisions)) * 2.0 - 1.0;
    
    // Clamp to avoid numerical issues at edges
    u = clamp(u, -0.999999, 0.999999);
    v = clamp(v, -0.999999, 0.999999);
    
    // Calculate position on cube face
    vec3 cube_pos = params.face_normal.xyz +     // Face center
                    params.face_right.xyz * u +   // Horizontal offset
                    params.face_up.xyz * v;       // Vertical offset
    
    // Normalize to project onto unit sphere
    vec3 sphere_pos = cube_pos / length(cube_pos);
    
    // Generate terrain
    float continent = generateAdvancedContinentMask(sphere_pos);
    float displacement = calculateHDRDisplacement(sphere_pos, continent);
    vec3 surface_normal = calculateHDRNormal(sphere_pos, displacement);
    
    // Calculate final world position
    vec3 final_pos = sphere_pos * params.base_radius * (1.0 + displacement);
    
    // Generate biome colors
    float elevation = ultraDetailedNoise(sphere_pos, 6.0, 0.65, 1.95, params.feature_scale);
    vec4 colorData = generateEarthlikeBiomeColor(sphere_pos, continent, elevation, displacement);
    
    // Write results to buffers
    vertex_buffer.vertices[vertex_id] = vec4(final_pos, 1.0);
    normal_buffer.normals[vertex_id] = vec4(surface_normal, 0.0);
    color_buffer.colors[vertex_id] = colorData; // RGB color + roughness in alpha
}