#!/bin/bash

# Loads wget_check function which downloads files using wget.
# The following two flags are used with wget
# 1) tries: set to 5, retry 5 times in case of a failure
# 2) content-on-error: If an error occurs download the error webpage
# If an error occurs wget saves the error webpage in the filename
# provided during download (generally .tar format). We need to rename
# it to .html format, to cat it to stdout

WGET_OPT="--tries=5 --content-on-error"

function wget_check {
    url=$1
    file_name=$2
    bash_option=$-
    restore_e=0
    if [[ $bash_option =~ e ]]; then
        restore_e=1
        set +e
    fi
    # bash -c is used to avoid issues due to quotation within quotation
    bash -c "wget ${WGET_OPT} -O $file_name $url"
    if [ $? -ne 0 ]; then
        if [ -f "$file_name" ]; then
            # Only if the file type has ASCII text output the file
            if [[ $(file $file_name | grep "ASCII") =~ "ASCII" ]]; then
                cat $file_name
            fi
        fi
        exit 1
    fi
    if [ $restore_e -eq 1 ]; then
        set -e
    fi
}
