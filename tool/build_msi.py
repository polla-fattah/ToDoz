#!/usr/bin/env python3
"""Builds a genuine Windows Installer (.msi) for ToDoz using wixl.
"""
import os
import re
import subprocess
import sys

def sanitize_id(s):
    # WiX identifiers must be alphanumeric or underscore, max 72 chars
    clean = re.sub(r'[^A-Za-z0-9_]', '_', s)
    if clean and clean[0].isdigit():
        clean = '_' + clean
    return clean[:60]

def main():
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    release_dir = os.path.join(repo_root, 'build', 'windows', 'x64', 'runner', 'Release')
    output_msi = os.path.join(repo_root, 'landing', 'downloads', 'ToDoz-Setup.msi')
    wxs_path = os.path.join(repo_root, 'build', 'todoz.wxs')
    icon_path = os.path.join(repo_root, 'windows', 'runner', 'resources', 'app_icon.ico')

    if not os.path.isdir(release_dir):
        print(f"Error: release directory not found at {release_dir}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(os.path.dirname(wxs_path), exist_ok=True)
    os.makedirs(os.path.dirname(output_msi), exist_ok=True)

    # To run wixl in WSL, convert paths to /mnt/c/...
    def to_wsl(win_path):
        p = os.path.abspath(win_path).replace('\\', '/')
        if len(p) >= 2 and p[1] == ':':
            drive = p[0].lower()
            return f"/mnt/{drive}{p[2:]}"
        return p

    component_refs = []
    dir_xml_lines = []

    # Map directories to their WiX Directory elements
    # Release folder is mapped to INSTALLDIR
    dir_map = {release_dir: "INSTALLDIR"}
    dir_counter = 0
    file_counter = 0

    # First pass: collect and sort all directories
    all_dirs = []
    for root, dirs, _ in os.walk(release_dir):
        for d in sorted(dirs):
            all_dirs.append(os.path.join(root, d))

    for d in all_dirs:
        dir_counter += 1
        d_name = os.path.basename(d)
        dir_id = f"DIR_{dir_counter}_{sanitize_id(d_name)}"
        dir_map[d] = dir_id

    # Recursive directory XML generator
    def build_dir_tree(current_dir, indent=10):
        lines = []
        sp = " " * indent
        # subdirectories
        subdirs = sorted([os.path.join(current_dir, d) for d in os.listdir(current_dir) if os.path.isdir(os.path.join(current_dir, d))])
        for sd in subdirs:
            sd_name = os.path.basename(sd)
            sd_id = dir_map[sd]
            lines.append(f'{sp}<Directory Id="{sd_id}" Name="{sd_name}">')
            lines.extend(build_dir_tree(sd, indent + 2))
            lines.append(f'{sp}</Directory>')

        # files in current_dir as components
        nonlocal file_counter
        files = sorted([f for f in os.listdir(current_dir) if os.path.isfile(os.path.join(current_dir, f))])
        for f in files:
            if f.endswith('.msix') or f.endswith('.pdb') or f == 'ToDoz-Setup.msi':
                continue
            file_counter += 1
            f_id = f"FILE_{file_counter}_{sanitize_id(f)}"
            comp_id = f"COMP_{file_counter}_{sanitize_id(f)}"
            component_refs.append(comp_id)

            full_path = os.path.join(current_dir, f)
            wsl_src = to_wsl(full_path)

            if f.lower() == 'taskflow.exe':
                lines.append(f'{sp}<Component Id="{comp_id}" Guid="*" Win64="yes">')
                lines.append(f'{sp}  <File Id="{f_id}" Source="{wsl_src}" KeyPath="yes">')
                lines.append(f'{sp}    <Shortcut Id="StartMenuShortcut" Directory="ProgramMenuDir" Name="ToDoz" WorkingDirectory="INSTALLDIR" Icon="AppIcon.ico" IconIndex="0" Advertise="yes" />')
                lines.append(f'{sp}    <Shortcut Id="DesktopShortcut" Directory="DesktopFolder" Name="ToDoz" WorkingDirectory="INSTALLDIR" Icon="AppIcon.ico" IconIndex="0" Advertise="yes" />')
                lines.append(f'{sp}  </File>')
                lines.append(f'{sp}</Component>')
            else:
                lines.append(f'{sp}<Component Id="{comp_id}" Guid="*" Win64="yes">')
                lines.append(f'{sp}  <File Id="{f_id}" Source="{wsl_src}" KeyPath="yes" />')
                lines.append(f'{sp}</Component>')

        return lines

    install_tree = build_dir_tree(release_dir, indent=12)

    wsl_icon = to_wsl(icon_path)
    component_refs.append("CleanupProgramMenuDir")

    wxs_content = f"""<?xml version="1.0" encoding="windows-1252"?>
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
  <Product Name="ToDoz" Id="*" UpgradeCode="B8B3D937-2E89-4D88-B391-4D9EF6F3F4D2"
    Language="1033" Codepage="1252" Version="1.0.0" Manufacturer="Polla Fattah">
    <Package Id="*" Keywords="Installer" Description="ToDoz Desktop Installer"
      Comments="ToDoz Local-First Task Management" Manufacturer="Polla Fattah"
      InstallerVersion="200" Languages="1033" Compressed="yes" SummaryCodepage="1252" />

    <MajorUpgrade DowngradeErrorMessage="A newer version of ToDoz is already installed." />
    <Media Id="1" Cabinet="todoz.cab" EmbedCab="yes" />

    <Icon Id="AppIcon.ico" SourceFile="{wsl_icon}" />
    <Property Id="ARPPRODUCTICON" Value="AppIcon.ico" />
    <Property Id="ARPHELPLINK" Value="https://todoz.polla.dev" />

    <Directory Id="TARGETDIR" Name="SourceDir">
      <Directory Id="ProgramFiles64Folder" Name="PFiles64">
        <Directory Id="INSTALLDIR" Name="ToDoz">
{chr(10).join(install_tree)}
        </Directory>
      </Directory>

      <Directory Id="ProgramMenuFolder" Name="Programs">
        <Directory Id="ProgramMenuDir" Name="ToDoz">
          <Component Id="CleanupProgramMenuDir" Guid="*" Win64="yes">
            <RemoveFolder Id="RemoveProgramMenuDir" On="uninstall" />
            <RegistryValue Root="HKCU" Key="Software\\ToDoz" Name="Installed" Type="integer" Value="1" KeyPath="yes" />
          </Component>
        </Directory>
      </Directory>

      <Directory Id="DesktopFolder" Name="Desktop" />
    </Directory>

    <Feature Id="Complete" Title="ToDoz Application" Level="1">
{chr(10).join(f'      <ComponentRef Id="{ref}" />' for ref in component_refs)}
    </Feature>
  </Product>
</Wix>
"""

    with open(wxs_path, 'w', encoding='utf-8') as f:
        f.write(wxs_content)

    print(f"Generated WiX source at: {wxs_path}")
    print(f"Compiled with {len(component_refs)} components.")

    wsl_wxs = to_wsl(wxs_path)
    wsl_msi = to_wsl(output_msi)

    cmd = ["wsl", "-e", "wixl", "-a", "x64", "-o", wsl_msi, wsl_wxs]
    print(f"Running: {' '.join(cmd)}")
    subprocess.run(cmd, check=True)

    print(f"Successfully generated MSI at: {output_msi}")

if __name__ == '__main__':
    main()
