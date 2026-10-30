"""Write the chart post-job's ConfigMap `initialize` script (and fake root creds) to a directory, mimicking
the projected volume mounted at /config in the rendered minio-post-job.
usage: chart-initialize.py <rendered.yaml> <outdir> <rootUser> <rootPassword>"""
import sys, os, yaml
rendered, out, user, pw = sys.argv[1:5]
os.makedirs(out, exist_ok=True)
for d in yaml.safe_load_all(open(rendered)):
    if d and d.get("kind") == "ConfigMap" and "initialize" in (d.get("data") or {}):
        open(os.path.join(out, "initialize"), "w").write(d["data"]["initialize"])
open(os.path.join(out, "rootUser"), "w").write(user)
open(os.path.join(out, "rootPassword"), "w").write(pw)
