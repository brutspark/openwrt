#!/bin/sh
. /lib/netifd/netifd-wireless.sh
. /lib/netifd/hostapd.sh
. /lib/netifd/mac80211.sh

init_wireless_driver "$@"

MP_CONFIG_INT="mesh_retry_timeout mesh_confirm_timeout mesh_holding_timeout mesh_max_peer_links
	       mesh_max_retries mesh_ttl mesh_element_ttl mesh_hwmp_max_preq_retries
	       mesh_path_refresh_time mesh_min_discovery_timeout mesh_hwmp_active_path_timeout
	       mesh_hwmp_preq_min_interval mesh_hwmp_net_diameter_traversal_time mesh_hwmp_rootmode
	       mesh_hwmp_rann_interval mesh_gate_announcements mesh_sync_offset_max_neighor
	       mesh_rssi_threshold mesh_hwmp_active_path_to_root_timeout mesh_hwmp_root_interval
	       mesh_hwmp_confirmation_interval mesh_awake_window mesh_plink_timeout"
MP_CONFIG_BOOL="mesh_auto_open_plinks mesh_fwding"
MP_CONFIG_STRING="mesh_power_mode"

iw() {
	command iw $@ || logger -t mac80211 "Failed command: iw $@"
}

NEWAPLIST=
OLDAPLIST=
NEWSPLIST=
OLDSPLIST=

drv_mac80211_init_device_config() {
	hostapd_common_add_device_config

	config_add_string path phy 'macaddr:macaddr'
	config_add_string hwmode
	config_add_string tx_burst
	config_add_int beacon_int chanbw frag rts
	config_add_int rxantenna txantenna antenna_gain txpower distance
	config_add_boolean noscan ht_coex acs_exclude_dfs
	config_add_array ht_capab
	config_add_array channels
	config_add_boolean \
		rxldpc \
		short_gi_80 \
		short_gi_160 \
		tx_stbc_2by1 \
		su_beamformer \
		su_beamformee \
		mu_beamformer \
		mu_beamformee \
		vht_txop_ps \
		htc_vht \
		rx_antenna_pattern \
		tx_antenna_pattern
	config_add_int vht_max_a_mpdu_len_exp vht_max_mpdu vht_link_adapt vht160 rx_stbc tx_stbc
	config_add_boolean \
		ldpc \
		greenfield \
		short_gi_20 \
		short_gi_40 \
		max_amsdu \
		dsss_cck_40
}

drv_mac80211_init_iface_config() {
	hostapd_common_add_bss_config

	config_add_string 'macaddr:macaddr' ifname

	config_add_boolean wds powersave enable
	config_add_int maxassoc
	config_add_int max_listen_int
	config_add_int dtim_period
	config_add_int start_disabled

	# mesh
	config_add_string mesh_id
	config_add_int $MP_CONFIG_INT
	config_add_boolean $MP_CONFIG_BOOL
	config_add_string $MP_CONFIG_STRING
}

mac80211_add_capabilities() {
	local __var="$1"; shift
	local __mask="$1"; shift
	local __out= oifs

	oifs="$IFS"
	IFS=:
	for capab in "$@"; do
		set -- $capab

		[ "$(($4))" -gt 0 ] || continue
		[ "$(($__mask & $2))" -eq "$((${3:-$2}))" ] || continue
		__out="$__out[$1]"
	done
	IFS="$oifs"

	export -n -- "$__var=$__out"
}

mac80211_hostapd_setup_base() {
	local phy="$1"

	json_select config

	[ "$auto_channel" -gt 0 ] && channel=acs_survey
	[ "$auto_channel" -gt 0 ] && json_get_values channel_list channels

	[ "$auto_channel" -gt 0 ] && json_get_vars acs_exclude_dfs
	[ -n "$acs_exclude_dfs" ] && [ "$acs_exclude_dfs" -gt 0 ] &&
		append base_cfg "acs_exclude_dfs=1" "$N"

	json_get_vars noscan ht_coex
	json_get_values ht_capab_list ht_capab tx_burst

	[ -n "$noscan" -a "$noscan" -gt 0 ] && hostapd_noscan=1
	[ "$tx_burst" = 0 ] && tx_burst=

	ieee80211n=1
	ht_capab=
	case "$htmode" in
		VHT20|HT20) ;;
		HT40*|VHT40|VHT80|VHT160)
			case "$hwmode" in
				a)
					case "$(( ($channel / 4) % 2 ))" in
						1) ht_capab="[HT40+]";;
						0) ht_capab="[HT40-]";;
					esac
				;;
				*)
					case "$htmode" in
						HT40+) ht_capab="[HT40+]";;
						HT40-) ht_capab="[HT40-]";;
						*)
							if [ "$channel" -lt 7 ]; then
								ht_capab="[HT40+]"
							else
								ht_capab="[HT40-]"
							fi
						;;
					esac
				;;
			esac
			[ "$auto_channel" -gt 0 ] && ht_capab="[HT40+]"
		;;
		*) ieee80211n= ;;
	esac

	[ -n "$ieee80211n" ] && {
		append base_cfg "ieee80211n=1" "$N"

		set_default ht_coex 0
		append base_cfg "ht_coex=$ht_coex" "$N"

		json_get_vars \
			ldpc:1 \
			greenfield:0 \
			short_gi_20:1 \
			short_gi_40:1 \
			tx_stbc:1 \
			rx_stbc:3 \
			max_amsdu:1 \
			dsss_cck_40:1

		ht_cap_mask=0
		for cap in $(iw phy "$phy" info | grep 'Capabilities:' | cut -d: -f2); do
			ht_cap_mask="$(($ht_cap_mask | $cap))"
		done

		cap_rx_stbc=$((($ht_cap_mask >> 8) & 3))
		[ "$rx_stbc" -lt "$cap_rx_stbc" ] && cap_rx_stbc="$rx_stbc"
		ht_cap_mask="$(( ($ht_cap_mask & ~(0x300)) | ($cap_rx_stbc << 8) ))"

		mac80211_add_capabilities ht_capab_flags $ht_cap_mask \
			LDPC:0x1::$ldpc \
			GF:0x10::$greenfield \
			SHORT-GI-20:0x20::$short_gi_20 \
			SHORT-GI-40:0x40::$short_gi_40 \
			TX-STBC:0x80::$tx_stbc \
			RX-STBC1:0x300:0x100:1 \
			RX-STBC12:0x300:0x200:1 \
			RX-STBC123:0x300:0x300:1 \
			MAX-AMSDU-7935:0x800::$max_amsdu \
			DSSS_CCK-40:0x1000::$dsss_cck_40

		ht_capab="$ht_capab$ht_capab_flags"
		[ -n "$ht_capab" ] && append base_cfg "ht_capab=$ht_capab" "$N"
	}

	# 802.11ac
	enable_ac=0
	idx="$channel"
	case "$htmode" in
		VHT20) enable_ac=1;;
		VHT40)
			case "$(( ($channel / 4) % 2 ))" in
				1) idx=$(($channel + 2));;
				0) idx=$(($channel - 2));;
			esac
			enable_ac=1
			append base_cfg "vht_oper_chwidth=0" "$N"
			append base_cfg "vht_oper_centr_freq_seg0_idx=$idx" "$N"
		;;
		VHT80)
			case "$(( ($channel / 4) % 4 ))" in
				1) idx=$(($channel + 6));;
				2) idx=$(($channel + 2));;
				3) idx=$(($channel - 2));;
				0) idx=$(($channel - 6));;
			esac
			enable_ac=1
			append base_cfg "vht_oper_chwidth=1" "$N"
			append base_cfg "vht_oper_centr_freq_seg0_idx=$idx" "$N"
		;;
		VHT160)
			case "$channel" in
				36|40|44|48|52|56|60|64) idx=50;;
				100|104|108|112|116|120|124|128) idx=114;;
			esac
			enable_ac=1
			append base_cfg "vht_oper_chwidth=2" "$N"
			append base_cfg "vht_oper_centr_freq_seg0_idx=$idx" "$N"
		;;
	esac

	if [ "$enable_ac" != "0" ]; then
		json_get_vars \
			rxldpc:1 \
			short_gi_80:1 \
			short_gi_160:1 \
			tx_stbc_2by1:1 \
			su_beamformer:1 \
			su_beamformee:1 \
			mu_beamformer:1 \
			mu_beamformee:1 \
			vht_txop_ps:1 \
			htc_vht:1 \
			rx_antenna_pattern:1 \
			tx_antenna_pattern:1 \
			vht_max_a_mpdu_len_exp:7 \
			vht_max_mpdu:11454 \
			rx_stbc:4 \
			vht_link_adapt:3 \
			vht160:2

		set_default tx_burst 2.0
		append base_cfg "ieee80211ac=1" "$N"
		vht_cap=0
		for cap in $(iw phy "$phy" info | awk -F "[()]" '/VHT Capabilities/ { print $2 }'); do
			vht_cap="$(($vht_cap | $cap))"
		done

		cap_rx_stbc=$((($vht_cap >> 8) & 7))
		[ "$rx_stbc" -lt "$cap_rx_stbc" ] && cap_rx_stbc="$rx_stbc"
		vht_cap="$(( ($vht_cap & ~(0x700)) | ($cap_rx_stbc << 8) ))"

		mac80211_add_capabilities vht_capab $vht_cap \
			RXLDPC:0x10::$rxldpc \
			SHORT-GI-80:0x20::$short_gi_80 \
			SHORT-GI-160:0x40::$short_gi_160 \
			TX-STBC-2BY1:0x80::$tx_stbc_2by1 \
			SU-BEAMFORMER:0x800::$su_beamformer \
			SU-BEAMFORMEE:0x1000::$su_beamformee \
			MU-BEAMFORMER:0x80000::$mu_beamformer \
			MU-BEAMFORMEE:0x100000::$mu_beamformee \
			VHT-TXOP-PS:0x200000::$vht_txop_ps \
			HTC-VHT:0x400000::$htc_vht \
			RX-ANTENNA-PATTERN:0x10000000::$rx_antenna_pattern \
			TX-ANTENNA-PATTERN:0x20000000::$tx_antenna_pattern \
			RX-STBC-1:0x700:0x100:1 \
			RX-STBC-12:0x700:0x200:1 \
			RX-STBC-123:0x700:0x300:1 \
			RX-STBC-1234:0x700:0x400:1 \

		# supported Channel widths
		vht160_hw=0
		[ "$(($vht_cap & 12))" -eq 4 -a 1 -le "$vht160" ] && \
			vht160_hw=1
		[ "$(($vht_cap & 12))" -eq 8 -a 2 -le "$vht160" ] && \
			vht160_hw=2
		[ "$vht160_hw" = 1 ] && vht_capab="$vht_capab[VHT160]"
		[ "$vht160_hw" = 2 ] && vht_capab="$vht_capab[VHT160-80PLUS80]"

		# maximum MPDU length
		vht_max_mpdu_hw=3895
		[ "$(($vht_cap & 3))" -ge 1 -a 7991 -le "$vht_max_mpdu" ] && \
			vht_max_mpdu_hw=7991
		[ "$(($vht_cap & 3))" -ge 2 -a 11454 -le "$vht_max_mpdu" ] && \
			vht_max_mpdu_hw=11454
		[ "$vht_max_mpdu_hw" != 3895 ] && \
			vht_capab="$vht_capab[MAX-MPDU-$vht_max_mpdu_hw]"

		# maximum A-MPDU length exponent
		vht_max_a_mpdu_len_exp_hw=0
		[ "$(($vht_cap & 58720256))" -ge 8388608 -a 1 -le "$vht_max_a_mpdu_len_exp" ] && \
			vht_max_a_mpdu_len_exp_hw=1
		[ "$(($vht_cap & 58720256))" -ge 16777216 -a 2 -le "$vht_max_a_mpdu_len_exp" ] && \
			vht_max_a_mpdu_len_exp_hw=2
		[ "$(($vht_cap & 58720256))" -ge 25165824 -a 3 -le "$vht_max_a_mpdu_len_exp" ] && \
			vht_max_a_mpdu_len_exp_hw=3
		[ "$(($vht_cap & 58720256))" -ge 33554432 -a 4 -le "$vht_max_a_mpdu_len_exp" ] && \
			vht_max_a_mpdu_len_exp_hw=4
		[ "$(($vht_cap & 58720256))" -ge 41943040 -a 5 -le "$vht_max_a_mpdu_len_exp" ] && \
			vht_max_a_mpdu_len_exp_hw=5
		[ "$(($vht_cap & 58720256))" -ge 50331648 -a 6 -le "$vht_max_a_mpdu_len_exp" ] && \
			vht_max_a_mpdu_len_exp_hw=6
		[ "$(($vht_cap & 58720256))" -ge 58720256 -a 7 -le "$vht_max_a_mpdu_len_exp" ] && \
			vht_max_a_mpdu_len_exp_hw=7
		vht_capab="$vht_capab[MAX-A-MPDU-LEN-EXP$vht_max_a_mpdu_len_exp_hw]"

		# whether or not the STA supports link adaptation using VHT variant
		vht_link_adapt_hw=0
		[ "$(($vht_cap & 201326592))" -ge 134217728 -a 2 -le "$vht_link_adapt" ] && \
			vht_link_adapt_hw=2
		[ "$(($vht_cap & 201326592))" -ge 201326592 -a 3 -le "$vht_link_adapt" ] && \
			vht_link_adapt_hw=3
		[ "$vht_link_adapt_hw" != 0 ] && \
			vht_capab="$vht_capab[VHT-LINK-ADAPT-$vht_link_adapt_hw]"

		[ -n "$vht_capab" ] && append base_cfg "vht_capab=$vht_capab" "$N"
	fi

	hostapd_prepare_device_config "$hostapd_conf_file" nl80211
	cat >> "$hostapd_conf_file" <<EOF
${channel:+channel=$channel}
${channel_list:+chanlist=$channel_list}
${hostapd_noscan:+noscan=1}
${tx_burst:+tx_queue_data2_burst=$tx_burst}
$base_cfg

EOF
	json_select ..
}

mac80211_hostapd_setup_bss() {
	local phy="$1"
	local ifname="$2"
	local macaddr="$3"
	local type="$4"

	hostapd_cfg=
	append hostapd_cfg "$type=$ifname" "$N"

	hostapd_set_bss_options hostapd_cfg "$vif" || return 1
	json_get_vars wds dtim_period max_listen_int start_disabled

	set_default wds 0
	set_default start_disabled 0

	[ "$wds" -gt 0 ] && append hostapd_cfg "wds_sta=1" "$N"
	[ "$staidx" -gt 0 -o "$start_disabled" -eq 1 ] && append hostapd_cfg "start_disabled=1" "$N"

	cat >> /var/run/hostapd-$phy.conf <<EOF
$hostapd_cfg
bssid=$macaddr
${dtim_period:+dtim_period=$dtim_period}
${max_listen_int:+max_listen_interval=$max_listen_int}
EOF
}

mac80211_get_addr() {
	local phy="$1"
	local idx="$(($2 + 1))"

	head -n $(($macidx + 1)) /sys/class/ieee80211/${phy}/addresses | tail -n1
}

mac80211_generate_mac() {
	local phy="$1"
	local id="${macidx:-0}"

	local ref="$(cat /sys/class/ieee80211/${phy}/macaddress)"
	local mask="$(cat /sys/class/ieee80211/${phy}/address_mask)"

	[ "$mask" = "00:00:00:00:00:00" ] && {
		mask="ff:ff:ff:ff:ff:ff";

		[ "$(wc -l < /sys/class/ieee80211/${phy}/addresses)" -gt 1 ] && {
			addr="$(mac80211_get_addr "$phy" "$id")"
			[ -n "$addr" ] && {
				echo "$addr"
				return
			}
		}
	}

	local oIFS="$IFS"; IFS=":"; set -- $mask; IFS="$oIFS"

	local mask1=$1
	local mask6=$6

	local oIFS="$IFS"; IFS=":"; set -- $ref; IFS="$oIFS"

	macidx=$(($id + 1))
	[ "$((0x$mask1))" -gt 0 ] && {
		b1="0x$1"
		[ "$id" -gt 0 ] && \
			b1=$(($b1 ^ ((($id - 1) << 2) | 0x2)))
		printf "%02x:%s:%s:%s:%s:%s" $b1 $2 $3 $4 $5 $6
		return
	}

	[ "$((0x$mask6))" -lt 255 ] && {
		printf "%s:%s:%s:%s:%s:%02x" $1 $2 $3 $4 $5 $(( 0x$6 ^ $id ))
		return
	}

	off2=$(( (0x$6 + $id) / 0x100 ))
	printf "%s:%s:%s:%s:%02x:%02x" \
		$1 $2 $3 $4 \
		$(( (0x$5 + $off2) % 0x100 )) \
		$(( (0x$6 + $id) % 0x100 ))
}

find_phy() {
	[ -n "$phy" -a -d /sys/class/ieee80211/$phy ] && return 0
	[ -n "$path" ] && {
		phy="$(mac80211_path_to_phy "$path")"
		[ -n "$phy" ] && return 0
	}
	[ -n "$macaddr" ] && {
		for phy in $(ls /sys/class/ieee80211 2>/dev/null); do
			grep -i -q "$macaddr" "/sys/class/ieee80211/${phy}/macaddress" && return 0
		done
	}
	return 1
}

mac80211_check_ap() {
	has_ap=1
}

mac80211_iw_interface_add() {
	local phy="$1"
	local ifname="$2"
	local type="$3"
	local wdsflag="$4"
	local rc

	iw phy "$phy" interface add "$ifname" type "$type" $wdsflag
	rc="$?"

	[ "$rc" = 233 ] && {
		# Device might have just been deleted, give the kernel some time to finish cleaning it up
		sleep 1

		iw phy "$phy" interface add "$ifname" type "$type" $wdsflag
		rc="$?"
	}

	[ "$rc" = 233 ] && {
		# Device might not support virtual interfaces, so the interface never got deleted in the first place.
		# Check if the interface already exists, and avoid failing in this case.
		ip link show dev "$ifname" >/dev/null 2>/dev/null && rc=0
	}

	[ "$rc" != 0 ] && wireless_setup_failed INTERFACE_CREATION_FAILED
	return $rc
}

mac80211_prepare_vif() {
	json_select config

	json_get_vars ifname mode ssid wds powersave macaddr enable

	[ -n "$ifname" ] || ifname="wlan${phy#phy}${if_idx:+-$if_idx}"
	if_idx=$((${if_idx:-0} + 1))

	set_default wds 0
	set_default powersave 0

	json_select ..

	[ -n "$macaddr" ] || {
		macaddr="$(mac80211_generate_mac $phy)"
		macidx="$(($macidx + 1))"
	}

	json_add_object data
	json_add_string ifname "$ifname"
	json_close_object
	json_select config

	# It is far easier to delete and create the desired interface
	case "$mode" in
		adhoc)
			mac80211_iw_interface_add "$phy" "$ifname" adhoc || return
		;;
		ap)
			# Hostapd will handle recreating the interface and
			# subsequent virtual APs belonging to the same PHY
			if [ -n "$hostapd_ctrl" ]; then
				type=bss
			else
				type=interface
			fi

			mac80211_hostapd_setup_bss "$phy" "$ifname" "$macaddr" "$type" || return

			NEWAPLIST="${NEWAPLIST}$ifname "
			[ -n "$hostapd_ctrl" ] || {
				hostapd_ctrl="${hostapd_ctrl:-/var/run/hostapd/$ifname}"
			}
		;;
		mesh)
			mac80211_iw_interface_add "$phy" "$ifname" mp || return
		;;
		monitor)
			mac80211_iw_interface_add "$phy" "$ifname" monitor || return
		;;
		sta)
			local wdsflag=
			[ "$enable" = 0 ] || staidx="$(($staidx + 1))"
			[ "$wds" -gt 0 ] && wdsflag="4addr on"
			mac80211_iw_interface_add "$phy" "$ifname" managed "$wdsflag" || return
			[ "$powersave" -gt 0 ] && powersave="on" || powersave="off"
			iw "$ifname" set power_save "$powersave"
		;;
	esac

	case "$mode" in
		monitor|mesh)
			[ "$auto_channel" -gt 0 ] || iw dev "$ifname" set channel "$channel" $htmode
		;;
	esac

	if [ "$mode" != "ap" ]; then
		# ALL ap functionality will be passed to hostapd
		# All interfaces must have unique mac addresses
		# which can either be explicitly set in the device
		# section, or automatically generated
		ip link set dev "$ifname" address "$macaddr"
	fi

	json_select ..
}

mac80211_setup_supplicant() {
	local enable=$1
	local add_sp=0
	local spobj="$(ubus -S list | grep wpa_supplicant.${ifname})"

	wpa_supplicant_prepare_interface "$ifname" nl80211 || return 1
	wpa_supplicant_prepare_interface "$ifname" nl80211 || {
		iw dev "$ifname" del
		return 1
	}
	if [ "$mode" = "sta" ]; then
		wpa_supplicant_add_network "$ifname"
	else
		wpa_supplicant_add_network "$ifname" "$freq" "$htmode" "$noscan"
	fi

	NEWSPLIST="${NEWSPLIST}$ifname "

	if [ "${NEWAPLIST%% *}" != "${OLDAPLIST%% *}" ]; then
		[ "$spobj" ] && ubus call wpa_supplicant.${phy} config_del "{\"iface\":\"$ifname\"}"
		add_sp=1
	fi
	[ "$enable" = 0 ] && {
		ubus call wpa_supplicant.${phy} config_del "{\"iface\":\"$ifname\"}"
		ip link set dev "$ifname" down
		return 0
	}
	[ -z "$spobj" ] && add_sp=1

	if [ "$add_sp" = "1" ]; then
		wpa_supplicant_run "$ifname" "$hostapd_ctrl"
	else
		ubus call $spobj reload
	fi
}

mac80211_setup_supplicant_noctl() {
	local enable=$1
	local spobj="$(ubus -S list | grep wpa_supplicant.${ifname})"
	wpa_supplicant_prepare_interface "$ifname" nl80211 || {
		iw dev "$ifname" del
		return 1
	}

	wpa_supplicant_add_network "$ifname" "$freq" "$htmode" "$noscan"

	NEWSPLIST="${NEWSPLIST}$ifname "
	[ "$enable" = 0 ] && {
		ubus call wpa_supplicant.${phy} config_del "{\"iface\":\"$ifname\"}"
		ip link set dev "$ifname" down
		return 0
	}
	if [ -z "$spobj" ]; then
		wpa_supplicant_run "$ifname"
	else
		ubus call $spobj reload
	fi
}

mac80211_setup_adhoc_htmode() {
	case "$htmode" in
		VHT20|HT20) ibss_htmode=HT20;;
		HT40*|VHT40|VHT160)
			case "$hwmode" in
				a)
					case "$(( ($channel / 4) % 2 ))" in
						1) ibss_htmode="HT40+" ;;
						0) ibss_htmode="HT40-";;
					esac
				;;
				*)
					case "$htmode" in
						HT40+) ibss_htmode="HT40+";;
						HT40-) ibss_htmode="HT40-";;
						*)
							if [ "$channel" -lt 7 ]; then
								ibss_htmode="HT40+"
							else
								ibss_htmode="HT40-"
							fi
						;;
					esac
				;;
			esac
			[ "$auto_channel" -gt 0 ] && ibss_htmode="HT40+"
		;;
		VHT80)
			ibss_htmode="80MHZ"
		;;
		NONE|NOHT)
			ibss_htmode="NOHT"
		;;
		*) ibss_htmode="" ;;
	esac
}

mac80211_setup_adhoc() {
	local enable=$1
	json_get_vars bssid ssid key mcast_rate

	[ "$enable" = 0 ] && {
		ip link set dev "$ifname" down
		return 0
	}

	keyspec=
	[ "$auth_type" = "wep" ] && {
		set_default key 1
		case "$key" in
			[1234])
				local idx
				for idx in 1 2 3 4; do
					json_get_var ikey "key$idx"

					[ -n "$ikey" ] && {
						ikey="$(($idx - 1)):$(prepare_key_wep "$ikey")"
						[ $idx -eq $key ] && ikey="d:$ikey"
						append keyspec "$ikey"
					}
				done
			;;
			*)
				append keyspec "d:0:$(prepare_key_wep "$key")"
			;;
		esac
	}

	brstr=
	for br in $basic_rate_list; do
		wpa_supplicant_add_rate brstr "$br"
	done

	mcval=
	[ -n "$mcast_rate" ] && wpa_supplicant_add_rate mcval "$mcast_rate"

	iw dev "$ifname" ibss join "$ssid" $freq $ibss_htmode fixed-freq $bssid \
		beacon-interval $beacon_int \
		${brstr:+basic-rates $brstr} \
		${mcval:+mcast-rate $mcval} \
		${keyspec:+keys $keyspec}
}

mac80211_setup_mesh() {
	local enable=$1
	json_get_vars ssid mesh_id mcast_rate

	[ "$enable" = 0 ] && {
		ip link set dev "$ifname" down
		return 0
	}

	mcval=
	[ -n "$mcast_rate" ] && wpa_supplicant_add_rate mcval "$mcast_rate"
	[ -n "$mesh_id" ] && ssid="$mesh_id"

	case "$htmode" in
		VHT20|HT20) mesh_htmode=HT20;;
		HT40*|VHT40)
			case "$hwmode" in
				a)
					case "$(( ($channel / 4) % 2 ))" in
						1) mesh_htmode="HT40+" ;;
						0) mesh_htmode="HT40-";;
					esac
				;;
				*)
					case "$htmode" in
						HT40+) mesh_htmode="HT40+";;
						HT40-) mesh_htmode="HT40-";;
						*)
							if [ "$channel" -lt 7 ]; then
								mesh_htmode="HT40+"
							else
								mesh_htmode="HT40-"
							fi
						;;
					esac
				;;
			esac
		;;
		VHT80)
			mesh_htmode="80Mhz"
		;;
		VHT160)
			mesh_htmode="160Mhz"
		;;
		*) mesh_htmode="NOHT" ;;
	esac
	iw dev "$ifname" mesh join "$ssid" freq $freq $mesh_htmode \
		${mcval:+mcast-rate $mcval} \
		beacon-interval $beacon_int
}

mac80211_setup_vif() {
	local name="$1"
	local failed
	local action=up

	json_select data
	json_get_vars ifname
	json_select ..

	json_select config
	json_get_vars mode
	json_get_var vif_txpower txpower
	json_get_var vif_enable enable 1

	[ "$vif_enable" = 1 ] || action=down
	logger ip link set dev "$ifname" $action
	ip link set dev "$ifname" "$action" || {
		wireless_setup_vif_failed IFUP_ERROR
		json_select ..
		return
	}
	set_default vif_txpower "$txpower"
	[ -z "$vif_txpower" ] || iw dev "$ifname" set txpower fixed "${vif_txpower%%.*}00"

	case "$mode" in
		mesh)
			wireless_vif_parse_encryption
			freq="$(get_freq "$phy" "$channel")"
			if [ "$wpa" -gt 0 -o "$auto_channel" -gt 0 ] || chan_is_dfs "$phy" "$channel"; then
				mac80211_setup_supplicant $vif_enable || failed=1
			else
				mac80211_setup_mesh $vif_enable
			fi
			for var in $MP_CONFIG_INT $MP_CONFIG_BOOL $MP_CONFIG_STRING; do
				json_get_var mp_val "$var"
				[ -n "$mp_val" ] && iw dev "$ifname" set mesh_param "$var" "$mp_val"
			done
		;;
		adhoc)
			wireless_vif_parse_encryption
			mac80211_setup_adhoc_htmode
			if [ "$wpa" -gt 0 -o "$auto_channel" -gt 0 ]; then
				freq="$(get_freq "$phy" "$channel")"
				mac80211_setup_supplicant_noctl $vif_enable || failed=1
			else
				mac80211_setup_adhoc $vif_enable
			fi
		;;
		sta)
			mac80211_setup_supplicant $vif_enable || failed=1
		;;
	esac

	json_select ..
	[ -n "$failed" ] || wireless_add_vif "$name" "$ifname"
}

get_freq() {
	local phy="$1"
	local chan="$2"
	iw "$phy" info | grep -E -m1 "(\* ${chan:-....} MHz${chan:+|\\[$chan\\]})" | grep MHz | awk '{print $2}'
}

chan_is_dfs() {
	local phy="$1"
	local chan="$2"
	iw "$phy" info | grep -E -m1 "(\* ${chan:-....} MHz${chan:+|\\[$chan\\]})" | grep -q "MHz.*radar detection"
	return $!
}

mac80211_vap_cleanup() {
	local service="$1"
	local vaps="$2"

	for wdev in $vaps; do
		ubus call ${service}.${phy} config_remove "{\"iface\":\"$wdev\"}"
		ip link set dev "$wdev" down 2>/dev/null
		iw dev "$wdev" del
	done
}

mac80211_interface_cleanup() {
	local phy="$1"
	local primary_ap=$(uci -q -P /var/state get wireless._${phy}.aplist)
	primary_ap=${primary_ap%% *}

	mac80211_vap_cleanup hostapd "${primary_ap}"
	mac80211_vap_cleanup wpa_supplicant "$(uci -q -P /var/state get wireless._${phy}.splist)"
	for wdev in $(list_phy_interfaces "$phy"); do
		local wdev_phy="$(readlink /sys/class/net/${wdev}/phy80211)"
		wdev_phy="$(basename "$wdev_phy")"
		[ -n "$wdev_phy" -a "$wdev_phy" != "$phy" ] && continue
		ip link set dev "$wdev" down 2>/dev/null
		iw dev "$wdev" del
	done
}

mac80211_set_noscan() {
	hostapd_noscan=1
}

drv_mac80211_cleanup() {
	hostapd_common_cleanup
}

drv_mac80211_setup() {
	json_select config
	json_get_vars \
		phy macaddr path \
		country chanbw distance \
		txpower antenna_gain \
		rxantenna txantenna \
		frag rts beacon_int:100 htmode
	json_get_values basic_rate_list basic_rate
	json_select ..

	find_phy || {
		echo "Could not find PHY for device '$1'"
		wireless_set_retry 0
		return 1
	}

	[ -z "$(uci -q -P /var/state show wireless._${phy})" ] && {
		uci -q -P /var/state set wireless._${phy}=phy
		wireless_set_data phy="$phy"
	}

	# convert channel to frequency
	[ "$auto_channel" -gt 0 ] || freq="$(get_freq "$phy" "$channel")"

	[ -n "$country" ] && {
		iw reg get | grep -q "^country $country:" || {
			iw reg set "$country"
			sleep 1
		}
	}

	hostapd_conf_file="/var/run/hostapd-$phy.conf"

	no_ap=1
	macidx=0
	staidx=0

	[ -n "$chanbw" ] && {
		for file in /sys/kernel/debug/ieee80211/$phy/ath9k/chanbw /sys/kernel/debug/ieee80211/$phy/ath5k/bwmode; do
			[ -f "$file" ] && echo "$chanbw" > "$file"
		done
	}

	set_default rxantenna 0xffffffff
	set_default txantenna 0xffffffff
	set_default distance 0
	set_default antenna_gain 0

	[ "$txantenna" = "all" ] && txantenna=0xffffffff
	[ "$rxantenna" = "all" ] && rxantenna=0xffffffff

	iw phy "$phy" set antenna $txantenna $rxantenna >/dev/null 2>&1
	iw phy "$phy" set antenna_gain $antenna_gain
	iw phy "$phy" set distance "$distance"

	[ -n "$frag" ] && iw phy "$phy" set frag "${frag%%.*}"
	[ -n "$rts" ] && iw phy "$phy" set rts "${rts%%.*}"

	has_ap=
	hostapd_ctrl=
	hostapd_noscan=
	for_each_interface "ap" mac80211_check_ap

	rm -f "$hostapd_conf_file"

	for_each_interface "sta adhoc mesh" mac80211_set_noscan
	[ -n "$has_ap" ] && mac80211_hostapd_setup_base "$phy"

	for_each_interface "sta adhoc mesh monitor" mac80211_prepare_vif
	NEWAPLIST=
	for_each_interface "ap" mac80211_prepare_vif
	OLDAPLIST=$(uci -q -P /var/state get wireless._${phy}.aplist)
	NEW_MD5=$(md5sum ${hostapd_conf_file})
	OLD_MD5=$(uci -q -P /var/state get wireless._${phy}.md5)
	if [ "${NEWAPLIST}" != "${OLDAPLIST}" ]; then
		mac80211_vap_cleanup hostapd "${OLDAPLIST}"
		[ -n "${NEWAPLIST}" ] && mac80211_iw_interface_add "$phy" "${NEWAPLIST%% *}" __ap || return
	fi
	local add_ap=0
	local primary_ap=${NEWAPLIST%% *}
	[ -n "$hostapd_ctrl" ] && {
		if [ -n "$(ubus list | grep hostapd.$primary_ap)" ]; then
			[ "${NEW_MD5}" = "${OLD_MD5}" ] || {
				ubus call hostapd.$primary_ap reload
			}
		else
			add_ap=1
			ubus call hostapd.${phy} config_add "{\"iface\":\"$primary_ap\", \"config\":\"${hostapd_conf_file}\"}"
		fi
		ret="$?"
		[ "$ret" != 0 ] && {
			wireless_setup_failed HOSTAPD_START_FAILED
			return
		}
	}
	uci -q -P /var/state set wireless._${phy}.aplist="${NEWAPLIST}"
	uci -q -P /var/state set wireless._${phy}.md5="${NEW_MD5}"

	[ "${add_ap}" = 1 ] && sleep 1
	for_each_interface "ap" mac80211_setup_vif

	NEWSPLIST=
	OLDSPLIST=$(uci -q -P /var/state get wireless._${phy}.splist)
	for_each_interface "sta adhoc mesh monitor" mac80211_setup_vif

	uci -q -P /var/state set wireless._${phy}.splist="${NEWSPLIST}"

	local foundvap
	local dropvap=""
	for oldvap in $OLDSPLIST; do
		foundvap=0
		for newvap in $NEWSPLIST; do
			[ "$oldvap" = "$newvap" ] && foundvap=1
		done
		[ "$foundvap" = "0" ] && dropvap="$dropvap $oldvap"
	done
	[ -n "$dropvap" ] && mac80211_vap_cleanup wpa_supplicant "$dropvap"
	wireless_set_up
}

list_phy_interfaces() {
	local phy="$1"
	if [ -d "/sys/class/ieee80211/${phy}/device/net" ]; then
		ls "/sys/class/ieee80211/${phy}/device/net" 2>/dev/null;
	else
		ls "/sys/class/ieee80211/${phy}/device" 2>/dev/null | grep net: | sed -e 's,net:,,g'
	fi
}

drv_mac80211_teardown() {
	wireless_process_kill_all

	json_select data
	json_get_vars phy
	json_select ..

	mac80211_interface_cleanup "$phy"
	uci -q -P /var/state revert wireless._${phy}
}

add_driver mac80211
