# Battlebots Arena

A free-for-all robot arena shooter for Roblox, built with Rojo and Luau. Up to 20 players drop into
one arena, collect scrap to level up to Lv 100, pick an upgrade card every second level, and fight
with five different robots. Coins buy new robots in the Garage, and giant bosses show up every few
minutes.

## What's in the game

- **Five robots** with different roles. Range costs toughness: ranged robots hit from far away but
  are fragile and slowed while firing, and close-range robots are heavy and armored.

  | Robot | Weapon | Role |
  |---|---|---|
  | Rookie | Blaster | Ranged (free starter) |
  | Bombard | Accelerating rockets with splash | Ranged |
  | Brawler | Buzzsaw | Melee |
  | Scorcher | Flamethrower | Special |
  | Bomber | Nets that slow; blows itself up, then turns small and fast | Special |

- **Upgrade cards** every second level: stats, mounted attachments (each robot class has its own pool),
  skills (Dash, Shield Pulse, Earth Wall, Null Field, Flipper) and rare weapon variants (Laser Gun,
  Battle Axe, Sledgehammer).
- **Economy:** rare map coins and a coin chest, saved to your profile with ProfileStore. The Garage
  shows every robot's stats and lets you buy and equip them.
- **Bosses:** Inferno Giant, Forge Titan and Grinder. Everyone who hits a boss shares the reward, and
  each boss leaves an arena hazard behind for a few minutes (flame vents, edge hammers, floor saws).
- **Phone and PC controls,** with a third-person camera by default and a top-down view on V.

## Tools

The toolchain is pinned in `rokit.toml` (rojo, lune, selene, luau-lsp). Run `rokit install` once.

## Open it in Studio

Build a place file:

```sh
rojo build default.project.json -o build/battlebots-arena.rbxl
```

Or live-sync while editing: run `rojo serve`, then connect from the Rojo plugin in Studio. Saved
profiles need a published place with Studio access to API services turned on. Without it, ProfileStore
falls back to a mock store that forgets everything when the server stops.

## Checks

```sh
lune run tests/run
selene src
rojo build default.project.json -o build/battlebots-arena.rbxl
rojo sourcemap default.project.json --output sourcemap.json
luau-lsp analyze --platform roblox --sourcemap sourcemap.json --definitions "@roblox=.types/globalTypes.d.luau" --ignore "**/vendor/**" src
```

Get `.types/globalTypes.d.luau` from the luau-lsp repository first. `lune run tests/duel-table` prints
every ranged-vs-melee duel from the balance model, and `lune run tests/fit-curve` refits the XP curve.

## Debug commands

They work for everyone in Studio and for `Config.DebugUserIds` on live servers. Type `/help` in chat
for the full list. A few useful ones:

| Command | Effect |
|---|---|
| `/robot bomber` | Swap your robot |
| `/lvl 50` / `/give <id>` | Jump to a level / apply any upgrade card |
| `/dummy 5` / `/showcase` | Target robots / a line-up of sample robots |
| `/coins 500` / `/resetprofile` | Add coins / reset your saved profile |
| `/boss forge` / `/killboss` / `/hazard saws` | Summon a boss / beat it / start a hazard |

## Layout

| Path | Contents |
|---|---|
| `src/shared` | Config (every tuning number), robot and upgrade data, and pure rule modules (XP curve, offers, hit maths, stats, damage, shop, hazard timing) |
| `src/server` | Arena, robot builder, match flow, combat, pickups, profiles, bosses and hazards, anti-cheat guard, debug commands |
| `src/server/vendor` | ProfileStore by loleris (Apache-2.0), unmodified |
| `src/client` | Camera, input, HUD, Garage, robot visuals, projectiles, pickups, effects |
| `tests` | Lune tests for the pure shared modules, plus the duel balance model |

The server is authoritative: clients only send intent (aim, trigger, skill, card pick, buy and equip
requests).
