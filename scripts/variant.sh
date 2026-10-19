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
			SPLASH_VERSION=1.3.2-m1.1
			SPLASH_INSTALLER_URL=https://github.com/paperniuk/splash/releases/download/$SPLASH_VERSION/install-m1.sh
			SPLASH_INSTALLER_SHA256=126ad31847498d1384090b73498ab14c59bed09140a37cd8d39cf804000a049e
			SPLASH_HOME="$LLM_HOME/Library/Application Support/Splash-M1"
			SPLASH_BIN=$BREW_PREFIX/bin/splash-m1
			SPLASH_RUN_DIR=$SPLASH_HOME
			;;
		upstream)
			SPLASH_VERSION=1.3.2
			SPLASH_ARCHIVE_SHA256=c3deb1dd971461ffafcf6b82c318789d6698b22aa865e490a11a0ed943686c0b
			# The formula's only bottle, arm64_tahoe.
			SPLASH_BOTTLE_SHA256=6d5c864c49acdd83d5df93850efb8c113383eaaab7008a07accd475e5edf014f
			SPLASH_BIN=$BREW_PREFIX/bin/splash
			SPLASH_RUN_DIR=$BREW_PREFIX/opt/splash/libexec
			;;
		*)
			SPLASH_VERSION='' SPLASH_BIN='' SPLASH_RUN_DIR=''
			;;
	esac
}
