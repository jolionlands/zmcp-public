extends SceneTree
# zmcp-godot scene operations (Godot 4). Run headless:
#   godot --headless --path <project> --script ops.gd -- <operation> <json-params>
# Prints exactly one result line: "ZMCP_RESULT {json}" and quits (0 ok, 1 error).

const PREFIX := "ZMCP_RESULT "

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		_fail("usage: <operation> <json>")
		return
	var parsed = JSON.parse_string(args[1])
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("params must be a JSON object")
		return
	var p: Dictionary = parsed
	match args[0]:
		"create_scene": _create_scene(p)
		"add_node": _add_node(p)
		"load_sprite": _load_sprite(p)
		"save_scene": _save_scene(p)
		"export_mesh_library": _export_mesh_library(p)
		"get_uid": _get_uid(p)
		"update_uids": _update_uids()
		_: _fail("unknown operation: " + str(args[0]))

func _ok(data: Dictionary = {}) -> void:
	data["ok"] = true
	print(PREFIX + JSON.stringify(data))
	quit(0)

func _fail(msg: String) -> void:
	print(PREFIX + JSON.stringify({"ok": false, "error": msg}))
	quit(1)

func _load_scene(path: String) -> Node:
	if not ResourceLoader.exists(path):
		_fail("scene not found: " + path)
		return null
	var res = load(path)
	if not (res is PackedScene):
		_fail("not a scene: " + path)
		return null
	return (res as PackedScene).instantiate()

func _store(root: Node, path: String) -> bool:
	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err != OK:
		_fail("pack failed: " + str(err))
		return false
	err = ResourceSaver.save(packed, path)
	if err != OK:
		_fail("save failed: " + str(err))
		return false
	return true

func _find(root: Node, path: String) -> Node:
	if path == "" or path == "root" or path == ".":
		return root
	if path.begins_with("root/"):
		path = path.substr(5)
	return root.get_node_or_null(path)

func _coerce(v):
	# Strings such as "Vector2(1, 2)" or "Color(1,0,0)" become Godot values.
	if typeof(v) == TYPE_STRING:
		var s: String = v
		if s.contains("(") and s.ends_with(")"):
			var r = str_to_var(s)
			if r != null and typeof(r) != TYPE_OBJECT:
				return r
	return v

func _create_scene(p: Dictionary) -> void:
	var type: String = p.get("root_type", "Node2D")
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "Node"):
		_fail("invalid root node type: " + type)
		return
	var root: Node = ClassDB.instantiate(type)
	root.name = "root"
	if _store(root, p["scene_path"]):
		_ok({"scene": p["scene_path"], "root_type": type})

func _add_node(p: Dictionary) -> void:
	var root := _load_scene(p["scene_path"])
	if root == null:
		return
	var type: String = p["node_type"]
	if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "Node"):
		_fail("invalid node type: " + type)
		return
	var parent := _find(root, p.get("parent_path", "root"))
	if parent == null:
		_fail("parent not found: " + str(p.get("parent_path")))
		return
	var node: Node = ClassDB.instantiate(type)
	node.name = p["node_name"]
	var props: Dictionary = p.get("properties", {})
	for k in props:
		node.set(k, _coerce(props[k]))
	parent.add_child(node)
	node.owner = root
	if _store(root, p["scene_path"]):
		_ok({"node": str(root.get_path_to(node))})

func _load_sprite(p: Dictionary) -> void:
	var root := _load_scene(p["scene_path"])
	if root == null:
		return
	var node := _find(root, p["node_path"])
	if node == null:
		_fail("node not found: " + str(p["node_path"]))
		return
	if not (node is Sprite2D or node is Sprite3D or node is TextureRect):
		_fail("node is not Sprite2D/Sprite3D/TextureRect")
		return
	var tex = load(p["texture_path"])
	if not (tex is Texture2D):
		_fail("texture not found: " + str(p["texture_path"]))
		return
	node.texture = tex
	if _store(root, p["scene_path"]):
		_ok()

func _save_scene(p: Dictionary) -> void:
	var root := _load_scene(p["scene_path"])
	if root == null:
		return
	var dest: String = p.get("new_path", p["scene_path"])
	if _store(root, dest):
		_ok({"saved": dest})

func _collect_meshes(n: Node, out: Array) -> void:
	if n is MeshInstance3D and n.mesh != null:
		out.append(n)
	for c in n.get_children():
		_collect_meshes(c, out)

func _export_mesh_library(p: Dictionary) -> void:
	var root := _load_scene(p["scene_path"])
	if root == null:
		return
	var found := []
	_collect_meshes(root, found)
	var only: Array = p.get("mesh_item_names", [])
	var lib := MeshLibrary.new()
	var i := 0
	for m in found:
		if only.size() > 0 and not (m.name in only):
			continue
		lib.create_item(i)
		lib.set_item_name(i, m.name)
		lib.set_item_mesh(i, m.mesh)
		i += 1
	if i == 0:
		_fail("no MeshInstance3D nodes exported")
		return
	var err := ResourceSaver.save(lib, p["output_path"])
	if err != OK:
		_fail("save failed: " + str(err))
		return
	_ok({"items": i, "output": p["output_path"]})

func _get_uid(p: Dictionary) -> void:
	var path: String = p["file_path"]
	if not FileAccess.file_exists(path):
		_fail("file not found: " + path)
		return
	var id := ResourceLoader.get_resource_uid(path)
	if id == ResourceUID.INVALID_ID:
		_ok({"uid": null})
		return
	_ok({"uid": ResourceUID.id_to_text(id)})

func _walk(dir: String, out: Array) -> void:
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() in ["tscn", "scn", "tres", "res"]:
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			_walk(dir.path_join(d), out)

func _update_uids() -> void:
	var files := []
	_walk("res://", files)
	var n := 0
	for f in files:
		var r = load(f)
		if r != null and ResourceSaver.save(r, f) == OK:
			n += 1
	_ok({"resaved": n, "total": files.size()})
