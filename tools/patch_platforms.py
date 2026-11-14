"""Réglages appliqués aux dossiers générés par `flutter create`."""
import pathlib
import re
import sys

app = pathlib.Path(__file__).resolve().parent.parent / "app"


def edit(rel, fn):
    p = app / rel
    if not p.exists():
        print(f"(absent) {rel}")
        return
    s = p.read_text(encoding="utf-8")
    n = fn(s)
    if n != s:
        p.write_text(n, encoding="utf-8")
        print(f"modifié  {rel}")


# ---------------------------------------------------------------- Android
def manifest(s):
    if "android.permission.INTERNET" not in s:
        s = s.replace("<application", '<uses-permission android:name="android.permission.INTERNET"/>\n    <application', 1)
    s = re.sub(r'android:label="[^"]*"', 'android:label="Nothing Notes"', s, count=1)
    if "android.intent.action.VIEW" not in s.split("<queries>")[-1] if "<queries>" in s else True:
        q = ('        <intent>\n            <action android:name="android.intent.action.VIEW"/>\n'
             '            <data android:scheme="https"/>\n        </intent>\n')
        if "<queries>" in s:
            s = s.replace("<queries>", "<queries>\n" + q, 1)
        else:
            s = s.replace("</manifest>", "    <queries>\n" + q + "    </queries>\n</manifest>", 1)
    return s


edit("android/app/src/main/AndroidManifest.xml", manifest)


def gradle(s):
    # minSdk 24 (Android 7.0) : exigé par certaines bibliothèques récentes
    s = s.replace("minSdk = flutter.minSdkVersion", "minSdk = maxOf(24, flutter.minSdkVersion)")
    s = s.replace("minSdkVersion flutter.minSdkVersion", "minSdkVersion Math.max(24, flutter.minSdkVersion)")
    return s


edit("android/app/build.gradle.kts", gradle)
edit("android/app/build.gradle", gradle)

# ---------------------------------------------------------------- Windows
edit("windows/runner/main.cpp", lambda s: s.replace('L"nothing_notes"', 'L"Nothing Notes"')
     .replace("Win32Window::Size size(1280, 720);", "Win32Window::Size size(1360, 860);"))


def rc(s):
    for key in ("FileDescription", "ProductName", "InternalName"):
        s = re.sub(r'(VALUE "%s", )"[^"]*"' % key, r'\1"Nothing Notes"', s)
    s = re.sub(r'(VALUE "CompanyName", )"[^"]*"', r'\1"Nothing Notes"', s)
    s = re.sub(r'(VALUE "OriginalFilename", )"[^"]*"', r'\1"NothingNotes.exe"', s)
    s = re.sub(r'(VALUE "LegalCopyright", )"[^"]*"', r'\1"Logiciel libre et gratuit"', s)
    return s


edit("windows/runner/Runner.rc", rc)
edit("windows/CMakeLists.txt", lambda s: re.sub(r'set\(BINARY_NAME "[^"]*"\)', 'set(BINARY_NAME "NothingNotes")', s))
print("ok")
sys.exit(0)
