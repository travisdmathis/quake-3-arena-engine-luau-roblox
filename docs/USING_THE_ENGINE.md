# Using the engine

## 1. Mount the source

The default Rojo project mounts shared modules at
`ReplicatedStorage/Q3Engine` and authoritative runtime modules at
`ServerScriptService/Q3Engine/services`. You may vendor these folders into a
larger Rojo project, but keep the same relative hierarchy unless you also adapt
the `WaitForChild` paths in the runtime services.

```json
{
  "ReplicatedStorage": {
    "Q3Engine": { "$path": "vendor/q3-engine/src/shared" }
  },
  "ServerScriptService": {
    "Q3Engine": {
      "$className": "Folder",
      "services": { "$path": "vendor/q3-engine/src/server/services" }
    }
  }
}
```

## 2. Supply a map adapter

Create original geometry and describe its gameplay data using
`Q3Engine.maps.MapSchema`. Validate it before a match and convert it to the
immutable shape checked by `MapRuntimeContract`. A game adapter owns creation
of Roblox Parts and must provide the engine with:

- world bounds and kill volumes;
- combat/team spawns with stable IDs and facing vectors;
- exact static-solid queries;
- item spawn definitions;
- jump-pad and teleporter trigger definitions; and
- mover definitions and snapshots when the map uses doors or platforms.

Do not copy Q3 retail BSPs, textures, sounds, or other game data merely because
the engine source is GPL. Engine code and game data have different rights.

## 3. Build the server bootstrap

There is intentionally no drop-in game bootstrap. Your server script should:

1. disable `Players.CharacterAutoLoads` before players are observed;
2. construct and validate the map runtime;
3. start the authoritative frame/entity-slot services;
4. start movement and world-interaction services;
5. start combat, projectiles, items, flags, and match services as needed; and
6. load characters only after movement/combat have reserved a life and spawn.

The server must remain authoritative for movement acceptance, health, armor,
ammo, pickups, projectiles, hits, damage, flags, scoring, and match results.
Treat all client messages as untrusted, bounded input.

Runtime services are separated into modules so a game can inject its map,
admission, persistence, and presentation policies rather than inheriting those
from another experience. Read each service's `Start` signature before wiring it;
several services intentionally require another service as a dependency.

## 4. Build the client integration

Use the shared `Movement`, `CommandSequence`, `CommandQuantization`,
`PredictionReconciliationRules`, and mover/world-query modules to implement
local command replay. Send bounded input commands to your server and reconcile
only against authoritative snapshots. Render remote players from server frames
with `RemoteInterpolationRules`.

Client UI, controls, audio, camera treatment, viewmodels, and VFX are not engine
content and are intentionally absent. Your game supplies them and listens to the
accepted combat/entity events; presentation must never create authoritative
damage or projectiles.

## 5. Verify

Run:

```sh
npm run check
```

The public-boundary check rejects common asset formats, game-content folders,
Roblox asset IDs, place IDs, the private codename, and secret-file patterns.
The remaining checks format, lint, compile, and build the Rojo target.

