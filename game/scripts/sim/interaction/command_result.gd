class_name CommandResult
extends RefCounted
## Outcome of one InteractionCommand. On failure nothing was mutated.

var ok := false
var code := ""
var message := ""
var events: Array = []
var command: InteractionCommand


static func success(cmd: InteractionCommand, p_events: Array, msg := "") -> CommandResult:
	var r := CommandResult.new()
	r.ok = true
	r.command = cmd
	r.events = p_events
	r.message = msg
	return r


static func failure(cmd: InteractionCommand, p_code: String, msg: String) -> CommandResult:
	var r := CommandResult.new()
	r.ok = false
	r.command = cmd
	r.code = p_code
	r.message = msg
	return r
