#!/usr/bin/env bash
#
# setup.sh — provisionne un Mac fraîchement installé :
#   - installe Homebrew
#   - crée le groupe "brewusers" et y ajoute un utilisateur
#   - rend /opt/homebrew partageable entre les membres de ce groupe
#   - propose un utilitaire de désinstallation d'applications
#
# À exécuter avec un compte disposant des droits admin, SANS sudo devant :
#   chmod +x setup.sh && ./setup.sh
#
# Le script demandera le mot de passe admin via sudo au besoin. Ce mot de
# passe n'est jamais lu ni stocké par ce script : sudo gère son propre
# prompt et son propre cache (ticket temporaire), on ne fait que le
# rafraîchir pour éviter de le retaper à chaque étape.

set -euo pipefail

# ---------------------------------------------------------------------------
# Utilitaires d'affichage
# ---------------------------------------------------------------------------
log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33mAttention:\033[0m %s\n' "$1" >&2; }
err()  { printf '\033[1;31mErreur:\033[0m %s\n' "$1" >&2; }

# ---------------------------------------------------------------------------
# Garde-fous
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  err "Ce script est prévu pour macOS uniquement."
  exit 1
fi

if [[ $EUID -eq 0 ]]; then
  err "Ne lancez pas ce script avec sudo ou en tant que root."
  err "Lancez-le avec votre compte admin normal (./setup.sh) : il demandera sudo lui-même quand nécessaire."
  exit 1
fi

# ---------------------------------------------------------------------------
# Cache sudo (le mot de passe n'est jamais stocké : sudo gère son ticket
# temporaire lui-même, on le rafraîchit juste en tâche de fond)
# ---------------------------------------------------------------------------
log "Ce script a besoin des droits administrateur pour certaines étapes."
log "Le mot de passe sera demandé par sudo et ne sera jamais écrit sur le disque."
sudo -v

( while true; do
    sudo -n true
    sleep 60
    kill -0 "$$" 2>/dev/null || exit
  done ) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
cleanup() { kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. Installation de Homebrew
# ---------------------------------------------------------------------------
if command -v brew >/dev/null 2>&1; then
  log "Homebrew est déjà installé ($(brew --version | head -n1))."
else
  log "Installation de Homebrew..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Détermine le préfixe (Apple Silicon vs Intel)
if [[ -d /opt/homebrew ]]; then
  BREW_PREFIX="/opt/homebrew"
elif [[ -d /usr/local/Homebrew ]]; then
  BREW_PREFIX="/usr/local"
else
  err "Impossible de localiser l'installation Homebrew."
  exit 1
fi
log "Préfixe Homebrew détecté : $BREW_PREFIX"

# S'assure que brew est dans le PATH de cette session
if ! command -v brew >/dev/null 2>&1; then
  eval "$("$BREW_PREFIX"/bin/brew shellenv)"
fi

# ---------------------------------------------------------------------------
# 2. Création du groupe brewusers
# ---------------------------------------------------------------------------
GROUP_NAME="brewusers"

if dscl . -read "/Groups/$GROUP_NAME" >/dev/null 2>&1; then
  log "Le groupe '$GROUP_NAME' existe déjà."
else
  log "Création du groupe '$GROUP_NAME'..."
  sudo dseditgroup -o create -q "$GROUP_NAME"
fi

# ---------------------------------------------------------------------------
# 3. Ajout de l'utilisateur au groupe
# ---------------------------------------------------------------------------
DEFAULT_USER="$(id -un)"
read -r -p "Nom de l'utilisateur à ajouter au groupe '$GROUP_NAME' [$DEFAULT_USER]: " TARGET_USER
TARGET_USER="${TARGET_USER:-$DEFAULT_USER}"

if ! id "$TARGET_USER" >/dev/null 2>&1; then
  err "L'utilisateur '$TARGET_USER' n'existe pas sur ce Mac."
  exit 1
fi

if dseditgroup -o checkmember -m "$TARGET_USER" "$GROUP_NAME" >/dev/null 2>&1; then
  log "'$TARGET_USER' est déjà membre de '$GROUP_NAME'."
else
  log "Ajout de '$TARGET_USER' au groupe '$GROUP_NAME'..."
  sudo dseditgroup -o edit -a "$TARGET_USER" -t user "$GROUP_NAME"
fi

# ---------------------------------------------------------------------------
# 4. Permissions partagées sur le préfixe Homebrew
#    - groupe = brewusers
#    - g+rwX  = lecture/écriture/traverse pour le groupe
#    - g+s sur les dossiers = les nouveaux fichiers héritent du groupe
# ---------------------------------------------------------------------------
log "Application des permissions partagées sur $BREW_PREFIX (peut prendre un moment)..."
sudo chgrp -R "$GROUP_NAME" "$BREW_PREFIX"
sudo chmod -R g+rwX "$BREW_PREFIX"
sudo find "$BREW_PREFIX" -type d -exec chmod g+s {} +

log "Terminé. Déconnectez/reconnectez '$TARGET_USER' (ou redémarrez sa session) pour que l'appartenance au groupe soit prise en compte."

# ---------------------------------------------------------------------------
# 5. Désinstallation d'applications (optionnel)
# ---------------------------------------------------------------------------
uninstall_app() {
  local app_path="$1"
  local app_name
  app_name="$(basename "$app_path" .app)"

  read -r -p "Supprimer '$app_name' ? [o/N] " confirm
  case "$confirm" in
    o|O|oui|Oui) ;;
    *) log "Ignoré : $app_name"; return ;;
  esac

  # Si l'app a été installée via un cask Homebrew, on laisse brew faire le
  # ménage (fichiers de conf, LaunchAgents, etc.), sinon suppression directe.
  local cask_name
  cask_name="$(brew list --cask 2>/dev/null | grep -ix -- "$(echo "$app_name" | tr ' ' '-')" || true)"

  if [[ -n "$cask_name" ]]; then
    log "Désinstallation via Homebrew Cask ($cask_name)..."
    brew uninstall --cask --zap "$cask_name"
  else
    log "Suppression directe de $app_path..."
    sudo rm -rf "$app_path"
  fi
}

read -r -p $'\nVoulez-vous désinstaller des applications maintenant ? [o/N] ' DO_UNINSTALL
case "$DO_UNINSTALL" in
  o|O|oui|Oui)
    mapfile -t APPS < <(find /Applications -maxdepth 1 -name '*.app' | sort)
    if [[ ${#APPS[@]} -eq 0 ]]; then
      warn "Aucune application trouvée dans /Applications."
    else
      log "Applications installées :"
      for i in "${!APPS[@]}"; do
        printf '  [%d] %s\n' "$((i+1))" "$(basename "${APPS[$i]}" .app)"
      done
      read -r -p "Numéros à supprimer (ex: 1 3 5), vide pour annuler: " -a SELECTION
      for idx in "${SELECTION[@]}"; do
        if [[ "$idx" =~ ^[0-9]+$ ]] && (( idx >= 1 && idx <= ${#APPS[@]} )); then
          uninstall_app "${APPS[$((idx-1))]}"
        else
          warn "Sélection ignorée : $idx"
        fi
      done
    fi
    ;;
  *)
    log "Aucune désinstallation demandée."
    ;;
esac

log "Script terminé."
