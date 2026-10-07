#!/bin/sh
# Runs on the device after every configuration update (see config_update.toml), as the tedge
# user, with the configuration type as its argument. For a tedge-dot configuration it
#
# 1. reloads tedge-dot (SIGHUP), which applies new, changed and removed connector configs;
# 2. publishes the unit of every measurement as retained thin-edge.io measurement metadata.
#
# Step 2 works around tedge-dot 0.0.11: the connector puts a point's `unit` into its samples, but
# the ot-measurement flow sends bare numbers, so the unit never reaches Cumulocity. thin-edge.io 2.x
# adds units from te/<device>/m/<type>/meta. The units are taken from the samples themselves, so
# this script knows nothing about the pump.
set -eu

case "${1:-}" in
    tedge-dot-*) ;;
    *) exit 0 ;;   # not a tedge-dot configuration: nothing to do
esac

# The connector runs as tedge too, so no privileges are needed.
pkill -HUP -x tedge-dot || true

# Collect the samples for a while after the reload (every point publishes at least once per poll
# interval), then publish one retained metadata message per device and measurement type, holding
# the unit of each of its series. Naming follows ot-measurement: meta.measurement.group/series,
# else the protocol and the point id.
tedge mqtt sub 'te/+/+/ot/+/sample/+' --no-topic --duration 20s 2>/dev/null \
| jq -rcs 'map(select(.unit != null and .unit != "" and .meta.measurement != false)
              | (.meta.measurement // {}) as $m
              | {device, group: ($m.group // .protocol), series: ($m.series // .point), unit})
          | group_by([.device, .group])[]
          | [.[0].device, .[0].group,
             (map({key: "\(.group).\(.series)", value: {unit}}) | from_entries | tojson)]
          | @tsv' \
| while IFS="$(printf '\t')" read -r device group payload; do
    tedge mqtt pub -r "te/device/$device///m/$group/meta" "$payload"
done

echo "tedge-dot reloaded and units published"
