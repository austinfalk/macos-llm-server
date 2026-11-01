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
			SPLASH_VERSION=1.4.0-m1
			SPLASH_INSTALLER_URL=https://github.com/paperniuk/splash/releases/download/$SPLASH_VERSION/install-m1.sh
			SPLASH_INSTALLER_SHA256=9e61b9d3a3a1a3646170df628c14beb52abe1b59babea2710c5991c228a1ad17
			SPLASH_HOME="$LLM_HOME/Library/Application Support/Splash-M1"
			SPLASH_BIN=$BREW_PREFIX/bin/splash-m1
			SPLASH_RUN_DIR=$SPLASH_HOME
			;;
		upstream)
			SPLASH_VERSION=1.5.0
			SPLASH_ARCHIVE_SHA256=1ddc28bf7bfda8833859a913d7072e2aac9072addb9eb5664f3bf1a83a8d6ee2
			# The formula's only bottle, arm64_tahoe.
			SPLASH_BOTTLE_SHA256=515ae0aa6fd3c1efa391903c3b669b5d8000557ac14293af82fb17c9521bfcd6
			SPLASH_BIN=$BREW_PREFIX/bin/splash
			SPLASH_RUN_DIR=$BREW_PREFIX/opt/splash/libexec
			;;
		*)
			SPLASH_VERSION='' SPLASH_BIN='' SPLASH_RUN_DIR=''
			;;
	esac
}
