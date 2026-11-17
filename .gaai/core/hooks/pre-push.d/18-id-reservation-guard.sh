#!/usr/bin/env bash
# Pre-push validator : every new Epic or Story id must be reserved through allocate-id.sh.
#
# The rules have long said that ids come from .gaai/core/scripts/lib/allocate-id.sh whenever
# several sessions may write the backlog, but nothing checked it at publication. A session that
# picked "the next number" by scanning the backlog collided silently with a session that had
# reserved that number properly: the first push won, and the honest session had to renumber.
#
# This hook refuses a push that adds an id with no reservation in the shared record
# refs/gaai/reservations, or with a reservation that belongs to another host's holder token.
# It also runs on a direct push to the integration branch, which no hosted check can stop.
# The rule, its exemptions and its limits are documented in the library it calls.
#
# Cost : one ls-remote, at most one fetch, and two git grep passes over the backlog family.
# Failure mode : push aborted, naming each offending id and how to re-reserve it. Fails closed
#                when the remote's reservation record cannot be read.

set -u

ROOT="$(git rev-parse --show-toplevel)" || exit 1
GUARD="$ROOT/.gaai/core/scripts/lib/id-reservation-guard.sh"

if [ ! -f "$GUARD" ]; then
  echo "" >&2
  echo "❌ pre-push: $GUARD is missing — push aborted." >&2
  echo "   The hook and its library ship together; restore the framework files." >&2
  echo "" >&2
  exit 1
fi

exec bash "$GUARD" pre-push "$@"
