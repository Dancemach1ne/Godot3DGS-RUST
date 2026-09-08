class_name GaussianSplatRaster
extends Node3D

## Milestone 3 Raster baseline. Rust owns the packed record; this node uploads
## it once as a data texture and draws one GPU-projected quad per splat.
const RASTER_SHADER = preload("res://scripts/raster/gaussian_splat_raster.gdshader")
const TEXELS_PER_SPLAT := 15
const MAX_TEXTURE_DIM := 16384

var gaussian: GaussianResource:
	set(value):
		gaussian = value
		if is_inside_tree():
			_rebuild()

var _instance: MultiMeshInstance3D
var _material: ShaderMaterial
var _sort_state: GdgsSortState
var _order_image: Image
var _order_texture: ImageTexture
var _order_dims := Vector2i(1, 1)
var _last_view_direction := Vector3.ZERO
var _has_sorted := false

func _ready() -> void:
	_rebuild()

func _process(_delta: float) -> void:
	_update_sort()

func _exit_tree() -> void:
	_clear()

func _rebuild() -> void:
	_clear()
	if gaussian == null or not gaussian.is_valid() or gaussian.point_count == 0:
		return
	var packed := _make_record_texture(gaussian.point_data, gaussian.point_count)
	if packed.is_empty():
		push_error("[Godot3DGS-RUST] Raster texture build failed")
		return
	var material := ShaderMaterial.new()
	material.shader = RASTER_SHADER
	material.set_shader_parameter("splat_data", packed["texture"])
	material.set_shader_parameter("data_width", packed["width"])
	material.set_shader_parameter("point_count", gaussian.point_count)
	_order_dims = _order_dimensions(gaussian.point_count)
	var empty_order := PackedByteArray()
	empty_order.resize(_order_dims.x * _order_dims.y * 4)
	_order_image = Image.create_from_data(_order_dims.x, _order_dims.y, false, Image.FORMAT_RF, empty_order)
	_order_texture = ImageTexture.create_from_image(_order_image)
	material.set_shader_parameter("order_data", _order_texture)
	material.set_shader_parameter("order_width", _order_dims.x)
	material.set_shader_parameter("use_order", false)
	_material = material
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2.0, 2.0)
	mesh.material = material
	mesh.custom_aabb = AABB(Vector3(-1000000.0, -1000000.0, -1000000.0), Vector3(2000000.0, 2000000.0, 2000000.0))
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = gaussian.point_count
	_instance = MultiMeshInstance3D.new()
	_instance.name = "RasterSplats"
	_instance.multimesh = multimesh
	_instance.extra_cull_margin = 1000000.0
	_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_instance.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(_instance)
	_sort_state = GdgsSortState.new()
	_sort_state.set_positions(gaussian.positions)
	_last_view_direction = Vector3.ZERO
	_has_sorted = false

## Splat-aligned packing means `splat_index * 15 + texel` is a valid lookup.
func _make_record_texture(bytes: PackedByteArray, count: int) -> Dictionary:
	var total_texels := count * TEXELS_PER_SPLAT
	var side := int(ceil(sqrt(float(total_texels))))
	var width := clampi(int(ceil(float(side) / TEXELS_PER_SPLAT)) * TEXELS_PER_SPLAT, TEXELS_PER_SPLAT, MAX_TEXTURE_DIM)
	var height := int(ceil(float(total_texels) / float(width)))
	if height > MAX_TEXTURE_DIM:
		push_error("[Godot3DGS-RUST] Raster texture exceeds one 2D texture; chunking is a later extension")
		return {}
	var padded := bytes.duplicate()
	padded.resize(width * height * 16)
	var image := Image.create_from_data(width, height, false, Image.FORMAT_RGBAF, padded)
	if image == null:
		return {}
	return {"texture": ImageTexture.create_from_image(image), "width": width}

func _clear() -> void:
	if _instance != null and is_instance_valid(_instance):
		_instance.queue_free()
	_instance = null
	_sort_state = null
	_order_image = null
	_order_texture = null
	_material = null
	_has_sorted = false

func _update_sort() -> void:
	if _instance == null or _sort_state == null or gaussian == null:
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var world_forward := -camera.global_transform.basis.z
	var local_direction := global_transform.basis.transposed() * world_forward
	if local_direction.length_squared() < 0.000001:
		return
	local_direction = local_direction.normalized()
	if _has_sorted and _last_view_direction.dot(local_direction) >= 0.99985:
		return
	var order := _sort_state.sort_back_to_front(local_direction)
	assert(order.size() == gaussian.point_count)
	var order_bytes := order.to_byte_array()
	order_bytes.resize(_order_dims.x * _order_dims.y * 4)
	_order_image.set_data(_order_dims.x, _order_dims.y, false, Image.FORMAT_RF, order_bytes)
	_order_texture.update(_order_image)
	_material.set_shader_parameter("use_order", true)
	_last_view_direction = local_direction
	_has_sorted = true

func _order_dimensions(count: int) -> Vector2i:
	var width := clampi(int(ceil(sqrt(float(count)))), 1, MAX_TEXTURE_DIM)
	return Vector2i(width, int(ceil(float(count) / float(width))))
