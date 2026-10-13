#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/brand/AppIcon.iconset
xcrun swift Scripts/make-icon.swift Resources/Branding/Ecru-Master.png .build/brand/AppIcon.iconset
iconutil -c icns .build/brand/AppIcon.iconset -o Resources/Branding/AppIcon.icns
cp .build/brand/AppIcon.iconset/icon_512x512@2x.png Resources/Branding/AppIcon.png
print 'Built AppIcon.icns from the preserved Ecru master'
