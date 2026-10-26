#!/bin/bash
# Double-click to build. Output goes to build.log (used while developing).
cd "$(dirname "$0")"
{ echo "== $(date)"; sw_vers 2>/dev/null; swift --version 2>&1 | head -2; ./build.sh; echo "EXIT $?"; } > build.log 2>&1
echo "EXIT=$(tail -1 build.log)"
