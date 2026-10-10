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

const TEST_SAVE_PATH := "user://test_ui_highscore.cfg"
const SEED := 20261010
const SINGLE_TILE_BOARD := "5 . . . .\n. . . . .\n. . . . .\n. . . . .\n. . . . ."

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
	await _test_revive_flow()
	await _test_game_over_and_highscore()
	await _test_restart_flow()
	await _test_error_state()

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
	_section("连锁：界面显示结算完成后的最终棋盘")
	_load_fixture("4 5 5 . .\n4 . . . .\n3 . . . .\n. . . . .\n. . . . .", 2, 0, 1)
	main.board.tile_at(2, 0).pressed.emit()
	await process_frame

	_eq_int("kernel board (0,0)", main.state.board[0], 6)
	_eq_int("kernel score +33", main.state.score, 33)
	_eq_int("kernel energy 2-1+2", main.state.energy, 3)
	_t("kernel board is stable", main.state.has_unresolved_matches() == false, main.state.board_text())
	_eq_int("tile (0,0) shows 6", main.board.tile_at(0, 0).value, 6)
	_eq_str("tile (0,0) text", main.board.tile_at(0, 0).text, "6")
	var leftovers := 0
	for i in GS.CELL_COUNT:
		if main.state.board[i] != GS.EMPTY:
			leftovers += 1
	_eq_int("only one tile remains", leftovers, 1)
	_check_ui_matches_state("连锁后")


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
	_load_fixture("4 5 5 . .\n4 . . . .\n3 . . . .\n. . . . .\n. . . . .", 3, 0, 1)
	main.state.max_chain_steps = 1                  # 逼出连锁上限异常
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
