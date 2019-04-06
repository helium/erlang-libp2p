#!/usr/bin/env bash

set -ex


. "$HOME/.asdf/asdf.sh"
asdf local erlang 21.3

(
    echo --- cleaning build
    make clean
    echo --- build
    make 2>&1 | tee build.log | sed 's/^\(\x1b\[[0-9;]*m\)*>>>/---/'
)

echo --- ok
