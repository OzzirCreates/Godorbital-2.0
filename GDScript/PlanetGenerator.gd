extends MeshInstance3D
## GPU Planet Generator
##
## PURPOSE:
## --------
## Generates a detailed planet mesh using GPU compute shaders.
## Creates Earth-like terrain with continents, oceans, mountains, and biomes.
## Uses a cube-sphere approach for uniform vertex distribution.
##
## ALGORITHM:
## ----------
## 1. Creates 6 cube faces with specified subdivisions
## 2. Projects cube vertices onto sphere surface
## 3. Generates terrain using procedural noise on GPU
## 4. Welds duplicate vertices for seamless mesh
## 5. Applies PBR materials with biome-based coloring
## 6. Adds atmospheric effects

# === PLANET CONFIGURATION ===
# Number of subdivisions per cube face edge
# Higher = more detail but more memory/processing
const SUBDIVISIONS := 512  

# Base sphere radius before terrain displacement
const BASE_RADIUS := 1000.0

# Maximum mountain height above base radius
const MOUNTAIN_HEIGHT := 0.4

# Maximum canyon/ocean depth below base radius  
const CANYON_DEPTH := 5.0

# === GPU COMPUTE RESOURCES ===
# RenderingDevice for compute operations
var rd: RenderingDevice

# Compute shader resource ID
var compute_shader: RID

# Compute pipeline for dispatching work
var pipeline: RID

# === GPU BUFFERS ===
# Buffer for vertex positions (vec4 per vertex)
var vertex_buffer: RID

# Buffer for vertex normals (vec4 per normal)
var normal_buffer: RID  

# Buffer for vertex colors and roughness (vec4)
var color_buffer: RID

# Buffer for uniform parameters sent to shader
var uniform_buffer: RID

# === PERFORMANCE TRACKING ===
# Time when generation started
var generation_start_time: float

# Memory usage at start for tracking
var memory_usage_start: int

# === SCENE ENVIRONMENT ===
# Environment settings for rendering
var environment: Environment

func _ready():
	print("=== Starting Optimized GPU Planet Generation ===")
	# Display GPU info for debugging
	print("GPU: ", RenderingServer.get_video_adapter_name())
	print("Target subdivisions: ", SUBDIVISIONS)
	
	# Start performance tracking
	memory_usage_start = OS.get_static_memory_usage()
	generation_start_time = Time.get_ticks_msec() / 1000.0
	
	# Setup rendering environment
	setup_scene_environment()
	
	# Initialize GPU compute pipeline
	setup_compute_pipeline()
	
	# Verify pipeline is ready
	if compute_shader.is_valid() and pipeline.is_valid():
		print("Starting planet generation...")
		generate_planet_gpu()
	else:
		push_error("Failed to setup compute pipeline!")
	
	# Report performance metrics
	var elapsed = (Time.get_ticks_msec() / 1000.0) - generation_start_time
	var memory_used = (OS.get_static_memory_usage() - memory_usage_start) / 1048576.0
	print("Total generation time: %.3f seconds" % elapsed)
	print("Memory used: %.2f MB" % memory_used)

## Setup GPU compute pipeline for planet generation
func setup_compute_pipeline():
	# === CREATE RENDERING DEVICE ===
	# Local rendering device for compute operations
	rd = RenderingServer.create_local_rendering_device()
	if not rd:
		push_error("Failed to create local rendering device!")
		return
	
	# === LOAD COMPUTE SHADER ===
	# Load the planet generation compute shader
	var shader_file = load("res://assets/shaders/compute/planet_generation.glsl")
	if shader_file == null:
		push_error("Planet generation shader not found!")
		return
	
	# === COMPILE SHADER ===
	# Create shader from SPIR-V bytecode
	compute_shader = rd.shader_create_from_spirv(shader_file.get_spirv())
	if not compute_shader.is_valid():
		push_error("Shader compilation failed!")
		return
	
	# === CREATE PIPELINE ===
	# Create compute pipeline from shader
	pipeline = rd.compute_pipeline_create(compute_shader)
	if not pipeline.is_valid():
		push_error("Failed to create compute pipeline!")
		return
	
	print("Compute pipeline created successfully")

## Create GPU buffers for vertex data
## @param vertex_count: Total number of vertices to allocate
func create_gpu_buffers(vertex_count: int):
	# Calculate buffer size (vec4 = 4 floats = 16 bytes)
	var buffer_size = vertex_count * 16
	
	print("Creating GPU buffers for %d vertices (%.2f MB total)" % [
		vertex_count, 
		buffer_size * 3 / 1048576.0  # 3 buffers total
	])
	
	# === CREATE EMPTY BUFFER ===
	# Initialize with zeros
	var empty_data = PackedByteArray()
	empty_data.resize(buffer_size)
	
	# === CREATE STORAGE BUFFERS ===
	# These will be written by the compute shader
	vertex_buffer = rd.storage_buffer_create(buffer_size, empty_data)
	normal_buffer = rd.storage_buffer_create(buffer_size, empty_data)
	color_buffer = rd.storage_buffer_create(buffer_size, empty_data)
	
	# === CREATE UNIFORM BUFFER ===
	# For passing parameters to shader
	# 128 bytes is enough for our parameters
	var uniform_data = PackedByteArray()
	uniform_data.resize(128)
	uniform_buffer = rd.uniform_buffer_create(128, uniform_data)

## Main GPU planet generation function
func generate_planet_gpu():
	# === CALCULATE VERTEX COUNTS ===
	# Each face is a grid of (subdivisions+1)² vertices
	var verts_per_face = (SUBDIVISIONS + 1) * (SUBDIVISIONS + 1)
	# Cube has 6 faces
	var total_vertices = verts_per_face * 6
	
	print("Generating planet with %d total vertices" % total_vertices)
	
	# Create GPU buffers
	create_gpu_buffers(total_vertices)
	
	# Verify buffers are valid
	if not vertex_buffer.is_valid() or not normal_buffer.is_valid() or not color_buffer.is_valid():
		push_error("Failed to create buffers!")
		return
	
	# === DEFINE CUBE FACES ===
	# Each face has normal, up, and right vectors
	var faces = [
		# Front face (+Z)
		{"normal": Vector3(0, 0, 1), "up": Vector3(0, 1, 0), "right": Vector3(1, 0, 0)},
		# Back face (-Z)
		{"normal": Vector3(0, 0, -1), "up": Vector3(0, 1, 0), "right": Vector3(-1, 0, 0)},
		# Right face (+X)
		{"normal": Vector3(1, 0, 0), "up": Vector3(0, 1, 0), "right": Vector3(0, 0, -1)},
		# Left face (-X)
		{"normal": Vector3(-1, 0, 0), "up": Vector3(0, 1, 0), "right": Vector3(0, 0, 1)},
		# Top face (+Y)
		{"normal": Vector3(0, 1, 0), "up": Vector3(0, 0, -1), "right": Vector3(1, 0, 0)},
		# Bottom face (-Y)
		{"normal": Vector3(0, -1, 0), "up": Vector3(0, 0, 1), "right": Vector3(1, 0, 0)}
	]
	
	# === PROCESS EACH FACE ===
	for i in range(6):
		print("Processing face %d" % i)
		# Dispatch compute shader for this face
		dispatch_face_generation(faces[i], i)
		# Submit work to GPU
		rd.submit()
		# Wait for completion before next face
		rd.sync()
	
	# Create final mesh from GPU data
	create_mesh_from_gpu_data(total_vertices)

## Dispatch compute shader for one cube face
## @param face: Dictionary with normal, up, right vectors
## @param face_index: Which face (0-5)
func dispatch_face_generation(face: Dictionary, face_index: int):
	# === PREPARE UNIFORM DATA ===
	# Pack all parameters into float array for GPU
	var uniform_data = PackedFloat32Array([
		# Face orientation vectors (3x vec4)
		face.normal.x, face.normal.y, face.normal.z, 0.0,      # Face normal
		face.up.x, face.up.y, face.up.z, 0.0,                  # Up direction
		face.right.x, face.right.y, face.right.z, 0.0,         # Right direction
		# Terrain parameters
		BASE_RADIUS,            # Planet radius
		MOUNTAIN_HEIGHT,        # Max mountain height
		CANYON_DEPTH,           # Max ocean depth
		float(SUBDIVISIONS),    # Grid subdivisions
		# Generation parameters
		Time.get_ticks_msec() / 1000.0,  # Time for animation
		1.2,   # continent_size - Scale of continental features
		0.2,   # continent_edge_falloff - Smoothness of coasts
		float(face_index),      # Which face we're generating
		2.5,   # ridge_sharpness - Mountain ridge sharpness
		0.1,   # erosion_strength - Erosion amount
		1.5,   # terrain_contrast - Height multiplier
		8.0    # feature_scale - Overall feature scale
	])
	
	# Convert to byte array for GPU upload
	var data_bytes = uniform_data.to_byte_array()
	# Update uniform buffer with parameters
	rd.buffer_update(uniform_buffer, 0, data_bytes.size(), data_bytes)
	
	# === CREATE UNIFORM SET ===
	# Bind buffers to shader bindings
	var uniforms = []
	
	# Binding 0: Vertex buffer (output)
	uniforms.append(create_storage_buffer_uniform(0, vertex_buffer))
	# Binding 1: Normal buffer (output)
	uniforms.append(create_storage_buffer_uniform(1, normal_buffer))
	# Binding 2: Color buffer (output)
	uniforms.append(create_storage_buffer_uniform(2, color_buffer))
	
	# Binding 3: Parameters (input)
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	params_uniform.binding = 3
	params_uniform.add_id(uniform_buffer)
	uniforms.append(params_uniform)
	
	# Create uniform set for this dispatch
	var uniform_set = rd.uniform_set_create(uniforms, compute_shader, 0)
	
	# === DISPATCH COMPUTE WORK ===
	var compute_list = rd.compute_list_begin()
	
	# Bind pipeline and uniforms
	rd.compute_list_bind_compute_pipeline(compute_list, pipeline)
	rd.compute_list_bind_uniform_set(compute_list, uniform_set, 0)
	
	# Calculate work groups
	# Each work group is 32x32 threads (defined in shader)
	var groups_x = int((SUBDIVISIONS + 31) / 32)  # Round up division
	var groups_y = int((SUBDIVISIONS + 31) / 32)
	
	# Dispatch the compute shader
	rd.compute_list_dispatch(compute_list, groups_x, groups_y, 1)
	
	rd.compute_list_end()
	
	# Clean up uniform set
	rd.free_rid(uniform_set)

## Helper to create storage buffer uniform descriptor
func create_storage_buffer_uniform(binding: int, buffer: RID) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	uniform.binding = binding
	uniform.add_id(buffer)
	return uniform

## Create mesh from GPU-generated vertex data
func create_mesh_from_gpu_data(vertex_count: int):
	print("Creating mesh from GPU data...")
	
	# === RETRIEVE GPU DATA ===
	# Download buffers from GPU to CPU
	var vertex_bytes = rd.buffer_get_data(vertex_buffer)
	var normal_bytes = rd.buffer_get_data(normal_buffer)
	var color_bytes = rd.buffer_get_data(color_buffer)
	
	# Convert byte arrays to float arrays
	var vertex_floats = vertex_bytes.to_float32_array()
	var normal_floats = normal_bytes.to_float32_array()
	var color_floats = color_bytes.to_float32_array()
	
	# === VERTEX WELDING ===
	# Remove duplicate vertices at cube edges using spatial hashing
	var vertex_map = {}  # Spatial hash map
	var unique_vertices = PackedVector3Array()
	var unique_normals = PackedVector3Array()
	var unique_colors = PackedColorArray()
	var unique_uv2s = PackedVector2Array()  # For roughness
	var vertex_remap = PackedInt32Array()   # Maps old index to new
	
	vertex_remap.resize(vertex_count)
	
	# Welding threshold - vertices closer than this are merged
	var weld_threshold = 0.001
	# Grid size for spatial hashing
	var grid_size = 1.0
	
	print("Processing vertices for welding...")
	
	# === PROCESS EACH VERTEX ===
	for i in range(vertex_count):
		# Extract vertex data (vec4 format)
		var idx = i * 4
		
		var vertex = Vector3(
			vertex_floats[idx],
			vertex_floats[idx + 1],
			vertex_floats[idx + 2]
		)
		
		var normal = Vector3(
			normal_floats[idx],
			normal_floats[idx + 1],
			normal_floats[idx + 2]
		).normalized()
		
		var color = Color(
			color_floats[idx],      # R
			color_floats[idx + 1],  # G
			color_floats[idx + 2],  # B
			1.0                     # A
		)
		
		# Roughness stored in alpha channel
		var roughness = color_floats[idx + 3]
		
		# === SPATIAL HASHING ===
		# Hash vertex position to grid cell
		var key_x = int(vertex.x / grid_size)
		var key_y = int(vertex.y / grid_size)
		var key_z = int(vertex.z / grid_size)
		var hash_key = "%d,%d,%d" % [key_x, key_y, key_z]
		
		# === CHECK FOR EXISTING VERTEX ===
		var found_match = false
		var matched_index = -1
		
		# Look for nearby vertices in same grid cell
		if vertex_map.has(hash_key):
			for candidate_idx in vertex_map[hash_key]:
				# Check distance to candidate
				if unique_vertices[candidate_idx].distance_squared_to(vertex) < weld_threshold * weld_threshold:
					found_match = true
					matched_index = candidate_idx
					# Average normals for smooth shading
					unique_normals[candidate_idx] = (unique_normals[candidate_idx] + normal).normalized()
					break
		
		# === ADD OR REMAP VERTEX ===
		if found_match:
			# Use existing vertex
			vertex_remap[i] = matched_index
		else:
			# Add new unique vertex
			var new_index = unique_vertices.size()
			unique_vertices.append(vertex)
			unique_normals.append(normal)
			unique_colors.append(color)
			unique_uv2s.append(Vector2(roughness, 0.0))
			
			# Add to spatial hash
			if not vertex_map.has(hash_key):
				vertex_map[hash_key] = []
			vertex_map[hash_key].append(new_index)
			
			vertex_remap[i] = new_index
	
	print("Welded %d vertices down to %d unique vertices (%.1f%% reduction)" % [
		vertex_count, unique_vertices.size(),
		(1.0 - float(unique_vertices.size()) / float(vertex_count)) * 100.0
	])
	
	# === CALCULATE TEXTURE COORDINATES ===
	# Generate spherical UVs
	var unique_uvs = PackedVector2Array()
	unique_uvs.resize(unique_vertices.size())
	
	for i in range(unique_vertices.size()):
		# Normalize to unit sphere
		var sphere_pos = unique_vertices[i].normalized()
		# Convert to spherical coordinates
		var u = 0.5 + atan2(sphere_pos.z, sphere_pos.x) / (2.0 * PI)
		var v = 0.5 - asin(clamp(sphere_pos.y, -1.0, 1.0)) / PI
		unique_uvs[i] = Vector2(u, v)
	
	# === GENERATE TRIANGLE INDICES ===
	var indices = PackedInt32Array()
	var verts_per_face = (SUBDIVISIONS + 1) * (SUBDIVISIONS + 1)
	
	# For each cube face
	for face in range(6):
		var face_offset = face * verts_per_face
		
		# Generate quad grid
		for y in range(SUBDIVISIONS):
			for x in range(SUBDIVISIONS):
				# Index of bottom-left vertex of quad
				var idx = face_offset + y * (SUBDIVISIONS + 1) + x
				
				# Get remapped indices for quad vertices
				var v0 = vertex_remap[idx]                           # Bottom-left
				var v1 = vertex_remap[idx + SUBDIVISIONS + 1]       # Top-left
				var v2 = vertex_remap[idx + 1]                      # Bottom-right
				var v3 = vertex_remap[idx + SUBDIVISIONS + 2]       # Top-right
				
				# Create two triangles for the quad
				# Triangle 1: v0, v1, v2
				indices.append(v0)
				indices.append(v1)
				indices.append(v2)
				
				# Triangle 2: v2, v1, v3
				indices.append(v2)
				indices.append(v1)
				indices.append(v3)
	
	# === CREATE MESH ARRAYS ===
	var arrays = []
	arrays.resize(Mesh.ARRAY_MAX)
	
	arrays[Mesh.ARRAY_VERTEX] = unique_vertices
	arrays[Mesh.ARRAY_NORMAL] = unique_normals
	arrays[Mesh.ARRAY_COLOR] = unique_colors
	arrays[Mesh.ARRAY_TEX_UV] = unique_uvs
	arrays[Mesh.ARRAY_TEX_UV2] = unique_uv2s  # Roughness in UV2
	arrays[Mesh.ARRAY_INDEX] = indices
	
	# Create ArrayMesh
	var array_mesh = ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	
	# Apply PBR material
	var material = create_pbr_material()
	array_mesh.surface_set_material(0, material)
	
	# Set as our mesh
	self.mesh = array_mesh
	
	print("Created mesh with %d vertices and %d triangles" % [
		unique_vertices.size(), 
		indices.size() / 3
	])
	
	# Add atmosphere effects
	add_atmosphere()
	
	# Clean up GPU resources
	cleanup_gpu_resources()

## Create PBR material for planet surface
func create_pbr_material() -> ShaderMaterial:
	# === CREATE CUSTOM SHADER ===
	var shader = Shader.new()
	shader.code = """
	shader_type spatial;
	render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_schlick_ggx;
	
	// Detail normal map for micro-surface detail
	uniform sampler2D detail_normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
	uniform float detail_normal_scale : hint_range(0.0, 2.0) = 0.5;
	uniform float detail_uv_scale = 100.0;
	
	// Material properties
	uniform float metallic : hint_range(0.0, 1.0) = 0.0;
	uniform float specular : hint_range(0.0, 1.0) = 0.5;
	
	// Varyings for fragment shader
	varying vec3 world_pos;
	varying float vertex_roughness;
	
	void vertex() {
		// Pass world position to fragment shader
		world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		// Extract roughness from UV2.x (set in mesh generation)
		vertex_roughness = UV2.x;
	}
	
	void fragment() {
		// Use vertex color as albedo
		ALBEDO = COLOR.rgb;
		// Use vertex roughness
		ROUGHNESS = vertex_roughness;
		
		// === DETAIL NORMAL MAPPING ===
		// Sample detail normal map using world position
		vec3 detail_norm = texture(detail_normal_tex, world_pos.xz * detail_uv_scale).xyz;
		detail_norm = detail_norm * 2.0 - 1.0;  // Unpack from [0,1] to [-1,1]
		detail_norm *= detail_normal_scale;
		
		// Apply detail normal
		NORMAL_MAP = normalize(vec3(detail_norm.xy, 1.0));
		NORMAL_MAP_DEPTH = detail_normal_scale;
		
		// Set material properties
		METALLIC = metallic;
		SPECULAR = specular;
		
		// === SPECIAL MATERIAL EFFECTS ===
		// Calculate altitude above base radius
		float altitude = length(world_pos) - 1000.0;
		
		// Snow/ice: high altitude or white color
		if (altitude > 0.05 || COLOR.r > 0.85) {
			ROUGHNESS *= 0.5;    // Smoother
			SPECULAR = 0.8;      // More reflective
		}
		
		// Water: below sea level and blue-ish
		if (altitude < 0.0 && COLOR.b > COLOR.r * 1.5) {
			ROUGHNESS = 0.1;     // Very smooth
			SPECULAR = 0.7;      // Reflective
			METALLIC = 0.0;      // Non-metallic
		}
	}
	"""
	
	# === CREATE MATERIAL ===
	var material = ShaderMaterial.new()
	material.shader = shader
	
	# === GENERATE DETAIL NORMAL TEXTURE ===
	# Create procedural normal map for surface detail
	var image = Image.create(256, 256, false, Image.FORMAT_RGB8)
	for y in range(256):
		for x in range(256):
			# Random normal direction
			var nx = randf() * 2.0 - 1.0
			var ny = randf() * 2.0 - 1.0
			# Calculate Z to ensure unit length
			var nz = sqrt(max(0.0, 1.0 - nx*nx - ny*ny))
			# Pack to color (0.5 offset for storage)
			image.set_pixel(x, y, Color(nx * 0.5 + 0.5, ny * 0.5 + 0.5, nz))
	
	var detail_texture = ImageTexture.create_from_image(image)
	
	# === SET SHADER PARAMETERS ===
	material.set_shader_parameter("detail_normal_tex", detail_texture)
	material.set_shader_parameter("detail_normal_scale", 0.3)
	material.set_shader_parameter("detail_uv_scale", 200.0)
	material.set_shader_parameter("metallic", 0.0)
	material.set_shader_parameter("specular", 0.5)
	
	return material

## Add atmospheric glow effects
func add_atmosphere():
	# Create two layers for depth
	for i in range(2):
		var atmosphere = MeshInstance3D.new()
		atmosphere.name = "Atmosphere_Layer_" + str(i)
		
		# === CREATE ATMOSPHERE SPHERE ===
		# Slightly larger than planet
		var scale_factor = 1.002 + i * 0.008  # Each layer is progressively larger
		var sphere_mesh = SphereMesh.new()
		sphere_mesh.radius = BASE_RADIUS * scale_factor
		sphere_mesh.height = sphere_mesh.radius * 2.0
		sphere_mesh.radial_segments = 64
		sphere_mesh.rings = 32
		
		atmosphere.mesh = sphere_mesh
		atmosphere.material_override = create_atmosphere_material(i)
		# Don't cast shadows
		atmosphere.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		
		add_child(atmosphere)

## Create atmosphere glow material
func create_atmosphere_material(layer: int) -> ShaderMaterial:
	var material = ShaderMaterial.new()
	var shader = Shader.new()
	
	shader.code = """
	shader_type spatial;
	render_mode blend_add, depth_draw_opaque, cull_front, unshaded;
	
	// Atmosphere parameters
	uniform vec3 atmosphere_color = vec3(0.15, 0.35, 0.8);
	uniform float intensity = 1.0;
	uniform float layer = 0.0;
	
	varying vec3 world_pos;
	varying vec3 world_normal;
	
	void vertex() {
		// Calculate world space position and normal
		world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
		world_normal = (MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz;
	}
	
	void fragment() {
		// View direction from camera to fragment
		vec3 view_dir = normalize(CAMERA_POSITION_WORLD - world_pos);
		vec3 normal = normalize(world_normal);
		
		// Calculate rim lighting effect
		float ndotv = dot(normal, view_dir);
		float rim = 1.0 - abs(ndotv);  // Stronger at edges
		
		// Power function for falloff, adjusted by layer
		float atmosphere = pow(rim, 2.0 + layer * 0.5) * intensity;
		
		ALBEDO = atmosphere_color;
		// Reduce opacity for outer layers
		ALPHA = atmosphere * (1.0 - layer * 0.2);
	}
	"""
	
	material.shader = shader
	material.set_shader_parameter("layer", float(layer))
	material.set_shader_parameter("intensity", 0.8 - layer * 0.2)
	
	return material

## Setup scene rendering environment
func setup_scene_environment():
	# === CREATE ENVIRONMENT ===
	environment = Environment.new()
	
	# === BACKGROUND SETTINGS ===
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.02, 0.02, 0.03)  # Dark space
	
	# === AMBIENT LIGHTING ===
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.1, 0.15, 0.2)  # Slight blue tint
	environment.ambient_light_energy = 0.3
	
	# === TONE MAPPING ===
	environment.tonemap_mode = Environment.TONE_MAPPER_ACES
	environment.tonemap_exposure = 1.2
	environment.tonemap_white = 1.0
	
	# === POST-PROCESSING ===
	environment.ssao_enabled = false  # Performance
	environment.glow_enabled = true
	environment.glow_intensity = 0.8
	environment.glow_strength = 1.2
	
	# Apply to camera if available
	if get_viewport().get_camera_3d():
		get_viewport().get_camera_3d().environment = environment

## Clean up GPU resources
func cleanup_gpu_resources():
	if rd:
		# List of buffers to free
		var buffers = [vertex_buffer, normal_buffer, color_buffer, uniform_buffer]
		
		# Free each buffer if valid
		for buffer in buffers:
			if buffer and buffer.is_valid():
				rd.free_rid(buffer)

## Clean up when node is removed
func _exit_tree():
	# Clean up all GPU resources
	cleanup_gpu_resources()
	
	# Free compute resources
	if compute_shader and compute_shader.is_valid() and rd:
		rd.free_rid(compute_shader)
	if pipeline and pipeline.is_valid() and rd:
		rd.free_rid(pipeline)
