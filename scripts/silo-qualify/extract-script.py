"""Print the shell script (command[2]) of a container in a Job/CronJob manifest as committed at a git ref.

usage: extract-script.py <git-ref> <repo-relative-manifest-path> [--image]
Reads `git show <ref>:<path>` so the harness replays exactly what Flux would apply,
never a paraphrase. With --image prints the container image instead.
"""
import subprocess, sys, yaml

ref, path = sys.argv[1], sys.argv[2]
want_image = "--image" in sys.argv[3:]
text = subprocess.run(["git", "show", f"{ref}:{path}"], check=True, capture_output=True, text=True).stdout
for doc in yaml.safe_load_all(text):
    if not doc or doc.get("kind") not in ("Job", "CronJob"):
        continue
    spec = doc["spec"]
    if doc["kind"] == "CronJob":
        spec = spec["jobTemplate"]["spec"]
    c = spec["template"]["spec"]["containers"][0]
    if want_image:
        print(c["image"])
    else:
        cmd = c["command"]
        assert cmd[:2] == ["/bin/sh", "-c"], cmd[:2]
        sys.stdout.write(cmd[2])
    break
else:
    sys.exit("no Job/CronJob found")
