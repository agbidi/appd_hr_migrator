#!/usr/bin/env bash

# filename          : hrmigrator.sh
# description       : Migrate AppDynamics Health Rules
# author            : Alexander Agbidinoukoun
# email             : aagbidin@cisco.com
# date              : 20220414
# version           : 0.2
# usage             : ./hrmigrator.sh -c config.cfg -m export|import
# notes             : 0.1: first release
#                   : 0.2: handle space in application names

#==============================================================================


set -Euo pipefail
trap cleanup SIGINT SIGTERM EXIT

PREV_IFS=$IFS

# check for jq
if ! command -v jq >/dev/null; then
  echo "Please install jq to use this tool (sudo yum install -y jq)"
  exit 1
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
log_file=$(echo ${BASH_SOURCE[0]} | sed 's/sh$/log/')

usage() {
  cat << EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] -m export|import -c config_file

Migrate AppDynamics Health Rules

Available options:

-h, --help        Print this help and exit
-v, --verbose     Print script debug info
-m, --mode        Export or Import
-c, --config      Path to config file

EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM EXIT
  # script cleanup here
  if [ "$daemon" -eq 1 ]; then
      exit 255
  fi
}

setup_colors() {
  if [ -t 2 ] && [ -z "${NO_COLOR-}" ] && [ "${TERM-}" != "dumb" ]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[0;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

log() {
  echo >&2 -e "${1-}" >> ${log_file}
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  local date=`date '+%Y-%m-%d %H:%M:%S'`
  msg "${date}: ${RED}ERR:${NOFORMAT} $msg"
  log "${date}: ERR: $msg"
  exit $code
}

warn() {
  local msg=$1
  local date=`date '+%Y-%m-%d %H:%M:%S'`
  msg "${date}: ${YELLOW}WARN:${NOFORMAT} $msg"
  log "${date}: WARN: $msg"
}

info() {
  local msg=$1
  local date=`date '+%Y-%m-%d %H:%M:%S'`
  msg "${date}: ${GREEN}INFO:${NOFORMAT} $msg"
  log "${date}: INFO: $msg"
}

parse_params() {
  # default values of variables set from params
  daemon=0
  frequency=3600

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -c | --config)
      config="${2-}"
      shift
      ;;
    -m | --mode)
      mode="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [ -z "${config-}" ] &&  warn "Missing required parameter: config" && usage
  [ -z "${mode-}" ] && warn "Missing required parameter: mode" && usage

  #[ ${#args[@]} -eq 0 ] && die "Missing script arguments"

  return 0
}

setup_colors
parse_params "$@"

# script logic here

# msg "${RED}Read parameters:${NOFORMAT}"
# msg "- flag: ${flag}"
# msg "- param: ${param}"
# msg "- arguments: ${args[*]-}"

warn_on_error() {
  file=$1
  PREV_IFS=$IFS
  IFS=$'\n'
  for e in `cat $file | grep '<error>' | sed -r 's#^.*<error>(.*)</error>#\1#'`; do
    warn $e
  done
  IFS=$PREV_IFS
}


get_appd_oauth_token() {

  # curl request

  response=`my_curl -s -X POST -H "Content-Type: application/vnd.appd.cntrl+protobuf;v=1" \
  -d "grant_type=client_credentials&client_id=${appd_api_user}@${appd_account}&client_secret=${appd_api_secret}" \
  ${appd_url}/controller/api/oauth/access_token`

  # validate response
  [ -z "`echo $response | grep access_token`" ] && die "Could not retrieve oauth token: $response"

  # extract token from response
  echo -n $response | sed 's/[[:blank:]]//g' | sed -E 's/^.*"access_token":"([^"]*)".*$/\1/'
}

my_curl() {
  IFS=$PREV_IFS #reset IFS to original value in import/export loops

  if [ ! -z "${appd_oauth_token}" ]; then
    curl -s -H "Authorization:Bearer ${appd_oauth_token}" ${appd_proxy} "$@"
  else
    curl -s -u "${appd_api_user}@${appd_account}:${appd_api_password}" ${appd_proxy} "$@"
  fi
}

get_applications_info() {
  regex=$1
  response=`my_curl -H "Content-Type: application/json" -X GET \
      "${appd_url}/controller/rest/applications?output=json"`
  infos=`jq -r ".[] | select(.name | test(\"$regex\")) | .name,.id" <<<$response`

  app_infos=""
  last_info='id'

  for info in ${infos}; do
    if [ `echo ${info} | grep -E '^[0-9]+$'` ] ; then  # app id
      app_infos+="=${info},"
      last_info='id'
    else
      if [ $last_info == 'id' ]; then # app name
        app_infos+="${info}"
      else # app name with space
        app_infos+=" ${info}"
      fi
      last_info='name'
    fi
  done

  echo -n ${app_infos}
}

export_hr() {
  name=$1
  id=$2

  #warn if file already exists
  [ -e ${output_dir}/${name}.xml ] && warn "File ${name}.xml already exists and will be overwritten"
  
  my_curl -X GET -o ${output_dir}/${name}.xml "${appd_url}/controller/healthrules/$id"
  [ $? -ne 0 ] && warn "There was an issue exporting health rules for application $name ($id)" && return 1
  
  # warn if file contains errors
  warn_on_error ${output_dir}/${name}.xml

  return 0
}

export_hrs() {
    # source config file
    [ ! -r $config ] && die "$config is not readable"
    . $config

    # check required config entries
    [ -z "${appd_src_url-}" ] && die "Missing required config entry: appd_src_url"
    [ -z "${appd_src_account-}" ] && die "Missing required config entry: appd_src_account"
    [ -z "${appd_src_api_user-}" ] && die "Missing required config entry: appd_api_user"
    [ -z "${appd_src_api_password-}" ] && [ -z "${appd_src_api_secret-}" ] && die "Missing required config entry: appd_src_api_password or appd_src_api_secret"
    [ -z "${appd_application_names-}" ] && die "Missing required config entry: appd_application_names"
    [ -z "${output_dir-}" ] && die "Missing required config entry: output_dir"
   
    appd_url=${appd_src_url}
    appd_account=${appd_src_account}
    appd_api_user=${appd_src_api_user}
    appd_api_password=${appd_src_api_password}
    appd_api_secret=${appd_src_api_secret}

    # proxy
    appd_proxy=""
    [ ! -z "${appd_src_proxy-}" ] && appd_proxy="--proxy ${appd_src_proxy}"

    # display key config
    info "Using AppDynamics Source URL: ${appd_src_url-}"
    info "Using output directory: ${output_dir}"
    info "Using application name regex: ${appd_application_names}"

    # retrieve appd token
    appd_oauth_token=''
    if [ "${appd_api_secret}" != "" ]; then
      info "Retrieving AppDynamics oauth token at ${appd_url}"
      appd_oauth_token=`get_appd_oauth_token`; [ $? -ne 0 ]
    fi

    info "Retrieving AppDynamics application ids"
    applications_info=`get_applications_info ${appd_application_names}`; [ $? -ne 0 ]
    info "Matched applications: $applications_info"

    # create output dir if it does not exist
    if [ ! -d ${output_dir} ]; then 
      mkdir ${output_dir}
      [ $? -ne 0 ] && die "Could not create output directory: ${output_dir}"
    fi

    all=0
    ok=0
    # loop over all applications
    PREV_IFS=$IFS
    IFS=','
    for info in ${applications_info}; do
      # get alerting action id
      name=`echo ${info} | cut -d '=' -f 1`
      id=`echo ${info} | cut -d '=' -f 2`
      info "Exporting health rules for application $name ($id)"
      export_hr $name $id
      [ $? -eq 0 ] && ok=$(( $ok + 1 ))
      all=$(( $all + 1 )) 
    done
    IFS=$PREV_IFS
    info "$ok/$all applications health rules exported"
}

input_to_regex() {  
  input_apps=`ls ${output_dir} | grep -E "${appd_application_names}" | sed 's/\.xml//'`
  [ -z "$input_apps" ] && die "Health rules directory is empty: ${output_dir}"

  regex=''
  for a in $input_apps; do
    regex="$a|$regex"
  done
  regex=`echo $regex | sed 's/.$//'`
  echo -n $regex
}


import_hr() {
  name=$1
  id=$2

  my_curl -X POST -F file=@${output_dir}/${name}.xml "${appd_url}/controller/healthrules/$id?overwrite=${overwrite}"
  [ $? -ne 0 ] && warn "There was an issue importing health rules for application $name ($id)" && return 1
  return 0
}

import_hrs() {
    # source config file
    [ ! -r $config ] && die "$config is not readable"
    . $config

    # check required config entries
    [ -z "${appd_dst_url-}" ] && die "Missing required config entry: appd_dst_url"
    [ -z "${appd_dst_account-}" ] && die "Missing required config entry: appd_dst_account"
    [ -z "${appd_dst_api_user-}" ] && die "Missing required config entry: appd_api_user"
    [ -z "${appd_dst_api_password-}" ] && [ -z "${appd_dst_api_secret-}" ] && die "Missing required config entry: appd_dst_api_password or appd_dst_api_secret"
    [ -z "${appd_application_names-}" ] && die "Missing required config entry: appd_application_names"
    [ -z "${output_dir-}" ] && die "Missing required config entry: output_dir"
    [ -z "${overwrite-}" ] && die "Missing required config entry: overwrite"
   
    appd_url=${appd_dst_url}
    appd_account=${appd_dst_account}
    appd_api_user=${appd_dst_api_user}
    appd_api_password=${appd_dst_api_password}
    appd_api_secret=${appd_dst_api_secret}

    # proxy
    appd_proxy=""
    [ ! -z "${appd_dst_proxy-}" ] && appd_proxy="--proxy ${appd_dst_proxy}"

    # display key config
    info "Using AppDynamics destination URL: ${appd_dst_url-}"
    info "Using input directory: ${output_dir}"
    info "Using application name regex: ${appd_application_names}"

    #build app names regex from input directory
    appd_application_names_orig=${appd_application_names}
    appd_application_names=`input_to_regex`

    # retrieve appd token
    appd_oauth_token=''
    if [ "${appd_api_secret}" != "" ]; then
      info "Retrieving AppDynamics oauth token at ${appd_url}"
      appd_oauth_token=`get_appd_oauth_token`; [ $? -ne 0 ]
    fi

    info "Retrieving AppDynamics application ids"
    applications_info=`get_applications_info $appd_application_names`; [ $? -ne 0 ]
    info "Matched applications: $applications_info"

    # check if input directory exists
    [ ! -d ${output_dir} ] && die "Wrong input directory: ${output_dir}"

    all=$(( `ls ${output_dir} | grep -E "${appd_application_names_orig}" | wc -l` ))
    ok=0

    # loop over all applications
    PREV_IFS=$IFS
    IFS=','
    for info in ${applications_info}; do
      # get alerting action id
      name=`echo ${info} | cut -d '=' -f 1`
      id=`echo ${info} | cut -d '=' -f 2`
      info "Importing health rules for application $name ($id)"
      import_hr $name $id
      [ $? -eq 0 ] && ok=$(( $ok + 1 ))
    done
    IFS=$PREV_IFS

    if [ $ok == $all ]; then
      info "$ok/$all applications health rules imported"
    else
      warn "$ok/$all applications health rules imported. Some input files could not be matched with an application on the destination"
    fi
}

if [ $mode == "export" ]; then
    info "Export Health Rules: Start"
    export_hrs
    [ $? -eq 0 ] && info "Export Health Rules: Completed"
elif [ $mode == "import" ]; then
    info "Import Health Rules: Start"
    import_hrs
    [ $? -eq 0 ] && info "Import Health Rules: Completed"
else
  die "Unknown mode: $mode"
fi