extends SceneTree

## P0.5 逻辑内核测试：连通区域合并 + 重力下落 + 顶部随机补充。
##
## 运行方式：
##   godot --headless --path <项目目录> --script res://tests/test_game_state.gd
## 退出码 0 = 全部通过；1 = 存在失败断言。
##
## 约定：需要精确断言棋盘时把 spawn_enabled 关掉（不做顶部补充），
## 这样"合并 → 重力"的结果是唯一确定的；顶部补充与连锁另用固定 seed 验证。

const GS = preload("res://game_state.gd")
const SS = preload("res://score_store.gd")

const TEST_SAVE_PATH := "user://test_highscore.cfg"
const EMPTY_ROW := ". . . . ."
const SINGLE_TILE := "5 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW
# 无任何 >=3 连通区域的满盘（横向成对，纵向交替）
const PAIRS_BOARD := "2 2 1 1 2\n1 1 2 2 1\n2 2 1 1 2\n1 1 2 2 1\n2 2 1 1 2"

## 玩家直接合成 + 自动连锁：点击 (2,0) 让纵列三个 4 成区域（含点击格 → 结果仍为 4），
## 重力后底行形成 4,4,4 → 第二轮为自动连锁（4 + 1 = 5）。
## 第 2 轮区域 {20,21,22} 不含点击格 10，因此即使把点击格坐标也算进去也不会误判。
const PLAYER_CHAIN := "4 . . . .\n4 . . . .\n3 . . . .\n. 4 4 . .\n. . . . ."

## 纯自动连锁（直接 resolve_all()，无点击）：连续 4 轮，每轮结果都比匹配值大 1。
## 列 0 的 2,2,2 → 3；底行 3,3,3 → 4；列 1/2 落下的 4,4 → 5；再落下的 5,5 → 6。
const AUTO_CASCADE := "2 . . . .\n2 . . . .\n2 5 5 . .\n. 4 4 . .\n. 3 3 . ."

var _passed := 0
var _failed := 0
var _current := ""


func _initialize() -> void:
	_test_initial_board()
	_test_initial_board_failure()
	_test_region_detection()
	_test_merge_and_target()
	_test_multi_region_round()
	_test_gravity()
	_test_top_refill()
	_test_chain_by_refill()
	_test_player_merge_rules()
	_test_chain_and_energy()
	_test_tap_rules()
	_test_energy_and_game_over()
	_test_revive()
	_test_chain_limit_is_error()
	_test_determinism()
	_test_animation_events()
	_test_score_store()
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
	_t(label, actual == expected, "expected:\n%s\ngot:\n%s" % [expected, actual])


func _eq_cells(label: String, cells: PackedInt32Array, expected: Array) -> void:
	var got := PackedStringArray()
	for v in cells:
		got.append(str(v))
	var want := PackedStringArray()
	for v in expected:
		want.append(str(v))
	_eq_str(label, ",".join(got), ",".join(want))


func _load_board(gs, text: String) -> void:
	_t("board fixture loads", gs.set_board_from_text(text), "fixture:\n" + text)


func _all_cells_between(gs, lo: int, hi: int) -> bool:
	if gs.board.size() != GS.CELL_COUNT:
		return false
	for v in gs.board:
		if v < lo or v > hi:
			return false
	return true


func _count_empty(gs) -> int:
	return GS.CELL_COUNT - gs.tile_count()


func _finish() -> void:
	print("")
	print("checks passed: %d, failed: %d" % [_passed, _failed])
	print("RESULT=", "PASS" if _failed == 0 else "FAIL")
	quit(0 if _failed == 0 else 1)


# ================================================ F2 / 初始化

func _test_initial_board() -> void:
	_section("F2/T01/T02 开局棋盘：满盘、只用 {1,2}、无 >=3 连通区域、可复现")

	var seeds := [0, 1, 2, 7, 42, 999, 12345, 20261009]
	for s in seeds:
		var gs = GS.new(s)
		_eq_int("seed %d board size" % s, gs.board.size(), GS.CELL_COUNT)
		_t("seed %d all cells in {1,2}" % s, _all_cells_between(gs, GS.INIT_MIN, GS.INIT_MAX), gs.board_text())
		_eq_int("seed %d is completely filled" % s, gs.tile_count(), GS.CELL_COUNT)
		_t("seed %d has no mergeable region" % s, gs.find_all_regions().is_empty(), gs.board_text())
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
		elif g.tile_count() != GS.CELL_COUNT:
			bad += 1
		elif not g.find_all_regions().is_empty():
			bad += 1
	_eq_int("200 seeds all give full boards without mergeable regions", bad, 0)

	var sigs := {}
	for s in seeds:
		sigs[GS.new(s).board_signature()] = true
	_t("different seeds give different boards", sigs.size() >= 2, "distinct=%d" % sigs.size())


func _test_initial_board_failure() -> void:
	_section("T03 初始化无解时必须显式失败，绝不返回含可合并区域的棋盘")

	# 只允许填 1 → 整盘 25 个 1 必然连通 → 无解
	var gs = GS.new(5)
	gs.init_candidates = PackedInt32Array([1])
	gs.new_game()
	_eq_int("unsolvable candidates → ERROR", gs.phase, GS.Phase.ERROR)
	_t("error message recorded", gs.error_message != "", gs.error_message)
	_eq_int("no board is claimed on failure", gs.tile_count(), 0)
	_t("tap refused while ERROR", gs.tap(0, 0) == false)
	_eq_int("board unchanged after refused tap", gs.tile_count(), 0)

	var gs2 = GS.new(5)
	gs2.init_candidates = PackedInt32Array()
	gs2.new_game()
	_eq_int("empty candidate list → ERROR", gs2.phase, GS.Phase.ERROR)

	var gs3 = GS.new(5)
	gs3.init_node_limit = 0
	gs3.new_game()
	_eq_int("node limit 0 → ERROR", gs3.phase, GS.Phase.ERROR)


# ================================================ A. 连通区域检测

func _test_region_detection() -> void:
	_section("A 连通区域检测（4 邻接、同值、非空）")
	var gs = GS.new(10)
	gs.spawn_enabled = false

	# A1 横向 3
	_load_board(gs, "2 2 2 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	var r: Array = gs.find_all_regions()
	_eq_int("A1 one region", r.size(), 1)
	if r.size() == 1:
		_eq_int("A1 value", r[0].value, 2)
		_eq_int("A1 size", r[0].size, 3)
		_eq_int("A1 target index", r[0].target, 0)
		_eq_cells("A1 cells", r[0].cells, [0, 1, 2])

	# A2 纵向 3
	_load_board(gs, ". . 5 . .\n. . 5 . .\n. . 5 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	r = gs.find_all_regions()
	_eq_int("A2 one region", r.size(), 1)
	if r.size() == 1:
		_eq_int("A2 size", r[0].size, 3)
		_eq_int("A2 target is the topmost cell", r[0].target, 2)
		_eq_cells("A2 cells", r[0].cells, [2, 7, 12])

	# A3 L 形 3
	_load_board(gs, "2 . . . .\n2 2 . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	r = gs.find_all_regions()
	_eq_int("A3 L shape is one region", r.size(), 1)
	if r.size() == 1:
		_eq_int("A3 size", r[0].size, 3)
		_eq_cells("A3 cells", r[0].cells, [0, 5, 6])

	# A4 T 形 4
	_load_board(gs, ". 3 . . .\n3 3 3 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	r = gs.find_all_regions()
	_eq_int("A4 T shape is one region", r.size(), 1)
	if r.size() == 1:
		_eq_int("A4 size", r[0].size, 4)
		_eq_cells("A4 cells", r[0].cells, [1, 5, 6, 7])

	# A5 十字 5
	_load_board(gs, ". 4 . . .\n4 4 4 . .\n. 4 . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	r = gs.find_all_regions()
	_eq_int("A5 cross is ONE region (not three lines)", r.size(), 1)
	if r.size() == 1:
		_eq_int("A5 size", r[0].size, 5)
		_eq_cells("A5 cells", r[0].cells, [1, 5, 6, 7, 11])
	var total := 0
	for reg in r:
		total += reg.size
	_eq_int("A5 total cells counted once", total, 5)

	# A6 直线 5 个只算一个区域
	_load_board(gs, "1 1 1 1 1\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	r = gs.find_all_regions()
	_eq_int("A6 straight 5 is one region", r.size(), 1)
	if r.size() == 1:
		_eq_int("A6 size", r[0].size, 5)
		_eq_int("A6 target", r[0].target, 0)

	# A7 空格阻断
	_load_board(gs, "2 2 . 2 .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("A7 gap breaks connectivity", gs.find_all_regions().size(), 0)

	# A8 不同数字阻断
	_load_board(gs, "2 2 3 2 .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("A8 different values break connectivity", gs.find_all_regions().size(), 0)

	# A9 仅对角线连接不算
	_load_board(gs, "2 . . . .\n. 2 . . .\n. . 2 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	_eq_int("A9 diagonal is not connected", gs.find_all_regions().size(), 0)

	# A10 没有 >=3 的区域就不触发合并
	_load_board(gs, PAIRS_BOARD)
	_eq_int("A10 no region on pair board", gs.find_all_regions().size(), 0)
	gs.score = 0
	gs.energy = 3
	_eq_int("A10 resolve is STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_str("A10 board untouched", gs.board_text(), PAIRS_BOARD)
	_eq_int("A10 score untouched", gs.score, 0)
	_eq_int("A10 energy untouched", gs.energy, 3)


# ================================================ B. 合并与位置

func _test_merge_and_target() -> void:
	_section("B 合并阈值、结果落点与得分")
	var gs = GS.new(11)
	gs.spawn_enabled = false

	# B1 三个 2 → 一个 3，得分 +9
	_load_board(gs, EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n2 2 2 . .")
	gs.score = 0
	gs.energy = 0
	_eq_int("B1 resolve STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_int("B1 score +9", gs.score, 9)
	_eq_int("B1 energy +1", gs.energy, 1)
	_eq_str("B1 result 3 at leftmost cell of the row", gs.board_text(),
		EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n3 . . . .")

	# B2 四个 3 → 一个 4，得分 +16（不拆成 3+1）
	_load_board(gs, EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n3 3 3 3 .")
	gs.score = 0
	_eq_int("B2 resolve STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_int("B2 score +16", gs.score, 16)
	_eq_str("B2 one tile of 4", gs.board_text(),
		EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n4 . . . .")

	# B3 五个 4 → 一个 5，得分 +25
	_load_board(gs, EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n4 4 4 4 4")
	gs.score = 0
	_eq_int("B3 resolve STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_int("B3 score +25", gs.score, 25)
	_eq_str("B3 one tile of 5", gs.board_text(),
		EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n5 . . . .")

	# B4 落点 = 最左上格（用"顶端优先"与"最左列优先"可区分的形状）
	#    cells = (0,2) (1,1) (1,2)：最上行是 row 0 → 取 (0,2)，而不是最左列 (1,1)
	_load_board(gs, ". . 7 . .\n. 7 7 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	var regs: Array = gs.find_all_regions()
	_eq_int("B4 one region", regs.size(), 1)
	if regs.size() == 1:
		_eq_int("B4 target is topmost-then-leftmost", regs[0].target, 2)
	gs.score = 0
	_eq_int("B4 resolve STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_int("B4 score (7+1)*3", gs.score, 24)
	_eq_str("B4 result fell to the bottom of column 2", gs.board_text(),
		EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n. . 8 . .")

	# B6 十字 5 格只算一次：得分 (v+1)*5，能量只 +1
	_load_board(gs, EMPTY_ROW + "\n" + EMPTY_ROW + "\n. 4 . . .\n4 4 4 . .\n. 4 . . .")
	regs = gs.find_all_regions()
	_eq_int("B6 cross detected once", regs.size(), 1)
	if regs.size() == 1:
		_eq_int("B6 size 5", regs[0].size, 5)
	gs.score = 0
	gs.energy = 0
	_eq_int("B6 resolve STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_int("B6 score (4+1)*5 once", gs.score, 25)
	_eq_int("B6 energy +1 only once", gs.energy, 1)
	_eq_str("B6 result fell to the bottom of column 1", gs.board_text(),
		EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n. 5 . . .")

	# B7 顶端区域的结果会在重力阶段下落
	_load_board(gs, "6 6 6 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.score = 0
	_eq_int("B7 resolve STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_int("B7 score (6+1)*3", gs.score, 21)
	_eq_str("B7 result falls to the bottom", gs.board_text(),
		EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n7 . . . .")


func _test_multi_region_round() -> void:
	_section("B5 同一轮多个独立区域全部结算，格子不被重复处理")
	var gs = GS.new(12)
	gs.spawn_enabled = false
	_load_board(gs, "2 2 2 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n5 5 5 . .")
	var regs: Array = gs.find_all_regions()
	_eq_int("two independent regions", regs.size(), 2)
	gs.score = 0
	gs.energy = 0
	_eq_int("resolve STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_int("score = 9 + 18", gs.score, 27)
	_eq_int("energy +2 (one per region)", gs.energy, 2)
	_eq_str("both results present after gravity", gs.board_text(),
		EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n3 . . . .\n6 . . . .")


# ================================================ C. 重力

func _test_gravity() -> void:
	_section("C 重力：每列独立压实、保持顺序、空格只在顶部")
	var gs = GS.new(13)

	# C1/C2 中间有空位 → 上方方块下落且相对顺序不变
	_load_board(gs, "1 . . . .\n. . . . .\n2 . . . .\n. . . . .\n3 . . . .")
	gs.apply_gravity()
	_eq_str("C1/C2 column compacted in order", gs.board_text(),
		EMPTY_ROW + "\n" + EMPTY_ROW + "\n1 . . . .\n2 . . . .\n3 . . . .")

	# C3 结果下方有空位时也能下落
	_load_board(gs, ". . . . .\n9 . . . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.apply_gravity()
	_eq_str("C3 lone tile falls to the bottom", gs.board_text(),
		EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n9 . . . .")

	# C4 各列独立、不左右移动
	_load_board(gs, "1 2 3 4 5\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n6 7 8 9 1")
	gs.apply_gravity()
	_eq_str("C4 columns are independent", gs.board_text(),
		EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n1 2 3 4 5\n6 7 8 9 1")
	var col_ok := true
	for c in GS.BOARD_N:
		if gs.at(3, c) != c + 1 or gs.at(4, c) != (6 + c if c < 4 else 1):
			col_ok = false
	_t("C4 per-column values unchanged", col_ok, gs.board_text())

	# C5 重力后每列的空格都只出现在顶部
	_load_board(gs, "4 . 4 . 4\n. 4 . 4 .\n4 . 4 . 4\n. 4 . 4 .\n4 . 4 . 4")
	gs.apply_gravity()
	var holes_ok := true
	for c in GS.BOARD_N:
		var seen := false
		for r in GS.BOARD_N:
			if gs.at(r, c) == GS.EMPTY:
				if seen:
					holes_ok = false
			else:
				seen = true
	_t("C5 holes only at the top of each column", holes_ok, gs.board_text())
	_eq_int("C5 tile count preserved", gs.tile_count(), 13)


# ================================================ D. 顶部随机补充

func _test_top_refill() -> void:
	_section("D 顶部随机补充：位置=各列顶部空格、取值 {1..5}、可复现、补满 25")
	var gs = GS.new(14)
	_load_board(gs, EMPTY_ROW + "\n" + EMPTY_ROW + "\n1 2 3 4 5\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.apply_gravity()
	_eq_str("fixture settled", gs.board_text(),
		EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n1 2 3 4 5")
	_eq_int("20 empty cells before refill", _count_empty(gs), 20)
	var a0: int = gs.spawn_attempts
	var d0: int = gs.spawns_done
	var added: int = gs.refill_tops()
	_eq_int("D1 one new tile per top hole", added, 20)
	_eq_int("D5 attempts == generated tiles", gs.spawn_attempts - a0, 20)
	_eq_int("D5 generated == top holes", gs.spawns_done - d0, 20)
	_eq_int("D4 board is full again", gs.tile_count(), GS.CELL_COUNT)
	_eq_int("D4 no empty cells left", _count_empty(gs), 0)
	var bottom_ok := true
	for c in GS.BOARD_N:
		if gs.at(4, c) != c + 1:
			bottom_ok = false
	_t("existing tiles were not overwritten", bottom_ok, gs.board_text())
	_t("D2 all refilled values in {1..5}", _all_cells_between(gs, GS.SPAWN_MIN, GS.SPAWN_MAX), gs.board_text())

	# D2 大样本：500 次补充的取值全部合法且 5 个值都出现过
	var counts := {}
	for v in range(GS.SPAWN_MIN, GS.SPAWN_MAX + 1):
		counts[v] = 0
	var out_of_range := 0
	for i in 500:
		_load_board(gs, EMPTY_ROW + "\n" + EMPTY_ROW + "\n1 2 3 4 5\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
		gs.apply_gravity()
		gs.refill_tops()
		for r in 4:
			for c in GS.BOARD_N:
				var v := gs.at(r, c)
				if v < GS.SPAWN_MIN or v > GS.SPAWN_MAX:
					out_of_range += 1
				else:
					counts[v] += 1
	_eq_int("D2 10000 refilled values all in range", out_of_range, 0)
	var lo := 99999
	var hi := 0
	for v in counts:
		if counts[v] < lo:
			lo = counts[v]
		if counts[v] > hi:
			hi = counts[v]
	print("   refill distribution over 10000 samples: ", str(counts))
	_t("D2 every value 1..5 appears", lo > 0, "counts=%s" % str(counts))
	_t("D2 distribution roughly uniform", lo >= 10000 / 10 and hi <= 10000 / 10 * 3, "counts=%s" % str(counts))

	# D3 固定 seed 复现
	var x = GS.new(77)
	var y = GS.new(77)
	x.rng.seed = 555
	y.rng.seed = 555
	for i in 2:
		_load_board(x, EMPTY_ROW + "\n" + EMPTY_ROW + "\n1 2 3 4 5\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
		_load_board(y, EMPTY_ROW + "\n" + EMPTY_ROW + "\n1 2 3 4 5\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
		x.apply_gravity()
		y.apply_gravity()
		x.refill_tops()
		y.refill_tops()
	_eq_str("D3 same seed + same sequence → identical board", x.board_signature(), y.board_signature())
	_eq_str("D3 board text", x.board_text(), y.board_text())


# ================================================ E1 补充触发连锁（受控随机）

func _test_chain_by_refill() -> void:
	_section("E1 补充的新方块触发下一轮合并（受控 seed）")
	# (0,0) 是唯一空格，其两个邻居都是 3 → 只要补出来的是 3 就立刻形成 L 形三连
	var fixture := ". 3 1 2 1\n3 1 2 1 2\n1 2 1 2 1\n2 1 2 1 2\n1 2 1 2 1"
	var gs = GS.new(15)
	_load_board(gs, fixture)
	_eq_int("fixture is full except (0,0)", gs.tile_count(), 24)
	_eq_int("fixture has exactly one hole", _count_empty(gs), 1)
	_t("fixture has no mergeable region", gs.find_all_regions().is_empty(), gs.board_text())

	var desired := 3
	var found := -1
	for s in range(0, 5000):
		var r := RandomNumberGenerator.new()
		r.seed = s
		if r.randi_range(GS.SPAWN_MIN, GS.SPAWN_MAX) == desired:
			found = s
			break
	_t("found a seed producing the desired refill value", found >= 0)

	gs.rng.seed = found
	_eq_int("refill fills the single hole", gs.refill_tops(), 1)
	_eq_int("refilled value landed on top of its column", gs.at(0, 0), desired)
	var regs: Array = gs.find_all_regions()
	_eq_int("refilled tile completed a region", regs.size(), 1)
	if regs.size() == 1:
		_eq_int("region size from refill", regs[0].size, 3)
		_eq_cells("region cells", regs[0].cells, [0, 1, 5])

	gs.spawn_enabled = false                 # 让本轮结算结果唯一可断言
	gs.score = 0
	gs.energy = 0
	_eq_int("chain resolves STABLE", gs.resolve_all(), GS.ResolveResult.STABLE)
	_eq_int("score from the region", gs.score, (3 + 1) * 3)
	_eq_int("energy from the region", gs.energy, 1)
	# 列 0 原有 1,2,1 三个方块 → 合并结果 4 压在这三者之上，落在倒数第 4 行
	_eq_str("board after gravity (order preserved, 4 on top of column 0)", gs.board_text(),
		". . 1 2 1\n4 1 2 1 2\n1 2 1 2 1\n2 1 2 1 2\n1 2 1 2 1")
	_eq_int("column 0 row 1 holds the merged result", gs.at(1, 0), 4)
	_eq_int("column 0 top row is now empty", gs.at(0, 0), GS.EMPTY)
	_eq_int("column 0 keeps its original order below", gs.at(2, 0), 1)
	_eq_int("column 0 keeps its original order below (2)", gs.at(3, 0), 2)
	_eq_int("column 0 keeps its original order below (3)", gs.at(4, 0), 1)
	_t("board is stable afterwards", gs.find_all_regions().is_empty(), gs.board_text())


# ================================================ E 连锁与能量

func _test_chain_and_energy() -> void:
	_section("E2-E6 连锁、能量扣除与上限")
	var gs = GS.new(16)
	gs.spawn_enabled = false
	# E2 两轮连锁：第一轮是玩家直接参与（纵列三个 4 合成后仍是 4）→ 重力后底行 4,4,4
	#     → 第二轮属于自动连锁（4 + 1 = 5）。
	_load_board(gs, PLAYER_CHAIN)
	gs.score = 0
	gs.energy = 2
	_t("E2 tap accepted", gs.tap(2, 0) == true)
	_eq_int("E2 score 12 (player) + 15 (auto chain)", gs.score, 12 + 15)
	_eq_int("E4 one tap costs exactly 1 energy across the whole chain", gs.energy, 3)
	_eq_str("E2 final board after the whole chain", gs.board_text(),
		EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n5 . . . .")
	_t("E2 chain ends on a stable board", gs.find_all_regions().is_empty())

	# E5 能量上限
	_load_board(gs, EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n2 2 2 . .")
	gs.energy = GS.ENERGY_MAX
	gs.score = 0
	gs.resolve_all()
	_eq_int("E5 energy stays capped", gs.energy, GS.ENERGY_MAX)
	_eq_int("E5 score still awarded", gs.score, 9)

	# E6 最后一格能量被扣除后发生合并 → 结算完仍可继续
	_load_board(gs, "2 2 1 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.energy = 1
	gs.score = 0
	gs.revive_left = 1
	gs.phase = GS.Phase.PLAYING
	_t("E6 tap accepted", gs.tap(0, 2) == true)
	_eq_int("E6 energy settles back to 1", gs.energy, 1)
	_eq_int("E6 game continues", gs.phase, GS.Phase.PLAYING)
	# 玩家直接合成：结果保持匹配值 2（不再 +1）
	_eq_int("E6 player result stays 2 at bottom of column 0", gs.at(4, 0), 2)


# ================================================ 点击规则 / 能量 / 复活

func _test_tap_rules() -> void:
	_section("M 点击规则：空格、越界、非法状态")
	var gs = GS.new(17)
	gs.spawn_enabled = false
	_load_board(gs, SINGLE_TILE)
	gs.energy = 3
	gs.score = 0
	var before := gs.board_signature()
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


func _test_energy_and_game_over() -> void:
	_section("J/L 能量扣除与结束判定")
	var gs = GS.new(18)
	gs.spawn_enabled = false
	_load_board(gs, SINGLE_TILE)
	gs.energy = 5
	gs.score = 0
	_t("J tap accepted", gs.tap(0, 0) == true)
	_eq_int("J score +0 without merge", gs.score, 0)
	_eq_int("J energy 5 -> 4", gs.energy, 4)

	_load_board(gs, SINGLE_TILE)
	gs.energy = 1
	gs.revive_left = 1
	gs.phase = GS.Phase.PLAYING
	_t("L tap accepted", gs.tap(0, 0) == true)
	_eq_int("L energy 0", gs.energy, 0)
	_eq_int("L asks for revive", gs.phase, GS.Phase.REVIVE_PROMPT)

	_load_board(gs, SINGLE_TILE)
	gs.energy = 1
	gs.revive_left = 0
	gs.phase = GS.Phase.PLAYING
	gs.tap(0, 0)
	_eq_int("L2 game over without revive left", gs.phase, GS.Phase.GAME_OVER)
	_t("L2 is_game_over()", gs.is_game_over())


func _test_revive() -> void:
	_section("复活：能量 3、次数 -1、棋盘与分数不变")
	var gs = GS.new(19)
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

	_load_board(gs, SINGLE_TILE)
	gs.energy = 1
	gs.tap(0, 0)
	_eq_int("second depletion ends the game", gs.phase, GS.Phase.GAME_OVER)

	var gs2 = GS.new(20)
	gs2.spawn_enabled = false
	_load_board(gs2, SINGLE_TILE)
	gs2.energy = 1
	gs2.tap(0, 0)
	_eq_int("prompt shown", gs2.phase, GS.Phase.REVIVE_PROMPT)
	var sig2: String = gs2.board_signature()
	_t("give_up accepted", gs2.give_up() == true)
	_eq_int("give_up → GAME_OVER", gs2.phase, GS.Phase.GAME_OVER)
	_eq_str("give_up leaves board", gs2.board_signature(), sig2)
	_t("give_up twice refused", gs2.give_up() == false)


# ================================================ E7 连锁上限 → ERROR

func _test_chain_limit_is_error() -> void:
	_section("E7 连锁步数上限：不得静默继续，必须进入 ERROR")
	var gs = GS.new(21)
	gs.spawn_enabled = false
	# 该夹具确定会产生 2 轮：第一轮玩家直接合成，第二轮自动连锁
	_load_board(gs, PLAYER_CHAIN)
	gs.max_chain_steps = 1
	gs.energy = 3
	gs.score = 0
	var accepted: bool = gs.tap(2, 0)
	_t("tap reports failure", accepted == false)
	_eq_int("phase is ERROR", gs.phase, GS.Phase.ERROR)
	_t("error message recorded", gs.error_message != "", gs.error_message)
	_t("board is NOT claimed stable", gs.has_unresolved_matches(), gs.board_text())
	# 第一轮按玩家直接合成的规则已结算完成：结果 4 落在列底，底行 4,4,4 尚未合并
	_eq_int("score from completed rounds kept", gs.score, 4 * 3)
	_eq_int("player round result written before the limit", gs.at(4, 0), 4)
	_eq_int("unresolved row remains", gs.at(4, 1), 4)
	# 玩家参与标记不得让第二轮的终止性保护失效
	var merges: Array = []
	for ev in gs.events:
		if ev.kind == "merge":
			merges.append(ev)
	_eq_int("only the first round resolved", merges.size(), 1)
	if merges.size() == 1:
		_t("round 1 was the player merge", merges[0].regions[0].player_merge == true)
	var frozen: String = gs.board_signature()
	_t("further taps refused", gs.tap(0, 0) == false)
	_eq_str("board frozen after ERROR", gs.board_signature(), frozen)
	_eq_int("resolve_all blocked while ERROR", gs.resolve_all(), GS.ResolveResult.BLOCKED_ERROR)
	_eq_str("board still frozen after blocked resolve", gs.board_signature(), frozen)
	_eq_int("phase stays ERROR", gs.phase, GS.Phase.ERROR)


# ================================================ F4 确定性

func _test_determinism() -> void:
	_section("F4 固定 seed 的完整操作序列确定性（含顶部补充）")
	var coords := [[0, 0], [1, 1], [2, 2], [3, 3], [4, 4], [0, 4], [4, 0], [2, 1], [1, 3], [3, 2]]
	var g1 = GS.new(20261010)
	var g2 = GS.new(20261010)
	var steps := 0
	for i in 60:
		var p: Array = coords[i % coords.size()]
		var r1: bool = g1.tap(p[0], p[1])
		var r2: bool = g2.tap(p[0], p[1])
		_t("tap result identical at step %d" % i, r1 == r2)
		steps += 1
		_eq_int("board stays full after step %d" % i, g1.tile_count(), GS.CELL_COUNT)
		_t("board stable after step %d" % i, g1.find_all_regions().is_empty(), g1.board_text())
		if g1.phase == GS.Phase.REVIVE_PROMPT:
			g1.revive()
			g2.revive()
		elif g1.phase != GS.Phase.PLAYING:
			break
	_eq_str("full-game boards identical", g1.board_signature(), g2.board_signature())
	_eq_int("full-game scores identical", g1.score, g2.score)
	_eq_int("full-game energy identical", g1.energy, g2.energy)
	_eq_int("full-game phases identical", g1.phase, g2.phase)
	_eq_int("full-game refill counts identical", g1.spawns_done, g2.spawns_done)
	_eq_int("full-game refill attempts identical", g1.spawn_attempts, g2.spawn_attempts)
	_t("refills actually happened", g1.spawns_done > 0, "spawns=%d" % g1.spawns_done)
	_t("final board is full", g1.tile_count() == GS.CELL_COUNT, g1.board_text())
	_t("final board is stable", g1.find_all_regions().is_empty(), g1.board_text())


# ================================================ F3 最高分

func _test_score_store() -> void:
	_section("F3 最高分写入与重新读取")
	_remove_test_save()
	var store = SS.new(TEST_SAVE_PATH)
	_eq_int("missing file → 0", store.load_best(), 0)
	_t("save new record accepted", store.save_best(1234) == true)
	_eq_int("reload after save", store.load_best(), 1234)
	_t("lower score does not overwrite", store.save_best(100) == false)
	_eq_int("value kept after lower save", store.load_best(), 1234)
	_t("higher score overwrites", store.save_best(9999) == true)
	_eq_int("value after overwrite", store.load_best(), 9999)

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


# ================================================ P2 动画事件序列

func _event_kinds(gs) -> String:
	var parts := PackedStringArray()
	for ev in gs.events:
		parts.append(str(ev.kind))
	return ",".join(parts)


func _sig(values: PackedInt32Array) -> String:
	var parts := PackedStringArray()
	for v in values:
		parts.append(str(v))
	return ",".join(parts)


func _test_animation_events() -> void:
	_section("P2 事件序列：tap → (merge → gravity → refill) × N → settled")
	var gs = GS.new(30)
	gs.spawn_enabled = false

	# 无合并的点击：只有 tap + settled
	_load_board(gs, SINGLE_TILE)
	gs.energy = 5
	gs.score = 0
	gs.tap(0, 0)
	_eq_int("plain click records 2 events", gs.events.size(), 2)
	_eq_str("plain click kinds", _event_kinds(gs), "tap,settled")
	_eq_int("tap event value", gs.events[0].value, 6)
	_eq_int("tap board_before is the pre-click board", gs.events[0].board_before[0], 5)
	_eq_int("tap board_after applies +1", gs.events[0].board_after[0], 6)
	_eq_str("settled board equals final board", _sig(gs.events[1].board), gs.board_signature())

	# 被拒绝的点击不残留上一轮事件（UI 据此避免重放）
	gs.tap(0, 1)
	_eq_int("refused tap clears events", gs.events.size(), 0)

	# 恰好一轮合并 + 重力（水平三连合成后，结果落到列底，之后棋盘稳定）
	_load_board(gs, "2 2 1 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.energy = 3
	gs.score = 0
	gs.tap(0, 2)
	_eq_str("one round kinds", _event_kinds(gs), "tap,merge,gravity,settled")

	var merge_ev = gs.events[1]
	_eq_int("merge round number", merge_ev["round"], 1)
	_eq_int("merge board_before is pre-merge", merge_ev.board_before[0], 2)
	_eq_int("merge board_after holds the player result (no +1)", merge_ev.board_after[0], 2)
	_eq_int("merge region count", merge_ev.regions.size(), 1)
	if merge_ev.regions.size() == 1:
		_eq_int("region value", merge_ev.regions[0].value, 2)
		_eq_int("region size", merge_ev.regions[0].size, 3)
		_eq_int("region target", merge_ev.regions[0].target, 0)
		_eq_cells("region cells", merge_ev.regions[0].cells, [0, 1, 2])
		_eq_int("region result_value is written by the kernel", merge_ev.regions[0].result_value, 2)
		_t("region is flagged as a player merge", merge_ev.regions[0].player_merge == true)
		# 用事件重放合并：清空区域 → 在目标写 result_value → 必须得到 board_after
		var replay: PackedInt32Array = merge_ev.board_before.duplicate()
		for idx in merge_ev.regions[0].cells:
			replay[idx] = GS.EMPTY
		replay[merge_ev.regions[0].target] = merge_ev.regions[0].result_value
		_eq_str("merge event replays to board_after", _sig(replay), _sig(merge_ev.board_after))

	var grav_ev = gs.events[2]
	_eq_int("gravity move count", grav_ev.moves.size(), 1)
	_eq_int("gravity move lands on the column bottom", grav_ev.moves[0]["to"], 20)
	_eq_int("gravity move keeps the player result value", grav_ev.moves[0]["value"], 2)
	var replay_g: PackedInt32Array = grav_ev.board_before.duplicate()
	for mv in grav_ev.moves:
		replay_g[mv["from"]] = GS.EMPTY
	for mv in grav_ev.moves:
		replay_g[mv["to"]] = mv["value"]
	_eq_str("gravity moves replay to board_after", _sig(replay_g), _sig(grav_ev.board_after))
	_eq_str("gravity board_after equals kernel board", _sig(grav_ev.board_after), gs.board_signature())

	# 关闭补充时轮次里不应出现 refill 事件
	_eq_int("no refill event when refill disabled", 0, _count_kind(gs, "refill"))

	# 开启补充：refill 事件必须能重放出 board_after
	gs.spawn_enabled = true
	_load_board(gs, "2 2 1 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs.energy = 5
	gs.score = 0
	gs.tap(0, 2)
	var refill_ev = null
	for ev in gs.events:
		if ev.kind == "refill":
			refill_ev = ev
			break
	_t("refill event recorded", refill_ev != null, _event_kinds(gs))
	if refill_ev != null:
		var replay_r: PackedInt32Array = refill_ev.board_before.duplicate()
		for sp in refill_ev.spawns:
			replay_r[sp["index"]] = sp["value"]
		_eq_str("refill spawns replay to board_after", _sig(replay_r), _sig(refill_ev.board_after))
		var holes_before := 0
		for v in refill_ev.board_before:
			if v == GS.EMPTY:
				holes_before += 1
		_eq_int("one spawn per empty cell", refill_ev.spawns.size(), holes_before)
		var in_range := true
		for sp in refill_ev.spawns:
			if sp["value"] < GS.SPAWN_MIN or sp["value"] > GS.SPAWN_MAX:
				in_range = false
		_t("spawn values within {1..5}", in_range)

	# 连锁：每一轮都各自带一组 merge/gravity 事件（第一轮玩家直接合成、第二轮自动连锁）
	gs.spawn_enabled = false
	_load_board(gs, PLAYER_CHAIN)
	gs.energy = 3
	gs.score = 0
	gs.tap(2, 0)
	_eq_str("two rounds kinds", _event_kinds(gs), "tap,merge,gravity,merge,gravity,settled")
	_eq_int("round numbers ascend", gs.events[1]["round"], 1)
	_eq_int("second merge round number", gs.events[3]["round"], 2)
	_eq_int("second merge has no gravity move", gs.events[4].moves.size(), 0)
	_eq_int("round 1 result is the player result", gs.events[1].regions[0].result_value, 4)
	_eq_int("round 2 result is v + 1", gs.events[3].regions[0].result_value, 5)
	_t("round 1 flagged as player merge", gs.events[1].regions[0].player_merge == true)
	_t("round 2 is NOT a player merge", gs.events[3].regions[0].player_merge == false)

	# ERROR 轮次以 error 结尾
	var gs3 = GS.new(31)
	gs3.spawn_enabled = false
	_load_board(gs3, PLAYER_CHAIN)
	gs3.max_chain_steps = 1
	gs3.tap(2, 0)
	_eq_str("error turn kinds", _event_kinds(gs3), "tap,merge,gravity,error")
	_eq_int("error turn phase", gs3.phase, GS.Phase.ERROR)

	# 记录事件不改变随机数消费顺序：用独立 RNG 复算补充数值
	var gs4 = GS.new(32)
	gs4.spawn_enabled = true
	_load_board(gs4, EMPTY_ROW + "\n" + EMPTY_ROW + "\n1 2 3 4 5\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	gs4.apply_gravity()
	gs4.rng.seed = 555
	gs4.refill_tops()
	var probe := RandomNumberGenerator.new()
	probe.seed = 555
	var order_ok := true
	for sp in gs4.last_refill_spawns:
		if sp["value"] != probe.randi_range(GS.SPAWN_MIN, GS.SPAWN_MAX):
			order_ok = false
	_eq_int("20 top holes filled", gs4.last_refill_spawns.size(), 20)
	_t("exactly one rng draw per hole, column-major order", order_ok)

	# 记录事件不重复计分 / 不重复回能
	var gs5 = GS.new(33)
	gs5.spawn_enabled = false
	_load_board(gs5, EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n2 2 1 . .")
	gs5.energy = 1
	gs5.score = 0
	gs5.tap(4, 2)
	_eq_int("score counted once (player result 2 * 3)", gs5.score, 2 * 3)
	_eq_int("energy gained once", gs5.energy, 1)
	_eq_int("single merge event", _count_kind(gs5, "merge"), 1)


func _count_kind(gs, kind: String) -> int:
	var n := 0
	for ev in gs.events:
		if ev.kind == kind:
			n += 1
	return n


# ================================================ 玩家直接合成 vs 自动连锁

func _test_player_merge_rules() -> void:
	_section("A/B/C/D 玩家直接合成、同轮其他区域、自动连锁、无点击默认语义")

	# ---- A) 玩家直接参与：横排 2 2 1 → 点击第三格 → 结果仍然是 2（不额外加一）
	var a = GS.new(40)
	a.spawn_enabled = false
	_load_board(a, "2 2 1 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW)
	a.score = 0
	a.energy = 5
	_t("A tap accepted", a.tap(0, 2) == true)
	_eq_int("A merged number stays 2 (no +1)", a.at(4, 0), 2)
	_eq_int("A score = result_value * size = 2 * 3", a.score, 6)
	_eq_int("A energy +1 for the single region", a.energy, 5 - 1 + 1)
	_eq_int("A exactly one merge round", _count_kind(a, "merge"), 1)
	_eq_int("A one tile left on the board", a.tile_count(), 1)
	_eq_str("A final board", a.board_text(),
		EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n2 . . . .")
	var a_reg = a.events[1].regions[0]
	_eq_int("A event value (matched value)", a_reg.value, 2)
	_eq_int("A event result_value", a_reg.result_value, 2)
	_eq_int("A event size", a_reg.size, 3)
	_t("A event player_merge", a_reg.player_merge == true)

	# ---- B) 第一轮两个区域：只有含点击格的那个不加一
	var b = GS.new(41)
	b.spawn_enabled = false
	_load_board(b, "2 2 1 . .\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n5 5 5 . .")
	b.score = 0
	b.energy = 3                           # 起点低于上限，便于观察"每个区域各回 1 点"
	_t("B tap accepted", b.tap(0, 2) == true)
	var b_regs: Array = b.events[1].regions
	_eq_int("B round 1 has two regions", b_regs.size(), 2)
	if b_regs.size() == 2:
		_eq_int("B player region value", b_regs[0].value, 2)
		_eq_int("B player region result (no +1)", b_regs[0].result_value, 2)
		_t("B player region flagged", b_regs[0].player_merge == true)
		_eq_int("B other region value", b_regs[1].value, 5)
		_eq_int("B other region result (v + 1)", b_regs[1].result_value, 6)
		_t("B other region not flagged", b_regs[1].player_merge == false)
		_eq_int("B player region target", b_regs[0].target, 0)
		_eq_int("B other region target", b_regs[1].target, 20)
	_eq_int("B score 2*3 + 6*3", b.score, 6 + 18)
	_eq_int("B energy +2 (one per region)", b.energy, 3 - 1 + 2)
	_eq_int("B player result after gravity", b.at(3, 0), 2)
	_eq_int("B chain result after gravity", b.at(4, 0), 6)
	_eq_int("B two tiles left", b.tile_count(), 2)
	_eq_int("B no second round", _count_kind(b, "merge"), 1)

	# ---- C) 第一轮之后全部自动加一（直接结算、无点击 → 4 轮连锁）
	var c = GS.new(42)
	c.spawn_enabled = false
	_load_board(c, AUTO_CASCADE)
	c.score = 0
	c.energy = 0
	_eq_int("C cascade resolves STABLE", c.resolve_all(), GS.ResolveResult.STABLE)
	var c_merges: Array = []
	for ev in c.events:
		if ev.kind == "merge":
			c_merges.append(ev)
	_eq_int("C four merge rounds", c_merges.size(), 4)
	var all_auto := true
	var all_plus_one := true
	var ascending := true
	var expected_score := 0
	for i in c_merges.size():
		if c_merges[i]["round"] != i + 1:
			ascending = false
		for reg in c_merges[i].regions:
			if reg.player_merge:
				all_auto = false
			if reg.result_value != reg.value + 1:
				all_plus_one = false
			expected_score += reg.result_value * reg.size
	_t("C every later round is an automatic merge", all_auto)
	_t("C every automatic result is v + 1", all_plus_one)
	_t("C round numbers ascend from 1", ascending)
	_eq_int("C score equals the sum of result_value * size", c.score, expected_score)
	_eq_int("C score 9 + 12 + 15 + 18", c.score, 9 + 12 + 15 + 18)
	_eq_int("C energy from four regions", c.energy, 4)
	_eq_str("C final board", c.board_text(),
		EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n6 . . . .")

	# ---- D) 没有玩家点击：直接调用 resolve_all() 时全部按自动合成处理
	var d = GS.new(43)
	d.spawn_enabled = false
	_load_board(d, EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n" + EMPTY_ROW + "\n2 2 2 . .")
	d.score = 0
	d.energy = 0
	_eq_int("D resolves STABLE", d.resolve_all(), GS.ResolveResult.STABLE)
	_eq_int("D result is v + 1", d.at(4, 0), 3)
	_eq_int("D score = 3 * 3", d.score, 9)
	var d_reg = d.events[0].regions[0]
	_t("D not a player merge", d_reg.player_merge == false)
	_eq_int("D event result_value", d_reg.result_value, 3)

	# ---- E) 玩家参与判定不得延续到第二轮（即使点击格仍在原坐标）
	var e = GS.new(44)
	e.spawn_enabled = false
	_load_board(e, PLAYER_CHAIN)
	e.score = 0
	e.energy = 0
	e.tap(2, 0)
	var e_merges: Array = []
	for ev in e.events:
		if ev.kind == "merge":
			e_merges.append(ev)
	_eq_int("E two merge rounds", e_merges.size(), 2)
	if e_merges.size() == 2:
		_t("E round 1 is the player merge", e_merges[0].regions[0].player_merge == true)
		_eq_int("E round 1 result stays v", e_merges[0].regions[0].result_value, 4)
		_t("E round 2 is automatic", e_merges[1].regions[0].player_merge == false)
		_eq_int("E round 2 result is v + 1", e_merges[1].regions[0].result_value, 5)
	_eq_int("E score 12 + 15", e.score, 27)
	_eq_int("E final result at column bottom", e.at(4, 0), 5)
	_eq_int("E only one tile left", e.tile_count(), 1)
