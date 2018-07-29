#!/bin/bash
## Print build information for project under Git
##
## By Evgueni Souleimanov
##

set -u
set -e
PROGNAME="$( basename "$0" )"

## Caller wants usage (-h)
OPT_WANT_USAGE=""

## Get information for directory (-d)
OPT_DIRECTORY="."

## Write output to file (-f)
OPT_OUT_FILE=""

## Project name specified by caller
OPT_PROJECT_NAME=""

## Item
OPT_ITEM=""

## List of possible items
LIST_ITEMS="
c-header
c-header-u-boot-1-2-timestamp
commit-id
commit-id-abbrev
date-epoch
date-safe-str
date-str
print-all
repo-url
"

LIST_ITEMS="$( echo ${LIST_ITEMS} )"

unset BID_COMMIT_ID_FULL BID_COMMIT_ID_ABBREV
unset BID_DATE_EPOCH
unset BID_DATE_SAFE_STR BID_DATE_STR BID_DATE_C_DATE_STR BID_DATE_C_TIME_STR
unset BID_REPO_URL

unset ITEM_HANDLER_FUNC

unset TOP_LEVEL_DIR

exit_handler()
{
	local rv="${1:-120}"
	set +x
	set +e
	if ! [ "${rv}" = 0 ] ; then
		if [ -n "${OPT_OUT_FILE}" ] ; then
			rm -f "${OPT_OUT_FILE}"
		fi
	fi
	return "${rv}"
}

trap 'exit_handler "$?" "$0"' EXIT

show_usage()
{
	set +x
	local arg1="${1:-}"

	cat <<__EOF__ >&2
Usage: ${PROGNAME} [options] ITEM
Print build information for project under Git

Options:

    -d DIRECTORY        Get information for DIRECTORY
    -f FILE             Write information to FILE
    -n PROJECTNAME      Specify project name

Possible items:

__EOF__
	echo "${LIST_ITEMS}" | tr ' ' '\012' | LC_COLLATE=C sort | sed -e 's/^/    /'    >&2

	if [ "${arg1}" != 0 ] ; then
		exit "${arg1}"
	fi

	return 0
}

show_debug()
{
	echo "DEBUG: ${PROGNAME}:" "$@"    >&2
}

show_error()
{
	echo "ERROR: ${PROGNAME}:" "$@"    >&2
}

##
## returns OK if $1 contains $2
##

strstr()
{
	if [ "${1#*$2*}" = "$1" ] ; then
		# $1 does not contain $2
		# return false
		return 1
	fi

	# return true
	return 0
}

##
## Parse command line options with getopts
##

parse_options()
{
	local ret_val
	local OPTION

	if [ $# -lt 1 ] ; then
		OPT_WANT_USAGE=y
		return 0
	fi

	ret_val=0
	while getopts "d:f:hn:" OPTION ; do
		case "${OPTION}" in
		d)
			if [ -n "${OPTARG}" ] && [ -d "${OPTARG}" ] ; then
				OPT_DIRECTORY="${OPTARG}"
			else
				show_error "Invalid directory name"
				ret_val=71
			fi
			;;
		f)
			if [ -n "${OPTARG}" ] ; then
				OPT_OUT_FILE="${OPTARG}"
			else
				show_error "Invalid output file name"
				ret_val=72
			fi
			;;
		n)
			if [ -n "${OPTARG}" ] ; then
				OPT_PROJECT_NAME="${OPTARG}"
			else
				show_error "Invalid project name"
				ret_val=72
			fi
			;;
		h)
			OPT_WANT_USAGE=y
			;;
		'?')
			ret_val=79
			;;
		esac
	done

	return ${ret_val}
}

##
## Parse item to print
##

parse_item_to_print()
{
	OPT_ITEM="${1:-}"

	if [ -z "${OPT_ITEM}" ] ; then
		show_error "Please specify item to print"
		return 81
	fi

	if ! strstr "${LIST_ITEMS}" "${OPT_ITEM}" ; then
		show_error "Unrecognized item \"${OPT_ITEM}\" [1]"
		return 82
	fi

	ITEM_HANDLER_FUNC="handler_$( echo -n "${OPT_ITEM}" | tr '-' '_' )"

	if ! [ "$( type -t "${ITEM_HANDLER_FUNC}" )" = function ] ; then
		show_error "Unrecognized item \"${OPT_ITEM}\" [2]"
		return 83
	fi

	return 0
}

##
## Locate top level Git directory
##

locate_top_level_dir()
{
	local top_dir

	if [ "$( cd "${OPT_DIRECTORY}" && git rev-parse --is-inside-work-tree 2>/dev/null )" = "true" ] ; then
		top_dir="$( cd "${OPT_DIRECTORY}" && git rev-parse --show-toplevel 2>/dev/null )"
	else
		show_error "Could not locate top level Git directory (not inside work tree)"
		return 1
	fi

	top_dir="$( cd "${top_dir}" && pwd )"

	if [ -z "${top_dir}" ] ; then
		show_error "Could not locate top level Git directory (cannot chdir)"
		return 1
	fi

	TOP_LEVEL_DIR="${top_dir}"
	if [ -z "${OPT_PROJECT_NAME}" ] ; then
		OPT_PROJECT_NAME="$( basename "${top_dir}" )"
	fi

	return 0
}

##
## Run git log command to get commit ID and committer date
##

run_git_log_101()
{
	local log_str
	local commit_id_full
	local commit_id_abbrev
	local date_epoch

	if [ "${DONE_RUN_GIT_LOG_101:-}" ] ; then
		return 0
	fi

	log_str="$( cd "${TOP_LEVEL_DIR}" && TZ=UTC git log -1 --format='tformat:%H|%ct' HEAD )"
	if [ -z "${log_str}" ] ; then
		show_error "Could not run git log command"
		return 1
	fi

	commit_id_full="$( echo "${log_str}" | cut -d '|' -f 1 )"
	date_epoch="$( echo "${log_str}" | cut -d '|' -f 2 )"

	if [ -z "${commit_id_full}" ] || [ -z "${date_epoch}" ] ; then
		show_error "Could not parse output of git log command"
		return 1
	fi

	if [ -n "${SOURCE_DATE_EPOCH:-}" ] ; then
		set +e
		date_epoch="$( TZ=UTC LANG=C LC_ALL=C date -u -d "@${SOURCE_DATE_EPOCH}" '+%s' )"
		set -e
		if [ -z "${date_epoch}" ] ; then
			show_error "Invalid SOURCE_DATE_EPOCH value"
			return 1
		fi
	fi

	if [ -n "${SOURCE_X_GIT_COMMIT_ID:-}" ] ; then
		set +e
		commit_id_full="$( echo "${SOURCE_X_GIT_COMMIT_ID}" | grep -E -o '^[0-9a-fA-F]{40}$' )"
		set -e
		if [ -z "${commit_id_full}" ] ; then
			show_error "Invalid SOURCE_X_GIT_COMMIT_ID value"
			return 1
		fi
	fi

	commit_id_abbrev="$( echo "${commit_id_full}" | grep -E -o '^[0-9a-fA-F]{12}'  )"
	if [ -z "${commit_id_abbrev}" ] ; then
		show_error "Could not parse abbreviated commit ID"
		return 1
	fi

	BID_COMMIT_ID_FULL="${commit_id_full}"
	BID_COMMIT_ID_ABBREV="${commit_id_abbrev}"
	BID_DATE_EPOCH="${date_epoch}"
	DONE_RUN_GIT_LOG_101=y
	return 0
}

##
## Format committer date in all formats
##

run_date_format()
{
	local date_str
	local date_safe_str
	local date_c_date_str
	local date_c_time_str

	if [ "${DONE_RUN_DATE_FORMAT:-}" ] ; then
		return 0
	fi

	if [ -z "${BID_DATE_EPOCH}" ] ; then
		show_error "Could not format date - no date to format"
		return 1
	fi

	date_str="$( TZ=UTC LANG=C LC_ALL=C date -u -d "@${BID_DATE_EPOCH}" '+%Y-%m-%d %H:%M:%S %z' )"
	if [ -z "${date_str}" ] ; then
		return 1
	fi

	date_safe_str="$( TZ=UTC LANG=C LC_ALL=C date -u -d "@${BID_DATE_EPOCH}" '+%Y%m%d-%H%M%S' )"
	if [ -z "${date_safe_str}" ] ; then
		return 1
	fi

	date_c_date_str="$( TZ=UTC LANG=C LC_ALL=C date -u -d "@${BID_DATE_EPOCH}" '+%b %d %Y' )"
	if [ -z "${date_c_date_str}" ] ; then
		return 1
	fi

	date_c_time_str="$( TZ=UTC LANG=C LC_ALL=C date -u -d "@${BID_DATE_EPOCH}" '+%H:%M:%S' )"
	if [ -z "${date_c_time_str}" ] ; then
		return 1
	fi

	BID_DATE_STR="${date_str}"
	BID_DATE_SAFE_STR="${date_safe_str}"
	BID_DATE_C_DATE_STR="${date_c_date_str}"
	BID_DATE_C_TIME_STR="${date_c_time_str}"
	DONE_RUN_DATE_FORMAT=y
	return 0
}

##
## Run git commands to get repository URL
##

run_git_remote_repo_url()
{
	local first_repo_name
	local repo_url

	if [ "${DONE_RUN_GIT_REMOTE_REPO_URL:-}" ] ; then
		return 0
	fi

	## Get the first remote.FOO.url entry in .git/config
	## it is the one where the repository was likely cloned
	## It is usually "origin", but not always

	first_repo_name="$( cd "${TOP_LEVEL_DIR}" && \
			git config --get-regexp 'remote[\.][^\.]+[\.]url' \
			| head -n 1 | awk '{ print $1 }' \
			| cut -d '.' -f2 \
			| grep -E -o '[A-Za-z0-9_-]+' )"

	if [ -z "${first_repo_name}" ] ; then
		show_error "Could not determine remote name for origin repository"
		return 1
	fi

	repo_url="$( cd "${TOP_LEVEL_DIR}" && git remote get-url "${first_repo_name}" )"
	if [ -z "${repo_url}" ] ; then
		show_error "Could not determine URL for remote ${first_repo_name}"
		return 1
	fi

	BID_REPO_URL="${repo_url}"
	DONE_RUN_GIT_REMOTE_REPO_URL=y
	return 0
}

##
## Handlers
##

handler_c_header()
{
	if ! run_git_log_101 ; then
		return 1
	fi
	if ! run_date_format ; then
		return 1
	fi

cat <<__EOF__
/* Generated file, do not edit */
/* Generated with build-id.sh c-header */

#define _BUILD_DATE_NUM_		${BID_DATE_EPOCH}
#define _BUILD_DATE_STR_		"${BID_DATE_STR}"
#define _BUILD_DATE_SAFE_STR_		"${BID_DATE_SAFE_STR}"
#define _BUILD_COMMIT_ID_		"${BID_COMMIT_ID_ABBREV}"
__EOF__

	return 0
}

handler_c_header_u_boot_1_2_timestamp()
{
	if ! run_git_log_101 ; then
		return 1
	fi
	if ! run_date_format ; then
		return 1
	fi

cat <<__EOF__
/* Generated file, do not edit */
/* Generated with build-id.sh c-header-u-boot-1-2-timestamp */

#define U_BOOT_DATE			"${BID_DATE_C_DATE_STR}"
#define U_BOOT_TIME			"${BID_DATE_C_TIME_STR}"
__EOF__

	return 0
}

handler_commit_id()
{
	if ! run_git_log_101 ; then
		return 1
	fi

	echo "${BID_COMMIT_ID_FULL}"
	return 0
}

handler_commit_id_abbrev()
{
	if ! run_git_log_101 ; then
		return 1
	fi

	echo "${BID_COMMIT_ID_ABBREV}"
	return 0
}

handler_date_epoch()
{
	if ! run_git_log_101 ; then
		return 1
	fi

	echo "${BID_DATE_EPOCH}"
	return 0
}

handler_date_safe_str()
{
	if ! run_git_log_101 ; then
		return 1
	fi
	if ! run_date_format ; then
		return 1
	fi

	echo "${BID_DATE_SAFE_STR}"
	return 0
}

handler_date_str()
{
	if ! run_git_log_101 ; then
		return 1
	fi
	if ! run_date_format ; then
		return 1
	fi

	echo "${BID_DATE_STR}"
	return 0
}

handler_print_all()
{
	local p_item
	local p_handler
	local ret_val

	for p_item in ${LIST_ITEMS} ; do
		p_handler="handler_$( echo -n "${p_item}" | tr '-' '_' )"

		if ! [ "$( type -t "${p_handler}" )" = function ] ; then
			show_error "Unrecognized item \"${p_item}\" [3]"
			return 84
		fi

		if [ "${p_handler}" = "handler_print_all" ] ; then
			## Do not call this function from itself
			continue
		fi

		echo "######## ${p_item} ################################"
		if ${p_handler} ; then
			ret_val=$?
		else
			ret_val=$?
		fi
		echo "[${ret_val}]"
	done

	return 0
}

handler_repo_url()
{
	if ! run_git_remote_repo_url ; then
		return 1
	fi

	echo "${BID_REPO_URL}"
	return 0
}

##
## Run handler
##

run_item_handler()
{
	"${ITEM_HANDLER_FUNC}"

	return $?
}

##
## Replace file_1 with file_2 if different or if file_1 does not exist
##
replace_file_if_changed()
{
	local file_1="${1}"
	local file_2="${2}"
	local file_bak="${1}.$$.bak.tmp"
	local rv

	if ! [ -e "${file_1}" ] ; then
		## file_1 does not exist
		mv "${file_2}" "${file_1}"
		rm -f "${file_2}"
		return 0
	fi

	set +e
	diff -q "${file_1}" "${file_2}" >/dev/null 2>&1
	rv=$?
	set -e

	if [ "$rv" -eq 0 ] ; then
		## Files are the same, remove file_2
		rm -f "${file_2}"
		return 0
	fi

	if [ "$rv" -eq 1 ] ; then
		## Files are different, replace file_1 with file_2
		mv "${file_1}" "${file_bak}"
		mv "${file_2}" "${file_1}"
		rm -f "${file_2}"
		rm -f "${file_bak}"
		return 0
	fi

	show_error "Error $rv when comparing \"${file_1}\" and \"${file_2}\""
	rm -f "${file_1}"
	rm -f "${file_2}"
	rm -f "${file_bak}"
	return 2
}


##
## Write content to file, if changed
##

write_content_to_file()
{
	local fname
	local newfile

	fname="${1}"
	newfile="${1}.$$.new.tmp"

	run_item_handler >"${newfile}"
	if ! [ -s "${newfile}" ] ; then
		rm -f "${fname}"
		rm -f "${newfile}"
		show_error "Generated empty file"
		return 1
	fi

	replace_file_if_changed "${fname}" "${newfile}"

	return $?
}

##
## Main function
##

build_id_main()
{
	# set -x

	if ! parse_options "$@" ; then
		show_error "Could not parse command-line options"
		exit 1
	fi

	shift $(( OPTIND - 1 ))

	if [ -n "${OPT_WANT_USAGE}" ] ; then
		show_usage 0
		exit 0
	fi

	if ! parse_item_to_print "$@" ; then
		show_error "Could not parse item to print"
		exit 1
	fi

	shift 1

	if ! locate_top_level_dir ; then
		show_error "Could not locate top level git directory"
		exit 1
	fi

	if [ -n "${OPT_OUT_FILE}" ] ; then
		write_content_to_file "${OPT_OUT_FILE}"
	else
		run_item_handler
	fi

	return $?
}

build_id_main "$@"
exit $?
