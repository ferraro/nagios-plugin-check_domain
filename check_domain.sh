#!/bin/sh
# Nagios plugin for checking a domain name expiration date
#
# Copyright (c) 2005 Tomàs Núñez Lirola <tnunez@criptos.com>,
# Copyright (c) 2009-2014 Elan Ruusamäe <glen@pld-linux.org>
#
# Licensed under GPL v2 License
# URL: https://github.com/glensc/nagios-plugin-check_domain

PROGRAM=${0##*/}
VERSION=1.3.3
PROGPATH=${0%/*}
. $PROGPATH/utils.sh

# Default values (days):
critical=7
warning=30

# Parse arguments
args=$(getopt -o hd:w:c:P: --long help,domain:,warning:,critical:,path: -u -n $PROGRAM -- "$@")
if [ $? != 0 ]; then
	echo >&2 "$PROGRAM: Could not parse arguments"
	echo "Usage: $PROGRAM -h | -d <domain> [-c <critical>] [-w <warning>]"
	exit 1
fi
set -- $args

die() {
	local rc=$1
	local msg="$2"
	echo "$msg"
	exit $rc
}

fullusage() {
	cat <<EOF
check_domain - v$VERSION
Copyright (c) 2005 Tomàs Núñez Lirola <tnunez@criptos.com>,
Copyright (c) 2009-2014 Elan Ruusamäe <glen@pld-linux.org>
Under GPL v2 License

This plugin checks the expiration date of a domain name.

Usage: $PROGRAM -h | -d <domain> [-c <critical>] [-w <warning>]
NOTE: -d must be specified

Options:
-h
     Print detailed help
-d
     Domain name to check
-w
     Response time to result in warning status (days)
-c
     Response time to result in critical status (days)

This plugin will use whois service to get the expiration date for the domain name.
Example:
     $PROGRAM -d domain.tld -w 30 -c 10

EOF
}

while :; do
	case "$1" in
		-c|--critical) critical=$2; shift 2;;
		-w|--warning)  warning=$2; shift 2;;
		-d|--domain)   domain=$2; shift 2;;
		-P|--path)     whoispath=$2; shift 2;;
		-h|--help)     fullusage; exit;;
		--) shift; break;;
		*)  die $STATE_UNKNOWN "Internal error!";;
	esac
done

if [ -z $domain ]; then
	die $STATE_UNKNOWN "UNKNOWN - There is no domain name to check"
fi

# Looking for whois binary
if [ -n "$whoispath" ]; then
	if [ -f "$whoispath" ] && [ -x "$whoispath" ]; then
		whois=$whoispath
	elif [ -x "$whoispath/whois" ]; then
		whois=$whoispath/whois
	fi
	[ -n "$whois" ] || die $STATE_UNKNOWN "UNKNOWN - Unable to find whois binary, you specified an incorrect path"
else
	type whois > /dev/null 2>&1 || die $STATE_UNKNOWN "UNKNOWN - Unable to find whois binary in your path. Is it installed? Please specify path."
	whois=whois
fi

out=$($whois $domain)

[ -z "$out" ] && die $STATE_UNKNOWN "UNKNOWN - Domain $domain doesn't exist or no WHOIS server available."

# Calculate days until expiration
expiration=$(
	echo "$out" | awk '
	BEGIN {
		HH_MM_DD = "[0-9][0-9]:[0-9][0-9]:[0-9][0-9]"
		YYYY = "[0-9][0-9][0-9][0-9]"
		DD = "[0-9][0-9]"
		MON = "[A-Z][a-z][a-z]"
		DATE_DD_MM_YYYY_DOT = "[0-9][0-9]\.[0-9][0-9]\.[0-9][0-9][0-9][0-9]"
		DATE_DD_MON_YYYY = "[0-9][0-9]-[A-Z][a-z][a-z]-[0-9][0-9][0-9][0-9]"
		DATE_ISO_FULL = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T"
		DATE_ISO_LIKE = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] "
		DATE_YYYY_MM_DD_DASH = "[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]"
		DATE_YYYY_MM_DD_DOT = "[0-9][0-9][0-9][0-9]\.[0-9][0-9]\.[0-9][0-9]"
		DATE_YYYY_MM_DD_SLASH = "[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9]"
		# Wed Mar 02 23:59:59 GMT 2016
		DATE_DAY_MON_DD_HHMMSS_TZ_YYYY = "[A-Z][a-z][a-z] [A-Z][a-z][a-z] [0-9][0-9] " HH_MM_DD " GMT " YYYY
		# 02-May-2018 16:12:25 UTC
		DATE_DD_MON_YYYY_HHMMSS_TZ = "[0-9][0-9]-" MON "-" YYYY " " HH_MM_DD " UTC"

		split("January February March April May June July August September October November December", months, " ");
		for (i in months) {
			Month[months[i]] = i;
		}

		split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", months, " ");
		for (i in months) {
			Mon[months[i]] = i;
		}
	}

	# convert short month name to month number (Month Of Year)
	function mon2moy(month) {
		return Mon[month]
	}

	# convert long month name to month number (Month Of Year)
	function month2moy(month) {
		return Month[month]
	}

	# Renewal date:
	#   Monday 21st Sep 2015
	/Renewal date:/{renewal = 1; next}
	{if (renewal) { sub(/[^0-9]+/, "", $2); printf("%s-%s-%s", $4, mon2moy($3), $2); ; exit}}

	# Expiry date:  05-Dec-2014
	/Expiry date:/ && $NF ~ DATE_DD_MON_YYYY {split($3, a, "-"); printf("%s-%s-%s\n", a[3], mon2moy(a[2]), a[1])}

	# expires:	2015-11-18
	/expires:[ ]+/ && $NF ~ DATE_YYYY_MM_DD_DASH {print $NF; exit}

	# expires:      March  5 2014
	/expires:/{printf("%s-%s-%s\n", $4, month2moy($2), $3); exit}

	# renewal: 31-March-2016
	/renewal:/{split($2, a, "-"); printf("%s-%s-%s\n", a[3], month2moy(a[2]), a[1]); exit}

	# paid-till: 2013.11.01
	/paid-till:/ && $NF ~ DATE_YYYY_MM_DD_DOT {split($2, a, "."); printf("%s-%s-%s", a[1], a[2], a[3]); exit}

	# expire: 16.11.2013
	/expire:/ && $NF ~ DATE_DD_MM_YYYY_DOT {split($2, a, "."); printf("%s-%s-%s", a[3], a[2], a[1]); exit}

	# Expiration Date: 2017-01-26T10:14:11Z
	# Registrar Registration Expiration Date: 2018-09-21 00:00:00 -0400
	# Registrar Registration Expiration Date: 2015-02-22T00:00:00Z
	$0 ~ "Expiration Date: " DATE_ISO_LIKE {split($0, a, ":"); s = a[2]; if (split(s,d,/T/)) print d[1]; exit}

	# Domain Expiration Date: Wed Mar 02 23:59:59 GMT 2016
	$0 ~ "Expiration Date: *" DATE_DAY_MON_DD_HHMMSS_TZ_YYYY {
		printf("%s-%s-%s", $9, mon2moy($5), $6);
	}

	# Expiration Date:02-May-2018 16:12:25 UTC
	$0 ~ "Expiration Date: *" DATE_DD_MON_YYYY_HHMMSS_TZ {
		sub(/Date:/, "Date: ")
		split($3, a, "-");
		printf("%s-%s-%s", a[3], mon2moy(a[2]), a[1]);
	}

	# Registry Expiry Date: 2015-08-03T04:00:00Z
	# Registry Expiry Date: 2017-01-26T10:14:11Z
	$0 ~ "Expiry Date: " DATE_ISO_FULL {split($0, a, ":"); s = a[2]; if (split(s,d,/T/)) print d[1]; exit}

	# Expiry date: 2017/07/16
	/Expiry date:/ && $NF ~ DATE_YYYY_MM_DD_SLASH {split($3, a, "/"); printf("%s-%s-%s", a[1], a[2], a[3]); exit}

	# Expires: 2014-01-31
	# Expiry : 2014-03-08
	# Valid-date          2014-10-21
	/Valid-date|Expir(es|ation|y)/ && $NF ~ DATE_YYYY_MM_DD_DASH {print $NF; exit}
')

[ -z "$expiration" ] && die $STATE_UNKNOWN "UNKNOWN - Unable to figure out expiration date for $domain Domain."

expseconds=$(date +%s --date="$expiration")
expdate=$(date +'%Y-%m-%d' --date="$expiration")
nowseconds=$(date +%s)
diffseconds=$((expseconds-nowseconds))
expdays=$((diffseconds/86400))

# Trigger alarms if applicable
[ $expdays -lt 0 ] && die $STATE_CRITICAL "CRITICAL - Domain $domain expired on $expiration"
[ $expdays -lt $critical ] && die $STATE_CRITICAL "CRITICAL - Domain $domain will expire in $expdays days ($expdate)."
[ $expdays -lt $warning ] && die $STATE_WARNING "WARNING - Domain $domain will expire in $expdays days ($expdate)."

# No alarms? Ok, everything is right.
echo "OK - Domain $domain will expire in $expdays days ($expdate)."
exit $STATE_OK
