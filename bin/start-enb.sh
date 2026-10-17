#!/bin/sh
#
# Start this eNodeB (and the core, if this node hosts it) in tmux session
# "ran", with E2/S1AP/MAC captures under /local/logs/e2run/<run-id>/.
# Set E2TERM_SCTP (and E2TERM_PORT) to override the RIC address configured
# at boot.  Stop with: /local/repository/bin/ran-run.sh stop enb
#
# usage: start-enb.sh [run-id]
#

/local/repository/bin/ran-run.sh start enb "$@" || exit 1
exec tmux attach-session -t ran
