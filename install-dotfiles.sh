#!/usr/bin/env bash
# ============================================================================
# Exact full-system installer for the "etc" dotfiles
# Matches the environment in your screenshots:
#   Arch Linux · i3 · polybar · mopidy · firefox startpage · termite · zsh · vim/emacs
#
# Usage:
#   bash install-dotfiles.sh
#   # or
#   REPO_URL=https://github.com/you/dotfilesetc.git bash install-dotfiles.sh
#
# Requirements: Arch Linux (or derivative), git, sudo, internet
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REPO_URL="${REPO_URL:-https://github.com/mrslackwaresmo-ai/dotfilesetc.git}"
FALLBACK_REPO="https://github.com/roosta/etc.git"
ETC_DIR="${ETC_DIR:-$HOME/etc}"

# hostname is not always present on minimal installs – never fail under set -e
HOST="localhost"
if command -v hostname >/dev/null 2>&1; then
  HOST="$(hostname 2>/dev/null)" || true
elif [[ -r /etc/hostname ]]; then
  HOST="$(tr -d '[:space:]' </etc/hostname 2>/dev/null)" || true
elif command -v uname >/dev/null 2>&1; then
  HOST="$(uname -n 2>/dev/null)" || true
fi
[[ -z "${HOST}" ]] && HOST="localhost"
NOW="$(date +"%Y-%m-%dT%T")"

YELLOW='\033[0;33m'
GREEN='\033[1;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${YELLOW}==> \( * \){NC}"; }
ok()   { echo -e "${GREEN}✔  \( * \){NC}"; }
err()  { echo -e "${RED}✖  \( * \){NC}" >&2; }
info() { echo -e "${CYAN}·  \( * \){NC}"; }

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
preflight() {
  if [[ $EUID -eq 0 ]]; then
    err "Do not run as root. Run as a normal user with sudo privileges."
    exit 1
  fi
  if ! command -v pacman &>/dev/null; then
    err "This script requires Arch Linux (pacman)."
    exit 1
  fi
  if ! command -v git &>/dev/null; then
    log "Installing git..."
    sudo pacman -S --noconfirm --needed git
  fi
  if ! command -v stow &>/dev/null; then
    log "Installing stow (needed for linking)..."
    sudo pacman -S --noconfirm --needed stow
  fi
  ok "Pre-flight checks passed"
}

# ---------------------------------------------------------------------------
# 1. Clone repository
# ---------------------------------------------------------------------------
clone_repo() {
  log "Cloning dotfiles into ${ETC_DIR}..."
  if [[ -d "${ETC_DIR}/.git" ]]; then
    info "Repo already present – pulling latest"
    git -C "${ETC_DIR}" pull --rebase || true
  else
    if ! git clone "\( {REPO_URL}" " \){ETC_DIR}" 2>/dev/null; then
      log "Primary repo unavailable – using fallback"
      git clone "\( {FALLBACK_REPO}" " \){ETC_DIR}"
    fi
  fi
  # Make scripts executable
  chmod +x "${ETC_DIR}/scripts/"*.sh 2>/dev/null || true
  ok "Repository ready at ${ETC_DIR}"
}

# ---------------------------------------------------------------------------
# 2. Create user filesystem layout (exact Makefile user-fs)
# ---------------------------------------------------------------------------
create_user_fs() {
  log "Creating user filesystem layout..."
  local dirs=(
    "${HOME}/src"
    "${HOME}/lib"
    "${HOME}/mnt"
    "${HOME}/tmp"
    "${HOME}/bin"
    "${HOME}/sbin"
    "${HOME}/var/log"
    "${HOME}/var/vim/undo"
    "${HOME}/var/emacs/undo"
    "${HOME}/var/emacs/backup"
    "${HOME}/.cache/zsh"
    "${HOME}/backup"
    "${HOME}/.local/share"
    "${HOME}/.mozilla/firefox/roosta"
    "${HOME}/etc/build"
    "${HOME}/.config/systemd/user"
  )
  for d in "${dirs[@]}"; do
    mkdir -p "${d}"
  done
  touch "${HOME}/.cache/zsh/dirs" 2>/dev/null || true
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

  # base-devel provides fakeroot, debugedit, make, gcc, etc. required by makepkg
  log "Installing base-devel (required to build AUR packages)..."
  sudo pacman -S --noconfirm --needed base-devel git

  log "Building and installing yay..."
  mkdir -p "${HOME}/etc/build"
  (
    cd "${HOME}/etc/build"
    # Clean any previous failed build
    rm -rf yay
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm --needed
  )
  ok "yay installed"
}

# ---------------------------------------------------------------------------
# 4. Install official packages
# ---------------------------------------------------------------------------
install_pacman_packages() {
  local pkgfile="${ETC_DIR}/pacman_packages.txt"
  if [[ ! -f "${pkgfile}" ]]; then
    err "pacman_packages.txt not found – skipping"
    return
  fi
  log "Installing official packages (this takes a while)..."
  # Filter comments and blank lines
  sudo pacman -Sy --needed --noconfirm - < <(grep -vE '^\s*(#|\( )' " \){pkgfile}") || true
  ok "Official packages installed"
}

# ---------------------------------------------------------------------------
# 5. Install AUR packages
# ---------------------------------------------------------------------------
install_aur_packages() {
  local pkgfile="${ETC_DIR}/aur_packages.txt"
  if [[ ! -f "${pkgfile}" ]]; then
    err "aur_packages.txt not found – skipping"
    return
  fi
  log "Installing AUR packages..."
  yay -S --needed --noconfirm - < <(grep -vE '^\s*(#|\( )' " \){pkgfile}") || true
  ok "AUR packages installed"
}

# ---------------------------------------------------------------------------
# 6. Backup original shell files
# ---------------------------------------------------------------------------
save_originals() {
  log "Backing up original shell files..."
  local bak="\( {HOME}/backup/original-system-files@ \){NOW}"
  mkdir -p "${bak}"
  for f in .bashrc .bash_profile .bash_logout .profile .zshrc; do
    [[ -f "\( {HOME}/ \){f}" && ! -L "\( {HOME}/ \){f}" ]] && \
      mv "\( {HOME}/ \){f}" "${bak}/" 2>/dev/null || true
  done
  ok "Originals saved to ${bak}"
}

# ---------------------------------------------------------------------------
# 7. Set default shell to zsh
# ---------------------------------------------------------------------------
set_shell() {
  local zsh_path
  zsh_path="$(command -v zsh)"
  if [[ "${SHELL}" == */zsh ]]; then
    ok "Already using zsh"
    return
  fi
  if [[ -z "${zsh_path}" ]]; then
    err "zsh not found – install it first"
    return
  fi
  log "Changing default shell to zsh..."
  chsh -s "${zsh_path}"
  ok "Shell set to zsh (takes effect on next login)"
}

# ---------------------------------------------------------------------------
# 8. Clone / update external repositories
# ---------------------------------------------------------------------------
update_repos() {
  local git_update="${ETC_DIR}/scripts/git_update.sh"

  log "Updating library repositories (\~/lib)..."
  if [[ -f "${ETC_DIR}/lib_repositories.txt" ]]; then
    bash "\( {git_update}" " \){HOME}/lib" "${ETC_DIR}/lib_repositories.txt" || true
  fi

  log "Updating source repositories (\~/src)..."
  if [[ -f "${ETC_DIR}/src_repositories.txt" ]]; then
    # Convert git@ → https so it works without SSH keys
    local tmp
    tmp="$(mktemp)"
    sed 's|git@github.com:|https://github.com/|g' \
      "\( {ETC_DIR}/src_repositories.txt" > " \){tmp}"
    bash "\( {git_update}" " \){HOME}/src" "${tmp}" || true
    rm -f "${tmp}"
  fi
  ok "External repositories updated"
}

# ---------------------------------------------------------------------------
# 9. Install zplug
# ---------------------------------------------------------------------------
install_zplug() {
  if [[ -d "${HOME}/.zplug" ]]; then
    ok "zplug already present"
    return
  fi
  log "Installing zplug..."
  curl -sL --proto-redir -all,https \
    https://raw.githubusercontent.com/zplug/installer/master/installer.zsh | zsh
  ok "zplug installed"
}

# ---------------------------------------------------------------------------
# 10. Symlink everything with stow (exact Makefile behaviour)
# ---------------------------------------------------------------------------
link_conf() {
  log "Linking configuration files with stow..."
  cd "${ETC_DIR}"

  # Link every package under conf/
  # Original Makefile ignores md|org|firefox
  if [[ -d conf ]]; then
    # shellcheck disable=SC2046
    stow \( (ls conf) -R -t " \){HOME}" -d conf --ignore="md|org|firefox" 2>/dev/null || \
    stow -R -t "${HOME}" -d conf $(ls conf) || true
  fi

  # Host-specific local configs
  if [[ -d "local/${HOST}/conf" ]]; then
    info "Linking host-specific configs for ${HOST}..."
    # shellcheck disable=SC2046
    stow \( (ls "local/ \){HOST}/conf") -R -t "\( {HOME}" -d "local/ \){HOST}/conf" || true
  fi

  # Misc symlinks from the original Makefile
  ln -sfn "\( {HOME}/src/scripts"                     " \){HOME}/scripts"              2>/dev/null || true
  ln -sfn "\( {HOME}/src/colors"                      " \){HOME}/colors"               2>/dev/null || true
  ln -sfn "\( {ETC_DIR}/scripts/ftl.sh"               " \){HOME}/bin/ftl"              2>/dev/null || true
  ln -sfn "\( {HOME}/src/scripts/emacs-file-opener.sh" " \){HOME}/bin/emacs-file-opener" 2>/dev/null || true
  ln -sfn "\( {HOME}/src/scripts/touchpad-toggle.sh"  " \){HOME}/bin/touchpad-toggle"  2>/dev/null || true
  ln -sfn "\( {HOME}/scripts/tmux-main.sh"            " \){HOME}/bin/tmain"            2>/dev/null || true
  ln -sfn "\( {HOME}/scripts/tmux-update-window.sh"   " \){HOME}/bin/tupd"             2>/dev/null || true
  ln -sfn "\( {HOME}/scripts/tmux-ssh.sh"             " \){HOME}/bin/tssh"             2>/dev/null || true
  ln -sfn "\( {HOME}/scripts/tmux-music.sh"           " \){HOME}/bin/tmusic"           2>/dev/null || true

  ok "All configs linked"
}

# ---------------------------------------------------------------------------
# 11. Generate i3 / rofi / dunst configs from templates
# ---------------------------------------------------------------------------
generate_wm_configs() {
  log "Generating window-manager configs from templates..."

  # i3
  if [[ -d "${ETC_DIR}/templates/i3" ]]; then
    mkdir -p "${HOME}/.i3"
    cat "\( {ETC_DIR}/templates/i3/"*.i3 > " \){HOME}/.i3/config" 2>/dev/null || true

    if [[ -f "\( {ETC_DIR}/local/ \){HOST}/variables.mk" ]]; then
      # shellcheck disable=SC1090
      source <(grep -E '^[a-z_]+=' "\( {ETC_DIR}/local/ \){HOST}/variables.mk" || true)
      [[ -n "${primary_monitor:-}"   ]] && echo "set \$primary_monitor \( {primary_monitor}"   >> " \){HOME}/.i3/config"
      [[ -n "${secondary_monitor:-}" ]] && echo "set \$secondary_monitor \( {secondary_monitor}" >> " \){HOME}/.i3/config"
      [[ -n "${tertiary_monitor:-}"  ]] && echo "set \$tertiary_monitor \( {tertiary_monitor}"  >> " \){HOME}/.i3/config"
    fi
  fi

  # dunst
  if [[ -f "${ETC_DIR}/templates/dunst/config.dunst" ]]; then
    mkdir -p "${HOME}/.config/dunst"
    cat "\( {ETC_DIR}/templates/dunst/config.dunst" > " \){HOME}/.config/dunst/dunstrc"
  fi

  # rofi
  if [[ -d "${ETC_DIR}/templates/rofi" ]]; then
    mkdir -p "${HOME}/.config/rofi"
    cat "\( {ETC_DIR}/templates/rofi/"*.rofi > " \){HOME}/.config/rofi/config.rasi" 2>/dev/null || true
  fi

  ok "Window-manager configs generated"
}

# ---------------------------------------------------------------------------
# 12. Initialize tmux plugin manager
# ---------------------------------------------------------------------------
init_tmux() {
  log "Initializing tmux plugin manager (tpm)..."
  mkdir -p "${HOME}/.tmux/plugins"
  if [[ ! -d "${HOME}/.tmux/plugins/tpm" ]]; then
    git clone https://github.com/tmux-plugins/tpm "${HOME}/.tmux/plugins/tpm"
  fi
  "${HOME}/.tmux/plugins/tpm/bin/install_plugins" 2>/dev/null || true
  ok "tmux ready"
}

# ---------------------------------------------------------------------------
# 13. Initialize vim-plug
# ---------------------------------------------------------------------------
init_vim() {
  log "Installing vim-plug..."
  curl -fLo "${HOME}/.vim/autoload/plug.vim" --create-dirs \
    https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
  vim -c "PlugInstall --sync" -c "qa" 2>/dev/null || true
  ok "vim plugins installed"
}

# ---------------------------------------------------------------------------
# 14. Optional Spacemacs
# ---------------------------------------------------------------------------
init_spacemacs() {
  if [[ -d "${HOME}/.emacs.d" ]]; then
    ok "emacs.d already present"
    return
  fi
  log "Cloning Spacemacs (develop branch)..."
  git clone -b develop https://github.com/syl20bnr/spacemacs "${HOME}/.emacs.d" || true
  ok "Spacemacs ready (first launch installs packages)"
}

# ---------------------------------------------------------------------------
# 15. Enable system + user services
# ---------------------------------------------------------------------------
enable_services() {
  log "Enabling system and user services..."

  # ----- System services -----
  local system_services=(
    NetworkManager
    sshd
    ufw
  )

  for svc in "${system_services[@]}"; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1 || \
       systemctl cat "${svc}.service" &>/dev/null 2>&1; then
      if sudo systemctl enable --now "${svc}.service" 2>/dev/null; then
        ok "System service enabled: ${svc}"
      else
        info "Could not enable ${svc} (may already be active)"
      fi
    else
      info "System unit ${svc}.service not found – skipping"
    fi
  done

  # UFW safe defaults
  if command -v ufw &>/dev/null; then
    sudo ufw --force enable          2>/dev/null || true
    sudo ufw default deny incoming   2>/dev/null || true
    sudo ufw default allow outgoing  2>/dev/null || true
    sudo ufw allow ssh               2>/dev/null || true
    ok "UFW enabled with basic rules"
  fi

  # ----- User services (linked by stow into \~/.config/systemd/user/) -----
  systemctl --user daemon-reload 2>/dev/null || true

  local user_services=(
    emacs.service
    mopidy-user.service
    ssh-agent.service
    tmux.service
  )

  for svc in "${user_services[@]}"; do
    if [[ -f "\( {HOME}/.config/systemd/user/ \){svc}" ]] || \
       systemctl --user cat "${svc}" &>/dev/null 2>&1; then
      if systemctl --user enable --now "${svc}" 2>/dev/null; then
        ok "User service enabled: ${svc}"
      else
        info "Could not start ${svc} yet (needs a logged-in session)"
        systemctl --user enable "${svc}" 2>/dev/null || true
      fi
    else
      info "User unit ${svc} not found – available after next login"
    fi
  done

  # Linger so user services start at boot
  if command -v loginctl &>/dev/null; then
    sudo loginctl enable-linger "${USER}" 2>/dev/null || true
    ok "User lingering enabled"
  fi

  ok "Services configured"
}

# ---------------------------------------------------------------------------
# 16. Final post-install
# ---------------------------------------------------------------------------
post_install() {
  log "Running final post-install steps..."

  # cht.sh helper
  curl -s https://cht.sh/:cht.sh > "${HOME}/bin/cht.sh"
  chmod +x "${HOME}/bin/cht.sh"

  # Ensure \~/bin is on PATH
  if [[ -f "\( {HOME}/.zshrc" ]] && ! grep -q 'HOME/bin' " \){HOME}/.zshrc" 2>/dev/null; then
    echo 'export PATH="$HOME/bin:\( PATH"' >> " \){HOME}/.zshrc"
  fi

  # SSH agent socket for the user service
  if [[ -f "\( {HOME}/.zshrc" ]] && ! grep -q 'SSH_AUTH_SOCK' " \){HOME}/.zshrc" 2>/dev/null; then
    cat >> "${HOME}/.zshrc" << 'EOF'

# ssh-agent (user service)
export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR}/ssh-agent.socket"
EOF
  fi

  # Reload i3 if it is already running
  if pgrep -x i3 &>/dev/null; then
    i3-msg reload 2>/dev/null || true
  fi

  # Clean build dir
  rm -rf "${HOME}/etc/build" 2>/dev/null || true

  ok "Post-install finished"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo
  echo "╔════════════════════════════════════════════════════════════╗"
  echo "║  Exact dotfiles installer                                  ║"
  echo "║  Arch · i3 · polybar · mopidy · firefox · zsh · vim/emacs  ║"
  echo "╚════════════════════════════════════════════════════════════╝"
  echo

  preflight
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
  # init_spacemacs          # uncomment if you want Spacemacs
  enable_services
  post_install

  echo
  ok "ALL DONE"
  echo
  echo "Next steps:"
  echo "  1. Log out and back in (or reboot) so zsh is the login shell."
  echo "  2. Start i3 – polybar, dunst, and the rest will come up."
  echo "  3. User services (emacs, mopidy, ssh-agent, tmux) start automatically."
  echo "  4. Firefox startpage lives under \~/.mozilla/firefox/roosta"
  echo
  echo "Service status:"
  echo "  systemctl --user status mopidy-user emacs ssh-agent tmux"
  echo "  systemctl status NetworkManager sshd ufw"
  echo
  echo "Daily update (original Makefile):"
  echo "  cd \~/etc && make"
  echo
}

main "$@"
