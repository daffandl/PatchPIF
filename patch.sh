#!/bin/bash
set -e  # Berhenti jika ada perintah gagal

ensure_zipalign() {
    if command -v zipalign &> /dev/null; then
        return 0
    fi

    echo "⚠️ zipalign not found. Installing dependencies and zipalign..."

    sudo apt-get update -qq
    sudo apt-get install -y -qq openjdk-17-jre android-sdk-libsparse-utils android-sdk-platform-tools zip unzip wget

    wget -q -O /tmp/zipalign https://github.com/AndroidSDKPlatformTools/android-sdk-platform-tools/raw/main/zipalign
    chmod +x /tmp/zipalign
    sudo mv /tmp/zipalign /usr/local/bin/

    if ! command -v zipalign &> /dev/null; then
        echo "❌ zipalign installation failed!"
        exit 1
    fi
    echo "✅ zipalign is ready."
}

ensure_zipalign

dirnow="$PWD"

if [[ ! -f "$dirnow/framework.jar" ]]; then
    echo "❌ No framework.jar detected in $dirnow!"
    exit 1
fi

# Backup otomatis (opsional tapi aman)
if [[ ! -f "$dirnow/framework.jar.bak" ]]; then
    echo "Creating backup: framework.jar.bak"
    cp "$dirnow/framework.jar" "$dirnow/framework.jar.bak"
fi

apkeditor() {
    jarfile="$dirnow/tool/APKEditor.jar"
    javaOpts="-Xmx4096M -Dfile.encoding=utf-8 -Djdk.util.zip.disableZip64ExtraFieldValidation=true -Djdk.nio.zipfs.allowDotZipEntry=true"
    java $javaOpts -jar "$jarfile" "$@"
}

certificatechainPatch() {
    echo "
    .line $1
    invoke-static {}, Lcom/android/internal/util/danda/OemPorts10TUtils;->onEngineGetCertificateChain()V
"
}

instrumentationPatch() {
    local returnline=$(( $2 + 1 ))
    echo "    invoke-static {$1}, Lcom/android/internal/util/danda/OemPorts10TUtils;->onNewApplication(Landroid/content/Context;)V
    
    .line $returnline
    "
}

blSpoofPatch() {
    echo "    invoke-static {$1}, Lcom/android/internal/util/danda/OemPorts10TUtils;->genCertificateChain([Ljava/security/cert/Certificate;)[Ljava/security/cert/Certificate;
	
    move-result-object $1
    "
}

expressions_fix() {
    local var="$1"
    local escaped_var
    escaped_var=$(printf '%s' "$var" | sed 's/[\/&]/\\&/g')
    escaped_var=$(printf '%s' "$escaped_var" | sed 's/\[/\\[/g; s/\]/\\]/g; s/\./\\./g; s/;/\\;/g')
    echo "$escaped_var"
}

echo "🔧 Unpacking framework.jar..."
apkeditor d -i framework.jar -o frmwrk
mv framework.jar frmwrk.jar

echo "🪛 Patching framework.jar..."

keystorespiclassfile=$(find frmwrk/ -name 'AndroidKeyStoreSpi.smali' -printf '%P\n')
instrumentationsmali=$(find frmwrk/ -name "Instrumentation.smali" -printf '%P\n')

if [[ -z "$keystorespiclassfile" ]]; then
    echo "❌ AndroidKeyStoreSpi.smali not found!"
    exit 1
fi
if [[ -z "$instrumentationsmali" ]]; then
    echo "❌ Instrumentation.smali not found!"
    exit 1
fi

engineGetCertMethod=$(expressions_fix "$(grep -m1 'engineGetCertificateChain(' "frmwrk/$keystorespiclassfile")")
newAppMethod1=$(expressions_fix "$(grep -m1 'newApplication(Ljava/lang/ClassLoader;' "frmwrk/$instrumentationsmali")")
newAppMethod2=$(expressions_fix "$(grep -m1 'newApplication(Ljava/lang/Class;' "frmwrk/$instrumentationsmali")")

# Ekstrak & hapus method
sed -n "/^${engineGetCertMethod}/,/^\.end method/p" "frmwrk/$keystorespiclassfile" > tmp_keystore
sed -i "/^${engineGetCertMethod}/,/^\.end method/d" "frmwrk/$keystorespiclassfile"

sed -n "/^${newAppMethod1}/,/^\.end method/p" "frmwrk/$instrumentationsmali" > inst1
sed -i "/^${newAppMethod1}/,/^\.end method/d" "frmwrk/$instrumentationsmali"

sed -n "/^${newAppMethod2}/,/^\.end method/p" "frmwrk/$instrumentationsmali" > inst2
sed -i "/^${newAppMethod2}/,/^\.end method/d" "frmwrk/$instrumentationsmali"

# Patch Instrumentation newApplication 1
inst1_insert=$(( $(wc -l < inst1) - 2 ))
instreg=$(grep "Landroid/app/Application;->attach(Landroid/content/Context;)V" inst1 | awk '{print $3}' | sed 's/},//')
instline=$(( $(grep -E "^\s*\.line\s+[0-9]+" inst1 | tail -n1 | awk '{print $2}') + 1 ))
instrumentationPatch "$instreg" "$instline" | sed -i "${inst1_insert}r /dev/stdin" inst1

# Patch Instrumentation newApplication 2
inst2_insert=$(( $(wc -l < inst2) - 2 ))
instreg=$(grep "Landroid/app/Application;->attach(Landroid/content/Context;)V" inst2 | awk '{print $3}' | sed 's/},//')
instline=$(( $(grep -E "^\s*\.line\s+[0-9]+" inst2 | tail -n1 | awk '{print $2}') + 1 ))
instrumentationPatch "$instreg" "$instline" | sed -i "${inst2_insert}r /dev/stdin" inst2

# Patch AndroidKeyStoreSpi
kstoreline=$(( $(grep -E "^\s*\.line\s+[0-9]+" tmp_keystore | head -n1 | awk '{print $2}') - 2 ))
certificatechainPatch "$kstoreline" | sed -i '4r /dev/stdin' tmp_keystore

lastaput=$(grep "aput-object" tmp_keystore | tail -n1)
leafcert=$(echo "$lastaput" | awk '{print $3}' | cut -d',' -f1)
blspoof_insert=$(( $(grep -n "$lastaput" tmp_keystore | cut -d: -f1) + 1 ))
blSpoofPatch "$leafcert" | sed -i "${blspoof_insert}r /dev/stdin" tmp_keystore

# Gabungkan kembali
cat inst1 >> "frmwrk/$instrumentationsmali"
cat inst2 >> "frmwrk/$instrumentationsmali"
cat tmp_keystore >> "frmwrk/$keystorespiclassfile"

rm -f inst1 inst2 tmp_keystore

echo "📦 Repacking framework.jar classes..."
apkeditor b -i frmwrk
unzip -q frmwrk_out.apk 'classes*.dex' -d frmwrk

# Tambahkan PIF/classes.dex
if [[ ! -f "PIF/classes.dex" ]]; then
    echo "❌ PIF/classes.dex not found! Required for patching."
    exit 1
fi
patchclass=$(( $(find frmwrk/ -name '*.dex' | wc -l) + 1 ))
cp PIF/classes.dex "frmwrk/classes${patchclass}.dex"

echo "🔖 Zipping classes into JAR..."
cd frmwrk
zip -qr0 "$dirnow/frmwrk.jar" classes*
cd "$dirnow"

echo "⚡ Zipaligning final framework.jar..."
zipalign -v 4 frmwrk.jar framework.jar

# Bersihkan
rm -rf frmwrk frmwrk_out.apk frmwrk.jar

echo
echo "✅ SUCCESS! Patched framework.jar is ready in:"
echo "   $dirnow/framework.jar"
echo "   (Original backed up as framework.jar.bak)"
