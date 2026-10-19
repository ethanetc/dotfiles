#!/usr/bin/env bash
# =============================================================================
#  dots.sh - one-shot installer for the ethanetc "etc" dotfiles (Arch Linux)
#
#  Rebuilds the desktop in the four reference pictures
#  (clean.jpg / busy.png / busy2.png / firefox.png):
#    i3 + polybar (default bar) · alacritty · rofi · dunst · picom · zsh/zplug
#    tmux · vim/neovim/emacs · ranger · mopidy + ncmpcpp · cava · vtop
#    Firefox (dark + userChrome + start page) · srcery colours · Iosevka
#
#  Source of the dotfiles (first match wins):
#    1. an existing ~/etc checkout
#    2. a snapshot zip next to this script (dotfiles-<sha>.zip) or $DOTFILES_ZIP
#    3. $REPO_URL (default https://github.com/ethanetc/dotfiles.git), which
#       holds the snapshot zip
#
#  Usage:  bash dots.sh [--configs-only] [--skip-packages] [--skip-plugins]
#                       [--skip-services] [--no-startpage] [-h|--help]
#
#    --configs-only   only (re)apply configs: no packages, plugins or services
#
#  Environment overrides:
#    PROFILE=ethan|lintilla|garkbit|allitnil   machine profile (default: ethan,
#                                         auto-detects monitors and DPI)
#    ETC_DPI=96|120|144|192               force the X DPI (default: auto from the
#                                         primary monitor: 4K -> 192, like the pics)
#    DOTFILES_ZIP=/path/to/snapshot.zip  REPO_URL=https://github.com/you/repo.git
#    GIT_NAME / GIT_EMAIL                identity for ~/.gitconfig.local
#    USER_SERVICES="a.service b.socket"  user units to enable
#    SKIP_PKGS="pkg1 pkg2"               extra packages to skip
#    KEEP_AWESOME=1                      do not uninstall awesome
#
#  Run it as your normal user (it uses sudo when needed). Safe to re-run.
#  Non-fatal problems are collected and printed at the end.
# =============================================================================

set -uo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
ETC_DIR="${HOME}/etc"   # fixed: the Makefile hardcodes ~/etc
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
NOW="$(date +%Y-%m-%dT%T)"
BACKUP_DIR="${HOME}/backup/original-system-files@${NOW}"

REPO_URL="${REPO_URL:-https://github.com/ethanetc/dotfiles.git}"
SCRIPTS_URL="https://github.com/roosta/scripts.git"
STARTPAGE_URL="https://github.com/roosta/startpage.git"
CLEAN_JPG_URL="https://raw.githubusercontent.com/roosta/assets/master/etc/clean.jpg"
DOTFILES_ZIP="${DOTFILES_ZIP:-}"
PROFILE="${PROFILE:-ethan}"
ETC_DPI="${ETC_DPI:-}"
USER_SERVICES="${USER_SERVICES-mopidy-user.service gpg-agent-ssh.socket}"
SYSTEM_SERVICES="${SYSTEM_SERVICES:-}"
SKIP_PKGS="${SKIP_PKGS:-}"
KEEP_AWESOME="${KEEP_AWESOME:-0}"
WALLPAPER="${HOME}/backgrounds/clouds.jpg"

# Same ignore pattern as the Makefile's link-conf rule.
STOW_IGNORE='md|org|firefox'

DO_PACKAGES=1
DO_PLUGINS=1
DO_SERVICES=1
DO_STARTPAGE=1

# Everything the configs and the pictures need that pacman_packages.txt lacks
# (or names by an old name). Anything not in the official repos goes to the AUR.
EXTRA_PACMAN=(
  rustup ruby fzf eza                                   # zsh / ls
  alacritty                                             # replaces termite (gone from Arch)
  i3-wm i3lock polybar rofi rofi-calc picom dunst libnotify feh nitrogen
  xorg-server xorg-xinit xorg-xrandr xorg-xrdb xorg-xset xorg-setxkbmap numlockx
  pipewire pipewire-pulse pipewire-alsa wireplumber pavucontrol
  ttf-firacode-nerd ttf-nerd-fonts-symbols ttf-font-awesome noto-fonts noto-fonts-emoji
  ranger w3m highlight atool mediainfo poppler ffmpegthumbnailer libcaca odt2txt p7zip
  python-pillow python-numpy python-chardet
  mopidy ncmpcpp tmux neovim vim lua go task emacs xclip xdotool   # lua: miniyank, go: hexokinase
  clipmenu flameshot lxqt-policykit gnome-keyring gnome-themes-extra
  pacman-contrib networkmanager jq nodejs npm jdk-openjdk leiningen
  git stow make curl unzip
)
EXTRA_AUR=(
  ttf-iosevka ttf-iosevka-term                          # font in every picture
  mopidy-mpd                                            # lets ncmpcpp/polybar talk to mopidy
  archey3                                               # the system info in clean.jpg
  themix-theme-oomox-git                                # builds the oomox-srcery GTK theme
)

# Packages that cannot / must not be installed, with the reason.
declare -A SKIP_PKG=(
  [termite]="removed from Arch; alacritty is configured to look the same"
  [jdk7-openjdk]="end-of-life, no longer buildable"
  [jdk8-openjdk]="replaced by jdk-openjdk"
  [cargo]="provided by rustup (rust and rustup conflict)"
  [compton]="replaced by picom (your .xinitrc starts picom)"
  [universal-ctags-git]="repo 'ctags' is already universal-ctags (they conflict)"
  [joker-bin]="duplicate of 'joker' (they conflict)"
  [google-chrome-dev]="conflicts with google-chrome (also listed)"
  [rust-racer]="needs the 'rust' package, which conflicts with rustup"
  [rust-docs]="needs the 'rust' package, which conflicts with rustup"
  [pulseaudio]="pipewire-pulse is the audio server on current Arch"
  [pulseaudio-alsa]="pipewire-pulse is the audio server on current Arch"
  [oomox-git]="renamed; themix-theme-oomox-git is installed instead"
  [pablodraw]="unmaintained, no longer builds"
  [dropbox]="needs a manual GPG key import; install it by hand if you use it"
  [dropbox-cli]="needs dropbox"
  [awesome]="you asked for i3, not awesome"
)
# Old name -> current name, used only when the old name is gone from the repos.
declare -A RENAMED_PKG=( [qemu]=qemu-desktop [mlocate]=plocate [java-rhino]=rhino [rxvt-unicode-terminfo]=rxvt-unicode )

# Repos your configs load from ~/src and ~/lib but that the *_repositories.txt
# lists don't contain:
EXTRA_SRC_REPOS=(
  https://github.com/srcery-colors/srcery-textmate     # bat theme (conf/bat)
  https://github.com/srcery-colors/srcery-shell        # vifm colours
  https://github.com/srcery-colors/srcery-web          # tridactyl theme
  https://github.com/roosta/fif                        # zplug "~/src/fif"
  https://github.com/roosta/foldlist                   # vim: Plug '~/src/foldlist'
  https://github.com/roosta/tmux-fuzzback              # tmux.conf run-shell
  https://github.com/roosta/cljr-ivy                   # emacs: :load-path
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
  C_Y=$'\033[0;33m'; C_G=$'\033[1;32m'; C_R=$'\033[0;31m'; C_C=$'\033[0;36m'; C_M=$'\033[1;35m'; C_N=$'\033[0m'
else
  C_Y=''; C_G=''; C_R=''; C_C=''; C_M=''; C_N=''
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
  sed -n '2,/^# ====/p' "${BASH_SOURCE[0]}" | sed -e '/^# ====/d' -e 's/^# \{0,2\}//'
}

parse_args() {
  while (($#)); do
    case "$1" in
      --configs-only)  DO_PACKAGES=0; DO_PLUGINS=0; DO_SERVICES=0; DO_STARTPAGE=0 ;;
      --skip-packages) DO_PACKAGES=0 ;;
      --skip-plugins)  DO_PLUGINS=0 ;;
      --skip-services) DO_SERVICES=0 ;;
      --no-startpage)  DO_STARTPAGE=0 ;;
      -h|--help)       usage; exit 0 ;;
      *)               die "Unknown option: $1 (try --help)" ;;
    esac
    shift
  done
}

# Write a file only when its content changes (keeps re-runs quiet in git).
put() {  # put <path> [mode]   (content on stdin)
  local dst=$1 mode=${2:-} tmp
  tmp="$(mktemp)"; cat > "$tmp"
  mkdir -p "$(dirname -- "$dst")"
  if [[ -L $dst ]]; then rm -f -- "$dst"; fi
  if [[ -f $dst ]] && cmp -s "$tmp" "$dst"; then rm -f "$tmp"
  else mv -f "$tmp" "$dst"; fi
  [[ -n $mode ]] && chmod "$mode" "$dst"
  return 0
}

# -----------------------------------------------------------------------------
# 0. Pre-flight
# -----------------------------------------------------------------------------
preflight() {
  [[ $EUID -ne 0 ]] || die "Run as your normal user (with sudo rights), not as root."

  if ((DO_PACKAGES)); then
    have pacman || die "Installing packages needs Arch Linux (pacman). Use --configs-only to only apply the configs."
    have sudo   || die "sudo is required."
    start_sudo_keepalive
    log "Upgrading the system and installing base tooling (a partial upgrade is unsafe on Arch)..."
    sudo pacman -Syu --needed --noconfirm base-devel git stow unzip curl make \
      || warn "pacman -Syu failed; continuing with what is already installed"
  else
    local -a missing=() t
    for t in git stow unzip curl make; do have "$t" || missing+=("$t"); done
    if ((${#missing[@]})) && have pacman && have sudo; then
      sudo pacman -S --needed --noconfirm "${missing[@]}" || true
    fi
  fi
  local t
  for t in git stow unzip curl make; do have "$t" || die "Required tool missing: $t"; done
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

etc_commit() {  # etc_commit <message>
  [[ -d $ETC_DIR/.git ]] || return 0
  (
    cd "$ETC_DIR" && git add -A &&
    { git diff --cached --quiet || git -c user.name="dots.sh" -c user.email="dots.sh@localhost" \
        -c commit.gpgsign=false commit -q -m "$1"; }
  ) >/dev/null 2>&1 || true
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
  ( cd "$ETC_DIR" && git init -q ) >/dev/null 2>&1
  etc_commit "Import dotfiles snapshot $(basename -- "$zip" .zip)"
  ok "Dotfiles ready at ${ETC_DIR} (a git repo: 'git -C ~/etc log' shows what dots.sh changed)"
}

fetch_from_remote() {
  local tmp z
  tmp="$(mktemp -d)"
  log "Cloning ${REPO_URL}"
  GIT_TERMINAL_PROMPT=0 git clone --quiet --depth 1 "$REPO_URL" "$tmp/repo" \
    || { rm -rf "$tmp"; die "Could not clone ${REPO_URL} (offline, or the repo is private?)"; }
  # Keep the repo's extras (e.g. wallpaper.jpg) next to the zip for later steps.
  [[ -f $tmp/repo/wallpaper.jpg ]] && { mkdir -p "$(dirname "$WALLPAPER")"; cp -n "$tmp/repo/wallpaper.jpg" "$WALLPAPER"; }
  if [[ -f $tmp/repo/Makefile && -d $tmp/repo/conf ]]; then
    mv "$tmp/repo" "$ETC_DIR"; rm -rf "$tmp"
    ok "Cloned dotfiles into ${ETC_DIR}"; return 0
  fi
  z="$(first_zip_in "$tmp/repo")"
  [[ -n $z ]] || { rm -rf "$tmp"; die "${REPO_URL} has neither a dotfiles tree nor a dotfiles-<sha>.zip snapshot"; }
  extract_zip "$z"
  rm -rf "$tmp"
}

fetch_dotfiles() {
  log "Locating the dotfiles..."
  [[ -f $SELF_DIR/wallpaper.jpg && ! -f $WALLPAPER ]] && { mkdir -p "$(dirname "$WALLPAPER")"; cp "$SELF_DIR/wallpaper.jpg" "$WALLPAPER"; }
  if [[ -f $ETC_DIR/Makefile && -d $ETC_DIR/conf ]]; then
    ok "Using the existing dotfiles in ${ETC_DIR}"
    return 0
  fi
  if [[ -e $ETC_DIR ]] && [[ -n "$(ls -A "$ETC_DIR" 2>/dev/null)" ]]; then
    local aside="${ETC_DIR}.old-${NOW//:/-}"
    warn "${ETC_DIR} existed but was not the dotfiles tree - moved to ${aside/#$HOME/~}"
    mv -- "$ETC_DIR" "$aside" || die "Could not move ${ETC_DIR} out of the way"
  fi
  [[ -d $ETC_DIR ]] && rmdir "$ETC_DIR" 2>/dev/null || true
  if [[ -n $DOTFILES_ZIP && ! -f $DOTFILES_ZIP ]]; then
    die "DOTFILES_ZIP=${DOTFILES_ZIP} does not exist"
  fi
  local zip; zip="$(find_local_zip)"
  if [[ -n $zip ]]; then extract_zip "$zip"; else fetch_from_remote; fi
}

# The snapshot hardcodes /home/roosta in files and in a few symlinks.
rewrite_home_paths() {
  [[ $HOME != /home/roosta ]] || return 0
  local -a files=()
  mapfile -t files < <(grep -rlI --exclude-dir=.git --exclude='*.md' '/home/roosta' "$ETC_DIR" 2>/dev/null)
  if ((${#files[@]})); then
    local repl; repl="$(printf '%s' "$HOME" | sed -e 's/[\\|&]/\\&/g')"
    sed -i "s|/home/roosta|${repl}|g" "${files[@]}"
    info "rewrote /home/roosta -> ${HOME} in ${#files[@]} files"
  fi
  local l t
  while IFS= read -r -d '' l; do
    t="$(readlink "$l")"
    [[ $t == /home/roosta/* ]] && ln -sfn "${HOME}/${t#/home/roosta/}" "$l"
  done < <(find "$ETC_DIR" -path "$ETC_DIR/.git" -prune -o -type l -print0)
  # links to things that no longer exist anywhere
  rm -f "$ETC_DIR/conf/vimperator/.vimperator/plugin/alias.js" \
        "$ETC_DIR/conf/vimperator/.vimperator/plugin/caret-hint.js"
}

# -----------------------------------------------------------------------------
# 2. Fixes and the look from the pictures, applied on top of the snapshot.
#    Every change lands in ~/etc as a git commit, so 'git -C ~/etc show' lists it.
# -----------------------------------------------------------------------------
overlay_colors() {
  # The repo's srcery.xresources is a dead symlink, and today's srcery-terminal
  # uses a different palette. These are the exact colours in the pictures.
  put "$ETC_DIR/conf/x/.Xresources.d/srcery.xresources" <<'EOF'
! srcery - the palette in clean.jpg / busy.png / busy2.png (written by dots.sh)
*foreground:   #FCE8C3
*background:   #1C1B19
*cursorColor:  #FBB829
*color0:       #1C1B19
*color8:       #918175
*color1:       #EF2F27
*color9:       #F75341
*color2:       #519F50
*color10:      #98BC37
*color3:       #FBB829
*color11:      #FED06E
*color4:       #2C78BF
*color12:      #68A8E4
*color5:       #E02C6D
*color13:      #FF5C8F
*color6:       #0AAEB3
*color14:      #53FDE9
*color7:       #D0BFA1
*color15:      #FCE8C3
*color166:     #D75F00
*color208:     #FF8700
*color232:     #080808
*color235:     #262626
*color236:     #2D2B28
*color237:     #3A3A3A
*color238:     #444444
*color239:     #4E4E4E
EOF
}

overlay_terminal() {
  # termite is gone from Arch; alacritty gets termite's exact font and colours.
  rm -f "$ETC_DIR/conf/alacritty/.config/alacritty/alacritty.yml"
  put "$ETC_DIR/conf/alacritty/.config/alacritty/alacritty.toml" <<'EOF'
# Alacritty - stands in for termite from the pictures (written by dots.sh)

[window]
padding = { x = 2, y = 2 }
dynamic_padding = false

[scrolling]
history = 10000

[font]
size = 9.0
normal      = { family = "Iosevka Term", style = "Regular" }
bold        = { family = "Iosevka Term", style = "Bold" }
italic      = { family = "Iosevka Term", style = "Italic" }
bold_italic = { family = "Iosevka Term", style = "Bold Italic" }

[colors]
draw_bold_text_with_bright_colors = true

[colors.primary]
background = "#1c1b19"
foreground = "#fce8c3"

[colors.cursor]
text   = "#1c1b19"
cursor = "#fbb829"

[colors.selection]
text       = "#1c1b19"
background = "#fce8c3"

[colors.normal]
black   = "#1c1b19"
red     = "#ef2f27"
green   = "#519f50"
yellow  = "#fbb829"
blue    = "#2c78bf"
magenta = "#e02c6d"
cyan    = "#0aaeb3"
white   = "#d0bfa1"

[colors.bright]
black   = "#918175"
red     = "#f75341"
green   = "#98bc37"
yellow  = "#fed06e"
blue    = "#68a8e4"
magenta = "#ff5c8f"
cyan    = "#53fde9"
white   = "#fce8c3"

[bell]
duration = 0

[cursor]
style = { shape = "Block", blinking = "On" }

[selection]
semantic_escape_chars = ",│`|:\"' ()[]{}<>"
save_to_clipboard = false

[mouse]
hide_when_typing = false
EOF

  local zenv="$ETC_DIR/conf/zsh/.zshenv"
  # TERM=xterm-termite breaks every program when termite's terminfo is missing.
  sed -i -E 's|^export TERM="xterm-termite"|# TERM is set by the terminal (dots.sh)|' "$zenv"
  sed -i -E 's|^export TERMINAL=termite$|export TERMINAL=alacritty|' "$zenv"
  sed -i -E 's|^export GEM_HOME="\$\(ruby -e .puts Gem.user_dir.\)"$|hash ruby 2>/dev/null \&\& export GEM_HOME="$(ruby -e '"'"'puts Gem.user_dir'"'"')"|' "$zenv"
  grep -q '\.local/bin' "$zenv" || sed -i 's|^\t~/bin$|\t~/bin\n\t~/.local/bin|' "$zenv"

  local tconf="$ETC_DIR/conf/tmux/.tmux.conf"
  grep -q 'alacritty:Tc' "$tconf" || \
    sed -i 's|^set -ga terminal-overrides ",xterm-termite:Tc"|&\nset -ga terminal-overrides ",alacritty:Tc"|' "$tconf"

  sed -i -E 's/^Termite = /Alacritty = /' "$ETC_DIR/conf/i3wsr/.i3wsr_config.toml" 2>/dev/null || true
  sed -i -E 's/^Exec=env GDK_DPI_SCALE=0.5 termite$/Exec=alacritty -o font.size=6/' \
    "$ETC_DIR/conf/desktop/.local/share/applications/termite-scaled.desktop" 2>/dev/null || true
}

overlay_i3() {
  local vars="$ETC_DIR/templates/i3/variables.i3" conf="$ETC_DIR/templates/i3/config.i3"

  # terminal
  sed -i -E 's|^set \$term .*|set $term alacritty|; s|^set \$term_scaled .*|set $term_scaled alacritty -o font.size=6|' "$vars"

  # Workspace names exactly as on the bar in the pictures: Q:term W:edit E:www 1 2 3 4
  sed -i -E '/^set \$(pws|sws|tws|aws)_/d; /^# (primary monitor|secondary monitor|tertiary monitor) (workspaces|ws)$/d; /^# Auxiliary workspaces$/d' "$vars"
  if ! grep -q 'set $pws_q' "$vars"; then
    cat >> "$vars" <<'EOF'

# Workspaces (named like the bar in the pictures; written by dots.sh)
set $pws_q "1:Q:term"
set $pws_w "2:W:edit"
set $pws_e "3:E:www"
set $pws_1 "4:1"
set $pws_2 "5:2"
set $pws_3 "6:3"
set $pws_4 "7:4"
set $sws_a "8:A"
set $sws_s "9:S"
set $sws_d "10:D"
set $tws_f1 "11:F1"
set $tws_f2 "12:F2"
set $tws_f3 "13:F3"
set $aws_5 "14:5"
set $aws_6 "15:6"
set $aws_7 "16:7"
set $aws_8 "17:8"
set $aws_9 "18:9"
set $aws_0 "19:0"
set $aws_f4 "20:F4"
set $aws_f5 "21:F5"
set $aws_f6 "22:F6"
set $aws_f7 "23:F7"
set $aws_f8 "24:F8"
set $aws_f9 "25:F9"
set $aws_f10 "26:F10"
set $aws_f11 "27:F11"
set $aws_f12 "28:F12"
EOF
  fi

  # startup: our polybar launcher; i3wsr would rename the workspaces away from the pictures
  sed -i -E 's|^exec_always --no-startup-id \$HOME/scripts/launch-polybar.sh$|exec_always --no-startup-id $HOME/.config/polybar/launch.sh|' "$conf"
  sed -i -E '/^exec_always --no-startup-id \$HOME\/\.cargo\/bin\/i3wsr/d' "$conf"

  # workspace -> monitor lines come from ~/.i3/monitors.conf (written at login by etc-monitors)
  sed -i -E '/^workspace \$[a-z]+_[a-z0-9]+ output \$(primary|secondary|tertiary)_monitor$/d' "$conf"
  sed -i -E '/^assign \[class="\(\?i\)google-chrome-unstable"\] output /d' "$conf"
  put "$ETC_DIR/templates/i3/zz-monitors.i3" <<'EOF'

# Monitors {{{
# Written at every login by ~/bin/etc-monitors (primary + other screens).
include ~/.i3/monitors.conf
# }}}
EOF

  # current i3 syntax
  sed -i -E 's|^new_window pixel 1$|default_border pixel 1\ndefault_floating_border pixel 1|' "$conf"
  # screenshots: teiler is dead, flameshot is started by .xinitrc
  sed -i -E 's|^bindsym --release Print exec teiler$|bindsym --release Print exec --no-startup-id flameshot gui|' "$conf"
  # polybar 3.7 IPC
  sed -i -E 's|exec polybar-msg hook keyboard-layout 1$|exec --no-startup-id polybar-msg action "#keyboard-layout.hook.0"|' "$conf"
  # rofi through a wrapper that places it under the bar, full height (busy2.png)
  sed -i -E 's|^bindsym \$mod\+Tab .*|bindsym $mod+Tab   exec --no-startup-id ~/bin/etc-rofi -show combi|' "$conf"
  sed -i -E 's|^bindsym \$mod\+g .*|bindsym $mod+g     exec --no-startup-id ~/bin/etc-rofi calc|' "$conf"
  sed -i -E 's|^bindsym \$mod\+y .*|bindsym $mod+y     exec --no-startup-id ~/bin/etc-rofi clip|' "$conf"
  sed -i -E 's|^bindsym \$mod\+grave .*|bindsym $mod+grave exec --no-startup-id ~/bin/etc-rofi -show window|' "$conf"
  sed -i -E 's|^  bindsym w \[class="\(\?i\)termite"\] focus$|  bindsym w [class="(?i)alacritty"] focus|' "$conf"
  # snapshot bug: a window title matched as an id
  sed -i -E 's|^for_window \[id="Open Document"\]|for_window [title="Open Document"]|' "$conf"

  # Window colours sampled from busy2.png: pink focused title, dark #2D2B28 otherwise
  sed -i -E '/^client\.(focused|focused_inactive|unfocused|urgent) /d' "$conf"
  if ! grep -q '^client.focused ' "$conf"; then
    sed -i -E 's|^(client\.placeholder .*)$|client.focused          $magenta $magenta $bright_white $cyan    $magenta\nclient.focused_inactive #2D2B28  #2D2B28  $bright_white #2D2B28  #2D2B28\nclient.unfocused        #2D2B28  #2D2B28  $bright_white #2D2B28  #2D2B28\nclient.urgent           $yellow  $yellow  $black        $yellow  $yellow\n\1|' "$conf"
  fi
}

overlay_polybar() {
  local cfg="$ETC_DIR/conf/polybar/.config/polybar/config"
  local d="$ETC_DIR/conf/polybar/.config/polybar"

  # font names as they are packaged today
  sed -i -E 's/"fura code nerd font:/"FiraCode Nerd Font:/I
             s/"FontAwesome5Free:style=Solid:/"Font Awesome 6 Free:style=Solid:/
             s/"FontAwesome5Free:style=Regular:/"Font Awesome 6 Free:style=Regular:/
             s/"FontAwesome5Brands:style=Regular:/"Font Awesome 6 Brands:style=Regular:/' "$cfg"
  # meter segments: today's Iosevka draws ╸ as a dash; ◾ gives the squares in the pictures
  sed -i 's/╸/◾/g' "$cfg"
  # PipeWire/PulseAudio volume instead of raw ALSA
  sed -i -E '/^\[module\/volume\]$/,/^\[/{s/^type = internal\/alsa$/type = internal\/pulseaudio/}' "$cfg"
  # helper scripts shipped with the config instead of the retired roosta/scripts ones
  sed -i -E 's|^exec = ~/scripts/updates-arch-combined.sh$|exec = ~/.config/polybar/scripts/updates.sh|
             s|^hook-0 = ~/scripts/keyboard-layout.sh$|hook-0 = ~/.config/polybar/scripts/keyboard-layout.sh|
             s|^exec = ~/scripts/vpn.sh$|exec = ~/.config/polybar/scripts/vpn.sh|' "$cfg"

  if ! grep -q '^\[bar/ethan-primary\]' "$cfg"; then
    cat >> "$cfg" <<'EOF'

;; ---------------------------------------------------------------------------
;; ethan: the bar from the pictures on any monitor setup (written by dots.sh)
;; Started by ~/.config/polybar/launch.sh, which sets MONITOR and BAR_HEIGHT.
;; DPI follows Xft.dpi, so a 1080p screen looks like the 4K pictures, scaled.
;; ---------------------------------------------------------------------------
[bar/ethan-primary]
inherit = bar/lintilla-primary
monitor = ${env:MONITOR:}
dpi = ${xrdb:Xft.dpi:96}
height = ${env:BAR_HEIGHT:34}
background = #2D2B28
foreground = ${colors.brightblack}
wm-restack = i3
modules-left = i3-ethan xwindow
modules-center = mpd-ethan
modules-right = keyboard-layout vpncheck updates-arch-combined volume memory cpu date time

[bar/ethan-secondary]
inherit = bar/ethan-primary
modules-center =

[module/i3-ethan]
inherit = module/i3
label-focused-background = ${colors.magenta}
label-focused-foreground = ${colors.brightwhite}
label-unfocused-foreground = ${colors.brightwhite}
label-visible-foreground = ${colors.brightwhite}

[module/mpd-ethan]
inherit = module/mpd
host = 127.0.0.1
format-online = <label-song>
format-online-prefix = "♪ "
format-online-foreground = ${colors.brightblack}
label-song = %artist% - %title%
format-offline =
EOF
  fi

  put "$d/launch.sh" 755 <<'EOF'
#!/usr/bin/env bash
# Starts the bar from the pictures on every connected monitor (written by dots.sh)
cfg="$HOME/.config/polybar/config"
killall -q polybar
for _ in $(seq 50); do pgrep -u "$UID" -x polybar >/dev/null || break; sleep 0.1; done

dpi=$(xrdb -query 2>/dev/null | awk '/^Xft\.dpi:/ {printf "%d", $2; exit}')
[ -n "$dpi" ] || dpi=96
export BAR_HEIGHT=$(( (34 * dpi + 96) / 192 ))   # 34px at 192 dpi, as in the pictures

mapfile -t outs < <(xrandr --query 2>/dev/null | awk '/ connected/ {print $1}')
primary=$(xrandr --query 2>/dev/null | awk '/ connected primary/ {print $1; exit}')
[ -n "$primary" ] || primary="${outs[0]:-}"
log="${XDG_RUNTIME_DIR:-/tmp}/polybar"

if [ -z "$primary" ]; then
  polybar -c "$cfg" -r ethan-primary >"$log-primary.log" 2>&1 &
  exit 0
fi
MONITOR="$primary" polybar -c "$cfg" -r ethan-primary >"$log-primary.log" 2>&1 &
for o in "${outs[@]}"; do
  [ "$o" = "$primary" ] && continue
  MONITOR="$o" polybar -c "$cfg" -r ethan-secondary >"$log-$o.log" 2>&1 &
done
EOF

  put "$d/scripts/updates.sh" 755 <<'EOF'
#!/usr/bin/env bash
# "PKG: repo/aur" on the bar (written by dots.sh)
repo=$(checkupdates 2>/dev/null | wc -l)
aur=0
if command -v yay >/dev/null 2>&1; then aur=$(yay -Qua 2>/dev/null | wc -l); fi
echo "${repo}/${aur}"
EOF

  put "$d/scripts/keyboard-layout.sh" 755 <<'EOF'
#!/usr/bin/env bash
# Active keyboard layout, upper case: "US" (written by dots.sh)
layouts=$(setxkbmap -query 2>/dev/null | awk '/^layout:/ {print $2}')
current=${layouts%%,*}
if [ "$layouts" != "$current" ] && [ -x "$HOME/lib/xkblayout-state/xkblayout-state" ]; then
  current=$("$HOME/lib/xkblayout-state/xkblayout-state" print %s)
fi
echo "${current^^}"
EOF

  put "$d/scripts/vpn.sh" 755 <<'EOF'
#!/usr/bin/env bash
# Green "VPN" while a VPN/WireGuard link is up, grey otherwise (written by dots.sh)
if ip -o link show up 2>/dev/null | grep -qE ': (tun|tap|wg|ppp|proton|nordlynx|mullvad|tailscale)[^:]*:' \
   || nmcli -t -f TYPE connection show --active 2>/dev/null | grep -qE '^(vpn|wireguard)$'; then
  echo "%{F#98BC37}VPN%{F-}"
else
  echo "%{F#918175}VPN%{F-}"
fi
EOF
}

overlay_rofi() {
  # rofi 1.7 dropped width/lines/location/yoffset from config; the layout lives in the theme.
  put "$ETC_DIR/templates/rofi/config.rofi" <<'EOF'
/* vim: set ts=2 sw=2 tw=0 fdm=marker ft=css et :*/
/* ┳━┓┏━┓┳━┓o */
/* ┃┳┛┃ ┃┣━ ┃ */
/* ┇┗┛┛━┛┇  ┇   rofi 1.7 config (written by dots.sh) */

@theme "~/.config/rofi/srcery-etc.rasi"

configuration {
  modi: "combi,calc";
  combi-modi: "window,drun";
  terminal: "alacritty";
  show-icons: false;
  disable-history: false;
  window-format: "{w}    {c}    {t}";
  display-combi: "combi";
  display-calc: "calc";

  kb-accept-entry: "Return,KP_Enter";
  kb-remove-to-eol: "Control+q";
  kb-remove-char-back: "BackSpace,Shift+BackSpace";
  kb-mode-complete: "";
  kb-mode-next: "Shift+Right,Control+Tab,Control+l";
  kb-mode-previous: "Shift+Left,Control+ISO_Left_Tab,Control+h";
  kb-row-up: "Up,Control+k,ISO_Left_Tab";
  kb-row-down: "Down,Control+j";
  kb-element-prev: "";
  kb-page-prev: "Page_Up";
  kb-page-next: "Page_Down";
}
EOF

  put "$ETC_DIR/conf/rofi/.config/rofi/srcery-etc.rasi" <<'EOF'
/* Srcery rofi theme matching busy2.png (written by dots.sh).
 * Panel down the left fifth of the screen, under the bar. ~/bin/etc-rofi sets
 * y-offset/height/border for the current DPI. */
* {
  black:       #1C1B19;
  xgray1:      #262626;
  xgray2:      #2D2B28;
  white:       #918175;
  brightwhite: #FCE8C3;
  yellow:      #FBB829;
  magenta:     #E02C6D;
  orange:      #D75F00;

  background-color: transparent;
  text-color:       @brightwhite;
  spacing:          0;
}

window {
  location:         north west;
  anchor:           north west;
  x-offset:         0;
  y-offset:         17px;
  width:            20%;
  height:           calc( 100% - 17px );
  border:           1px;
  border-color:     @magenta;
  padding:          1px;
  background-color: @black;
}

mainbox {
  children: [ inputbar, listview, mode-switcher ];
  spacing:  0;
}

inputbar {
  children: [ prompt, textbox-prompt-colon, entry, case-indicator ];
  padding:  0.15em 0.1em;
}
prompt               { text-color: @brightwhite; }
textbox-prompt-colon { expand: false; str: ":"; text-color: @brightwhite; }
entry                { text-color: @brightwhite; cursor-color: @brightwhite; }
case-indicator       { text-color: @brightwhite; }

listview {
  border:       1px dash 0 0 0;
  border-color: @white;
  padding:      1px 0 0 0;
  lines:        200;
  fixed-height: false;
  dynamic:      true;
  scrollbar:    false;
  expand:       true;
}

element {
  padding: 0.04em 0.1em;
}
element-text {
  background-color: inherit;
  text-color:       inherit;
  highlight:        bold #E02C6D;
}
element normal.normal      { background-color: @xgray2;  text-color: @brightwhite; }
element alternate.normal   { background-color: @xgray1;  text-color: @brightwhite; }
element selected.normal    { background-color: @yellow;  text-color: @black; }
element normal.active      { background-color: @xgray2;  text-color: @yellow; }
element alternate.active   { background-color: @xgray1;  text-color: @yellow; }
element selected.active    { background-color: @yellow;  text-color: @black; }
element normal.urgent      { background-color: @orange;  text-color: @black; }
element alternate.urgent   { background-color: @orange;  text-color: @black; }
element selected.urgent    { background-color: @yellow;  text-color: @black; }

mode-switcher {
  border:       1px dash 0 0 0;
  border-color: @white;
  spacing:      0;
}
button {
  background-color: @black;
  text-color:       @brightwhite;
  horizontal-align: 0.5;
  padding:          0.05em 0;
}
button selected {
  background-color: @magenta;
  text-color:       @brightwhite;
}

message { border: 1px dash 0 0 0; border-color: @white; padding: 1px; }
textbox { text-color: @brightwhite; }
EOF
}

overlay_dunst() {
  # dunst >= 1.7 replaced geometry/shortcuts; same look as before, current keys.
  put "$ETC_DIR/templates/dunst/config.dunst" <<'EOF'
# dunst (written by dots.sh) - srcery, top right under the bar.
# "scale = 0" follows Xft.dpi, so sizes below are at 96 dpi.
[global]
    font = Iosevka 9
    monitor = 0
    follow = keyboard
    width = 300
    height = 300
    origin = top-right
    offset = 0x17
    scale = 0
    notification_limit = 10
    progress_bar = true
    indicate_hidden = yes
    transparency = 0
    separator_height = 1
    padding = 4
    horizontal_padding = 4
    frame_width = 1
    frame_color = "#E02C6D"
    separator_color = frame
    sort = yes
    idle_threshold = 120
    line_height = 0
    markup = full
    format = "<u>%a</u>\n<b>%s</b>\n%b\n%p"
    alignment = left
    vertical_alignment = center
    show_age_threshold = 60
    ellipsize = middle
    ignore_newline = no
    stack_duplicates = true
    hide_duplicate_count = false
    show_indicators = yes
    icon_position = left
    max_icon_size = 32
    sticky_history = yes
    history_length = 20
    dmenu = /usr/bin/rofi -dmenu -p dunst
    browser = /usr/bin/xdg-open
    always_run_script = true
    corner_radius = 0
    mouse_left_click = close_current
    mouse_middle_click = do_action, close_current
    mouse_right_click = close_all

[urgency_low]
    background = "#2D2B28"
    foreground = "#918175"
    timeout = 10

[urgency_normal]
    background = "#2D2B28"
    foreground = "#FCE8C3"
    timeout = 15

[urgency_critical]
    background = "#E02C6D"
    foreground = "#FCE8C3"
    frame_color = "#FBB829"
    timeout = 0
EOF
}

overlay_x() {
  local xi="$ETC_DIR/conf/x/.xinitrc"
  # US layout like the bar in the pictures (the snapshot toggled to Norwegian on Caps Lock)
  sed -i -E 's|^setxkbmap -model pc104 -layout us,no -option grp:caps_toggle -option terminate:ctrl_alt_bksp &$|setxkbmap -model pc104 -layout "${ETC_XKB_LAYOUT:-us}" -option terminate:ctrl_alt_bksp \&|' "$xi"
  # wallpaper on every monitor
  sed -i -E 's|^nitrogen --restore &$|if [ -x "$HOME/.fehbg" ]; then "$HOME/.fehbg" \& else nitrogen --restore \& fi|' "$xi"

  # bin: helpers used by i3 and the login scripts
  put "$ETC_DIR/conf/etc-bin/bin/etc-monitors" 755 <<'EOF'
#!/usr/bin/env bash
# Run at login (before i3): pick the primary monitor, set the DPI and tell i3
# which workspaces go where. Written by dots.sh.
#   DPI: $ETC_DPI or ~/.config/etc-dpi, else from the primary monitor's width
#        (4K -> 192 like the pictures, 1440p -> 120, otherwise 96).
command -v xrandr >/dev/null || exit 0
[ -x "$HOME/.screenlayout/main.sh" ] && "$HOME/.screenlayout/main.sh"

q=$(xrandr --query 2>/dev/null)
mapfile -t outs < <(printf '%s\n' "$q" | awk '/ connected/ {print $1}')
primary=$(printf '%s\n' "$q" | awk '/ connected primary/ {print $1; exit}')
if [ -z "$primary" ] && [ "${#outs[@]}" -gt 0 ]; then
  primary=${outs[0]}
  xrandr --output "$primary" --primary 2>/dev/null
fi

# extra monitors that X stacked on top of each other go to the right
if [ "${#outs[@]}" -gt 1 ]; then
  stacked=$(printf '%s\n' "$q" | awk '/ connected/ {for(i=3;i<=5;i++) if ($i ~ /^[0-9]+x[0-9]+\+0\+0$/) n++} END {print n+0}')
  if [ "$stacked" -gt 1 ]; then
    prev=$primary
    for o in "${outs[@]}"; do
      [ "$o" = "$primary" ] && continue
      xrandr --output "$o" --auto --right-of "$prev" 2>/dev/null && prev=$o
    done
  fi
fi

others=()
for o in "${outs[@]}"; do [ "$o" = "$primary" ] || others+=("$o"); done
p=${primary:-primary}; s1=${others[0]:-$p}; s2=${others[1]:-$s1}

dpi=${ETC_DPI:-}
[ -z "$dpi" ] && [ -r "$HOME/.config/etc-dpi" ] && dpi=$(tr -dc 0-9 < "$HOME/.config/etc-dpi")
if [ -z "$dpi" ]; then
  w=$(xrandr --query 2>/dev/null | awk -v o="$p" '$1==o {for(i=3;i<=5;i++) if (match($i,/^[0-9]+x/)) {split($i,a,"x"); print a[1]; exit}}')
  w=${w:-1920}
  if   [ "$w" -ge 3200 ]; then dpi=192
  elif [ "$w" -ge 2560 ]; then dpi=120
  else dpi=96; fi
fi
printf 'Xft.dpi: %s\n*dpi: %s\n' "$dpi" "$dpi" | xrdb -merge

mkdir -p "$HOME/.i3"
{
  echo "# generated by etc-monitors at $(date '+%F %T') - do not edit"
  for ws in "1:Q:term" "2:W:edit" "3:E:www" "4:1" "5:2" "6:3" "7:4"; do echo "workspace \"$ws\" output $p"; done
  for ws in "8:A" "9:S" "10:D"; do echo "workspace \"$ws\" output $s1 $p"; done
  for ws in "11:F1" "12:F2" "13:F3"; do echo "workspace \"$ws\" output $s2 $s1 $p"; done
} > "$HOME/.i3/monitors.conf"
EOF

  put "$ETC_DIR/conf/etc-bin/bin/etc-rofi" 755 <<'EOF'
#!/usr/bin/env bash
# rofi down the left of the screen, under the bar, like busy2.png (written by dots.sh)
#   etc-rofi -show combi | etc-rofi calc | etc-rofi clip | etc-rofi <any rofi args>
dpi=$(xrdb -query 2>/dev/null | awk '/^Xft\.dpi:/ {printf "%d", $2; exit}')
[ -n "$dpi" ] || dpi=96
bar=$(( (34 * dpi + 96) / 192 ))
b=$(( dpi / 96 )); [ "$b" -ge 1 ] || b=1
theme="window { y-offset: ${bar}px; height: calc( 100% - ${bar}px ); border: ${b}px; }"
case "${1:-}" in
  calc)
    shift
    exec rofi -dpi "$dpi" -theme-str "$theme" -show calc -modi calc -no-show-match -no-sort \
      -calc-command "echo -n '{result}' | xclip -selection clipboard" "$@" ;;
  clip)
    shift
    exec rofi -dpi "$dpi" -theme-str "$theme" -modi "clipmenu:env CM_LAUNCHER=rofi-script clipmenu" -show clipmenu "$@" ;;
  *)
    exec rofi -dpi "$dpi" -theme-str "$theme" "$@" ;;
esac
EOF
}

overlay_profile() {
  # A machine profile that adapts to whatever monitors this computer has.
  local p="$ETC_DIR/local/ethan"
  put "$p/variables.mk" <<'EOF'
# ethan: any monitor setup (written by dots.sh).
# Monitors and DPI are detected at login by ~/bin/etc-monitors, so they are not
# set here; fonts are in points and scale with Xft.dpi.
font = "Iosevka 9"
EOF
  put "$p/conf/x/.Xresources.local" <<'EOF'
! ethan (written by dots.sh). Xft.dpi is set at login by ~/bin/etc-monitors.
Xft.antialias: 1
Xft.hinting:   1
Xft.hintstyle: hintslight
Xft.rgba:      rgb
Xft.lcdfilter: lcddefault
Emacs.font: Iosevka Term-9

! vim:ft=xdefaults:ts=2:sw=2:fdm=marker
EOF
  put "$p/conf/x/.xinitrc.local" 755 <<'EOF'
# ethan (written by dots.sh): monitors, DPI and i3 workspace outputs
"$HOME/bin/etc-monitors"
# vim:ft=sh:ts=2:sw=2:fdm=marker
EOF
}

apply_overlay() {
  log "Applying fixes and the look from the pictures..."
  overlay_colors
  overlay_terminal
  overlay_i3
  overlay_polybar
  overlay_rofi
  overlay_dunst
  overlay_x
  overlay_profile
  etc_commit "dots.sh: fixes for current Arch + look from the pictures"
  [[ -f $ETC_DIR/local/$PROFILE/variables.mk ]] || die "Profile '${PROFILE}' not found in ${ETC_DIR}/local"
  printf '%s\n' "$PROFILE" > "${HOME}/.config/etc-profile" 2>/dev/null || { mkdir -p "${HOME}/.config"; printf '%s\n' "$PROFILE" > "${HOME}/.config/etc-profile"; }
  [[ -n $ETC_DPI ]] && printf '%s\n' "$ETC_DPI" > "${HOME}/.config/etc-dpi"
  ok "Overlay applied (profile: ${PROFILE})"
}

# -----------------------------------------------------------------------------
# 3. User filesystem layout (the Makefile's user-fs rule)
# -----------------------------------------------------------------------------
create_user_fs() {
  log "Creating the user filesystem layout..."
  local d
  for d in src lib mnt tmp bin sbin var/log var/vim/undo var/emacs/undo var/emacs/backup \
           .cache/zsh backup .local/share .local/bin .config .config/systemd/user \
           .i3 backgrounds Music Pictures/screenshots; do
    mkdir -p "${HOME}/${d}"
  done
  touch "${HOME}/.cache/zsh/dirs"
  [[ -e ${HOME}/.i3/monitors.conf ]] || : > "${HOME}/.i3/monitors.conf"
  mkdir -p "${ETC_DIR}/build"
  ok "Filesystem layout created"
}

# -----------------------------------------------------------------------------
# 4. Packages
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
    cd "${ETC_DIR}/build" && rm -rf yay-bin &&
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git &&
    cd yay-bin && makepkg -si --noconfirm --needed
  ) || { warn "Could not build yay - AUR packages will be skipped"; return 1; }
  ok "yay installed"
}

install_pacman_packages() {
  local list="${ETC_DIR}/pacman_packages.txt" p reason
  log "Installing official packages (anything not in the repos falls back to the AUR)..."

  local -a requested=() official=()
  mapfile -t requested < <({ printf '%s\n' "${EXTRA_PACMAN[@]}"; read_list "$list"; } | awk 'NF && !seen[$0]++')

  for p in "${requested[@]}"; do
    if reason="$(is_skipped "$p")"; then info "skip ${p} - ${reason}"; continue; fi
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
  mapfile -t queue < <({ printf '%s\n' "${AUR_QUEUE[@]}" "${EXTRA_AUR[@]}"; read_list "${ETC_DIR}/aur_packages.txt"; } | awk 'NF && !seen[$0]++')
  for p in "${queue[@]}"; do
    if reason="$(is_skipped "$p")"; then info "skip ${p} - ${reason}"; continue; fi
    pkg_installed "$p" && continue
    todo+=("$p")
  done
  ((${#todo[@]})) || return 0

  if ! have yay; then
    warn "yay unavailable - AUR packages not installed: ${todo[*]}"
    FAILED_PKGS+=("${todo[@]}"); return 0
  fi
  log "Installing AUR packages (${#todo[@]}) - this takes a while..."
  if [[ " ${todo[*]} " == *" spotify "* ]]; then
    curl -fsSL https://download.spotify.com/debian/pubkey_C85668DF69375001.gpg 2>/dev/null | gpg --import - >/dev/null 2>&1 \
      || info "could not import the Spotify signing key (the spotify build may fail)"
  fi
  local -a flags=(-S --needed --noconfirm --answerclean None --answerdiff None --answeredit None --removemake)
  for p in "${todo[@]}"; do      # one by one: a single broken AUR package must not stop the rest
    yay "${flags[@]}" "$p" </dev/null || FAILED_PKGS+=("$p")
  done
  ok "AUR packages done"
}

# aliases.zsh uses `exa` (the Git column in busy2.png); Arch now ships eza.
ensure_exa() {
  have exa && return 0
  if have eza; then
    ln -sfn "$(command -v eza)" "${HOME}/bin/exa"
    ok "exa is provided by eza (~/bin/exa)"
  fi
}

# Iosevka / Iosevka Term are in every picture; fetch them straight from the
# upstream release if the AUR packages did not deliver them.
fetch_release_fonts() {  # fetch_release_fonts <repo> <asset-pattern %s=version> <dir>
  local repo=$1 pattern=$2 dir=$3 tag ver url tmp
  tag="$(git ls-remote --tags --refs "https://github.com/${repo}" 'v*' 2>/dev/null \
         | awk -F/ '{print $3}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1)"
  [[ -n $tag ]] || return 1
  ver="${tag#v}"
  # shellcheck disable=SC2059
  url="https://github.com/${repo}/releases/download/${tag}/$(printf "$pattern" "$ver")"
  tmp="$(mktemp -d)"
  if curl -fsSL -o "$tmp/f.zip" "$url" && unzip -q -o "$tmp/f.zip" -d "$tmp/x"; then
    mkdir -p "$dir"
    find "$tmp/x" -name '*.ttf' -exec cp -f {} "$dir/" \;
    rm -rf "$tmp"; return 0
  fi
  rm -rf "$tmp"; return 1
}

font_has() {  # reads all of fc-list (grep -q + pipefail would report a false miss)
  fc-list : family 2>/dev/null | tr ',' '\n' | grep -x "$1" >/dev/null
}

ensure_fonts() {
  have fc-list || return 0
  local fdir="${HOME}/.local/share/fonts"
  if ! font_has 'Iosevka Term'; then
    log "Downloading Iosevka Term from github.com/be5invis/Iosevka..."
    fetch_release_fonts be5invis/Iosevka 'PkgTTF-IosevkaTerm-%s.zip' "$fdir/iosevka" \
      || warn "could not download Iosevka Term - terminals fall back to another monospace font"
  fi
  if ! font_has 'Iosevka'; then
    log "Downloading Iosevka from github.com/be5invis/Iosevka..."
    fetch_release_fonts be5invis/Iosevka 'PkgTTF-Iosevka-%s.zip' "$fdir/iosevka" \
      || warn "could not download Iosevka - i3/polybar/rofi fall back to another font"
  fi
  if ! font_has 'FiraCode Nerd Font'; then
    fetch_release_fonts ryanoasis/nerd-fonts 'FiraCode.zip' "$fdir/firacode-nerd" \
      || warn "could not install FiraCode Nerd Font (polybar icons)"
  fi
  fc-cache -f >/dev/null 2>&1 || true
}

remove_awesome() {
  ((KEEP_AWESOME)) && return 0
  if pkg_installed awesome; then
    log "Removing awesome (i3 is the window manager now)..."
    sudo pacman -Rns --noconfirm awesome >/dev/null 2>&1 \
      && ok "awesome removed" || warn "could not remove awesome (something depends on it) - i3 is still the default session"
  fi
}

# -----------------------------------------------------------------------------
# 5. Repositories in ~/lib and ~/src
# -----------------------------------------------------------------------------
sync_repo() {  # sync_repo <url> <parent> [branch] [dirname]
  local url=$1 parent=$2 branch=${3:-} name=${4:-}
  if [[ -z $name ]]; then name="${url##*/}"; name="${name%.git}"; fi
  local dest="${parent}/${name}"
  if [[ -d $dest/.git ]]; then
    git -C "$dest" pull --ff-only --quiet 2>/dev/null && info "updated ${name}" \
      || info "kept ${dest} as it is (local changes or offline)"
  elif [[ -e $dest ]]; then
    warn "${dest} exists and is not a git checkout - skipped"
  else
    local -a args=(clone --quiet --depth 1)
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
  sync_list "${HOME}/src" "${ETC_DIR}/src_repositories.txt"
  for u in "${EXTRA_SRC_REPOS[@]}"; do sync_repo "$u" "${HOME}/src"; done
  # tmux and the aliases call scripts that only live on the scripts repo's old branch
  sync_repo "$SCRIPTS_URL" "${HOME}/src" deprecated scripts-deprecated
  local main="${HOME}/src/scripts" dep="${HOME}/src/scripts-deprecated" f
  if [[ -d $main && -d $dep ]]; then
    for f in "$dep"/*.sh; do
      [[ -e $f ]] || continue
      f="${f##*/}"
      if [[ ! -e $main/$f ]]; then
        ln -sfn "$dep/$f" "$main/$f"
        grep -qxF "$f" "$main/.git/info/exclude" 2>/dev/null || printf '%s\n' "$f" >> "$main/.git/info/exclude"
      fi
    done
  fi
}

# -----------------------------------------------------------------------------
# 6. Misc symlinks (the Makefile's link-misc rule and friends)
# -----------------------------------------------------------------------------
link_if_present() {  # link_if_present <target> <linkname>
  local src=$1 dst=$2
  [[ -e $src ]] || return 0
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
  link_if_present "${HOME}/src/scripts-deprecated/chdisp-xrandr.sh" "$b/chdisp"
  link_if_present "${HOME}/lib/vidir/bin/vidir"        "$b/vidir"
  link_if_present "${HOME}/src/bakc/bakc.sh"           "$b/bakc"
  link_if_present "${HOME}/lib/LS_COLORS/LS_COLORS"    "${HOME}/.dircolors"

  if [[ ! -x $b/cht.sh ]]; then
    if curl -fsSL https://cht.sh/:cht.sh -o "$b/cht.sh"; then chmod +x "$b/cht.sh"
    else rm -f "$b/cht.sh"; info "could not download cht.sh (optional)"; fi
  fi
}

# -----------------------------------------------------------------------------
# 7. Link the configs with stow, backing up anything that is in the way
# -----------------------------------------------------------------------------
parse_stow_conflicts() {  # reads stow output on stdin, prints conflicting paths (relative to $HOME)
  sed -nE \
    -e 's/^[[:space:]]*\* existing target is (neither a link nor a directory|not owned by stow): (.+)$/\2/p' \
    -e 's/^[[:space:]]*\* cannot stow .+ over existing target (.+) since .*$/\1/p' \
    -e 's/^[[:space:]]*\* (existing target|cannot stow).* ([^ ]+)$/\2/p'
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
  for attempt in 1 2 3 4 5; do
    out="$(cd "$ETC_DIR" && stow --no-folding -R -t "$HOME" -d "$dir" "$@" "${pkgs[@]}" 2>&1)"; rc=$?
    if ((rc == 0)); then ok "linked ${#pkgs[@]} packages from ${dir}"; return 0; fi
    mapfile -t conflicts < <(parse_stow_conflicts <<<"$out" | awk 'NF && !seen[$0]++')
    if ((${#conflicts[@]} == 0)); then
      warn "stow failed for ${dir}: ${out}"; return 1
    fi
    backup_paths "${conflicts[@]}"
  done
  warn "stow still reports conflicts for ${dir} after backing files up: ${out}"
}

link_conf() {
  log "Linking configs with stow (old files are moved to ${BACKUP_DIR/#$HOME/~})..."
  # bash dotfiles from the distro are replaced by the repo's (the Makefile's save-originals)
  stow_dir conf --ignore="$STOW_IGNORE"
  stow_dir "local/${PROFILE}/conf"
  # i3 reads ~/.config/i3/config before ~/.i3/config when started by a display manager
  if [[ -e ${HOME}/.config/i3/config && ! -L ${HOME}/.config/i3/config ]]; then
    backup_paths .config/i3/config
  fi
  mkdir -p "${HOME}/.config/i3"
  ln -sfn "${HOME}/.i3/config" "${HOME}/.config/i3/config"
  # polybar prefers config.ini over config
  [[ -e ${HOME}/.config/polybar/config.ini && ! -L ${HOME}/.config/polybar/config.ini ]] && backup_paths .config/polybar/config.ini
  return 0
}

# The repo's ~/.gitconfig is roosta's identity with commit.gpgsign=true and includes
# ~/.gitconfig.local; keep the user's own identity there.
capture_git_identity() {
  GIT_PREV_NAME="${GIT_NAME:-}"; GIT_PREV_EMAIL="${GIT_EMAIL:-}"
  [[ -L ${HOME}/.gitconfig ]] && return 0
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
    echo "# Written by dots.sh - your identity, overriding the one in the shared ~/.gitconfig"
    echo "[user]"
    printf '\tname = %s\n'  "${GIT_PREV_NAME:-$USER}"
    if [[ -n $GIT_PREV_EMAIL ]]; then printf '\temail = %s\n' "$GIT_PREV_EMAIL"; else printf '\temail = %s@%s\n' "$USER" "$(uname -n)"; fi
    [[ -n $GIT_PREV_KEY ]] && printf '\tsigningkey = %s\n' "$GIT_PREV_KEY"
    echo "[commit]"
    printf '\tgpgsign = %s\n' "${GIT_PREV_SIGN:-false}"
  } > "$f"
  [[ -n $GIT_PREV_EMAIL ]] || warn "Put your real git email in ~/.gitconfig.local"
}

# ~/.pam_environment (SSH_AUTH_SOCK -> gpg-agent) is ignored by current PAM.
write_zprofile() {
  local f="${HOME}/.zprofile"
  if [[ -e $f ]] && grep -q 'SSH_AUTH_SOCK' "$f"; then return 0; fi
  cat >> "$f" <<'ZPROFILE'
# Added by dots.sh: ssh via gpg-agent (the repo sets this in ~/.pam_environment,
# which current PAM no longer reads).
export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR:-/run/user/$UID}/gnupg/S.gpg-agent.ssh"
ZPROFILE
}

# -----------------------------------------------------------------------------
# 8. Generate i3 / rofi / dunst with the repo's own Makefile rules
# -----------------------------------------------------------------------------
generate_configs() {
  log "Generating the i3, rofi and dunst configs..."
  mkdir -p "${HOME}/.config/rofi" "${HOME}/.config/dunst" "${HOME}/.i3"
  [[ -L ${HOME}/.i3/config ]] && rm -f "${HOME}/.i3/config"
  if (cd "$ETC_DIR" && make -B -o link-conf HOST="$PROFILE" \
        "${HOME}/.i3/config" "${HOME}/.config/rofi/config" "${HOME}/.config/dunst/dunstrc") >/dev/null; then
    ok "Generated ~/.i3/config, ~/.config/rofi/config.rasi and dunstrc"
  else
    warn "Generating the i3/rofi/dunst configs failed - run 'make HOST=${PROFILE} i3 rofi dunst' in ~/etc to see why"
  fi
  # rofi errors out on a missing mode; drop calc when the rofi-calc plugin is absent
  if ! ls /usr/lib/rofi/calc.so /usr/lib/*/rofi/calc.so >/dev/null 2>&1; then
    sed -i 's/modi: "combi,calc";/modi: "combi";/' "${HOME}/.config/rofi/config.rasi" 2>/dev/null
  fi
  if have i3; then
    local out
    out="$(i3 -C -c "${HOME}/.i3/config" 2>&1 | grep -E 'ERROR|error' | head -n 5)"
    [[ -z $out ]] || warn "i3 reports problems in ~/.i3/config: ${out}"
  fi
  if have i3-msg && pgrep -x i3 >/dev/null 2>&1; then i3-msg reload >/dev/null 2>&1 || true; fi
}

# i3's $locker points at a tiled background that is not in the repo.
ensure_locker_image() {
  local img="${HOME}/backgrounds/footer_lodyas.png"
  [[ -e $img ]] && return 0
  if have magick; then magick -size 8x8 'xc:#1C1B19' "$img"
  elif have convert; then convert -size 8x8 'xc:#1C1B19' "$img"
  else info "ImageMagick not found - the lock screen tile will be created on the next run"; fi
}

# -----------------------------------------------------------------------------
# 9. The wallpaper from clean.jpg (bar and terminal removed)
# -----------------------------------------------------------------------------
make_wallpaper() {
  if [[ ! -s $WALLPAPER ]]; then
    log "Building the wallpaper from clean.jpg..."
    local tmp; tmp="$(mktemp -d)"
    if curl -fsSL -o "$tmp/clean.jpg" "$CLEAN_JPG_URL"; then
      if have python3 && python3 -c 'import PIL, numpy' 2>/dev/null; then
        python3 -I - "$tmp/clean.jpg" "$WALLPAPER" <<'PY' || warn "wallpaper build failed"
import sys
import numpy as np
from PIL import Image
im = np.asarray(Image.open(sys.argv[1]).convert("RGB")).astype(float)
H = im.shape[0]
im[0:34] = im[34:68][::-1]                       # the bar: mirror the sky below it
x0, x1, y0, dx, f = 0, 1160, 1416, 1200, 36      # the terminal: star field from its right
patch = im[y0:H, x0 + dx:x1 + dx].copy()
h, w = patch.shape[:2]
ax = np.ones(w); ax[w - f:] = np.linspace(1, 0, f)
ay = np.ones(h); ay[:f] = np.linspace(0, 1, f)
a = np.outer(ay, ax)[..., None]
im[y0:H, x0:x1] = a * patch + (1 - a) * im[y0:H, x0:x1]
Image.fromarray(im.clip(0, 255).astype("uint8")).save(sys.argv[2], quality=95)
PY
      elif have magick || have convert; then
        local im; im="$(command -v magick || command -v convert)"
        "$im" "$tmp/clean.jpg" -crop 3840x1380+0+40 +repage -resize '3840x2160^' -gravity north -extent 3840x2160 "$WALLPAPER" \
          || warn "wallpaper build failed"
      else
        cp "$tmp/clean.jpg" "$WALLPAPER"
      fi
    else
      warn "could not download clean.jpg for the wallpaper - put any image at ${WALLPAPER/#$HOME/~}"
    fi
    rm -rf "$tmp"
  fi
  [[ -s $WALLPAPER ]] || return 0
  cat > "${HOME}/.fehbg" <<EOF
#!/bin/sh
feh --no-fehbg --bg-fill '${WALLPAPER}'
EOF
  chmod +x "${HOME}/.fehbg"
  mkdir -p "${HOME}/.config/nitrogen"
  printf '[xin_-1]\nfile=%s\nmode=5\nbgcolor=#1c1b19\n' "$WALLPAPER" > "${HOME}/.config/nitrogen/bg-saved.cfg"
  ok "Wallpaper: ${WALLPAPER/#$HOME/~}"
}

# -----------------------------------------------------------------------------
# 10. Programs that need more than a symlink
# -----------------------------------------------------------------------------
setup_ranger() {
  have ranger || { warn "ranger is not installed"; return 0; }
  log "Setting up ranger..."
  # The snapshot's commands.py / scope.sh are from ranger 1.7 and break on 1.9.
  local base dst="$ETC_DIR/conf/ranger/.config/ranger" f
  base="$(python3 -c 'import os, ranger; print(os.path.dirname(ranger.__file__))' 2>/dev/null)"
  if [[ -n $base && -f $base/config/commands.py ]]; then
    for f in commands.py commands_full.py; do
      [[ -f $base/config/$f ]] && cp -f "$base/config/$f" "$dst/$f"
    done
    for f in "$base/data/scope.sh" "$base/config/scope.sh"; do
      [[ -f $f ]] && { cp -f "$f" "$dst/scope.sh"; break; }
    done
    chmod +x "$dst/scope.sh"
    etc_commit "dots.sh: ranger commands/scope from the installed ranger"
    ok "ranger commands.py and scope.sh match the installed ranger"
  else
    warn "could not find ranger's bundled config - kept the snapshot's commands.py/scope.sh"
  fi
}

setup_gtk_theme() {
  local settings="$ETC_DIR/conf/gtk/.config/gtk-3.0/settings.ini" gtk2="$ETC_DIR/conf/gtk/.gtkrc-2.0"
  local colors="$ETC_DIR/conf/oomox/.config/oomox/colors/srcery"
  if [[ ! -d ${HOME}/.themes/oomox-srcery && ! -d /usr/share/themes/oomox-srcery ]]; then
    local cc
    for cc in /opt/oomox/plugins/theme_oomox/change_color.sh /opt/oomox/plugins/theme_oomox/gtk-theme/change_color.sh; do
      if [[ -x $cc && -f $colors ]]; then
        log "Building the oomox-srcery GTK theme..."
        "$cc" -o oomox-srcery "$colors" >/dev/null 2>&1 && break
      fi
    done
  fi
  if [[ -d ${HOME}/.themes/oomox-srcery || -d /usr/share/themes/oomox-srcery ]]; then
    ok "GTK theme: oomox-srcery"
  else
    sed -i 's/^gtk-theme-name=oomox-srcery$/gtk-theme-name=Adwaita-dark/; s/^gtk-icon-theme-name=oomox-srcery$/gtk-icon-theme-name=Adwaita/' "$settings"
    sed -i 's/^gtk-theme-name = "oomox-srcery"$/gtk-theme-name = "Adwaita-dark"/; s/^gtk-icon-theme-name = "oomox-srcery"$/gtk-icon-theme-name = "Adwaita"/' "$gtk2"
    etc_commit "dots.sh: GTK falls back to Adwaita-dark (oomox-srcery not built)"
    info "GTK theme: Adwaita-dark (oomox-srcery could not be built)"
  fi
}

setup_mopidy() {
  local f="${HOME}/.config/mopidy/mopidy.conf"
  [[ -e $f ]] && return 0
  mkdir -p "$(dirname "$f")" "${HOME}/Music"
  cat > "$f" <<'EOF'
# Written by dots.sh - music for ncmpcpp and the polybar song title.
# Put files in ~/Music.
[audio]
output = autoaudiosink

[file]
enabled = true
media_dirs = ~/Music|Music
show_dotfiles = false

[mpd]
enabled = true
hostname = 127.0.0.1
port = 6600

[http]
enabled = false

[spotify]
enabled = false
EOF
}

setup_bat() {
  have bat || return 0
  bat cache --build >/dev/null 2>&1 || true
}

setup_startpage() {
  ((DO_STARTPAGE)) || return 0
  local dir="${HOME}/src/startpage"
  if ! have lein || ! have npm || ! have java; then
    warn "start page skipped (needs leiningen, npm and java)"; return 0
  fi
  sync_repo "$STARTPAGE_URL" "${HOME}/src"
  [[ -d $dir ]] || return 0
  [[ -f ${HOME}/TODOs.org ]] || cp "$dir/TODOs.example.org" "${HOME}/TODOs.org" 2>/dev/null || true
  cat > "$dir/config.edn" <<EOF
{:reddit-feed-url "https://www.reddit.com/.json"
 :reddit-user "/u/${USER}"
 :server-port 8080
 :todo-file "${HOME}/TODOs.org"}
EOF
  if [[ ! -f $dir/target/prod/server.js ]]; then
    log "Building the Firefox start page (firefox.png) - first build takes a few minutes..."
    ( cd "$dir" && npm install --no-audit --no-fund >/dev/null 2>&1 && timeout 1800 lein min >/dev/null 2>&1 ) \
      || { warn "start page build failed - Firefox opens its normal home page"; return 0; }
  fi
  mkdir -p "${HOME}/.config/systemd/user"
  cat > "${HOME}/.config/systemd/user/startpage.service" <<'EOF'
[Unit]
Description=Start page for Firefox (http://localhost:8080)
After=network.target

[Service]
WorkingDirectory=%h/src/startpage
ExecStart=/usr/bin/node target/prod/server.js
Restart=on-failure

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now startpage.service >/dev/null 2>&1 \
    && ok "start page running on http://localhost:8080" \
    || info "start page enabled for your next login"
}

firefox_profile_dir() {
  local ini="${HOME}/.mozilla/firefox/profiles.ini"
  [[ -f $ini ]] || return 1
  python3 - "$ini" <<'PY'
import configparser, os, sys
ini = sys.argv[1]; base = os.path.dirname(ini)
c = configparser.ConfigParser(); c.read(ini)
path = None
for s in c.sections():                      # the profile this Firefox install opens
    if s.startswith("Install") and c[s].get("Default"):
        path = c[s]["Default"]; break
if not path:
    for s in c.sections():
        if s.startswith("Profile") and c[s].get("Default") == "1":
            path = c[s]["Path"]; break
if not path:
    for s in c.sections():
        if s.startswith("Profile"):
            path = c[s]["Path"]; break
if path:
    print(path if os.path.isabs(path) else os.path.join(base, path))
PY
}

setup_firefox() {
  have firefox || { info "Firefox not installed - skipping its theme"; return 0; }
  local css="${ETC_DIR}/conf/firefox/.mozilla/firefox/roosta/chrome/userChrome.css" prof
  prof="$(firefox_profile_dir 2>/dev/null)"
  if [[ -z $prof ]]; then
    # let Firefox create its normal default profile once, headless
    MOZ_HEADLESS=1 timeout 25 firefox --headless --no-remote about:blank >/dev/null 2>&1 || true
    pkill -u "$USER" -f 'firefox.*--headless' 2>/dev/null || true
    prof="$(firefox_profile_dir 2>/dev/null)"
  fi
  if [[ -z $prof || ! -d $prof ]]; then
    info "Firefox has no profile yet - re-run dots.sh --configs-only after starting Firefox once"; return 0
  fi
  mkdir -p "$prof/chrome"
  [[ -f $css ]] && ln -sfn "$css" "$prof/chrome/userChrome.css"
  local home="about:home"
  [[ -f ${HOME}/.config/systemd/user/startpage.service ]] && home="http://localhost:8080"
  local uj="$prof/user.js" tmp; tmp="$(mktemp)"
  [[ -f $uj ]] && sed '/^\/\/ >>> dots.sh/,/^\/\/ <<< dots.sh/d' "$uj" > "$tmp"
  cat >> "$tmp" <<EOF
// >>> dots.sh - dark compact Firefox with the srcery userChrome (firefox.png)
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
user_pref("extensions.activeThemeID", "firefox-compact-dark@mozilla.org");
user_pref("browser.theme.toolbar-theme", 0);
user_pref("browser.theme.content-theme", 0);
user_pref("layout.css.prefers-color-scheme.content-override", 0);
user_pref("browser.compactmode.show", true);
user_pref("browser.uidensity", 1);
user_pref("browser.startup.page", 1);
user_pref("browser.startup.homepage", "${home}");
user_pref("browser.aboutwelcome.enabled", false);
// <<< dots.sh
EOF
  mv -f "$tmp" "$uj"
  ok "Firefox: dark compact theme + userChrome.css in ${prof/#$HOME/~}"
}

# -----------------------------------------------------------------------------
# 11. Plugin managers and toolchains
# -----------------------------------------------------------------------------
setup_zplug() {
  have zsh || { warn "zsh is not installed - skipping zplug"; return 0; }
  if [[ ! -d ${HOME}/.zplug ]]; then
    log "Installing zplug..."
    git clone --quiet --depth 1 https://github.com/zplug/zplug "${HOME}/.zplug" \
      || { warn "could not clone zplug"; return 0; }
  fi
  log "Installing zsh plugins..."
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
    || info "tpm returned non-zero; press \` then I inside tmux to finish it"
}

setup_vim() {
  log "Installing vim / neovim plugins (vim-plug)..."
  if have vim; then
    [[ -f ${HOME}/.vim/autoload/plug.vim ]] || curl -fsSLo "${HOME}/.vim/autoload/plug.vim" --create-dirs \
      https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
    timeout 900 vim -N -E -s -u "${HOME}/.vimrc" -i NONE +'PlugInstall --sync' +qall </dev/null >/dev/null 2>&1 || true
    local hk="${HOME}/.vim/plugged/vim-hexokinase"
    if [[ -d $hk && ! -x $hk/hexokinase/hexokinase ]] && have go; then
      make -C "$hk" hexokinase >/dev/null 2>&1 || warn "vim-hexokinase could not be built (colour previews in vim)"
    fi
  fi
  if have nvim && [[ -f ${HOME}/.config/nvim/init.vim ]]; then
    local d="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/autoload/plug.vim"
    [[ -f $d ]] || curl -fsSLo "$d" --create-dirs https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
    timeout 900 nvim --headless +'PlugInstall --sync' +qa </dev/null >/dev/null 2>&1 || true
  fi
}

setup_rust_tools() {
  have rustup || return 0
  export PATH="${HOME}/.cargo/bin:${PATH}"
  rustup default stable >/dev/null 2>&1 || rustup install stable >/dev/null 2>&1 || warn "rustup could not install the stable toolchain"
}

setup_npm_tools() {
  have npm || return 0
  if [[ ! -x ${HOME}/.npm/bin/vtop ]]; then   # the system monitor in busy.png
    log "Installing vtop..."
    NPM_CONFIG_PREFIX="${HOME}/.npm" npm install -g vtop >/dev/null 2>&1 \
      || warn "npm install -g vtop failed (use htop instead)"
  fi
}

# -----------------------------------------------------------------------------
# 12. Session: i3 by default, login shell, services
# -----------------------------------------------------------------------------
set_session() {
  # Display managers do not read ~/.xinitrc; ~/.xprofile gets the same startup
  # programs (everything before the window manager part).
  local xi="${HOME}/.xinitrc"
  if [[ -f $xi ]]; then
    {
      echo "# Written by dots.sh from ~/.xinitrc - used when you log in through a display manager"
      sed '/^## WINDOW MANAGER/,$d' "$xi"
    } > "${HOME}/.xprofile"
  fi
  printf '[Desktop]\nSession=i3\n' > "${HOME}/.dmrc"
  if have sudo && [[ -d /var/lib/AccountsService ]]; then
    printf '[User]\nXSession=i3\nSession=i3\nSystemAccount=false\n' \
      | sudo tee "/var/lib/AccountsService/users/${USER}" >/dev/null 2>&1 || true
  fi
  if have sudo && [[ -f /var/lib/sddm/state.conf ]]; then
    sudo sed -i -E 's|^Session=.*|Session=/usr/share/xsessions/i3.desktop|' /var/lib/sddm/state.conf 2>/dev/null || true
  fi
  ok "i3 is the default session (tty1 login runs startx -> i3)"
}

set_shell() {
  have zsh || { warn "zsh not installed - login shell unchanged"; return 0; }
  local zsh_path current
  zsh_path="$(command -v zsh)"
  current="$(getent passwd "$USER" | cut -d: -f7)"
  [[ $current == */zsh ]] && return 0
  log "Changing the login shell to zsh..."
  grep -qx "$zsh_path" /etc/shells 2>/dev/null || printf '%s\n' "$zsh_path" | sudo tee -a /etc/shells >/dev/null
  sudo chsh -s "$zsh_path" "$USER" || warn "chsh failed - run: chsh -s ${zsh_path}"
}

enable_services() {
  local unit
  if have systemctl && [[ -n $USER_SERVICES ]]; then
    log "Enabling user services: ${USER_SERVICES}"
    systemctl --user daemon-reload 2>/dev/null || true
    for unit in $USER_SERVICES; do
      if systemctl --user enable --now "$unit" >/dev/null 2>&1; then ok "enabled ${unit}"
      elif systemctl --user enable "$unit" >/dev/null 2>&1; then info "enabled ${unit} (starts at your next login)"
      else warn "could not enable user unit ${unit}"; fi
    done
  fi
  if [[ -n $SYSTEM_SERVICES ]] && have sudo; then
    for unit in $SYSTEM_SERVICES; do
      sudo systemctl enable --now "${unit%.service}.service" >/dev/null 2>&1 \
        && ok "enabled ${unit}" || warn "could not enable system unit ${unit}"
    done
  fi
}

# -----------------------------------------------------------------------------
# 13. Wrap-up
# -----------------------------------------------------------------------------
summary() {
  rm -rf "${ETC_DIR}/build" 2>/dev/null || true
  echo
  if ((${#FAILED_PKGS[@]})); then
    printf '%sPackages that could not be installed (nothing in the pictures depends on them):%s\n' "$C_Y" "$C_N"
    printf '   %s\n' "${FAILED_PKGS[@]}"
    echo
  fi
  if ((${#WARNINGS[@]})); then
    printf '%sThings to look at:%s\n' "$C_Y" "$C_N"
    local w; for w in "${WARNINGS[@]}"; do printf '  - %s\n' "$w"; done
    echo
  fi
  printf '%s' "$C_M"
  cat <<EOF
Done. Log out and log back in on tty1 - X and i3 start by themselves.

  Super+Return  terminal (alacritty)     Super+Tab  rofi (combi / calc)
  Super+c       close window             Super+End  lock / logout / reboot
  Super+q/w/e   workspaces Q:term W:edit E:www, Super+1..4 the numbered ones
  Super+Shift+r restart i3               \` is the tmux prefix

  Re-apply configs any time:  bash dots.sh --configs-only
  Different DPI:              ETC_DPI=96 bash dots.sh --configs-only
EOF
  printf '%s' "$C_N"
}

main() {
  parse_args "$@"
  printf '\n%s' "$C_M"
  echo "╔══════════════════════════════════════════════════════════════════╗"
  echo "║  ethanetc dotfiles - i3 · polybar · alacritty · rofi · ranger    ║"
  echo "╚══════════════════════════════════════════════════════════════════╝"
  printf '%s\n' "$C_N"

  preflight
  fetch_dotfiles
  rewrite_home_paths
  create_user_fs
  apply_overlay

  if ((DO_PACKAGES)); then
    install_yay
    install_pacman_packages
    install_aur_packages
    remove_awesome
  fi
  ensure_exa
  ensure_fonts

  capture_git_identity
  ((DO_PACKAGES || DO_PLUGINS)) && sync_repositories
  link_misc
  setup_ranger
  setup_gtk_theme
  link_conf
  write_git_local
  write_zprofile
  generate_configs
  ensure_locker_image
  make_wallpaper
  setup_mopidy
  setup_bat

  if ((DO_PLUGINS)); then
    setup_zplug
    setup_tmux
    setup_vim
    setup_rust_tools
    setup_npm_tools
  fi
  setup_startpage
  setup_firefox

  set_session
  ((DO_PACKAGES)) && set_shell
  ((DO_SERVICES)) && enable_services
  summary
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
  main "$@"
fi
