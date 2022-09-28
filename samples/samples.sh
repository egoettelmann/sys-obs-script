#!/bin/bash

current_dir="$( dirname -- "$0"; )"

source "${current_dir}/../sos"

check "--config_file=apache/error.cfg"
