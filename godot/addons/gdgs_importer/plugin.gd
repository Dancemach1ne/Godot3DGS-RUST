@tool
extends EditorPlugin

const StandardPlyImporter = preload("res://addons/gdgs_importer/standard_ply_importer.gd")
var importer: EditorImportPlugin

func _enter_tree() -> void:
	importer = StandardPlyImporter.new()
	add_import_plugin(importer)

func _exit_tree() -> void:
	remove_import_plugin(importer)
