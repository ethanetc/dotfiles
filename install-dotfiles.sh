#!/usr/bin/env bash
# =============================================================================
#  install-dotfiles.sh - installer for the "etc" dotfiles
#
#  Rebuilds the desktop from the screenshots (clean / busy / busy2 / firefox):
#    Arch · i3 · polybar · termite · rofi · dunst · zsh+zplug · tmux · vim/emacs
#    mopidy + ncmpcpp · cava · vtop · Firefox + userChrome + startpage
#
#  Source of the dotfiles (first match wins):
#    1. an existing ~/etc checkout
#    2. a snapshot zip next to this script (dotfiles-<sha>.zip) or $DOTFILES_ZIP
#    3. $REPO_URL (a real dotfiles repo, or a repo that contains the snapshot zip)
#    4. upstream roosta/etc (last resort - NOT your snapshot)
#
#  Usage:  bash install-dotfiles.sh [--skip-packages] [--skip-plugins]
#                                   [--skip-services] [-h|--help]
#
#  Environment overrides:
#    PROFILE=lintilla|allitnil|garkbit   machine profile under local/ (default: the
#                                        host's own, else lintilla = your screenshots)
#    DOTFILES_ZIP=/path/to/snapshot.zip  REPO_URL=https://github.com/you/repo.git
#    GIT_NAME / GIT_EMAIL                identity for ~/.gitconfig.local
#    REWRITE_HOME_PATHS=0                keep the literal /home/roosta paths
#    USER_SERVICES="a.service b.socket"  user units to enable ("" = none)
#    SYSTEM_SERVICES="NetworkManager"    system units to enable (default: none)
#    SKIP_PKGS="pkg1 pkg2"               extra packages to skip
#
#  Safe to re-run. Non-fatal problems are collected and printed at the end.
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
ETC_DIR="${HOME}/etc"   # fixed: the Makefile hardcodes ~/etc
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NOW="$(date +%Y-%m-%dT%T)"
BACKUP_DIR="${HOME}/backup/original-system-files@${NOW}"

REPO_URL_GIVEN="${REPO_URL:+1}"
REPO_URL="${REPO_URL:-https://github.com/ethanetc/dotfiles.git}"
UPSTREAM_REPO_URL="https://github.com/roosta/etc.git"
SCRIPTS_URL="https://github.com/roosta/scripts.git"
DOTFILES_ZIP="${DOTFILES_ZIP:-}"
PROFILE="${PROFILE:-}"
REWRITE_HOME_PATHS="${REWRITE_HOME_PATHS:-1}"
USER_SERVICES="${USER_SERVICES-mopidy-user.service gpg-agent-ssh.socket}"
SYSTEM_SERVICES="${SYSTEM_SERVICES:-}"
SKIP_PKGS="${SKIP_PKGS:-}"

# Same ignore pattern as the Makefile's link-conf rule.
STOW_IGNORE='md|org|firefox'

DO_PACKAGES=1
DO_PLUGINS=1
DO_SERVICES=1

# Referenced by your configs but missing from pacman_packages.txt:
#   rustup (first: it provides cargo/rust)  ruby (.zshenv)  fzf (zsh/vim/tmux)
#   rofi (i3 bindings)  picom (.xinitrc)  Symbols Nerd Font / Font Awesome (polybar)
EXTRA_PACMAN=(rustup ruby fzf rofi picom ttf-nerd-fonts-symbols ttf-font-awesome)

# Packages that cannot / must not be installed, with the reason.
declare -A SKIP_PKG=(
  [jdk7-openjdk]="end-of-life, no longer buildable"
  [cargo]="provided by rustup (rust and rustup conflict)"
  [compton]="replaced by picom (your .xinitrc starts picom)"
  [universal-ctags-git]="repo 'ctags' is already universal-ctags (they conflict)"
  [joker-bin]="duplicate of 'joker' (they conflict)"
)
# Old name -> current name, used only when the old name is gone from the repos.
declare -A RENAMED_PKG=( [qemu]=qemu-desktop [mlocate]=plocate )

# Repos your configs load from ~/src and ~/lib but that the *_repositories.txt
# lists don't contain (each one checked to exist):
EXTRA_SRC_REPOS=(
  https://github.com/srcery-colors/srcery-gui     # rofi theme (templates/rofi)
  https://github.com/roosta/fif                   # zplug "~/src/fif"
  https://github.com/roosta/foldlist              # vim: Plug '~/src/foldlist'
  https://github.com/roosta/tmux-fuzzback         # tmux.conf run-shell
  https://github.com/roosta/cljr-ivy              # emacs: :load-path
  https://github.com/roosta/startpage             # the Firefox start page
)
EXTRA_LIB_REPOS=(
  https://github.com/Jvanrhijn/polybar-spotify    # polybar [module/spotify]
)

WARNINGS=()
FAILED_PKGS=()
AUR_QUEUE=()
GIT_PREV_NAME="" GIT_PREV_EMAIL="" GIT_PREV_KEY="" GIT_PREV_SIGN=""
SUDO_KEEPALIVE_PID=""

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_Y=$'\033[0;33m'; C_G=$'\033[1;32m'; C_R=$'\033[0;31m'; C_C=$'\033[0;36m'; C_N=$'\033[0m'
else
  C_Y=''; C_G=''; C_R=''; C_C=''; C_N=''
fi
log()  { printf '%s==> %s%s\n' "$C_Y" "$*" "$C_N"; }
ok()   { printf '%s✔  %s%s\n'  "$C_G" "$*" "$C_N"; }
info() { printf '%s·  %s%s\n'  "$C_C" "$*" "$C_N"; }
warn() { printf '%s!  %s%s\n'  "$C_Y" "$*" "$C_N" >&2; WARNINGS+=("$*"); }
err()  { printf '%s✖  %s%s\n'  "$C_R" "$*" "$C_N" >&2; }
die()  { err "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Print the entries of a package/repo list: comments and blanks removed, de-duplicated.
read_list() {
  [[ -f $1 ]] || return 0
  sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$1" | awk 'NF && !seen[$0]++'
}

start_sudo_keepalive() {
  sudo -v || die "sudo authentication failed"
  (
    while true; do
      sudo -n true 2>/dev/null
      sleep 50
      kill -0 "$$" 2>/dev/null || exit 0
    done
  ) &
  SUDO_KEEPALIVE_PID=$!
}
cleanup() {
  [[ -n $SUDO_KEEPALIVE_PID ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT

usage() {
  sed -n '2,/^# ====.*$/{/^# ====/q;s/^# \{0,2\}//;p}' "${BASH_SOURCE[0]}" | sed '1d'
}

parse_args() {
  while (($#)); do
    case "$1" in
      --skip-packages) DO_PACKAGES=0 ;;
      --skip-plugins)  DO_PLUGINS=0 ;;
      --skip-services) DO_SERVICES=0 ;;
      -h|--help)       usage; exit 0 ;;
      *)               die "Unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

# -----------------------------------------------------------------------------
# 0. Pre-flight
# -----------------------------------------------------------------------------
preflight() {
  [[ $EUID -ne 0 ]] || die "Run as a normal user with sudo rights, not as root."

  local -a missing=()
  local t
  for t in git stow unzip curl make; do have "$t" || missing+=("$t"); done

  if ((DO_PACKAGES)); then
    have pacman || die "Installing packages needs Arch Linux (pacman). Use --skip-packages to only link the configs."
    have sudo   || die "sudo is required."
    start_sudo_keepalive
    log "Upgrading the system and installing base tooling (a partial upgrade is unsafe on Arch)..."
    sudo pacman -Syu --needed --noconfirm base-devel git stow unzip curl \
      || warn "pacman -Syu failed; continuing with what is already installed"
  elif ((${#missing[@]})); then
    if have pacman && have sudo; then
      sudo pacman -S --needed --noconfirm "${missing[@]}" || true
    fi
  fi

  for t in git stow unzip curl make; do
    have "$t" || die "Required tool missing: $t"
  done
  ok "Pre-flight checks passed"
}

# -----------------------------------------------------------------------------
# 1. Get the dotfiles into ~/etc
# -----------------------------------------------------------------------------
first_zip_in() {
  local f
  for f in "$1"/dotfiles-*.zip "$1"/etc-*.zip; do
    if [[ -f $f ]]; then printf '%s' "$f"; return 0; fi
  done
  return 0
}

find_local_zip() {
  if [[ -n $DOTFILES_ZIP ]]; then printf '%s' "$DOTFILES_ZIP"; return 0; fi
  local d z
  for d in "$SELF_DIR" "$PWD"; do
    z="$(first_zip_in "$d")"
    if [[ -n $z ]]; then printf '%s' "$z"; return 0; fi
  done
  return 0
}

init_git_repo() {
  # ~/etc from a zip has no history; ftl and your daily workflow expect a repo.
  (
    cd "$ETC_DIR" && git init -q && git add -A &&
    git -c user.name="dotfiles installer" -c user.email="installer@localhost" \
        -c commit.gpgsign=false commit -q -m "Import dotfiles snapshot"
  ) >/dev/null 2>&1 \
    && info "Initialised a git repo in ~/etc (the installer's own edits will show in 'git diff')" \
    || warn "Could not initialise a git repo in ~/etc (non-fatal)"
}

extract_zip() {
  local zip=$1 tmp top
  log "Extracting $(basename -- "$zip") into ${ETC_DIR}"
  tmp="$(mktemp -d)"
  unzip -q "$zip" -d "$tmp" || { rm -rf "$tmp"; die "Could not unzip $zip"; }
  if [[ -f $tmp/Makefile ]]; then
    top="$tmp"
  else
    top="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  fi
  if [[ -z $top || ! -f $top/Makefile || ! -d $top/conf ]]; then
    rm -rf "$tmp"; die "$zip does not contain the dotfiles tree (no Makefile/conf)"
  fi
  rmdir "$ETC_DIR" 2>/dev/null || true
  mv "$top" "$ETC_DIR" || { rm -rf "$tmp"; die "Could not move the dotfiles to $ETC_DIR"; }
  rm -rf "$tmp"
  find "$ETC_DIR/scripts" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
  init_git_repo
  ok "Dotfiles ready at ${ETC_DIR}"
}

fetch_from_remote() {
  local tmp z
  tmp="$(mktemp -d)"
  log "No local snapshot found; cloning ${REPO_URL}"
  if GIT_TERMINAL_PROMPT=0 git clone --quiet "$REPO_URL" "$tmp/repo"; then
    if [[ -f $tmp/repo/Makefile && -d $tmp/repo/conf ]]; then
      mv "$tmp/repo" "$ETC_DIR"; rm -rf "$tmp"
      ok "Cloned dotfiles into ${ETC_DIR}"; return 0
    fi
    z="$(first_zip_in "$tmp/repo")"
    if [[ -n $z ]]; then
      extract_zip "$z"; rm -rf "$tmp"; return 0
    fi
    warn "${REPO_URL} has neither a dotfiles tree nor a snapshot zip"
  else
    warn "Could not clone ${REPO_URL}"
  fi
  rm -rf "$tmp"
  warn "Falling back to upstream ${UPSTREAM_REPO_URL} - this is NOT your uploaded snapshot"
  GIT_TERMINAL_PROMPT=0 git clone --quiet "$UPSTREAM_REPO_URL" "$ETC_DIR" \
    || die "Could not obtain any dotfiles source"
}

fetch_dotfiles() {
  log "Locating the dotfiles..."
  if [[ -f $ETC_DIR/Makefile && -d $ETC_DIR/conf ]]; then
    ok "Using the existing dotfiles in ${ETC_DIR}"
    if [[ -d $ETC_DIR/.git ]]; then
      git -C "$ETC_DIR" pull --rebase --autostash --quiet 2>/dev/null \
        || info "git pull skipped (no upstream configured, or offline)"
    fi
    return 0
  fi
  if [[ -e $ETC_DIR ]] && [[ -n "$(ls -A "$ETC_DIR" 2>/dev/null)" ]]; then
    die "${ETC_DIR} exists but is not the dotfiles tree (no Makefile/conf). Move it away and re-run."
  fi
  if [[ -n $DOTFILES_ZIP && ! -f $DOTFILES_ZIP ]]; then
    die "DOTFILES_ZIP=${DOTFILES_ZIP} does not exist"
  fi

  local zip=""
  if [[ -z $REPO_URL_GIVEN || -n $DOTFILES_ZIP ]]; then zip="$(find_local_zip)"; fi
  if [[ -n $zip ]]; then extract_zip "$zip"; else fetch_from_remote; fi
}

# Pick the machine profile (local/<name>): own hostname if it has one, else lintilla.
resolve_profile() {
  local host="${HOSTNAME:-}"
  [[ -n $host ]] || host="$(uname -n 2>/dev/null || true)"
  host="${host%%.*}"
  if [[ -z $PROFILE ]]; then
    if [[ -d $ETC_DIR/local/$host ]]; then
      PROFILE="$host"
    else
      PROFILE="lintilla"
      warn "No local/${host} profile in the repo - using 'lintilla' (the machine in your screenshots: 3 monitors, 4K primary, DPI 192). Pick another with PROFILE=allitnil|garkbit."
    fi
  fi
  [[ -f $ETC_DIR/local/$PROFILE/variables.mk ]] \
    || die "Profile '${PROFILE}' not found in ${ETC_DIR}/local"
  ok "Machine profile: ${PROFILE}"
}

# The repo hardcodes /home/roosta in a few files (xrandr layout, lock-screen image, ...).
rewrite_home_paths() {
  [[ $REWRITE_HOME_PATHS == 1 && $HOME != /home/roosta ]] || return 0
  local -a files=()
  mapfile -t files < <(grep -rlI --exclude-dir=.git --exclude='*.md' '/home/roosta' "$ETC_DIR" 2>/dev/null)
  ((${#files[@]})) || return 0
  local repl
  repl="$(printf '%s' "$HOME" | sed -e 's/[\\|&]/\\&/g')"
  sed -i "s|/home/roosta|${repl}|g" "${files[@]}"
  ok "Rewrote /home/roosta -> ${HOME} in ${#files[@]} files (see 'git -C ~/etc diff')"
}

# -----------------------------------------------------------------------------
# 2. User filesystem layout (the Makefile's user-fs rule)
# -----------------------------------------------------------------------------
create_user_fs() {
  log "Creating the user filesystem layout..."
  local d
  for d in src lib mnt tmp bin sbin var/log var/vim/undo var/emacs/undo var/emacs/backup \
           .cache/zsh backup .local/share .config .config/systemd/user \
           .mozilla/firefox/roosta backgrounds; do
    mkdir -p "${HOME}/${d}"
  done
  touch "${HOME}/.cache/zsh/dirs"
  mkdir -p "${ETC_DIR}/build"
  ok "Filesystem layout created"
}

# -----------------------------------------------------------------------------
# 3. Packages
# -----------------------------------------------------------------------------
repo_has()      { pacman -Si "$1" >/dev/null 2>&1 || [[ -n "$(pacman -Sg "$1" 2>/dev/null)" ]]; }
pkg_installed() { pacman -Qq "$1" >/dev/null 2>&1; }

is_skipped() {  # echoes the reason and returns 0 when the package must be skipped
  local p=$1 s
  if [[ -n ${SKIP_PKG[$p]:-} ]]; then printf '%s' "${SKIP_PKG[$p]}"; return 0; fi
  for s in $SKIP_PKGS; do
    if [[ $s == "$p" ]]; then printf 'listed in SKIP_PKGS'; return 0; fi
  done
  return 1
}

install_yay() {
  if have yay; then ok "yay already installed"; return 0; fi
  log "Building yay (AUR helper)..."
  mkdir -p "${ETC_DIR}/build"
  (
    cd "${ETC_DIR}/build" && rm -rf yay &&
    git clone --depth 1 https://aur.archlinux.org/yay.git &&
    cd yay && makepkg -si --noconfirm --needed
  ) || { warn "Could not build yay - AUR packages will be skipped"; return 1; }
  ok "yay installed"
}

install_pacman_packages() {
  local list="${ETC_DIR}/pacman_packages.txt" p reason
  if [[ ! -f $list ]]; then warn "pacman_packages.txt not found - skipping official packages"; return 0; fi
  log "Installing official packages (anything not in the repos falls back to the AUR)..."

  local -a requested=() official=()
  mapfile -t requested < <({ printf '%s\n' "${EXTRA_PACMAN[@]}"; read_list "$list"; } | awk 'NF && !seen[$0]++')

  for p in "${requested[@]}"; do
    if reason="$(is_skipped "$p")"; then info "skip ${p} - ${reason}"; continue; fi
    if [[ $p == pulseaudio* ]] && pkg_installed pipewire-pulse; then
      info "skip ${p} - pipewire-pulse is installed and conflicts"; continue
    fi
    if repo_has "$p"; then
      official+=("$p")
    elif [[ -n ${RENAMED_PKG[$p]:-} ]] && repo_has "${RENAMED_PKG[$p]}"; then
      info "${p} is now ${RENAMED_PKG[$p]}"; official+=("${RENAMED_PKG[$p]}")
    else
      AUR_QUEUE+=("$p")
    fi
  done

  if ((${#official[@]})); then
    info "${#official[@]} packages from the official repos"
    if ! sudo pacman -S --needed --noconfirm "${official[@]}"; then
      warn "Bulk pacman install failed (conflict or missing dependency) - retrying one by one"
      for p in "${official[@]}"; do
        sudo pacman -S --needed --noconfirm "$p" || FAILED_PKGS+=("$p")
      done
    fi
  fi
  ok "Official packages done"
}

install_aur_packages() {
  local -a queue=() todo=()
  local p reason
  mapfile -t queue < <({ printf '%s\n' "${AUR_QUEUE[@]}"; read_list "${ETC_DIR}/aur_packages.txt"; } | awk 'NF && !seen[$0]++')
  for p in "${queue[@]}"; do
    if reason="$(is_skipped "$p")"; then info "skip ${p} - ${reason}"; continue; fi
    todo+=("$p")
  done
  ((${#todo[@]})) || return 0

  if ! have yay; then
    warn "yay unavailable - AUR packages not installed: ${todo[*]}"
    FAILED_PKGS+=("${todo[@]}"); return 0
  fi
  log "Installing AUR packages (${#todo[@]})..."
  local -a flags=(-S --needed --noconfirm --answerclean None --answerdiff None --answeredit None)
  if ! yay "${flags[@]}" "${todo[@]}"; then
    warn "Bulk AUR install failed - retrying one by one"
    for p in "${todo[@]}"; do
      yay "${flags[@]}" "$p" || FAILED_PKGS+=("$p")
    done
  fi
  ok "AUR packages done"
}

# aliases.zsh uses `exa` (the Git column in your screenshot); Arch now ships eza.
ensure_exa() {
  have exa && return 0
  if repo_has exa; then
    sudo pacman -S --needed --noconfirm exa || true
  elif repo_has eza; then
    sudo pacman -S --needed --noconfirm eza || true
  fi
  if ! have exa && have eza; then
    ln -sfn "$(command -v eza)" "${HOME}/bin/exa"
    ok "exa is provided by eza (~/bin/exa)"
  fi
}

# -----------------------------------------------------------------------------
# 4. Repositories in ~/lib and ~/src
# -----------------------------------------------------------------------------
sync_repo() {  # sync_repo <url> <parent> [branch] [dirname]
  local url=$1 parent=$2 branch=${3:-} name=${4:-}
  if [[ -z $name ]]; then name="${url##*/}"; name="${name%.git}"; fi
  local dest="${parent}/${name}"
  if [[ -d $dest/.git ]]; then
    if git -C "$dest" pull --ff-only --quiet 2>/dev/null; then info "updated ${name}"
    else warn "could not update ${dest} (local changes or offline)"; fi
  elif [[ -e $dest ]]; then
    warn "${dest} exists and is not a git checkout - skipped"
  else
    local -a args=(clone --quiet)
    [[ -n $branch ]] && args+=(--branch "$branch" --single-branch)
    if GIT_TERMINAL_PROMPT=0 git "${args[@]}" "$url" "$dest"; then ok "cloned ${name}"
    else warn "could not clone ${url}"; fi
  fi
}

sync_list() {  # sync_list <parent> <listfile>   (git@github.com: -> https, no SSH key needed)
  local parent=$1 list=$2 url
  mkdir -p "$parent"
  while IFS= read -r url; do
    url="${url/#git@github.com:/https://github.com/}"
    sync_repo "$url" "$parent"
  done < <(read_list "$list")
}

sync_repositories() {
  log "Syncing ~/lib and ~/src..."
  local u
  sync_list "${HOME}/lib" "${ETC_DIR}/lib_repositories.txt"
  for u in "${EXTRA_LIB_REPOS[@]}"; do sync_repo "$u" "${HOME}/lib"; done
  sync_list "${HOME}/src" "${ETC_DIR}/src_repositories.txt"
  for u in "${EXTRA_SRC_REPOS[@]}"; do sync_repo "$u" "${HOME}/src"; done
}

# -----------------------------------------------------------------------------
# 5. Helper scripts: the polybar/i3 configs call scripts that were removed from the
#    scripts repo's main branch (they live on its `deprecated` branch), and the old
#    launcher had no case for the lintilla bars. Provide them without touching tracked files.
# -----------------------------------------------------------------------------
git_exclude() {  # git_exclude <repo> <path>
  local ex="$1/.git/info/exclude"
  [[ -d $1/.git ]] || return 0
  mkdir -p "$(dirname "$ex")"
  grep -qxF "$2" "$ex" 2>/dev/null || printf '%s\n' "$2" >> "$ex"
}

write_polybar_launcher() {
  local dest=$1
  cat > "$dest" <<'LAUNCHER'
#!/usr/bin/env sh
# Generated by install-dotfiles.sh.
# Starts the polybar bars from ~/.config/polybar/config for this machine's profile.
# A bar whose monitor is absent is skipped; the primary bar falls back to the
# primary (or first connected) output so you always get one.

killall -q polybar
while pgrep -x polybar >/dev/null 2>&1; do sleep 1; done

profile="${ETC_PROFILE:-}"
[ -z "$profile" ] && [ -r "$HOME/.config/etc-profile" ] && profile="$(cat "$HOME/.config/etc-profile")"
[ -z "$profile" ] && profile="$(hostname 2>/dev/null || uname -n)"

connected="$(xrandr --query 2>/dev/null | awk '/ connected/ {print $1}')"
fallback="$(xrandr --query 2>/dev/null | awk '/ connected primary/ {print $1; exit}')"
[ -z "$fallback" ] && fallback="$(printf '%s\n' "$connected" | head -n 1)"

is_connected() { printf '%s\n' "$connected" | grep -qx "$1"; }

primary_bar() {   # primary_bar BAR DEFAULT_MONITOR
  if is_connected "$2" || [ -z "$fallback" ]; then
    polybar "$1" -r &
  else
    MONITOR="$fallback" polybar "$1" -r &
  fi
}
extra_bar() {     # extra_bar BAR DEFAULT_MONITOR
  if is_connected "$2"; then polybar "$1" -r & fi
}

case "$profile" in
  lintilla)
    primary_bar lintilla-primary DP-1
    extra_bar   lintilla-secondary DVI-I-1
    extra_bar   lintilla-tertiary HDMI-0 ;;
  garkbit)
    primary_bar garkbit-primary DP1
    extra_bar   garkbit-secondary HDMI2 ;;
  allitnil)
    primary_bar allitnil eDP1 ;;
  *)
    echo "launch-polybar: unknown profile '$profile'" >&2; exit 1 ;;
esac
LAUNCHER
  chmod +x "$dest"
}

setup_script_compat() {
  local main="${HOME}/src/scripts" dep="${HOME}/src/scripts-deprecated" f
  log "Setting up the polybar / i3 helper scripts..."
  if [[ ! -d $main ]]; then
    warn "~/src/scripts is missing - polybar, tmux and i3 helper scripts are unavailable"; return 0
  fi
  sync_repo "$SCRIPTS_URL" "${HOME}/src" deprecated scripts-deprecated

  for f in keyboard-layout.sh vpn.sh touchpad-toggle.sh emacs-file-opener.sh tmux-music.sh rxtx.sh loadavg.sh; do
    if [[ -e $dep/$f && ! -e $main/$f ]]; then
      ln -sfn "$dep/$f" "$main/$f"; git_exclude "$main" "$f"
    fi
  done
  if [[ -e $dep/chdisp-xrandr.sh && ! -e $main/chdisp ]]; then   # i3's display-layout mode
    ln -sfn "$dep/chdisp-xrandr.sh" "$main/chdisp"; git_exclude "$main" chdisp
  fi

  if git -C "$main" ls-files --error-unmatch launch-polybar.sh >/dev/null 2>&1; then
    info "scripts repo ships its own launch-polybar.sh - leaving it"
  else
    write_polybar_launcher "$main/launch-polybar.sh"; git_exclude "$main" launch-polybar.sh
    ok "wrote ~/src/scripts/launch-polybar.sh (handles lintilla / garkbit / allitnil)"
  fi
  printf '%s\n' "$PROFILE" > "${HOME}/.config/etc-profile"
}

# -----------------------------------------------------------------------------
# 6. Misc symlinks (the Makefile's link-misc rule and friends)
# -----------------------------------------------------------------------------
link_if_present() {  # link_if_present <target> <linkname>
  local src=$1 dst=$2
  if [[ ! -e $src ]]; then info "skip $(basename -- "$dst") (missing ${src/#$HOME/~})"; return 0; fi
  if [[ -e $dst && ! -L $dst ]]; then warn "${dst} exists and is not a symlink - left alone"; return 0; fi
  mkdir -p "$(dirname -- "$dst")"
  ln -sfn "$src" "$dst"
}

link_misc() {
  log "Linking helper scripts and libs..."
  local b="${HOME}/bin" s="${HOME}/src/scripts"
  link_if_present "${HOME}/src/scripts"  "${HOME}/scripts"
  link_if_present "${HOME}/src/scripts"  "${HOME}/utils"      # legacy path still used by i3
  link_if_present "${HOME}/src/colors"   "${HOME}/colors"
  link_if_present "${ETC_DIR}/scripts/ftl.sh"          "$b/ftl"
  link_if_present "$s/emacs-file-opener.sh"            "$b/emacs-file-opener"
  link_if_present "$s/touchpad-toggle.sh"              "$b/touchpad-toggle"
  link_if_present "$s/tmux-main.sh"                    "$b/tmain"
  link_if_present "$s/tmux-update-window.sh"           "$b/tupd"
  link_if_present "$s/tmux-ssh.sh"                     "$b/tssh"
  link_if_present "$s/tmux-music.sh"                   "$b/tmusic"
  link_if_present "$s/rxtx.sh"                         "$b/rxtx"
  link_if_present "$s/loadavg.sh"                      "$b/loadavg"
  link_if_present "$s/chdisp"                          "$b/chdisp"
  link_if_present "${HOME}/lib/vidir/bin/vidir"        "$b/vidir"
  link_if_present "${HOME}/src/bakc/bakc.sh"           "$b/bakc"
  link_if_present "${HOME}/lib/LS_COLORS/LS_COLORS"    "${HOME}/.dircolors"

  if [[ ! -x $b/cht.sh ]]; then
    if curl -fsSL https://cht.sh/:cht.sh -o "$b/cht.sh"; then chmod +x "$b/cht.sh"
    else rm -f "$b/cht.sh"; warn "could not download cht.sh"; fi
  fi
}

# -----------------------------------------------------------------------------
# 7. Link the configs with stow, backing up anything that is in the way
# -----------------------------------------------------------------------------
parse_stow_conflicts() {  # reads stow output on stdin, prints conflicting paths (relative to $HOME)
  sed -nE \
    -e 's/^[[:space:]]*\* existing target is (neither a link nor a directory|not owned by stow): (.+)$/\2/p' \
    -e 's/^[[:space:]]*\* cannot stow .+ over existing target (.+) since .*$/\1/p'
}

backup_paths() {
  local rel dest
  for rel in "$@"; do
    case $rel in ''|/*|*..*) warn "refusing to back up odd path '${rel}'"; continue ;; esac
    [[ -e ${HOME}/${rel} || -L ${HOME}/${rel} ]] || continue
    dest="${BACKUP_DIR}/${rel}"
    mkdir -p "$(dirname -- "$dest")"
    if mv "${HOME}/${rel}" "$dest"; then info "backed up ~/${rel} -> ${dest/#$HOME/~}"
    else warn "could not back up ~/${rel}"; fi
  done
}

stow_dir() {  # stow_dir <dir relative to ~/etc> [extra stow args]
  local dir=$1; shift
  if [[ ! -d $ETC_DIR/$dir ]]; then info "no ${dir} - skipped"; return 0; fi
  local -a pkgs=() conflicts=()
  mapfile -t pkgs < <(find "$ETC_DIR/$dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
  ((${#pkgs[@]})) || return 0

  local attempt out rc
  for attempt in 1 2 3 4; do
    out="$(cd "$ETC_DIR" && stow -R -t "$HOME" -d "$dir" "$@" "${pkgs[@]}" 2>&1)"; rc=$?
    if ((rc == 0)); then ok "stowed ${#pkgs[@]} packages from ${dir}"; return 0; fi
    mapfile -t conflicts < <(parse_stow_conflicts <<<"$out")
    if ((${#conflicts[@]} == 0)); then
      warn "stow failed for ${dir}: ${out}"; return 1
    fi
    backup_paths "${conflicts[@]}"
  done
  warn "stow still reports conflicts for ${dir} after backing files up: ${out}"
}

link_conf() {
  log "Linking configs with stow..."
  stow_dir conf --ignore="$STOW_IGNORE"
  stow_dir "local/${PROFILE}/conf"
}

# The repo's ~/.gitconfig is roosta's identity with commit.gpgsign=true and includes
# ~/.gitconfig.local; keep the user's own identity there.
capture_git_identity() {
  GIT_PREV_NAME="${GIT_NAME:-}"; GIT_PREV_EMAIL="${GIT_EMAIL:-}"
  [[ -L ${HOME}/.gitconfig ]] && return 0   # already linked by an earlier run
  [[ -n $GIT_PREV_NAME  ]] || GIT_PREV_NAME="$(git config --global --get user.name 2>/dev/null || true)"
  [[ -n $GIT_PREV_EMAIL ]] || GIT_PREV_EMAIL="$(git config --global --get user.email 2>/dev/null || true)"
  GIT_PREV_KEY="$(git config --global --get user.signingkey 2>/dev/null || true)"
  GIT_PREV_SIGN="$(git config --global --get commit.gpgsign 2>/dev/null || true)"
}

write_git_local() {
  local f="${HOME}/.gitconfig.local"
  [[ -e $f ]] && return 0
  [[ -L ${HOME}/.gitconfig ]] || return 0
  {
    echo "# Written by install-dotfiles.sh - overrides the identity and signing in the shared ~/.gitconfig"
    echo "[user]"
    if [[ -n $GIT_PREV_NAME  ]]; then printf '\tname = %s\n'  "$GIT_PREV_NAME";  else echo "#	name = Your Name";   fi
    if [[ -n $GIT_PREV_EMAIL ]]; then printf '\temail = %s\n' "$GIT_PREV_EMAIL"; else echo "#	email = you@example.com"; fi
    [[ -n $GIT_PREV_KEY ]] && printf '\tsigningkey = %s\n' "$GIT_PREV_KEY"
    echo "[commit]"
    printf '\tgpgsign = %s\n' "${GIT_PREV_SIGN:-false}"
  } > "$f"
  if [[ -z $GIT_PREV_NAME || -z $GIT_PREV_EMAIL ]]; then
    warn "Set your git name/email in ~/.gitconfig.local - until then commits use roosta's identity from the shared ~/.gitconfig"
  else
    ok "Wrote ~/.gitconfig.local with your own git identity"
  fi
}

# ~/.pam_environment (SSH_AUTH_SOCK -> gpg-agent) is ignored by current PAM.
write_zprofile() {
  local f="${HOME}/.zprofile"
  if [[ -e $f ]] && grep -q 'SSH_AUTH_SOCK' "$f"; then return 0; fi
  cat >> "$f" <<'ZPROFILE'
# Added by install-dotfiles.sh: ssh via gpg-agent (the repo sets this in
# ~/.pam_environment, which modern PAM no longer reads).
export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR:-/run/user/$UID}/gnupg/S.gpg-agent.ssh"
ZPROFILE
  ok "Wrote ~/.zprofile (SSH_AUTH_SOCK -> gpg-agent)"
}

# -----------------------------------------------------------------------------
# 8. Generate i3 / rofi / dunst configs with the repo's own Makefile rules, so the
#    host variables (monitors, font, DPI, bar height, ...) apply exactly as upstream.
# -----------------------------------------------------------------------------
generate_configs() {
  log "Generating the i3, rofi and dunst configs (profile: ${PROFILE})..."
  mkdir -p "${HOME}/.config/rofi" "${HOME}/.config/dunst"
  if (cd "$ETC_DIR" && make -B -o link-conf HOST="$PROFILE" \
        "${HOME}/.i3/config" "${HOME}/.config/rofi/config" "${HOME}/.config/dunst/dunstrc") >/dev/null; then
    if grep -q 'set \$primary_monitor' "${HOME}/.i3/config" 2>/dev/null; then
      ok "Generated ~/.i3/config, rofi/config.rasi and dunstrc"
    else
      warn "~/.i3/config was generated without the monitor variables - check local/${PROFILE}/variables.mk"
    fi
  else
    warn "Generating the i3/rofi/dunst configs failed - run 'make HOST=${PROFILE} i3 rofi dunst' in ~/etc to see why"
  fi
  if have i3-msg && pgrep -x i3 >/dev/null 2>&1; then i3-msg reload >/dev/null 2>&1 || true; fi
}

# i3's $locker points at a tiled background that is not in the repo; without it i3lock refuses to lock.
ensure_locker_image() {
  local img="${HOME}/backgrounds/footer_lodyas.png"
  [[ -e $img ]] && return 0
  if have magick; then magick -size 8x8 'xc:#1C1B19' "$img"
  elif have convert; then convert -size 8x8 'xc:#1C1B19' "$img"
  else warn "ImageMagick not found - the i3 lock screen needs ${img}"; return 0; fi
  info "created a plain srcery-black lock-screen tile at ~/backgrounds/footer_lodyas.png"
}

# stow ignores conf/firefox on purpose (the profile directory is machine specific),
# so link userChrome.css into the "roosta" profile directory the Makefile creates.
setup_firefox() {
  local prof="${HOME}/.mozilla/firefox/roosta"
  local css="${ETC_DIR}/conf/firefox/.mozilla/firefox/roosta/chrome/userChrome.css"
  [[ -f $css ]] || return 0
  mkdir -p "$prof/chrome"
  ln -sfn "$css" "$prof/chrome/userChrome.css"
  local pref='user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);'
  grep -qsF "$pref" "$prof/user.js" || printf '%s\n' "$pref" >> "$prof/user.js"
  if have firefox && [[ ! -e $prof/.registered ]]; then
    if MOZ_HEADLESS=1 timeout 60 firefox -CreateProfile "roosta ${prof}" >/dev/null 2>&1; then
      touch "$prof/.registered"; ok "Firefox profile 'roosta' registered with userChrome.css (start it with: firefox -P roosta)"
    else
      info "Run once to register the profile: firefox -CreateProfile \"roosta ${prof}\""
    fi
  fi
}

# -----------------------------------------------------------------------------
# 9. Plugin managers and toolchains
# -----------------------------------------------------------------------------
setup_zplug() {
  have zsh || { warn "zsh is not installed - skipping zplug"; return 0; }
  if [[ ! -d ${HOME}/.zplug ]]; then
    log "Installing zplug..."
    curl -fsSL --proto-redir -all,https \
      https://raw.githubusercontent.com/zplug/installer/master/installer.zsh | zsh \
      || { warn "zplug installer failed"; return 0; }
  fi
  # ~/.zshrc runs `zplug install` itself when plugins are missing.
  log "Installing zsh plugins (first interactive start)..."
  timeout 900 zsh -i -c 'exit' </dev/null >/dev/null 2>&1 \
    || info "zsh plugin install returned non-zero; open a new terminal to finish it"
}

setup_tmux() {
  have tmux || { warn "tmux is not installed - skipping tpm"; return 0; }
  log "Installing tmux plugins (tpm)..."
  mkdir -p "${HOME}/.tmux/plugins"
  if [[ ! -d ${HOME}/.tmux/plugins/tpm ]]; then
    git clone --quiet --depth 1 https://github.com/tmux-plugins/tpm "${HOME}/.tmux/plugins/tpm" \
      || { warn "could not clone tpm"; return 0; }
  fi
  "${HOME}/.tmux/plugins/tpm/bin/install_plugins" >/dev/null 2>&1 \
    || info "tpm install returned non-zero; press prefix + I inside tmux to finish it"
}

setup_vim() {
  have vim || { warn "vim is not installed - skipping vim plugins"; return 0; }
  log "Installing vim plugins (vim-plug)..."
  if [[ ! -f ${HOME}/.vim/autoload/plug.vim ]]; then
    curl -fsSLo "${HOME}/.vim/autoload/plug.vim" --create-dirs \
      https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim \
      || { warn "could not download vim-plug"; return 0; }
  fi
  vim -E -s -u "${HOME}/.vimrc" -i NONE +'PlugInstall --sync' +qall </dev/null >/dev/null 2>&1 \
    || info "vim exited non-zero (often harmless before the colorscheme exists); check :PlugStatus"
}

setup_rust_tools() {
  have rustup || { info "rustup not installed - skipping rust toolchain, i3wsr"; return 0; }
  export PATH="${HOME}/.cargo/bin:${PATH}"
  log "Setting up the rust toolchain..."
  rustup install stable  >/dev/null 2>&1 || warn "rustup install stable failed"
  rustup install nightly >/dev/null 2>&1 || info "nightly toolchain not installed (non-fatal)"
  rustup default stable  >/dev/null 2>&1 || warn "rustup default stable failed"
  if [[ ! -x ${HOME}/.cargo/bin/i3wsr ]]; then   # i3 execs this: it names workspaces Q:term, W:edit ...
    log "Building i3wsr (workspace renamer used by i3)..."
    cargo install i3wsr >/dev/null 2>&1 || warn "cargo install i3wsr failed - i3 will log an error at startup"
  fi
  if ! have exa; then
    cargo install exa >/dev/null 2>&1 || warn "no exa/eza available - 'ls' falls back to ls++ or plain ls"
  fi
}

setup_npm_tools() {
  have npm || return 0
  if [[ ! -x ${HOME}/.npm/bin/vtop ]]; then   # the system monitor in the "busy" screenshot
    log "Installing vtop..."
    NPM_CONFIG_PREFIX="${HOME}/.npm" npm install -g vtop >/dev/null 2>&1 \
      || warn "npm install -g vtop failed (vtop is unmaintained and may not run on current Node)"
  fi
}

# -----------------------------------------------------------------------------
# 10. Login shell and services
# -----------------------------------------------------------------------------
set_shell() {
  have zsh || { warn "zsh not installed - login shell unchanged"; return 0; }
  local zsh_path current
  zsh_path="$(command -v zsh)"
  current="$(getent passwd "$USER" | cut -d: -f7)"
  if [[ $current == */zsh ]]; then ok "Login shell is already zsh"; return 0; fi
  log "Changing the login shell to zsh..."
  if have sudo; then
    grep -qx "$zsh_path" /etc/shells 2>/dev/null || printf '%s\n' "$zsh_path" | sudo tee -a /etc/shells >/dev/null
    sudo chsh -s "$zsh_path" "$USER" || warn "chsh failed - run: chsh -s ${zsh_path}"
  else
    chsh -s "$zsh_path" || warn "chsh failed - run: chsh -s ${zsh_path}"
  fi
}

enable_services() {
  local unit
  # emacs.service / tmux.service exist in the repo but are NOT enabled: ~/.xinitrc
  # already starts the emacs daemon, and tmux is attached via the tmain script.
  if have systemctl && [[ -n $USER_SERVICES ]]; then
    log "Enabling user services: ${USER_SERVICES}"
    systemctl --user daemon-reload 2>/dev/null || true
    for unit in $USER_SERVICES; do
      if systemctl --user enable --now "$unit" 2>/dev/null; then ok "enabled and started ${unit}"
      elif systemctl --user enable "$unit" 2>/dev/null; then info "enabled ${unit} (starts at your next login)"
      else warn "could not enable user unit ${unit}"; fi
    done
  fi
  if [[ -n $SYSTEM_SERVICES ]] && have sudo; then
    log "Enabling system services: ${SYSTEM_SERVICES}"
    for unit in $SYSTEM_SERVICES; do
      sudo systemctl enable --now "${unit%.service}.service" 2>/dev/null \
        && ok "enabled ${unit}" || warn "could not enable system unit ${unit}"
    done
  fi
}

# -----------------------------------------------------------------------------
# 11. Wrap-up
# -----------------------------------------------------------------------------
summary() {
  rm -rf "${ETC_DIR}/build" 2>/dev/null || true
  echo
  if ((${#FAILED_PKGS[@]})); then
    printf '%sPackages that could not be installed:%s\n' "$C_R" "$C_N"
    printf '   %s\n' "${FAILED_PKGS[@]}"
    echo
  fi
  if ((${#WARNINGS[@]})); then
    printf '%sThings to look at:%s\n' "$C_Y" "$C_N"
    local w; for w in "${WARNINGS[@]}"; do printf '  - %s\n' "$w"; done
    echo
  fi
  ok "Done. Profile: ${PROFILE}"
  cat <<EOF

Next steps
  1. Log out, then log in on tty1: ~/.zlogin runs startx -> ~/.xinitrc -> i3.
  2. Wallpaper: run nitrogen once (the clean screenshot's wallpaper is not in the repo).
  3. Music: put files in ~/Music (mopidy + ncmpcpp), or configure mopidy-spotify.
  4. Daily routine from your Makefile:  cd ~/etc && make HOST=${PROFILE}
  5. Not your hardware? Edit ~/etc/local/${PROFILE}/variables.mk (monitors, DPI, font)
     and the monitor names in ~/.config/polybar/config, then 'make HOST=${PROFILE} i3 rofi dunst'.
EOF
}

main() {
  parse_args "$@"
  echo
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  etc dotfiles installer                                          ║"
  echo "║  Arch · i3 · polybar · termite · rofi · zsh · tmux · vim/emacs   ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  echo

  preflight
  fetch_dotfiles
  resolve_profile
  rewrite_home_paths
  create_user_fs

  if ((DO_PACKAGES)); then
    install_yay
    install_pacman_packages
    install_aur_packages
    ensure_exa
  fi

  capture_git_identity
  sync_repositories
  setup_script_compat
  link_misc
  link_conf
  write_git_local
  write_zprofile
  generate_configs
  ensure_locker_image
  setup_firefox

  if ((DO_PLUGINS)); then
    setup_zplug
    setup_tmux
    setup_vim
    setup_rust_tools
    setup_npm_tools
  fi

  set_shell
  if ((DO_SERVICES)); then enable_services; fi
  summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
