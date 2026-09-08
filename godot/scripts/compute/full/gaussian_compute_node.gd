class_name GaussianComputeNode
extends Node3D

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

static func get_model_orientation_correction() -> Transform3D:
	return Transform3D(Basis.from_euler(Vector3(0.0, 0.0, -PI)), Vector3.ZERO)

func _enter_tree() -> void:
	# Match the reference GaussianSplatNode coordinate-system correction.
	if transform.basis.orthonormalized().is_equal_approx(Basis.IDENTITY):
		transform = transform * get_model_orientation_correction()

func _ready() -> void:
	_register()

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
	var manager = GaussianRenderManager.get_instance()
	if manager != null:
		manager.mark_resource_dirty(self)
