#!/usr/bin/env bash
# Stream Kaset's own log output live, while you use the app.
#
# Kaset logs through `DiagnosticsLogger`, which is a set of `os.Logger`s on one subsystem
# (`com.sertacozercan.Kaset`) with one category per area — `player`, `ui`, `app`, `webKit`, `api`,
# `auth`, `history`, and so on (see Sources/Kaset/Utilities/DiagnosticsLogger.swift).
#
# `log stream` is the live side of the same log store `log show` reads: it prints each entry as it is
# emitted, instead of a window of the past. Everything is teed to a file so a running agent (or a
# later `grep`) can read what happened without re-running the app.
#
# The `--info --debug` flags matter. `info` is where most of the app's narrative lives and `debug` is
# where the shell's own diagnostics live; without them `log stream` prints only the default-level
# entries and the stream looks empty while the app is clearly doing something.
#
# Usage:
#   Scripts/stream-logs.sh                # every category
#   Scripts/stream-logs.sh Player         # one category (matches DiagnosticsLogger.player)
#   KASET_LOG_FILE=~/kaset.log Scripts/stream-logs.sh
#
# Stop it with Ctrl-C, or `kill` the background job.
#
# A note on `<private>`: `os.Logger` redacts interpolated values that are not marked
# `privacy: .public`, so some entries read `... <private>`. That is the logger's default and it is
# deliberate. Kaset's own diagnostic entries publish the numbers they carry, which is why the
# instrumented shell/panel lines in this repo are readable; values the app does not mark are the ones
# shown as `<private>`.

set -euo pipefail

SUBSYSTEM="${KASET_LOG_SUBSYSTEM:-com.sertacozercan.Kaset}"
CATEGORY="${1:-}"
LOG_FILE="${KASET_LOG_FILE:-${TMPDIR:-/tmp}/kaset-live.log}"

PREDICATE="subsystem == \"${SUBSYSTEM}\""
if [[ -n "${CATEGORY}" ]]; then
  # `[c]` because the app's categories are capitalised (`UI`, `WebKit`) while they are written
  # lowercase on the command line: an exact match here silently selects nothing, and an empty stream
  # looks exactly like an app that is not logging.
  PREDICATE="${PREDICATE} AND category ==[c] \"${CATEGORY}\""
fi

: >"${LOG_FILE}"

echo "==> Streaming ${SUBSYSTEM}${CATEGORY:+ (category ${CATEGORY})}"
echo "==> Teeing to ${LOG_FILE}   (Ctrl-C to stop)"
echo

# `log stream` writes to stderr, so the pipe has to merge it or `tee` sees nothing.
log stream --style compact --info --debug --predicate "${PREDICATE}" 2>&1 | tee "${LOG_FILE}"
