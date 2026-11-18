--!strict
-- The timing curves behind robot animation (D94): how fast a saw spins up, how the
-- Scorcher heats and cools, the hammer's smash, the Flipper's kick, the Null Field
-- dome opening, lamp blinks. Pure: Config.Presentation.motion is passed in, so Lune
-- pins every curve. Robots.luau's animators apply them to parts.

local RobotMotion = {}

-- Saw spin rate one frame on: eases toward the attack or idle speed, never snaps.
function RobotMotion.sawRate(m: any, rate: number, attacking: boolean, dt: number): number
	local target = if attacking then m.sawAttackSpin else m.sawIdleSpin
	return rate + (target - rate) * math.min(1, dt * m.sawEase)
end

-- The saw loop's volume and pitch at a spin rate.
function RobotMotion.sawSound(m: any, rate: number): (number, number)
	local f = rate / m.sawAttackSpin
	return 0.08 + 0.32 * f, 0.7 + 0.4 * f
end

-- Scorcher heat (0-1) one frame on: rises while firing, cools after.
function RobotMotion.heat(m: any, heat: number, attacking: boolean, dt: number): number
	return math.clamp(heat + dt * (if attacking then m.heatUp else -m.heatDown), 0, 1)
end

function RobotMotion.smashRest(m: any): number
	return math.rad(m.smashRestDegrees)
end

-- Sledgehammer pitch t seconds into a smash (D80): lifts a little further back,
-- slams onto the ground by the server's windup, holds, then rises back to rest.
function RobotMotion.smashAngle(m: any, t: number): number
	local rest, lift = math.rad(m.smashRestDegrees), math.rad(m.smashLiftDegrees)
	if t < m.smashLiftTime then
		return rest + (lift - rest) * math.sin(t / m.smashLiftTime * math.pi / 2)
	elseif t < m.smashSlamTime then
		return lift * (1 - ((t - m.smashLiftTime) / (m.smashSlamTime - m.smashLiftTime)) ^ 2)
	elseif t < m.smashHoldTime then
		return 0
	elseif t < m.smashRestTime then
		return rest * ((t - m.smashHoldTime) / (m.smashRestTime - m.smashHoldTime))
	end
	return rest
end

-- Flipper plate pitch t seconds after a flip: kicks up, then settles.
function RobotMotion.flipAngle(m: any, t: number): number
	local up = if t < m.flipUpTime then t / m.flipUpTime
		elseif t < m.flipDownTime then 1 - (t - m.flipUpTime) / (m.flipDownTime - m.flipUpTime)
		else 0
	return math.rad(m.flipDegrees) * up
end

-- How far the Null Field dome has opened (0-1), t seconds after it appears.
function RobotMotion.fieldOpen(m: any, t: number): number
	return 1 - (1 - math.min(1, t / m.fieldOpenTime)) ^ 3
end

-- Whether a lamp blinking at hz is lit at time t.
function RobotMotion.blinkOn(t: number, hz: number): boolean
	return (t * hz) % 1 < 0.5
end

return RobotMotion
