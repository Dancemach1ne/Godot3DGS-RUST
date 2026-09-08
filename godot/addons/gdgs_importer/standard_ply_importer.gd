@tool
extends EditorImportPlugin

## Godot editor entry point. Binary parsing and 3DGS packing remain in Rust.
const GaussianResourceScript = preload("res://scripts/gaussian_resource.gd")

func _get_importer_name() -> String:
	return "godot3dgs_rust.standard_ply"

func _get_visible_name() -> String:
	return "Gaussian Splat (standard PLY, Rust)"

func _get_recognized_extensions() -> PackedStringArray:
	return ["ply"]

func _get_save_extension() -> String:
	return "res"

func _get_resource_type() -> String:
	return "Resource"

func _get_preset_count() -> int:
	return 1

func _get_preset_name(_preset_index: int) -> String:
	return "Default"

func _get_import_options(_path: String, _preset_index: int) -> Array[Dictionary]:
	return []

func _import(source_file: String, save_path: String, _options: Dictionary, _platform_variants: Array[String], _gen_files: Array[String]) -> Error:
	var native := GdgsNative.new()
	var result: Dictionary = native.decode_standard_ply(ProjectSettings.globalize_path(source_file))
	if not result.get("ok", false):
		push_error("[Godot3DGS-RUST] PLY import failed: %s" % result.get("message", "unknown error"))
		return ERR_INVALID_DATA

	var resource := GaussianResourceScript.new()
	resource.point_count = int(result["point_count"])
	resource.point_data = result["point_data"]
	resource.positions = result["positions"]
	resource.aabb = _aabb_from_positions(resource.positions)
	if not resource.is_valid():
		push_error("[Godot3DGS-RUST] Rust returned an invalid GaussianResource contract")
		return ERR_INVALID_DATA
	return ResourceSaver.save(resource, "%s.res" % save_path)

func _aabb_from_positions(positions: PackedVector3Array) -> AABB:
	if positions.is_empty():
		return AABB()
	var box := AABB(positions[0], Vector3.ZERO)
	for position in positions:
		box = box.expand(position)
	return box
