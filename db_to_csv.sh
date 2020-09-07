#!/bin/bash
set -e

#
# get_last_date_to(item) -> date string
#

function get_last_date_to {
    echo "SELECT time FROM ${1} ORDER BY time DESC LIMIT 1" | psql -t -A
}

# TODO: Are we scared of MIM attacks?
ssh-keyscan -p "2020" ${REMOTE_HOST} > ${HOME}/.ssh/known_hosts   # add remote host to known_hosts

# all in smartenergy known devices
set +e
linked_items=$(curl -s -X GET --header "Accept: application/json" "http://172.20.0.1/rest/things" | jq '.[] | {label: .label, linkedItems: .channels[].linkedItems[]}')
set -e

mkdir -p "${DATA_DIR}"

# Export postgres client parameters
export PGPASSWORD=${POSTGRES_ENV_POSTGRES_PASSWORD}
export PGHOST=${POSTGRES_PORT_5432_TCP_ADDR}

# saves all device names in an array
declare -a item_names=$(echo "SELECT itemname FROM items" | psql -t -A)
for item_name in ${item_names[@]}
do
    item_id=$(echo "SELECT itemid from items where itemname='${item_name}'" | psql -t -A)
    item_table_name=$( printf 'item%04d' ${item_id})
    # get last date
    last_db_date=$(get_last_date_to ${item_table_name})
    if [ "${last_db_date}" == "" ]; then
        echo "NO VALUES FOUND FOR "${item_table_name}", SKIPPING TO NEXT ITEM"
        continue
    fi

    directory="${DATA_DIR}/data/${item_name}"
    mkdir -p "${directory}"

    # date of the last exported row
    last_date_file="${directory}/last_date.txt"

    if [ -f ${last_date_file} ]; then
        last_export_date=$(cat ${last_date_file});
    else
        last_export_date='1970-01-01 00:00:00.00000'
    fi

    #### Write meta json

    # get_label from smartenergy-api
    meta_json=$(echo ${linked_items} | jq "select(.linkedItems | index(\"${item_name}\"))")

    # if no label found, use item_name
    if [ -z "${meta_json}" ]; then
        if [[ "${last_db_date}" != "${last_export_date}" ]]; then
            # We found data, but no label
            meta_json="{\"label\": \"${item_name}\", \"linkedItems\":  \"${item_name}\"}"
        else
            # Found item in db with NO label and NO new data
            continue
        fi
    fi

   # write meta.json
    printf "${meta_json}" > "${directory}/meta.json"

    if [[ "${last_db_date}" == "${last_export_date}" ]]; then
        # Nothing to export
        continue
    fi

    #### export data
    # replace ":" with "-" ---- SCP is not possible with ":"
    item_date_to_pretty=$(echo ${last_db_date} | tr ":" "-")
    # creating csv-file
    output_db=$(echo "${directory}/${item_name}_${item_date_to_pretty}.csv" | tr ' ' '_')
    # write all timestamps and values from each itemtable to csv-file
    echo "\copy (SELECT * FROM ${item_table_name} WHERE time > '${last_export_date}' ORDER BY time) to '${output_db}'" | psql

    # saves the date of the last exported row
    echo ${last_db_date} > ${last_date_file}

    # rename file to <checksum>.csv
    checksum=$(sha1sum ${output_db} | awk '{print $1;}')
    mv ${output_db} "${directory}/${checksum}.csv"

done

#
# make rsync to inf-lvs-ext
#

set +e
for item_name in ${item_names[@]}
do  # sync all exported data
    item_path="${DATA_DIR}/data/${item_name}"
    if [ -d "${item_path}" ]; then
        # upload measurements if csv files exist
        if [ -n "$(find ${item_path} -maxdepth 1 -name '*.csv' -print 2>/dev/null)" ]; then
            rsync -rzce 'ssh -p 2020' ${item_path}/*.csv ${HOUSE}@${REMOTE_HOST}:/${item_name}/ && rm -rf ${item_path}/*.csv
        fi
        # upload meta.json
        rsync -zce 'ssh -p 2020' ${item_path}/meta.json ${HOUSE}@${REMOTE_HOST}:/${item_name}/
    fi
done
