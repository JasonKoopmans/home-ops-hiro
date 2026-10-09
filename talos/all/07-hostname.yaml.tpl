# topf's `host` is only a label; without this the first apply renames every node
# to talos-xxx-xxx. A .tpl file is parsed by Go's template engine in full,
# comments included, so no double-brace pairs in comments.
---
apiVersion: v1alpha1
kind: HostnameConfig
auto: "off"
hostname: {{ .Node.Host }}
