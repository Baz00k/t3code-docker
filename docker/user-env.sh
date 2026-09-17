# shellcheck shell=sh
# User tool environment for the unprivileged t3 account.
#
# Installed as /etc/profile.d/t3-user-env.sh and sourced explicitly by the
# entrypoint before it launches anything, so the server, the setup service and
# the terminals T3 opens all inherit it. It returns early for uid 0: anything in
# the user's home is user-controlled, and root must neither resolve its binaries
# nor create state there.
#
# The mutable npm prefix is handled separately, in /home/t3/.npmrc, because npm
# reads its own user config without needing a shell.

if [ "$(id -u)" != "0" ]; then
  # Go installs user binaries under GOPATH/bin. It is deliberately off the
  # image-wide PATH (see the Dockerfile): root running `go install` should use
  # its own /root/go, and a binary the t3 user dropped here must not be
  # resolvable by root.
  : "${GOPATH:=/home/t3/go}"
  export GOPATH
  case ":$PATH:" in
    *":${GOPATH}/bin:"*) ;;
    *) PATH="${GOPATH}/bin:${PATH}"; export PATH ;;
  esac
fi
