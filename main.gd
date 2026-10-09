extends Control

var number: int = 0

@onready var number_label: Label = $CenterContainer/VBoxContainer/NumberLabel


func _ready() -> void:
	number_label.text = str(number)


func _on_plus_one_button_pressed() -> void:
	number += 1
	number_label.text = str(number)
