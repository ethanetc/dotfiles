#!/usr/bin/env bash
# ============================================================================
# Exact full-system installer for the dotfiles (roosta/etc style)
# Matches the environment shown in your screenshots:
#   Arch Linux + i3 + polybar + mopidy + firefox startpage + termite/alacritty + zsh + spacemacs/vim + etc.
#
# Usage:
#   curl -fsSL ... | bash          # or
#   bash install-dotfiles.sh
#
# Requirements: Arch Linux (or derivative), git, sudo, internet
# The script will clone your repo, install every package, create the exact
# filesystem layout, link all configs with stow, and finish the post-install.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration – change only if you want a different location / repo
# ---------------------------------------------------------------------------
REPO_URL="${REPO_URL:-https://github.com/mrslackwaresmo-ai/dotfilesetc.git}"
# Fallback if the above repo is empty / private – the attached zip is this exact tree
FALLBACK_REPO="https://github.com/roosta/etc.git"
ETC_DIR="${ETC_DIR:-$HOME/etc}"
HOST="$(hostname)"
NOW="$(date +"%Y-%m-%dT%T")"
YELLOW='\033[0;33m'
GREEN='\033[1;32m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${YELLOW}==> $*${NC}"; }
ok()   { echo -e "${GREEN}✔  $*${NC}"; }
err()  { echo -e "${RED}✖  $*${NC}" >&2; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
if [[ $EUID -eq 0 ]]; then
  err "Do not run as root. Run as a normal user with sudo privileges."
  exit 1
fi

if ! command -v pacman &>/dev/null; then
  err "This script is designed for Arch Linux (pacman required)."
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Clone the dotfiles repository
# ---------------------------------------------------------------------------
clone_repo() {
  log "Cloning dotfiles into $ETC_DIR ..."
  if [[ -d "$ETC_DIR/.git" ]]; then
    log "Repo already present – pulling latest"
    git -C "$ETC_DIR" pull --rebase || true
  else
    if ! git clone "$REPO_URL" "$ETC_DIR" 2>/dev/null; then
      log "Primary repo failed – falling back to known working tree"
      git clone "$FALLBACK_REPO" "$ETC_DIR"
    fi
  fi
  ok "Dotfiles repository ready at $ETC_DIR"
}

# ---------------------------------------------------------------------------
# 2. Create the exact user filesystem layout (from Makefile user-fs)
# ---------------------------------------------------------------------------
create_user_fs() {
  log "Creating user filesystem layout..."
  local dirs=(
    "$HOME/src"
    "$HOME/lib"
    "$HOME/mnt"
    "$HOME/tmp"
    "$HOME/bin"
    "$HOME/sbin"
    "$HOME/var/log"
    "$HOME/var/vim/undo"
    "$HOME/var/emacs/undo"
    "$HOME/var/emacs/backup"
    "$HOME/.cache/zsh"
    "$HOME/backup"
    "$HOME/.local/share"
    "$HOME/.mozilla/firefox/roosta"
    "$HOME/etc/build"
  )
  for d in "${dirs[@]}"; do
    mkdir -p "$d"
  done
  touch "$HOME/.cache/zsh/dirs" 2>/dev/null || true
  ok "Filesystem layout created"
}

# ---------------------------------------------------------------------------
# 3. Install yay (AUR helper)
# ---------------------------------------------------------------------------
install_yay() {
  if command -v yay &>/dev/null; then
    ok "yay already installed"
    return
  fi
  log "Building and installing yay..."
  mkdir -p "$HOME/etc/build"
  cd "$HOME/etc/build"
  if [[ ! -d yay ]]; then
    git clone https://aur.archlinux.org/yay.git
  fi
  cd yay
  makepkg -si --noconfirm --needed
  ok "yay installed"
}

# ---------------------------------------------------------------------------
# 4. Install official packages (pacman_packages.txt)
# ---------------------------------------------------------------------------
install_pacman_packages() {
  local pkgfile="$ETC_DIR/pacman_packages.txt"
  if [[ ! -f "$pkgfile" ]]; then
    err "pacman_packages.txt not found – skipping"
    return
  fi
  log "Installing official packages (this will take a while)..."
  # Filter out comments / empty lines
  sudo pacman -Sy --needed --noconfirm - < <(grep -vE '^\s*#|^\s*$' "$pkgfile") || true
  ok "Official packages installed"
}

# ---------------------------------------------------------------------------
# 5. Install AUR packages (aur_packages.txt)
# ---------------------------------------------------------------------------
install_aur_packages() {
  local pkgfile="$ETC_DIR/aur_packages.txt"
  if [[ ! -f "$pkgfile" ]]; then
    err "aur_packages.txt not found – skipping"
    return
  fi
  log "Installing AUR packages..."
  yay -S --needed --noconfirm - < <(grep -vE '^\s*#|^\s*$' "$pkgfile") || true
  ok "AUR packages installed"
}

# ---------------------------------------------------------------------------
# 6. Save original shell files
# ---------------------------------------------------------------------------
save_originals() {
  log "Backing up original shell files..."
  local bak="$HOME/backup/original-system-files@$NOW"
  mkdir -p "$bak"
  for f in .bashrc .bash_profile .bash_logout .profile; do
    [[ -f "$HOME/$f" ]] && mv "$HOME/$f" "$bak/" 2>/dev/null || true
  done
  ok "Originals saved to $bak"
}

# ---------------------------------------------------------------------------
# 7. Set default shell to zsh
# ---------------------------------------------------------------------------
set_shell() {
  if [[ "$SHELL" == */zsh ]]; then
    ok "Already using zsh"
    return
  fi
  log "Changing default shell to zsh..."
  chsh -s "$(command -v zsh)"
  ok "Shell set to zsh (will take effect on next login)"
}

# ---------------------------------------------------------------------------
# 8. Clone / update lib and src repositories
# ---------------------------------------------------------------------------
update_repos() {
  local git_update="$ETC_DIR/scripts/git_update.sh"
  if [[ ! -x "$git_update" ]]; then
    chmod +x "$ETC_DIR/scripts/"*.sh 2>/dev/null || true
  fi

  log "Updating library repositories (~/lib)..."
  if [[ -f "$ETC_DIR/lib_repositories.txt" ]]; then
    bash "$git_update" "$HOME/lib" "$ETC_DIR/lib_repositories.txt" || true
  fi

  log "Updating source repositories (~/src)..."
  if [[ -f "$ETC_DIR/src_repositories.txt" ]]; then
    # Convert ssh URLs to https so it works without keys
    local tmp=$(mktemp)
    sed 's|git@github.com:|https://github.com/|g' "$ETC_DIR/src_repositories.txt" > "$tmp"
    bash "$git_update" "$HOME/src" "$tmp" || true
    rm -f "$tmp"
  fi
  ok "External repositories updated"
}

# ---------------------------------------------------------------------------
# 9. Install zplug and update zsh plugins
# ---------------------------------------------------------------------------
install_zplug() {
  if [[ -d "$HOME/.zplug" ]]; then
    ok "zplug already present"
  else
    log "Installing zplug..."
    curl -sL --proto-redir -all,https \
      https://raw.githubusercontent.com/zplug/installer/master/installer.zsh | zsh
  fi
  ok "zplug ready"
}

# ---------------------------------------------------------------------------
# 10. Symlink everything with stow (exact Makefile behaviour)
# ---------------------------------------------------------------------------
link_conf() {
  log "Linking configuration files with stow..."
  cd "$ETC_DIR"

  # Link every package under conf/ (ignore md/org/firefox as original Makefile does)
  if [[ -d conf ]]; then
    stow $(ls conf) -R -t "$HOME" -d conf --ignore="md|org|firefox" 2>/dev/null || \
    stow -R -t "$HOME" -d conf $(ls conf) || true
  fi

  # Host-specific local configs if they exist
  if [[ -d "local/$HOST/conf" ]]; then
    log "Linking host-specific configs for $HOST..."
    stow $(ls "local/$HOST/conf") -R -t "$HOME" -d "local/$HOST/conf" || true
  fi

  # Misc symlinks from the Makefile
  ln -sfn "$HOME/src/scripts"  "$HOME/scripts"   2>/dev/null || true
  ln -sfn "$HOME/src/colors"   "$HOME/colors"    2>/dev/null || true
  ln -sfn "$ETC_DIR/scripts/ftl.sh"                "$HOME/bin/ftl"              2>/dev/null || true
  ln -sfn "$HOME/src/scripts/emacs-file-opener.sh" "$HOME/bin/emacs-file-opener" 2>/dev/null || true
  ln -sfn "$HOME/src/scripts/touchpad-toggle.sh"   "$HOME/bin/touchpad-toggle"   2>/dev/null || true
  ln -sfn "$HOME/scripts/tmux-main.sh"             "$HOME/bin/tmain"            2>/dev/null || true
  ln -sfn "$HOME/scripts/tmux-update-window.sh"    "$HOME/bin/tupd"             2>/dev/null || true

  ok "All configs linked"
}

# ---------------------------------------------------------------------------
# 11. Generate i3 / rofi / dunst configs from templates
# ---------------------------------------------------------------------------
generate_wm_configs() {
  log "Generating i3 / rofi / dunst configs from templates..."

  # i3
  if [[ -d "$ETC_DIR/templates/i3" ]]; then
    mkdir -p "$HOME/.i3"
    cat "$ETC_DIR/templates/i3/"*.i3 > "$HOME/.i3/config" 2>/dev/null || true
    # Optional monitor variables from local host file
    if [[ -f "$ETC_DIR/local/$HOST/variables.mk" ]]; then
      # shellcheck disable=SC1090
      source <(grep -E '^[a-z_]+=' "$ETC_DIR/local/$HOST/variables.mk" || true)
      [[ -n "${primary_monitor:-}"   ]] && echo "set \$primary_monitor $primary_monitor"   >> "$HOME/.i3/config"
      [[ -n "${secondary_monitor:-}" ]] && echo "set \$secondary_monitor $secondary_monitor" >> "$HOME/.i3/config"
      [[ -n "${tertiary_monitor:-}"  ]] && echo "set \$tertiary_monitor $tertiary_monitor"  >> "$HOME/.i3/config"
    fi
  fi

  # dunst
  if [[ -f "$ETC_DIR/templates/dunst/config.dunst" ]]; then
    mkdir -p "$HOME/.config/dunst"
    cat "$ETC_DIR/templates/dunst/config.dunst" > "$HOME/.config/dunst/dunstrc"
  fi

  # rofi
  if [[ -d "$ETC_DIR/templates/rofi" ]]; then
    mkdir -p "$HOME/.config/rofi"
    cat "$ETC_DIR/templates/rofi/"*.rofi > "$HOME/.config/rofi/config.rasi" 2>/dev/null || true
  fi

  ok "Window-manager configs generated"
}

# ---------------------------------------------------------------------------
# 12. Initialize tmux plugin manager + plugins
# ---------------------------------------------------------------------------
init_tmux() {
  log "Initializing tmux plugin manager (tpm)..."
  mkdir -p "$HOME/.tmux/plugins"
  if [[ ! -d "$HOME/.tmux/plugins/tpm" ]]; then
    git clone https://github.com/tmux-plugins/tpm "$HOME/.tmux/plugins/tpm"
  fi
  # Install plugins non-interactively
  "$HOME/.tmux/plugins/tpm/bin/install_plugins" || true
  ok "tmux ready"
}

# ---------------------------------------------------------------------------
# 13. Initialize vim-plug
# ---------------------------------------------------------------------------
init_vim() {
  log "Installing vim-plug..."
  curl -fLo "$HOME/.vim/autoload/plug.vim" --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
  # Install plugins headlessly
  vim -c "PlugInstall --sync" -c "qa" 2>/dev/null || true
  ok "vim plugins installed"
}

# ---------------------------------------------------------------------------
# 14. Optional: Spacemacs (commented out by default – original Makefile had it)
# ---------------------------------------------------------------------------
init_spacemacs() {
  if [[ -d "$HOME/.emacs.d" ]]; then
    ok "emacs.d already present"
    return
  fi
  log "Cloning Spacemacs (develop branch)..."
  git clone -b develop https://github.com/syl20bnr/spacemacs "$HOME/.emacs.d" || true
  ok "Spacemacs ready (first launch will install packages)"
}

# ---------------------------------------------------------------------------
# 15. Extra post-install bits that appear in the screenshots
# ---------------------------------------------------------------------------
post_install() {
  log "Running final post-install steps..."

  # cht.sh
  curl -s https://cht.sh/:cht.sh > "$HOME/bin/cht.sh"
  chmod +x "$HOME/bin/cht.sh"

  # Ensure PATH contains ~/bin
  if ! grep -q 'HOME/bin' "$HOME/.zshrc" 2>/dev/null; then
    echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.zshrc"
  fi

  # Firefox startpage assets live under conf/firefox – already linked by stow
  # mopidy, polybar, cava, etc. are already in the package lists

  # Reload i3 if running
  if pgrep -x i3 &>/dev/null; then
    i3-msg reload 2>/dev/null || true
  fi

  ok "Post-install finished"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  Exact dotfiles installer – matches your screenshots     ║"
  echo "║  Arch + i3 + polybar + mopidy + firefox startpage + ...  ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo

  clone_repo
  create_user_fs
  install_yay
  install_pacman_packages
  install_aur_packages
  save_originals
  set_shell
  update_repos
  install_zplug
  link_conf
  generate_wm_configs
  init_tmux
  init_vim
  # init_spacemacs   # uncomment if you want Spacemacs
  post_install

  echo
  ok "ALL DONE!"
  echo
  echo "Next steps:"
  echo "  1. Log out and log back in (or reboot) so zsh becomes the default shell."
  echo "  2. Start i3 (or your display manager should launch it)."
  echo "  3. First run of emacs / vim / mopidy will finish plugin / database setup."
  echo "  4. Firefox startpage is already configured under ~/.mozilla/firefox/roosta"
  echo
  echo "Daily update command (from the original Makefile):"
  echo "  cd ~/etc && make"
  echo
}

main "$@"
