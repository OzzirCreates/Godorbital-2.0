class_name RenderingContext extends Object
## RenderingContext - GPU Resource Management Wrapper
## 
## PURPOSE:
## --------
## Provides a high-level wrapper around Godot's RenderingDevice API.
## Handles automatic memory management, resource allocation, and cleanup.
## Simplifies GPU compute pipeline creation and execution.
##
## FEATURES:
## ---------
## - Automatic resource cleanup via DeletionQueue
## - Simplified buffer and texture creation
## - Shader caching system
## - Easy compute pipeline creation
## - Type-safe descriptor management

## DeletionQueue - Manages GPU resource lifetime
## Ensures resources are freed in reverse order of allocation
class DeletionQueue:
	# Array of resource IDs to be freed
	var queue : Array[RID] = []

	## Add a resource to the deletion queue
	## Returns the RID for convenience
	func push(rid : RID) -> RID:
		queue.push_back(rid)
		return rid

	## Free all resources in the queue
	## Works backwards to free in reverse allocation order
	func flush(device : RenderingDevice) -> void:
		# Reverse order prevents dependencies issues
		# (e.g., free textures before buffers they depend on)
		for i in range(queue.size() - 1, -1, -1):
			if not queue[i].is_valid(): 
				continue
			device.free_rid(queue[i])
		queue.clear()

	## Free a specific resource immediately
	## Removes it from the queue
	func free_rid(device : RenderingDevice, rid : RID) -> void:
		var rid_idx := queue.find(rid)
		# Ensure the RID exists in our queue
		assert(rid_idx != -1, 'RID was not found in deletion queue!')
		# Remove and free the resource
		device.free_rid(queue.pop_at(rid_idx))

## Descriptor - Represents a GPU resource with type information
## Used for creating descriptor sets with proper typing
class Descriptor:
	# Resource identifier
	var rid : RID
	# Type of resource (buffer, texture, etc.)
	var type : RenderingDevice.UniformType

	func _init(rid_ : RID, type_ : RenderingDevice.UniformType) -> void:
		rid = rid_
		type = type_

# === MEMBER VARIABLES ===
# The underlying RenderingDevice
var device : RenderingDevice

# Manages resource cleanup
var deletion_queue := DeletionQueue.new()

# Caches loaded shaders to avoid recompilation
# Key: shader path, Value: shader RID
var shader_cache : Dictionary

# Tracks if synchronization is needed
var needs_sync := false

## Create a new RenderingContext
## @param device: Optional RenderingDevice to use (creates local if null)
static func create(device : RenderingDevice = null) -> RenderingContext:
	var context := RenderingContext.new()
	# Use provided device or create a local one
	context.device = RenderingServer.create_local_rendering_device() if not device else device
	return context

## Handle object deletion
func _notification(what):
	if what == NOTIFICATION_PREDELETE:
		# === CLEANUP ON DESTRUCTION ===
		# All resources must be freed to avoid GPU memory leaks
		deletion_queue.flush(device)
		shader_cache.clear()
		
		# Free the device if it's not the global one
		if device != RenderingServer.get_rendering_device():
			device.free()

# === WRAPPER FUNCTIONS ===
# These provide direct access to common RenderingDevice methods

## Submit queued GPU commands for execution
func submit() -> void: 
	device.submit()
	needs_sync = true  # Mark that sync may be needed

## Wait for GPU operations to complete
func sync() -> void: 
	device.sync()
	needs_sync = false

## Begin a compute command list
func compute_list_begin() -> int: 
	return device.compute_list_begin()

## End a compute command list
func compute_list_end() -> void: 
	device.compute_list_end()

## Add a memory barrier in compute list
## Ensures previous operations complete before continuing
func compute_list_add_barrier(compute_list : int) -> void: 
	device.compute_list_add_barrier(compute_list)

# === HELPER FUNCTIONS ===

## Load and cache a shader from file
## @param path: Resource path to shader file
## @return: Shader RID
func load_shader(path : String) -> RID:
	# Check cache first
	if not shader_cache.has(path):
		# Load shader file
		var shader_file := load(path)
		# Get SPIR-V bytecode
		var shader_spirv : RDShaderSPIRV = shader_file.get_spirv()
		# Create shader and add to cache and deletion queue
		shader_cache[path] = deletion_queue.push(
			device.shader_create_from_spirv(shader_spirv)
		)
	return shader_cache[path]

## Create a storage buffer (read/write from shaders)
## @param size: Buffer size in bytes
## @param data: Initial data (optional)
## @param usage: Usage flags (default 0)
## @return: Descriptor for the buffer
func create_storage_buffer(size : int, data : PackedByteArray = [], usage := 0) -> Descriptor:
	# === HANDLE PADDING ===
	# If data is smaller than requested size, pad with zeros
	if size > len(data):
		var padding := PackedByteArray()
		padding.resize(size - len(data))
		data += padding
		
	# Create buffer and add to deletion queue
	var rid = deletion_queue.push(
		device.storage_buffer_create(max(size, len(data)), data, usage)
	)
	
	# Return typed descriptor
	return Descriptor.new(rid, RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER)

## Create a uniform buffer (read-only from shaders)
## @param size: Buffer size in bytes (minimum 16)
## @param data: Initial data (optional)
## @return: Descriptor for the buffer
func create_uniform_buffer(size : int, data : PackedByteArray = []) -> Descriptor:
	# Uniform buffers must be at least 16 bytes (vec4)
	size = max(16, size)
	
	# === HANDLE PADDING ===
	if size > len(data):
		var padding := PackedByteArray()
		padding.resize(size - len(data))
		data += padding
		
	# Create buffer and add to deletion queue
	var rid = deletion_queue.push(
		device.uniform_buffer_create(max(size, len(data)), data)
	)
	
	# Return typed descriptor
	return Descriptor.new(rid, RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER)

## Create a texture resource
## @param dimensions: Texture width and height
## @param format: Pixel format
## @param usage: Usage flags (default includes all common uses)
## @param num_layers: Array layers (0 for 2D, >0 for 2D array)
## @param view: Texture view settings
## @param data: Initial texture data
## @return: Descriptor for the texture
func create_texture(
	dimensions : Vector2i, 
	format : RenderingDevice.DataFormat, 
	usage := 0x18B,  # Default: sampling + color + storage + copy
	num_layers := 0, 
	view := RDTextureView.new(), 
	data : PackedByteArray = []
) -> Descriptor:
	# Ensure at least 1 layer
	assert(num_layers >= 1)
	
	# === CONFIGURE TEXTURE FORMAT ===
	var texture_format := RDTextureFormat.new()
	texture_format.array_layers = 1 if num_layers == 0 else num_layers
	texture_format.format = format
	texture_format.width = dimensions.x
	texture_format.height = dimensions.y
	
	# Determine texture type based on layers
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D if num_layers == 0 else RenderingDevice.TEXTURE_TYPE_2D_ARRAY
	
	# Set usage bits (default includes all common operations)
	texture_format.usage_bits = usage
	
	# Create texture and add to deletion queue
	var rid = deletion_queue.push(
		device.texture_create(texture_format, view, data)
	)
	
	# Return typed descriptor
	return Descriptor.new(rid, RenderingDevice.UNIFORM_TYPE_IMAGE)

## Create a descriptor set for shader bindings
## @param descriptors: Array of descriptors in binding order
## @param shader: Shader RID to bind to
## @param descriptor_set_index: Which set in the shader (default 0)
## @return: Descriptor set RID
func create_descriptor_set(
	descriptors : Array[Descriptor], 
	shader : RID, 
	descriptor_set_index := 0
) -> RID:
	# === BUILD UNIFORM ARRAY ===
	var uniforms : Array[RDUniform]
	
	# Create uniform for each descriptor
	for i in range(len(descriptors)):
		var uniform := RDUniform.new()
		uniform.uniform_type = descriptors[i].type
		uniform.binding = i  # Binding index matches array order
		uniform.add_id(descriptors[i].rid)
		uniforms.push_back(uniform)
		
	# Create descriptor set and add to deletion queue
	return deletion_queue.push(
		device.uniform_set_create(uniforms, shader, descriptor_set_index)
	)

## Create a compute pipeline with simplified dispatch
## @param block_dimensions: Work group counts [x, y, z]
## @param descriptor_sets: Array of descriptor set RIDs
## @param shader: Compute shader RID
## @return: Callable that dispatches the pipeline
func create_pipeline(
	block_dimensions : Array, 
	descriptor_sets : Array, 
	shader : RID
) -> Callable:
	# Create compute pipeline
	var pipeline = deletion_queue.push(device.compute_pipeline_create(shader))
	
	# === RETURN DISPATCH CALLABLE ===
	# This closure captures the pipeline and provides easy dispatch
	return func(
		context : RenderingContext,          # RenderingContext to use
		compute_list : int,                  # Active compute list
		push_constant : PackedByteArray = [], # Optional push constants
		descriptor_set_overwrites := [],      # Override descriptor sets
		block_dimensions_overwrite_buffer := RID(),        # Indirect dispatch buffer
		block_dimensions_overwrite_buffer_byte_offset := 0 # Offset in indirect buffer
	) -> void:
		var device := context.device
		var sets = descriptor_sets if descriptor_set_overwrites.is_empty() else descriptor_set_overwrites
		
		# === VALIDATION ===
		assert(
			len(block_dimensions) == 3 or block_dimensions_overwrite_buffer.is_valid(), 
			'Must specify block dimensions or specify a dispatch indirect buffer!'
		)
		assert(len(sets) >= 1, 'Must specify at least one descriptor set!')

		# === BIND PIPELINE ===
		device.compute_list_bind_compute_pipeline(compute_list, pipeline)
		
		# === SET PUSH CONSTANTS ===
		device.compute_list_set_push_constant(compute_list, push_constant, push_constant.size())
		
		# === BIND DESCRIPTOR SETS ===
		for i in range(len(sets)):
			device.compute_list_bind_uniform_set(compute_list, sets[i], i)

		# === DISPATCH WORK ===
		if block_dimensions_overwrite_buffer.is_valid():
			# Indirect dispatch - work group count comes from buffer
			device.compute_list_dispatch_indirect(
				compute_list, 
				block_dimensions_overwrite_buffer, 
				block_dimensions_overwrite_buffer_byte_offset
			)
		else:
			# Direct dispatch with specified work groups
			device.compute_list_dispatch(
				compute_list, 
				block_dimensions[0], 
				block_dimensions[1], 
				block_dimensions[2]
			)

## Create push constant data from array
## Ensures proper alignment and padding for GPU
## @param data: Array of int/float values
## @return: Packed byte array with proper alignment
static func create_push_constant(data : Array) -> PackedByteArray:
	# Calculate size (4 bytes per value)
	var packed_size := len(data) * 4
	
	# Push constants limited to 128 bytes in most GPUs
	assert(packed_size <= 128, 'Push constant size must be at most 128 bytes!')

	# === HANDLE ALIGNMENT ===
	# GPU requires 16-byte alignment for push constants
	var padding := ceili(packed_size / 16.0) * 16 - packed_size
	
	# Create byte array with padding
	var packed_data := PackedByteArray()
	packed_data.resize(packed_size + (padding if padding > 0 else 0))
	packed_data.fill(0)  # Initialize with zeros

	# === ENCODE VALUES ===
	for i in range(len(data)):
		match typeof(data[i]):
			TYPE_INT, TYPE_BOOL:   
				# Encode as signed 32-bit integer
				packed_data.encode_s32(i * 4, data[i])
			TYPE_FLOAT: 
				# Encode as 32-bit float
				packed_data.encode_float(i * 4, data[i])
				
	return packed_data
