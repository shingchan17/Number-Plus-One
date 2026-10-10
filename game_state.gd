class_name GameState
extends RefCounted

## 数字加一合成游戏 —— 纯逻辑内核（P0）。
##
## 本类不引用任何 Node、不读写任何文件、不产生任何 UI 副作用，
## 因此可以在无窗口环境下用 `godot --headless --script` 直接实例化并断言。
##
## 规则来源：《最终规则草案 v1.1》+ 用户对次生规则 S1/S2 的补充确认：
##   - 每个消除事件都尝试在随机空格补一个数字，取值 {SPAWN_MIN..SPAWN_MAX} 等概率
##   - 补充的数字参与同一轮之后的重扫，可以继续触发连锁
##   - 随机数统一由本类的 rng 产生（位置与数值都来自同一个 rng）
##   - 开局只用 {INIT_MIN..INIT_MAX}，与补充取值无关

# ------------------------------------------------------------------ 规则常量
const BOARD_N := 5                      # 棋盘边长
const CELL_COUNT := BOARD_N * BOARD_N   # 25
const EMPTY := 0                        # 空格
const MIN_MATCH := 3                    # 构成一次消除的最短连续长度
const INIT_MIN := 1                     # 开局候选数字下界
const INIT_MAX := 2                     # 开局候选数字上界（含）
const SPAWN_MIN := 1                    # 随机补充数字下界
const SPAWN_MAX := 5                    # 随机补充数字上界（含）
const ENERGY_START := 5                 # 开局能量
const ENERGY_MAX := 5                   # 能量上限
const REVIVE_MAX := 1                   # 每局复活次数
const REVIVE_ENERGY := 3                # 复活后能量
const MAX_CHAIN_STEPS := 64             # 连锁轮次上限（终止性保护）
const INIT_NODE_LIMIT := 200000         # 初始化回溯搜索节点上限（防御性）

enum Phase { PLAYING, REVIVE_PROMPT, GAME_OVER, ERROR }
## STABLE = 棋盘已稳定；CHAIN_LIMIT_EXCEEDED = 本轮触发连锁上限，已进入 ERROR；
## BLOCKED_ERROR = 已经处于 ERROR，拒绝继续结算（棋盘状态不可信，不允许被"自动修复"）。
enum ResolveResult { STABLE, CHAIN_LIMIT_EXCEEDED, BLOCKED_ERROR }


## 一个极大同值连续段。first 为段首格索引（横向 = 最左格，纵向 = 最上格）。
class Segment:
	var first: int = -1
	var length: int = 0
	var value: int = 0
	var horizontal: bool = true
	var cells: PackedInt32Array = PackedInt32Array()


# ------------------------------------------------------ 可配置项（默认 = 规则值）
## 开局候选数字。默认 {1, 2}；测试可收窄以构造"无解"场景。
var init_candidates: PackedInt32Array = PackedInt32Array([INIT_MIN, INIT_MAX])
## 初始化搜索节点上限，超过即判定失败（绝不返回含匹配段的棋盘）。
var init_node_limit: int = INIT_NODE_LIMIT
## 连锁轮次上限。测试可收紧以验证异常处理路径。
var max_chain_steps: int = MAX_CHAIN_STEPS
## 关闭后不执行随机补充（用于单独验证合并 / 计分 / 能量规则）。
var spawn_enabled: bool = true


# ------------------------------------------------------------------ 运行时状态
## 长度 25 的扁平棋盘，索引 = r * BOARD_N + c，0 表示空格。
var board: PackedInt32Array = PackedInt32Array()
var energy: int = ENERGY_START
var score: int = 0
var revive_left: int = REVIVE_MAX
var phase: int = Phase.PLAYING
var error_message: String = ""
## 补充尝试次数与成功次数（供测试与调试观察，不参与规则判定）。
var spawn_attempts: int = 0
var spawns_done: int = 0
## 本类唯一的随机源。位置与数值都从这里取。
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

var _seed: int = 0
var _init_nodes: int = 0
var _work: PackedInt32Array = PackedInt32Array()


func _init(p_seed: int = 0) -> void:
	_seed = p_seed
	new_game()


## 换一个种子并重开一局。
func reseed(p_seed: int) -> void:
	_seed = p_seed
	new_game()


## 开新一局。同一 seed 下整局（含补充）完全可复现。
func new_game() -> void:
	rng.seed = _seed
	energy = ENERGY_START
	score = 0
	revive_left = REVIVE_MAX
	spawn_attempts = 0
	spawns_done = 0
	error_message = ""
	if _build_initial_board():
		phase = Phase.PLAYING
	else:
		_fail("initial board generation failed: no match-free layout exists")


# ==================================================================== 初始化

## 带回溯的随机初始化：填满 25 格，且不产生任何横向 / 纵向匹配段。
## 失败时返回 false，并把棋盘置为空（绝不返回含匹配段的棋盘）。
func _build_initial_board() -> bool:
	_work = PackedInt32Array()
	_work.resize(CELL_COUNT)
	_init_nodes = 0
	if not _fill_cells(0):
		board = PackedInt32Array()
		board.resize(CELL_COUNT)
		return false
	board = _work
	return true


## 为 _work[index] 选择一个合法取值并递归；走不通则回溯。
func _fill_cells(index: int) -> bool:
	if index >= CELL_COUNT:
		return true
	_init_nodes += 1
	if _init_nodes > init_node_limit:
		return false

	var candidates := init_candidates.duplicate()
	# 就地 Fisher-Yates（使用统一 rng，固定 seed 下顺序确定）
	for i in range(candidates.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp := candidates[i]
		candidates[i] = candidates[j]
		candidates[j] = tmp

	for v in candidates:
		_work[index] = v
		if _creates_match_at(index):
			continue                      # 该取值非法，试下一个候选
		if _fill_cells(index + 1):
			return true

	_work[index] = EMPTY                  # 回溯：恢复空格后返回上一层
	return false


## 检查把 index 填成 _work[index] 之后，是否在横 / 纵方向形成了 >= MIN_MATCH 的段。
## 只需检查包含 index 的段：更早的格子此前已校验过。
func _creates_match_at(index: int) -> bool:
	var v := _work[index]
	if v == EMPTY:
		return false
	var r := index / BOARD_N
	var c := index % BOARD_N

	var run := 1
	var i := c - 1
	while i >= 0 and _work[r * BOARD_N + i] == v:
		run += 1
		i -= 1
	i = c + 1
	while i < BOARD_N and _work[r * BOARD_N + i] == v:
		run += 1
		i += 1
	if run >= MIN_MATCH:
		return true

	run = 1
	var j := r - 1
	while j >= 0 and _work[j * BOARD_N + c] == v:
		run += 1
		j -= 1
	j = r + 1
	while j < BOARD_N and _work[j * BOARD_N + c] == v:
		run += 1
		j += 1
	return run >= MIN_MATCH


# ==================================================================== 回合流程

## 玩家点击一格。返回 true 表示这次点击被接受（不代表一定发生了消除）。
func tap(r: int, c: int) -> bool:
	if phase != Phase.PLAYING:
		return false
	if not in_bounds(r, c):
		return false
	var idx := r * BOARD_N + c
	if board[idx] == EMPTY:
		return false                       # 空格不可点击，不消耗能量

	energy -= 1
	board[idx] += 1

	if resolve_all() == ResolveResult.CHAIN_LIMIT_EXCEEDED:
		return false                       # phase 已进入 ERROR，拒绝继续游戏

	_settle_after_turn()
	return true


## 反复结算直到棋盘稳定。返回 ResolveResult。
## 超过 max_chain_steps 时进入 ERROR（不静默继续游戏）。
func resolve_all() -> int:
	if phase == Phase.ERROR:
		return ResolveResult.BLOCKED_ERROR     # ERROR 状态是黏性的：不结算、不改棋盘
	var steps := 0
	while true:
		var segs := find_all_segments()
		if segs.is_empty():
			break
		steps += 1
		if steps > max_chain_steps:
			_fail("chain step limit exceeded: %d round(s) resolved, %d match(es) left unresolved" % [steps - 1, segs.size()])
			return ResolveResult.CHAIN_LIMIT_EXCEEDED
		_resolve_round(segs)
	return ResolveResult.STABLE


## 结算一轮：本轮的多个匹配段【同时】成立（横纵交叉处两条线都消除）。
func _resolve_round(segs: Array) -> void:
	# ① 计分与回能：每个消除事件各结算一次
	for s in segs:
		score += (s.value + 1) * s.length
		energy += 1
		if energy > ENERGY_MAX:
			energy = ENERGY_MAX

	# ② 清空所有段格子的【并集】（交叉处共享格只清一次）
	for s in segs:
		for idx in s.cells:
			board[idx] = EMPTY

	# ③ 放置合并结果：按【不同段首格】去重统计，
	#    段首格重合的两段必然同值（它们共享该格），因此只占 1 格。
	var placed := {}
	for s in segs:
		if not placed.has(s.first):
			board[s.first] = s.value + 1
			placed[s.first] = true

	# ④ 每个消除事件都尝试补充一个数字（可能触发下一轮连锁）
	if spawn_enabled:
		for i in segs.size():
			spawn_one()


func _settle_after_turn() -> void:
	if energy > 0:
		return
	if revive_left > 0:
		phase = Phase.REVIVE_PROMPT
	else:
		phase = Phase.GAME_OVER


# ==================================================================== 匹配检测

## 收集当前棋盘上所有的极大匹配段：先横向（r 升序、c 升序），后纵向（c 升序、r 升序）。
func find_all_segments() -> Array:
	var segs: Array = []

	for r in BOARD_N:
		var c := 0
		while c < BOARD_N:
			var v := at(r, c)
			if v == EMPTY:
				c += 1
				continue
			var end := c + 1
			while end < BOARD_N and at(r, end) == v:
				end += 1
			if end - c >= MIN_MATCH:
				segs.append(_make_segment(r, c, end - c, v, true))
			c = end

	for c in BOARD_N:
		var r := 0
		while r < BOARD_N:
			var v := at(r, c)
			if v == EMPTY:
				r += 1
				continue
			var end := r + 1
			while end < BOARD_N and at(end, c) == v:
				end += 1
			if end - r >= MIN_MATCH:
				segs.append(_make_segment(r, c, end - r, v, false))
			r = end

	return segs


func _make_segment(r: int, c: int, length: int, value: int, horizontal: bool) -> Segment:
	var seg := Segment.new()
	seg.horizontal = horizontal
	seg.length = length
	seg.value = value
	var cells := PackedInt32Array()
	for i in length:
		if horizontal:
			cells.append(r * BOARD_N + c + i)
		else:
			cells.append((r + i) * BOARD_N + c)
	seg.cells = cells
	seg.first = cells[0]
	return seg


## 棋盘上是否还残留未结算的匹配段（ERROR 状态下用于确认"没有假装稳定"）。
func has_unresolved_matches() -> bool:
	return not find_all_segments().is_empty()


# ==================================================================== 随机补充

## 尝试在一个随机空格补充一个 {SPAWN_MIN..SPAWN_MAX} 的数字。
## 无空格时返回 false 且不修改棋盘（不报错）。
## 随机顺序固定为：先抽位置、再抽数值 —— 保证固定 seed 下完全可复现。
func spawn_one() -> bool:
	spawn_attempts += 1
	var empties := PackedInt32Array()
	for i in board.size():
		if board[i] == EMPTY:
			empties.append(i)
	if empties.is_empty():
		return false
	var pick := empties[rng.randi_range(0, empties.size() - 1)]
	board[pick] = rng.randi_range(SPAWN_MIN, SPAWN_MAX)
	spawns_done += 1
	return true


# ==================================================================== 复活 / 结束

## 能量归零且仍有复活次数时，玩家可以复活。
func revive() -> bool:
	if phase != Phase.REVIVE_PROMPT or revive_left <= 0:
		return false
	revive_left -= 1
	energy = REVIVE_ENERGY
	phase = Phase.PLAYING
	return true


## 在复活询问界面选择"结束本局"。
func give_up() -> bool:
	if phase != Phase.REVIVE_PROMPT:
		return false
	phase = Phase.GAME_OVER
	return true


func is_playing() -> bool:
	return phase == Phase.PLAYING


func is_game_over() -> bool:
	return phase == Phase.GAME_OVER


func is_errored() -> bool:
	return phase == Phase.ERROR


func _fail(message: String) -> void:
	phase = Phase.ERROR
	error_message = message


# ==================================================================== 小工具

func in_bounds(r: int, c: int) -> bool:
	return r >= 0 and r < BOARD_N and c >= 0 and c < BOARD_N


func at(r: int, c: int) -> int:
	if not in_bounds(r, c):
		return -1
	return board[r * BOARD_N + c]


func set_cell(r: int, c: int, value: int) -> void:
	if in_bounds(r, c):
		board[r * BOARD_N + c] = value


func tile_count() -> int:
	var n := 0
	for v in board:
		if v != EMPTY:
			n += 1
	return n


## 扁平签名，便于断言与比较。
func board_signature() -> String:
	var parts := PackedStringArray()
	for v in board:
		parts.append(str(v))
	return ",".join(parts)


## 多行文本，便于阅读失败信息。"." 表示空格。
func board_text() -> String:
	var lines := PackedStringArray()
	for r in BOARD_N:
		var row := PackedStringArray()
		for c in BOARD_N:
			var v := at(r, c)
			row.append("." if v == EMPTY else str(v))
		lines.append(" ".join(row))
	return "\n".join(lines)


## 从多行文本装载棋盘（测试 / 调试用）。"." 或 "0" 表示空格。
## 只改棋盘，不动 energy / score / phase / rng。
func set_board_from_text(text: String) -> bool:
	var rows := text.strip_edges().split("\n", false)
	if rows.size() != BOARD_N:
		return false
	var cells := PackedInt32Array()
	cells.resize(CELL_COUNT)
	for r in BOARD_N:
		var tokens := rows[r].strip_edges().split(" ", false)
		if tokens.size() != BOARD_N:
			return false
		for c in BOARD_N:
			var token := tokens[c]
			if token == "." or token == "0":
				cells[r * BOARD_N + c] = EMPTY
			elif token.is_valid_int():
				cells[r * BOARD_N + c] = token.to_int()
			else:
				return false
	board = cells
	return true
