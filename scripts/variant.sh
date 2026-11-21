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
			SPLASH_VERSION=1.6.1-m1.1
			SPLASH_INSTALLER_URL=https://github.com/paperniuk/splash/releases/download/$SPLASH_VERSION/install-m1.sh
			SPLASH_INSTALLER_SHA256=89b1a1616bbbb4e5a6ec95f70f1a722f61baf00cf942e1e8c4cb0109665ddc4f
			SPLASH_HOME="$LLM_HOME/Library/Application Support/Splash-M1"
			SPLASH_BIN=$BREW_PREFIX/bin/splash-m1
			SPLASH_RUN_DIR=$SPLASH_HOME
			;;
		upstream)
			SPLASH_VERSION=1.7.0
			SPLASH_ARCHIVE_SHA256=5cbb1a6708443383c08262bca7c3d8261109caf74238fdafca063435074b586d
			# The formula's only bottle, arm64_tahoe.
			SPLASH_BOTTLE_SHA256=f86e7857146930174df0ccf72c1ac42e5c93eaa225f00715b10f40b678cf038c
			SPLASH_BIN=$BREW_PREFIX/bin/splash
			SPLASH_RUN_DIR=$BREW_PREFIX/opt/splash/libexec
			;;
		*)
			SPLASH_VERSION='' SPLASH_BIN='' SPLASH_RUN_DIR=''
			;;
	esac
}
