#!/bin/sh
# Removes compiler output and test builds (build/). The library in the script folder stays.
cd "$(dirname "$0")"
rm -rf build
echo "Removed build/"
