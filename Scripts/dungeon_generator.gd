extends Node2D

class_name Dungeon1D

# Parameters
@export var width: int = 10
@export var height: int = 10
@export var min_rooms: int = 8
@export var max_rooms: int = 14
@export var branching: float =0.5 #Between 0 and 1, the higher the value the bushy the dungeon will look like
@export var genSeed: int = 0 # Seed for random generation
@export var cell_px: int = 64

# Cell Types
enum CellType{ Empty = -1, Normal = 0, Start = 1, Boss = 2, Item = 3}

var cells: Array = [] #Length of this == width*height
var start_i: int = -1
var boss_i: int = -1
var item_i: int = -1
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_seed()
	generate()
	queue_redraw()

func _seed() -> void:
	if genSeed == 0: _rng.randomize()
	else: _rng.seed = genSeed

# Helper Functions
func idx(x: int, y: int) -> int:
	return y * width + x

func xy(i: int) -> Vector2i:
	return Vector2i(i % width, i / width)

func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and x < width and y >= 0 and y < height

func neighbours(i: int) -> Array[int]:
	var p := xy(i)
	var out: Array[int] = []
	if p.y > 0: out.append(i - width) #up
	if p.y < height -1: out.append(i + width) #down
	if p.x > 0: out.append(i - 1) #left
	if p.x < width - 1: out.append(i + 1) #right
	return out

# Compute degree quickly (you already have _degree(i)).
# Keep the neighbor on the path back to start, remove all other branches.
func _ensure_dead_end(i: int, start_index: int) -> void:
	if i == -1 or cells[i] == CellType.Empty:
		return
	if _degree(i) <= 1:
		return

	# Choose the neighbor closest to start to KEEP (so we don't cut Start off).
	var keep_n := _neighbor_closest_to(i, start_index)
	for n in neighbours(i):
		if n == keep_n: 
			continue
		if cells[n] != CellType.Empty:
			_remove_branch(i, n)  # delete everything reachable through n, without crossing back through i

# Pick neighbor with smallest (estimated) distance to start.
# Manhattan works well on this 4-connected grid; if you want exact graph distance later,
# replace with a BFS distance map.
func _neighbor_closest_to(i: int, start_index: int) -> int:
	var best := -1
	var best_d := 1_000_000
	for n in neighbours(i):
		if cells[n] == CellType.Empty: 
			continue
		var d := _manhattan(n, start_index)
		if d < best_d:
			best = n
			best_d = d
	return best

# Remove the whole branch that lies "beyond" (from_i -> via_n), without crossing back through from_i.
func _remove_branch(from_i: int, via_n: int) -> void:
	var stack: Array[int] = [via_n]
	var visited := {}
	visited[ from_i ] = true  # acts as a hard boundary: don't cross back through the special room
	while not stack.is_empty():
		var cur: int = stack.pop_back()
		if visited.has(cur):
			continue
		visited[cur] = true

		# Delete this room.
		if cells[cur] != CellType.Empty:
			cells[cur] = CellType.Empty

		# Flood outward, but never step back through 'from_i'.
		for nn in neighbours(cur):
			if visited.has(nn):
				continue
			if cells[nn] == CellType.Empty:
				continue
			# Don't step back through the pivot room.
			if nn == from_i:
				continue
			stack.push_back(nn)

# Generation Algorithm
func generate() -> void:
	#initialize cell array to EMPTY
	cells.resize(width * height)
	for i in range(cells.size()): cells[i] = CellType.Empty

	# Grow the dungeon layout, starting from center cell
	var center := idx(width / 2, height / 2)
	var target := _rng.randi_range(min_rooms, max_rooms)
	_grow(center, target)

	# Place Special rooms
	_place_special_rooms(center)

func _grow(start_index: int, target_count: int) -> void:
	var queue: Array[int] = []
	cells[start_index] = CellType.Normal
	queue.append(start_index)

	while _filled_count() < target_count and queue.size() > 0:
		var pick := _rng.randi_range(0, queue.size()-1) if _rng.randf() < branching else queue.size() - 1
		var current := queue[pick]
		queue.remove_at(pick)

		var nb := neighbours(current)
		nb.shuffle()

		var expanded := false
		for n in nb:
			if cells[n] == CellType.Empty:
				cells[n] = CellType.Normal
				queue.append(n)
				expanded = true
				if _filled_count() >= target_count:
					break
		
		if not expanded and _rng.randf() < 0.35:
			queue.append(current) # Reinsert if no expansion happened

func _place_special_rooms(center: int) -> void:
	# Start
	start_i = center if cells[center] != CellType.Empty else _nearest_filled_to(center)
	if start_i != -1:
		cells[start_i] = CellType.Start

	# Collect true dead ends, excluding Start
	var dead_ends: Array[int] = []
	for i in range(cells.size()):
		if cells[i] != CellType.Empty and i != start_i and _degree(i) == 1:
			dead_ends.append(i)

	# If we somehow have zero dead ends, force one and refresh the list.
	if dead_ends.is_empty():
		var any_room := _nearest_filled_to(center)
		if any_room != -1 and any_room != start_i:
			_ensure_dead_end(any_room, start_i)
		# Rebuild dead ends after pruning
		dead_ends.clear()
		for i in range(cells.size()):
			if cells[i] != CellType.Empty and i != start_i and _degree(i) == 1:
				dead_ends.append(i)

	# --- Boss: farthest TRUE dead end from Start ---
	boss_i = _farthest_from(start_i, dead_ends)
	if boss_i != -1:
		_ensure_dead_end(boss_i, start_i)  # guarantee degree==1 (no-op if already)
		cells[boss_i] = CellType.Boss

	# --- Item: farthest TRUE dead end excluding Start & Boss ---
	var candidates: Array[int] = []
	for i in dead_ends:
		if i != boss_i and i != start_i:
			candidates.append(i)

	# If that still leaves no candidate, force another dead end and try again.
	if candidates.is_empty():
		# pick a far room that's not Start/Boss, then prune it into a dead end
		var far_pick := -1
		var best_d := -1
		for i in range(cells.size()):
			if cells[i] != CellType.Empty and i != start_i and i != boss_i:
				var d := _manhattan(start_i, i)
				if d > best_d:
					best_d = d
					far_pick = i
		if far_pick != -1:
			_ensure_dead_end(far_pick, start_i)

		# Rebuild candidates strictly from degree==1 cells
		candidates.clear()
		for i in range(cells.size()):
			if cells[i] != CellType.Empty and i != start_i and i != boss_i and _degree(i) == 1:
				candidates.append(i)

	item_i = _farthest_from(start_i, candidates)
	if item_i != -1:
		_ensure_dead_end(item_i, start_i)  # guarantee degree==1
		cells[item_i] = CellType.Item
	
func _filled_count() -> int:
	var count := 0
	for cell in cells:
		if cell != CellType.Empty:
			count += 1
	return count

func _degree(i: int) -> int:
	var d := 0
	for n in neighbours(i):
		if cells[n] != CellType.Empty:
			d += 1
	return d

func _manhattan(a: int, b: int) -> int:
	var pa := xy(a)
	var pb := xy(b)
	return abs(pa.x - pb.x) + abs(pa.y - pb.y)

func _nearest_filled_to(target_i: int) -> int:
	var best   := -1
	var best_d := 1e9
	for i in range(cells.size()):
		if cells[i] == CellType.Empty: continue
		var d := _manhattan(i, target_i)
		if d < best_d: best = i; best_d = d
	return best

func _farthest_from(origin_i: int, arr: Array[int]) -> int:
	if arr.is_empty():
		return -1
	var best   := arr[0]
	var best_d := -1
	for i in arr:
		var d := _manhattan(origin_i, i)
		if d > best_d:
			best = i
			best_d = d
	return best

# Minimap Rendering
func _draw() -> void:
	# Background
	for y in range(height):
		for x in range(width):
			var r := Rect2(Vector2(x*cell_px, y*cell_px), Vector2(cell_px, cell_px))
			draw_rect(r, Color(0,0,0,0.1), false, 1.0)
	
	#cells + Door Nottches
	for i in range(cells.size()):
		if cells[i] == CellType.Empty: continue
		var p := xy(i)
		var rect := Rect2(Vector2(p.x*cell_px, p.y*cell_px), Vector2(cell_px, cell_px))
		var col := Color(0.18, 0.22, 0.28)
		match cells[i]:
			CellType.Start: col = Color(0.2, 0.7, 0.3)
			CellType.Boss: col = Color(0.75, 0.2, 0.2)
			CellType.Item: col = Color(0.9, 0.8, 0.25)
		draw_rect(rect, col, true)
		draw_rect(rect, Color(1,1,1,0.25), false, 1.0)

		# Draw door notches
		var cx := rect.position.x + rect.size.x / 2
		var cy := rect.position.y + rect.size.y / 2
		var notch := cell_px * 0.15
		for n in neighbours(i):
			if cells[n] == CellType.Empty: continue
			var np := xy(n)
			if np.y == p.y - 1: draw_line(Vector2(cx, rect.position.y), Vector2(cx, rect.position.y + notch), Color.WHITE, 2.0) # Up
			elif np.y == p.y + 1: draw_line(Vector2(cx, rect.position.y + rect.size.y), Vector2(cx, rect.position.y + rect.size.y - notch), Color.WHITE, 2.0) # Down
			elif np.x == p.x - 1: draw_line(Vector2(rect.position.x, cy), Vector2(rect.position.x + notch, cy), Color.WHITE, 2.0) # Left
			elif np.x == p.x + 1: draw_line(Vector2(rect.position.x + rect.size.x, cy), Vector2(rect.position.x + rect.size.x - notch, cy), Color.WHITE, 2.0) # Right
