#!/bin/bash
#

shellcheck -P ./ -x -o all ${1:-install.sh scripts/*}
