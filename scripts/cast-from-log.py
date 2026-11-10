#!/usr/bin/env python3
"""Replay what a CI job printed as an asciinema recording, from the run's own log.

    scripts/cast-from-log.py RUN_ID JOB "STEP=COMMAND" [...] > docs/demo/e2e.cast

The e2e needs Linux and a firewall on the host, so it cannot be recorded on a
laptop the way a `make test` can. GitHub keeps every line a job printed, with
the time it was printed: this writes those lines, step by step, as an
asciinema v2 recording. Each STEP is a step name in JOB, shown as `$ COMMAND`
before its output; where the log names its steps UNKNOWN STEP, the step is
the one whose command starts with COMMAND. Times are the log's own, with every wait cut to two
seconds. Two things are left out: the step headers GitHub adds (the command
echo and the environment), and the unindented PASS/FAIL lines a script
prints at the end to repeat its checks. Nothing is reworded.

Needs `gh`, signed in to read the run's log. agg turns the recording into
the README's GIF.
"""
import datetime
import json
import re
import subprocess
import sys

IDLE = 2.0
WIDTH, HEIGHT = 120, 34
STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z ?(.*)$")
SUMMARY = re.compile(r"^(PASS|FAIL)  ")


def when(stamp):
    return datetime.datetime.strptime(stamp[:26], "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=datetime.timezone.utc)


def main():
    if len(sys.argv) < 4:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    run, job, steps = sys.argv[1], sys.argv[2], [s.split("=", 1) for s in sys.argv[3:]]
    repo = subprocess.run(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"],
                          check=True, capture_output=True, text=True).stdout.strip()
    log = subprocess.run(["gh", "run", "view", run, "-R", repo, "--log"],
                         check=True, capture_output=True, text=True).stdout
    # Lines by step name, and by the command in each step's "Run" header: some
    # logs name every step UNKNOWN STEP, and then the command finds it.
    lines, runs, current = {}, [], None
    for raw in log.splitlines():
        parts = raw.split("\t", 2)
        if len(parts) == 3 and parts[0] == job:
            # A step's first line starts with a byte order mark.
            m = STAMP.match(parts[2].lstrip("\ufeff"))
            if m:
                line = (when(m.group(1)), m.group(2))
                if line[1].startswith("##[group]Run "):
                    current = (line[1][len("##[group]Run "):], [])
                    runs.append(current)
                if current:
                    current[1].append(line)
                lines.setdefault(parts[1], []).append(line)
    events, clock, last, first = [], 0.0, None, None

    def emit(t, text):
        nonlocal clock, last, first
        first = first or t
        if last is not None:
            clock += min(max((t - last).total_seconds(), 0.0), IDLE)
        last = t
        events.append([round(clock, 3), "o", text])

    for name, command in steps:
        found = lines.get(name) if name != "UNKNOWN STEP" else None
        if found is None:
            found = next((seg for cmd, seg in runs if cmd.startswith(command)), None)
        if found is None:
            print("no step %r, and no step that runs %r, in job %r of run %s" % (name, command, job, run), file=sys.stderr)
            return 1
        header = False
        for t, text in found:
            if text.startswith("##[group]"):
                header = True
                continue
            if text.startswith("##[endgroup]"):
                header = False
                emit(t, "\r\n\x1b[1m$ %s\x1b[0m\r\n" % command)
                continue
            if header or SUMMARY.match(text) or text.startswith("##["):
                continue
            emit(t, text + "\r\n")
    head = {"version": 2, "width": WIDTH, "height": HEIGHT, "idle_time_limit": IDLE,
            "timestamp": int(first.timestamp()) if first else 0,
            "title": "%s: run %s, %s, replayed from its log" % (repo.split("/")[1], run, job)}
    print(json.dumps(head))
    for e in events:
        print(json.dumps(e))
    return 0


if __name__ == "__main__":
    sys.exit(main())
