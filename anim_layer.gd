extends Control

## 动画覆盖层（P2）：只把【逻辑内核给出的事件】画成移动中的临时方块。
##
## 职责边界：
##   - 不计算任何游戏规则（哪些方块合并、结果数值、重力目标、补充数值全部来自 GameState）
##   - 不产生随机数、不修改 GameState、不修改静态棋盘的格子数据（只调用 board.refresh(快照)）
##   - 只做一件事：把事件里的坐标/数值翻译成位置动画
##
## 静态棋盘仍由 GridContainer(board.gd) 负责布局；本层是独立的 Control，
## 因此临时方块可以直接用 position 做 Tween，不会被容器重新排版。
##
## 时序用 SceneTree 定时器驱动，Tween 只负责画面插值：
## 这样即使中途清理了临时对象，播放协程也一定会结束，不会挂起。

const GS = preload("res://game_state.gd")
const TileViewScript = preload("res://tile_view.gd")

# ---------------------------------------------------------------- 动画参数（集中管理）
const TAP_PULSE := 0.14              # 点击后方块脉冲
const MERGE_CONVERGE := 0.36         # 区域内方块汇聚到目标格
const MERGE_FADE := 0.08             # 非目标方块消失
const MERGE_RESULT := 0.14           # 目标格数字 +1 与脉冲
const GRAVITY_BASE := 0.22           # 重力下落基准时长
const GRAVITY_PER_ROW := 0.035       # 每多落一行增加的时间
const GRAVITY_MAX := 0.35            # 重力下落时长上限
const REFILL_DROP := 0.28            # 顶部新方块落入时长
const TARGET_PULSE_SCALE := 1.10
const RESULT_PULSE_SCALE := 1.18

## 时长整体缩放（自动化测试可调小以加速；不影响任何逻辑结果）。
var time_scale: float = 1.0

## 本次点击播放过的步骤记录（供自动化测试核对顺序、坐标与数值）。
var history: Array = []

## 静态棋盘节点（board.gd），由 main.gd 在 _ready 注入。
var board = null

# ---------------------------------------------------------------- 播放状态 / 取消机制
## 播放正常结束时发出（携带本次播放序号）。被取消时不发。
signal play_finished(generation: int)
## 播放被取消时发出（携带被取消的播放序号）。正常完成时不发。
signal play_canceled(generation: int)

var _generation: int = 0      # 播放序号：每次 begin_play 递增
var _playing: bool = false    # 是否有播放正在进行
var _canceled: bool = false   # 当前播放是否已被取消
var _tweens: Array = []       # 本次播放创建的全部 Tween（取消时统一 kill）


func _ready() -> void:
	# 覆盖层不拦截输入，避免挡住棋盘的点击
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _exit_tree() -> void:
	# 节点退出场景树：立即终止播放并清理，不依赖任何仍然存活的 UI 节点，
	# 也不发射信号（树正在拆除时发信号不安全）。
	_abort()


# ==================================================================== 对外入口

## 启动一次播放（非协程，立即返回播放序号）。
## 播放由 _run_play 驱动；结束方式只有两种：play_finished（正常）或 play_canceled（被取消）。
## 调用方应当用 is_playing() 轮询或监听信号来等待，而**不要** await 本对象上的协程
## —— 那样一旦本节点被释放，等待方就再也醒不过来。
func begin_play(events: Array) -> int:
	cancel_play()                      # 若上一次还在播，先把它取消掉
	_generation += 1
	_canceled = false
	_playing = true
	_run_play(events, _generation)
	return _generation


## 取消当前播放：立即标记失效、kill 全部 Tween、清理临时方块、恢复静态格子。
## 返回是否确实取消了正在进行的播放（重复调用不会重复发信号、不会重复清理）。
func cancel_play() -> bool:
	if not _playing:
		return false
	var canceled_generation := _generation
	_canceled = true
	_playing = false
	_kill_tweens()
	clear_ghosts()
	if board != null and is_instance_valid(board):
		_show_all_static()
	# 注意：不清空 history —— 它记录"已经播过什么"，是取消后排查问题的依据；
	# 每次 begin_play / 重开新局时才会重置。
	play_canceled.emit(canceled_generation)
	return true


func is_playing() -> bool:
	return _playing


func current_generation() -> int:
	return _generation


## 中止播放但**不发射任何信号**（退出场景树等拆除场景使用）。
func _abort() -> void:
	_canceled = true
	_playing = false
	_kill_tweens()
	clear_ghosts()
	if board != null and is_instance_valid(board):
		_show_all_static()


## 当前这一步是否仍属于有效的播放：
## 未被取消、没有被新的播放取代、并且仍然在场景树里。
func _is_current(generation: int) -> bool:
	return _playing and not _canceled and generation == _generation and is_inside_tree()


func _run_play(events: Array, generation: int) -> void:
	await play_events(events, generation)
	if not _is_current(generation):
		return                         # 已被取消 / 已被新播放取代：不发完成信号
	_playing = false
	play_finished.emit(generation)


## 依次播放一次点击产生的全部事件。
## 每个异步阶段恢复后都会重新检查 generation，旧动画绝不会继续修改新棋盘的 UI。
func play_events(events: Array, generation: int) -> void:
	clear_ghosts()
	_show_all_static()
	history = []
	for ev in events:
		if not _is_current(generation):
			return
		match ev.kind:
			"tap":
				await _play_tap(ev, generation)
			"merge":
				await _play_merge(ev, generation)
			"gravity":
				await _play_gravity(ev, generation)
			"refill":
				await _play_refill(ev, generation)
			_:
				pass                       # settled / error：没有可播放的画面
	if not _is_current(generation):
		return
	clear_ghosts()
	_show_all_static()


func ghost_count() -> int:
	return get_child_count()


func clear_ghosts() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()


# ==================================================================== 几何 / 临时对象

## 某个棋盘格在覆盖层坐标系里的矩形（与静态棋盘格子完全对齐）。
func cell_rect(index: int) -> Rect2:
	if board == null:
		return Rect2()
	var tile = board.tile_at(index / GS.BOARD_N, index % GS.BOARD_N)
	if tile == null:
		return Rect2()
	return Rect2(tile.global_position - global_position, tile.size)


func _make_ghost(index: int, value: int, rect: Rect2):
	var ghost = TileViewScript.new()
	add_child(ghost)
	ghost.setup(index / GS.BOARD_N, index % GS.BOARD_N)
	ghost.position = rect.position
	ghost.size = rect.size
	ghost.pivot_offset = rect.size * 0.5
	ghost.set_value(value)
	ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 临时方块绝不接收输入
	return ghost


func _hide_static(index: int) -> void:
	var tile = _tile(index)
	if tile != null:
		tile.set_ghosted(true)


func _show_all_static() -> void:
	if board == null:
		return
	for i in GS.CELL_COUNT:
		var tile = _tile(i)
		if tile != null:
			tile.set_ghosted(false)
			tile.scale = Vector2.ONE


func _tile(index: int):
	if board == null:
		return null
	return board.tile_at(index / GS.BOARD_N, index % GS.BOARD_N)


## 等待 duration 秒。返回 false 表示"这次播放已经失效"（被取消 / 离开场景树）。
##
## 关键：这里**不等待任何 Tween 的 finished 信号**，而是每帧检查取消标志。
## 因此 Tween 被 kill、目标节点被释放、甚至整层被移出场景树，等待都能可靠结束，
## 不会出现"协程永远等不到信号"的挂起。
func _wait(duration: float) -> bool:
	if _canceled or not is_inside_tree():
		return false
	var tree := get_tree()
	if tree == null:
		return false
	if duration <= 0.0:
		return true
	var deadline := Time.get_ticks_msec() + int(round(duration * 1000.0))
	while Time.get_ticks_msec() < deadline:
		if _canceled or not is_inside_tree():
			return false
		await tree.process_frame
	return not _canceled and is_inside_tree()


## 登记一条 Tween，供取消时统一 kill。
func _track(t: Tween) -> Tween:
	var alive: Array = []
	for old in _tweens:
		if is_instance_valid(old) and old.is_valid():
			alive.append(old)
	_tweens = alive
	_tweens.append(t)
	return t


func _kill_tweens() -> void:
	for t in _tweens:
		if is_instance_valid(t):
			t.kill()
	_tweens = []


func _pulse(node, peak: float, duration: float) -> void:
	if not is_instance_valid(node):
		return
	var t := create_tween()
	t.tween_property(node, "scale", Vector2(peak, peak), duration * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	t.tween_property(node, "scale", Vector2.ONE, duration * 0.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_track(t)


# ==================================================================== 各阶段播放

## 被点击方块数字 +1（静态棋盘立即更新，并给该格一个脉冲）。
func _play_tap(ev: Dictionary, generation: int) -> void:
	if not _is_current(generation):
		return
	board.refresh(ev.board_after)
	var tile = _tile(ev.index)
	if tile == null:
		return
	tile.pivot_offset = tile.size * 0.5
	history.append({"kind": "tap", "index": ev.index, "value": ev.value})
	var duration := TAP_PULSE * time_scale
	_pulse(tile, 1.12, duration)
	var finished: bool = await _wait(duration)
	if not finished or not _is_current(generation):
		return
	if is_instance_valid(tile):
		tile.scale = Vector2.ONE


## 同一轮的所有连通区域并行汇聚：区域内所有方块移向目标格，非目标方块随后消失。
func _play_merge(ev: Dictionary, generation: int) -> void:
	if not _is_current(generation):
		return
	board.refresh(ev.board_before)
	var rec := {
		"kind": "merge",
		"round": ev.round,
		"region_count": ev.regions.size(),
		"ghosts": 0,
		"targets": [],
		"results": [],
		"converge": [],
	}
	var other_ghosts: Array = []
	var target_ghosts: Array = []

	for reg in ev.regions:
		var target_rect := cell_rect(reg.target)
		rec.targets.append(reg.target)
		rec.results.append(reg.value + 1)
		for idx in reg.cells:
			var from_rect := cell_rect(idx)
			_hide_static(idx)
			var ghost = _make_ghost(idx, reg.value, from_rect)
			rec.ghosts += 1
			rec.converge.append({
				"from": idx, "to": reg.target, "value": reg.value,
				"from_pos": from_rect.position, "to_pos": target_rect.position,
			})
			if idx == reg.target:
				target_ghosts.append(ghost)
				_pulse(ghost, TARGET_PULSE_SCALE, MERGE_CONVERGE * time_scale)
			else:
				other_ghosts.append(ghost)
				var t := create_tween()
				t.tween_property(ghost, "position", target_rect.position, MERGE_CONVERGE * time_scale)
				t.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
				_track(t)
	history.append(rec)

	# ① 汇聚
	var converged: bool = await _wait(MERGE_CONVERGE * time_scale)
	if not converged or not _is_current(generation):
		return

	# ② 非目标方块淡出并移除
	for g in other_ghosts:
		if is_instance_valid(g):
			var t := create_tween()
			t.tween_property(g, "modulate:a", 0.0, MERGE_FADE * time_scale)
			_track(t)
	var faded: bool = await _wait(MERGE_FADE * time_scale)
	if not faded or not _is_current(generation):
		return
	for g in other_ghosts:
		if is_instance_valid(g) and g.get_parent() == self:
			remove_child(g)
			g.queue_free()

	# ③ 目标格显示唯一的合并结果（数值 +1）并脉冲
	for i in target_ghosts.size():
		target_ghosts[i].set_value(rec.results[i])
		_pulse(target_ghosts[i], RESULT_PULSE_SCALE, MERGE_RESULT * time_scale)
	var pulsed: bool = await _wait(MERGE_RESULT * time_scale)
	if not pulsed or not _is_current(generation):
		return

	clear_ghosts()
	_show_all_static()
	board.refresh(ev.board_after)


## 重力：需要移动的方块从原格滑到目标格，距离越长时间略长。
func _play_gravity(ev: Dictionary, generation: int) -> void:
	if not _is_current(generation):
		return
	board.refresh(ev.board_before)
	var rec := {"kind": "gravity", "round": ev.round, "moved": ev.moves.size(), "moves": []}
	history.append(rec)
	if ev.moves.is_empty():
		return                              # 没有需要移动的方块 → 不播放多余动画

	var longest := 0.0
	for mv in ev.moves:
		var from_rect := cell_rect(mv["from"])
		var to_rect := cell_rect(mv["to"])
		_hide_static(mv["from"])
		var ghost = _make_ghost(mv["from"], mv["value"], from_rect)
		var rows: int = absi((mv["to"] / GS.BOARD_N) - (mv["from"] / GS.BOARD_N))
		var duration: float = clampf(GRAVITY_BASE + GRAVITY_PER_ROW * rows, GRAVITY_BASE, GRAVITY_MAX) * time_scale
		if duration > longest:
			longest = duration
		rec.moves.append({
			"from": mv["from"], "to": mv["to"], "value": mv["value"],
			"from_pos": from_rect.position, "to_pos": to_rect.position,
		})
		var t := create_tween()
		t.tween_property(ghost, "position", to_rect.position, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_track(t)

	var fallen: bool = await _wait(longest)
	if not fallen or not _is_current(generation):
		return
	clear_ghosts()
	_show_all_static()
	board.refresh(ev.board_after)


## 顶部补充：新方块从棋盘上方落入各自目标格；同一列多个方块等距叠放、同时抵达。
func _play_refill(ev: Dictionary, generation: int) -> void:
	if not _is_current(generation):
		return
	board.refresh(ev.board_before)
	var rec := {"kind": "refill", "round": ev.round, "spawns": []}
	history.append(rec)
	if ev.spawns.is_empty():
		return

	# 每列的空位数（= 该列新方块数），用于把方块等距叠在棋盘上方
	var per_col := {}
	for sp in ev.spawns:
		var col: int = int(sp["index"]) % GS.BOARD_N
		per_col[col] = per_col.get(col, 0) + 1

	for sp in ev.spawns:
		var idx: int = sp["index"]
		var col: int = idx % GS.BOARD_N
		var target_rect := cell_rect(idx)
		var start_pos := Vector2(target_rect.position.x,
			target_rect.position.y - target_rect.size.y * float(per_col[col]))
		var ghost = _make_ghost(idx, sp["value"], target_rect)
		ghost.position = start_pos
		rec.spawns.append({
			"index": idx, "value": sp["value"],
			"start_pos": start_pos, "to_pos": target_rect.position,
		})
		var t := create_tween()
		t.tween_property(ghost, "position", target_rect.position, REFILL_DROP * time_scale)
		t.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_track(t)

	var dropped: bool = await _wait(REFILL_DROP * time_scale)
	if not dropped or not _is_current(generation):
		return
	clear_ghosts()
	board.refresh(ev.board_after)
