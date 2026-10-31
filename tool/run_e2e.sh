#!/usr/bin/env bash
# The shared runner owns only fresh, labelled Docker resources. It never drops
# a host database, kills a process using a port, or reuses production services.
set -euo pipefail

pos_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cloud_dir=${POS_CLOUD_DIR:-$pos_dir/../cloud-pos}
if [[ ! -f "$cloud_dir/scripts/test-pos-integration.sh" && -z ${POS_CLOUD_DIR:-} ]]; then
  cloud_dir="$pos_dir/../claoud-pos-nusantara"
fi
if [[ ! -f "$cloud_dir/scripts/test-pos-integration.sh" ]]; then
  echo 'Set POS_CLOUD_DIR to the merged Cloud POS checkout containing scripts/test-pos-integration.sh.' >&2
  exit 2
fi
cloud_dir=$(cd "$cloud_dir" && pwd)
exec "$cloud_dir/scripts/test-pos-integration.sh" --phase flutter --flutter "$pos_dir" "$@"
