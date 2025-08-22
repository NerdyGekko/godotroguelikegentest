# dungeon_generator.gd
extends Node2D
class_name Dungeon1D

# --- Params ---
@export var width: int = 9
@export var height: int = 8
@export var level: int = 1                           # Used for Isaac-style room count
@export var cell_px: int = 64
@export var genSeed: int = 0

# Growth knobs
@export var expand_chance: float = 0.5               # 50%: chance a neighbor gets added
@export var requeue_period: int = 6                  # if rooms target > 16, re-seed start every N pops

# Types
enum CellType { Empty = -1, Normal = 0, Start = 1, Boss = 2, Item = 3 }

var cells: Array = []
var start_i := -1
var boss_i  := -1
var item_i  := -1

var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_seed()
	generate()
	queue_redraw()

func _seed() -> void:
	if genSeed == 0:
		_rng.randomize()
	else:
		_rng.seed = genSeed

# --- Helpers ---
func idx(x: int, y: int) -> int: return y * width + x
func xy(i: int) -> Vector2i: return Vector2i(i % width, i / width)
func in_bounds_xy(x: int, y: int) -> bool: return x >= 0 and x < width and y >= 0 and y < height
func in_bounds_i(i: int) -> bool:
	var p := xy(i)
	return in_bounds_xy(p.x, p.y)

func neighbours(i: int) -> Array[int]:
	var p := xy(i)
	var out: Array[int] = []
	if p.y > 0: out.append(i - width)           # up
	if p.y < height - 1: out.append(i + width)  # down
	if p.x > 0: out.append(i - 1)               # left
	if p.x < width - 1: out.append(i + 1)       # right
	return out

func filled_neighbour_count(i: int) -> int:
	var c := 0
	for n in neighbours(i):
		if cells[n] != CellType.Empty:
			c += 1
	return c

func grid_center_index() -> int:
	return idx(width / 2, height / 2)

# --- Isaac floorplan ---
func _target_room_count() -> int:
	# random(2) + 5 + level * 2.6  (rounding to nearest int)
	var base := (_rng.randi() % 2) + 5
	return int(round(level * 2.6)) + base

func generate() -> void:
	# Try a few times to satisfy constraints (boss not adjacent to start, right room count)
	var max_attempts := 50
	for attempt in range(max_attempts):
		if _try_generate_once():
			return
	# If all else fails, at least draw *something*
	push_warning("Dungeon generation consistency checks failed after many attempts; using last attempt.")
	queue_redraw()

func _try_generate_once() -> bool:
	# clear
	cells.resize(width * height)
	for i in range(cells.size()):
		cells[i] = CellType.Empty
	start_i = -1
	boss_i  = -1
	item_i  = -1

	var center := grid_center_index()
	if not in_bounds_i(center):
		center = idx(clamp(width / 2, 0, width-1), clamp(height / 2, 0, height-1))

	var target_rooms := _target_room_count()
	var ok := _grow_bfs(center, target_rooms)
	if not ok:
		return false

	# specials (Isaac-style):
	# Start at center (or nearest filled if center somehow empty)
	start_i = center if cells[center] != CellType.Empty else _nearest_filled_to(center)
	if start_i == -1:
		return false
	cells[start_i] = CellType.Start

	# Build end_rooms during growth; grab it
	var end_rooms: Array[int] = _end_rooms_cached
	# Remove start if it sneaked in
	end_rooms = end_rooms.filter(func(i): return i != start_i and cells[i] != CellType.Empty)

	# Boss = LAST end room encountered (furthest by outward growth)
	if end_rooms.is_empty():
		return false
	boss_i = end_rooms.back()
	# Consistency: Boss cannot be adjacent to Start; if true, fail & redo
	if neighbours(boss_i).has(start_i):
		return false
	cells[boss_i] = CellType.Boss

	# Item = random end room (excluding start/boss)
	var pool := end_rooms.duplicate()
	pool = pool.filter(func(i): return i != boss_i and i != start_i)
	if pool.is_empty():
		# fallback: any non-empty, excluding start/boss, that is a dead end right now
		for i in range(cells.size()):
			if i != start_i and i != boss_i and cells[i] != CellType.Empty and filled_neighbour_count(i) == 1:
				pool.append(i)
	if pool.is_empty():
		return false
	item_i = pool[_rng.randi_range(0, pool.size()-1)]
	cells[item_i] = CellType.Item

	# final count check
	var count := 0
	for v in cells:
		if v != CellType.Empty: count += 1
	if abs(count - target_rooms) > 0:
		# If we over- or under-shot because of blocking rules, just accept close fits,
		# but you can require exact match by returning false here.
		pass

	queue_redraw()
	return true

# Cached during growth (processing-time dead ends)
var _end_rooms_cached: Array[int] = []

func _grow_bfs(start_index: int, target_count: int) -> bool:
	_end_rooms_cached.clear()

	# seed start
	cells[start_index] = CellType.Normal
	var placed := 1

	var q: Array[int] = [start_index]
	var pops := 0

	while not q.is_empty() and placed < target_count:
		var cur: int = q.pop_front()
		pops += 1

		var dirs := neighbours(cur)
		dirs.shuffle()

		var expanded_any := false
		for n in dirs:
			if placed >= target_count:
				break
			if cells[n] != CellType.Empty:
				continue
			# 50% chance gate
			if _rng.randf() > expand_chance:
				continue
			# Isaac rule: don't place if this neighbor would have >1 filled neighbors (prevents loops)
			var touching := 0
			for nn in neighbours(n):
				if cells[nn] != CellType.Empty:
					touching += 1
			if touching >= 2:
				continue

			# place room
			cells[n] = CellType.Normal
			q.append(n)
			placed += 1
			expanded_any = true

		# If this node didn't expand at all when processed, it's a "dead end" by the algorithm's notion
		if not expanded_any:
			# avoid dupes
			if not _end_rooms_cached.has(cur):
				_end_rooms_cached.append(cur)

		# Encourage growth when many rooms needed: reseed start periodically
		if target_count > 16 and (pops % max(requeue_period, 1) == 0):
			q.append(start_index)

	return placed >= max(1, min(target_count, width * height))

func _nearest_filled_to(target_i: int) -> int:
	var best := -1
	var best_d := 1e9
	for i in range(cells.size()):
		if cells[i] == CellType.Empty: continue
		var d := _manhattan(i, target_i)
		if d < best_d:
			best = i
			best_d = d
	return best

func _manhattan(a: int, b: int) -> int:
	var pa := xy(a); var pb := xy(b)
	return abs(pa.x - pb.x) + abs(pa.y - pb.y)

# --- Drawing (unchanged styling) ---
func _draw() -> void:
	# bg grid
	for y in range(height):
		for x in range(width):
			var r := Rect2(Vector2(x*cell_px, y*cell_px), Vector2(cell_px, cell_px))
			draw_rect(r, Color(0,0,0,0.08), false, 1.0)

	for i in range(cells.size()):
		var t: int = cells[i]
		if t == CellType.Empty: continue
		var p := xy(i)
		var rect := Rect2(Vector2(p.x*cell_px, p.y*cell_px), Vector2(cell_px, cell_px))
		var col := Color(0.18, 0.22, 0.28)
		match t:
			CellType.Start: col = Color(0.2, 0.7, 0.3)
			CellType.Boss:  col = Color(0.75, 0.2, 0.2)
			CellType.Item:  col = Color(0.9, 0.8, 0.25)
		draw_rect(rect, col, true)
		draw_rect(rect, Color(1,1,1,0.25), false, 1.0)

		# door notches (for visual connectivity)
		var cx := rect.position.x + rect.size.x / 2.0
		var cy := rect.position.y + rect.size.y / 2.0
		var notch := cell_px * 0.15
		for n in neighbours(i):
			if cells[n] == CellType.Empty: continue
			var np := xy(n)
			if np.y == p.y - 1:
				draw_line(Vector2(cx, rect.position.y), Vector2(cx, rect.position.y + notch), Color.WHITE, 2.0)
			elif np.y == p.y + 1:
				draw_line(Vector2(cx, rect.position.y + rect.size.y), Vector2(cx, rect.position.y + rect.size.y - notch), Color.WHITE, 2.0)
			elif np.x == p.x - 1:
				draw_line(Vector2(rect.position.x, cy), Vector2(rect.position.x + notch, cy), Color.WHITE, 2.0)
			elif np.x == p.x + 1:
				draw_line(Vector2(rect.position.x + rect.size.x, cy), Vector2(rect.position.x + rect.size.x - notch, cy), Color.WHITE, 2.0)
