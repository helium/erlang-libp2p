#!/usr/bin/env bash

set -e

. "$HOME/.asdf/asdf.sh"
asdf local erlang 21.3

(
    set -x
    echo --- cleaning build
    make clean
    echo --- build
    ./rebar3 as test do eunit,ct && ./rebar3 dialyzer 2>&1 | tee build.log | sed 's/^\(\x1b\[[0-9;]*m\)*>>>/---/'
)

echo --- ok
