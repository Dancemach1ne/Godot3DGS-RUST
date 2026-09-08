class_name GaussianComputeEffect
extends CompositorEffect

## Milestone 4 Compute baseline.
##
## The effect runs on Godot's render thread. It uploads the immutable 240-byte
## splat records once and composites a small direct-evaluation kernel into the
## scene color image. Tile projection/sort/raster passes replace this kernel in
## the next Compute increment without changing the resource contract.

const COMPUTE_SHADER = preload("res://scripts/compute/shaders/gaussian_direct.glsl")
const WORKGROUP_SIZE := 8

var _rd: RenderingDevice
var _shader := RID()
var _pipeline := RID()
var _splat_buffer := RID()
var _camera_buffer := RID()
var _point_count := 0
var _pending_splat_bytes := PackedByteArray()

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	RenderingServer.call_on_render_thread(_initialize_on_render_thread)

func set_gaussian(resource: GaussianResource) -> void:
	if resource == null or not resource.is_valid():
		_point_count = 0
		_pending_splat_bytes = PackedByteArray()
		RenderingServer.call_on_render_thread(_drop_splats_on_render_thread)
		return
	_point_count = resource.point_count
	_pending_splat_bytes = resource.point_data
	RenderingServer.call_on_render_thread(_upload_splats_on_render_thread)

func _notification(what: int) -> void:
	if what != NOTIFICATION_PREDELETE or _rd == null:
		return
	# The effect object itself is already being destroyed. Capture only the
	# device and RIDs, so the render-thread callback never dereferences self.
	var device := _rd
	var rids: Array[RID] = [_splat_buffer, _camera_buffer, _pipeline, _shader]
	RenderingServer.call_on_render_thread(func() -> void:
		for rid in rids:
			if rid.is_valid():
				device.free_rid(rid)
	)

func _initialize_on_render_thread() -> void:
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		push_warning("[Godot3DGS-RUST] Compute backend unavailable: this renderer has no RenderingDevice")
		return
	_shader = _rd.shader_create_from_spirv(COMPUTE_SHADER.get_spirv())
	_pipeline = _rd.compute_pipeline_create(_shader)
	_camera_buffer = _rd.uniform_buffer_create(160)
	if not _pending_splat_bytes.is_empty():
		_upload_splats_on_render_thread()

func _upload_splats_on_render_thread() -> void:
	if _rd == null:
		return
	if _splat_buffer.is_valid():
		_rd.free_rid(_splat_buffer)
		_splat_buffer = RID()
	if _pending_splat_bytes.is_empty() or _point_count <= 0:
		return
	_splat_buffer = _rd.storage_buffer_create(_pending_splat_bytes.size(), _pending_splat_bytes)

func _drop_splats_on_render_thread() -> void:
	if _rd != null and _splat_buffer.is_valid():
		_rd.free_rid(_splat_buffer)
	_splat_buffer = RID()

func _render_callback(_callback_type: int, render_data: RenderData) -> void:
	if _rd == null or not _pipeline.is_valid() or not _splat_buffer.is_valid() or _point_count <= 0:
		return
	var scene_buffers: RenderSceneBuffersRD = render_data.get_render_scene_buffers()
	var scene_data: RenderSceneDataRD = render_data.get_render_scene_data()
	if scene_buffers == null or scene_data == null:
		return
	var size := scene_buffers.get_internal_size()
	if size.x <= 0 or size.y <= 0:
		return
	var view := 0
	var camera_transform: Transform3D = scene_data.get_cam_transform()
	var projection: Projection = scene_data.get_view_projection(view)
	_rd.buffer_update(_camera_buffer, 0, 160, _camera_bytes(camera_transform, projection, size))
	var scene_color: RID = scene_buffers.get_color_layer(view)
	if not scene_color.is_valid():
		return
	var scene_uniform := RDUniform.new()
	scene_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	scene_uniform.binding = 0
	scene_uniform.add_id(scene_color)
	var splat_uniform := RDUniform.new()
	splat_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	splat_uniform.binding = 1
	splat_uniform.add_id(_splat_buffer)
	var camera_uniform := RDUniform.new()
	camera_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER
	camera_uniform.binding = 2
	camera_uniform.add_id(_camera_buffer)
	var uniform_set := UniformSetCacheRD.get_cache(_shader, 0, [scene_uniform, splat_uniform, camera_uniform])
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	_rd.compute_list_dispatch(list, int(ceili(size.x / float(WORKGROUP_SIZE))), int(ceili(size.y / float(WORKGROUP_SIZE))), 1)
	_rd.compute_list_end()

func _camera_bytes(transform: Transform3D, projection: Projection, size: Vector2i) -> PackedByteArray:
	var view := Projection(transform.affine_inverse())
	var values: Array[float] = []
	values.append_array(_projection_floats(view))
	values.append_array(_projection_floats(projection))
	values.append_array([transform.origin.x, transform.origin.y, transform.origin.z, 0.0])
	var bytes := PackedByteArray()
	bytes.resize(160)
	for index in values.size():
		bytes.encode_float(index * 4, values[index])
	bytes.encode_s32(144, size.x)
	bytes.encode_s32(148, size.y)
	bytes.encode_s32(152, _point_count)
	bytes.encode_s32(156, 0)
	return bytes

func _projection_floats(matrix: Projection) -> Array[float]:
	return [matrix.x[0], matrix.x[1], matrix.x[2], matrix.x[3], matrix.y[0], matrix.y[1], matrix.y[2], matrix.y[3], matrix.z[0], matrix.z[1], matrix.z[2], matrix.z[3], matrix.w[0], matrix.w[1], matrix.w[2], matrix.w[3]]
