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

## Not yet verified (check on first start)

- Geyser log shows NetherNet enabled, no RakNet warning, no "needs Java 26.3" warning (ViaVersion loaded).
- Whether WebRTC gameplay survives the Envoy UDP proxy (client source address is replaced).
  If joins hang after the trust prompt, move UDP to a Cilium `LoadBalancer` Service
  (`lbipam.cilium.io/ips`) for 19132 instead of the UDPRoute.
- `SPIGET_RESOURCES=19254` (ViaVersion) downloads at start; Spiget outages block startup.

## Allowlist

`ENFORCE_WHITELIST=TRUE`. Java names go in `minecraftServer.whitelist`. Floodgate (Bedrock)
players have prefixed names: add them in-game or via RCON with Floodgate's `fwhitelist add <gamertag>`
(confirm command in the Floodgate docs), and record who was added here:

| Player | Platform | Added |
|---|---|---|

## Backups

`mc-backup` sidecar: RCON save-off/flush, tar.gz every 6h to PVC `minecraft-backupdir`
(`longhorn-no-backup`, 5Gi), pruned after 14 days, skipped while nobody is online.
The world PVC is on `longhorn`, so Longhorn's recurring backups to S3 are the second layer.

Restore test (do once before inviting friends): scale a scratch pod with a new PVC, extract the
newest `/backups/*.tgz` into it, start the server image against it, confirm spawn loads.

## Secret

`app/secret.sops.yaml` holds the SOPS-encrypted `rcon-password`, shared by the server and the
mc-backup sidecar (localhost only). Do not regenerate it: both containers read it, so a changed
value needs a restart of the pod (the reloader annotation is not set on this chart).
