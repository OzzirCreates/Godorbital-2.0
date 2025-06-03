@tool
class_name WaveCascadeParameters extends Resource
## Wave Cascade Parameters
##
## PURPOSE:
## --------
## Defines parameters for a single wave cascade in the ocean simulation.
## Multiple cascades are combined to create detailed ocean waves at different scales.
## Each cascade represents a different frequency band of waves.
##
## THEORY:
## -------
## Ocean waves contain energy at many frequencies. By simulating multiple
## cascades at different scales, we can capture both large swells and
## small ripples efficiently.

# Signal emitted when scale-related parameters change
# Used to update shader uniforms
signal scale_changed

## Tile size in world units (meters)
## Smaller tiles = higher frequency waves
## Larger tiles = lower frequency waves, ocean swells
@export var tile_length := Vector2(50, 50) :
	set(value):
		if tile_length == value:
			return
		tile_length = value
		# Mark spectrum for regeneration
		should_generate_spectrum = true
		# Update internal array for UI
		_tile_length = [value.x, value.y]
		# Notify shader to update
		emit_signal("scale_changed")

## Vertical displacement scale
## Controls wave height for this cascade
## Should be reduced for higher frequency cascades
@export_range(0, 2) var displacement_scale := 1.0 :
	set(value):
		if displacement_scale == value:
			return
		displacement_scale = value
		# Update internal array
		_displacement_scale = [displacement_scale]
		# Notify shader
		emit_signal("scale_changed")

## Normal map strength
## Controls surface bumpiness for this cascade
## Higher = more detailed surface normals
@export_range(0, 2) var normal_scale := 1.0 :
	set(value):
		if normal_scale == value:
			return
		normal_scale = value
		# Update internal array
		_normal_scale = [normal_scale]
		# Notify shader
		emit_signal("scale_changed")

## Wind speed in meters per second
## Higher wind = steeper, more chaotic waves
## Affects wave spectrum shape
@export var wind_speed := 20.0 :
	set(value):
		if wind_speed == value:
			return
		# Prevent zero/negative wind speed
		wind_speed = max(0.0001, value)
		# Mark for spectrum regeneration
		should_generate_spectrum = true
		# Update internal array
		_wind_speed = [wind_speed]

## Primary wind direction in degrees
## 0° = positive X direction
## 90° = positive Z direction
@export_range(-360, 360) var wind_direction := 0.0 :
	set(value):
		if wind_direction == value:
			return
		wind_direction = value
		should_generate_spectrum = true
		# Convert to radians for shader
		_wind_direction = [deg_to_rad(value)]

## Fetch length in kilometers
## Distance over which wind has blown
## Longer fetch = larger, steeper waves
@export var fetch_length := 550.0 :
	set(value):
		if fetch_length == value:
			return
		# Prevent zero/negative fetch
		fetch_length = max(0.0001, value)
		should_generate_spectrum = true
		_fetch_length = [fetch_length]

## Swell amount (0-2)
## Adds long-wavelength waves from distant storms
## Higher = more pronounced swells
@export_range(0, 2) var swell := 0.8 :
	set(value):
		if swell == value:
			return
		swell = value
		should_generate_spectrum = true
		_swell = [value]

## Directional spread (0-1)
## 0 = waves all in one direction
## 1 = waves spread in all directions
## Controls how much waves deviate from wind direction
@export_range(0, 1) var spread := 0.2 :
	set(value):
		if spread == value:
			return
		spread = value
		should_generate_spectrum = true
		_spread = [value]

## High frequency detail (0-1)
## 0 = suppress small wavelengths
## 1 = full detail at all frequencies
## Can improve performance by reducing detail
@export_range(0, 1) var detail := 1.0 :
	set(value):
		if detail == value:
			return
		detail = value
		should_generate_spectrum = true
		_detail = [value]

## Whitecap threshold (0-2)
## Controls when foam appears on waves
## Lower = foam appears on gentler waves
## Higher = only steep waves get foam
@export_range(0, 2) var whitecap := 0.5 :
	set(value):
		if whitecap == value:
			return
		whitecap = value
		should_generate_spectrum = true
		_whitecap = [value]

## Foam generation amount (0-10)
## Controls how much foam is generated
## Higher = more foam coverage
## Works with whitecap to control foam appearance
@export_range(0, 10) var foam_amount := 5.0 :
	set(value):
		if foam_amount == value:
			return
		foam_amount = value
		should_generate_spectrum = true
		_foam_amount = [value]

# === INTERNAL STATE ===
# Random seed for wave phase
# Each cascade gets unique seed for variety
var spectrum_seed := Vector2i.ZERO

# Flag indicating spectrum needs regeneration
# Set to true when wave parameters change
var should_generate_spectrum := true

# === RUNTIME VARIABLES ===
# Current simulation time for this cascade
var time : float

# Foam dynamics calculated each frame
var foam_grow_rate : float   # How fast foam appears
var foam_decay_rate : float   # How fast foam disappears

# === UI REFERENCES ===
# Internal arrays for potential UI systems
# These mirror the export variables but in array form
# The actual parameters won't reflect these unless manually synced
var _tile_length := [tile_length.x, tile_length.y]
var _displacement_scale := [displacement_scale]
var _normal_scale := [normal_scale]
var _wind_speed := [wind_speed]
var _wind_direction := [deg_to_rad(wind_direction)]
var _fetch_length := [fetch_length]
var _swell := [swell]
var _detail := [detail]
var _spread := [spread]
var _whitecap := [whitecap]
var _foam_amount := [foam_amount]
