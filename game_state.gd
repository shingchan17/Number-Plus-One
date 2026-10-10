class_name GameState
extends RefCounted

## 数字加一合成游戏 —— 纯逻辑内核（P0.5：连通区域合并 + 重力下落 + 顶部补充）。
##
## 规则：
##   - 上下左右相邻且数值相同的**非空**方块构成一个连通区域；对角线不算连接，空格不参与
##   - 连通区域大小 >= MIN_REGION_SIZE(3) 时，整块合并为一个 v+1 的方块
##   - 合并结果初始落在区域"最左上"格（最小行号；同行取最小列号），随后照常参与重力
##   - 每轮顺序：快照式检测全部区域 → 统一结算（分数/能量）→ 清空 → 写结果 → 全盘重力
##     → 每列顶部空格随机补充 → 重新检测，直到棋盘稳定
##   - 稳定后棋盘一定是满盘（25 个非空格）
##
## 本类不引用任何 Node、不读写任何文件，可在 --headless 下直接实例化并断言。

# ------------------------------------------------------------------ 规则常量
const BOARD_N := 5                      # 棋盘边长
const CELL_COUNT := BOARD_N * BOARD_N   # 25
const EMPTY := 0                        # 空格
const MIN_REGION_SIZE := 3              # 触发合并的最少连通方块数
const INIT_MIN := 1                     # 开局候选数字下界
const INIT_MAX := 2                     # 开局候选数字上界（含）
const SPAWN_MIN := 1                    # 顶部补充数字下界
const SPAWN_MAX := 5                    # 顶部补充数字上界（含）
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


## 一个同值连通区域。
## cells 按索引升序排列（索引 = r * BOARD_N + c），因此 cells[0] 就是"最左上"格。
class Region:
	var value: int = 0
	var size: int = 0
	var cells: PackedInt32Array = PackedInt32Array()
	var target: int = -1            # 合并结果的初始位置（最左上格索引）


# ------------------------------------------------------ 可配置项（默认 = 规则值）
## 开局候选数字。默认 {1, 2}；测试可收窄以构造"无解"场景。
var init_candidates: PackedInt32Array = PackedInt32Array([INIT_MIN, INIT_MAX])
## 初始化搜索节点上限，超过即判定失败（绝不返回含可合并区域的棋盘）。
var init_node_limit: int = INIT_NODE_LIMIT
## 连锁轮次上限。测试可收紧以验证异常处理路径。
var max_chain_steps: int = MAX_CHAIN_STEPS
## 关闭后不做"每列顶部补充"（测试用：让合并/重力的结果保持可精确断言）。
var spawn_enabled: bool = true


# ------------------------------------------------------------------ 运行时状态
## 长度 25 的扁平棋盘，索引 = r * BOARD_N + c，0 表示空格。
var board: PackedInt32Array = PackedInt32Array()
var energy: int = ENERGY_START
var score: int = 0
var revive_left: int = REVIVE_MAX
var phase: int = Phase.PLAYING
var error_message: String = ""
## 顶部补充统计：顶部空格补充尝试次数 / 实际生成的方块数（供测试与调试观察）。
var spawn_attempts: int = 0
var spawns_done: int = 0
## 本类唯一的随机源。顶部补充的数字都从这里取。
var rng: RandomNumberGenerator = RandomNumberGenerator.new()

var _seed: int = 0
var _init_nodes: int = 0
# 初始化用的工作棋盘（成员变量，避免 Packed 数组传参语义带来的歧义）
var _work: PackedInt32Array = PackedInt32Array()
# 洪泛用的 scratch（同样放在成员上，保证写入一定生效）
var _flood_cells: PackedInt32Array = PackedInt32Array()
var _flood_stack: PackedInt32Array = PackedInt32Array()
var _flood_visited: PackedByteArray = PackedByteArray()


func _init(p_seed: int = 0) -> void:
	_seed = p_seed
	new_game()


## 换一个种子并重开一局。
func reseed(p_seed: int) -> void:
	_seed = p_seed
	new_game()


## 开新一局。同一 seed 下整局（含顶部补充）完全可复现。
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
		_fail("initial board generation failed: no layout without a mergeable region exists")


# ==================================================================== 初始化

## 带回溯的随机初始化：填满 25 格，且不存在任何大小 >= MIN_REGION_SIZE 的同值连通区域。
## 失败时返回 false，并把棋盘置为空。
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
		if _work_region_size(index) >= MIN_REGION_SIZE:
			continue                       # 该取值会立刻形成可合并区域，试下一个候选
		if _fill_cells(index + 1):
			return true

	_work[index] = EMPTY                   # 回溯
	return false


## 统计 _work 中与 start 连通（4 邻接、同值、非空）的方块数量。
## 构造过程中 start 之后的格子都还是空格，因此只会向上/向左扩展。
func _work_region_size(start: int) -> int:
	var v := _work[start]
	if v == EMPTY:
		return 0
	var seen := {}
	var queue: Array = [start]
	seen[start] = true
	var count := 0
	while not queue.is_empty():
		var cur: int = queue.pop_back()
		count += 1
		var r := cur / BOARD_N
		var c := cur % BOARD_N
		if r > 0:
			_work_enqueue(cur - BOARD_N, v, seen, queue)
		if r < BOARD_N - 1:
			_work_enqueue(cur + BOARD_N, v, seen, queue)
		if c > 0:
			_work_enqueue(cur - 1, v, seen, queue)
		if c < BOARD_N - 1:
			_work_enqueue(cur + 1, v, seen, queue)
	return count


func _work_enqueue(idx: int, v: int, seen: Dictionary, queue: Array) -> void:
	if seen.has(idx):
		return
	if _work[idx] != v:
		return
	seen[idx] = true
	queue.append(idx)


# ==================================================================== 回合流程

## 玩家点击一格。返回 true 表示这次点击被接受（不代表一定发生了合并）。
func tap(r: int, c: int) -> bool:
	if phase != Phase.PLAYING:
		return false
	if not in_bounds(r, c):
		return false
	var idx := r * BOARD_N + c
	if board[idx] == EMPTY:
		return false                       # 空格不可点击，不消耗能量

	energy -= 1                            # 一次点击只扣 1 点，无论之后多少轮连锁
	board[idx] += 1

	if resolve_all() == ResolveResult.CHAIN_LIMIT_EXCEEDED:
		return false                       # phase 已进入 ERROR

	_settle_after_turn()
	return true


## 反复结算直到棋盘稳定。返回 ResolveResult。
## 超过 max_chain_steps 时进入 ERROR（不静默继续、也不假装已正常结算）。
func resolve_all() -> int:
	if phase == Phase.ERROR:
		return ResolveResult.BLOCKED_ERROR     # ERROR 状态是黏性的
	var steps := 0
	while true:
		var regions := find_all_regions()
		if regions.is_empty():
			break
		steps += 1
		if steps > max_chain_steps:
			_fail("chain step limit exceeded: %d round(s) resolved, %d region(s) left unresolved" % [steps - 1, regions.size()])
			return ResolveResult.CHAIN_LIMIT_EXCEEDED
		_resolve_round(regions)
	return ResolveResult.STABLE


## 结算一轮：基于同一份快照完成 分数/能量 → 清空 → 写结果 → 重力 → 顶部补充。
func _resolve_round(regions: Array) -> void:
	# ① 分数与能量：每个连通区域各结算一次（区域之间互不重叠，天然不会重复计分）
	for reg in regions:
		score += (reg.value + 1) * reg.size
		energy += 1
		if energy > ENERGY_MAX:
			energy = ENERGY_MAX

	# ② 清空全部待合并区域（只用快照里的坐标集合，不边扫描边改棋盘）
	for reg in regions:
		for idx in reg.cells:
			board[idx] = EMPTY

	# ③ 在各自的合并目标位置写入 v + 1
	for reg in regions:
		board[reg.target] = reg.value + 1

	# ④ 全盘重力：所有保留方块（含本轮结果）按列下落
	apply_gravity()

	# ⑤ 每列顶部空格补充随机方块
	if spawn_enabled:
		refill_tops()


## 全盘重力：每列独立处理。保留非空方块的原有上下顺序，把它们压到该列底部。
## 不做任何左右移动，也不交换同列内方块的相对顺序。
func apply_gravity() -> void:
	for c in BOARD_N:
		var write_row := BOARD_N - 1
		for r in range(BOARD_N - 1, -1, -1):
			var v := board[r * BOARD_N + c]
			if v == EMPTY:
				continue
			if write_row != r:
				board[write_row * BOARD_N + c] = v
				board[r * BOARD_N + c] = EMPTY
			write_row -= 1
		while write_row >= 0:
			board[write_row * BOARD_N + c] = EMPTY
			write_row -= 1


## 每列顶部的连续空格各生成一个新方块，取值 {SPAWN_MIN..SPAWN_MAX} 等概率。
## 抽取顺序固定为：列从左到右、同列自上而下 —— 保证固定 seed 完全可复现。
## 返回本次生成的方块数量。
func refill_tops() -> int:
	var added := 0
	for c in BOARD_N:
		for r in BOARD_N:
			if board[r * BOARD_N + c] != EMPTY:
				break                  # 该列顶部连续空格到此为止
			spawn_attempts += 1
			board[r * BOARD_N + c] = rng.randi_range(SPAWN_MIN, SPAWN_MAX)
			spawns_done += 1
			added += 1
	return added


func _settle_after_turn() -> void:
	if energy > 0:
		return
	if revive_left > 0:
		phase = Phase.REVIVE_PROMPT
	else:
		phase = Phase.GAME_OVER


# ==================================================================== 连通区域检测

## 收集当前棋盘上全部"大小 >= MIN_REGION_SIZE 的同值连通区域"。
## 一次快照式扫描：每个格子只归属一个区域，区域之间不重叠。
func find_all_regions() -> Array:
	var regions: Array = []
	_flood_visited = PackedByteArray()
	_flood_visited.resize(CELL_COUNT)
	for i in CELL_COUNT:
		if _flood_visited[i] == 1:
			continue
		var v := board[i]
		if v == EMPTY:
			_flood_visited[i] = 1
			continue
		var n := _flood_from(i, v)
		if n >= MIN_REGION_SIZE:
			var reg := Region.new()
			reg.value = v
			reg.size = n
			reg.cells = _flood_cells.duplicate()
			reg.cells.sort()               # 升序 = 行优先 → cells[0] 即最左上格
			reg.target = reg.cells[0]
			regions.append(reg)
	return regions


## 从 start 出发对 board 做 4 邻接洪泛，结果写入 _flood_cells，返回区域大小。
## 使用成员 scratch 数组，避免 Packed 数组传参语义的歧义。
func _flood_from(start: int, value: int) -> int:
	_flood_cells = PackedInt32Array()
	_flood_stack = PackedInt32Array()
	_flood_stack.append(start)
	_flood_visited[start] = 1
	while not _flood_stack.is_empty():
		var cur := _flood_stack[_flood_stack.size() - 1]
		_flood_stack.remove_at(_flood_stack.size() - 1)
		_flood_cells.append(cur)
		var r := cur / BOARD_N
		var c := cur % BOARD_N
		if r > 0:
			_flood_try(cur - BOARD_N, value)
		if r < BOARD_N - 1:
			_flood_try(cur + BOARD_N, value)
		if c > 0:
			_flood_try(cur - 1, value)
		if c < BOARD_N - 1:
			_flood_try(cur + 1, value)
	return _flood_cells.size()


func _flood_try(idx: int, value: int) -> void:
	if _flood_visited[idx] == 0 and board[idx] == value:
		_flood_visited[idx] = 1
		_flood_stack.append(idx)


## 棋盘上是否还存在待合并的连通区域（ERROR 状态下用于确认"没有假装稳定"）。
func has_unresolved_matches() -> bool:
	return not find_all_regions().is_empty()


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
