extends Button

## 单个格子视图：只负责"显示一个数字"和"把点击翻译成行列坐标"。
##
## 本脚本绝不修改分数、能量、棋盘数值或随机数状态；
## 所有规则判定都由 GameState 完成。

const GS = preload("res://game_state.gd")

## 本格被点击（行列坐标即 GameState 的坐标）。
signal tile_clicked(row: int, col: int)

var row: int = 0
var col: int = 0
var value: int = GS.EMPTY

var _font_size: int = 0


func setup(p_row: int, p_col: int) -> void:
	row = p_row
	col = p_col
	name = "Tile_%d_%d" % [p_row, p_col]
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	# clip_text 让按钮的最小尺寸不再随文字长度增长，避免 4 位数把棋盘撑大
	clip_text = true
	focus_mode = Control.FOCUS_NONE
	if not pressed.is_connected(_on_pressed):
		pressed.connect(_on_pressed)
	set_value(GS.EMPTY)


## 设置本格显示的数字（GS.EMPTY 表示空格）。
func set_value(p_value: int) -> void:
	value = p_value
	if value == GS.EMPTY:
		text = ""
		# 空格不接受鼠标输入：连按下反馈都不给，也不消耗任何状态
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	else:
		text = str(value)
		mouse_filter = Control.MOUSE_FILTER_STOP
	_update_font_size()


## 动画期间隐藏 / 恢复该静态格子（避免与覆盖层里的移动方块同时出现）。
func set_ghosted(hidden: bool) -> void:
	modulate.a = 0.0 if hidden else 1.0


func _on_pressed() -> void:
	tile_clicked.emit(row, col)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_font_size()


## 字号随格子尺寸自适应，保证 3~4 位数也不会溢出格子。
func _update_font_size() -> void:
	var target := int(clamp(size.x * 0.34, 10.0, 56.0))
	if target != _font_size:
		_font_size = target
		add_theme_font_size_override("font_size", target)
