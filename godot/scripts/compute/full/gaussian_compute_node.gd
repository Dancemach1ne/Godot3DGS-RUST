class_name GaussianComputeNode
extends Node3D

const GaussianCollisionBuilder := preload("res://scripts/collision/gaussian_collision_builder.gd")

signal collision_generated(result: Dictionary)

## Current-project adapter: one node/resource pair registered with the full
## reference Compute scheduler. Future collision and bake components can be
## added beside this node without changing the renderer contract.
@export var gaussian: GaussianResource:
	set(value):
		gaussian = value
		_notify_resource_changed()

# Reserved compatibility fields. The imported full Compute pipeline allocates
# neutral buffers for them; no lighting bake is produced in this project yet.
@export var lighting: Resource
@export var relight_enabled := false
@export var relight_unlit_level := 1.0
@export var relight_light_gain := 1.0
@export var relight_ambient := Color.WHITE
@export var relight_dc_only := false

@export_group("Collision")
## Zero selects the reference-compatible automatic size: longest 3-sigma
## bounds axis / 128, clamped to 0.01..0.5 scene units.
@export_range(0.0, 10.0, 0.001, "or_greater") var collision_voxel_size := 0.0
@export_range(0.001, 0.999, 0.001) var collision_opacity_cutoff := 0.1
## Collision baking is intentionally opt-in because a large PLY can take time.
@export var generate_collision_on_ready := false

static func get_model_orientation_correction() -> Transform3D:
	return Transform3D(Basis.from_euler(Vector3(0.0, 0.0, -PI)), Vector3.ZERO)

func _enter_tree() -> void:
	# Match the reference GaussianSplatNode coordinate-system correction.
	if transform.basis.orthonormalized().is_equal_approx(Basis.IDENTITY):
		transform = transform * get_model_orientation_correction()

func _ready() -> void:
	_register()
	if generate_collision_on_ready:
		call_deferred("generate_collision")

func _exit_tree() -> void:
	var manager = GaussianRenderManager.get_instance()
	if manager != null:
		manager.unregister_splat_node(self)

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		var manager = GaussianRenderManager.get_instance()
		if manager != null:
			manager.mark_transform_dirty(self)

func _register() -> void:
	var manager = GaussianRenderManager.get_instance()
	if manager != null:
		manager.register_splat_node(self)

func _notify_resource_changed() -> void:
	if not is_inside_tree():
		return
	# A baked shape belongs to the previous resource and must never silently
	# remain active after the rendered splat data changes.
	clear_collision()
	var manager = GaussianRenderManager.get_instance()
	if manager != null:
		manager.mark_resource_dirty(self)

## Synchronously bakes and attaches a StaticBody3D. Call this from a loading
## screen or editor tool for large captures; the renderer itself stays usable
## when collision generation is disabled or fails.
func generate_collision() -> Dictionary:
	var result := GaussianCollisionBuilder.generate_and_attach(
		self,
		gaussian,
		collision_voxel_size,
		collision_opacity_cutoff
	)
	if result.get("ok", false):
		var stats: Dictionary = result.get("stats", {})
		print(
			"[Godot3DGS-RUST] Rust collision ready: %d occupied voxels, %d triangles, %d position outliers skipped, voxel_size=%s" % [
				int(stats.get("occupied_voxels", 0)),
				int(stats.get("triangles", 0)),
				int(stats.get("position_outliers", 0)),
				str(stats.get("voxel_size", collision_voxel_size)),
			]
		)
	else:
		push_error("[Godot3DGS-RUST] Collision generation failed: %s" % result.get("message", "unknown error"))
	collision_generated.emit(result)
	return result

func clear_collision() -> void:
	GaussianCollisionBuilder.clear(self)
