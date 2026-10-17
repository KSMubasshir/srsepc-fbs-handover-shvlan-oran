#!/bin/sh
#
# Start srsue and ping the core gateway (IPERF=1 adds an iperf3 client) in
# tmux session "ran".  Stop with: /local/repository/bin/ran-run.sh stop ue
#
# usage: start-ue.sh [run-id]
#

/local/repository/bin/ran-run.sh start ue "$@" || exit 1
exec tmux attach-session -t ran
