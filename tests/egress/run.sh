#!/usr/bin/env bash
# tests/egress/run.sh reference|defaults - what the Coder server looks up on
# its own, with this repository's settings or with Coder's defaults.
#
# The e2e gates the reference half (step 9 of tests/e2e/run.sh). This is the
# other half, the one the gate cannot show: with the defaults
# (tests/egress/values-defaults.yaml) the same measurement sees every name
# a default dials, which is what makes an empty list in the reference run
# mean something. A measurement that never saw a name proves nothing.
#
# The server has no way to the internet in either run (since v1.1.0 the 443
# rule is optional, manifests/optional/), so a default that dials out is seen
# asking for the name and sends nothing: no telemetry leaves a CI run, no
# update check reaches GitHub.
#
# Run on a fresh cluster: the sandbox's kind cluster and gVisor, then
# `scripts/dns-log.sh on`, then this. It installs Coder itself. Prints one
# "name<TAB>count" per outside name and writes a table to
# $GITHUB_STEP_SUMMARY when set.
set -euo pipefail
cd "$(dirname "$0")/../.."
profile="${1:?reference or defaults}"
window="${EGRESS_WINDOW:-180}"

case "$profile" in
  reference) values="" ;;
  defaults) values="tests/egress/values-defaults.yaml" ;;
  *) echo "profile is reference or defaults" >&2; exit 2 ;;
esac

if [ "$profile" = defaults ]; then
  CODER_VALUES="$values" ./scripts/install-coder.sh
else
  ./scripts/install-coder.sh
fi

started="$(kubectl -n coder get pods -l app.kubernetes.io/name=coder -o jsonpath='{.items[0].status.startTime}')"
echo "the server started at $started; logging its lookups for ${window}s"
sleep "$window"
raw="$(FROM="$started" ./scripts/dns-log.sh names coder app.kubernetes.io/name=coder)"
names="$(grep -v '^#' <<<"$raw" || true)"
total="$(awk -F'\t' '$1 == "#total" {print $2}' <<<"$raw")"
printf '%s\n' "$names"
echo "every lookup by the server in the window, cluster names included: ${total:-0}"
if [ "${total:-0}" -eq 0 ]; then echo "the resolver logged nothing from the server: the measurement is blind" >&2; exit 1; fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### What the Coder server looked up on its own: $profile"
    echo
    echo "Its first ${window} seconds, no template pushed, from the cluster resolver's log."
    echo
    echo "| name | lookups |"
    echo "|---|---|"
    if [ -n "$names" ]; then awk -F'\t' '{printf "| %s | %s |\n", $1, $2}' <<<"$names"; else echo "| (none) | 0 |"; fi
  } >>"$GITHUB_STEP_SUMMARY"
fi
# The defaults run must see something, or the measurement is blind.
if [ "$profile" = defaults ] && [ -z "$names" ]; then echo "the defaults run saw no name: the measurement is blind" >&2; exit 1; fi
if [ "$profile" = reference ] && [ -n "$names" ]; then echo "the reference server looked up names on its own" >&2; exit 1; fi
exit 0
