#!/bin/bash

# This script waits up to 10 minutes for cloud-init to finish
# Usage: /bin/bash boot_finished_check.sh

retry=20
while [[ $retry -ge 0 ]]; do
    if [ -f /var/lib/cloud/instance/boot-finished ]; then
        break
    else
        retry=$((retry - 1))
        sleep 30
    fi
done
if [ -f /var/lib/cloud/instance/boot-finished ]; then
    echo "Cloud-init completed successfully."
else
    echo "Cloud-init failed to finish."
    exit 1
fi
