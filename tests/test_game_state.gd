extends SceneTree

## P0 纯逻辑内核的 headless 自动化测试。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tests/test_game_state.gd
## 退出码 0 = 全部通过；1 = 存在失败断言。
##
## 所有随机行为都通过固定 seed 或可控随机输入构造，不存在"多跑几次碰巧通过"。

const GS = preload("res://game_state.gd")
const SS = preload("res://score_store.gd")

const TEST_SAVE_PATH := "user://test_highscore.cfg"
const EMPTY_ROW := ". . . . ."
const CHECKERBOARD := "1 2 1 2 1\n2 1 2 1 2\n1 2 1 2 1\n2 1 2 1 2\n1 2 1 2 1"

var _passed := 0
var _failed := 0
var _current := ""


func _initialize() -> void:
	_test_initial_board()
	_test_initial_board_failure()
	_test_basic_merges()
	_test_cross_matches()
	_test_chain()
	_test_dense_block()
	_test_tap_rules()
	_test_energy_and_game_over()
	_test_revive()
	_test_chain_limit_is_error()
	_test_spawn_basics()
	_test_spawn_value_range()
	_test_spawn_reproducibility()
	_test_spawn_participates_in_chain()
	_test_score_store()
	print("")
	print("checks passed: %d, failed: %d" % [_passed, _failed])
	print("RESULT=", "PASS" if _failed == 0 else "FAIL")
	quit(0 if _failed == 0 else 1)


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
	_t(label, actual == expected, "expected:\n%s\ngot:\n%s" % [expected, actual])


func _load_board(gs, text: String) -> void:
	_t("board fixture loads", gs.set_board_from_text(text), "fixture:\n" + text)


func _all_cells_between(gs, lo: int, hi: int) -> bool:
	if gs.board.size() != GS.CELL_COUNT:
		return false
	for v in gs.board:
		if v < lo or v > hi:
			return false
	return true


# ============================================================ T01/T02/T25 初始化

func _test_initial_board() -> void:
	_section("T01/T02/T25 开局棋盘：填满、无匹配、可复现")

	var seeds := [0, 1, 2, 7, 42, 999, 12345, 20261009]
	for s in seeds:
		var gs = GS.new(s)
		_eq_int("seed %d board size" % s, gs.board.size(), GS.CELL_COUNT)
		_t("seed %d all cells in {1,2}" % s, _all_cells_between(gs, GS.INIT_MIN, GS.INIT_MAX), gs.board_text())
		_t("seed %d tile count == 25" % s, gs.tile_count() == GS.CELL_COUNT, gs.board_text())
		_t("seed %d has no match at start" % s, gs.find_all_segments().is_empty(), gs.board_text())
		_eq_int("seed %d starts PLAYING" % s, gs.phase, GS.Phase.PLAYING)
		_eq_int("seed %d starts energy 5" % s, gs.energy, GS.ENERGY_START)
		_eq_int("seed %d starts score 0" % s, gs.score, 0)
		_eq_int("seed %d starts revive 1" % s, gs.revive_left, GS.REVIVE_MAX)

		var again = GS.new(s)
		_eq_str("seed %d reproducible" % s, again.board_signature(), gs.board_signature())

	var bad := 0
	for s in range(0, 200):
		var g = GS.new(s)
		if g.board.size() != GS.CELL_COUNT or not _all_cells_between(g, GS.INIT_MIN, GS.INIT_MAX):
			bad += 1
		elif not g.find_all_segments().is_empty():
			bad += 1
	_eq_int("200 seeds all give full match-free boards", bad, 0)

	var sigs := {}
	for s in seeds:
		sigs[GS.new(s).board_signature()] = true
	_t("different seeds give different boards", sigs.size() >= 2, "distinct=%d" % sigs.size())


func _test_initial_board_failure() -> void:
	_section("T03 初始化无解时必须显式失败，绝不返回含匹配段的棋盘")

	# 只允许填 1 → 5x5 必然出现三连 → 无解，必须回溯到穷尽并失败
	var gs = GS.new(5)
	gs.init_candidates = PackedInt32Array([1])
	gs.new_game()
	_eq_int("unsolvable candidates → ERROR", gs.phase, GS.Phase.ERROR)
	_t("error message recorded", gs.error_message != "", gs.error_message)
	_eq_int("no board is claimed on failure", gs.tile_count(), 0)
	_t("tap refused while ERROR", gs.tap(0, 0) == false)
	_eq_int("board unchanged after refused tap", gs.tile_count(), 0)

	# 候选集合为空也必须失败
	var gs2 = GS.new(5)
	gs2.init_candidates = PackedInt32Array()
	gs2.new_game()
	_eq_int("empty candidate list → ERROR", gs2.phase, GS.Phase.ERROR)

	# 搜索节点上限也必须失败（防御性）
	var gs3 = GS.new(5)
	gs3.init_node_limit = 0
	gs3.new_game()
	_eq_int("node limit 0 → ERROR", gs3.phase, GS.Phase.ERROR)


# ============================================== A/B/C/D/G/H 基础消除

func _test_basic_merges() -> void:
	_section("A/B/C/D/G/H 三连、四连、五连、纵向、打断、不同数字")

	var gs = GS.new(11)
	gs.spawn_enabled = false
	_load_board(gs, "2 2 2 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.score = 0
	gs.energy = 3
	_eq_int("A single segment found", gs.find_all_segments().size(), 1)
	_eq_int("A resolves STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_str("A board", gs.board_text(), "3 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("A score +9", gs.score, 9)
	_eq_int("A energy +1", gs.energy, 4)

	_load_board(gs, "1 1 1 1 .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.score = 0
	gs.energy = 0
	_eq_int("B one maximal segment", gs.find_all_segments().size(), 1)
	_eq_int("B resolves STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_str("B board", gs.board_text(), "2 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("B score +8", gs.score, 8)

	_load_board(gs, "3 3 3 3 3\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.score = 0
	_eq_int("C resolves STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_str("C board", gs.board_text(), "4 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("C score +20", gs.score, 20)

	# D：纵向三连，结果落在最上格
	_load_board(gs, ". . 5 . .\n. . 5 . .\n. . 5 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.score = 0
	_eq_int("D resolves STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_str("D board", gs.board_text(), ". . 6 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("D score +18", gs.score, 18)

	# G：空格打断连续
	_load_board(gs, "2 . 2 2 .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.score = 0
	gs.energy = 2
	_eq_int("G no segment (gap breaks run)", gs.find_all_segments().size(), 0)
	_eq_int("G resolves STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_str("G board unchanged", gs.board_text(), "2 . 2 2 .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("G score unchanged", gs.score, 0)
	_eq_int("G energy unchanged", gs.energy, 2)

	# H：不同数字不构成匹配段
	_load_board(gs, "2 2 3 2 .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("H no segment", gs.find_all_segments().size(), 0)


# ============================================== E / E2 交叉匹配

func _test_cross_matches() -> void:
	_section("E / E2 横纵交叉：两条线都消除")

	var gs = GS.new(12)
	gs.spawn_enabled = false
	_load_board(gs, ". 2 . . .\n2 2 2 . .\n. 2 . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("E both lines detected", gs.find_all_segments().size(), 2)
	_eq_int("E tile count before", gs.tile_count(), 5)
	gs.score = 0
	gs.energy = 0
	_eq_int("E resolves STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_str("E board", gs.board_text(), ". 3 . . .\n3 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("E score +18 (two events)", gs.score, 18)
	_eq_int("E energy +2 (two events)", gs.energy, 2)
	_eq_int("E tiles: 5 -5 +2 placed, spawn off", gs.tile_count(), 2)

	# E2：两段段首格重合（都在角点）
	_load_board(gs, "2 2 2 . .\n2 . . . .\n2 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("E2 both lines detected", gs.find_all_segments().size(), 2)
	gs.score = 0
	gs.energy = 0
	_eq_int("E2 resolves STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_str("E2 board", gs.board_text(), "3 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("E2 score +18 (still two events)", gs.score, 18)
	_eq_int("E2 energy +2", gs.energy, 2)
	_eq_int("E2 shared first cell occupies 1 tile", gs.tile_count(), 1)


# ============================================== F 连锁

func _test_chain() -> void:
	_section("F 连锁：合并产物接上已有同值数字")

	var gs = GS.new(13)
	gs.spawn_enabled = false
	_load_board(gs, "4 5 5 . .\n4 . . . .\n3 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.score = 0
	gs.energy = 2
	_t("F tap accepted", gs.tap(2, 0) == true)
	_eq_str("F board after chain", gs.board_text(), "6 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("F score +33 (15 then 18)", gs.score, 33)
	_eq_int("F energy 2 -1 +1 +1", gs.energy, 3)
	_t("F board is stable", gs.find_all_segments().is_empty())
	_eq_int("F no spawn attempts while spawn disabled", gs.spawn_attempts, 0)


# ============================================== K 密集区块

func _test_dense_block() -> void:
	_section("K 3x3 全同值区块：多段重叠 + 多轮连锁")

	var gs = GS.new(14)
	gs.spawn_enabled = false
	_load_board(gs, EMPTY_ROW + "\n. 3 3 3 .\n. 3 3 3 .\n. 3 3 3 .\n" + EMPTY_ROW)
	_eq_int("K six segments in one round", gs.find_all_segments().size(), 6)
	_eq_int("K tiles before", gs.tile_count(), 9)
	gs.score = 0
	gs.energy = 0
	_eq_int("K resolves STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_str("K final board", gs.board_text(), EMPTY_ROW + "\n. 5 . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("K score +102 (72 then 30)", gs.score, 102)
	_eq_int("K energy capped at 5", gs.energy, GS.ENERGY_MAX)
	_eq_int("K tiles 9 -> 1 (distinct first cells, not segment count)", gs.tile_count(), 1)


# ============================================== 点击规则

func _test_tap_rules() -> void:
	_section("M/点击规则：空格、越界、非法状态")

	var gs = GS.new(15)
	gs.spawn_enabled = false
	_load_board(gs, "5 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.energy = 3
	gs.score = 0
	var before: String = gs.board_signature()
	_t("tap empty cell refused", gs.tap(0, 1) == false)
	_eq_str("empty tap leaves board", gs.board_signature(), before)
	_eq_int("empty tap costs no energy", gs.energy, 3)
	_eq_int("empty tap gives no score", gs.score, 0)

	_t("out of bounds refused (5,0)", gs.tap(5, 0) == false)
	_t("out of bounds refused (-1,0)", gs.tap(-1, 0) == false)
	_eq_int("out of bounds costs no energy", gs.energy, 3)

	gs.phase = GS.Phase.GAME_OVER
	_t("tap refused after GAME_OVER", gs.tap(0, 0) == false)
	_eq_str("GAME_OVER tap leaves board", gs.board_signature(), before)

	gs.phase = GS.Phase.ERROR
	_t("tap refused while ERROR", gs.tap(0, 0) == false)


# ============================================== J/L/M 能量与结束判定

func _test_energy_and_game_over() -> void:
	_section("J/L/M 能量扣除、每段回能、上限、先结算后判定")

	# J：无消除 → 只扣能量
	var gs = GS.new(16)
	gs.spawn_enabled = false
	_load_board(gs, "5 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.energy = 5
	gs.score = 0
	_t("J tap accepted", gs.tap(0, 0) == true)
	_eq_int("J score +0 without merge", gs.score, 0)
	_eq_int("J energy 5 -> 4", gs.energy, 4)

	# J2：能量已满时消除不再增加
	_load_board(gs, "2 2 2 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.energy = GS.ENERGY_MAX
	gs.score = 0
	gs.resolve_all()
	_eq_int("J2 energy stays capped", gs.energy, GS.ENERGY_MAX)
	_eq_int("J2 score still awarded", gs.score, 9)

	# M：消耗掉最后一格能量但随后发生消除 → 结算后能量为 1，游戏继续
	_load_board(gs, "2 2 1 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.energy = 1
	gs.score = 0
	gs.revive_left = 1
	gs.phase = GS.Phase.PLAYING
	_t("M tap accepted", gs.tap(0, 2) == true)
	_eq_str("M board", gs.board_text(), "3 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("M energy settles to 1", gs.energy, 1)
	_eq_int("M game continues", gs.phase, GS.Phase.PLAYING)

	# L：消耗掉最后一格能量且没有消除 → 能量 0 → 进入复活询问
	_load_board(gs, "5 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.energy = 1
	gs.revive_left = 1
	gs.phase = GS.Phase.PLAYING
	_t("L tap accepted", gs.tap(0, 0) == true)
	_eq_int("L energy 0", gs.energy, 0)
	_eq_int("L asks for revive", gs.phase, GS.Phase.REVIVE_PROMPT)

	# L2：没有复活次数时直接结束
	_load_board(gs, "5 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.energy = 1
	gs.revive_left = 0
	gs.phase = GS.Phase.PLAYING
	gs.tap(0, 0)
	_eq_int("L2 game over without revive left", gs.phase, GS.Phase.GAME_OVER)
	_t("L2 is_game_over()", gs.is_game_over())


# ============================================== 复活

func _test_revive() -> void:
	_section("复活：能量 3、次数 -1、棋盘与分数不变")

	var gs = GS.new(17)
	gs.spawn_enabled = false
	_load_board(gs, "4 5 . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.energy = 1
	gs.revive_left = 1
	gs.score = 123
	gs.tap(0, 1)
	_eq_int("reaches REVIVE_PROMPT", gs.phase, GS.Phase.REVIVE_PROMPT)

	var board_before: String = gs.board_signature()
	var score_before: int = gs.score
	_t("revive accepted", gs.revive() == true)
	_eq_int("energy restored to 3", gs.energy, GS.REVIVE_ENERGY)
	_eq_int("revive count 1 -> 0", gs.revive_left, 0)
	_eq_int("back to PLAYING", gs.phase, GS.Phase.PLAYING)
	_eq_str("board unchanged by revive", gs.board_signature(), board_before)
	_eq_int("score unchanged by revive", gs.score, score_before)
	_t("second revive refused", gs.revive() == false)

	# 次数用尽后再耗尽 → 直接结束
	_load_board(gs, "5 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.energy = 1
	gs.tap(0, 0)
	_eq_int("second depletion ends the game", gs.phase, GS.Phase.GAME_OVER)

	# 放弃复活
	var gs2 = GS.new(18)
	gs2.spawn_enabled = false
	_load_board(gs2, "5 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs2.energy = 1
	gs2.tap(0, 0)
	_eq_int("prompt shown", gs2.phase, GS.Phase.REVIVE_PROMPT)
	var sig2: String = gs2.board_signature()
	_t("give_up accepted", gs2.give_up() == true)
	_eq_int("give_up → GAME_OVER", gs2.phase, GS.Phase.GAME_OVER)
	_eq_str("give_up leaves board", gs2.board_signature(), sig2)
	_t("give_up twice refused", gs2.give_up() == false)


# ============================================== 连锁上限 → ERROR

func _test_chain_limit_is_error() -> void:
	_section("T 连锁步数上限：不得静默继续，必须进入 ERROR")

	var gs = GS.new(19)
	gs.spawn_enabled = false
	_load_board(gs, "4 5 5 . .\n4 . . . .\n3 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.max_chain_steps = 1          # F 场景需要 2 轮，这里只允许 1 轮
	gs.energy = 3
	gs.score = 0
	var accepted: bool = gs.tap(2, 0)
	_t("tap reports failure", accepted == false)
	_eq_int("phase is ERROR", gs.phase, GS.Phase.ERROR)
	_t("error message recorded", gs.error_message != "", gs.error_message)
	_t("board is NOT claimed stable", gs.has_unresolved_matches(), "expected unresolved match, board:\n" + gs.board_text())
	_eq_int("score from completed rounds kept", gs.score, 15)

	var frozen: String = gs.board_signature()
	_t("further taps refused", gs.tap(0, 0) == false)
	_eq_str("board frozen after ERROR", gs.board_signature(), frozen)
	_eq_int("resolve_all blocked while ERROR", gs.resolve_all(), GS.ResolveResult.BLOCKED_ERROR)
	_eq_str("board still frozen after blocked resolve", gs.board_signature(), frozen)
	_eq_int("phase stays ERROR", gs.phase, GS.Phase.ERROR)


# ============================================== 随机补充

func _test_spawn_basics() -> void:
	_section("S1/S2/S3 每个消除事件一次补充尝试")

	var gs = GS.new(20)
	gs.spawn_enabled = true
	_load_board(gs, "2 2 2 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	var a0: int = gs.spawn_attempts
	var d0: int = gs.spawns_done
	gs.score = 0
	gs.energy = 0
	_eq_int("S1 resolves STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_int("S1 one attempt for one segment", gs.spawn_attempts - a0, 1)
	_eq_int("S1 one successful spawn", gs.spawns_done - d0, 1)
	_eq_int("S1 tiles 3 -3 +1 placed +1 spawned", gs.tile_count(), 2)
	_t("S1 board stable after spawn", gs.find_all_segments().is_empty(), gs.board_text())
	_eq_int("S1 score unchanged by spawn", gs.score, 9)

	# S2：一次点击两个消除事件 → 两次补充尝试
	_load_board(gs, ". 2 . . .\n2 2 2 . .\n. 2 . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	a0 = gs.spawn_attempts
	d0 = gs.spawns_done
	gs.score = 0
	gs.energy = 0
	_eq_int("S2 resolves STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_int("S2 two attempts for two segments", gs.spawn_attempts - a0, 2)
	_eq_int("S2 two successful spawns", gs.spawns_done - d0, 2)
	_eq_int("S2 tiles 5 -5 +2 placed +2 spawned", gs.tile_count(), 4)

	# S3：棋盘已满时补充失败但不崩溃
	var full = GS.new(21)
	_eq_int("S3 initial board is full", full.tile_count(), GS.CELL_COUNT)
	var fa: int = full.spawn_attempts
	var fd: int = full.spawns_done
	_t("S3 spawn on full board returns false", full.spawn_one() == false)
	_eq_int("S3 attempt counted", full.spawn_attempts - fa, 1)
	_eq_int("S3 no successful spawn", full.spawns_done - fd, 0)
	_eq_int("S3 board untouched", full.tile_count(), GS.CELL_COUNT)
	_eq_int("S3 still PLAYING", full.phase, GS.Phase.PLAYING)


func _test_spawn_value_range() -> void:
	_section("S5 补充数字必须落在 {1..5} 且分布均匀")

	# 只有一个空格的棋盘 → 位置固定，便于直接读取抽出的数值
	var one_empty := "2 . 2 1 2\n1 2 1 2 1\n2 1 2 1 2\n1 2 1 2 1\n2 1 2 1 2"
	var gs = GS.new(22)
	_load_board(gs, one_empty)
	_eq_int("fixture has exactly one empty cell", gs.tile_count(), GS.CELL_COUNT - 1)

	var counts := {}
	for v in range(GS.SPAWN_MIN, GS.SPAWN_MAX + 1):
		counts[v] = 0
	var samples := 500
	var out_of_range := 0
	var spawn_failures := 0
	for i in samples:
		if not gs.spawn_one():
			spawn_failures += 1
			continue
		var v: int = gs.at(0, 1)
		if v < GS.SPAWN_MIN or v > GS.SPAWN_MAX:
			out_of_range += 1
		else:
			counts[v] += 1
		_load_board(gs, one_empty)          # 复位棋盘，但 rng 继续前进

	_eq_int("all 500 spawn attempts succeeded", spawn_failures, 0)
	_eq_int("500 spawns all within range", out_of_range, 0)
	print("   spawn distribution over %d samples: %s" % [samples, str(counts)])
	var lo := samples
	var hi := 0
	for v in counts:
		if counts[v] < lo:
			lo = counts[v]
		if counts[v] > hi:
			hi = counts[v]
	_t("every value 1..5 appears", lo > 0, "counts=%s" % str(counts))
	_t("distribution roughly uniform", lo >= samples / 10 and hi <= samples / 10 * 3, "counts=%s" % str(counts))


func _test_spawn_reproducibility() -> void:
	_section("S4 补充位置与数值均可用固定 seed 复现")

	# 定点测试：相同 seed、相同棋盘、相同调用序列
	var text := "2 . 2 . 2\n. 2 . 2 .\n2 . 2 . 2\n. 2 . 2 .\n2 . 2 . 2"
	var a = GS.new(0)
	var b = GS.new(0)
	_load_board(a, text)
	_load_board(b, text)
	a.rng.seed = 777
	b.rng.seed = 777
	for i in 3:
		a.spawn_one()
		b.spawn_one()
	_eq_str("spawned positions+values reproducible", a.board_signature(), b.board_signature())
	_t("spawns actually happened", a.spawns_done >= 3, "spawns=%d" % a.spawns_done)
	_eq_str("spawn signature", a.board_text(), b.board_text())

	# 整局测试：同一 seed + 同一操作序列 → 完全一致
	var coords := [[0, 0], [1, 1], [2, 2], [3, 3], [4, 4], [0, 4], [4, 0], [2, 1], [1, 3], [3, 2]]
	var g1 = GS.new(20261009)
	var g2 = GS.new(20261009)
	for i in 40:
		var p: Array = coords[i % coords.size()]
		var r1: bool = g1.tap(p[0], p[1])
		var r2: bool = g2.tap(p[0], p[1])
		_t("tap result identical at step %d" % i, r1 == r2)
		if g1.phase == GS.Phase.REVIVE_PROMPT:
			g1.revive()
			g2.revive()
		elif g1.phase != GS.Phase.PLAYING:
			break
	_eq_str("full-game boards identical", g1.board_signature(), g2.board_signature())
	_eq_int("full-game scores identical", g1.score, g2.score)
	_eq_int("full-game energy identical", g1.energy, g2.energy)
	_eq_int("full-game phases identical", g1.phase, g2.phase)
	_eq_int("full-game spawn attempts identical", g1.spawn_attempts, g2.spawn_attempts)
	_eq_int("full-game spawn successes identical", g1.spawns_done, g2.spawns_done)
	_t("the random run actually spawned", g1.spawns_done > 0, "spawns=%d" % g1.spawns_done)
	_t("no unresolved match left at the end", g1.find_all_segments().is_empty(), g1.board_text())


func _test_spawn_participates_in_chain() -> void:
	_section("S5b 补充的数字参与同一轮之后的连锁")

	# 只有 (0,1) 是空格，且左右邻居都是 2 → 只要补充值是 2 就立刻三连
	var fixture := "2 . 2 1 2\n1 2 1 2 1\n2 1 2 1 2\n1 2 1 2 1\n2 1 2 1 2"
	var gs = GS.new(23)
	_load_board(gs, fixture)
	_eq_int("fixture has exactly one empty cell", gs.tile_count(), GS.CELL_COUNT - 1)
	_t("fixture itself has no match", gs.find_all_segments().is_empty(), gs.board_text())

	# 暴力搜索一个 seed，使其"第二次抽签"（数值）恰好为 2
	var desired := 2
	var found := -1
	for s in range(0, 500):
		var r := RandomNumberGenerator.new()
		r.seed = s
		r.randi_range(0, 0)                                   # 位置抽签（唯一空格 → 范围 0..0）
		if r.randi_range(GS.SPAWN_MIN, GS.SPAWN_MAX) == desired:
			found = s
			break
	_t("found a seed producing the desired spawn value", found >= 0, "searched 500 seeds")

	gs.rng.seed = found
	_t("controlled spawn succeeds", gs.spawn_one() == true)
	_eq_int("spawned value landed in the only empty cell", gs.at(0, 1), desired)
	_eq_int("spawned cell completed a triple", gs.find_all_segments().size(), 1)

	# 关闭本轮的自动补充，让这次结算的棋盘结果唯一可断言
	# （参与连锁的是上面那次受控补充出来的数字）
	gs.spawn_enabled = false
	gs.score = 0
	gs.energy = 0
	_eq_int("chain after spawn resolves STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_str("board after spawned triple merged", gs.board_text(),
		"3 . . 1 2\n1 2 1 2 1\n2 1 2 1 2\n1 2 1 2 1\n2 1 2 1 2")
	_eq_int("score from spawned triple", gs.score, 9)
	_eq_int("energy from spawned triple", gs.energy, 1)
	_t("board stable at the end", gs.find_all_segments().is_empty(), gs.board_text())


# ============================================== 最高分持久化

func _test_score_store() -> void:
	_section("最高分写入与重新读取")

	_remove_test_save()
	var store = SS.new(TEST_SAVE_PATH)
	_eq_int("missing file → 0", store.load_best(), 0)
	_t("save new record accepted", store.save_best(1234) == true)
	_eq_int("reload after save", store.load_best(), 1234)
	_t("lower score does not overwrite", store.save_best(100) == false)
	_eq_int("value kept after lower save", store.load_best(), 1234)
	_t("higher score overwrites", store.save_best(9999) == true)
	_eq_int("value after overwrite", store.load_best(), 9999)

	# 损坏文件不应崩溃，视为无记录
	var f := FileAccess.open(TEST_SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string("this is not a ConfigFile at all")
		f.close()
	_eq_int("corrupt file → 0", store.load_best(), 0)
	_t("save recovers from corrupt file", store.save_best(50) == true)
	_eq_int("value after recovery save", store.load_best(), 50)

	_remove_test_save()
	_eq_int("file removed → 0", store.load_best(), 0)


func _remove_test_save() -> void:
	var dir := DirAccess.open("user://")
	if dir != null and dir.file_exists(TEST_SAVE_PATH.get_file()):
		dir.remove(TEST_SAVE_PATH.get_file())
