#!/bin/bash
set -euo pipefail  # Berhenti pada error, variabel tak terdefinisi, atau pipe gagal

# === 1. Pastikan zipalign resmi dari Google tersedia ===
ensure_official_zipalign() {
    local need_install=false

    if ! command -v zipalign &> /dev/null; then
        need_install=true
    else
        # Verifikasi apakah ini zipalign asli
        if ! zipalign 2>&1 | grep -q "infile.zip outfile.zip"; then
            echo "⚠️ Detected non-functional zipalign. Reinstalling official version..."
            need_install=true
        fi
    fi

    if [ "$need_install" = true ]; then
        echo "🔧 Installing official zipalign from Google..."

        sudo apt-get update -qq
        sudo apt-get install -y -qq openjdk-17-jre zip unzip wget

        # Unduh build-tools versi 34.0.0 (nama file spesifik)
        wget -q https://dl.google.com/android/repository/build-tools_r34.0.0-linux.zip
        unzip -q build-tools_r34.0.0-linux.zip
        sudo mv build-tools/zipalign /usr/local/bin/
        sudo chmod +x /usr/local/bin/zipalign
        rm -rf build-tools_r34.0.0-linux.zip build-tools/

        echo "✅ Official zipalign installed."
    else
        echo "✅ zipalign is ready."
    fi
}

ensure_official_zipalign

# === 2. Persiapan ===
dirnow="$PWD"

if [[ ! -f "$dirnow/framework.jar" ]]; then
    echo "❌ framework.jar not found in $dirnow!"
    exit 1
fi

# Backup otomatis (hanya jika belum ada)
if [[ ! -f "$dirnow/framework.jar.bak" ]]; then
    echo "💾 Creating backup: framework.jar.bak"
    cp "$dirnow/framework.jar" "$dirnow/framework.jar.bak"
fi

# Cek dependensi eksternal
if [[ ! -f "$dirnow/tool/APKEditor.jar" ]]; then
    echo "❌ Missing tool/APKEditor.jar!"
    exit 1
fi

if [[ ! -f "$dirnow/PIF/classes.dex" ]]; then
    echo "❌ Missing PIF/classes.dex!"
    exit 1
fi

# === 3. Fungsi Bantuan ===
apkeditor() {
    java -Xmx2048M \
        -Dfile.encoding=utf-8 \
        -Djdk.util.zip.disableZip64ExtraFieldValidation=true \
        -Djdk.nio.zipfs.allowDotZipEntry=true \
        -jar "$dirnow/tool/APKEditor.jar" "$@"
}

expressions_fix() {
    local var="$1"
    printf '%s' "$var" | sed 's/[\/&]/\\&/g; s/\[/\\[/g; s/\]/\\]/g; s/\./\\./g; s/;/\\;/g'
}

# === 4. Unpack ===
echo "📦 Unpacking framework.jar..."
apkeditor d -i framework.jar -o frmwrk
mv framework.jar frmwrk.jar

# === 5. Temukan file target ===
echo "🔍 Locating target files..."
keystorespiclassfile=$(find frmwrk/ -name 'AndroidKeyStoreSpi.smali' -print -quit)
instrumentationsmali=$(find frmwrk/ -name 'Instrumentation.smali' -print -quit)

if [[ -z "$keystorespiclassfile" ]]; then
    echo "❌ AndroidKeyStoreSpi.smali not found!"
    exit 1
fi
if [[ -z "$instrumentationsmali" ]]; then
    echo "❌ Instrumentation.smali not found!"
    exit 1
fi

# === 6. Ekstrak method ===
engineGetCertMethod=$(expressions_fix "$(grep -m1 'engineGetCertificateChain(' "$keystorespiclassfile")")
newAppMethod1=$(expressions_fix "$(grep -m1 'newApplication(Ljava/lang/ClassLoader;' "$instrumentationsmali")")
newAppMethod2=$(expressions_fix "$(grep -m1 'newApplication(Ljava/lang/Class;' "$instrumentationsmali")")

sed -n "/^${engineGetCertMethod}/,/^\.end method/p" "$keystorespiclassfile" > tmp_keystore
sed -i "/^${engineGetCertMethod}/,/^\.end method/d" "$keystorespiclassfile"

sed -n "/^${newAppMethod1}/,/^\.end method/p" "$instrumentationsmali" > inst1
sed -i "/^${newAppMethod1}/,/^\.end method/d" "$instrumentationsmali"

sed -n "/^${newAppMethod2}/,/^\.end method/p" "$instrumentationsmali" > inst2
sed -i "/^${newAppMethod2}/,/^\.end method/d" "$instrumentationsmali"

# === 7. Patch ===
# Patch Instrumentation (method 1)
inst1_insert=$(( $(wc -l < inst1) - 2 ))
instreg=$(grep "Landroid/app/Application;->attach(Landroid/content/Context;)V" inst1 | awk '{print $3}' | sed 's/},//')
instline=$(( $(grep -E "^\s*\.line\s+[0-9]+" inst1 | tail -n1 | awk '{print $2}') + 1 ))
{
    echo "    invoke-static {$instreg}, Lcom/android/internal/util/danda/OemPorts10TUtils;->onNewApplication(Landroid/content/Context;)V"
    echo ""
    echo "    .line $instline"
} | sed -i "${inst1_insert}r /dev/stdin" inst1

# Patch Instrumentation (method 2)
inst2_insert=$(( $(wc -l < inst2) - 2 ))
instreg=$(grep "Landroid/app/Application;->attach(Landroid/content/Context;)V" inst2 | awk '{print $3}' | sed 's/},//')
instline=$(( $(grep -E "^\s*\.line\s+[0-9]+" inst2 | tail -n1 | awk '{print $2}') + 1 ))
{
    echo "    invoke-static {$instreg}, Lcom/android/internal/util/danda/OemPorts10TUtils;->onNewApplication(Landroid/content/Context;)V"
    echo ""
    echo "    .line $instline"
} | sed -i "${inst2_insert}r /dev/stdin" inst2

# Patch AndroidKeyStoreSpi
kstoreline=$(( $(grep -E "^\s*\.line\s+[0-9]+" tmp_keystore | head -n1 | awk '{print $2}') - 2 ))
{
    echo "    .line $kstoreline"
    echo "    invoke-static {}, Lcom/android/internal/util/danda/OemPorts10TUtils;->onEngineGetCertificateChain()V"
} | sed -i '4r /dev/stdin' tmp_keystore

# Patch Certificate Chain Spoof
lastaput=$(grep "aput-object" tmp_keystore | tail -n1)
leafcert=$(echo "$lastaput" | awk '{print $3}' | cut -d',' -f1)
blspoof_insert=$(( $(grep -n "$lastaput" tmp_keystore | cut -d: -f1) + 1 ))
{
    echo "    invoke-static {$leafcert}, Lcom/android/internal/util/danda/OemPorts10TUtils;->genCertificateChain([Ljava/security/cert/Certificate;)[Ljava/security/cert/Certificate;"
    echo ""
    echo "    move-result-object $leafcert"
} | sed -i "${blspoof_insert}r /dev/stdin" tmp_keystore

# Gabungkan kembali
cat inst1 >> "$instrumentationsmali"
cat inst2 >> "$instrumentationsmali"
cat tmp_keystore >> "$keystorespiclassfile"

rm -f inst1 inst2 tmp_keystore

# === 8. Repack ===
echo "🔄 Repacking patched classes..."
apkeditor b -i frmwrk

# Ekstrak DEX
unzip -q frmwrk_out.apk 'classes*.dex' -d frmwrk

# Tambahkan PIF
patchclass=$(( $(find frmwrk/ -name '*.dex' | wc -l) + 1 ))
cp PIF/classes.dex "frmwrk/classes${patchclass}.dex"

# Buat JAR sementara
cd frmwrk
zip -qr0 "$dirnow/frmwrk.jar" classes*
cd "$dirnow"

# === 9. Zipalign resmi ===
echo "⚡ Applying zipalign (official)..."
zipalign -v 4 frmwrk.jar framework.jar

# Verifikasi
if [[ ! -f "framework.jar" ]]; then
    echo "❌ Fatal: framework.jar was not created after zipalign!"
    exit 1
fi

# === 10. Bersihkan ===
rm -rf frmwrk frmwrk_out.apk frmwrk.jar

echo
echo "✅ SUCCESS!"
echo "📁 Output: $dirnow/framework.jar"
echo "🛡️  Backup: $dirnow/framework.jar.bak"
