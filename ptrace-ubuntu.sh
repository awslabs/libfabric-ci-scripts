#!/usr/bin/env bash

TARGET_BRANCH=$1
LABEL=$2
if [ ${LABEL} == "ubuntu" ]; then
    if [ ${TARGET_BRANCH} == "v1.9.x" ] || [ ${TARGET_BRANCH} == "v1.8.x" ];then
        sudo sysctl -w kernel.yama.ptrace_scope=0
    fi
fi
