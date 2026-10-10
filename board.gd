extends GridContainer

## 棋盘容器：创建并管理 25 个 TileView，把格子点击翻译成行列坐标后向上转发。
##
## 本脚本不持有任何游戏状态，也不修改分数 / 能量 / 棋盘数值 / 随机数；
## 它只是 GameState.board 的一层"显示器 + 输入转发器"。

const GS = preload("res://game_state.gd")
const TileViewScript = preload("res://tile_view.gd")

## 某个格子被点击（row / col 与 GameState 的坐标一致）。
signal tile_clicked(row: int, col: int)

var _tiles: Array = []
var _input_enabled: bool = true


func _ready() -> void:
	columns = GS.BOARD_N
	if _tiles.is_empty():
		_build_tiles()


func _build_tiles() -> void:
	for r in GS.BOARD_N:
		for c in GS.BOARD_N:
			var tile = TileViewScript.new()
			tile.setup(r, c)
			tile.tile_clicked.connect(_on_tile_clicked)
			add_child(tile)
			_tiles.append(tile)


## 用逻辑内核的棋盘数组刷新全部格子。索引 = r * BOARD_N + c。
func refresh(board_values: PackedInt32Array) -> void:
	if board_values.size() != _tiles.size():
		push_error("board size mismatch: %d cells vs %d tiles" % [board_values.size(), _tiles.size()])
		return
	for i in _tiles.size():
		_tiles[i].set_value(board_values[i])


## 非 PLAYING 阶段禁用棋盘输入（与逻辑内核保持一致）。
func set_input_enabled(enabled: bool) -> void:
	_input_enabled = enabled
	for t in _tiles:
		t.disabled = not enabled


func tile_at(row: int, col: int):
	if row < 0 or row >= GS.BOARD_N or col < 0 or col >= GS.BOARD_N:
		return null
	return _tiles[row * GS.BOARD_N + col]


func tile_count() -> int:
	return _tiles.size()


func _on_tile_clicked(row: int, col: int) -> void:
	if not _input_enabled:
		return
	tile_clicked.emit(row, col)
