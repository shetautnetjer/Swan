extends CharacterBody2D

@export var speed: float = 200.0
var health := 100

func _physics_process(delta):
	var dir = Input.get_axis("ui_left", "ui_right")
	velocity.x = dir * speed
	move_and_slide()

func hit(damage: int) -> void:
	health -= damage
	print("health ", health)
	if health <= 0:
		queue_free()
