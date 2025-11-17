extends Control

var gameCenter: GameCenterManager
var local: AppleLocalPlayer

func _ready() -> void:
	gameCenter = GameCenterManager.new()
	local = gameCenter.local_player
	#gameCenter.load_leaderboards(["BOARD_1", "BOARD_2"])
	print("ONREADY: game center, is %s" % gameCenter)
	print("ONREADY: local, is auth: %s" % local.is_authenticated)
	print("ONREADY: local, player ID: %s" % local.game_player_id)

func _on_button_pressed() -> void:
	var player = gameCenter.local_player
	print("Got %s" % player)
	print("Fetching the other object: %s" % player.is_authenticated)
	$auth_result.text = "Instantiated"
	gameCenter.authentication_error.connect(func(error: String) -> void:
		$auth_result.text = error
		)
	gameCenter.authentication_result.connect(func(status: bool) -> void:
		if status:
			$auth_state.text = "Authenticated"
			gameCenter.local_player.load_photo(true, func(data: PackedByteArray) -> void: 
				print("Got the image %d" % data.size())
			)
		else:
			$auth_state.text = "Not Authenticated"
		)
	gameCenter.authenticate()
