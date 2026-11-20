#!/usr/bin/env bash
#
# Install wgb onto this machine.
#
#   sudo ./install.sh                 install to /usr/local/bin/wgb (recommended)
#        ./install.sh --dry-run       print exactly what would happen, change nothing
#   sudo ./install.sh --uninstall     remove exactly what a previous install recorded
#
# AI-assisted: a coding agent wrote most of this (see README.md).
#
# WHY /usr/local AND NOT /usr/bin - AND WHEN THAT FLIPS
#   /usr/bin belongs to the distribution's package manager - it is the directory `dpkg -S` and apt
#   own, and a distribution package that ever ships a `wgb` would collide with ours (and a distro
#   upgrade could replace it without warning). /usr/local is the FHS home for software the machine's
#   administrator installed and no package manager touches.
#
#   But wgb is run through sudo, and sudo finds commands in secure_path, NOT in your PATH. On a host
#   whose sudoers trims secure_path - Kali and Debian both ship variants that do - /usr/local/bin is
#   invisible to sudo and `sudo wgb up` fails with "command not found" even though the tool is
#   installed. So the installer reads secure_path, and if the default prefix is not on it, it installs
#   to /usr/bin instead and says so. An explicit --prefix/--bindir is always honoured, with a warning.
#
# WHY A COPY AND NOT A SYMLINK
#   wgb is run with sudo, so the file sudo executes must not be writable by anyone but root. A
#   symlink into a user-writable checkout would mean any process running as that user - or any
#   `git pull` in that checkout - decides what root runs next. The tool already refuses a
#   user-writable --config-dir for exactly this reason, and the installer keeps the same rule: the
#   installed file is a root-owned copy. `--link` exists for development and says what it costs.
#
# WHAT IT INSTALLS  (every path is recorded in a manifest, so --uninstall removes these and only these)
#   <prefix>/bin/wgb                                   the tool (0755, root:root, atomic replace)
#   <prefix>/share/bash-completion/completions/wgb      bash completion for verbs and flags
#   <prefix>/share/zsh/site-functions/_wgb              zsh completion (fpath-checked; see below)
#   <prefix>/share/doc/wgb/README.md                   the documentation
#   <prefix>/share/doc/wgb/troubleshooting.md          the symptom-by-symptom reference
#   <prefix>/share/doc/wgb/LICENSE                     the licence
#   <prefix>/share/wgb/install-manifest                 what was installed, read by --uninstall
#
# zsh loads a completion only from a directory on its fpath, and the sites are not equal: on Debian
# /usr/local/share/zsh/site-functions is on the default fpath while /usr/share/zsh/site-functions is
# not. The installer checks the installed directory against zsh's actual fpath and, when it is not
# there, prints the one line for ~/.zshrc instead of leaving a completion that does nothing. (The file
# is installed 0644 because compinit refuses a completion that group or others can write.)
#
# A note on profiles, since this is the one surprise after installing: `wgb up` writes the client
# profiles (key material) into ./out under the directory you run it from, not under the prefix.
# Run it from where you keep engagement data, or set WGB_OUT_BASE to an absolute path.
#
# Exit codes: 0 ok, 1 failure, 2 usage error - the same contract as wgb itself.

# Backticks appear as literal text in messages printed for the operator; they are never meant to be
# command substitution. (Same reasoning as wgb's own header.)
# shellcheck disable=SC2016

# Strictness applies only when this file is executed. Sourced (by the test suite) it must not modify
# the caller's shell options - the same rule wgb's own header states, and for the same reason: the
# test harness relies on commands being allowed to fail so it can assert on the failure.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
fi

PROG="${0##*/}"

PREFIX=/usr/local
BINDIR=""
DESTDIR=""
LINK=0
WANT_COMPLETION=1
WANT_DOCS=1
UNINSTALL=0
DRY_RUN=0
FORCE=0
EXPLICIT_PREFIX=0

# A copy of wgb contains this line; anything else at <bindir>/wgb is somebody else's file and is not
# ours to overwrite or delete.
MARKER='bring up a WireGuard tunnel that drives'

log()  { printf '%s: %s\n' "$PROG" "$*"; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
# Same contract as wgb: a bad invocation is exit 2, and the usage text goes to stderr with it.
usage_die() { printf '%s: %s\n' "$PROG" "$*" >&2; usage >&2; exit 2; }

usage() {
  cat <<'EOF'
install wgb - WireGuard tunnel that drives a client's traffic through Burp Suite.

USAGE
  sudo ./install.sh [options]      install (default prefix /usr/local)
       ./install.sh --dry-run      print the plan, change nothing
  sudo ./install.sh --uninstall    remove exactly what a previous install recorded

OPTIONS
  --prefix DIR      install root                    (default /usr/local, or /usr/bin if sudo
                                                    cannot see /usr/local/bin - see below)
  --bindir DIR      directory for the tool          (default <prefix>/bin)
  --destdir DIR     stage everything under DIR      (packaging; no root needed)
  --link            symlink to this checkout instead of copying (development only)
  --no-completion   do not install the bash and zsh completions
  --no-doc          do not install README.md and LICENSE
  --uninstall       remove what the manifest lists, then exit
  --force           overwrite a <bindir>/wgb this installer did not put there
  --dry-run         print the plan, change nothing
  -h, --help        this text

Exit codes: 0 ok, 1 failure, 2 usage error.
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --prefix)        [[ $# -ge 2 ]] || usage_die "--prefix needs a directory"
                       PREFIX="$2"; EXPLICIT_PREFIX=1; shift 2 ;;
      --bindir)        [[ $# -ge 2 ]] || usage_die "--bindir needs a directory"
                       BINDIR="$2"; EXPLICIT_PREFIX=1; shift 2 ;;
      --destdir)       [[ $# -ge 2 ]] || usage_die "--destdir needs a directory"
                       DESTDIR="$2"; shift 2 ;;
      --link)          LINK=1; shift ;;
      --no-completion) WANT_COMPLETION=0; shift ;;
      --no-doc)        WANT_DOCS=0; shift ;;
      --uninstall)     UNINSTALL=1; shift ;;
      --force)         FORCE=1; shift ;;
      --dry-run)       DRY_RUN=1; shift ;;
      -h|--help)       usage; exit 0 ;;
      *)               usage_die "unknown option: $1" ;;
    esac
  done

  # Absolute paths only: a relative prefix would make the manifest and every recorded path depend on
  # the directory the installer happened to run from, and --uninstall would then be unusable from
  # anywhere else.
  case "$PREFIX" in /*) ;; *) usage_die "--prefix must be an absolute path (got: $PREFIX)" ;; esac
  case "$DESTDIR" in ""|/*) ;; *) usage_die "--destdir must be an absolute path (got: $DESTDIR)" ;; esac
  [[ -n "$BINDIR" ]] || BINDIR="$PREFIX/bin"

  # The staging root is a prefix in front of everything, so an absolute prefix inside it stays
  # absolute - that is what makes `--destdir /tmp/stage --prefix /usr/local` land in
  # /tmp/stage/usr/local/... exactly as packaging expects.
  ROOT="${DESTDIR%/}"
  set_prefix_paths "$PREFIX" "$BINDIR"
}

# Every directory an install touches, derived from the prefix. Used by the argument parser, by the
# sudo-reachability switch and by the uninstall search - one place, so a prefix decided late cannot
# leave any of the four pointing at the old one (it did: pruning then ran against /usr/local while the
# files were under /usr, and left empty directories behind).
set_prefix_paths() { # <prefix> [bindir]
  local p="${1%/}"
  BINDIR="${2:-$p/bin}"
  BINDIR="$ROOT${BINDIR}"
  COMPDIR="$ROOT$p/share/bash-completion/completions"
  ZSHDIR="$ROOT$p/share/zsh/site-functions"
  DOCDIR="$ROOT$p/share/doc/wgb"
  LIBDIR="$ROOT$p/share/wgb"
  MANIFEST="$LIBDIR/install-manifest"
}

# The directory the script lives in, so `install.sh` works no matter where it is called from.
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SRC_DIR/wgb"
SRC_COMPLETION="$SRC_DIR/completions/wgb.bash"
SRC_ZSH_COMPLETION="$SRC_DIR/completions/_wgb"
SRC_VERSION=""
ROOT=""
BINDIR=""
COMPDIR=""
ZSHDIR=""
DOCDIR=""
LIBDIR=""
MANIFEST=""

check_source() {
  [[ -f "$SRC" ]] || die "no wgb next to this script ($SRC) - run install.sh from a checkout"
  grep -q "$MARKER" "$SRC" || die "$SRC does not look like wgb"
  SRC_VERSION="$(sed -n 's/^WGB_VERSION="\(.*\)"$/\1/p' "$SRC" | head -1)"
  [[ -n "$SRC_VERSION" ]] || die "$SRC has no WGB_VERSION line - refusing to install an unknown build"

  bash -n "$SRC" || die "$SRC does not parse (bash -n)"

  if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -x "$SRC" >/dev/null 2>&1; then
      log "lint: shellcheck clean"
    else
      warn "shellcheck reports findings in $SRC - installing anyway, but look at shellcheck -x wgb"
    fi
  else
    warn "shellcheck is not installed, so the source was only syntax-checked"
  fi
}

# Whether writing to the target tree needs root. Any ancestor that exists decides it, so a prefix
# under a user-writable directory (--prefix ~/.local) installs without root.
needs_root() {
  local d p
  for d in "$BINDIR" "$COMPDIR" "$ZSHDIR" "$DOCDIR" "$LIBDIR"; do
    p="$d"
    while [[ ! -e "$p" && "$p" != / ]]; do p="$(dirname "$p")"; done
    [[ -w "$p" ]] || return 0
  done
  return 1
}

# Write a file the way wgb writes its own configs: a temporary file in the target directory, then a
# rename over the destination. A reader (including sudo about to execute it) either sees the old file
# or the new one, never a half-written one.
install_file() { # <src> <dest> <mode>
  local src="$1" dest="$2" mode="$3" tmp
  mkdir -p "$(dirname "$dest")"
  tmp="$(dirname "$dest")/.$(basename "$dest").new.$$"
  cp -f "$src" "$tmp"
  chmod "$mode" "$tmp"
  if [[ -z "$DESTDIR" && $EUID -eq 0 ]]; then
    # The primary group of root is named wheel on macOS.
    chown 0:0 "$tmp"
  fi
  mv -f "$tmp" "$dest"
  path_record "$dest"
}

path_record() { # <path>
  [[ -n "$MANIFEST" ]] || return 0
  printf 'path %s\n' "$1" >>"$MANIFEST"
}

looks_like_wgb() { # <path>
  [[ -e "$1" ]] || return 1
  grep -q "$MARKER" "$1" 2>/dev/null
}

path_in_list() { # <dir> <colon-separated path list>
  local dir="${1%/}" list="$2"
  [[ ":$list:" == *":$dir:"* ]]
}

# Where sudo looks for commands: secure_path, not your PATH. Every privileged verb is run through
# sudo, so a bin directory sudo cannot see makes the tool unusable as `sudo wgb` - the failure this
# whole check exists to prevent. The last definition wins: /etc/sudoers, then sudoers.d in sorted
# order, which is the order sudo itself parses them in. WGB_INSTALL_SUDOERS lets the test suite point
# this at a fixture instead of the real file.
detect_sudo_path() {
  local main="${WGB_INSTALL_SUDOERS:-/etc/sudoers}" f v last=""
  [[ -r "$main" ]] || return 1
  last="$(secure_path_from_file "$main")"
  if [[ -d "$(dirname "$main")/sudoers.d" ]]; then
    for f in "$(dirname "$main")/sudoers.d"/*; do
      [[ -f "$f" && -r "$f" ]] || continue
      v="$(secure_path_from_file "$f")"
      if [[ -n "$v" ]]; then
        last="$v"
      fi
    done
  fi
  last="${last#*=}"                     # drop '=' and anything before it
  last="${last%%#*}"                    # drop a trailing comment
  last="${last//[[:space:]]/}"          # drop spaces
  last="${last%\"}"; last="${last#\"}"  # drop the quotes
  [[ -n "$last" ]] || return 1
  printf '%s\n' "$last"
}

# The last secure_path value in one sudoers file, unparsed (empty when the file does not set it).
secure_path_from_file() { # <file>
  local line last=""
  [[ -r "$1" ]] || return 0
  while IFS= read -r line; do
    case "$line" in
      \#*) continue ;;
      *secure_path*) last="${line#*secure_path}" ;;
    esac
  done <"$1"
  printf '%s' "$last"
}

# Choose where the tool goes, given that sudo - not your shell - decides what `wgb` means when it is
# run privileged. An explicit --prefix/--bindir is always honoured, with a warning.
resolve_sudo_reachability() {
  [[ -z "$DESTDIR" ]] || return 0 # packaging: the staged files are not run from here
  if [[ "$(uname -s)" == Darwin ]]; then
    log "macOS: leaving the local prefix unchanged; see docs/macos.md for sudo PATH requirements"
    return 0
  fi
  local sudo_path alt
  if ! sudo_path="$(detect_sudo_path)"; then
    log "could not read sudo's PATH here: if \`sudo wgb\` says command not found, install with --prefix /usr/bin"
    return 0
  fi
  if path_in_list "$BINDIR" "$sudo_path"; then
    return 0
  fi
  if (( EXPLICIT_PREFIX )); then
    warn "$BINDIR is not in sudo's PATH ($sudo_path), so \`sudo wgb\` will not resolve"
    warn "  add $BINDIR to secure_path in /etc/sudoers, or install with --prefix /usr/bin"
    return 0
  fi
  for alt in /usr/bin /bin; do
    if path_in_list "$alt" "$sudo_path"; then
      log "$BINDIR is not in sudo's PATH ($sudo_path), so \`sudo wgb\` would not resolve"
      log "installing to $alt instead - override with --prefix DIR or --bindir DIR"
      BINDIR="$alt"
      PREFIX="$(dirname "$alt")" # the docs and completion follow the tool
      set_prefix_paths "$PREFIX"
      return 0
    fi
  done
  warn "nothing in sudo's PATH ($sudo_path) can hold the tool; installing to $BINDIR"
  warn "  run it as \`sudo $BINDIR/wgb\` rather than \`sudo wgb\`"
  return 0
}

installed_version() { # <path>
  sed -n 's/^WGB_VERSION="\(.*\)"$/\1/p' "$1" 2>/dev/null | head -1
}

write_manifest() {
  local tmp
  mkdir -p "$(dirname "$MANIFEST")"
  tmp="$(dirname "$MANIFEST")/.$(basename "$MANIFEST").new.$$"
  {
    printf '# written by install.sh; read by install.sh --uninstall - do not edit\n'
    printf 'version %s\n' "$SRC_VERSION"
    printf 'source %s\n' "$SRC"
    printf 'prefix %s\n' "$ROOT$PREFIX"
    printf 'bindir %s\n' "$BINDIR"
    printf 'link %s\n' "$LINK"
  } >"$tmp"
  mv -f "$tmp" "$MANIFEST"
}

do_install() {
  resolve_sudo_reachability

  local dest="$BINDIR/wgb"

  if needs_root; then
    (( EUID == 0 )) || die "installing to $ROOT$PREFIX needs root: re-run as  sudo ./$PROG"
  fi

  if [[ -e "$dest" ]]; then
    if looks_like_wgb "$dest"; then
      log "upgrading $dest (replacing wgb $(installed_version "$dest"))"
      if [[ "$LINK" -eq 0 && -z "$DESTDIR" ]] && cmp -s "$SRC" "$dest"; then
        log "already identical to this checkout - reinstalling anyway"
      fi
    elif (( FORCE )); then
      warn "overwriting $dest, which does not look like wgb (--force)"
    else
      die "refusing to overwrite $dest: it is not a wgb install. Move it away, or pass --force"
    fi
  fi

  if (( DRY_RUN )); then
    log "plan (nothing below is executed):"
    printf '  install -m 0755 %s -> %s\n' "$SRC" "$dest"
    if (( WANT_COMPLETION )); then
      printf '  install -m 0644 %s -> %s\n' "$SRC_COMPLETION" "$COMPDIR/wgb"
      printf '  install -m 0644 %s -> %s\n' "$SRC_ZSH_COMPLETION" "$ZSHDIR/_wgb"
    fi
    if (( WANT_DOCS )); then
      printf '  install -m 0644 %s -> %s\n' "$SRC_DIR/README.md" "$DOCDIR/README.md"
      printf '  install -m 0644 %s -> %s\n' "$SRC_DIR/LICENSE" "$DOCDIR/LICENSE"
      printf '  install -m 0644 %s -> %s\n' "$SRC_DIR/docs/troubleshooting.md" "$DOCDIR/troubleshooting.md"
    fi
    printf '  write manifest -> %s\n' "$MANIFEST"
    if (( LINK )); then
      printf '  (as a SYMLINK to %s, not a copy)\n' "$SRC"
    fi
    if [[ -n "$DESTDIR" ]]; then
      printf '  staged under DESTDIR=%s - nothing outside it is touched\n' "$DESTDIR"
    fi
    return 0
  fi

  # Keep the previous manifest aside, then write a fresh one and append to it as paths land. An
  # install that dies part-way therefore still leaves a record: of the attempt if there was no
  # previous manifest, or of the working install it was upgrading if there was.
  if [[ -e "$MANIFEST" ]]; then
    cp -f "$MANIFEST" "$MANIFEST.previous" 2>/dev/null || true
  fi
  mkdir -p "$LIBDIR"
  : >"$MANIFEST" 2>/dev/null || true
  write_manifest

  if (( LINK )); then
    local tmp="$BINDIR/.wgb.link.$$"
    mkdir -p "$BINDIR"
    ln -sfn "$SRC" "$tmp"
    mv -f "$tmp" "$dest"
    path_record "$dest"
    warn "$dest is a symlink to $SRC"
    warn "  anything that can write that file (your user, a git pull, an editor) decides what"
    warn "  root executes next. Use it for development, install a copy for real engagements."
  else
    install_file "$SRC" "$dest" 0755
  fi

  if (( WANT_COMPLETION )); then
    if [[ -f "$SRC_COMPLETION" ]]; then
      install_file "$SRC_COMPLETION" "$COMPDIR/wgb" 0644
    else
      warn "no $SRC_COMPLETION in this checkout - skipping the bash completion"
    fi
    # 0644 matters: zsh's compinit refuses a completion file that is writable by group or others.
    if [[ -f "$SRC_ZSH_COMPLETION" ]]; then
      install_file "$SRC_ZSH_COMPLETION" "$ZSHDIR/_wgb" 0644
    else
      warn "no $SRC_ZSH_COMPLETION in this checkout - skipping the zsh completion"
    fi
  fi

  if (( WANT_DOCS )); then
    [[ -f "$SRC_DIR/README.md" ]] && install_file "$SRC_DIR/README.md" "$DOCDIR/README.md" 0644
    [[ -f "$SRC_DIR/LICENSE" ]] && install_file "$SRC_DIR/LICENSE" "$DOCDIR/LICENSE" 0644
    [[ -f "$SRC_DIR/docs/troubleshooting.md" ]] &&
      install_file "$SRC_DIR/docs/troubleshooting.md" "$DOCDIR/troubleshooting.md" 0644
  fi

  # Prove the installed thing actually runs, rather than trusting that the copy worked.
  if [[ -x "$dest" ]]; then
    local v
    if ! v="$("$dest" version 2>&1)"; then
      die "$dest was installed but does not run: $v"
    fi
    log "installed wgb $SRC_VERSION at $dest ($v)"
  fi

  report_shadowing
  if (( WANT_COMPLETION )); then
    report_zsh_fpath
  fi
}

# zsh only loads a completion from a directory on its fpath, and the sites differ: on Debian
# /usr/local/share/zsh/site-functions is on the default fpath while /usr/share/zsh/site-functions is
# not, so a /usr install puts a working file where zsh will never look. Say so, with the one line that
# fixes it, rather than leaving a completion that silently does nothing.
report_zsh_fpath() {
  [[ -z "$DESTDIR" ]] || return 0
  command -v zsh >/dev/null 2>&1 || return 0
  local zdir="$ZSHDIR"
  if zsh -fc "print -l \$fpath" 2>/dev/null | grep -qx "$zdir"; then
    log "zsh: $zdir is on zsh's fpath - the completion is active"
  else
    warn "zsh: $zdir is not on zsh's fpath, so tab completion will not load"
    warn "  add this to ~/.zshrc BEFORE compinit runs:"
    warn "    fpath=($zdir \$fpath)"
  fi
}

report_shadowing() {
  [[ -z "$DESTDIR" ]] || return 0
  local found
  found="$(type -a wgb 2>/dev/null | sed 's/^/    /' || true)"
  [[ -n "$found" ]] || { log "no other wgb earlier in PATH"; return 0; }
  printf '%s: what `wgb` resolves to now, in order:\n%s\n' "$PROG" "$found" >&2
  if (( LINK == 0 )); then
    printf '%s: if an older copy sits above this one, remove it and run: hash -r\n' "$PROG" >&2
  fi
}

# The prefixes an install could have gone to, WITHOUT the staging root: the caller adds that, and so
# does set_prefix_paths. Passing a stamped candidate to set_prefix_paths is how the pruning ended up
# doubly-rooted and pointing at nothing.
manifest_candidates() {
  local p full seen=" "
  for p in "$PREFIX" /usr/local /usr /; do
    full="${p%/}"
    [[ -n "$full" ]] || full="/"
    case "$seen" in *" $full "*) continue ;; esac
    seen="$seen$full "
    printf '%s\n' "$full"
  done
}

do_uninstall() {
  # Find the manifest: the recorded prefix, then the other prefixes this installer can use.
  #
  # The fallback is deliberately limited. Walking into /usr or /usr/local on behalf of a caller who
  # cannot write there would let anyone's "uninstall" reach a system-wide install they never made -
  # so it is only done by root, or inside a --destdir staging root where the paths are the caller's
  # own. A non-root caller without --destdir gets its own prefix and nothing else.
  if [[ ! -e "$MANIFEST" ]] && { [[ -n "$ROOT" ]] || (( EUID == 0 )); }; then
    local cand full
    while IFS= read -r cand; do
      full="$ROOT$cand"
      if [[ -e "$full/share/wgb/install-manifest" ]]; then
        log "no manifest under the default prefix; using the one under $cand"
        set_prefix_paths "$cand" # bare prefix: this is what makes the pruning hit the same tree
        MANIFEST="$full/share/wgb/install-manifest"
        break
      fi
      if [[ -e "$full/share/wgb/install-manifest.previous" ]]; then
        log "no manifest under the default prefix; using $cand/share/wgb/install-manifest.previous"
        set_prefix_paths "$cand"
        MANIFEST="$full/share/wgb/install-manifest.previous"
        break
      fi
    done < <(manifest_candidates)
  fi
  if [[ ! -e "$MANIFEST" && -e "$MANIFEST.previous" ]]; then
    log "no manifest at $MANIFEST; using $MANIFEST.previous (an install was interrupted)"
    MANIFEST="$MANIFEST.previous"
  fi
  [[ -e "$MANIFEST" ]] || die "no manifest under $ROOT$PREFIX (or /usr, /usr/local) - nothing installed here to remove"
  local declared_prefix declared_bindir version p removed=0 kept=0
  declared_prefix="$(sed -n 's/^prefix \(.*\)$/\1/p' "$MANIFEST" | head -1)"
  declared_bindir="$(sed -n 's/^bindir \(.*\)$/\1/p' "$MANIFEST" | head -1)"
  version="$(sed -n 's/^version \(.*\)$/\1/p' "$MANIFEST" | head -1)"
  log "removing wgb ${version:-unknown} installed under ${declared_prefix:-unknown}"

  # Only paths the manifest records, only files, and only under the prefix it claims. A manifest that
  # has been edited to point somewhere else removes nothing.
  while IFS= read -r p; do
    case "$p" in
      'path '*) p="${p#path }" ;;
      *) continue ;; # header and metadata lines (version, source, prefix, ...) are not paths
    esac
    [[ -n "$p" ]] || continue
    if [[ -n "$declared_prefix" && "$p" != "$declared_prefix"/* ]] &&
       [[ -z "$declared_bindir" || "$p" != "$declared_bindir"/* ]]; then
      warn "skipping $p: outside the recorded prefix $declared_prefix"
      kept=$((kept + 1))
      continue
    fi
    if [[ ! -e "$p" && ! -L "$p" ]]; then
      continue
    fi
    if [[ ! -f "$p" && ! -L "$p" ]]; then
      warn "skipping $p: not a regular file"
      kept=$((kept + 1))
      continue
    fi
    if [[ ! -L "$p" ]]; then
      case "$p" in
        */wgb|*/_wgb|*.md|*/LICENSE) ;; # ours by contract: the tool, the completions, the docs
        *)
          if ! looks_like_wgb "$p"; then
            warn "skipping $p: does not look like something this installer wrote"
            kept=$((kept + 1))
            continue
          fi
          ;;
      esac
    fi
    if (( DRY_RUN )); then
      log "would remove $p"
    else
      rm -f "$p"
      log "removed $p"
    fi
    removed=$((removed + 1))
  done <"$MANIFEST"

  if (( DRY_RUN )); then
    log "would remove $MANIFEST"
  else
    rm -f "$MANIFEST" "$LIBDIR/install-manifest" "$LIBDIR/install-manifest.previous"
    # Prune only the directories this installer created, and only while they are empty, so a shared
    # /usr/local/share never loses anything a package manager or another tool owns.
    local d
    for d in "$LIBDIR" "$DOCDIR" "$COMPDIR" "$ZSHDIR"; do
      rmdir "$d" 2>/dev/null || true
    done
    log "removed the manifest; $removed file(s) removed, $kept kept"
    log "run 'hash -r' in any shell that still has the old path cached"
  fi
}

main() {
  parse_args "$@"
  check_source
  if (( UNINSTALL )); then
    do_uninstall
  else
    do_install
  fi
}

# Strictness and execution apply only when this file is run. Sourced (by the test suite) it just
# defines its functions, which is how the tests check the parsing helpers directly. Same pattern as
# wgb itself.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
