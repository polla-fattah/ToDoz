# ToDoz Binary Distribution

Place compiled client installer files in this directory:
- `ToDoz-Setup.msi` (Windows MSI Installer)
- `ToDoz.apk` (Android APK)
- `todoz-linux.deb` (Ubuntu Debian Package)

Files placed in this directory are served directly by Caddy with streaming download headers at `/downloads/<filename>`.
