@tool
extends Node3D
class_name PlanetAtmosphere

# Core properties
@export var planet_radius: float = 100.0:
	set(value):
		planet_radius = max(value, 10.0)
		_update_shader_param("planet_radius", planet_radius)
		_update_mesh_scale()

@export var atmosphere_height: float = 25.0:
	set(value):
		atmosphere_height = max(value, 1.0)
		_update_shader_param("atmosphere_height", atmosphere_height)
		_update_mesh_scale()

# Light parameters
@export var sun_intensity: float = 30.0:
	set(value):
		sun_intensity = max(value, 0.1)
		_update_shader_param("sun_intensity", sun_intensity)

@export var sun_color: Color = Color(1.0, 0.98, 0.9):
	set(value):
		sun_color = value
		_update_shader_param("sun_color", sun_color)

# Atmosphere color properties
@export var wavelengths: Vector3 = Vector3(700.0, 530.0, 440.0):
	set(value):
		wavelengths = value
		_update_shader_param("wavelengths", wavelengths)

@export var scattering_strength: float = 0.5:
	set(value):
		scattering_strength = value
		_update_shader_param("scattering_strength", scattering_strength)

@export var density: float = 10.0:
	set(value):
		density = value
		_update_shader_param("density", density)

# Mie scattering parameters
@export var mie_color: Color = Color(0.9, 0.9, 0.9):
	set(value):
		mie_color = value
		_update_shader_param("mie_color", mie_color)

@export var mie_coefficient: float = 0.7:
	set(value):
		mie_coefficient = value
		_update_shader_param("mie_coefficient", mie_coefficient)

@export var mie_scale_height: float = 0.1:
	set(value):
		mie_scale_height = value
		_update_shader_param("mie_scale_height", mie_scale_height)

@export var mie_density: float = 1.2:
	set(value):
		mie_density = value
		_update_shader_param("mie_density", mie_density)

@export var mie_direction: float = 0.758:
	set(value):
		mie_direction = value
		_update_shader_param("mie_direction", mie_direction)

# Quality settings
@export var primary_steps: int = 24:
	set(value):
		primary_steps = max(value, 4)
		_update_shader_param("primary_steps", primary_steps)

@export var light_steps: int = 8:
	set(value):
		light_steps = max(value, 4)
		_update_shader_param("light_steps", light_steps)

@export var intensity_factor: float = 3.0:
	set(value):
		intensity_factor = value
		_update_shader_param("intensity_factor", intensity_factor)

@export var sun_path: NodePath:
	set(value):
		sun_path = value
		update_configuration_warnings()

@export var force_fullscreen: bool = false:
	set(value):
		force_fullscreen = value
		_update_shader_param("u_clip_mode", force_fullscreen)

# Private variables
var _mesh_instance: MeshInstance3D

func _init():
	# Create atmosphere sphere mesh
	var sphere = SphereMesh.new()
	sphere.radial_segments = 64
	sphere.rings = 32
	
	# Create material
	var material = ShaderMaterial.new()
	
	# Use external shader file
	var atmosphere_shader = load("res://assets/Atmosphere/Atmosphere.gdshader")
	material.shader = atmosphere_shader
	
	# Create mesh instance
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.mesh = sphere
	_mesh_instance.material_override = material
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)
	
	# Initialize parameters
	_update_shader_param("planet_radius", planet_radius)
	_update_shader_param("atmosphere_height", atmosphere_height)
	_update_shader_param("sun_intensity", sun_intensity)
	_update_shader_param("sun_color", sun_color)
	_update_shader_param("wavelengths", wavelengths)
	_update_shader_param("scattering_strength", scattering_strength)
	_update_shader_param("density", density)
	_update_shader_param("mie_color", mie_color)
	_update_shader_param("mie_coefficient", mie_coefficient)
	_update_shader_param("mie_scale_height", mie_scale_height)
	_update_shader_param("mie_density", mie_density)
	_update_shader_param("mie_direction", mie_direction)
	_update_shader_param("primary_steps", primary_steps)
	_update_shader_param("light_steps", light_steps)
	_update_shader_param("intensity_factor", intensity_factor)
	_update_shader_param("u_clip_mode", force_fullscreen)
	
	# Initialize mesh scale
	_update_mesh_scale()

func _process(_delta):
	# Update sun position in shader
	if has_node(sun_path):
		var sun = get_node(sun_path)
		if sun is Node3D:
			_update_shader_param("sun_position", sun.global_position)

func _update_mesh_scale():
	# Scale mesh to encompass atmosphere
	var total_radius = planet_radius + atmosphere_height
	_mesh_instance.scale = Vector3(total_radius, total_radius, total_radius)
	
	# Update cull margin to prevent clipping
	_mesh_instance.extra_cull_margin = atmosphere_height * 0.5

func _update_shader_param(param_name, value):
	# Update shader parameter if material exists
	if _mesh_instance and _mesh_instance.material_override:
		var material = _mesh_instance.material_override as ShaderMaterial
		if material:
			material.set_shader_parameter(param_name, value)

func _get_configuration_warnings() -> PackedStringArray:
	var warnings = PackedStringArray()
	
	if sun_path.is_empty():
		warnings.append("No sun node assigned. Assign a DirectionalLight3D to the sun_path for dynamic lighting.")
	
	return warnings
