extends Button

## 单个格子视图：只负责"显示一个数字"和"把点击翻译成行列坐标"。
##
## 本脚本绝不修改分数、能量、棋盘数值或随机数状态；
## 所有规则判定都由 GameState 完成。
##
## 视觉规则（全项目唯一来源）：
##   - 底色 → color_for(value)：1~5 手工调色，>5 按规律色阶推导（任何整数都有确定颜色）
##   - 文字 → text_color_for(bg)：按底色相对亮度挑选，保证对比度
##   - 字号 → font_size_for(格子边长, 位数)：随格子缩放并按位数收缩，3~4 位也不溢出
##   - 圆角/边框 → _box()：静态缓存，悬停/按下/禁用只是同一底色的明暗变化
## 动画层（anim_layer.gd）直接实例化本脚本，因此临时方块自动共用同一套规则，
## 不存在"两份调色表"的问题。

const GS = preload("res://game_state.gd")

## 本格被点击（行列坐标即 GameState 的坐标）。
signal tile_clicked(row: int, col: int)

const CORNER_RADIUS := 12
const BORDER_WIDTH := 2
const FONT_DARK := Color("14161a")
const FONT_LIGHT := Color("f7f9fc")
## 底色相对亮度的上限：低于它时白色文字对比度一定 >= 4.5（WCAG AA 正文标准）。
const WHITE_TEXT_MAX_LUMINANCE := 0.165
const MIN_CONTRAST := 4.5

## 1~5 的手工调色：色相彼此拉开（最小间隔 >= 0.10 圈），避免"靠细微色差区分"。
const BASE_COLORS := {
	1: Color("3f6fa8"),   # 蓝
	2: Color("2f8f7a"),   # 青绿
	3: Color("c08a2e"),   # 琥珀
	4: Color("b23a3a"),   # 红
	5: Color("7a5aa8"),   # 紫
}

var row: int = 0
var col: int = 0
## 初次 setup 之前用 -1 作为哨兵，保证第一次 set_value 一定会套用样式。
var value: int = -1

var _font_size: int = 0

static var _box_cache: Dictionary = {}
static var _empty_box: StyleBoxEmpty = null


# ==================================================================== 共享视觉规则（静态，供测试与动画层核对）

## 数值对应的方块底色。1~5 用手工调色；>5 用"色相按固定角度推进 + 明度逐级加深"的色阶，
## 因此任意整数（含很大的值）都能得到确定且有效的颜色，不存在数组越界或无效样式。
## 所有底色都会经过 _readable_bg()：保证文字对比度达标，同时保留各自色相。
static func color_for(value: int) -> Color:
	if value <= GS.EMPTY:
		return Color(0, 0, 0, 0)                 # 空格：完全透明
	if BASE_COLORS.has(value):
		return _readable_bg(BASE_COLORS[value])
	var step := value - 5
	var hue := fposmod(0.11 + 0.13 * step, 1.0)  # 相邻数值色相差距大，容易区分
	var sat := clampf(0.50 + 0.04 * (step % 3), 0.44, 0.62)
	var val := clampf(0.76 - 0.045 * step, 0.40, 0.80)
	return _readable_bg(Color.from_hsv(hue, sat, val))


## 把底色压到"白色文字对比度达标"的亮度范围。
## 逐次变暗是确定的（最多 24 次），且 darkened() 不会改变色相，因此颜色仍然彼此可辨。
static func _readable_bg(c: Color) -> Color:
	var out := c
	var guard := 0
	while _luminance(out) > WHITE_TEXT_MAX_LUMINANCE and guard < 24:
		out = out.darkened(0.05)
		guard += 1
	return out


## WCAG 相对亮度。
static func _luminance(c: Color) -> float:
	return 0.2126 * _channel(c.r) + 0.7152 * _channel(c.g) + 0.0722 * _channel(c.b)


static func _channel(v: float) -> float:
	if v <= 0.03928:
		return v / 12.92
	return pow((v + 0.055) / 1.055, 2.4)


## 在给定底色上挑一个对比度更高的文字颜色（不手写反色表）。
static func text_color_for(bg: Color) -> Color:
	if contrast_ratio(FONT_LIGHT, bg) >= contrast_ratio(FONT_DARK, bg):
		return FONT_LIGHT
	return FONT_DARK


## 两个颜色的对比度（用于测试断言"文字清晰可读"）。
static func contrast_ratio(a: Color, b: Color) -> float:
	var la := _luminance(a)
	var lb := _luminance(b)
	var hi := maxf(la, lb)
	var lo := minf(la, lb)
	return (hi + 0.05) / (lo + 0.05)


## 字号规则：随格子边长缩放，并按数字位数收缩（3 位数与 4 位数都能放下）。
static func font_size_for(cell: float, digits: int) -> int:
	var base := clampf(cell * 0.34, 10.0, 56.0)
	if digits == 2:
		base *= 0.86
	elif digits == 3:
		base *= 0.66
	elif digits >= 4:
		base *= 0.52
	return int(maxf(10.0, base))


## 降低饱和度（Godot 4 的 Color 没有 desaturated()，用 HSV 往返实现）。
static func _desaturate(c: Color, amount: float) -> Color:
	return Color.from_hsv(c.h, clampf(c.s * (1.0 - amount), 0.0, 1.0), c.v, c.a)


## 某个状态的底色：明暗与饱和度的小幅变化 + 同样的可读性钳制（因此每个状态都清晰可读）。
static func state_background(bg: Color, state: String) -> Color:
	match state:
		"hover":
			return _readable_bg(_desaturate(bg, 0.15).lightened(0.10))
		"pressed":
			return _readable_bg(_desaturate(bg, 0.05).darkened(0.16))
		"disabled":
			return _readable_bg(_desaturate(bg, 0.55).darkened(0.30))
	return bg


## 某个状态的边框色：悬停时明显提亮，按下/禁用时收敛（状态差异清楚但克制）。
static func state_border(bg: Color, state: String) -> Color:
	match state:
		"hover":
			return bg.lightened(0.55)
		"pressed":
			return bg.lightened(0.12)
		"disabled":
			return bg.lightened(0.10)
	return bg.lightened(0.22)


static func _box(bg: Color, border: Color) -> StyleBoxFlat:
	var key := bg.to_html(false) + "/" + border.to_html(false)
	if _box_cache.has(key):
		return _box_cache[key]
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left = CORNER_RADIUS
	sb.corner_radius_top_right = CORNER_RADIUS
	sb.corner_radius_bottom_left = CORNER_RADIUS
	sb.corner_radius_bottom_right = CORNER_RADIUS
	sb.border_width_left = BORDER_WIDTH
	sb.border_width_top = BORDER_WIDTH
	sb.border_width_right = BORDER_WIDTH
	sb.border_width_bottom = BORDER_WIDTH
	sb.border_color = border
	sb.anti_aliasing = true
	_box_cache[key] = sb
	return sb


static func _empty() -> StyleBoxEmpty:
	if _empty_box == null:
		_empty_box = StyleBoxEmpty.new()
	return _empty_box


# ==================================================================== 生命周期

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


## 设置本格显示的数字（GS.EMPTY 表示空格）。只影响渲染，不触碰任何游戏状态。
func set_value(p_value: int) -> void:
	value = p_value
	if value == GS.EMPTY:
		text = ""
		# 空格不接受鼠标输入：连按下反馈都不给，也不消耗任何状态
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	else:
		text = str(value)
		mouse_filter = Control.MOUSE_FILTER_STOP
	_apply_style()
	_update_font_size()


## 动画期间隐藏 / 恢复该静态格子（避免与覆盖层里的移动方块同时出现）。
func set_ghosted(hidden: bool) -> void:
	modulate.a = 0.0 if hidden else 1.0


## 恢复动画可能改动过的可视状态（透明度 / 缩放）并按当前数值重新套用样式。
## 取消、重开、动画结束都会走这里，保证不留视觉残留。
func reset_visual_state() -> void:
	modulate.a = 1.0
	scale = Vector2.ONE
	_apply_style()
	_update_font_size()


## 当前数值"普通状态"的底色（供测试与动画层核对静态/临时方块是否同色）。
func background_color() -> Color:
	return color_for(value)


## 某个状态下的实际底色（空字符串状态返回透明）。
func stylebox_color(state: String) -> Color:
	var sb := get_theme_stylebox(state)
	if sb is StyleBoxFlat:
		return sb.bg_color
	return Color(0, 0, 0, 0)


func _on_pressed() -> void:
	tile_clicked.emit(row, col)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_font_size()


# ==================================================================== 内部

func _apply_style() -> void:
	if value == GS.EMPTY:
		var e := _empty()
		for state in ["normal", "hover", "pressed", "disabled", "focus"]:
			add_theme_stylebox_override(state, e)
		return
	var bg := color_for(value)
	for state in ["normal", "hover", "pressed", "disabled"]:
		var sb_bg := state_background(bg, state)
		add_theme_stylebox_override(state, _box(sb_bg, state_border(sb_bg, state)))
		add_theme_color_override(_font_color_key(state), text_color_for(sb_bg))
	var hover_bg := state_background(bg, "hover")
	add_theme_stylebox_override("focus", _box(hover_bg, state_border(hover_bg, "hover")))
	add_theme_color_override("font_focus_color", text_color_for(hover_bg))


static func _font_color_key(state: String) -> String:
	if state == "normal":
		return "font_color"
	return "font_%s_color" % state


## 字号随格子尺寸与数字位数自适应，保证 3~4 位数也不会溢出格子。
func _update_font_size() -> void:
	var digits := 0 if value == GS.EMPTY else str(value).length()
	var target := font_size_for(size.x, digits)
	if target != _font_size:
		_font_size = target
		add_theme_font_size_override("font_size", target)
