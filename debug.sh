#!/bin/bash

# Hanya untuk debugging — jangan pakai > /dev/null

dirnow="$PWD"

echo "📍 Working directory: $dirnow"
ls -l framework.jar

if [[ ! -f "$dirnow/framework.jar" ]]; then
    echo "❌ framework.jar missing!"
    exit 1
fi

# Backup (jika belum ada)
if [[ ! -f "$dirnow/framework.jar.bak" ]]; then
    cp "$dirnow/framework.jar" "$dirnow/framework.jar.bak"
fi

apkeditor() {
    jarfile="$dirnow/tool/APKEditor.jar"
    javaOpts="-Xmx4096M -Dfile.encoding=utf-8 -Djdk.util.zip.disableZip64ExtraFieldValidation=true -Djdk.nio.zipfs.allowDotZipEntry=true"
    java $javaOpts -jar "$jarfile" "$@"
}

echo "1️⃣ Unpacking framework.jar..."
apkeditor d -i framework.jar -o frmwrk
echo "→ Unpack result: $?"

mv framework.jar frmwrk.jar
echo "→ Moved to frmwrk.jar"

echo "2️⃣ Checking for critical files..."
ls -la PIF/
ls frmwrk/ | grep -E "(Instrumentation|AndroidKeyStoreSpi)"

echo "3️⃣ Repacking with APKEditor..."
apkeditor b -i frmwrk
echo "→ Repack result: $?"

echo "4️⃣ Extracting DEX files..."
unzip frmwrk_out.apk 'classes*.dex' -d frmwrk

echo "5️⃣ Adding PIF/classes.dex..."
cp PIF/classes.dex frmwrk/classes99.dex

echo "6️⃣ Creating JAR..."
cd frmwrk
zip -qr0 "$dirnow/frmwrk.jar" classes*
echo "→ ZIP result: $?"
ls -l "$dirnow/frmwrk.jar"
cd "$dirnow"

echo "7️⃣ Zipaligning..."
zipalign -v 4 frmwrk.jar framework.jar
echo "→ Zipalign result: $?"
ls -l framework.jar

echo "✅ Done."
