#!/bin/bash
set -e

NAME=compo
VERSION=1.0.0
ARCH=amd64
BUNDLE=build/linux/x64/release/bundle
ICON=assets/icon/app_icon.png          # sesuaikan kalau path ikonmu beda
BIN=yt_audio                           # nama binary di dalam bundle

PKG=build/deb/${NAME}_${VERSION}_${ARCH}
rm -rf build/deb
mkdir -p $PKG/DEBIAN \
         $PKG/opt/$NAME \
         $PKG/usr/bin \
         $PKG/usr/share/applications \
         $PKG/usr/share/icons/hicolor/256x256/apps

# aplikasi
cp -r $BUNDLE/* $PKG/opt/$NAME/
ln -s /opt/$NAME/$BIN $PKG/usr/bin/$NAME
cp $ICON $PKG/usr/share/icons/hicolor/256x256/apps/$NAME.png

# menu aplikasi
cat > $PKG/usr/share/applications/$NAME.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Compo
Comment=Pemutar musik YouTube
Exec=/opt/$NAME/$BIN
Icon=$NAME
Terminal=false
Categories=AudioVideo;Audio;Player;
EOF

# metadata paket
cat > $PKG/DEBIAN/control <<EOF
Package: $NAME
Version: $VERSION
Architecture: $ARCH
Maintainer: Sutanto <you@example.com>
Depends: libgtk-3-0, libmpv2 | libmpv1, ffmpeg
Recommends: yt-dlp
Section: sound
Priority: optional
Description: Compo - pemutar musik YouTube
 Pemutar musik berbasis yt-dlp dengan playlist dan penyimpanan offline.
EOF

chmod -R 755 $PKG/DEBIAN
dpkg-deb --build --root-owner-group $PKG
echo "Selesai: build/deb/${NAME}_${VERSION}_${ARCH}.deb"
