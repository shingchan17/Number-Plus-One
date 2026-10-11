extends SceneTree

## P1 UI 集成测试（headless）。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tests/test_ui.gd
## 退出码 0 = 全部通过；1 = 存在失败断言。
##
## 测试原则：UI 只允许显示 GameState 的最终状态，因此每个操作后都断言
## "25 个格子 + 分数 + 能量 + 最高分"与内核状态完全一致。

const GS = preload("res://game_state.gd")
const SS = preload("res://score_store.gd")
const TileViewScript = preload("res://tile_view.gd")

const TEST_SAVE_PATH := "user://test_ui_highscore.cfg"
const SEED := 20261010
const SINGLE_TILE_BOARD := "5 . . . .\n. . . . .\n. . . . .\n. . . . .\n. . . . ."
const EMPTY_ROWS := ". . . . .\n. . . . .\n. . . . .\n. . . . ."
const MERGE_FIXTURE := "2 2 1 . .\n" + EMPTY_ROWS
## 旧规则的"两轮连锁"夹具（5 行）：新规则下第一轮是玩家直接合成，结果保持 4，
## 底行变成 4,5,5 因此不再连锁 —— 用于锁定"玩家合成不再触发该连锁"这一行为变化。
const CHAIN_FIXTURE := "4 5 5 . .\n4 . . . .\n3 . . . .\n. . . . .\n. . . . ."
## 玩家直接合成 + 自动连锁：点击 (2,0) → 第一轮玩家合成（结果仍为 4）→ 重力后底行 4,4,4
## → 第二轮自动连锁（结果 5）→ 最终只剩 (4,0) = 5。
const PLAYER_CHAIN_FIXTURE := "4 . . . .\n4 . . . .\n3 . . . .\n. 4 4 . .\n. . . . ."

var _passed := 0
var _failed := 0
var _current := ""
var main


func _initialize() -> void:
	_run()


func _run() -> void:
	change_scene_to_file("res://main.tscn")
	await process_frame
	await process_frame
	await process_frame

	main = current_scene
	_current = "启动"
	_t("main scene loaded", main != null)
	if main == null:
		_finish()
		return
	_t("main scene ready", main.is_node_ready())
	_t("state is a GameState instance", main.state != null)

	# 既有用例验证的是"点击后的最终状态"，因此先关闭动画；
	# 动画专项验证放在 _test_animations() 里再打开（见文件末尾）。
	main.set_animations_enabled(false)

	# 换用测试存档，避免污染真实最高分
	_remove_test_save()
	main.use_score_store(TEST_SAVE_PATH)
	main.start_new_game(SEED)
	await process_frame

	await _test_structure()
	await _test_initial_sync()
	await _test_click_updates_state()
	await _test_empty_tile_rejected()
	await _test_chain_shows_final_board()
	await _test_player_merge_display()
	await _test_revive_flow()
	await _test_game_over_and_highscore()
	await _test_restart_flow()
	await _test_error_state()
	await _test_animations()
	await _test_visual_rules()
	await _test_animation_cancel()

	_remove_test_save()
	_finish()


# ==================================================================== 断言工具

func _section(name: String) -> void:
	_current = name
	print("-- ", name)


func _t(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		_passed += 1
	else:
		_failed += 1
		print("   FAIL [%s] %s%s" % [_current, label, "" if detail == "" else "  | " + detail])


func _eq_int(label: String, actual: int, expected: int) -> void:
	_t(label, actual == expected, "expected %d, got %d" % [expected, actual])


func _eq_str(label: String, actual: String, expected: String) -> void:
	_t(label, actual == expected, "expected '%s', got '%s'" % [expected, actual])


func _finish() -> void:
	print("")
	print("checks passed: %d, failed: %d" % [_passed, _failed])
	print("RESULT=", "PASS" if _failed == 0 else "FAIL")
	quit(0 if _failed == 0 else 1)


## 25 个格子文本 + 三个标签必须与内核状态一致。
func _check_ui_matches_state(tag: String) -> void:
	var board = main.board
	var st = main.state
	var mismatch := -1
	for i in GS.CELL_COUNT:
		var v: int = st.board[i]
		var expect: String = "" if v == GS.EMPTY else str(v)
		if board.get_child(i).text != expect:
			mismatch = i
			break
	_t("[%s] 25 tiles mirror GameState.board" % tag, mismatch == -1, "first mismatch at index %d" % mismatch)
	_eq_str("[%s] score label" % tag, main.score_label.text, "分数 %d" % st.score)
	_t("[%s] energy label" % tag, main.energy_label.text.ends_with("%d/%d" % [st.energy, GS.ENERGY_MAX]), main.energy_label.text)
	_eq_str("[%s] best label" % tag, main.best_label.text, "最高 %d" % main.best_score)
	var hearts := 0
	for ch in main.energy_label.text:
		if ch == "♥":
			hearts += 1
	_eq_int("[%s] filled hearts == energy" % tag, hearts, st.energy)


## 用场景输入管线做一次真实点击（按下 + 抬起），返回是否执行。
func _real_click(tile) -> bool:
	var rect: Rect2 = tile.get_global_rect()
	if rect.size.x < 4.0 or rect.size.y < 4.0:
		return false
	var pos: Vector2 = rect.get_center()
	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = pos
	down.global_position = pos
	root.push_input(down, true)
	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = pos
	up.global_position = pos
	root.push_input(up, true)
	return true


## 装载一个确定性棋盘（关闭随机补充，避免测试受随机影响）。
func _load_fixture(text: String, energy: int, score: int, revive_left: int) -> void:
	main.state.spawn_enabled = false
	main.state.set_board_from_text(text)
	main.state.energy = energy
	main.state.score = score
	main.state.revive_left = revive_left
	main.sync_ui()
	# 防呆：夹具必须真的落在棋盘上（行数写错时立刻暴露，避免用例在随机棋盘上"碰巧通过"）
	_eq_str("fixture applied", main.state.board_text(), text.strip_edges())


func _remove_test_save() -> void:
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists(TEST_SAVE_PATH.get_file()):
		dir.remove(TEST_SAVE_PATH.get_file())


# ==================================================================== 用例

func _test_structure() -> void:
	_section("主场景结构：25 个格子与行列映射")
	var board = main.board
	_t("board node exists", board != null)
	_eq_int("25 tiles created", board.tile_count(), 25)
	_eq_int("grid has 25 children", board.get_child_count(), 25)
	_eq_int("grid columns", board.columns, GS.BOARD_N)

	var mapping_ok := true
	var lookup_ok := true
	for i in GS.CELL_COUNT:
		var tile = board.get_child(i)
		if tile.row != i / GS.BOARD_N or tile.col != i % GS.BOARD_N:
			mapping_ok = false
		if board.tile_at(tile.row, tile.col) != tile:
			lookup_ok = false
	_t("row/col mapping matches child order", mapping_ok)
	_t("tile_at(row, col) returns the same node", lookup_ok)
	_t("tile_at out of bounds is null", board.tile_at(5, 0) == null and board.tile_at(0, -1) == null)
	_t("overlay hidden while PLAYING", main.overlay.visible == false)
	_t("status label exists", main.status_label.text != "")


func _test_initial_sync() -> void:
	_section("初始化：界面与 GameState 一致")
	_eq_int("phase is PLAYING", main.state.phase, GS.Phase.PLAYING)
	_eq_int("energy is 5", main.state.energy, GS.ENERGY_START)
	_eq_int("score is 0", main.state.score, 0)
	_eq_int("best starts at 0 (test save)", main.best_score, 0)
	_check_ui_matches_state("初始化")
	var full := true
	for i in GS.CELL_COUNT:
		if main.state.board[i] == GS.EMPTY:
			full = false
	_t("initial board is completely filled", full)


func _test_click_updates_state() -> void:
	_section("点击非空格：UI / 分数 / 能量与内核一致")

	_load_fixture(SINGLE_TILE_BOARD, 5, 0, 1)
	var tile = main.board.tile_at(0, 0)
	_eq_str("tile shows 5", tile.text, "5")

	# 真实输入管线点击
	var clicked: bool = _real_click(tile)
	await process_frame
	if clicked:
		_eq_int("[real click] kernel board", main.state.board[0], 6)
		_eq_int("[real click] energy", main.state.energy, 4)
		_eq_int("[real click] score", main.state.score, 0)
		_eq_str("[real click] tile text", tile.text, "6")
		_eq_int("[real click] phase", main.state.phase, GS.Phase.PLAYING)
		_check_ui_matches_state("真实点击后")
	else:
		print("   NOTE: 无头环境下格子尺寸为 0，跳过真实输入管线点击")

	# 直接触发按钮信号（等价于 Button.pressed）
	tile.pressed.emit()
	await process_frame
	_eq_int("signal click kernel board", main.state.board[0], 7)
	_eq_int("signal click energy", main.state.energy, 3)
	_check_ui_matches_state("信号点击后")


func _test_empty_tile_rejected() -> void:
	_section("空格：不接受有效输入")
	_load_fixture(SINGLE_TILE_BOARD, 5, 0, 1)
	var empty_tile = main.board.tile_at(0, 1)
	_eq_int("empty tile has IGNORE mouse filter", empty_tile.mouse_filter, Control.MOUSE_FILTER_IGNORE)
	_eq_str("empty tile shows no text", empty_tile.text, "")

	var sig: String = main.state.board_signature()
	var clicked: bool = _real_click(empty_tile)
	await process_frame
	if clicked:
		_eq_str("[real click] board unchanged", main.state.board_signature(), sig)
		_eq_int("[real click] energy unchanged", main.state.energy, 5)
		_eq_int("[real click] phase unchanged", main.state.phase, GS.Phase.PLAYING)

	empty_tile.pressed.emit()
	await process_frame
	_eq_str("board unchanged after forced signal", main.state.board_signature(), sig)
	_eq_int("energy unchanged after forced signal", main.state.energy, 5)
	_eq_int("score unchanged", main.state.score, 0)
	_check_ui_matches_state("空格点击后")


func _test_chain_shows_final_board() -> void:
	_section("连锁：界面显示结算完成后的最终棋盘（含重力下落）")
	# 新规则：纵列 4,4,4 含点击格 → 玩家直接合成，结果仍是 4 → 重力后底行 4,4,4
	# → 第二轮属于自动连锁（4 + 1 = 5）→ 最终只剩 (4,0) = 5
	_load_fixture(PLAYER_CHAIN_FIXTURE, 2, 0, 1)
	main.board.tile_at(2, 0).pressed.emit()
	await process_frame

	_eq_int("kernel board (4,0)", main.state.board[20], 5)
	_eq_int("kernel score 12 + 15", main.state.score, 27)
	_eq_int("kernel energy 2-1+2", main.state.energy, 3)
	_t("kernel board is stable", main.state.has_unresolved_matches() == false, main.state.board_text())
	_eq_int("tile (4,0) shows 5", main.board.tile_at(4, 0).value, 5)
	_eq_str("tile (4,0) text", main.board.tile_at(4, 0).text, "5")
	var leftovers := 0
	for i in GS.CELL_COUNT:
		if main.state.board[i] != GS.EMPTY:
			leftovers += 1
	_eq_int("only one tile remains", leftovers, 1)
	_check_ui_matches_state("连锁后")


func _test_player_merge_display() -> void:
	_section("玩家直接合成：界面显示的数字保持不变")
	main.start_new_game(SEED)
	_load_fixture(MERGE_FIXTURE, 5, 0, 1)
	main.board.tile_at(0, 2).pressed.emit()
	await process_frame

	# 点击 1 → 2，与左侧两个 2 合并；玩家直接参与 ⇒ 结果仍是 2
	_eq_int("kernel result stays 2", main.state.board[20], 2)
	_eq_int("kernel score 2 * 3", main.state.score, 6)
	_eq_int("kernel energy 5-1+1", main.state.energy, 5)
	_eq_int("tile value is 2", main.board.tile_at(4, 0).value, 2)
	_eq_str("tile text is 2", main.board.tile_at(4, 0).text, "2")
	_eq_int("only one tile left", main.state.tile_count(), 1)
	_check_ui_matches_state("玩家直接合成后")


func _test_revive_flow() -> void:
	_section("REVIVE_PROMPT：复活 / 结束本局")
	_load_fixture(SINGLE_TILE_BOARD, 1, 40, 1)
	main.board.tile_at(0, 0).pressed.emit()
	await process_frame

	_eq_int("energy exhausted", main.state.energy, 0)
	_eq_int("phase is REVIVE_PROMPT", main.state.phase, GS.Phase.REVIVE_PROMPT)
	_t("overlay visible", main.overlay.visible == true)
	_eq_str("overlay title", main.overlay_title.text, "能量耗尽")
	_t("revive button visible", main.revive_button.visible == true)
	_t("give-up button visible", main.give_up_button.visible == true)
	_t("restart button hidden in prompt", main.overlay_restart_button.visible == false)
	_t("board input disabled", main.board.tile_at(0, 0).disabled == true)

	var sig: String = main.state.board_signature()
	main.board.tile_at(0, 0).pressed.emit()          # 提示期间不得改变任何状态
	await process_frame
	_eq_str("board frozen during prompt", main.state.board_signature(), sig)
	_eq_int("energy still 0", main.state.energy, 0)
	_eq_int("phase still REVIVE_PROMPT", main.state.phase, GS.Phase.REVIVE_PROMPT)

	var score_before: int = main.state.score
	main.revive_button.pressed.emit()
	await process_frame
	_eq_int("energy restored to 3", main.state.energy, GS.REVIVE_ENERGY)
	_eq_int("revive count consumed", main.state.revive_left, 0)
	_eq_int("phase back to PLAYING", main.state.phase, GS.Phase.PLAYING)
	_eq_str("board preserved by revive", main.state.board_signature(), sig)
	_eq_int("score preserved by revive", main.state.score, score_before)
	_t("overlay hidden after revive", main.overlay.visible == false)
	_t("board input re-enabled", main.board.tile_at(0, 0).disabled == false)
	_check_ui_matches_state("复活后")

	# 复活次数已用尽：再次耗尽 → 直接进入 GAME_OVER（不再询问）
	main.state.energy = 1
	main.sync_ui()
	main.board.tile_at(0, 0).pressed.emit()
	await process_frame
	_eq_int("second depletion goes straight to GAME_OVER", main.state.phase, GS.Phase.GAME_OVER)

	# 「结束本局」路径：新开一局（重新获得一次复活机会）
	main.start_new_game(SEED)
	_load_fixture(SINGLE_TILE_BOARD, 1, 11, 1)
	main.board.tile_at(0, 0).pressed.emit()
	await process_frame
	_eq_int("prompt shown before give up", main.state.phase, GS.Phase.REVIVE_PROMPT)
	main.give_up_button.pressed.emit()
	await process_frame
	_eq_int("give up → GAME_OVER", main.state.phase, GS.Phase.GAME_OVER)
	_eq_str("game over title", main.overlay_title.text, "游戏结束")
	_t("detail shows give-up score", main.overlay_detail.text.contains("11"), main.overlay_detail.text)


func _test_game_over_and_highscore() -> void:
	_section("GAME_OVER：分数、最高分写盘与重新开始")
	main.start_new_game(SEED)          # 真实流程中 GAME_OVER 之后只能重开，这里保持一致
	_load_fixture(SINGLE_TILE_BOARD, 1, 777, 0)
	main.board.tile_at(0, 0).pressed.emit()
	await process_frame

	_eq_int("phase is GAME_OVER", main.state.phase, GS.Phase.GAME_OVER)
	_t("overlay visible", main.overlay.visible == true)
	_eq_str("overlay title", main.overlay_title.text, "游戏结束")
	_t("detail shows final score", main.overlay_detail.text.contains("777"), main.overlay_detail.text)
	_t("restart button visible", main.overlay_restart_button.visible == true)
	_t("revive button hidden", main.revive_button.visible == false)
	_t("board input disabled", main.board.tile_at(0, 0).disabled == true)
	_eq_int("best score updated in memory", main.best_score, 777)
	_eq_int("best score written via ScoreStore", main.store.load_best(), 777)
	var fresh = SS.new(TEST_SAVE_PATH)
	_eq_int("best score re-readable by a new ScoreStore", fresh.load_best(), 777)
	_check_ui_matches_state("游戏结束后")

	var frozen: String = main.state.board_signature()
	main.board.tile_at(0, 0).pressed.emit()
	await process_frame
	_eq_str("board frozen after GAME_OVER", main.state.board_signature(), frozen)
	_eq_int("phase stays GAME_OVER", main.state.phase, GS.Phase.GAME_OVER)


func _test_restart_flow() -> void:
	_section("重新开始：新 seed、最高分保留、棋盘重置")
	var old_seed: int = main.game_seed
	main.overlay_restart_button.pressed.emit()
	await process_frame

	_eq_int("phase back to PLAYING", main.state.phase, GS.Phase.PLAYING)
	_eq_int("score reset", main.state.score, 0)
	_eq_int("energy reset", main.state.energy, GS.ENERGY_START)
	_eq_int("revive reset", main.state.revive_left, GS.REVIVE_MAX)
	_eq_int("board refilled", main.state.tile_count(), GS.CELL_COUNT)
	_t("new board has no match", main.state.has_unresolved_matches() == false)
	_t("best score preserved after restart", main.best_score == 777, str(main.best_score))
	_eq_int("best score still on disk", main.store.load_best(), 777)
	_t("seed changed on restart", main.game_seed != old_seed, "%d vs %d" % [main.game_seed, old_seed])
	_t("overlay hidden", main.overlay.visible == false)
	_check_ui_matches_state("重新开始后")

	# 底部"重新开始"按钮同样有效
	var seed_2: int = main.game_seed
	main.get_node("Root/Layout/BottomBar/RestartButton").pressed.emit()
	await process_frame
	_t("bottom restart also reseeds", main.game_seed != seed_2, "%d vs %d" % [main.game_seed, seed_2])
	_eq_int("still PLAYING after bottom restart", main.state.phase, GS.Phase.PLAYING)
	_eq_int("best still preserved", main.best_score, 777)


func _test_error_state() -> void:
	_section("ERROR：显示错误信息并停止接受操作")
	main.start_new_game(SEED)
	_load_fixture(PLAYER_CHAIN_FIXTURE, 3, 0, 1)
	main.state.max_chain_steps = 1                  # 逼出连锁上限异常（该夹具确定有 2 轮）
	main.board.tile_at(2, 0).pressed.emit()
	await process_frame

	_eq_int("phase is ERROR", main.state.phase, GS.Phase.ERROR)
	_t("overlay visible", main.overlay.visible == true)
	_t("title mentions ERROR", main.overlay_title.text.contains("ERROR"), main.overlay_title.text)
	_t("detail shows error_message", main.overlay_detail.text.contains(main.state.error_message), main.overlay_detail.text)
	_t("board input disabled", main.board.tile_at(0, 0).disabled == true)
	_t("board not auto-repaired", main.state.has_unresolved_matches() == true)

	var frozen: String = main.state.board_signature()
	var score_frozen: int = main.state.score
	main.board.tile_at(0, 0).pressed.emit()
	main.board.tile_at(2, 0).pressed.emit()
	await process_frame
	_eq_str("board frozen in ERROR", main.state.board_signature(), frozen)
	_eq_int("score frozen in ERROR", main.state.score, score_frozen)
	_eq_int("phase stays ERROR", main.state.phase, GS.Phase.ERROR)

	# 允许玩家显式重开（不修改出错的棋盘）
	main.overlay_restart_button.pressed.emit()
	await process_frame
	_eq_int("restart from ERROR works", main.state.phase, GS.Phase.PLAYING)
	_eq_int("fresh board after restart", main.state.tile_count(), GS.CELL_COUNT)


# ==================================================================== P2 动画专项

func _history(kind: String) -> Array:
	var out: Array = []
	for h in main.anim_layer.history:
		if h.kind == kind:
			out.append(h)
	return out


func _history_count(kind: String) -> int:
	return _history(kind).size()


func _history_kinds() -> String:
	var parts := PackedStringArray()
	for h in main.anim_layer.history:
		parts.append(str(h.kind))
	return ",".join(parts)


## 验证播放顺序严格是 tap, (merge, gravity, refill) × N —— 每一轮都完整走完才进入下一轮。
func _steps_sequential() -> bool:
	var kinds := PackedStringArray()
	for h in main.anim_layer.history:
		kinds.append(str(h.kind))
	if kinds.size() == 0 or kinds[0] != "tap":
		return false
	var i := 1
	while i < kinds.size():
		if i + 2 >= kinds.size():
			return false                    # 出现不完整的轮次
		if kinds[i] != "merge" or kinds[i + 1] != "gravity" or kinds[i + 2] != "refill":
			return false
		i += 3
	return true


func _await_animation(timeout_frames: int = 20000) -> void:
	var frames := 0
	while main.is_animating() and frames < timeout_frames:
		await process_frame
		frames += 1
	_t("animation finished within timeout", main.is_animating() == false, "frames=%d" % frames)


func _check_no_leftovers(tag: String) -> void:
	_eq_int("[%s] no temporary ghost nodes left" % tag, main.anim_layer.ghost_count(), 0)
	var visible := true
	var unscaled := true
	for i in GS.CELL_COUNT:
		var tile = main.board.tile_at(i / GS.BOARD_N, i % GS.BOARD_N)
		if tile.modulate.a < 0.999:
			visible = false
		if tile.scale != Vector2.ONE:
			unscaled = false
	_t("[%s] every static tile visible again" % tag, visible)
	_t("[%s] every static tile scale restored" % tag, unscaled)


## 把动画层实际使用的坐标/数值，逐项与逻辑内核记录的事件对照。
func _check_anim_matches_kernel(tag: String) -> void:
	var ev_merges: Array = []
	var ev_gravs: Array = []
	var ev_refills: Array = []
	for ev in main.state.events:
		match ev.kind:
			"merge": ev_merges.append(ev)
			"gravity": ev_gravs.append(ev)
			"refill": ev_refills.append(ev)
	var h_merges := _history("merge")
	var h_gravs := _history("gravity")
	var h_refills := _history("refill")
	_eq_int("[%s] merge steps == kernel rounds" % tag, h_merges.size(), ev_merges.size())
	_eq_int("[%s] gravity steps == kernel rounds" % tag, h_gravs.size(), ev_gravs.size())
	_eq_int("[%s] refill steps == kernel rounds" % tag, h_refills.size(), ev_refills.size())

	var n := h_merges.size()
	if ev_merges.size() < n:
		n = ev_merges.size()
	var merge_ok := true
	var results_ok := true
	var flags_ok := true
	for i in n:
		var h = h_merges[i]
		var ev = ev_merges[i]
		var expect_ghosts := 0
		var expect_results: Array = []
		var expect_flags: Array = []
		for reg in ev.regions:
			expect_ghosts += reg.size
			expect_results.append(reg.result_value)
			expect_flags.append(reg.player_merge)
			for idx in reg.cells:
				var found := false
				for cvg in h.converge:
					if cvg["from"] == idx and cvg["to"] == reg.target and cvg["value"] == reg.value:
						found = true
						if cvg["from_pos"] != main.anim_layer.cell_rect(idx).position:
							merge_ok = false
						if cvg["to_pos"] != main.anim_layer.cell_rect(reg.target).position:
							merge_ok = false
				if not found:
					merge_ok = false
		if h.ghosts != expect_ghosts:
			merge_ok = false
		# 动画显示的结果数字必须逐项等于内核 result_value（UI 不得自行 value + 1）
		if str(h.results) != str(expect_results):
			results_ok = false
		if str(h.player_merge) != str(expect_flags):
			flags_ok = false
	_t("[%s] every region cell converges to its kernel target" % tag, merge_ok)
	_t("[%s] animated result values equal kernel result_value" % tag, results_ok)
	_t("[%s] player_merge flags match the kernel" % tag, flags_ok)

	var g := h_gravs.size()
	if ev_gravs.size() < g:
		g = ev_gravs.size()
	var gravity_ok := true
	for i in g:
		var h = h_gravs[i]
		var ev = ev_gravs[i]
		if h.moves.size() != ev.moves.size():
			gravity_ok = false
		else:
			for j in ev.moves.size():
				var mv = ev.moves[j]
				var hm = h.moves[j]
				if hm["from"] != mv["from"] or hm["to"] != mv["to"] or hm["value"] != mv["value"]:
					gravity_ok = false
				if hm["from_pos"] != main.anim_layer.cell_rect(mv["from"]).position:
					gravity_ok = false
				if hm["to_pos"] != main.anim_layer.cell_rect(mv["to"]).position:
					gravity_ok = false
	_t("[%s] gravity source/target match kernel and cell rects" % tag, gravity_ok)

	var r := h_refills.size()
	if ev_refills.size() < r:
		r = ev_refills.size()
	var refill_ok := true
	for i in r:
		var h = h_refills[i]
		var ev = ev_refills[i]
		if h.spawns.size() != ev.spawns.size():
			refill_ok = false
		else:
			for j in ev.spawns.size():
				var sp = ev.spawns[j]
				var hs = h.spawns[j]
				if hs["index"] != sp["index"] or hs["value"] != sp["value"]:
					refill_ok = false
				if hs["to_pos"] != main.anim_layer.cell_rect(sp["index"]).position:
					refill_ok = false
				if hs["start_pos"].y >= hs["to_pos"].y:
					refill_ok = false          # 必须从棋盘上方落入
	_t("[%s] refill values/positions match kernel" % tag, refill_ok)


func _test_animations() -> void:
	_section("P2 动画：逐阶段播放、输入锁定、临时对象清理")
	main.set_animations_enabled(true)
	main.anim_layer.time_scale = 0.15      # 只核对顺序与坐标，不核对真实时长

	# ---- 1) 无合并的点击：不播放虚假的合并动画
	main.start_new_game(SEED)
	_load_fixture(SINGLE_TILE_BOARD, 5, 0, 1)
	main.board.tile_at(0, 0).pressed.emit()
	_t("is_animating right after the click", main.is_animating() == true)
	_t("board input locked during animation", main.board.tile_at(0, 0).disabled == true)
	await _await_animation()
	_eq_str("plain click plays only the tap step", _history_kinds(), "tap")
	_eq_int("no merge animation for a plain click", _history_count("merge"), 0)
	_eq_str("tile shows the tapped result", main.board.tile_at(0, 0).text, "6")
	_check_no_leftovers("无合并点击")
	_check_ui_matches_state("无合并点击后")

	# ---- 2) 三连汇聚：所有区域方块朝内核给出的目标格移动
	main.start_new_game(SEED)
	_load_fixture("2 2 1 . .\n" + EMPTY_ROWS, 5, 0, 1)
	main.board.tile_at(0, 2).pressed.emit()
	var waited := 0
	while main.anim_layer.ghost_count() == 0 and main.is_animating() and waited < 20000:
		await process_frame
		waited += 1
	_eq_int("three ghosts for a 3-cell region", main.anim_layer.ghost_count(), 3)
	var hidden := true
	for idx in [0, 1, 2]:
		if main.board.tile_at(0, idx).modulate.a > 0.001:
			hidden = false
	_t("static tiles of the region are hidden while ghosts move", hidden)
	await _await_animation()
	_eq_str("merge then gravity", _history_kinds(), "tap,merge,gravity")
	_check_anim_matches_kernel("三连")
	# 玩家直接参与：点击 1 → 2，三个 2 合并后数字保持 2
	_eq_int("kernel result fell to (4,0)", main.state.board[20], 2)
	_eq_int("tile (4,0) shows the unchanged value", main.board.tile_at(4, 0).value, 2)
	var m_hist := _history("merge")
	if m_hist.size() == 1:
		_eq_int("animated result is the player result", m_hist[0].results[0], 2)
		_t("player merge flagged in the animation history", m_hist[0].player_merge[0] == true)
		_t("converging ghosts show the matched value 2", m_hist[0].converge[0]["value"] == 2)
	_check_no_leftovers("三连+重力")
	_check_ui_matches_state("三连+重力后")

	# ---- 3) 顶部补充动画：数值与位置来自内核
	main.start_new_game(SEED)
	main.state.spawn_enabled = true
	main.state.set_board_from_text("2 2 1 . .\n" + EMPTY_ROWS)
	main.state.energy = 5
	main.state.score = 0
	main.sync_ui()
	main.board.tile_at(0, 2).pressed.emit()
	await _await_animation()
	_t("at least one merge round played", _history_count("merge") >= 1, _history_kinds())
	_eq_int("every round has a gravity step", _history_count("gravity"), _history_count("merge"))
	_eq_int("every round has a refill step", _history_count("refill"), _history_count("merge"))
	_t("steps are strictly per-round sequential", _steps_sequential(), _history_kinds())
	_check_anim_matches_kernel("补充")
	var spawn_total := 0
	var in_range := true
	var from_above := true
	for h in _history("refill"):
		spawn_total += h.spawns.size()
		for sp in h.spawns:
			if sp["value"] < GS.SPAWN_MIN or sp["value"] > GS.SPAWN_MAX:
				in_range = false
			if sp["start_pos"].y >= sp["to_pos"].y:
				from_above = false
	_t("refill steps generated tiles", spawn_total > 0, "spawns=%d" % spawn_total)
	_t("all refill values within {1..5}", in_range)
	_t("all refill tiles start above their target", from_above)
	_eq_int("board full after refill animation", main.state.tile_count(), GS.CELL_COUNT)
	_eq_int("phase still PLAYING after the chain", main.state.phase, GS.Phase.PLAYING)
	_check_no_leftovers("补充")
	_check_ui_matches_state("补充后")

	# ---- 4) 两轮连锁：第一轮玩家直接合成、第二轮自动连锁，必须逐轮播放
	main.start_new_game(SEED)
	_load_fixture(PLAYER_CHAIN_FIXTURE, 2, 0, 1)
	main.board.tile_at(2, 0).pressed.emit()
	await process_frame
	await process_frame
	_t("round 2 has not started before round 1 ends", _history_count("merge") <= 1, _history_kinds())
	await _await_animation()
	_eq_str("rounds played sequentially", _history_kinds(), "tap,merge,gravity,merge,gravity")
	_check_anim_matches_kernel("连锁")
	_eq_int("final kernel result", main.state.board[20], 5)
	_eq_int("score after chain (12 player + 15 auto)", main.state.score, 27)
	var h_merges := _history("merge")
	_eq_int("two merge rounds animated", h_merges.size(), 2)
	if h_merges.size() == 2:
		_eq_int("round 1 animates the player result (no +1)", h_merges[0].results[0], 4)
		_t("round 1 flagged player_merge", h_merges[0].player_merge[0] == true)
		_eq_int("round 2 animates the chained result (v + 1)", h_merges[1].results[0], 5)
		_t("round 2 NOT flagged player_merge", h_merges[1].player_merge[0] == false)
		_t("round 1 ghosts show the matched value 4", h_merges[0].converge[0]["value"] == 4)
		_t("round 2 ghosts show the matched value 4", h_merges[1].converge[0]["value"] == 4)
	_check_no_leftovers("连锁")
	_check_ui_matches_state("连锁后")

	# ---- 4b) 旧的两轮连锁夹具在新规则下只剩一轮（玩家合成结果不加一 ⇒ 不再触发连锁）
	main.start_new_game(SEED)
	_load_fixture(CHAIN_FIXTURE, 2, 0, 1)
	main.board.tile_at(2, 0).pressed.emit()
	await _await_animation()
	_eq_str("player merge no longer chains here", _history_kinds(), "tap,merge,gravity")
	_eq_int("row 4 keeps the untouched 5s", main.state.board[20], 4)
	_eq_int("score is the player result only (4 * 3)", main.state.score, 12)
	_check_ui_matches_state("旧夹具新规则")
	_check_no_leftovers("旧夹具新规则")

	# ---- 5) 动画期间的点击被忽略（不扣能量、不追加结算）
	main.start_new_game(SEED)
	_load_fixture("2 2 1 . .\n" + EMPTY_ROWS, 5, 0, 1)
	main.board.tile_at(0, 2).pressed.emit()
	var energy_after_tap: int = main.state.energy
	main.board.tile_at(0, 0).pressed.emit()
	main.board.tile_at(1, 1).pressed.emit()
	_eq_int("extra clicks during animation cost no energy", main.state.energy, energy_after_tap)
	_eq_int("only one tap step recorded", _history_count("tap"), 1)
	await _await_animation()
	_eq_int("still one tap step after the animation", _history_count("tap"), 1)
	_eq_int("score unchanged by the ignored clicks (player result 2 * 3)", main.state.score, 6)

	# ---- 6) 动画结束后可以继续正常点击
	_eq_int("phase still PLAYING", main.state.phase, GS.Phase.PLAYING)
	_t("board input re-enabled", main.board.tile_at(4, 0).disabled == false)
	var energy_before: int = main.state.energy
	main.board.tile_at(4, 0).pressed.emit()
	_eq_int("click after animation is accepted", main.state.energy, energy_before - 1)
	await _await_animation()
	_eq_int("the new turn played its own tap step", _history_count("tap"), 1)

	# ---- 7) REVIVE_PROMPT 延迟到动画结束
	main.start_new_game(SEED)
	_load_fixture(SINGLE_TILE_BOARD, 1, 40, 1)
	main.board.tile_at(0, 0).pressed.emit()
	_t("overlay hidden during animation", main.overlay.visible == false)
	await _await_animation()
	_eq_int("phase is REVIVE_PROMPT", main.state.phase, GS.Phase.REVIVE_PROMPT)
	_t("overlay visible after animation", main.overlay.visible == true)
	_check_no_leftovers("复活提示")

	# ---- 8) ERROR 也延迟到动画结束，且不自动修复棋盘
	main.start_new_game(SEED)
	_load_fixture(PLAYER_CHAIN_FIXTURE, 3, 0, 1)
	main.state.max_chain_steps = 1                  # 该夹具确定有 2 轮
	main.board.tile_at(2, 0).pressed.emit()
	_t("overlay hidden while animating", main.overlay.visible == false)
	await _await_animation()
	_eq_int("phase is ERROR", main.state.phase, GS.Phase.ERROR)
	_t("error overlay visible after animation", main.overlay.visible == true)
	_t("board not auto-repaired", main.state.has_unresolved_matches() == true)
	_check_no_leftovers("ERROR")
	main.state.max_chain_steps = GS.MAX_CHAIN_STEPS

	main.set_animations_enabled(false)


# ==================================================================== P2.1 取消机制

var _sig_finished := 0
var _sig_canceled := 0


func _on_play_finished(_generation: int) -> void:
	_sig_finished += 1


func _on_play_canceled(_generation: int) -> void:
	_sig_canceled += 1


## 每帧检查条件是否成立（不使用"猜一个等待时间"的写法）。
func _await_until(cond: Callable, label: String, timeout_frames: int = 30000) -> bool:
	var frames := 0
	while not cond.call() and frames < timeout_frames:
		await process_frame
		frames += 1
	var ok: bool = cond.call()
	_t("wait satisfied: %s" % label, ok, "frames=%d" % frames)
	return ok


## 棋盘输入是否已解除锁定（取消后必须恢复）。
func _input_released() -> bool:
	return main.board.tile_at(4, 0).disabled == false


func _test_animation_cancel() -> void:
	_section("P2.1 动画取消：解除等待 / 清理资源 / 不覆盖新局")
	main.set_animations_enabled(true)
	main.anim_layer.time_scale = 0.4        # 放慢一点，便于在阶段中途取消
	_sig_finished = 0
	_sig_canceled = 0
	main.anim_layer.play_finished.connect(_on_play_finished)
	main.anim_layer.play_canceled.connect(_on_play_canceled)

	# ---- 1) 普通动画正常播放完成
	main.start_new_game(SEED)
	_load_fixture(MERGE_FIXTURE, 5, 0, 1)
	main.board.tile_at(0, 2).pressed.emit()
	await _await_until(func(): return not main.is_animating(), "normal play completes")
	_eq_int("play_finished emitted exactly once", _sig_finished, 1)
	_eq_int("no cancel signal on normal completion", _sig_canceled, 0)
	_t("layer is idle", main.anim_layer.is_playing() == false)
	_check_no_leftovers("正常完成")
	_check_ui_matches_state("正常完成后")

	# ---- 2) 合并动画中途取消
	_sig_finished = 0
	_sig_canceled = 0
	main.start_new_game(SEED)
	_load_fixture(MERGE_FIXTURE, 5, 0, 1)
	main.board.tile_at(0, 2).pressed.emit()
	await _await_until(func(): return main.anim_layer.ghost_count() > 0, "merge step started")
	var first_cancel: bool = main.anim_layer.cancel_play()
	_t("cancel during merge returns true", first_cancel == true)
	await _await_until(func(): return not main.is_animating(), "main unlocked after merge cancel")
	_eq_int("canceled signal emitted once", _sig_canceled, 1)
	_eq_int("canceled play never emits finished", _sig_finished, 0)
	_t("input released after cancel", _input_released())
	_check_no_leftovers("合并中途取消")
	_check_ui_matches_state("合并取消后")

	# ---- 3) 重力动画中途取消
	_sig_finished = 0
	_sig_canceled = 0
	main.start_new_game(SEED)
	_load_fixture(MERGE_FIXTURE, 5, 0, 1)
	main.board.tile_at(0, 2).pressed.emit()
	await _await_until(func(): return _history_count("gravity") == 1 and main.anim_layer.ghost_count() > 0, "gravity step started")
	main.anim_layer.cancel_play()
	await _await_until(func(): return not main.is_animating(), "unlocked after gravity cancel")
	_eq_int("gravity cancel emitted once", _sig_canceled, 1)
	_eq_int("no finished signal", _sig_finished, 0)
	_t("input released", _input_released())
	_check_no_leftovers("重力中途取消")
	_check_ui_matches_state("重力取消后")

	# ---- 4) 顶部补充动画中途取消
	_sig_finished = 0
	_sig_canceled = 0
	main.start_new_game(SEED)
	main.state.spawn_enabled = true
	main.state.set_board_from_text(MERGE_FIXTURE)
	main.state.energy = 5
	main.state.score = 0
	main.sync_ui()
	main.board.tile_at(0, 2).pressed.emit()
	await _await_until(func(): return _history_count("refill") >= 1 and main.anim_layer.ghost_count() > 0, "refill step started")
	main.anim_layer.cancel_play()
	await _await_until(func(): return not main.is_animating(), "unlocked after refill cancel")
	_eq_int("refill cancel emitted once", _sig_canceled, 1)
	_eq_int("no finished signal", _sig_finished, 0)
	_check_no_leftovers("补充中途取消")
	_check_ui_matches_state("补充取消后")

	# ---- 5) 连锁第二轮开始前取消
	_sig_finished = 0
	_sig_canceled = 0
	main.start_new_game(SEED)
	_load_fixture(PLAYER_CHAIN_FIXTURE, 2, 0, 1)
	main.board.tile_at(2, 0).pressed.emit()
	await _await_until(func(): return _history_count("gravity") == 1, "round 1 gravity reached")
	main.anim_layer.cancel_play()          # 此刻第 2 轮 merge 还不可能开始
	await _await_until(func(): return not main.is_animating(), "unlocked after chain cancel")
	_eq_int("round 2 never started", _history_count("merge"), 1)
	_eq_int("only one gravity step played", _history_count("gravity"), 1)
	_check_no_leftovers("连锁中途取消")
	_check_ui_matches_state("连锁取消后")

	# ---- 6) 动画中直接 start_new_game()：新局不能被旧动画覆盖
	_sig_finished = 0
	_sig_canceled = 0
	main.start_new_game(SEED)
	_load_fixture(MERGE_FIXTURE, 5, 0, 1)
	main.board.tile_at(0, 2).pressed.emit()
	await _await_until(func(): return main.anim_layer.ghost_count() > 0, "merge running before restart")
	main.start_new_game(SEED + 1)
	_eq_int("restart canceled the running play", _sig_canceled, 1)
	_t("not animating right after restart", main.is_animating() == false)
	_eq_int("no ghosts after restart", main.anim_layer.ghost_count(), 0)
	var fresh_sig: String = main.state.board_signature()
	_eq_int("new game board is full", main.state.tile_count(), GS.CELL_COUNT)
	_eq_int("new game score reset", main.state.score, 0)
	_eq_int("new game energy reset", main.state.energy, GS.ENERGY_START)
	_eq_int("new game phase", main.state.phase, GS.Phase.PLAYING)
	# 持续观察一段时间，确认旧动画的残余不会再改新局的任何状态
	for i in 90:
		await process_frame
	_eq_str("new board untouched by the old animation", main.state.board_signature(), fresh_sig)
	_eq_int("score still 0 after soak", main.state.score, 0)
	_eq_int("energy still 5 after soak", main.state.energy, GS.ENERGY_START)
	_eq_int("phase still PLAYING after soak", main.state.phase, GS.Phase.PLAYING)
	_eq_int("no finished signal from the canceled play", _sig_finished, 0)
	_check_no_leftovers("重开后")
	_check_ui_matches_state("重开后")

	# ---- 7) 动画中把动画层移出场景树 / 释放
	main.start_new_game(SEED)
	_load_fixture(MERGE_FIXTURE, 5, 0, 1)
	main.board.tile_at(0, 2).pressed.emit()
	await _await_until(func(): return main.anim_layer.ghost_count() > 0, "merge running before removal")
	var layer_parent = main.anim_layer.get_parent()
	layer_parent.remove_child(main.anim_layer)          # 触发 _exit_tree → 中止并清理
	await _await_until(func(): return not main.is_animating(), "unlocked after layer removal")
	_eq_int("layer cleaned its ghosts on tree exit", main.anim_layer.get_child_count(), 0)
	_t("input released after layer removal", _input_released())
	layer_parent.add_child(main.anim_layer)             # 放回场景树继续使用
	_t("layer is idle after re-adding", main.anim_layer.is_playing() == false)

	# ---- 8) 取消后再次正常点击，仍然可以正常游玩
	_sig_finished = 0
	_sig_canceled = 0
	main.start_new_game(SEED)
	_load_fixture(MERGE_FIXTURE, 5, 0, 1)
	main.board.tile_at(0, 2).pressed.emit()
	await _await_until(func(): return main.anim_layer.ghost_count() > 0, "merge running before cancel")
	main.anim_layer.cancel_play()
	await _await_until(func(): return not main.is_animating(), "unlocked after cancel")
	var canceled_before_new_turn: int = _sig_canceled
	var energy_after_cancel: int = main.state.energy
	main.board.tile_at(4, 0).pressed.emit()             # 取消后正常点击（合并结果落在这里）
	await _await_until(func(): return not main.is_animating(), "second turn completes")
	_eq_int("click after cancel is accepted", main.state.energy, energy_after_cancel - 1)
	_eq_int("the new turn finished normally", _sig_finished, 1)
	_eq_int("no extra cancel signal for the new turn", _sig_canceled, canceled_before_new_turn)
	_check_no_leftovers("取消后继续游玩")
	_check_ui_matches_state("取消后继续游玩")

	# ---- 9) 连续多次取消 / 连续重开：不重复清理、不误发完成信号
	_sig_finished = 0
	_sig_canceled = 0
	main.start_new_game(SEED)
	_load_fixture(MERGE_FIXTURE, 5, 0, 1)
	main.board.tile_at(0, 2).pressed.emit()
	await _await_until(func(): return main.anim_layer.ghost_count() > 0, "merge running before repeated cancel")
	var cancel_1: bool = main.anim_layer.cancel_play()
	var cancel_2: bool = main.anim_layer.cancel_play()
	var cancel_3: bool = main.anim_layer.cancel_play()
	_t("first cancel returns true", cancel_1 == true)
	_t("second and third cancels are no-ops", cancel_2 == false and cancel_3 == false)
	_eq_int("cancel signal emitted only once", _sig_canceled, 1)
	_eq_int("no finished signal after repeated cancel", _sig_finished, 0)
	await _await_until(func(): return not main.is_animating(), "unlocked after repeated cancel")
	main.start_new_game(SEED)
	main.start_new_game(SEED + 2)                       # 空闲状态下连续重开
	await _await_until(func(): return not main.is_animating(), "unlocked after double restart")
	_eq_int("idle restarts emit no extra cancel signal", _sig_canceled, 1)
	_eq_int("still no finished signal", _sig_finished, 0)
	_check_no_leftovers("连续取消后")
	_check_ui_matches_state("连续取消后")

	# ---- 10) 释放动画层节点：不能挂起等待，游戏仍可继续（放在最后）
	_sig_finished = 0
	_sig_canceled = 0
	main.start_new_game(SEED)
	_load_fixture(MERGE_FIXTURE, 5, 0, 1)
	main.board.tile_at(0, 2).pressed.emit()
	await _await_until(func(): return main.anim_layer.ghost_count() > 0, "merge running before free")
	main.anim_layer.queue_free()
	await process_frame
	await process_frame
	await _await_until(func(): return not main.is_animating(), "unlocked after layer freed")
	_t("animation layer is really gone", is_instance_valid(main.anim_layer) == false)
	_t("input released after layer freed", _input_released())
	var energy_before: int = main.state.energy
	main.board.tile_at(4, 0).pressed.emit()             # 没有动画层也必须能继续玩
	await process_frame
	_eq_int("clicks still work without the animation layer", main.state.energy, energy_before - 1)
	_eq_int("phase still PLAYING", main.state.phase, GS.Phase.PLAYING)
	_check_ui_matches_state("动画层释放后")


# ==================================================================== P3 视觉规则

func _visual_color_eq(tag: String, a: Color, b: Color) -> void:
	_eq_str(tag, a.to_html(false), b.to_html(false))


## 视觉残留检查：透明度 / 缩放 / 文字 / 每个格子的颜色都必须与自身数值一致。
func _check_visual_state(tag: String) -> void:
	var clean := true
	var colored := true
	for i in GS.CELL_COUNT:
		var t = main.board.tile_at(i / GS.BOARD_N, i % GS.BOARD_N)
		if t.modulate.a < 0.999 or t.scale != Vector2.ONE:
			clean = false
		if t.value == GS.EMPTY:
			if t.text != "":
				clean = false
		else:
			if t.text != str(t.value):
				clean = false
			if t.stylebox_color("normal") != TileViewScript.color_for(t.value):
				colored = false
	_t("[%s] no visual residue (alpha / scale / text)" % tag, clean)
	_t("[%s] every tile shows the color of its own value" % tag, colored)


func _test_visual_rules() -> void:
	_section("P3 视觉：颜色映射、共享样式、状态反馈、无残留")

	# ---- 1) 1~5 各有一种有效且互不相同的颜色
	var seen := {}
	var distinct := true
	var opaque := true
	for v in [1, 2, 3, 4, 5]:
		var c: Color = TileViewScript.color_for(v)
		if c.a < 1.0:
			opaque = false
		var key := c.to_html(false)
		if seen.has(key):
			distinct = false
		seen[key] = true
	_t("1..5 are all opaque", opaque)
	_t("1..5 use 5 different colors", distinct)

	# 不能只靠"细微色差"区分：色相间隔必须明显
	var hues: Array = []
	for v in [1, 2, 3, 4, 5]:
		hues.append(TileViewScript.color_for(v).h)
	var min_gap := 1.0
	for i in hues.size():
		for j in range(i + 1, hues.size()):
			var d: float = absf(hues[i] - hues[j])
			d = minf(d, 1.0 - d)
			min_gap = minf(min_gap, d)
	_t("1..5 differ by a clear hue gap (>= 0.06)", min_gap >= 0.06, "min_gap=%.3f" % min_gap)

	# ---- 2) >5 一定有确定、有效的颜色（不越界、不无效、不撞色）
	var high_ok := true
	var high_distinct := true
	var prev := Color(0, 0, 0, 0)
	for v in range(6, 61):
		var c: Color = TileViewScript.color_for(v)
		if c.a < 1.0 or c.to_html(false) == "000000":
			high_ok = false
		if TileViewScript.color_for(v) != c:
			high_ok = false                       # 同一数值必须稳定
		if v > 6 and c.to_html(false) == prev.to_html(false):
			high_distinct = false
		prev = c
	_t("values > 5 always produce a valid, stable color", high_ok)
	_t("consecutive values > 5 do not share a color", high_distinct)
	var huge: Color = TileViewScript.color_for(99999)
	_t("very large value still yields a valid color", huge.a == 1.0 and huge.to_html(false) != "000000")
	_t("empty cell has no background color", TileViewScript.color_for(GS.EMPTY).a == 0.0)

	# ---- 3) 文字与底色对比度达标（可读性用数值验证，不靠肉眼）
	var worst := 99.0
	for v in [1, 2, 3, 4, 5, 6, 8, 12, 25, 60]:
		var bg: Color = TileViewScript.color_for(v)
		worst = minf(worst, TileViewScript.contrast_ratio(TileViewScript.text_color_for(bg), bg))
	_t("text/background contrast >= 4.5 for every sampled value", worst >= TileViewScript.MIN_CONTRAST, "worst=%.2f" % worst)

	# ---- 4) 同一数值多次渲染完全一致；数值变化时样式跟着更新
	var t_a = main.board.tile_at(0, 0)
	var t_b = main.board.tile_at(4, 4)
	t_a.set_value(7)
	t_b.set_value(7)
	_visual_color_eq("same value -> same background", t_a.background_color(), t_b.background_color())
	_visual_color_eq("same value -> same normal stylebox", t_a.stylebox_color("normal"), t_b.stylebox_color("normal"))
	_eq_int("same value -> same font size", t_a.get_theme_font_size("font_size"), t_b.get_theme_font_size("font_size"))
	t_a.set_value(1)
	var c_1: Color = t_a.stylebox_color("normal")
	t_a.set_value(4)
	var c_4: Color = t_a.stylebox_color("normal")
	_t("stylebox follows the new value", c_1 != c_4)
	_visual_color_eq("value 1 uses the palette color", c_1, TileViewScript.color_for(1))
	_visual_color_eq("value 4 uses the palette color", c_4, TileViewScript.color_for(4))
	_eq_str("tile text follows the value", t_a.text, "4")

	# ---- 5) 状态反馈：普通 / 悬停 / 按下 / 禁用 各不相同，且都保持可读
	var states_distinct := true
	var states_readable := true
	for v in [1, 3, 6, 15]:
		t_a.set_value(v)
		var normal: Color = t_a.stylebox_color("normal")
		var hover: Color = t_a.stylebox_color("hover")
		var down: Color = t_a.stylebox_color("pressed")
		var off: Color = t_a.stylebox_color("disabled")
		if normal == hover or normal == down or normal == off:
			states_distinct = false
		for c in [normal, hover, down, off]:
			if TileViewScript.contrast_ratio(TileViewScript.text_color_for(c), c) < TileViewScript.MIN_CONTRAST:
				states_readable = false
	_t("normal / hover / pressed / disabled are visually distinct", states_distinct)
	_t("digits stay readable in every state", states_readable)

	# ---- 6) 字号规则：位数越多越小，始终可用，4 位数不溢出
	var fs1: int = TileViewScript.font_size_for(104.0, 1)
	var fs2: int = TileViewScript.font_size_for(104.0, 2)
	var fs3: int = TileViewScript.font_size_for(104.0, 3)
	var fs4: int = TileViewScript.font_size_for(104.0, 4)
	_t("font size shrinks as digits grow", fs1 > fs2 and fs2 > fs3 and fs3 >= fs4)
	_t("font size stays usable for 4 digits", fs4 >= 10)
	var width_ok := true
	var checked := 0
	for v in [7, 42, 512, 4096]:
		t_a.set_value(v)
		if t_a.size.x < 20.0:
			continue
		checked += 1
		var fs: int = t_a.get_theme_font_size("font_size")
		if fs * 0.62 * str(v).length() >= t_a.size.x:
			width_ok = false
	_t("even 4-digit numbers fit inside the cell (%d sizes checked)" % checked, width_ok and checked > 0)

	# ---- 7) 输入禁用只影响输入，不阻断视觉刷新
	main.start_new_game(SEED)
	_load_fixture(SINGLE_TILE_BOARD, 5, 0, 1)
	main.board.set_input_enabled(false)
	_t("input is disabled", main.board.tile_at(0, 0).disabled == true)
	main.board.tile_at(0, 0).set_value(9)
	_eq_str("disabled tile still updates its text", main.board.tile_at(0, 0).text, "9")
	_visual_color_eq("disabled tile still updates its color",
		main.board.tile_at(0, 0).stylebox_color("normal"), TileViewScript.color_for(9))
	main.board.tile_at(1, 1).set_value(2)
	_eq_str("another cell refreshed too", main.board.tile_at(1, 1).text, "2")
	_t("disabled state has its own background",
		main.board.tile_at(1, 1).stylebox_color("disabled") != main.board.tile_at(1, 1).stylebox_color("normal"))

	# ---- 8) 动画临时方块与静态方块共用同一套样式规则
	main.set_animations_enabled(true)
	main.anim_layer.time_scale = 0.5
	_sig_finished = 0
	_sig_canceled = 0
	main.start_new_game(SEED)
	_load_fixture(MERGE_FIXTURE, 5, 0, 1)
	main.board.tile_at(0, 2).pressed.emit()
	await _await_until(func(): return main.anim_layer.ghost_count() > 0, "ghost exists for style check")
	var ghost = main.anim_layer.get_child(0)
	var ghost_value: int = ghost.value
	_t("ghost carries a real value", ghost_value > 0, "value=%d" % ghost_value)
	var static_tile = main.board.tile_at(4, 4)
	static_tile.set_value(ghost_value)
	_visual_color_eq("ghost and static tile share the same background",
		ghost.stylebox_color("normal"), static_tile.stylebox_color("normal"))
	_visual_color_eq("ghost and static tile share the same hover background",
		ghost.stylebox_color("hover"), static_tile.stylebox_color("hover"))
	_eq_int("ghost and static tile share the same font size",
		ghost.get_theme_font_size("font_size"), static_tile.get_theme_font_size("font_size"))
	_visual_color_eq("ghost and static tile share the same text color",
		ghost.get_theme_color("font_color"), static_tile.get_theme_color("font_color"))
	_t("ghost never takes mouse input", ghost.mouse_filter == Control.MOUSE_FILTER_IGNORE)
	await _await_animation()
	_check_visual_state("动画完成后")

	# ---- 9) 取消动画后同样没有视觉残留
	main.start_new_game(SEED)
	_load_fixture(MERGE_FIXTURE, 5, 0, 1)
	main.board.tile_at(0, 2).pressed.emit()
	await _await_until(func(): return main.anim_layer.ghost_count() > 0, "ghost exists before cancel")
	main.anim_layer.cancel_play()
	await _await_until(func(): return not main.is_animating(), "unlocked after cancel")
	_eq_int("no ghost objects left after cancel", main.anim_layer.ghost_count(), 0)
	_check_visual_state("取消后")

	# ---- 10) 真实刷新路径：整盘刷新后每个格子都是自己数值的颜色
	main.start_new_game(SEED)
	_load_fixture(PLAYER_CHAIN_FIXTURE, 5, 0, 1)
	_check_visual_state("整盘刷新后")

	main.set_animations_enabled(false)
