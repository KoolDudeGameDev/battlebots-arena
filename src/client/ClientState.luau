-- Client-side hub: the latest server state and the actions modules call on each
-- other, so the client modules do not require one another in a circle.

local UserInputService = game:GetService("UserInputService")

local ClientState = {
	state = nil :: any, -- latest State push from the server
	aims = {} :: { [number]: number }, -- userId -> turret angle (others)
	localAim = 0,
	firing = false,
	autoFire = true, -- on by default; E or the AUTO button turns it off
	isTouch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled,
	localSkillReadyAt = 0,
	camMode = "third", -- "third" (default) or "top" (D37)
	camYaw = 0, -- third-person facing, same angle convention as aim
	camPitch = nil :: number?, -- third-person camera elevation (radians); nil = Config.Camera.PitchDefault
	fireButtonHeld = false, -- mobile FIRE button (third-person)
	cursorFree = false, -- third-person on PC: Left Alt held, cursor unlocked
	menuOpen = false, -- the Garage is open: the mouse is free
	actions = {} :: {
		pick: (index: number) -> (),
		useSkill: () -> (),
		toggleAuto: () -> (),
		toggleCam: () -> (),
		shake: (amount: number) -> (),
		garage: (open: boolean?) -> (),
		garageRefresh: () -> (),
		kick: (entityId: number) -> (), -- a shot left this robot's gun (recoil)
	},
}

return ClientState
