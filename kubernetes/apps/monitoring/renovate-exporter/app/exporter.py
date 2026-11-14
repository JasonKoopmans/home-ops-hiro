#!/usr/bin/env python3
"""Prometheus exporter for the Renovate pull requests of one GitHub repository.

Polls the GitHub REST API in the background every POLL_INTERVAL_SECONDS and
serves the cached result on /metrics, so a Prometheus scrape never costs an API
call. Standard library only; it runs on the stock python image.

Metrics:
  renovate_pr_open_created_timestamp_seconds{number,type}  one series per open PR
  renovate_prs_created_total / renovate_prs_merged_total   all-time counts (search API)
  renovate_last_merged_timestamp_seconds                   newest merge among recent closed PRs
  renovate_exporter_up                                     1 if the last poll worked
  renovate_exporter_last_success_timestamp_seconds
"""
import calendar
import json
import os
import threading
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REPO = os.environ["GITHUB_REPO"]  # owner/name
BOT_LOGIN = os.environ.get("RENOVATE_LOGIN", "renovate[bot]")  # login in the pulls API
SEARCH_AUTHOR = os.environ.get("RENOVATE_SEARCH_AUTHOR", "app/renovate")  # author: qualifier
INTERVAL = int(os.environ.get("POLL_INTERVAL_SECONDS", "300"))
TOKEN = os.environ.get("GITHUB_TOKEN", "")  # optional; public repo reads work without it
PORT = int(os.environ.get("PORT", "9100"))

state = {"up": 0, "last_success": 0.0, "open": [], "created": None, "merged": None, "last_merged": None}
lock = threading.Lock()


def get(url):
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "renovate-exporter"}
    if TOKEN:
        headers["Authorization"] = "Bearer " + TOKEN
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=20) as r:
        return json.load(r)


def epoch(ts):
    return calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))


def pr_type(labels):
    for label in labels:
        if label["name"].startswith("type/"):
            return label["name"][len("type/"):]
    return "unknown"


def search_count(extra):
    q = urllib.parse.quote("repo:%s is:pr author:%s %s" % (REPO, SEARCH_AUTHOR, extra))
    return get("https://api.github.com/search/issues?per_page=1&q=" + q)["total_count"]


def poll():
    # 100 is the API page maximum; far above the open Renovate PRs this repo carries.
    pulls = get("https://api.github.com/repos/%s/pulls?state=open&per_page=100" % REPO)
    open_prs = [
        (p["number"], pr_type(p["labels"]), epoch(p["created_at"]))
        for p in pulls
        if p["user"]["login"] == BOT_LOGIN
    ]
    # The 100 most recently updated closed PRs: a Saturday wave merges ~30, so the newest
    # merge is always in here unless nothing has merged for a long while, in which case the
    # previous value is kept below.
    closed = get("https://api.github.com/repos/%s/pulls?state=closed&sort=updated&direction=desc&per_page=100" % REPO)
    merge_times = [epoch(p["merged_at"]) for p in closed if p["user"]["login"] == BOT_LOGIN and p.get("merged_at")]
    created = search_count("")
    merged = search_count("is:merged")
    with lock:
        state.update(up=1, last_success=time.time(), open=open_prs, created=created, merged=merged)
        if merge_times:
            state["last_merged"] = max(merge_times)


def poll_forever():
    while True:
        try:
            poll()
        except Exception as e:  # keep serving the last good values and report up=0
            with lock:
                state["up"] = 0
            print("poll failed: %s" % e, flush=True)
        time.sleep(INTERVAL)


def render():
    with lock:
        s = dict(state)
    out = [
        "# HELP renovate_exporter_up 1 if the last GitHub poll succeeded.",
        "# TYPE renovate_exporter_up gauge",
        "renovate_exporter_up %d" % s["up"],
        "# HELP renovate_exporter_last_success_timestamp_seconds Time of the last successful poll.",
        "# TYPE renovate_exporter_last_success_timestamp_seconds gauge",
        "renovate_exporter_last_success_timestamp_seconds %d" % s["last_success"],
    ]
    if s["last_success"]:
        out += [
            "# HELP renovate_pr_open_created_timestamp_seconds Creation time of each open Renovate PR.",
            "# TYPE renovate_pr_open_created_timestamp_seconds gauge",
        ]
        out += [
            'renovate_pr_open_created_timestamp_seconds{number="%d",type="%s"} %d' % pr
            for pr in sorted(s["open"])
        ]
        out += [
            "# HELP renovate_prs_created_total Renovate PRs ever opened, merged or not.",
            "# TYPE renovate_prs_created_total counter",
            "renovate_prs_created_total %d" % s["created"],
            "# HELP renovate_prs_merged_total Renovate PRs ever merged.",
            "# TYPE renovate_prs_merged_total counter",
            "renovate_prs_merged_total %d" % s["merged"],
        ]
        if s["last_merged"] is not None:
            out += [
                "# HELP renovate_last_merged_timestamp_seconds Merge time of the newest merged Renovate PR.",
                "# TYPE renovate_last_merged_timestamp_seconds gauge",
                "renovate_last_merged_timestamp_seconds %d" % s["last_merged"],
            ]
    return "\n".join(out) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/metrics":
            body, ctype = render().encode(), "text/plain; version=0.0.4"
        elif self.path == "/healthz":
            body, ctype = b"ok\n", "text/plain"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):  # no per-scrape access log
        pass


if __name__ == "__main__":
    threading.Thread(target=poll_forever, daemon=True).start()
    ThreadingHTTPServer(("", PORT), Handler).serve_forever()
