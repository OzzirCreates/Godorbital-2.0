@tool
extends Node3D

# Minimal script that only manages what the shader cannot do itself
# Eliminates all redundant functionality

@export_category("Shader References")
@export var cloud_material: ShaderMaterial  # Reference to the cloud shader material
@export var noise_3d_texture: Texture3D  # 3D noise texture for the shader

@export_category("Runtime Updates")
@export var update_time: bool = true  # Whether to update time automatically
@export var update_camera: bool = true  # Whether to update camera position

# Optional time speed multiplier
@export var time_scale: float = 1.0

func _ready():
	# Initial setup - assign noise texture if available
	if cloud_material and noise_3d_texture:
		cloud_material.set_shader_parameter("noise3d_tex", noise_3d_texture)

func _process(delta):
	if not cloud_material:
		return
		
	# Only update time parameter from CPU - shader handles all the cloud animation
	if update_time:
		var current_time = cloud_material.get_shader_parameter("time")
		if current_time != null:
			cloud_material.set_shader_parameter("time", current_time + delta * time_scale)
	
	# Only update camera-based parameters - shader handles all visual effects
	if update_camera:
		update_camera_parameters()

func update_camera_parameters():
	# Get camera
	var camera = get_viewport().get_camera_3d()
	if not camera:
		return
		
	# Calculate camera distance from planet center
	var cam_pos = camera.global_position
	var distance = cam_pos.length()  # Assuming planet center is at origin
	
	# Update camera distance for LOD
	cloud_material.set_shader_parameter("camera_distance", distance)
	
	# Calculate altitude (distance from surface)
	var planet_radius = cloud_material.get_shader_parameter("planet_radius")
	if planet_radius:
		var altitude = max(0.0, distance - planet_radius)
		cloud_material.set_shader_parameter("player_altitude", altitude)

func set_light_direction(direction: Vector3):
	# Helper function to update light direction (e.g. for day/night cycle)
	if cloud_material:
		cloud_material.set_shader_parameter("light_direction", direction.normalized())
