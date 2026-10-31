# Minecraft (Paper + Geyser + Floodgate)

Family server for Java and Bedrock players. App: `kubernetes/apps/default/minecraft/`.

## How Bedrock gets in

Geyser runs in the Paper pod with NetherNet (Bedrock 26.60 dropped RakNet). Built-in signaling
needs **TCP and UDP on the same port, 19132**. Path today (LAN only):

`envoy-internal` listeners `minecraft-bedrock-signaling` (TCP) and `minecraft-bedrock` (UDP)
-> `TCPRoute minecraft-bedrock-signaling` / `UDPRoute minecraft-bedrock` -> Service `minecraft` 19132.

Geyser tells clients to connect to `-DgeyserAdvertiseAddresses` = `${ENVOY_INTERNAL_ADDR}`.
Port 25565 (Java) stays on its own TCPRoute; RCON (25575) is never routed.

Root cause of the old outage-in-waiting: `extraPorts` sat at the HelmRelease top level, but
the chart reads `minecraftServer.extraPorts`, so the Service had no 19132 and the UDPRoute had no backend.

## Sizing and later steps

Deliberately small to start: world PVC stays 1Gi, backup PVC 5Gi. Raise `minecraft-pvc` in
`app/pvc.yaml` (Longhorn expands online) once the first week of play shows growth, and watch
`LonghornVolumeUsageHigh`. Backup size and retention may need raising with it.

Tailscale is the planned next step for remote play: operator in its own `tailscale` namespace, a
second Service with `loadBalancerClass: tailscale` carrying TCP+UDP 19132, and
`geyserAdvertiseAddresses` pointed at the tailnet name. The LAN gateway path stays until then.

## Verified live (2026-10-31)

- Geyser starts with NetherNet from system properties (`Transport set from system property: nethernet`,
  built-in signaling on 19132). The flags are plain `-D` options in `jvmOpts` (`JVM_OPTS`): itzg's
  `JVM_DD_OPTS` splits on **spaces**, so a comma list reached Geyser as one value and it stayed on RakNet.
- `envoy-internal` accepts the TCP and UDP listeners on 19132 together (`Programmed`, no `ProtocolConflict`).
- A Bedrock client on the LAN joins end to end through the Envoy TCP and UDP routes; WebRTC gameplay
  survives the proxy. The `juice: Send failed, errno=101` warnings are failed ICE candidates and are harmless.
- ViaVersion loads (`SPIGET_RESOURCES=19254`); Spiget outages would block startup.
- The backup PVC's `storageClass` must sit at `mcbackup.persistence.storageClass`, not under `backupDir`
  (the chart ignores the latter). A PVC's class is immutable, so fixing it needs the claim deleted first.

Still unproven: restore test (below), Longhorn snapshot of `minecraft-pvc` before risky changes, and
`Kubeworld` size on the 1Gi volume.

## Allowlist

`ENFORCE_WHITELIST=TRUE`. Java names live in `minecraftServer.whitelist`; the list in Git is the
starting point after a pod restart. Anything added by hand below is **lost on restart** unless it
is also in Git.

Bedrock players appear to the server with a `.` prefix (`smileitsjake` is `.smileitsjake`); the dot is
Floodgate's, not part of the gamertag.

### Adding a Bedrock player

`fwhitelist add <gamertag>` fails for anyone the server has not met: Floodgate resolves the name through
GeyserMC's API, which only knows gamertags it has seen
(`Got an error from requesting the xuid of a Bedrock player: Unable to find user in our cache`).
`rcon-cli` prints nothing either way, so read the log. Use the Floodgate UUID instead:

1. Ask the player to try joining once. The log shows `Disconnecting ...: You are not whitelisted`.
2. Turn enforcement off, have them join and stay connected:
   `kubectl -n default exec deploy/minecraft -c minecraft -- rcon-cli "whitelist off"`
3. Read their UUID from the log:
   `kubectl -n default logs deploy/minecraft -c minecraft | grep 'Floodgate player logged in as .* joined'`
   (`00000000-0000-0000-0009-<xuid in hex>`).
4. Add the UUID and turn enforcement back on:
   `rcon-cli "fwhitelist add <uuid>"`, then `rcon-cli "whitelist on"`. Do not skip `whitelist on`.
5. Have them join again. A success logs `Floodgate player logged in as .<name> joined`.

Do not use name-based `fwhitelist add`, and do not expect `whitelist list` to show Floodgate entries
under a readable name.

Record who was added (UUIDs are not secret but are tied to a person):

| Player | Platform | UUID | Added |
|---|---|---|---|
| smileitsjake | Bedrock | `00000000-0000-0000-0009-01f38cdc5ceb` | 2026-10-31 |

Open item: make the list survive restarts by putting Bedrock UUIDs in Git. `MicroGachou` is on the live
list but not in `minecraftServer.whitelist`; it would be dropped on the next restart.

## Backups

`mc-backup` sidecar: RCON save-off/flush, tar.gz every 6h to PVC `minecraft-backupdir`
(`longhorn-no-backup`, 5Gi), pruned after 3 days (12 archives; a guess sized to the PVC, retention is
time-only so a full volume fails silently: watch `LonghornVolumeUsageHigh` for `minecraft-backupdir`), skipped while nobody is online.
The world PVC is on `longhorn`, so Longhorn's recurring backups to S3 are the second layer.

Restore test (do once before inviting friends): scale a scratch pod with a new PVC, extract the
newest `/backups/*.tgz` into it, start the server image against it, confirm spawn loads.

## Secret

`app/secret.sops.yaml` holds the SOPS-encrypted `rcon-password`, shared by the server and the
mc-backup sidecar (localhost only). Do not regenerate it: both containers read it, so a changed
value needs a restart of the pod (the reloader annotation is not set on this chart).
