extends Node2D
@onready var d: Dungeon1D = $Dungeon

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.is_pressed():
		match event.keycode:
			KEY_R:
				d.generate()
				d.queue_redraw()
			KEY_N:
				d.genSeed = 0
				d._seed()
				d.generate()
				d.queue_redraw()
			KEY_ESCAPE:
				get_tree().quit()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		print("Key pressed: ", event.keycode)
