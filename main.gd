extends Control

## UI 控制器：持有【唯一】的 GameState 实例与 ScoreStore，
## 把格子点击转成内核调用，并把内核【结算后的最终状态】整体刷到界面。
##
## 本脚本不做任何游戏规则计算：匹配、连锁、计分、能量、复活全部由 GameState 决定；
## UI 也从不自行推测"点一次应该加多少分"，只负责显示 tap() 之后的状态。

const GS = preload("res://game_state.gd")
const ScoreStoreScript = preload("res://score_store.gd")

## 最高分存档路径。自动化测试可换成临时文件，避免污染真实存档。
var high_score_path: String = ScoreStoreScript.DEFAULT_PATH

var state                       # GameState（P0 纯逻辑内核）
var store                       # ScoreStore
var best_score: int = 0
var game_seed: int = 0

var _best_saved: bool = false
var _restart_count: int = 0
## 动画开关：自动化测试可关闭（关闭后点击立即结算并刷新，便于断言最终状态）。
var animations_enabled: bool = true
## 动画播放中：用于锁输入、延迟遮罩出现。
var _animating: bool = false
## 回合序号：重开或取消后递增，用于识别"已经过期的播放/等待"。
var _turn_generation: int = 0

@onready var board = $Root/Layout/BoardWrapper/BoardStack/Board
@onready var anim_layer = $Root/Layout/BoardWrapper/BoardStack/AnimLayer
@onready var score_label: Label = $Root/Layout/TopBar/ScoreLabel
@onready var best_label: Label = $Root/Layout/TopBar/BestLabel
@onready var energy_label: Label = $Root/Layout/TopBar/EnergyLabel
@onready var status_label: Label = $Root/Layout/BottomBar/StatusLabel
@onready var overlay: Control = $Overlay
@onready var overlay_title: Label = $Overlay/Center/Panel/Margin/Box/OverlayTitle
@onready var overlay_detail: Label = $Overlay/Center/Panel/Margin/Box/OverlayDetail
@onready var revive_button: Button = $Overlay/Center/Panel/Margin/Box/ReviveButton
@onready var give_up_button: Button = $Overlay/Center/Panel/Margin/Box/GiveUpButton
@onready var overlay_restart_button: Button = $Overlay/Center/Panel/Margin/Box/OverlayRestartButton


func _ready() -> void:
	store = ScoreStoreScript.new(high_score_path)
	best_score = store.load_best()
	anim_layer.board = board                 # 动画层只借用静态格子的几何，不碰规则
	board.tile_clicked.connect(_on_tile_clicked)
	start_new_game()


## 打开 / 关闭动画（自动化测试用）。
func set_animations_enabled(enabled: bool) -> void:
	animations_enabled = enabled


## 是否正在播放动画。
func is_animating() -> bool:
	return _animating


# ==================================================================== 一局的生命周期

## 开新一局。
## p_seed >= 0 时使用指定 seed（自动化测试用，完全可复现）；
## p_seed < 0 时自动取一个新 seed（玩家重开用，避免重复同一条随机序列）。
func start_new_game(p_seed: int = -1) -> void:
	_restart_count += 1
	game_seed = p_seed if p_seed >= 0 else _generate_seed()
	_turn_generation += 1                    # 让旧的播放与等待全部失效
	_animating = false
	if is_instance_valid(anim_layer):
		anim_layer.cancel_play()             # 立即解除等待并清理临时对象
		anim_layer.history = []
	state = GS.new(game_seed)
	_best_saved = false
	sync_ui()


## 替换最高分存档路径（自动化测试用）。
func use_score_store(p_path: String) -> void:
	high_score_path = p_path
	store = ScoreStoreScript.new(p_path)
	best_score = store.load_best()
	sync_ui()


## 把 GameState 的最终状态整体刷到界面 —— 这是唯一的刷新入口。
func sync_ui() -> void:
	if state == null:
		return
	if state.phase == GS.Phase.GAME_OVER:
		_save_best_once()               # 先落盘再刷新，保证"最高"显示的是最终值

	board.refresh(state.board)
	board.set_input_enabled(state.phase == GS.Phase.PLAYING)
	score_label.text = "分数 %d" % state.score
	best_label.text = "最高 %d" % best_score
	energy_label.text = "%s  %d/%d" % [_energy_text(state.energy), state.energy, GS.ENERGY_MAX]
	status_label.text = _status_text()
	_update_overlay()


# ==================================================================== 输入

func _on_tile_clicked(row: int, col: int) -> void:
	if state == null or _animating:
		return                          # 动画播放期间拒绝新的棋盘输入
	if state.phase != GS.Phase.PLAYING:
		return                          # 与内核一致：只有 PLAYING 接受棋盘输入
	state.tap(row, col)                 # 内核一次性完成全部规则结算，并记录动画事件

	if animations_enabled and not state.events.is_empty() and is_instance_valid(anim_layer):
		_turn_generation += 1
		var turn := _turn_generation
		_animating = true
		board.set_input_enabled(false)  # 动画期间锁住棋盘
		await _await_play(state.events)
		if turn != _turn_generation:
			return                      # 本次播放已过期（被取消 / 被新局取代）：不碰新局的 UI
		_animating = false
	sync_ui()                           # 动画全部结束后才刷新最终棋盘与遮罩


## 播放动画并等待其结束。
##
## 关键：这里**不 await 动画层的协程** —— 那样一旦动画层被释放，等待方就永远醒不过来。
## 改为轮询 is_playing()：正常完成、被取消、动画层被移出场景树或被释放，
## 三种情况都能可靠退出，不会留下挂起的协程或永久锁死的输入。
func _await_play(events: Array) -> void:
	if not is_instance_valid(anim_layer) or not anim_layer.is_inside_tree():
		return
	anim_layer.begin_play(events)
	var tree := get_tree()
	while is_instance_valid(anim_layer) and anim_layer.is_inside_tree() and anim_layer.is_playing():
		if tree == null or not is_inside_tree():
			break
		await tree.process_frame


func _on_restart_pressed() -> void:
	if _animating:
		return                          # 动画期间不允许重开
	start_new_game()


func _on_revive_pressed() -> void:
	if _animating:
		return                          # 动画期间不允许复活
	if state == null or state.phase != GS.Phase.REVIVE_PROMPT:
		return
	if not state.revive():               # 能量与复活次数只能由内核改写
		return
	sync_ui()


func _on_give_up_pressed() -> void:
	if _animating:
		return                          # 动画期间不允许结束本局
	if state == null or state.phase != GS.Phase.REVIVE_PROMPT:
		return
	if not state.give_up():
		return
	sync_ui()


# ==================================================================== 界面文本

func _energy_text(energy: int) -> String:
	var text := ""
	for i in GS.ENERGY_MAX:
		text += ("♥" if i < energy else "♡")
	return text


func _status_text() -> String:
	match state.phase:
		GS.Phase.PLAYING:
			return "点击数字方块使其 +1（消耗 1 点能量）；横竖三连及以上自动合成"
		GS.Phase.REVIVE_PROMPT:
			return "能量耗尽：可以复活一次，或结束本局"
		GS.Phase.GAME_OVER:
			return "本局结束"
		GS.Phase.ERROR:
			return "结算异常：已停止接受操作"
	return ""


func _update_overlay() -> void:
	match state.phase:
		GS.Phase.PLAYING:
			overlay.visible = false
		GS.Phase.REVIVE_PROMPT:
			overlay_title.text = "能量耗尽"
			overlay_detail.text = "本局得分 %d\n历史最高 %d\n剩余复活次数 %d" % [state.score, best_score, state.revive_left]
			revive_button.visible = state.revive_left > 0
			give_up_button.visible = true
			overlay_restart_button.visible = false
			overlay.visible = true
		GS.Phase.GAME_OVER:
			overlay_title.text = "游戏结束"
			overlay_detail.text = "本局得分 %d\n历史最高 %d" % [state.score, best_score]
			revive_button.visible = false
			give_up_button.visible = false
			overlay_restart_button.visible = true
			overlay.visible = true
		GS.Phase.ERROR:
			overlay_title.text = "结算异常（ERROR）"
			overlay_detail.text = "%s\n\n棋盘状态不可信，已停止接受操作。" % state.error_message
			revive_button.visible = false
			give_up_button.visible = false
			overlay_restart_button.visible = true
			overlay.visible = true


# ==================================================================== 最高分

## 只在真正进入 GAME_OVER 时写盘一次；REVIVE_PROMPT 不算本局结束。
func _save_best_once() -> void:
	if _best_saved:
		return
	_best_saved = true
	if state.score > best_score:
		if store.save_best(state.score):
			best_score = state.score
		else:
			best_score = store.load_best()      # 写盘失败时以磁盘为准


## 每次重开都换一个新 seed。
## 注意：这里只是"挑一个种子"；游戏内的随机补充仍然全部由 GameState.rng 产生。
func _generate_seed() -> int:
	return int(Time.get_ticks_usec()) + _restart_count * 7919
