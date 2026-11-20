# bash completion for wgb - the verbs, and the flags that make sense for the verb being typed.
#
# install.sh installs this to <prefix>/share/bash-completion/completions/wgb, which the
# bash-completion package loads automatically. To use it straight from a checkout:
#   source completions/wgb.bash
#
# The tool's parser accepts any flag after any verb; what is offered here is the set that means
# something for that verb (the tool documents --iface and --config-dir for every session verb, since
# they all adopt the running session unless the caller names one).
#
# Client NAMES are deliberately not completed. The profiles hold private keys and the server config
# is root-only, so an unprivileged completion would either fail or expose what is in them - and a
# completion that needs sudo to be useful is worse than no completion.
#
# zsh users: completions/_wgb is the native one; zsh can also load this file through bashcompinit.

# SC2207: word splitting of compgen output into COMPREPLY is exactly what completion wants - one
# candidate per word - so the usual "prefer mapfile" advice does not apply here.
# shellcheck disable=SC2207

_wgb_verbs="up down status doctor list add-client remove-client qr wait ca version help"
_wgb_common_flags="-h --help --version"
_wgb_session_flags="--iface --config-dir"
_wgb_up_flags="--iface --subnet --listen-port --burp-port --dns --mtu --endpoint --wan"
_wgb_up_flags+=" --config-dir --clients --no-proxy --allow-quic --no-fix-firewall --fresh"
_wgb_up_flags+=" --dry-run --print-config --print-rules"

# Interfaces on this machine: the values --iface and --wan take.
_wgb_interfaces() {
  ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | tr '\n' ' '
}

_wgb() {
  local cur verb="" i w flags
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"

  # The verb is the first word that is not an option.
  for ((i = 1; i < COMP_CWORD; i++)); do
    w="${COMP_WORDS[i]}"
    case "$w" in
      -*) ;;
      *) verb="$w"; break ;;
    esac
  done

  # A flag that wants a value: offer what this machine can answer, not a bare blank.
  case "${COMP_WORDS[COMP_CWORD-1]:-}" in
    --iface|--wan)
      COMPREPLY=($(compgen -W "$(_wgb_interfaces)" -- "$cur"))
      return 0 ;;
    --config-dir)
      COMPREPLY=($(compgen -d -- "$cur"))
      return 0 ;;
    --dns)
      COMPREPLY=($(compgen -W "1.1.1.1 8.8.8.8 9.9.9.9 10.0.0.1 192.168.1.1" -- "$cur"))
      return 0 ;;
    --clients)
      COMPREPLY=($(compgen -W "1 2 3 4 5" -- "$cur"))
      return 0 ;;
    --mtu)
      COMPREPLY=($(compgen -W "1280 1300 1380 1420 1500" -- "$cur"))
      return 0 ;;
    --timeout)
      COMPREPLY=($(compgen -W "30 60 120 300" -- "$cur"))
      return 0 ;;
    --subnet|--listen-port|--burp-port|--endpoint)
      return 0 ;;
  esac

  case "$verb" in
    up)     flags="$_wgb_up_flags" ;;
    down)   flags="--purge $_wgb_session_flags" ;;
    qr)     flags="--png $_wgb_session_flags" ;;
    wait)   flags="--timeout $_wgb_session_flags" ;;
    doctor) flags="$_wgb_session_flags --endpoint --wan" ;;
    "")     COMPREPLY=($(compgen -W "$_wgb_verbs $_wgb_common_flags" -- "$cur"))
            return 0 ;;
    *)      flags="$_wgb_session_flags" ;;
  esac
  COMPREPLY=($(compgen -W "$flags $_wgb_common_flags" -- "$cur"))
  return 0
}

complete -F _wgb wgb
