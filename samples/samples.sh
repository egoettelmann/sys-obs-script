#!/bin/bash

current_dir="$( dirname -- "$0"; )"

source "${current_dir}/../sos.sh"

check "--config_file=apache/error.cfg"
