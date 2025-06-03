@tool
class_name CelestialBody extends Node3D
## Celestial Body Class (Moon/Planet)
## 
## PURPOSE:
## --------
## Simulates orbiting celestial bodies (like moons) with gravitational effects.
## Used primarily for creating tidal forces on ocean water.
## Can be used in editor (@tool) for preview.
##
## FEATURES:
## ---------
## - Circular/elliptical orbits with inclination
## - Gravitational pull calculations
## - Tidal force calculations (differential gravity)
## - Visual representation with customizable mesh/material
## - Real-time orbit updates with configurable frequency

# Signal emitted when orbit position changes
# Used by water system to update tidal forces
signal orbit_updated

# === ORBITAL PARAMETERS ===
# The body this celestial object orbits around (e.g., planet for a moon)
@export var parent_body: Node3D

# Orbital radius in world units (distance from parent)
@export var orbit_radius := 15000.0

# Orbital angular velocity (radians per second)
# Positive = counter-clockwise, Negative = clockwise
@export var orbit_speed := 0.0002

# Orbital plane inclination in degrees
# 0 = equatorial orbit, 90 = polar orbit
@export var orbit_inclination := 0.0

# Additional position offset from calculated orbit
# Useful for fine-tuning position
@export var orbit_offset := Vector3.ZERO

# Gravitational mass of this body (arbitrary units)
# Higher = stronger gravitational pull
@export var mass := 300.0

# Physical radius of the celestial body
# Used to prevent singularities in gravity calculations
@export var body_radius := 270.0

# === VISUAL PROPERTIES ===
# Mesh to display for this celestial body
@export var body_mesh: Mesh

# Material override for the mesh
@export var body_material: Material

# === STARTING CONDITIONS ===
# Initial angle in orbit (radians)
# 0 = positive X axis, PI/2 = positive Z axis
@export var initial_angle := 0.0

# === RUNTIME VARIABLES ===
# Current angle in the orbital path (radians)
var orbit_angle := 0.0

# Current 3D position relative to parent
var position_3d := Vector3.ZERO

# Time of last orbit_updated signal emission
# Used to throttle signal frequency
var last_update_time := 0.0

func _ready():
	# Initialize orbit to starting position
	orbit_angle = initial_angle
	
	# Create visual representation if mesh is provided but no child exists
	# This allows automatic mesh setup while preserving manual child nodes
	if body_mesh and get_child_count() == 0:
		var mesh_instance = MeshInstance3D.new()
		mesh_instance.mesh = body_mesh
		mesh_instance.material_override = body_material
		mesh_instance.name = "MoonMesh"  # Named for easy identification
		add_child(mesh_instance)
		
	# Set initial position
	_update_position()

func _process(delta):
	# === UPDATE ORBITAL MOTION ===
	# Advance orbit angle based on speed and time
	orbit_angle += orbit_speed * delta
	
	# Wrap angle to stay within 0 to 2π (TAU)
	# Prevents floating point overflow after long runtimes
	if orbit_angle > TAU:
		orbit_angle -= TAU
		
	# Calculate new position
	_update_position()
	
	# === SIGNAL EMISSION THROTTLING ===
	# Emit orbit update signal at limited frequency to avoid performance issues
	# Shader updates are expensive, so we limit to ~10Hz
	var current_time = Time.get_ticks_msec() / 1000.0
	if current_time - last_update_time > 0.1:  # 100ms = 10 updates per second
		orbit_updated.emit()
		last_update_time = current_time

func _update_position():
	# === CALCULATE ORBITAL POSITION ===
	# Basic circular orbit in XZ plane
	var x = cos(orbit_angle) * orbit_radius
	var z = sin(orbit_angle) * orbit_radius
	
	# === APPLY ORBITAL INCLINATION ===
	# Tilt the orbit by rotating around X axis
	var inclination_rad = deg_to_rad(orbit_inclination)
	
	# Y component comes from the Z position times sin(inclination)
	var y = sin(inclination_rad) * z
	
	# Z component is reduced by cos(inclination)
	z = cos(inclination_rad) * z
	
	# === SET FINAL POSITION ===
	# Combine orbital position with any manual offset
	position_3d = Vector3(x, y, z) + orbit_offset
	
	# === UPDATE TRANSFORM ===
	# Position relative to parent body if it exists
	if parent_body:
		global_position = parent_body.global_position + position_3d
	else:
		# No parent = orbit around world origin
		global_position = position_3d

## Calculate gravitational pull vector at a given position
## Uses simplified Newtonian gravity: F = G*M/r²
## @param at_position: World position to calculate gravity at
## @return: Force vector pointing toward this body
func get_gravitational_pull(at_position: Vector3) -> Vector3:
	# Calculate vector from target position to celestial body
	var direction = global_position - at_position
	var distance = direction.length()
	
	# === PREVENT SINGULARITIES ===
	# Clamp minimum distance to body radius
	# This prevents infinite forces at center
	if distance < body_radius:
		distance = body_radius
		
	# === CALCULATE FORCE MAGNITUDE ===
	# Newton's law of gravitation: F = G * m1 * m2 / r²
	# We simplify by:
	# - Setting G = 1.0 (gravitational constant)
	# - Assuming unit mass for the affected object
	# So: F = mass / distance²
	var force_magnitude = mass / (distance * distance)
	
	# === RETURN FORCE VECTOR ===
	# Normalize direction and scale by magnitude
	return direction.normalized() * force_magnitude
	
## Calculate tidal acceleration (differential gravity)
## Tides are caused by the difference in gravitational pull across an object
## @param at_position: Position to calculate tidal force at
## @param reference_position: Reference point (usually planet center)
## @return: Differential acceleration vector
func get_relative_acceleration(at_position: Vector3, reference_position: Vector3) -> Vector3:
	# === TIDAL FORCE CALCULATION ===
	# Tides occur because gravity varies with distance
	# Points closer to the moon experience stronger pull than the planet's center
	# Points farther experience weaker pull
	
	# Calculate absolute acceleration at the target position
	var pull_at_position = get_gravitational_pull(at_position)
	
	# Calculate absolute acceleration at the reference (planet center)
	var pull_at_reference = get_gravitational_pull(reference_position)
	
	# === DIFFERENTIAL ACCELERATION ===
	# The tidal effect is the difference between these accelerations
	# This creates the characteristic "stretching" effect:
	# - Bulge toward the moon (stronger pull)
	# - Bulge away from moon (weaker pull than center)
	return pull_at_position - pull_at_reference
