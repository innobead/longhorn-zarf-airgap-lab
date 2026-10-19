#!/usr/bin/env bash
# Laptop helper: talk to the lab node over SSM using terraform outputs.
set -euo pipefail
cd "$(dirname "$0")/../terraform"

out() { terraform output -raw "$1"; }
ID=$(out instance_id); REGION=$(out region)
ssm() { aws ssm start-session --region "$REGION" --target "$ID" "$@"; }

case "${1:-shell}" in
  shell)   ssm ;;
  lab)     shift; ssm --document-name AWS-StartInteractiveCommand --parameters "command=sudo -i lab $*" ;;
  demo)    ssm --document-name AWS-StartInteractiveCommand --parameters 'command=sudo -i lab demo' ;;
  log)     ssm --document-name AWS-StartInteractiveCommand --parameters 'command=sudo tail -f /var/log/lab-bootstrap.log' ;;
  ui)      echo "Longhorn UI -> http://localhost:8080"
           ssm --document-name AWS-StartPortForwardingSession --parameters portNumber=30080,localPortNumber=8080 ;;
  podinfo) echo "podinfo -> http://localhost:9898"
           ssm --document-name AWS-StartPortForwardingSession --parameters portNumber=30898,localPortNumber=9898 ;;
  *) echo "usage: $0 shell|lab <args>|demo|log|ui|podinfo"; exit 1 ;;
esac
