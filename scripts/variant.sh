# shellcheck shell=sh disable=SC2034

detect_variant() {
	case $1 in "Apple M"[0-9]*) ;; *) return 1 ;; esac
	_gen=${1#Apple M}; _gen=${_gen%%[!0-9]*}
	# Upstream Splash runs on M3 and later only: its engine refuses a GPU below
	# Apple family 9. M1 and M2 run its port.
	if [ "$_gen" -le 2 ]; then echo port; else echo upstream; fi
}

variant_values() {
	case $1 in
		port)
			# The installer keeps each version under SPLASH_HOME and points
			# `current` and the splash-m1 command at the newest.
			SPLASH_VERSION=1.6.1-m1
			SPLASH_INSTALLER_URL=https://github.com/paperniuk/splash/releases/download/$SPLASH_VERSION/install-m1.sh
			SPLASH_INSTALLER_SHA256=f3579df452ae7cd38bf7d1323c587ac0744aac422a915e20e5d1e28dea79a52a
			SPLASH_HOME="$LLM_HOME/Library/Application Support/Splash-M1"
			SPLASH_BIN=$BREW_PREFIX/bin/splash-m1
			SPLASH_RUN_DIR=$SPLASH_HOME
			;;
		upstream)
			SPLASH_VERSION=1.6.1
			SPLASH_ARCHIVE_SHA256=0ed408a781f951a13ff58bed95c9e8c1d1dc67ab9d649fcaf365972b6720ce6c
			# The formula's only bottle, arm64_tahoe.
			SPLASH_BOTTLE_SHA256=6a01f67e5a6c41c83f8fd08372cbd3ad6d3a40d660389bf98846378b86c8d3db
			SPLASH_BIN=$BREW_PREFIX/bin/splash
			SPLASH_RUN_DIR=$BREW_PREFIX/opt/splash/libexec
			;;
		*)
			SPLASH_VERSION='' SPLASH_BIN='' SPLASH_RUN_DIR=''
			;;
	esac
}
