# Robot Brawl

A top-down robot arena brawler: players drive robots, pick upgrade cards as they level
and fight each other and bosses across swapping maps.

## Language

### A robot's condition

**Condition**:
A robot's health-side state: health, armor, the front shield, active pods and burn,
and the rules for how hits, healing and burn change them.
_Avoid_: Health (too narrow), vitals, stats (stats are what the build allows)

**Hit**:
One instance of damage arriving at a robot, either direct or splash.
_Avoid_: Attack, damage event

**Direct hit**:
A hit from a single shot or strike aimed at the robot; it can be deflected by armor and
caught by the front shield.
_Avoid_: Normal hit

**Splash**:
A hit from an area: explosions, flames, burn. It is never deflected and passes the
front shield.
_Avoid_: AoE damage

**Armor**:
The robot's regenerating plating from Armor Plating cards; it takes hits before health.
_Avoid_: Shield

**Pod armor**:
Extra armor from an Armor Pod that goes first and runs out after a while.
_Avoid_: Bonus armor

**Front shield**:
The Shield Generator's recharging barrier that soaks direct hits from the front.
_Avoid_: Shield (Shield Pulse is a different thing)

**Shield Pulse**:
A skill that blocks every direct hit for a moment and halves splash.
_Avoid_: Shield, bubble

**Burn**:
Damage over time after being set alight by flames, a boss or lava, credited to whoever
set it.
_Avoid_: Fire damage, DoT
