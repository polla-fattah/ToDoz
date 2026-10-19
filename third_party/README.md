# Vendored packages

`record_windows` is `record_windows` 2.3.0 from pub.dev with one change: `windows/CMakeLists.txt` asks for CMake 3.14
instead of 3.23, so the Windows build works with Visual Studio 2019 Build Tools (they ship CMake 3.20). It is
wired in through `dependency_overrides` in `pubspec.yaml`. Remove the override and this folder once Visual Studio 2022
(or any CMake 3.23+) is installed, or when the plugin lowers its own minimum.
