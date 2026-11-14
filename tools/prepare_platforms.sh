#!/usr/bin/env bash
# Génère les dossiers natifs android/ et windows/ avec le modèle officiel de
# Flutter (toujours à jour), puis applique les réglages de Nothing Notes.
# Usage : tools/prepare_platforms.sh  (depuis la racine du dépôt)
set -euo pipefail
cd "$(dirname "$0")/../app"
flutter create --platforms=android,windows --org com.nothingnotes --project-name nothing_notes \
  --description "Nothing Notes" . >/dev/null
python3 ../tools/patch_platforms.py || python ../tools/patch_platforms.py
flutter pub get
dart run flutter_launcher_icons
echo "Plateformes prêtes."
