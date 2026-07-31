#!/usr/bin/env bash
# Corre la suite dentro del contenedor. Uso:
#   ./tests/run.sh                       -> toda la suite
#   ./tests/run.sh cmake_builder_spec    -> un solo spec
set -euo pipefail

cd "$(dirname "$0")/.."

docker build -q -t cmake-nvim-dap-test . >/dev/null

opts="{ minimal_init = 'tests/minimal_init.lua', timeout = 300000 }"
if [ $# -gt 0 ]; then
  cmd="PlenaryBustedDirectory tests/$1.lua $opts"
else
  cmd="PlenaryBustedDirectory tests/ $opts"
fi

exec docker run --rm -v "$PWD:/plugin:ro" cmake-nvim-dap-test \
  nvim --headless -u tests/minimal_init.lua -c "$cmd"
