class_name ScoreStore
extends RefCounted

## 历史最高分的持久化（P0）。
##
## 只负责读写 user:// 下的一个 ConfigFile，不含任何游戏规则。
## Windows 上 user:// 实际位于 %APPDATA%\Godot\app_userdata\<项目名>\ 。

const DEFAULT_PATH := "user://highscore.cfg"
const SECTION := "score"
const KEY := "high_score"

var path: String = DEFAULT_PATH
var last_error: String = ""


func _init(p_path: String = DEFAULT_PATH) -> void:
	path = p_path


## 读取历史最高分。文件不存在或内容损坏时返回 0（不报错、不崩溃）。
func load_best() -> int:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return 0
	var value = cfg.get_value(SECTION, KEY, 0)
	if typeof(value) != TYPE_INT and typeof(value) != TYPE_FLOAT:
		return 0
	return int(value)


## 仅当 p_score 高于已记录的最高分时才写盘。
## 返回 true 表示刷新了记录（并已写盘）。
func save_best(p_score: int) -> bool:
	if p_score <= load_best():
		return false
	var cfg := ConfigFile.new()
	cfg.load(path)                 # 读取失败无所谓：从空白配置重新建立
	cfg.set_value(SECTION, KEY, p_score)
	var err := cfg.save(path)
	if err != OK:
		last_error = "failed to save %s (error %d)" % [path, err]
		return false
	last_error = ""
	return true
