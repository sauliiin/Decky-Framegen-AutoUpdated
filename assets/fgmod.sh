#!/usr/bin/env bash

set -x
exec > >(tee -i /tmp/fgmod-install.log) 2>&1

error_exit() {
  echo " $1"
  if [[ -n $STEAM_ZENITY ]]; then
    $STEAM_ZENITY --error --text "$1"
  else 
    zenity --error --text "$1" || echo "Zenity failed to display error"
  fi
  logger -t fgmod "ERROR: $1"
  exit 1
}

# === CONFIG ===
fgmod_path="$HOME/fgmod"
dll_name="${DLL:-dxgi.dll}"
preserve_ini="${PRESERVE_INI:-true}"
python_cmd="${PYTHON:-python}"
if ! command -v "$python_cmd" >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  python_cmd="python3"
fi

case "$dll_name" in
  "dxgi.dll"|"winmm.dll"|"dbghelp.dll"|"version.dll"|"wininet.dll"|"winhttp.dll"|"OptiScaler.asi")
    ;;
  *)
    error_exit "Invalid DLL proxy name: $dll_name"
    ;;
esac

# === Resolve Game Path ===
if [[ "$#" -lt 1 ]]; then
  error_exit "Usage: $0 program [program_arguments...]"
fi

exe_folder_path=""
if [[ $# -eq 1 ]]; then
  [[ "$1" == *.exe ]] && exe_folder_path=$(dirname "$1") || exe_folder_path="$1"
else
  for arg in "$@"; do
    if [[ "$arg" == *.exe ]]; then
      [[ "$arg" == *"Cyberpunk 2077"* ]] && arg=${arg//REDprelauncher.exe/bin/x64/Cyberpunk2077.exe}
      [[ "$arg" == *"Witcher 3"* ]]      && arg=${arg//REDprelauncher.exe/bin/x64_dx12/witcher3.exe}
      [[ "$arg" == *"Baldurs Gate 3"* ]] && arg=${arg//Launcher\/LariLauncher.exe/bin/bg3_dx11.exe}
      [[ "$arg" == *"HITMAN 3"* ]]       && arg=${arg//Launcher.exe/Retail/HITMAN3.exe}
      [[ "$arg" == *"HITMAN World of Assassination"* ]] && arg=${arg//Launcher.exe/Retail/HITMAN3.exe}
      [[ "$arg" == *"SYNCED"* ]]         && arg=${arg//Launcher\/sop_launcher.exe/SYNCED.exe}
      [[ "$arg" == *"2KLauncher"* ]]     && arg=${arg//2KLauncher\/LauncherPatcher.exe/DoesntMatter.exe}
      [[ "$arg" == *"Warhammer 40,000 DARKTIDE"* ]] && arg=${arg//launcher\/Launcher.exe/binaries/Darktide.exe}
      [[ "$arg" == *"Warhammer Vermintide 2"* ]]    && arg=${arg//launcher\/Launcher.exe/binaries_dx12/vermintide2_dx12.exe}
      [[ "$arg" == *"Satisfactory"* ]]   && arg=${arg//FactoryGameSteam.exe/Engine/Binaries/Win64/FactoryGameSteam-Win64-Shipping.exe}
      [[ "$arg" == *"FINAL FANTASY XIV Online"* ]] && arg=${arg//boot\/ffxivboot.exe/game/ffxiv_dx11.exe}
      exe_folder_path=$(dirname "$arg")
      break
    fi
  done
fi

for arg in "$@"; do
  if [[ "$arg" == lutris:rungameid/* ]]; then
    lutris_id="${arg#lutris:rungameid/}"

    # Get slug from Lutris JSON
    slug=$(lutris --list-games --json 2>/dev/null | jq -r ".[] | select(.id == $lutris_id) | .slug")

    if [[ -z "$slug" || "$slug" == "null" ]]; then
      echo "Could not find slug for Lutris ID $lutris_id"
      break
    fi

    # Find matching YAML file using slug
    config_file=$(find ~/.config/lutris/games/ -iname "${slug}-*.yml" | head -1)

    if [[ -z "$config_file" ]]; then
      echo "No config file found for slug '$slug'"
      break
    fi

    # Extract executable path from YAML
    exe_path=$(grep -E '^\s*exe:' "$config_file" | sed 's/.*exe:[[:space:]]*//' )

    if [[ -n "$exe_path" ]]; then
      exe_folder_path=$(dirname "$exe_path")
      echo "Resolved executable path: $exe_path"
      echo "Executable folder: $exe_folder_path"
    else
      echo "Executable path not found in $config_file"
    fi

    break
  fi
done

[[ -z "$exe_folder_path" && -n "$STEAM_COMPAT_INSTALL_PATH" ]] && exe_folder_path="$STEAM_COMPAT_INSTALL_PATH"

if [[ -d "$exe_folder_path/Engine" ]]; then
  ue_exe=$(find "$exe_folder_path" -maxdepth 4 -mindepth 4 -path "*Binaries/Win64/*.exe" -not -path "*/Engine/*" | head -1)
  exe_folder_path=$(dirname "$ue_exe")
fi

[[ ! -d "$exe_folder_path" ]] && error_exit " Could not resolve game directory!"
[[ ! -w "$exe_folder_path" ]] && error_exit " No write permission to the game folder!"

logger -t fgmod "Target directory: $exe_folder_path"
logger -t fgmod "Using DLL name: $dll_name"
logger -t fgmod "Preserve INI: $preserve_ini"

# === Cleanup Old Injectors ===
rm -f "$exe_folder_path"/{dxgi.dll,winmm.dll,dbghelp.dll,version.dll,wininet.dll,winhttp.dll,OptiScaler.asi,nvngx.dll,_nvngx.dll,nvngx-wrapper.dll,dlss-enabler.dll,OptiScaler.dll}

# === Optional: Backup Original DLLs ===
original_dlls=("d3dcompiler_47.dll" "amd_fidelityfx_dx12.dll" "amd_fidelityfx_framegeneration_dx12.dll" "amd_fidelityfx_upscaler_dx12.dll" "amd_fidelityfx_vk.dll")
for dll in "${original_dlls[@]}"; do
  [[ -f "$exe_folder_path/$dll" && ! -f "$exe_folder_path/$dll.b" ]] && mv -f "$exe_folder_path/$dll" "$exe_folder_path/$dll.b"
done

# === Remove nvapi64.dll and its backup (conflicts from previous fakenvapi versions) ===
rm -f "$exe_folder_path/nvapi64.dll" "$exe_folder_path/nvapi64.dll.b"
echo " Cleaned up nvapi64.dll and backup (legacy fakenvapi conflicts)"

# === Core Install ===
if [[ -f "$fgmod_path/renames/$dll_name" ]]; then
  echo " Using pre-renamed $dll_name"
  cp "$fgmod_path/renames/$dll_name" "$exe_folder_path/$dll_name" || error_exit " Failed to copy $dll_name"
else
  echo " Pre-renamed $dll_name not found, falling back to OptiScaler.dll"
  cp "$fgmod_path/OptiScaler.dll" "$exe_folder_path/$dll_name" || error_exit " Failed to copy OptiScaler.dll as $dll_name"
fi

# === OptiScaler.ini Handling ===
installed_ini=false
if [[ "$preserve_ini" == "true" && -f "$exe_folder_path/OptiScaler.ini" ]]; then
  echo " Preserving existing OptiScaler.ini (user settings retained)"
  logger -t fgmod "Existing OptiScaler.ini preserved in $exe_folder_path"
else
  echo " Installing OptiScaler.ini from plugin defaults"
  if [[ -f "$exe_folder_path/OptiScaler.ini" && ! -f "$exe_folder_path/OptiScaler.ini.b" ]]; then
    mv -f "$exe_folder_path/OptiScaler.ini" "$exe_folder_path/OptiScaler.ini.b"
  fi
  cp "$fgmod_path/OptiScaler.ini" "$exe_folder_path/OptiScaler.ini" || error_exit " Failed to copy OptiScaler.ini"
  installed_ini=true
  logger -t fgmod "OptiScaler.ini installed to $exe_folder_path"
fi

# === OptiScaler env variables Handling ===
if [[ -f "$fgmod_path/update-optiscaler-config.py" ]]; then
  "$python_cmd" "$fgmod_path/update-optiscaler-config.py" "$exe_folder_path/OptiScaler.ini" || true
fi

# OptiScaler 0.9.0-pre11 can assert on Proton when HQ font auto mode tries to load
# an external TTF that is not present. Only normalize the default auto value.
sed -i 's/^UseHQFont[[:space:]]*=[[:space:]]*auto$/UseHQFont=false/' "$exe_folder_path/OptiScaler.ini" || true

# === Migrate FGType → FGInput/FGOutput (pre-v0.9-final INIs) ===
# v0.9-final split the single FGType key into FGInput + FGOutput. Games that were
# patched with an older build will have FGType=<value> with no FGInput/FGOutput,
# causing the new DLL to silently use nofg. Fix that here on every launch.
_fgtype_ini="$exe_folder_path/OptiScaler.ini"
if grep -q '^FGType=' "$_fgtype_ini" 2>/dev/null; then
  _fgtype_val=$(sed -n 's/^FGType=\(.*\)/\1/p' "$_fgtype_ini")
  echo " Migrating FGType=$_fgtype_val → FGInput/FGOutput in OptiScaler.ini"
  logger -t fgmod "Migrating FGType=$_fgtype_val → FGInput/FGOutput"
  if grep -q '^FGInput=' "$_fgtype_ini"; then
    # FGInput already present — INI already in v0.9-final format; just drop FGType
    sed -i '/^FGType=/d' "$_fgtype_ini" || true
  else
    # Replace FGType=X with FGInput=X + FGOutput=X
    sed -i "s/^FGType=.*$/FGInput=$_fgtype_val\nFGOutput=$_fgtype_val/" "$_fgtype_ini" || true
  fi
fi
unset _fgtype_ini _fgtype_val

# === ASI Plugins Directory ===
if [[ -d "$fgmod_path/plugins" ]]; then
  echo " Installing ASI plugins directory"
  cp -r "$fgmod_path/plugins" "$exe_folder_path/" || true
  logger -t fgmod "ASI plugins directory installed to $exe_folder_path"
else
  echo " No plugins directory found in fgmod"
fi

# === Supporting Directories ===
copied_dirs=()
for payload_dir in "$fgmod_path"/*; do
  [[ -d "$payload_dir" ]] || continue
  payload_dir_name=$(basename "$payload_dir")
  case "$payload_dir_name" in
    "renames"|"plugins"|"Licenses"|"__pycache__")
      continue
      ;;
  esac
  cp -r "$payload_dir" "$exe_folder_path/" || true
  copied_dirs+=("$payload_dir_name")
done
echo " Installed support directories: ${copied_dirs[*]}"
logger -t fgmod "Installed support directories: ${copied_dirs[*]}"

# === Supporting Payload ===
# OptiScaler support files change between releases. Copy the payload that exists
# in ~/fgmod instead of pinning this script to one release's DLL list.
copied_payload=()
for payload in "$fgmod_path"/*; do
  [[ -f "$payload" ]] || continue
  payload_name=$(basename "$payload")
  case "$payload_name" in
    "OptiPatcher_rolling.asi"|"OptiScaler.dll"|"OptiScaler.ini")
      continue
      ;;
    *.asi|*.ASI|*.bin|*.BIN|*.cfg|*.CFG|*.dll|*.DLL|*.ini|*.INI|*.json|*.JSON|*.toml|*.TOML)
      if [[ -f "$exe_folder_path/$payload_name" && ! -f "$exe_folder_path/$payload_name.b" ]]; then
        mv -f "$exe_folder_path/$payload_name" "$exe_folder_path/$payload_name.b"
      fi
      cp -f "$payload" "$exe_folder_path/" || true
      copied_payload+=("$payload_name")
      ;;
  esac
done
echo " Installed support payload: ${copied_payload[*]}"
logger -t fgmod "Installed support payload: ${copied_payload[*]}"

# Track files installed by this script so future uninstall can remove payload
# files even when upstream OptiScaler adds or renames support DLLs.
installed_manifest="$exe_folder_path/FRAMEGEN_PATCH_FILES"
installed_files=("$dll_name" "${copied_payload[@]}")
[[ "$installed_ini" == "true" ]] && installed_files+=("OptiScaler.ini")
"$python_cmd" - "$installed_manifest" "${installed_files[@]}" "::DIRS::" "${copied_dirs[@]}" <<'PY' || true
import json
import sys

manifest_path = sys.argv[1]
args = sys.argv[2:]
try:
    split_at = args.index("::DIRS::")
except ValueError:
    split_at = len(args)

payload = {
    "files": args[:split_at],
    "dirs": args[split_at + 1:] if split_at < len(args) else [],
}
with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
PY
unset copied_dirs payload_dir payload_dir_name copied_payload payload payload_name installed_manifest installed_files installed_ini python_cmd

echo " Installation completed successfully!"
echo " For Steam, add this to the launch options: \"$fgmod_path/fgmod\" %COMMAND%"
echo " For Heroic, add this as a new wrapper: \"$fgmod_path/fgmod\""
logger -t fgmod "Installation completed successfully for $exe_folder_path"

# === Execute original command ===
if [[ $# -gt 1 ]]; then
  # Log to both file and system journal
  logger -t fgmod "=================="
  logger -t fgmod "Debug Info (Launch Mode):"
  logger -t fgmod "Number of arguments: $#"
  for i in $(seq 1 $#); do
    logger -t fgmod "Arg $i: ${!i}"
  done
  logger -t fgmod "Final executable path: $exe_folder_path"
  logger -t fgmod "=================="
  
  # Execute the original command
  export SteamDeck=0
  # Build WINEDLLOVERRIDES from the actual proxy DLL name (strip extension to get the stem)
  if [[ "$dll_name" == *.dll ]]; then
    _wine_dll="${dll_name%.dll}"
    export WINEDLLOVERRIDES="$WINEDLLOVERRIDES,${_wine_dll}=n,b"
    unset _wine_dll
  fi
  # .asi files are loaded by an ASI loader — no WINEDLLOVERRIDES entry needed

  # Filter out leading -- separators (from Steam launch options)
  while [[ $# -gt 0 && "$1" == "--" ]]; do
    shift
  done

  exec >/dev/null 2>&1
  "$@"
else
  echo "Done!"
  echo "----------------------------------------"
  echo "Debug Info (Standalone Mode):"
  echo "Number of arguments: $#"
  for i in $(seq 1 $#); do
    echo "Arg $i: ${!i}"
  done
  echo "Final executable path: $exe_folder_path"
  echo "----------------------------------------"
  
  # Also log standalone mode to journal
  logger -t fgmod "=================="
  logger -t fgmod "Debug Info (Standalone Mode):"
  logger -t fgmod "Number of arguments: $#"
  for i in $(seq 1 $#); do
    logger -t fgmod "Arg $i: ${!i}"
  done
  logger -t fgmod "Final executable path: $exe_folder_path"
  logger -t fgmod "=================="
fi
