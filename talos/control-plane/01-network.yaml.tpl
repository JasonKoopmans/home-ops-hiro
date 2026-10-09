# The node's NIC, address and the shared control-plane VIP, as the documents
# the running config already uses (LinkAliasConfig/LinkConfig/Layer2VIPConfig).
# The legacy machine.network.interfaces also validates, but is not what the
# nodes run. Per-node values come from `data` in topf.yaml; the /24, gateway
# and VIP are the same for every node. A .tpl file is parsed in full, comments
# included, so no double-brace pairs in comments.
---
apiVersion: v1alpha1
kind: LinkAliasConfig
name: ethSel0
selector:
  match: glob("{{ .Node.Data.mac }}", mac(link.hardware_addr))
---
apiVersion: v1alpha1
kind: Layer2VIPConfig
name: 192.168.25.20
link: ethSel0
---
apiVersion: v1alpha1
kind: LinkConfig
name: ethSel0
mtu: 1500
addresses:
  - address: {{ .Node.IP }}/24
routes:
  - gateway: 192.168.25.1
