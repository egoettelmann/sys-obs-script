#!/bin/bash

# TODO: add support for email templates (including HTML, see https://gist.github.com/EricTendian/464a44a5874f985654d79609fd4885f8)
# TODO: check following project for templating https://github.com/nextrevision/sempl
# TODO: add 'update' command to retrieve latest version of script
# TODO: add 'status' command to retrieve status of cron scheduling registration
# TODO: add 'schedule' command to register cron job for script
# TODO: OPTIONAL - add disk space check
# TODO: OPTIONAL - add http status checks

__sos_script_version="0.0.2"

# Defining current folder
__sos_current_dir="$( dirname -- "$0"; )"

# Default value for logging
__sos_verbosity=2

############################################################################
# Utils methods
############################################################################

# Logging function.
#
# $1 - the level of the log message
# $2 - the message to log
#
# Logs the message to standard output if the level is greater or equal to ${__sos_verbosity}.
_log() {
  local level=$1
  local message=$2
  local colors=( '\033[0;37m' '\033[0;35m' '\033[0;34m' '\033[0;33m' '\033[0;31m' )
  if [ "${level}" -ge "${__sos_verbosity}" ]; then
    echo -e "${colors[level]}${message}\033[0m" >&2
  fi
}

# Fails the script with the provided error message.
#
# $1 - the message to log
#
# Exits the scripts with code 1.
_fail() {
  local message=$1
  _log 4 "${message}"
  exit 1
}

# Get the current date in the provided format.
#
# $1 - the format to use for the date output
# $2 - the delay for the date, e.g. '-1d'
#
# Returns the date in the format.
_get_date() {
  local format=$1
  local delay=$2
  _log 0 "Retrieving date with format '${format}' for '${delay}'"
  if date --version >/dev/null 2>&1 ; then
    # Using GNU date
    echo $(date -d "${delay} day" +"${format}")
  else
    # Using BSD date
    echo $(date -v "${delay}d" +"${format}")
  fi
}

# Calculates an average with a precision of 2.
# The returned value is x100 as bash does not support float values natively.
#
# $1 - the sum of all data points
# $2 - the number of data points
#
# The average value (x100 for the precision).
_avg() {
  local sum=$1
  local num=$2
  _log 0 "Calculating average of '${sum}/${num}'"
  echo $(( 100 * sum / num ))
}

# Formats a float value based on precision of 2.
# Expects a value x100 as bash does not support float values natively.
#
# $1 - the number to format
#
# The formatted value with a dot as decimal separator.
_format_float() {
  local num=$1
  local res=$(echo "${num}" | sed -e 's/..$/.&/;t' -e 's/.$/.0&/')
  local prefix=""
  if [ "${num}" -lt 10 ] && [ "${num}" -ge 0 ]; then
    prefix="0"
  fi
  echo "${prefix}${res}"
}

# Formats a variation, by adding the sign and the '%'.
# Expects a value x100 as bash does not support float values natively.
#
# $1 - the number to format
#
# The formatted value with a dot as decimal separator.
_format_variation() {
  local num=$1
  local sign=""
  if [ "${num}" -ge "0" ]; then
    sign="+"
  fi
  echo "${sign}$(_format_float ${num})%"
}

############################################################################
# Configurations management methods
############################################################################

# Reads a configuration value from command line arguments.
#
# $1 - the configuration property to read
#
# Returns the configuration value, or '__UNDEFINED__' if not found.
_get_config_from_args() {
  local property=$1
  local value="__UNDEFINED__"
  for i in "${!__sos_cli_args[@]}"; do
    if [[ ${__sos_cli_args[i]} = "--${property}="* ]]; then
      local j=${__sos_cli_args[i]}
      value="${j#*=}"
      break
    fi
  done
  echo "${value}"
}

# Loads the configuration file (from command line, or 'default.cfg').
#
# The absolute path to the found configuration file. Empty of no file defined.
_load_config_file() {
  local config_file=""
  local config_file_name=$(_get_config_from_args "config_file")
  if [ "${config_file_name}" != "__UNDEFINED__" ]; then
    config_file="${__sos_current_dir}/${config_file_name}"
    if test -f "${config_file}"; then
      _log 2 "Using configuration file: '${config_file}'"
    else
      _fail "Configuration file '${config_file}' not found"
    fi
  else
    config_file="${__sos_current_dir}/default.cfg"
    if test -f "${config_file}"; then
      _log 2 "Using default configuration file: '${config_file}'"
    else
      config_file=""
      _log 2 "No configuration file defined, using defaults"
    fi
  fi
  echo "${config_file}"
}

# Reads a value from a configuration file.
#
# $1 - the file to parse
# $2 - the configuration property to read
#
# Returns the configuration value, or '__UNDEFINED__' if not found.
_get_config_from_file() {
  local file=$1
  local property=$2
  (grep -E "^${property}=" -m 1 "${file}" 2>/dev/null || echo "VAR=__UNDEFINED__") | head -n 1 | cut -d '=' -f 2-;
}

# Gets the value for the requested configuration property.
# Tries to get the value from:
#  - the command line arguments ('--*=')
#  - the configuration file defined by ${__sos_config_file}
#  - or the provided default value
#
# $1 - the property to get
# $2 - the default value if not found
#
# Returns the configuration value.
_get_config() {
  local property=$1
  local default_value=$2
  local value=$(_get_config_from_args "${property}")
  if [ "${value}" != "__UNDEFINED__" ]; then
    _log 0 "Found configuration value for property '${property}' in command line arguments"
    echo "${value}"
    return
  fi
  value="$(_get_config_from_file "${__sos_config_file}" "${property}")";
  if [ "${value}" != "__UNDEFINED__" ]; then
    _log 0 "Found configuration value for property '${property}' in config file"
    echo "${value}"
    return
  fi
  _log 0 "No configuration found for property '${property}', returning default value"
  echo "${default_value}";
}

############################################################################
# Disk usage management methods
############################################################################

_disk_usage() {
  local volume=$1
  local usage=$(df -h "${volume}" | grep -o -E '[0-9]+%' | head -1 | sed -r "s/%//g")
  echo "${usage}"
}

############################################################################
# Log files management methods
############################################################################

# Get all files in a folder for the provided pattern.
# Files will be listed in reverse alphabetical order.
# TODO: handle spaces in file names
#
# $1 - the pattern to search for
# $2 - the folder to lookup
# $3 - optional, the maximum number of files to return
# $4 - optional, the offset (the number of files to ignore)
#
# Returns the list of found files, empty string if no files found.
_get_files() {
  local pattern=$1
  local folder=$2
  local limit=9999
  if [ ! -z "$3" ]; then
    limit=$3
  fi
  local offset=0
  if [ ! -z "$4" ]; then
    offset=$4
  fi
  _log 0 "Retrieving files in '${folder}' for '${pattern}' (offset=${offset}, limit=${limit})"
  if test -n "$(find ${folder} -maxdepth 1 -name ${pattern} -print -quit)"; then
    local counter=0
    find ${folder} -name ${pattern} -print0 | sort -zr | while read -d $'\0' file
    do
      counter=$((counter+1))
      if [ $((counter)) -gt $((offset + limit)) ]; then
        _log 0 "Max reached (${counter}), ignoring other files"
        break
      fi
      if [ $((counter)) -ge $((offset)) ]; then
        echo "${file}"
      fi
    done
  else
    _log 0 "No files found in '${folder}' for '${pattern}'"
    echo ""
  fi
}

# Get the current log file.
# TODO: should handle '%i' in pattern and return a list of files
#
# $1 - the pattern to search for
# $2 - the folder to lookup
# $3 - the formatted log date that will be replaced in the pattern
#
# Returns the matched log file, or empty if no file found.
_get_log_file() {
  local pattern=$1
  local folder=$2
  local log_date=$3
  _log 0 "Retrieving pattern '${pattern}' from log file in '${folder}' for '${log_date}'"
  local search=$(echo "${pattern}" | sed -r "s/%date/${log_date}/g")
  echo $(_get_files "${search}" "${folder}")
}

# Get the history of log files to analyze.
# Current log file ${__sos_log_file} is filtered out.
# TODO: should handle '%i' in pattern and return a list of files
#
# $1 - the pattern to search for
# $2 - the folder to lookup
#
# Returns the list of matching files, or empty string if no file found.
_get_log_file_history() {
  local pattern=$1
  local folder=$2
  local limit=$3
  local offset=$4
  _log 0 "Retrieving pattern '${pattern}' from log files history in '${folder}'"
  local search=$(echo "${pattern}" | sed -r "s/%date/*/g")
  local files=( $(_get_files "${search}" "${folder}" "${limit}" "${offset}") )
  local filtered_files=()
  for file in ${files[*]}; do
    if [ "${file}" != "${__sos_log_file}" ]; then
      filtered_files+=( "${file}" )
    else
      _log 0 "Ignoring '${file}' for history"
    fi
  done
  echo "${filtered_files[*]}"
}

############################################################################
# Analytics methods
############################################################################

# Counts the occurrences of a pattern in file.
#
# $1 - the pattern to search for
# $2 - the file to lookup
#
# Returns the number of found occurrences.
_count_occurrences_in_file() {
  local pattern=$1
  local file=$2
  _log 0 "Counting occurrences of pattern '${pattern}' in '${file}'"
  local count=$(grep -c "${pattern}" "${file}")
  echo "${count}"
}

# Counts the number of lines in file.
#
# $1 - the file to lookup
#
# Returns the number of lines.
_count_lines_in_file() {
  local file=$1
  local count=$(grep -c ^ "${file}")
  echo "${count}"
}

# Analyzes the provided log file with a given pattern.
#
# $1 - the pattern to search for
# $2 - the file to lookup
#
# Returns an array with the number of occurrences for each log type entry in ${__sos_log_types}.
_analyze_file() {
  local pattern=$1
  local file=$2
  _log 0 "Analyzing pattern '${pattern}' within log file '${file}'"
  local counts=()
  for type in ${__sos_log_types[@]}; do
    local search=$(echo "${pattern}" | sed -r "s/%type/${type}/g")
    local e=$(_count_occurrences_in_file "${search}" "${file}")
    counts+=("$e")
  done
  echo "${counts[@]}"
}

# Analyzes the provided history log files.
#
# $1 - the pattern to search for
# $2 - the files to analyze
#
# Returns an array with the number of average occurrences for each log type entry in ${__sos_log_types}.
_analyze_history() {
  local args=( $@ )
  local pattern=$1
  local files=("${args[@]:1}")
  _log 0 "Analyzing pattern '${pattern}' within log file history of '${#files[@]}' files"

  # Initializing results array for history
  local history=()
  for type in ${__sos_log_types[@]}; do
    history+=(0)
  done

  # Iterating over files
  local num_files=0
  for file in ${files[*]}; do
    _log 0 "Analyzing '${file}' for history"
    num_files=$((${num_files} + 1))
    local result=( $(_analyze_file "${pattern}" "${file}") )
    for i in "${!result[@]}"; do
      history[i]=$(( ${history[i]} + ${result[i]} ))
    done
  done
  _log 0 "Analyzed '${num_files}' files for history"

  # Calculating averages
  _log 1 "Calculating averages on history:"
  average=()
  for i in "${!__sos_log_types[@]}"; do
    average[i]=$(_avg ${history[i]} ${num_files})
    _log 1 " - ${__sos_log_types[i]}: $(_format_float ${average[i]})"
  done

  echo "${average[@]}"
}

# Calculates the variations between a provided list of averages and the current results.
# Both lists must have the same size.
#
# $1 - the list of averages (x100 for precision)
# $2 - the list of current results
#
# Returns the list of variations compared to the average.
_calculate_variations() {
  local args=( $@ )
  local log_types_size=${#__sos_log_types[@]}
  local initial_values=("${args[@]:0:log_types_size}")
  local current_values=("${args[@]:log_types_size}")
  _log 0 "Calculating variations from initial values '${initial_values[*]}' to '${current_values[*]}'"
  local variations=()
  for i in "${!__sos_log_types[@]}"; do
    diff=$((100 * current_values[i] - initial_values[i]))
    if [ "${initial_values[i]}" -eq "0" ]; then
      if [ "${diff}" -gt "0" ]; then
        variations[i]=10000
      else
        variations[i]=0
      fi
    else
      variations[i]=$((10000 * diff / initial_values[i] ))
    fi
  done
  echo "${variations[@]}"
}

# Calculates the highest log level for which the threshold has been exceeded.
# This method takes into account the values defined in ${__sos_log_thresholds_max} and ${__sos_log_thresholds_var}.
#
# $1 - the list of results (occurrences for each log level)
# $2 - optional - the list of variations (for each log level)
#
# Returns the highest log level.
_calculate_exceeded_threshold() {
  local args=( $@ )
  local log_types_size=${#__sos_log_types[@]}
  local results=("${args[@]:0:log_types_size}")
  local variations=("${args[@]:log_types_size}")
  local exceeded_level=""
  _log 0 "Calculating exceeded threshold with results '${results[*]}' and variations '${variations[*]}'"
  for i in "${!__sos_log_types[@]}"; do
    # Checking max
    if [ "${results[i]}" -gt "${__sos_log_thresholds_max[i]}" ]; then
      exceeded_level=${__sos_log_types[i]}
      _log 1 "Threshold (max) for ${exceeded_level} reached (${results[i]}>${__sos_log_thresholds_max[i]})"
      break
    fi
    # Checking variation
    size=${#variations[@]}
    if [ "${size}" -gt 0 ]; then
      t_var=$((100 * __sos_log_thresholds_var[i]))
      if [ "${variations[i]}" -gt "${t_var}" ]; then
        exceeded_level=${__sos_log_types[i]}
        _log 1 "Threshold (var) for ${exceeded_level} reached ($(_format_float ${variations[i]})>$(_format_float ${t_var}))"
        break
      fi
    fi
  done
  echo "${exceeded_level}"
}

############################################################################
# Notification methods
############################################################################

# Checks if the notification level has been exceeded for the provided level.
#
# $1 - the log level to check
#
# Returns 1 if the level exceeds the notification level, 0 otherwise.
_notification_level_exceeded() {
  local level=$1
  local exceeded=0
  local alert_idx=-1
  local current_idx=9999
  for i in "${!__sos_log_types[@]}"; do
    if [ "${__sos_log_types[i]}" = "${__sos_log_notification_level}" ]; then
      alert_idx=$i
    fi
    if [ "${__sos_log_types[i]}" = "${level}" ]; then
      current_idx=$i
    fi
    if [ $((current_idx)) -le $((alert_idx)) ]; then
      exceeded=1
      _log 0 "Notification level exceeded (${exceeded_level}>${__sos_log_notification_level})"
      break
    fi
  done
  echo "${exceeded}"
}

# Sends an email notification through SMTP.
#
# $1 - the subject of the email
# $1 - the body
#
# Returns 0 if notification has been sent successfully, 1 otherwise
_send_notification() {
  local subject=$1
  local body=$2
  if [ -z "${__sos_mail_receiver}" ] || [ "${__sos_mail_pretend}" -eq "1" ]; then
    _log 1 "Pretending to send notification to '${__sos_mail_receiver}'"
    _log 2 "------------------------------------"
    _log 2 "${subject}"
    _log 2 "---"
    _log 2 "${body}"
    _log 2 "------------------------------------"
    echo 1
    return
  fi
  local response=$(curl -s -w "HTTPSTATUS:%{http_code}" \
      --url "${__sos_mail_endpoint}" \
      --mail-from "${__sos_mail_sender}" \
      --mail-rcpt "${__sos_mail_receiver}" \
      --user "${__sos_mail_username}:${__sos_mail_password}" \
      -T <(echo -e "From: <${__sos_mail_sender}>\r\nTo: <${__sos_mail_receiver}>\r\nSubject: ${subject}\r\nDate: $(date -R)\r\n\r\n${body}"))
  local response_body=$(echo "${response}" | sed -e 's/HTTPSTATUS\:.*//g')
  local response_code=$(echo "${response}" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  if [ "${response_code}" -ge "200" ] && [ "${response_code}" -lt "300" ]; then
    _log 1 "Notification sent successfully: status='${response_code}'"
    echo 1
  else
    _log 4 "Error while sending notification: status='${response_code}', response='${response_body}'"
    echo 0
  fi
}

############################################################################
# Main execution
############################################################################

# Displays the help message.
#
# Exits the program with code 0.
usage() {
  echo "Usage: $(basename "$0") [command] [args|--options]" >&2
  echo "" >&2
  echo "where [command]:" >&2
  echo "   help                displays this help message" >&2
  echo "   version             displays the version number of the script" >&2
  #echo "   update              updates the script to the latest version" >&2
  #echo "   status              checks if the script is registered as a cron job" >&2
  #echo "   schedule [cron]     schedules the script as a cron job, with the provided [cron] expression" >&2
  echo "   check [--options]   default - runs the entire system observability check, with following [--options]:" >&2
  echo "     --verbosity=*                the verbosity for logs (0=TRACE, 1=DEBUG, 2=INFO, 3=WARNING, 4=ERROR) - default: '2'" >&2
  echo "     --environment=*              the environment identifier - default: 'default'" >&2
  echo "     --config_file=*              uses the specified configuration file - default: 'default.cfg'" >&2
  echo "     --log_folder=*               the folder in which all log files are located, either absolute or relative to the calling script" >&2
  echo "     --log_file=*                 the log file to analyze, relative to the log folder" >&2
  echo "     --log_types=*                the list of log types to search for (ordered by decreasing importance) - default: 'ERROR WARNING INFO DEBUG'" >&2
  echo "     --log_type_pattern=*         the pattern to retrieve the log type from the logs" >&2
  echo "     --log_thresholds_max=*       the accepted number of occurrences before considering for notification - default: '1 5 -1 -1'"  >&2
  echo "     --log_thresholds_var=*       the accepted variation to average (in %) before considering for notification - default: '5 10 -1 -1'" >&2
  echo "     --log_notification_level=*   the min level for which a notification will be sent if threshold is reached - default: 'WARNING'" >&2
  echo "     --log_file_pattern=*         the pattern of the log files (can contain placeholders)" >&2
  echo "     --log_file_date_format=*     the date format of the log files names (required if log_file is empty) - default: '%Y-%m-%d'" >&2
  echo "     --log_file_date_delay=*      delay for the current log file date (required if log_file is empty) - default: '-1'" >&2
  echo "     --log_file_history_limit=*   the maximum number of files to take into account for history - default: '10'" >&2
  echo "     --log_file_history_offset=*  the number of files to ignore for history (files are in reverse order) - default: '0'" >&2
  echo "     --mail_endpoint=*            the endpoint to use for sending the email (should include protocol, host and port)" >&2
  echo "     --mail_username=*            the username of the email account" >&2
  echo "     --mail_password=*            the password of the email account" >&2
  echo "     --mail_sender=*              the email address from which the notification email will be sent" >&2
  echo "     --mail_receiver=*            the email address to which the notification email will be sent" >&2
  echo "     --mail_subject=*             the subject of the notification email (can contain placeholders) - default: '[%environment] SysObsScript | %level'" >&2
  echo "" >&2
  exit 0
}

# Displays the current version of the script.
#
# Exits the program with code 0.
version() {
  echo "${__sos_script_version}" >&2
  exit 0
}

# Runs the entire SOS check.
#
# Exits the program with code 0 if successful.
check() {
  echo "========================================================================="
  echo "  ___                ___    _           ___              _          _    "
  echo " / __|  _  _   ___  / _ \  | |__   ___ / __|  __   _ _  (_)  _ __  | |_  "
  echo " \__ \ | || | (_-< | (_) | | '_ \ (_-< \__ \ / _| | '_| | | | '_ \ |  _| "
  echo " |___/  \_, | /__/  \___/  |_.__/ /__/ |___/ \__| |_|   |_| | .__/  \__| "
  echo "        |__/                                                |_|          "
  echo " Script version: ${__sos_script_version}                                 "
  echo "========================================================================="
  # Saving command line arguments
  __sos_cli_args=("$@")
  # Loading global configurations
  __sos_config_file=$(_load_config_file)
  __sos_verbosity=$(_get_config "verbosity" "2") # TODO: should be overridden by CLI args with (-v, -vv, -vvv, -vvvv)
  _log 0 "Loading global configurations from command line arguments and from file '${__sos_config_file}'"
  # > Global configurations for logs
  __sos_log_file=$(_get_config "log_file" "")
  __sos_log_types=($(_get_config "log_types" "ERROR WARNING INFO DEBUG"))
  __sos_log_thresholds_max=($(_get_config "log_thresholds_max" "1 5 -1 -1"))
  __sos_log_thresholds_var=($(_get_config "log_thresholds_var" "5 10 -1 -1"))
  __sos_log_notification_level=$(_get_config "log_notification_level" "WARNING")
  # > Global configuration for mail
  __sos_mail_endpoint=$(_get_config "mail_endpoint" "")
  __sos_mail_username=$(_get_config "mail_username" "")
  __sos_mail_password=$(_get_config "mail_password" "")
  __sos_mail_sender=$(_get_config "mail_sender" "")
  __sos_mail_receiver=$(_get_config "mail_receiver" "")
  __sos_mail_pretend=$(_get_config "mail_pretend" "0")

  _log 0 "Loading check options from command line arguments and from file '${__sos_config_file}'"
  # > Configurations for logs
  local environment=$(_get_config "environment" "default")
  local log_folder=$(_get_config "log_folder" "${__sos_current_dir}")
  if [[ $log_folder != /* ]]; then
    # Not an absolute path, appending current dir
    log_folder="${__sos_current_dir}/${log_folder}"
  fi
  local log_file_pattern=$(_get_config "log_file_pattern" "")
  local log_file_date_format=$(_get_config "log_file_date_format" "%Y-%m-%d")
  local log_file_date_delay=$(_get_config "log_file_date_delay" "-1")
  local log_file_history_limit=$(_get_config "log_file_history_limit" "10")
  local log_file_history_offset=$(_get_config "log_file_history_offset" "0")
  local log_type_pattern=$(_get_config "log_type_pattern" "%type")
  # > Configuration for mail
  local mail_subject=$(_get_config "mail_subject" "[%environment] SysObsScript | %level")
  # > Configuration for disk usage
  local disk_volume=$(_get_config "disk_volume" "/")

  # Logging current configuration
  _log 0 "Checking system with:"
  _log 0 "   environment = '${environment}'"
  _log 0 "   verbosity = '${__sos_verbosity}'"
  _log 0 "   log_folder = '${log_folder}'"
  _log 0 "   log_file_pattern = '${log_file_pattern}'"
  _log 0 "   log_file_date_format = '${log_file_date_format}'"
  _log 0 "   log_file_date_delay = '${log_file_date_delay}'"
  _log 0 "   log_file_history_limit = '${log_file_history_limit}'"
  _log 0 "   log_file_history_offset = '${log_file_history_offset}'"
  _log 0 "   log_type_pattern = '${log_type_pattern}'"
  _log 0 "   log_types = '${__sos_log_types[*]}'"
  _log 0 "   log_notification_level = '${__sos_log_notification_level}'"
  _log 0 "   mail_endpoint = '${__sos_mail_endpoint}'"
  _log 0 "   mail_username = '${__sos_mail_username}'"
  _log 0 "   mail_sender = '${__sos_mail_sender}'"
  _log 0 "   mail_receiver = '${__sos_mail_receiver}'"
  _log 0 "   mail_pretend = '${__sos_mail_pretend}'"
  _log 0 "   mail_subject = '${mail_subject}'"
  _log 0 "   disk_volume = '${disk_volume}'"

  # Defining pattern to retrieve log type
  local log_pattern=$(echo "${log_type_pattern}" | sed -r "s/%environment/${environment}/g")

  # Analyzing current log file
  if [ -z "${__sos_log_file}" ]; then
    # No log file provided: retrieving current with date and pattern
    local log_date=$(_get_date "${log_file_date_format}" "${log_file_date_delay}")
    _log 1 "No log file defined, retrieving logs for date '${log_date}'"

    __sos_log_file=$(_get_log_file "${log_file_pattern}" "${log_folder}" "${log_date}")
    if [ -z "${__sos_log_file}" ]; then
      _fail "No log file found for date '${log_date}'"
    fi
  else
    # Log file provided, appending log folder
    __sos_log_file="${log_folder}/${__sos_log_file}"
  fi
  _log 1 "Analyzing log file: ${__sos_log_file}"
  local results=( $(_analyze_file "${log_pattern}" "${__sos_log_file}") )

  # Analyzing log history
  local log_file_history=( $(_get_log_file_history "${log_file_pattern}" "${log_folder}" "${log_file_history_limit}" "${log_file_history_offset}") )
  local log_file_history_size=${#log_file_history[@]}
  local previous=()
  local averages=()
  if [ "${log_file_history_size}" -lt 1 ]; then
    _log 2 "No log history found to analyze"
  else
    _log 1 "Analyzing previous log file: ${log_file_history[0]} "
    previous=( $(_analyze_file "${log_pattern}" "${log_file_history[0]}") )

    _log 1 "Analyzing log file history: ${log_file_history[*]} "
    averages=( $(_analyze_history "${log_pattern}" "${log_file_history[*]}") )
  fi

  # Calculating variations
  local variations=()
  local variations_avg=()
  if [ "${log_file_history_size}" -lt 1 ]; then
    _log 1 "No variations to calculate without history"
  else
    local previous_avg=()
    for i in "${previous[@]}"; do
      previous_avg+=( $((100 * i)) )
    done
    variations=( $(_calculate_variations "${previous_avg[*]}" "${results[*]}") )
    variations_avg=( $(_calculate_variations "${averages[*]}" "${results[*]}") )
  fi

  # Counting line numbers
  local num_lines=$(_count_lines_in_file "${__sos_log_file}")
  _log 1 "Log file contains ${num_lines} number of lines"

  # Checking disk usage
  local disk_usage=$(_disk_usage "${disk_volume}")
  _log 1 "Disk usage: ${disk_usage}"

  # Analyzing thresholds: calculating exceeded threshold
  # TODO: also add thresholds for ${variations} (to previous, not only avg)
  _log 1 "Checking for exceeded thresholds"
  local exceeded_level=$(_calculate_exceeded_threshold "${results[*]}" "${variations_avg[*]}")
  if [ -z "${exceeded_level}" ]; then
    _log 1 "No threshold exceeded"
  else
    _log 1 "Threshold exceeded: ${exceeded_level}"
  fi

  # Checking if alert should be sent
  local send_alert=$(_notification_level_exceeded "${exceeded_level}")
  if [ "${send_alert}" -ne "1" ]; then
    _log 1 "Notification ignored"
  else
    _log 1 "Triggering notification"
    # Building subject
    local subject=$(echo "${mail_subject}" | sed -r "s/%environment/${environment}/g")
    subject=$(echo "${subject}" | sed -r "s/%level/${exceeded_level}/g")
    # Building body
    local body="Log file analysis results for '${__sos_log_file}':\n"
    for i in "${!__sos_log_types[@]}"; do
      local var=""
      if [ "${log_file_history_size}" -gt 0 ]; then
        # Adding variations to history
        var+=" | previous=$(_format_variation ${variations[i]})"
        var+=" | average=$(_format_variation ${variations_avg[i]})"
      fi
      body+=" - ${__sos_log_types[i]}: ${results[i]}${var}\n"
    done
    body+="Total number of lines: ${num_lines}\n"
    body+="\n"
    body+="Disk usage: $(_format_float "$((100 * disk_usage))")%\n"
    body+="\n"
    body+="Sent from: $(hostname)"
    local notification_sent=$(_send_notification "${subject}" "${body}")
    if [ "${notification_sent}" -ne "1" ]; then
      _fail "Notification failed"
    else
      _log 2 "Notification sent successfully"
    fi
  fi

  exit 0
}

############################################################################
# Entrypoint
############################################################################

# Check if script is being called or sourced
if [ "$0" = "$BASH_SOURCE" ]; then
  # Switching over command
  case "$1" in
    help|-h|--help) usage;;
    version|-v|--version) version;;
    #update) update;;
    #status) status;;
    #schedule) schedule;;
    check) check "$@";;
    *) check "$@";;
  esac
fi
