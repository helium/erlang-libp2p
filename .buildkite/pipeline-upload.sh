#!/usr/bin/env bash
#
# This script is used to upload the full buildkite pipeline. The steps defined
# in the buildkite UI should simply be:
#
#   steps:
#    - command: ".buildkite/pipeline-upload.sh <pipeline_path>"
#

set -e
cd "$(dirname "$0")"/..

echo --- uploading pipeline "$1"
buildkite-agent pipeline upload "$1"

if [[ $BUILDKITE_BRANCH =~ ^pull ]]; then
  # Add helpful link back to the corresponding Github Pull Request
  buildkite-agent annotate --style info --context pr-backlink \
    "Github Pull Request: https://github.com/helium/nextgate/$BUILDKITE_BRANCH"
fi
