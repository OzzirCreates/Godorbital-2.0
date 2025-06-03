@tool
extends MeshInstance3D
## SphereWater - FFT Ocean Water System
## 
## PURPOSE:
## --------
## Implements realistic ocean water using FFT (Fast Fourier Transform) wave simulation.
## Supports both flat planes and spherical oceans for planets.
## Features tidal effects, shore interaction, and multi-cascade wave detail.
##
## ALGORITHM:
## ----------
## 1. Generate wave spectrum based on wind/ocean parameters
## 2. Animate spectrum over time using dispersion relation
## 3. Use FFT to convert to displacement/normal maps
## 4. Apply maps in shader for vertex displacement and shading
## 5. Optional: Add tidal forces and shore foam effects

# === RESOURCE PRELOADS ===
# Water material and shader
const WATER_MAT := preload('res://assets/water/mat_water.tres')
# Spray particle material
const SPRAY_MAT := preload('res://assets/water/mat_spray.tres')
# High-quality sphere mesh
const WATER_MESH_HIGH := preload('res://assets/water/clipmap_sphere_high.obj')
# Low-quality sphere mesh for performance
const WATER_MESH_LOW := preload('res://assets/water/clipmap_sphere_low.obj')

# === ENUMERATIONS ===
# Mesh quality settings
enum MeshQuality { LOW, MEDIUM, HIGH }
# Mesh type (flat or spherical)
enum MeshType { PLANE, SPHERE }

# === PLANET INTEGRATION ===
# Reference to planet node for shore detection
@export var planet_node: Node3D  # Drag your planet mesh here in editor
# Cache for planet height data
var planet_height_data := {}

# === OCEAN PARAMETERS ===
@export_group('Ocean Parameters')
# Deep water color (darker)
@export_color_no_alpha var water_color : Color = Color(0.1, 0.15, 0.18) :
	set(value): 
		water_color = value
		# Update shader when changed in editor or runtime
		if Engine.is_editor_hint() or is_inside_tree():
			_update_shader_params()

# Foam/whitecap color (lighter)
@export_color_no_alpha var foam_color : Color = Color(0.73, 0.67, 0.62) :
	set(value): 
		foam_color = value
		if Engine.is_editor_hint() or is_inside_tree():
			_update_shader_params()

# Mesh detail level
@export var mesh_quality := MeshQuality.LOW :
	set(value):
		mesh_quality = value
		# Switch between mesh resolutions
		mesh = WATER_MESH_HIGH if mesh_quality == MeshQuality.HIGH else WATER_MESH_LOW

# Flat plane or sphere
@export var mesh_type := MeshType.SPHERE :
	set(value):
		mesh_type = value
		if Engine.is_editor_hint() or is_inside_tree():
			_update_mesh()

# Sphere radius (for spherical oceans)
@export var sphere_radius := 1000.0 :
	set(value):
		sphere_radius = value
		if mesh_type == MeshType.SPHERE and (Engine.is_editor_hint() or is_inside_tree()):
			_update_mesh()
			_update_shader_params()

# Sphere subdivision level
@export var sphere_subdivisions := 4 :
	set(value):
		sphere_subdivisions = value
		if mesh_type == MeshType.SPHERE and (Engine.is_editor_hint() or is_inside_tree()):
			_update_mesh()

# Control whether to use default wave parameters
@export var parameters_initialized := true  # Set to false to use default parameters

# === WAVE PARAMETERS ===
@export_group('Wave Parameters')
## Array of wave cascade parameters
## Each cascade represents different wave frequencies/scales
@export var parameters : Array[WaveCascadeParameters] :
	set(value):
		var new_size := len(value)
		# Ensure all parameters are valid
		for i in range(new_size):
			if not value[i]: 
				value[i] = WaveCascadeParameters.new()
			# Reconnect scale change signal
			if value[i].is_connected("scale_changed", _update_scales_uniform):
				value[i].disconnect("scale_changed", _update_scales_uniform)
			value[i].connect("scale_changed", _update_scales_uniform)
			# Set unique random seed for each cascade
			value[i].spectrum_seed = Vector2i(
				rng.randi_range(-10000, 10000), 
				rng.randi_range(-10000, 10000)
			)
			# Offset time for variety
			value[i].time = 120.0 + PI*i
		parameters = value
		if Engine.is_editor_hint() or is_inside_tree():
			_setup_wave_generator()
			_update_scales_uniform()

# === PERFORMANCE PARAMETERS ===
@export_group('Performance Parameters')
# Resolution of displacement/normal maps
@export_enum('128x128:128', '256x256:256', '512x512:512', '1024x1024:1024') var map_size := 1024 :
	set(value):
		map_size = value
		if Engine.is_editor_hint() or is_inside_tree():
			_setup_wave_generator()

## Wave simulation update frequency
## Lower values improve performance but reduce animation smoothness
@export_range(0, 60) var updates_per_second := 10.0 :
	set(value):
		# Adjust next update time to maintain smooth transitions
		next_update_time = next_update_time - (1.0/(updates_per_second + 1e-10) - 1.0/(value + 1e-10))
		updates_per_second = value

# === TIDAL PARAMETERS ===
@export_group('Tidal Parameters')
# Reference to moon/celestial body
@export var moon: CelestialBody
# Tidal effect strength multiplier
@export var tidal_strength := 1.0
# Enable/disable tidal calculations
@export var enable_tides := true
# Show debug visualization of tidal forces
@export var debug_tides := false

# === SHORE INTERACTION ===
@export_group('Shore Interaction')
# Terrain node for shore detection
@export var terrain_node: Node3D
# Water level relative to terrain
@export var sea_level := 0.0
# Distance from shore where foam appears
@export var shore_foam_distance := 50.0
# Foam intensity at shoreline
@export var shore_foam_intensity := 0.8
# Depth where waves start breaking
@export var wave_break_depth := 10.0
# Scale factor for terrain heights
@export var terrain_height_scale := 100.0
# Editor button to update shore maps
@export var update_shore_maps := false :
	set(value):
		if value:
			generate_shore_maps()
		update_shore_maps = false

# === WAVE GENERATOR ===
# Handles FFT computation
var wave_generator : WaveGenerator :
	set(value):
		# Clean up old generator
		if wave_generator and is_instance_valid(wave_generator): 
			wave_generator.queue_free()
		wave_generator = value
		# Add as child for processing
		if wave_generator:
			add_child(wave_generator)

# === RUNTIME VARIABLES ===
# Random number generator
var rng = RandomNumberGenerator.new()
# Total elapsed time
var time := 0.0
# Time for next wave update
var next_update_time := 0.0

# Texture arrays for GPU data
var displacement_maps := Texture2DArrayRD.new()
var normal_maps := Texture2DArrayRD.new()

# State tracking
var material_applied := false
var initialized := false
var shader_params_registered := false

# === PLANET-SPECIFIC VARIABLES ===
# Mesh instances for each cube face
var face_meshes := []
# Original vertex positions before displacement
var original_vertices := []
# Spherical water shader
var planet_shader := preload("res://assets/shaders/spatial/planet_water.gdshader")

# === TIDAL VARIABLES ===
var tidal_forces_updated := false
var planet_center := Vector3.ZERO
var debug_arrows := []

# === SHORE DETECTION ===
var terrain_heightmap: Texture2D
var shore_distance_map: ImageTexture
var shore_compute_context: RenderingContext
var shore_distance_texture: RID

## Detect terrain height at world position
## Used for shore foam calculations
func detect_planet_height(world_pos: Vector3) -> float:
	if not planet_node or not planet_node.mesh:
		return -100.0
		
	# Project position to sphere surface
	var to_planet = world_pos - planet_node.global_position
	var sphere_pos = to_planet.normalized()
	
	# Get mesh vertex data
	var arrays = planet_node.mesh.surface_get_arrays(0)
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	
	var closest_height = 0.0
	var min_dist = INF
	
	# Find closest vertex (simple approach)
	for vertex in vertices:
		var vert_dir = vertex.normalized()
		var dist = vert_dir.distance_to(sphere_pos)
		if dist < min_dist:
			min_dist = dist
			closest_height = vertex.length()
	
	return closest_height

func _init() -> void:
	# Initialize with fixed seed for consistency
	rng.set_seed(1234)
	# Don't register shader parameters here - wait for _ready

## Register global shader parameters
## These are shared across all water shaders
func _register_shader_parameters() -> void:
	# Only register once
	if shader_params_registered:
		return
		
	# === UPDATE GLOBAL SHADER PARAMETERS ===
	# Convert colors to linear space for correct rendering
	RenderingServer.global_shader_parameter_set("water_color", water_color.srgb_to_linear())
	RenderingServer.global_shader_parameter_set("foam_color", foam_color.srgb_to_linear())
	RenderingServer.global_shader_parameter_set("num_cascades", parameters.size() if parameters else 0)
	RenderingServer.global_shader_parameter_set("sphere_radius", sphere_radius)
	
	# Set texture arrays if valid
	if displacement_maps.texture_rd_rid.is_valid():
		RenderingServer.global_shader_parameter_set("displacements", displacement_maps)
		
	if normal_maps.texture_rd_rid.is_valid():
		RenderingServer.global_shader_parameter_set("normals", normal_maps)
	
	shader_params_registered = true
	print("Global shader parameters updated")

## Update shader parameters
## Called when properties change
func _update_shader_params() -> void:
	if not shader_params_registered:
		_register_shader_parameters()
		return
		
	# Update all global parameters
	RenderingServer.global_shader_parameter_set("water_color", water_color.srgb_to_linear())
	RenderingServer.global_shader_parameter_set("foam_color", foam_color.srgb_to_linear())
	RenderingServer.global_shader_parameter_set("num_cascades", parameters.size() if parameters else 0)
	RenderingServer.global_shader_parameter_set("sphere_radius", sphere_radius)
	
	if displacement_maps.texture_rd_rid.is_valid():
		RenderingServer.global_shader_parameter_set("displacements", displacement_maps)
		
	if normal_maps.texture_rd_rid.is_valid():
		RenderingServer.global_shader_parameter_set("normals", normal_maps)

func _ready() -> void:
	print("Ocean system initializing...")
	print("Mesh type: ", mesh_type)
	
	# Register shader parameters first
	_register_shader_parameters()
	
	# Update shader parameters
	_update_shader_params()
	
	# Create the mesh
	_update_mesh()
	
	# === APPLY WATER MATERIAL ===
	print("Applying water material...")
	if WATER_MAT:
		set_surface_override_material(0, WATER_MAT)
		material_applied = true
	else:
		push_error("Water material not found")
	
	# Setup subsystems
	_setup_wave_generator()
	_setup_tidal_connection()
	_setup_shore_detection()
	
	# Initialize position
	planet_center = global_position
	
	# Enable processing
	set_process(true)
	
	# Force initialization after a small delay
	call_deferred("_force_initial_setup")

## Setup shore detection system
func _setup_shore_detection():
	if not terrain_node:
		print("No terrain node assigned for shore detection")
		return
		
	# === GET HEIGHTMAP FROM TERRAIN ===
	# Try different methods to get heightmap
	if terrain_node.has_method("get_heightmap_texture"):
		var heightmap = terrain_node.call("get_heightmap_texture")
		if heightmap:
			terrain_heightmap = heightmap
		else:
			print("Warning: get_heightmap_texture returned null")
			return
	elif terrain_node.has_method("get_heightmap"):
		var heightmap_image = terrain_node.call("get_heightmap")
		if heightmap_image and heightmap_image is Image:
			terrain_heightmap = ImageTexture.create_from_image(heightmap_image)
		else:
			print("Warning: get_heightmap returned invalid data")
			return
	else:
		print("Warning: Terrain node doesn't have heightmap methods!")
		return
	
	# Generate shore maps if we have valid data
	if terrain_heightmap:
		generate_shore_maps()
	
	# Connect to terrain modification signals
	if terrain_node.has_signal("terrain_modified") and not terrain_node.is_connected("terrain_modified", _on_terrain_modified):
		terrain_node.connect("terrain_modified", _on_terrain_modified)

## Generate shore distance maps for foam effects
func generate_shore_maps():
	if not terrain_heightmap:
		print("Warning: No terrain heightmap available for shore map generation")
		return
		
	print("Generating shore distance maps...")
	
	# Initialize compute context if needed
	if not shore_compute_context:
		shore_compute_context = RenderingContext.create()
	
	# === GET HEIGHTMAP AS IMAGE ===
	var heightmap_image: Image
	if terrain_node and terrain_node.has_method("get_heightmap"):
		var img = terrain_node.call("get_heightmap")
		if img and img is Image:
			heightmap_image = img
		else:
			print("Warning: get_heightmap did not return a valid Image")
			return
	else:
		var img = terrain_heightmap.get_image()
		if img:
			heightmap_image = img
		else:
			print("Warning: Could not get image from terrain_heightmap texture")
			return
	
	if not heightmap_image:
		print("Warning: Could not get heightmap image!")
		return
	
	var heightmap_size = heightmap_image.get_size()
	
	# === CREATE SHORE DISTANCE MAP ===
	# Using CPU for simplicity (could be optimized with compute shader)
	var shore_image = Image.create(heightmap_size.x, heightmap_size.y, false, Image.FORMAT_RF)
	
	# For each pixel, calculate distance to nearest shore
	for y in range(heightmap_size.y):
		for x in range(heightmap_size.x):
			# Get terrain height at this point
			var height = heightmap_image.get_pixel(x, y).r * terrain_height_scale
			var underwater = height < sea_level
			
			var min_distance = shore_foam_distance
			
			# === SEARCH FOR NEAREST SHORE ===
			# Check surrounding pixels within search radius
			var search_radius = int(shore_foam_distance / 5.0)
			for dy in range(-search_radius, search_radius + 1):
				for dx in range(-search_radius, search_radius + 1):
					var sx = x + dx
					var sy = y + dy
					
					# Check bounds
					if sx >= 0 and sx < heightmap_size.x and sy >= 0 and sy < heightmap_size.y:
						var sample_height = heightmap_image.get_pixel(sx, sy).r * terrain_height_scale
						var sample_underwater = sample_height < sea_level
						
						# Shore is where underwater meets land
						if underwater != sample_underwater:
							var dist = Vector2(dx, dy).length()
							min_distance = min(min_distance, dist)
			
			# Normalize distance for storage
			var normalized_distance = min_distance / shore_foam_distance
			shore_image.set_pixel(x, y, Color(normalized_distance, 0, 0, 1))
	
	# Create texture from image
	shore_distance_map = ImageTexture.create_from_image(shore_image)
	
	# Update material with shore data
	_update_shore_parameters()
	
	print("Shore maps generated successfully!")
	
## Update shore-related shader parameters
func _update_shore_parameters():
	var material = get_surface_override_material(0)
	if material and terrain_heightmap:
		# Set all shore-related parameters
		material.set_shader_parameter("terrain_heightmap", terrain_heightmap)
		material.set_shader_parameter("shore_distance_map", shore_distance_map)
		material.set_shader_parameter("terrain_height_scale", terrain_height_scale)
		material.set_shader_parameter("sea_level", sea_level)
		material.set_shader_parameter("shore_foam_distance", shore_foam_distance)
		material.set_shader_parameter("shore_foam_intensity", shore_foam_intensity)
		material.set_shader_parameter("wave_break_depth", wave_break_depth)

## Handle terrain modification
func _on_terrain_modified(_modified_region: Rect2i):
	# Regenerate shore maps when terrain changes
	generate_shore_maps()

## Main water update function
## Updates wave simulation and shader parameters
func _update_water(delta : float) -> void:
	# === INITIALIZATION DELAY ===
	# Don't start updates immediately - give time for initialization
	if time < 0.5 and not initialized:
		return
		
	# === VALIDATE WAVE GENERATOR ===
	if wave_generator == null or not is_instance_valid(wave_generator) or not displacement_maps.texture_rd_rid.is_valid():
		print("Wave generator invalid, attempting to reinitialize...")
		_setup_wave_generator()

		if wave_generator == null:
			push_error("ERROR: Failed to reinitialize wave_generator")
			return
	
	# Update wave scale uniforms
	_update_scales_uniform()
	
	# === UPDATE SPHERE PARAMETERS ===
	if mesh_type == MeshType.SPHERE:
		RenderingServer.global_shader_parameter_set("sphere_radius", sphere_radius)
		
		# Update material parameter directly as well
		var sphere_material = get_surface_override_material(0)
		if sphere_material:
			sphere_material.set_shader_parameter("radius", sphere_radius)
	
	# Update shore parameters if available
	if terrain_node and shore_distance_map:
		_update_shore_parameters()
	
	# === UPDATE WAVE SIMULATION ===
	# Pass user parameters to wave generator
	wave_generator.update(delta, parameters)
	
	# === ENSURE SHADER PARAMETERS ARE CURRENT ===
	RenderingServer.global_shader_parameter_set("displacements", displacement_maps)
	RenderingServer.global_shader_parameter_set("normals", normal_maps)
	
	# === FORCE MATERIAL TO STAY APPLIED ===
	# Sometimes materials get cleared, so we check and reapply
	var water_material = get_surface_override_material(0)
	if not water_material:
		if WATER_MAT:
			water_material = WATER_MAT.duplicate()
			# Use appropriate shader for mesh type
			water_material.shader = planet_shader if mesh_type == MeshType.SPHERE else WATER_MAT.shader
			set_surface_override_material(0, water_material)
		else:
			push_error("Water material not found")
			return
	
	# Update texture references directly in material
	water_material.set_shader_parameter("displacements", displacement_maps)
	water_material.set_shader_parameter("normals", normal_maps)
	
	material_applied = true

## Force initial setup after scene is ready
func _force_initial_setup() -> void:
	# Wait 2 frames to ensure everything is initialized
	await get_tree().process_frame
	await get_tree().process_frame
	
	print("Forcing initial setup...")
	
	# Force update all shader parameters
	_update_shader_params()
	
	# === ENSURE TEXTURE ARRAYS ARE ASSIGNED ===
	if displacement_maps.texture_rd_rid.is_valid() and normal_maps.texture_rd_rid.is_valid():
		RenderingServer.global_shader_parameter_set("displacements", displacement_maps)
		RenderingServer.global_shader_parameter_set("normals", normal_maps)
		print("Texture arrays assigned globally")
	else:
		print("Warning: Texture arrays not valid during initial setup")
		# Try to recreate them
		_setup_wave_generator()
	
	# Force material updates
	_update_material_for_mesh_type()
	_update_scales_uniform()
	
	# Update tidal forces if moon is available
	if moon and enable_tides:
		_update_tidal_forces()
	
	# Update shore parameters
	if terrain_node:
		_update_shore_parameters()
	
	# Force immediate wave update with small delta
	_update_water(0.01)
	
	initialized = true
	print("Initial setup complete")

## Main process loop
func _process(delta: float) -> void:
	# === DEBUG OUTPUT ===
	# Print debug info every 5 seconds in debug builds
	if OS.is_debug_build() and Engine.get_frames_drawn() % 300 == 0:
		print("======== WATER DEBUG INFO ========")
		print("Mesh type: ", mesh_type)
		print("Sphere radius: ", sphere_radius)
		print("Material applied: ", material_applied)
		if get_surface_override_material(0):
			print("Shader is planet shader: ", get_surface_override_material(0).shader == planet_shader)
			print("is_sphere parameter: ", get_surface_override_material(0).get_shader_parameter("is_sphere"))
		print("num_cascades: ", parameters.size())
		if parameters.size() > 0:
			print("Displacement scale: ", parameters[0].displacement_scale)
			print("Tile length: ", parameters[0].tile_length)
		print("Displacement map RID valid: ", displacement_maps.texture_rd_rid.is_valid())
		print("Normal map RID valid: ", normal_maps.texture_rd_rid.is_valid())
		print("Wave generator active: ", is_instance_valid(wave_generator))
		print("Initialized: ", initialized)
		print("Moon connected: ", is_instance_valid(moon))
		print("Tides enabled: ", enable_tides)
		print("Terrain connected: ", is_instance_valid(terrain_node))
		print("Shore maps generated: ", shore_distance_map != null)
		print("==================================")
	
	# === CHECK MATERIAL ===
	# Ensure material stays applied
	if not material_applied or not get_surface_override_material(0):
		print("Reapplying water material")
		if WATER_MAT:
			set_surface_override_material(0, WATER_MAT)
			material_applied = true
			_update_material_for_mesh_type()
		else:
			push_error("Water material not found for reapplication")
	
	# === PERIODIC TEXTURE REFRESH ===
	# Ensure textures stay connected to shader (every second)
	if Engine.get_frames_drawn() % 60 == 0:  # At 60 FPS
		if displacement_maps.texture_rd_rid.is_valid() and normal_maps.texture_rd_rid.is_valid():
			# Update global shader parameters
			RenderingServer.global_shader_parameter_set("displacements", displacement_maps)
			RenderingServer.global_shader_parameter_set("normals", normal_maps)
			
			# Update material parameters as well
			var material = get_surface_override_material(0)
			if material:
				material.set_shader_parameter("displacements", displacement_maps)
				material.set_shader_parameter("normals", normal_maps)
				material.set_shader_parameter("num_cascades", parameters.size())
	
	# === UPDATE TIDAL FORCES ===
	if enable_tides and moon and not tidal_forces_updated:
		_update_tidal_forces()
	
	# === UPDATE WAVES ===
	# Update at specified frequency
	if updates_per_second == 0 or time >= next_update_time:
		var target_update_delta := 1.0 / (updates_per_second + 1e-10)
		var update_delta := delta if updates_per_second == 0 else target_update_delta + (time - next_update_time)
		next_update_time = time + target_update_delta
		_update_water(update_delta)
		
	time += delta

## Update mesh based on type
func _update_mesh() -> void:
	print("Updating mesh with type: ", mesh_type)
	
	if mesh_type == MeshType.PLANE:
		_create_plane_mesh()
	else:
		_create_sphere_mesh()
	
	# Store original vertices for wave displacement
	_store_original_vertices()
	
	# Update the material to use appropriate shader
	_update_material_for_mesh_type()

## Create flat plane mesh
func _create_plane_mesh() -> void:
	# Determine detail level
	var detail_level := 100
	if mesh_quality == MeshQuality.LOW:
		detail_level = 50
	elif mesh_quality == MeshQuality.HIGH:
		detail_level = 200
	
	# Create plane mesh
	var plane_mesh := PlaneMesh.new()
	plane_mesh.size = Vector2(2000, 2000)  # Large plane
	plane_mesh.subdivide_width = detail_level
	plane_mesh.subdivide_depth = detail_level
	
	mesh = plane_mesh
	print("Created plane mesh with detail: ", detail_level)

## Create spherical mesh
func _create_sphere_mesh() -> void:
	# Determine detail level based on quality
	var detail_level := sphere_subdivisions
	if mesh_quality == MeshQuality.LOW:
		detail_level = maxi(2, sphere_subdivisions - 1)
	elif mesh_quality == MeshQuality.HIGH:
		detail_level = sphere_subdivisions + 1
	
	# Create sphere mesh
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = sphere_radius
	sphere_mesh.height = sphere_radius * 2
	sphere_mesh.radial_segments = detail_level * 256
	sphere_mesh.rings = detail_level * 128
	
	mesh = sphere_mesh
	
	print("Created sphere mesh with radius: ", sphere_radius, " and detail: ", detail_level)
	print("  Radial segments: ", detail_level * 256)
	print("  Rings: ", detail_level * 128)

## Store original vertex positions
func _store_original_vertices() -> void:
	if not mesh:
		return
	
	# Get mesh vertex data
	var mesh_data := mesh.surface_get_arrays(0)
	if mesh_data.size() > 0:
		original_vertices = mesh_data[Mesh.ARRAY_VERTEX]
		print("Stored ", original_vertices.size(), " original vertices")

## Update material for current mesh type
func _update_material_for_mesh_type() -> void:
	if not WATER_MAT:
		push_error("Water material not found")
		return
		
	# Duplicate material to avoid modifying original
	var shader_material = WATER_MAT.duplicate()
	
	print("Updating material for mesh type: ", mesh_type)
	
	if mesh_type == MeshType.SPHERE:
		# === SPHERICAL WATER SETUP ===
		if shader_material.shader != planet_shader:
			print("Setting planet shader")
			shader_material.shader = planet_shader
			
		# Set sphere-specific parameters
		shader_material.set_shader_parameter("radius", sphere_radius)
		shader_material.set_shader_parameter("is_sphere", true)
		
		# Ensure texture arrays are assigned
		if displacement_maps.texture_rd_rid.is_valid() and normal_maps.texture_rd_rid.is_valid():
			shader_material.set_shader_parameter("displacements", displacement_maps)
			shader_material.set_shader_parameter("normals", normal_maps)
		
		# Initialize tidal parameters
		shader_material.set_shader_parameter("enable_tides", enable_tides)
		shader_material.set_shader_parameter("tidal_strength", tidal_strength)
		shader_material.set_shader_parameter("planet_radius", sphere_radius)
		
		# Set moon parameters if available
		if moon:
			shader_material.set_shader_parameter("moon_position", moon.global_position)
			shader_material.set_shader_parameter("planet_position", global_position)
			shader_material.set_shader_parameter("moon_mass", moon.mass)
			
		print("Sphere parameters set - radius:", sphere_radius)
	else:
		# === PLANE WATER SETUP ===
		shader_material.set_shader_parameter("is_sphere", false)
		shader_material.set_shader_parameter("enable_tides", false)
		print("Plane parameters set")
	
	# Apply the material
	set_surface_override_material(0, shader_material)
	material_applied = true
	print("Material updated")

## Setup wave generator for FFT simulation
func _setup_wave_generator() -> void:
	print("Setting up wave generator...")
	
	# Need parameters to continue
	if parameters.size() <= 0: 
		print("No parameters, cannot set up wave generator")
		return
	
	# Mark all cascades for spectrum generation
	for param in parameters:
		param.should_generate_spectrum = true

	# Create new wave generator
	wave_generator = WaveGenerator.new()
	wave_generator.map_size = map_size
	
	# === CHECK RENDERING DEVICE ===
	var rd = RenderingServer.get_rendering_device()
	if not rd:
		push_error("ERROR: No RenderingDevice available. Make sure you're using the Vulkan renderer!")
		return
	
	print("RenderingDevice found: ", rd.get_device_name())
	
	# Initialize GPU resources
	wave_generator.init_gpu(maxi(2, parameters.size()))
	
	# === CLEAN UP OLD TEXTURE RIDS ===
	if displacement_maps.texture_rd_rid.is_valid():
		displacement_maps.texture_rd_rid = RID()
		
	if normal_maps.texture_rd_rid.is_valid():
		normal_maps.texture_rd_rid = RID()
	
	# === ASSIGN NEW TEXTURE RIDS ===
	if wave_generator.descriptors.has(&'displacement_map') and wave_generator.descriptors[&'displacement_map'].rid.is_valid():
		displacement_maps.texture_rd_rid = wave_generator.descriptors[&'displacement_map'].rid
		
	if wave_generator.descriptors.has(&'normal_map') and wave_generator.descriptors[&'normal_map'].rid.is_valid():
		normal_maps.texture_rd_rid = wave_generator.descriptors[&'normal_map'].rid
	
	print("Displacement map RID valid after setup: ", displacement_maps.texture_rd_rid.is_valid())
	print("Normal map RID valid after setup: ", normal_maps.texture_rd_rid.is_valid())

	# Update shader parameters
	_update_shader_params()
	
	# Update material parameters directly
	var shader_material = get_surface_override_material(0)
	if shader_material:
		shader_material.set_shader_parameter("displacements", displacement_maps)
		shader_material.set_shader_parameter("normals", normal_maps)
		shader_material.set_shader_parameter("num_cascades", parameters.size())
	
	print("Wave generator setup complete")

## Setup tidal force connections
func _setup_tidal_connection():
	if moon and enable_tides:
		# Connect to moon's orbit update signal
		if not moon.is_connected("orbit_updated", _update_tidal_forces):
			moon.connect("orbit_updated", _update_tidal_forces)
	elif moon and moon.is_connected("orbit_updated", _update_tidal_forces):
		# Disconnect if tides disabled
		moon.disconnect("orbit_updated", _update_tidal_forces)
		
	# Create debug visualization if needed
	if debug_tides:
		_setup_debug_visualization()

## Update tidal force calculations
func _update_tidal_forces():
	if not moon or not enable_tides:
		return
		
	# Update center point
	planet_center = global_position
		
	# Calculate planet's acceleration due to moon
	var planet_acceleration = moon.get_gravitational_pull(planet_center)
	
	# === SET SHADER PARAMETERS ===
	var material = get_surface_override_material(0)
	if material:
		material.set_shader_parameter("moon_position", moon.global_position)
		material.set_shader_parameter("planet_position", planet_center)
		material.set_shader_parameter("planet_radius", sphere_radius)
		material.set_shader_parameter("planet_acceleration", planet_acceleration)
		material.set_shader_parameter("moon_mass", moon.mass)
		material.set_shader_parameter("tidal_strength", tidal_strength)
		material.set_shader_parameter("enable_tides", enable_tides)
	
	# Update debug visualization
	if debug_tides:
		_update_debug_vectors()
	
	tidal_forces_updated = true
	
	## Setup debug visualization for tidal forces
func _setup_debug_visualization():
	# Clear any existing arrows
	for arrow in debug_arrows:
		if is_instance_valid(arrow):
			arrow.queue_free()
	debug_arrows.clear()
	
	# === CREATE DEBUG ARROWS ===
	# Arrows show tidal force magnitude and direction
	var num_arrows = 24  # Number of arrows around sphere
	for i in range(num_arrows):
		var arrow = MeshInstance3D.new()
		
		# Create cone mesh for arrow
		var cylinder_mesh = CylinderMesh.new()
		cylinder_mesh.top_radius = 0.0      # Point at top
		cylinder_mesh.bottom_radius = 10.0  # Wide base
		cylinder_mesh.height = 100.0        # Length
		
		# Semi-transparent red material
		var arrow_material = StandardMaterial3D.new()
		arrow_material.albedo_color = Color(1, 0, 0, 0.5)
		arrow_material.flags_transparent = true
		
		arrow.mesh = cylinder_mesh
		arrow.material_override = arrow_material
		add_child(arrow)
		debug_arrows.append(arrow)

## Update debug visualization vectors
func _update_debug_vectors():
	if debug_arrows.size() == 0:
		return
		
	var num_arrows = debug_arrows.size()
	
	# === UPDATE EACH ARROW ===
	for i in range(num_arrows):
		# Calculate position around sphere
		var angle = TAU * i / float(num_arrows)
		var direction = Vector3(cos(angle), 0, sin(angle))
		var test_point = planet_center + direction * sphere_radius
		
		# Get tidal acceleration at this point
		var tidal_acceleration = Vector3.ZERO
		if moon:
			# Calculate differential gravity (tidal force)
			tidal_acceleration = moon.get_relative_acceleration(test_point, planet_center)
			# Scale for visualization
			tidal_acceleration *= tidal_strength * 1000.0
		
		# Update arrow transform
		var arrow = debug_arrows[i]
		arrow.global_position = test_point
		# Point arrow in direction of tidal force
		arrow.look_at(test_point + tidal_acceleration.normalized(), Vector3.UP)
		# Scale arrow length based on force magnitude
		arrow.scale = Vector3(1, tidal_acceleration.length() * 0.01, 1)

## Update wave scale uniforms for shader
func _update_scales_uniform() -> void:
	# Prepare array for all cascade scales
	var map_scales : PackedVector4Array
	map_scales.resize(len(parameters))

	# === PACK SCALE DATA ===
	for i in len(parameters):
		var params := parameters[i]

		# Calculate UV scale from tile length
		var uv_scale := Vector2.ONE / params.tile_length
		
		# Pack all scales into vec4
		# x,y = UV scale for texture sampling
		# z = displacement scale (height multiplier)
		# w = normal scale (bumpiness multiplier)
		map_scales[i] = Vector4(
			uv_scale.x, 
			uv_scale.y, 
			params.displacement_scale, 
			params.normal_scale
		)

	# === UPDATE MATERIAL ===
	var material = get_surface_override_material(0)
	if material:
		material.set_shader_parameter("map_scales", map_scales)

	# Update spray material if used
	if SPRAY_MAT:
		SPRAY_MAT.set_shader_parameter("map_scales", map_scales)

	print("Map scales updated")

## Handle node deletion and cleanup
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# === CLEAN UP GPU RESOURCES ===
		# Clear texture RIDs to prevent leaks
		if displacement_maps.texture_rd_rid.is_valid():
			displacement_maps.texture_rd_rid = RID()
		
		if normal_maps.texture_rd_rid.is_valid():
			normal_maps.texture_rd_rid = RID()
		
		# === DISCONNECT SIGNALS ===
		# Disconnect from moon if connected
		if is_instance_valid(moon) and moon.is_connected("orbit_updated", _update_tidal_forces):
			moon.disconnect("orbit_updated", _update_tidal_forces)
			
		# Disconnect from terrain if connected
		if is_instance_valid(terrain_node) and terrain_node.has_signal("terrain_modified") and terrain_node.is_connected("terrain_modified", _on_terrain_modified):
			terrain_node.disconnect("terrain_modified", _on_terrain_modified)
			
		# === CLEAN UP DEBUG VISUALIZATION ===
		for arrow in debug_arrows:
			if is_instance_valid(arrow):
				arrow.queue_free()
		debug_arrows.clear()
		
		# === CLEAN UP COMPUTE CONTEXT ===
		if shore_compute_context:
			shore_compute_context.free()
