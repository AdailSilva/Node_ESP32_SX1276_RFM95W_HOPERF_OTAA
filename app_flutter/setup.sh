#!/bin/sh
# Gera a estrutura Android/iOS que falta (o flutter create NÃO sobrescreve
# lib/, pubspec.yaml, AndroidManifest.xml, MainActivity.kt nem os res/xml deste repositório)
# e baixa as dependências.
set -e
cd "$(dirname "$0")"
command -v flutter >/dev/null || { echo "flutter não encontrado no PATH"; exit 1; }
flutter create --org br.com.adailsilva --project-name lorawan_node_otaa_app --platforms android,ios .
flutter pub get
echo
echo "Pronto. Rode:  flutter run    (ou: flutter build apk --release)"
