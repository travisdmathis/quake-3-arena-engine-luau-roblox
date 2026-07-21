# Quake III Arena Engine for Roblox

This repository contains the reusable Luau engine work translated from the
GPL-released Quake III Arena engine for Roblox. It is an engine source package,
not a finished Roblox experience.

The public source includes server-authoritative movement, collision, movers,
prediction/reconciliation rules, weapons, projectiles, damage, items, flags,
match rules, entity-frame publication, and generic map contracts. It deliberately
does **not** include any private game content: no maps, geometry, textures,
models, sounds, music, VFX assets, client GUI, lobby, progression, commerce,
place IDs, or publish configuration.

## License and upstream

The translated/derived engine is distributed under
`GPL-2.0-or-later`; see [LICENSE](LICENSE). Source headers identify the relevant
upstream Q3 files and the upstream commit used for the translation. Quake III
Arena game data is not licensed by this repository and is not included.

Quake III Arena and related marks belong to their respective owners. This is an
unofficial community project and is not endorsed by id Software, ZeniMax, Roblox,
or their affiliates.

## Use it in a Roblox game

1. Install [Rojo](https://rojo.space/), Node.js 20+, `luau-compile`,
   [StyLua](https://github.com/JohnnyMorganz/StyLua).
2. Clone this repository and run `npm run check`.
3. Either use `default.project.json` as a starting point or map `src/shared` to
   `ReplicatedStorage/Q3Engine` and `src/server/services` to a server-only folder
   in your own Rojo project.
4. Implement your own bootstrap, map adapter, input/prediction controller, and
   presentation. These are intentionally application-owned boundaries; the
   private game implementations are not part of this distribution.
5. Author original or properly licensed game content against `MapSchema` and
   `MapRuntimeContract`, then start only the services your game needs.

The detailed wiring contract is in [docs/USING_THE_ENGINE.md](docs/USING_THE_ENGINE.md).

## Repository layout

- `src/shared/simulation`: fixed-step movement, collision, prediction contracts,
  world queries, movers, and entity-state rules.
- `src/shared/combat`: weapon, hitscan, projectile, splash, damage, and accuracy rules.
- `src/shared/items`, `ctf`, and `match`: reusable gameplay rules and definitions.
- `src/shared/maps`: generic schemas and validation only; no authored maps.
- `src/server/services`: server-authoritative runtime modules. There is no public
  auto-start script, preventing this repository from becoming a clone of a game.

## Contributing

Do not submit proprietary game data or assets. Engine changes should identify
the corresponding upstream Q3 source path when behavior is translated. Run
`npm run check` before opening a pull request.
