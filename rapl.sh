#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "Run this installer with: sudo bash ${0##*/}" >&2
    exit 1
fi
command -v dnf >/dev/null 2>&1 || { echo 'Fedora dnf was not found.' >&2; exit 1; }

STATE_DIR=/var/lib/raplctl/rollback
MANAGED_PATHS=(
  /usr/local/sbin/raplctl
  /usr/local/bin/rapl
  /etc/rapl-battery-watts
  /etc/rapl-reapply-seconds
  /etc/rapl-igpu-max-mhz
  /etc/systemd/system/rapl-apply.service
  /etc/systemd/system/rapl-watch.service
  /etc/acpi/events/rapl-ac-adapter
)
MANAGED_DIRS=(/usr/local/sbin /usr/local/bin /etc/acpi /etc/acpi/events)

# Preserve the very first baseline across upgrades. Older releases did not
# preserve every original value; do not pretend a historical state is known.
if [[ ! -f "$STATE_DIR/path-manifest.tsv" ]]; then
    if [[ -d /var/lib/raplctl ]]; then parent_dir_created=0; else install -d -m 0700 /var/lib/raplctl; parent_dir_created=1; fi
    [[ -d "$STATE_DIR" ]] || mkdir -m 0700 "$STATE_DIR"
    [[ -d "$STATE_DIR/files" ]] || mkdir -m 0700 "$STATE_DIR/files"
    printf '%s\n' "$parent_dir_created" > "$STATE_DIR/parent-dir-created"
    : > "$STATE_DIR/path-manifest.tsv"
    : > "$STATE_DIR/dir-manifest.tsv"
    legacy=0
    if [[ -f /usr/local/sbin/raplctl ]] && grep -q 'RAPL package power cap' /usr/local/sbin/raplctl 2>/dev/null; then legacy=1; fi
    if (( legacy )); then
        touch "$STATE_DIR/legacy-install"
        for path in "${MANAGED_PATHS[@]}"; do printf '0\t%s\n' "$path" >> "$STATE_DIR/path-manifest.tsv"; done
        for dir in "${MANAGED_DIRS[@]}"; do printf '1\t%s\n' "$dir" >> "$STATE_DIR/dir-manifest.tsv"; done
        printf 'acpid-installed-before=unknown\npython3-installed-before=unknown\n' > "$STATE_DIR/package-state"
        printf 'acpid.service\tunknown\tunknown\nrapl-watch.service\tdisabled\tinactive\nrapl-apply.service\tdisabled\tinactive\n' > "$STATE_DIR/service-state.tsv"
        echo 'WARNING: legacy RAPL install detected. Original pre-legacy limits/files may not be recoverable.'
    else
        for path in "${MANAGED_PATHS[@]}"; do
            if [[ -e "$path" || -L "$path" ]]; then
                rel=${path#/}; mkdir -p "$STATE_DIR/files/$(dirname "$rel")"; cp -a -- "$path" "$STATE_DIR/files/$rel"
                printf '1\t%s\n' "$path" >> "$STATE_DIR/path-manifest.tsv"
            else printf '0\t%s\n' "$path" >> "$STATE_DIR/path-manifest.tsv"; fi
        done
        for dir in "${MANAGED_DIRS[@]}"; do
            if [[ -d "$dir" ]]; then printf '1\t%s\n' "$dir" >> "$STATE_DIR/dir-manifest.tsv"; else printf '0\t%s\n' "$dir" >> "$STATE_DIR/dir-manifest.tsv"; fi
        done
        rpm -q acpid >/dev/null 2>&1 && acpid_before=1 || acpid_before=0
        rpm -q python3 >/dev/null 2>&1 && python_before=1 || python_before=0
        printf 'acpid-installed-before=%s\npython3-installed-before=%s\n' "$acpid_before" "$python_before" > "$STATE_DIR/package-state"
        : > "$STATE_DIR/service-state.tsv"
        for unit in acpid.service rapl-watch.service rapl-apply.service; do
            enabled=$(systemctl is-enabled "$unit" 2>/dev/null || true); active=$(systemctl is-active "$unit" 2>/dev/null || true)
            [[ -n "$enabled" ]] || enabled=not-found; [[ -n "$active" ]] || active=inactive
            printf '%s\t%s\t%s\n' "$unit" "$enabled" "$active" >> "$STATE_DIR/service-state.tsv"
        done
    fi
fi

# Extend an existing rollback manifest for the configurable reapply interval.
# Older installations have a manifest already, so record this new path now.
if ! awk -F '\t' '$2 == "/etc/rapl-reapply-seconds" { found=1 } END { exit !found }' "$STATE_DIR/path-manifest.tsv"; then
    if [[ -e /etc/rapl-reapply-seconds || -L /etc/rapl-reapply-seconds ]]; then
        mkdir -p "$STATE_DIR/files/etc"
        cp -a -- /etc/rapl-reapply-seconds "$STATE_DIR/files/etc/rapl-reapply-seconds"
        printf '1\t/etc/rapl-reapply-seconds\n' >> "$STATE_DIR/path-manifest.tsv"
    else
        printf '0\t/etc/rapl-reapply-seconds\n' >> "$STATE_DIR/path-manifest.tsv"
    fi
fi

# Preserve any pre-existing iGPU-cap config on upgrades, and remove our new
# config on uninstall only when it did not exist before this installer.
if ! awk -F '\t' '$2 == "/etc/rapl-igpu-max-mhz" { found=1 } END { exit !found }' "$STATE_DIR/path-manifest.tsv"; then
    if [[ -e /etc/rapl-igpu-max-mhz || -L /etc/rapl-igpu-max-mhz ]]; then
        mkdir -p "$STATE_DIR/files/etc"
        cp -a -- /etc/rapl-igpu-max-mhz "$STATE_DIR/files/etc/rapl-igpu-max-mhz"
        printf '1\t/etc/rapl-igpu-max-mhz\n' >> "$STATE_DIR/path-manifest.tsv"
    else
        printf '0\t/etc/rapl-igpu-max-mhz\n' >> "$STATE_DIR/path-manifest.tsv"
    fi
fi

packages=()
rpm -q acpid >/dev/null 2>&1 || packages+=(acpid)
command -v python3 >/dev/null 2>&1 || packages+=(python3)
if ((${#packages[@]})); then dnf install -y --setopt=install_weak_deps=False "${packages[@]}"; fi
if ! python3 -c 'import curses' >/dev/null 2>&1; then
    echo 'ERROR: Python curses is unavailable; the TUI cannot start.' >&2
    exit 1
fi

# Stop the previous policy writer while replacing its code.
systemctl stop rapl-watch.service rapl-apply.service >/dev/null 2>&1 || true
for dir in /usr/local/sbin /usr/local/bin /etc/acpi /etc/acpi/events; do [[ -d "$dir" ]] || install -d -m 0755 "$dir"; done
rm -f /usr/local/sbin/raplctl /usr/local/bin/rapl /etc/systemd/system/rapl-apply.service /etc/systemd/system/rapl-watch.service /etc/acpi/events/rapl-ac-adapter

cat > /usr/local/sbin/raplctl <<'PYTHON'
#!/usr/bin/python3
"""RAPL power controller and Intel iGPU clock-cap TUI for Fedora."""
import curses
import fcntl
import glob
import json
import os
import re
import select
import shutil
import subprocess
import sys
import textwrap
import time
from pathlib import Path

CONFIG = Path('/etc/rapl-battery-watts')
REAPPLY_CONFIG = Path('/etc/rapl-reapply-seconds')
IGPU_CAP_CONFIG = Path('/etc/rapl-igpu-max-mhz')
LOCK = Path('/run/raplctl.lock')
ROLLBACK_DIR = Path('/var/lib/raplctl/rollback')
LIMITS_SNAPSHOT = ROLLBACK_DIR / 'rapl-original-limits.json'
IGPU_SNAPSHOT = ROLLBACK_DIR / 'igpu-original-clock.json'
PATH_MANIFEST = ROLLBACK_DIR / 'path-manifest.tsv'
SERVICE_MANIFEST = ROLLBACK_DIR / 'service-state.tsv'
DIR_MANIFEST = ROLLBACK_DIR / 'dir-manifest.tsv'
PACKAGE_STATE = ROLLBACK_DIR / 'package-state'
DEFAULT_WATTS = 7.0
ZONE_RE = re.compile(r'[A-Za-z0-9_.-]*rapl(?:-mmio)?:\d+$', re.IGNORECASE)
CONSTRAINT_RE = re.compile(r'constraint_(\d+)_power_limit_uw$')


def read_text(path):
    try: return Path(path).read_text().strip()
    except (OSError, UnicodeError): return ''


def run_capture(argv, timeout=180):
    try:
        return subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, check=False, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None


def battery_watts():
    try:
        value = float(read_text(CONFIG))
        if 0.5 <= value <= 1000.0: return value
    except (TypeError, ValueError): pass
    return DEFAULT_WATTS


def save_battery_watts(value):
    if not (0.5 <= value <= 1000.0): raise ValueError('Enter a value from 0.5 to 1000 watts.')
    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    temp = CONFIG.with_name(CONFIG.name + '.tmp')
    temp.write_text(f'{value:.3f}\n'); os.chmod(temp, 0o644); os.replace(temp, CONFIG)


def reapply_interval_seconds():
    """Read the live interval; invalid/missing settings default to seven seconds."""
    try:
        value = int(read_text(REAPPLY_CONFIG))
        if 1 <= value <= 3600:
            return value
    except (TypeError, ValueError, OSError):
        pass
    return 7


def save_reapply_interval(seconds):
    if isinstance(seconds, bool) or not isinstance(seconds, int) or not 1 <= seconds <= 3600:
        raise ValueError('Enter a whole number from 1 to 3600 seconds.')
    REAPPLY_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    temp = REAPPLY_CONFIG.with_name(REAPPLY_CONFIG.name + '.tmp')
    temp.write_text(f'{seconds}\n')
    os.chmod(temp, 0o644)
    os.replace(temp, REAPPLY_CONFIG)


def igpu_cap_mhz():
    """Return the configured iGPU maximum in MHz; zero means disabled."""
    try:
        value = int(read_text(IGPU_CAP_CONFIG) or '0')
        if 0 <= value <= 10000:
            return value
    except (TypeError, ValueError, OSError):
        pass
    return 0


def save_igpu_cap_mhz(value):
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 10000:
        raise ValueError('Enter a whole number from 0 to 10000 MHz; 0 disables the cap.')
    IGPU_CAP_CONFIG.parent.mkdir(parents=True, exist_ok=True)
    temp = IGPU_CAP_CONFIG.with_name(IGPU_CAP_CONFIG.name + '.tmp')
    temp.write_text(f'{value}\n')
    os.chmod(temp, 0o644)
    os.replace(temp, IGPU_CAP_CONFIG)


def _int_value(path):
    try:
        raw = read_text(path)
        return int(raw) if raw else None
    except (TypeError, ValueError, OSError):
        return None


def _frequency_scale(raw_values):
    """Map driver-reported values to MHz; Xe kernels can expose kHz values."""
    values = [v for v in raw_values if v is not None]
    return 1000 if values and max(values) > 20000 else 1


def detect_igpu():
    """Find the Intel integrated graphics DRM card and readable clock controls."""
    candidates = []
    drm_root = Path('/sys/class/drm')
    for card in sorted(drm_root.glob('card[0-9]*')):
        match = re.fullmatch(r'card(\d+)', card.name)
        if not match:
            continue  # Ignore connector entries such as card0-eDP-1.
        device_link = card / 'device'
        try:
            device_path = device_link.resolve(strict=True)
        except OSError:
            continue
        if read_text(device_path / 'vendor').lower() != '0x8086':
            continue
        if not read_text(device_path / 'class').lower().startswith('0x03'):
            continue
        try:
            driver = (device_path / 'driver').resolve(strict=True).name
        except OSError:
            continue
        if driver not in ('i915', 'xe'):
            continue

        controls = []
        if driver == 'i915':
            # i915 exports these attributes on the DRM card directory.
            max_file = card / 'gt_max_freq_mhz'
            min_file = card / 'gt_min_freq_mhz'
            if max_file.is_file() and min_file.is_file():
                controls.append({
                    'id': 'i915-gt', 'max_file': max_file, 'min_file': min_file,
                    'hw_min_file': card / 'gt_RPn_freq_mhz',
                    'hw_max_file': card / 'gt_RP0_freq_mhz',
                    'actual_file': card / 'gt_act_freq_mhz',
                    'requested_file': card / 'gt_cur_freq_mhz',
                    'scale': 1,
                })
        else:
            # Xe exposes one freq0 control for each GT under tile#/gt#/freq0.
            for freq_dir in sorted(device_path.glob('tile*/gt*/freq0')):
                max_file, min_file = freq_dir / 'max_freq', freq_dir / 'min_freq'
                if not max_file.is_file() or not min_file.is_file():
                    continue
                raw_limits = [_int_value(freq_dir / name) for name in ('rp0_freq', 'rpn_freq', 'max_freq', 'min_freq')]
                scale = _frequency_scale(raw_limits)
                controls.append({
                    'id': str(freq_dir.relative_to(device_path)),
                    'max_file': max_file, 'min_file': min_file,
                    'hw_min_file': freq_dir / 'rpn_freq',
                    'hw_max_file': freq_dir / 'rp0_freq',
                    'actual_file': freq_dir / 'act_freq',
                    'requested_file': freq_dir / 'cur_freq',
                    'scale': scale,
                })

        if not controls:
            continue
        boot_vga = read_text(device_path / 'boot_vga') == '1'
        candidates.append({
            'card_number': int(match.group(1)),
            'card_name': card.name,
            'device_path': str(device_path),
            'driver': driver,
            'boot_vga': boot_vga,
            'controls': controls,
        })

    if not candidates:
        raise RuntimeError('No Intel iGPU with supported i915/Xe clock controls was found.')
    integrated = [gpu for gpu in candidates if Path(gpu['device_path']).name == '0000:00:02.0']
    if len(integrated) == 1:
        return integrated[0]
    primary = [gpu for gpu in candidates if gpu['boot_vga']]
    if len(primary) == 1:
        return primary[0]
    if len(candidates) == 1:
        return candidates[0]
    # Don't silently cap an Intel discrete GPU when more than one Intel GPU
    # exists and sysfs does not identify a unique boot/primary adapter.
    found = ', '.join(f"DRM card{g['card_number']} ({g['driver']}, {g['device_path'].rsplit('/', 1)[-1]})" for g in candidates)
    raise RuntimeError(f'Intel iGPU selection is ambiguous ({found}); refusing to change clocks.')


def _load_igpu_snapshot():
    if not IGPU_SNAPSHOT.exists():
        return None
    try:
        data = json.loads(IGPU_SNAPSHOT.read_text())
    except (OSError, ValueError) as exc:
        raise RuntimeError(f'Cannot read iGPU clock rollback snapshot: {exc}')
    if not isinstance(data, dict) or data.get('version') != 1 or not isinstance(data.get('controls'), list):
        raise RuntimeError('The iGPU clock rollback snapshot has an unsupported format.')
    return data


def _snapshot_control_value(snapshot, gpu, control):
    if not snapshot or snapshot.get('device_path') != gpu['device_path']:
        return None
    for record in snapshot.get('controls', []):
        if record.get('id') == control['id']:
            try:
                return int(record['original_max_raw'])
            except (KeyError, TypeError, ValueError):
                return None
    return None


def _clock_control_status(gpu, control, snapshot=None):
    scale = control['scale']
    current_min_raw = _int_value(control['min_file'])
    current_max_raw = _int_value(control['max_file'])
    if current_min_raw is None or current_max_raw is None:
        raise RuntimeError(f"{control['id']}: cannot read current min/max clock values.")
    hardware_min_raw = _int_value(control['hw_min_file'])
    hardware_max_raw = _int_value(control['hw_max_file'])
    original_raw = _snapshot_control_value(snapshot, gpu, control)
    if original_raw is None:
        original_raw = current_max_raw
    # If hardware bounds are not exported, fall back to the captured original
    # maximum (or the current driver maximum before the first cap was applied).
    low_raw = max(current_min_raw, hardware_min_raw if hardware_min_raw is not None else current_min_raw)
    high_raw = min(hardware_max_raw if hardware_max_raw is not None else original_raw, original_raw)
    actual_raw = _int_value(control['actual_file'])
    requested_raw = _int_value(control['requested_file'])
    return {
        'id': control['id'], 'scale': scale,
        'current_min_mhz': current_min_raw / scale,
        'current_max_mhz': current_max_raw / scale,
        'hardware_min_mhz': (hardware_min_raw / scale) if hardware_min_raw is not None else (current_min_raw / scale),
        'hardware_max_mhz': (hardware_max_raw / scale) if hardware_max_raw is not None else (original_raw / scale),
        'range_min_mhz': low_raw / scale,
        'range_max_mhz': high_raw / scale,
        'original_max_raw': original_raw,
        'current_actual_mhz': (actual_raw / scale) if actual_raw is not None else None,
        'current_requested_mhz': (requested_raw / scale) if requested_raw is not None else None,
        'max_file': control['max_file'],
    }


def igpu_clock_status():
    target = igpu_cap_mhz()
    try:
        gpu = detect_igpu()
        snapshot = _load_igpu_snapshot()
        if snapshot and snapshot.get('device_path') != gpu['device_path']:
            raise RuntimeError('Saved iGPU clock baseline belongs to a different PCI device; refusing to overwrite it.')
        controls = [_clock_control_status(gpu, c, snapshot) for c in gpu['controls']]
        lower = max(c['range_min_mhz'] for c in controls)
        upper = min(c['range_max_mhz'] for c in controls)
        current = '/'.join(f"{c['current_max_mhz']:.0f}" for c in controls)
        actual_values = [c['current_actual_mhz'] for c in controls if c['current_actual_mhz'] is not None]
        actual = '/'.join(f'{v:.0f}' for v in actual_values) if actual_values else 'n/a'
        return {
            'ok': True, 'gpu': gpu, 'controls': controls,
            'minimum_mhz': lower, 'maximum_mhz': upper,
            'current_max': current, 'actual': actual, 'target_mhz': target,
            'detail': f"DRM card{gpu['card_number']} / {gpu['driver']}; current max {current} MHz; actual {actual} MHz",
        }
    except (OSError, RuntimeError, ValueError) as exc:
        return {'ok': False, 'target_mhz': target, 'detail': str(exc)}


def capture_igpu_snapshot(gpu):
    existing = _load_igpu_snapshot()
    if existing:
        if existing.get('device_path') != gpu['device_path']:
            raise RuntimeError('Saved iGPU clock baseline belongs to a different PCI device.')
        return existing
    controls = []
    for control in gpu['controls']:
        current = _int_value(control['max_file'])
        if current is None:
            raise RuntimeError(f"{control['id']}: current maximum clock is unreadable.")
        controls.append({'id': control['id'], 'original_max_raw': current})
    snapshot = {
        'version': 1, 'device_path': gpu['device_path'], 'driver': gpu['driver'],
        'card_number_at_capture': gpu['card_number'], 'controls': controls,
    }
    save_json_atomic(IGPU_SNAPSHOT, snapshot)
    return snapshot


def _apply_igpu_cap_locked(target_mhz, force=False):
    """Enforce an iGPU maximum-frequency cap; never raise above its baseline."""
    if isinstance(target_mhz, bool) or not isinstance(target_mhz, int) or not 1 <= target_mhz <= 10000:
        raise ValueError('The iGPU cap must be a whole number from 1 to 10000 MHz.')
    gpu = detect_igpu()
    snapshot = _load_igpu_snapshot()
    if snapshot and snapshot.get('device_path') != gpu['device_path']:
        raise RuntimeError('Saved iGPU clock baseline belongs to a different PCI device; refusing to write clocks.')
    statuses = [_clock_control_status(gpu, c, snapshot) for c in gpu['controls']]
    low = max(c['range_min_mhz'] for c in statuses)
    high = min(c['range_max_mhz'] for c in statuses)
    if low > high:
        raise RuntimeError(f'Invalid iGPU clock range detected ({low:.0f}-{high:.0f} MHz). No changes made.')
    if not low <= target_mhz <= high:
        raise ValueError(f'iGPU cap must be between {low:.0f} and {high:.0f} MHz for DRM card{gpu["card_number"]}.')
    if not snapshot:
        snapshot = capture_igpu_snapshot(gpu)
        statuses = [_clock_control_status(gpu, c, snapshot) for c in gpu['controls']]

    attempted = []
    results = []
    try:
        for control in gpu['controls']:
            current_raw = _int_value(control['max_file'])
            if current_raw is None:
                raise RuntimeError(f"{control['id']}: cannot read current max clock.")
            desired_raw = int(round(target_mhz * control['scale']))
            # TUI changes may raise a previous lower cap, but routine watcher
            # passes only reduce a reset/too-high value; they never raise it.
            should_write = force or current_raw > desired_raw
            if should_write and current_raw != desired_raw:
                attempted.append((control['max_file'], current_raw))
                control['max_file'].write_text(f'{desired_raw}\n')
            actual_raw = _int_value(control['max_file'])
            if actual_raw is None:
                raise RuntimeError(f"{control['id']}: max clock became unreadable after write.")
            if actual_raw > desired_raw:
                raise RuntimeError(f"{control['id']}: driver read back {actual_raw / control['scale']:.0f} MHz, above requested cap {target_mhz} MHz.")
            results.append({'id': control['id'], 'current_max_mhz': actual_raw / control['scale']})
    except (OSError, RuntimeError, ValueError) as exc:
        for path, old_value in reversed(attempted):
            try:
                path.write_text(f'{old_value}\n')
            except OSError:
                pass
        raise RuntimeError(f'iGPU cap was not fully applied: {exc}') from exc
    return {
        'gpu_number': gpu['card_number'], 'driver': gpu['driver'],
        'requested_mhz': target_mhz, 'controls': results,
        'changed': bool(attempted),
    }


def apply_igpu_cap(target_mhz, force=False):
    """Serialize background cap enforcement with TUI and RAPL writes."""
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with LOCK.open('w') as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        # Watcher passes use the latest saved value only after obtaining the
        # lock, preventing a stale pre-lock read from undoing a TUI change.
        if not force:
            target_mhz = igpu_cap_mhz()
            if target_mhz == 0:
                return {'changed': False, 'gpu_number': None, 'driver': None, 'controls': []}
        return _apply_igpu_cap_locked(target_mhz, force=force)


def set_igpu_cap(target_mhz):
    """Set and persist a cap atomically with respect to the watcher."""
    if target_mhz == 0:
        return disable_igpu_cap()
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with LOCK.open('w') as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        result = _apply_igpu_cap_locked(target_mhz, force=True)
        try:
            save_igpu_cap_mhz(target_mhz)
        except OSError as exc:
            # Do not leave a live cap active when its configuration could not
            # be persisted; restore the first-use baseline before reporting it.
            rollback_warnings = restore_igpu_clock()
            suffix = ('; rollback warning: ' + '; '.join(rollback_warnings)) if rollback_warnings else ''
            raise RuntimeError(f'Could not save iGPU cap configuration: {exc}{suffix}') from exc
        return result


def restore_igpu_clock():
    """Restore the iGPU max-clock values captured before our first cap."""
    try:
        snapshot = _load_igpu_snapshot()
    except (OSError, RuntimeError, ValueError) as exc:
        return [f'Could not read iGPU clock rollback data: {exc}']
    if not snapshot:
        return []
    warnings = []
    try:
        gpu = detect_igpu()
    except (OSError, RuntimeError, ValueError) as exc:
        return [f'Could not detect the saved iGPU for clock restoration: {exc}']
    if snapshot.get('device_path') != gpu['device_path']:
        return ['Saved iGPU clock baseline belongs to a different PCI device; no clocks were changed.']
    current_controls = {control['id']: control for control in gpu['controls']}
    for record in snapshot.get('controls', []):
        control_id = record.get('id')
        control = current_controls.get(control_id)
        if control is None:
            warnings.append(f'{control_id}: clock control is missing; original max could not be restored.')
            continue
        try:
            original = int(record['original_max_raw'])
            control['max_file'].write_text(f'{original}\n')
            actual = _int_value(control['max_file'])
            if actual != original:
                warnings.append(f'{control_id}: expected original max {original}, read back {actual}.')
        except (OSError, TypeError, ValueError, KeyError) as exc:
            warnings.append(f'{control_id}: failed to restore original max: {exc}')
    return warnings


def disable_igpu_cap():
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with LOCK.open('w') as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        warnings = restore_igpu_clock()
        if warnings:
            raise RuntimeError('; '.join(warnings))
        save_igpu_cap_mhz(0)
        return 'iGPU cap disabled; saved original maximum clock restored.'


def power_state():
    paths = sorted(Path('/sys/class/power_supply').glob('*'))
    online_values = []
    for path in paths:
        kind = read_text(path / 'type')
        if kind in ('Mains', 'USB', 'USB_C', 'USB_PD', 'Wireless'):
            online = read_text(path / 'online')
            if online in ('0', '1'): online_values.append(online == '1')
    if online_values: return 'AC' if any(online_values) else 'BATTERY'
    statuses = [read_text(p / 'status').lower() for p in paths if read_text(p / 'type') == 'Battery']
    statuses = [s for s in statuses if s in ('charging', 'discharging', 'full')]
    if 'discharging' in statuses: return 'BATTERY'
    if statuses and all(s in ('charging', 'full') for s in statuses): return 'AC'
    return None


def package_domains():
    """Find top-level RAPL zones by identifier/constraint shape, not display label."""
    found = {}
    for pattern in ('/sys/class/powercap/*', '/sys/class/powercap/*/*',
                    '/sys/devices/virtual/powercap/*', '/sys/devices/virtual/powercap/*/*'):
        for raw in glob.glob(pattern):
            path = Path(raw)
            if not ZONE_RE.fullmatch(path.name): continue
            if not path.is_dir() or not (path / 'constraint_0_power_limit_uw').is_file(): continue
            found[str(path.resolve())] = path
    return sorted(found.values(), key=lambda p: str(p))


def constraints_for(domain):
    result = []
    for file in sorted(domain.glob('constraint_*_power_limit_uw')):
        match = CONSTRAINT_RE.fullmatch(file.name)
        if not match: continue
        i = int(match.group(1)); max_file = domain / f'constraint_{i}_max_power_uw'
        if not max_file.exists(): continue
        try:
            current, maximum = int(read_text(file)), int(read_text(max_file))
            minimum = int(read_text(domain / f'constraint_{i}_min_power_uw') or '0')
        except ValueError: continue
        name = read_text(domain / f'constraint_{i}_name') or f'constraint {i}'
        result.append({'index': i, 'file': file, 'current': current,
                       'minimum': minimum, 'maximum': maximum, 'name': name})
    return result


def save_json_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + '.tmp')
    temp.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')
    os.chmod(temp, 0o600); os.replace(temp, path)


def capture_original_limits(domains=None):
    if LIMITS_SNAPSHOT.exists():
        try: snapshot = json.loads(LIMITS_SNAPSHOT.read_text())
        except (OSError, ValueError) as exc: raise RuntimeError(f'Cannot read RAPL rollback snapshot: {exc}')
    else:
        provenance = 'legacy-pre-upgrade-observation' if (ROLLBACK_DIR / 'legacy-install').exists() else 'original-pre-install'
        snapshot = {'version': 1, 'provenance': provenance, 'limits': {}}
    for domain in domains if domains is not None else package_domains():
        for item in constraints_for(domain):
            key = str(item['file'].resolve())
            snapshot['limits'].setdefault(key, {'path': key, 'value_uw': int(item['current']),
                'domain': read_text(domain / 'name') or domain.name, 'constraint': item['name']})
    save_json_atomic(LIMITS_SNAPSHOT, snapshot)
    return snapshot


def restore_original_limits():
    if not LIMITS_SNAPSHOT.exists(): raise RuntimeError('No saved RAPL baseline; original power limits are unknown.')
    snapshot = json.loads(LIMITS_SNAPSHOT.read_text()); restored = 0; warnings = []
    for record in snapshot.get('limits', {}).values():
        path = Path(record['path'])
        if not path.is_file(): warnings.append(f'{path}: sysfs path missing'); continue
        try:
            path.write_text(f"{int(record['value_uw'])}\n")
            if int(read_text(path)) != int(record['value_uw']): warnings.append(f'{path}: readback differed')
            else: restored += 1
        except (OSError, ValueError, KeyError) as exc: warnings.append(f'{path}: {exc}')
    if snapshot.get('provenance') != 'original-pre-install':
        warnings.append('Legacy-install baseline: values were captured during upgrade, not before the older version.')
    if not snapshot.get('limits'): warnings.append('No RAPL constraints were captured.')
    return restored, warnings


def apply_policy(state=None, quiet=False):
    """Apply policy and return write/readback failures instead of hiding them."""
    state = state or power_state()
    if state not in ('AC', 'BATTERY'):
        raise RuntimeError('Power source is unknown; no limits changed.')
    domains = package_domains()
    if not domains:
        raise RuntimeError('No supported top-level RAPL constraints found.')
    target_uw = int(round(battery_watts() * 1_000_000))
    changes, warnings, notices = [], [], []
    attempted = verified = 0
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with LOCK.open('w') as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        capture_original_limits(domains)
        for domain in domains:
            label = read_text(domain / 'name') or domain.name
            for item in constraints_for(domain):
                # Firmware often exposes disabled constraints with max=0.
                # Ignore those rather than falsely reporting a write failure.
                if item['maximum'] <= 0 or item['minimum'] > item['maximum']:
                    continue
                desired = item['maximum'] if state == 'AC' else max(item['minimum'], min(target_uw, item['maximum']))
                attempted += 1
                if state == 'BATTERY' and target_uw < item['minimum']:
                    notices.append(
                        f'{label} / {item["name"]}: requested {battery_watts():.2f} W is below '
                        f'the driver minimum {item["minimum"] / 1e6:.2f} W; using the minimum'
                    )
                try:
                    item['file'].write_text(f'{desired}\n')
                    raw_actual = read_text(item['file'])
                    actual = int(raw_actual)
                    changes.append((label, item['name'], desired, actual, item['maximum']))
                    if actual == desired:
                        verified += 1
                    else:
                        warnings.append(
                            f'{label} / {item["name"]}: requested {desired / 1e6:.2f} W, '
                            f'but read back {actual / 1e6:.2f} W'
                        )
                except (OSError, ValueError) as exc:
                    warnings.append(f'{label} / {item["name"]}: write/readback failed: {exc}')
        fcntl.flock(lock_file, fcntl.LOCK_UN)
    if not changes:
        raise RuntimeError('; '.join(warnings) or 'No usable RAPL limits could be changed.')
    result = {'state': state, 'changes': changes, 'warnings': warnings, 'notices': notices,
              'attempted': attempted, 'verified': verified}
    if not quiet:
        mode = 'maximum reported by hardware' if state == 'AC' else f'{battery_watts():g} W battery target'
        print(f'Power source: {state}; policy: {mode}')
        for label, name, desired, actual, maximum in changes:
            status = 'OK' if actual == desired else 'MISMATCH'
            print(f'  {status}: {label} / {name}: target {desired / 1e6:.2f} W, read back {actual / 1e6:.2f} W (driver max {maximum / 1e6:.2f} W)')
        for warning in warnings:
            print(f'WARNING: {warning}', file=sys.stderr)
        for notice in notices:
            print(f'NOTICE: {notice}', file=sys.stderr)
    return result


def read_tsv(path, fields):
    if not path.exists(): return []
    rows = []
    for line in path.read_text().splitlines():
        parts = line.split('\t', fields - 1)
        if len(parts) == fields: rows.append(parts)
    return rows


def restore_file_manifest(manifest, backup_root):
    warnings = []
    for existed, raw_path in read_tsv(manifest, 2):
        target = Path(raw_path)
        try:
            if target.is_dir() and not target.is_symlink():
                warnings.append(f'{target}: unexpected directory; left untouched'); continue
            target.unlink(missing_ok=True)
            if existed == '1':
                backup = backup_root / raw_path.lstrip('/')
                if not (backup.exists() or backup.is_symlink()): warnings.append(f'{target}: backup missing'); continue
                target.parent.mkdir(parents=True, exist_ok=True)
                result = subprocess.run(['cp', '-a', '--', str(backup), str(target)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                if result.returncode: warnings.append(f'{target}: {result.stdout.strip()}')
        except OSError as exc: warnings.append(f'{target}: {exc}')
    return warnings


def run_systemctl(*args):
    try:
        result = subprocess.run(['systemctl', *args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        return result.returncode, result.stdout.strip()
    except OSError as exc: return 127, str(exc)


def package_values():
    values = {}
    if PACKAGE_STATE.exists():
        for line in PACKAGE_STATE.read_text().splitlines():
            if '=' in line:
                key, value = line.split('=', 1); values[key] = value
    return values


def restore_service_state(unit, enabled, active, warnings):
    if enabled == 'enabled': actions = [('enable', unit)]
    elif enabled == 'disabled': actions = [('disable', unit)]
    elif enabled == 'enabled-runtime': actions = [('enable', '--runtime', unit)]
    else: actions = []
    for args in actions:
        rc, out = run_systemctl(*args)
        if rc: warnings.append(f'Could not restore {unit} enablement: {out or rc}')
    if active == 'active': args = ('start', unit)
    elif active in ('inactive', 'failed'): args = ('stop', unit)
    else: args = ()
    if args:
        rc, out = run_systemctl(*args)
        if rc and 'not found' not in out.lower() and 'not loaded' not in out.lower(): warnings.append(f'Could not restore {unit} active state: {out or rc}')


def uninstall_installation():
    messages = []; warnings = []
    for unit in ('rapl-watch.service', 'rapl-apply.service'):
        rc, out = run_systemctl('disable', '--now', unit)
        if rc and 'not found' not in out.lower() and 'not loaded' not in out.lower(): warnings.append(f'Could not stop {unit}: {out or rc}')
    # Restore the iGPU clock and RAPL limits before restoring managed files.
    warnings.extend(restore_igpu_clock())
    try:
        count, ws = restore_original_limits(); messages.append(f'Restored {count} saved RAPL constraint value(s).'); warnings.extend(ws)
    except (OSError, ValueError, RuntimeError) as exc: warnings.append(str(exc))
    warnings.extend(restore_file_manifest(PATH_MANIFEST, ROLLBACK_DIR / 'files'))
    try: LOCK.unlink(missing_ok=True)
    except OSError as exc: warnings.append(f'Could not remove runtime lock: {exc}')
    rc, out = run_systemctl('daemon-reload')
    if rc: warnings.append(f'systemd daemon-reload failed: {out or rc}')

    packages = package_values(); service_states = {u: (en, ac) for u, en, ac in read_tsv(SERVICE_MANIFEST, 3)}
    manifest_exists = {path for exists, path in read_tsv(PATH_MANIFEST, 2) if exists == '1'}
    if packages.get('acpid-installed-before') == '0':
        run_systemctl('disable', '--now', 'acpid.service')
        rc, out = subprocess.getstatusoutput('dnf remove -y acpid')
        if rc: warnings.append(f'Could not remove acpid installed by RAPL: {out or rc}')
    elif packages.get('acpid-installed-before') == '1':
        en, ac = service_states.get('acpid.service', ('unknown', 'unknown')); restore_service_state('acpid.service', en, ac, warnings)
    elif packages.get('acpid-installed-before') == 'unknown':
        warnings.append('Prior acpid package/service state was not recorded by the legacy installer.')
    if packages.get('python3-installed-before') == '0':
        warnings.append('Python 3 was installed because it was missing; it was retained to avoid removing a shared system runtime.')
    for unit, unitpath in [('rapl-watch.service', '/etc/systemd/system/rapl-watch.service'), ('rapl-apply.service', '/etc/systemd/system/rapl-apply.service')]:
        if unitpath in manifest_exists:
            en, ac = service_states.get(unit, ('unknown', 'unknown')); restore_service_state(unit, en, ac, warnings)
    for existed, raw_dir in reversed(read_tsv(DIR_MANIFEST, 2)):
        if existed == '0':
            try: Path(raw_dir).rmdir()
            except OSError: pass
    if warnings:
        messages.append('UNINSTALL COMPLETED WITH WARNINGS. Recovery data retained at /var/lib/raplctl/rollback.')
        messages.extend('WARNING: ' + w for w in warnings)
    else:
        try:
            parent_created = read_text(ROLLBACK_DIR / 'parent-dir-created') == '1'
            shutil.rmtree(ROLLBACK_DIR)
            if parent_created:
                try: Path('/var/lib/raplctl').rmdir()
                except OSError: pass
            messages.append('Uninstall finished. Saved RAPL limits, iGPU clock limits, and pre-existing managed files were restored.')
        except OSError as exc: messages.append(f'WARNING: rollback data remains at {ROLLBACK_DIR}: {exc}')
    return messages


def rapl_verification():
    """Compare live readbacks with the expected limit and list mismatches."""
    state = power_state()
    if state not in ('AC', 'BATTERY'):
        return {'ok': None, 'state': state or 'unknown', 'matched': 0, 'total': 0,
                'detail': 'Power source cannot be identified.', 'mismatches': [], 'notices': []}
    domains = package_domains()
    if not domains:
        return {'ok': False, 'state': state, 'matched': 0, 'total': 0,
                'detail': 'No RAPL package domains found.', 'mismatches': [], 'notices': []}
    target_uw = int(round(battery_watts() * 1_000_000))
    matched, total = 0, 0
    mismatches, notices = [], []
    for domain in domains:
        label = read_text(domain / 'name') or domain.name
        for item in constraints_for(domain):
            if item['maximum'] <= 0 or item['minimum'] > item['maximum']:
                continue
            desired = item['maximum'] if state == 'AC' else max(item['minimum'], min(target_uw, item['maximum']))
            if state == 'BATTERY' and target_uw < item['minimum']:
                notices.append(f'{label} / {item["name"]} has a driver minimum of {item["minimum"] / 1e6:.2f} W')
            total += 1
            try:
                raw = read_text(item['file'])
                actual = int(raw)
            except (OSError, TypeError, ValueError) as exc:
                mismatches.append({'label': label, 'name': item['name'], 'expected': desired,
                                   'actual': None, 'error': str(exc)})
                continue
            if actual == desired:
                matched += 1
            else:
                mismatches.append({'label': label, 'name': item['name'], 'expected': desired,
                                   'actual': actual, 'error': ''})
    if total == 0:
        return {'ok': False, 'state': state, 'matched': 0, 'total': 0,
                'detail': 'No supported constraints with a positive maximum.', 'mismatches': [], 'notices': []}
    detail = f'{matched}/{total} constraints match policy'
    if mismatches:
        first = mismatches[0]
        if first['actual'] is None:
            detail += f'; {first["label"]} / {first["name"]} unreadable'
        else:
            detail += (f'; {first["label"]} / {first["name"]}: expected '
                       f'{first["expected"] / 1e6:.2f} W, read {first["actual"] / 1e6:.2f} W')
    elif notices:
        detail += f'; {len(notices)} limit(s) constrained by driver minimum'
    return {'ok': matched == total, 'state': state, 'matched': matched, 'total': total,
            'detail': detail, 'mismatches': mismatches, 'notices': notices}


def watcher_status():
    result = run_capture(['systemctl', 'is-active', 'rapl-watch.service'], timeout=1.0)
    if result is None:
        return 'UNKNOWN'
    return 'ACTIVE' if result.returncode == 0 and (result.stdout or '').strip() == 'active' else 'INACTIVE'


def tui(stdscr):
    curses.curs_set(0); stdscr.keypad(True); stdscr.timeout(2000)
    message = 'Ready.'; message_error = False
    colors = False
    try:
        if curses.has_colors():
            curses.start_color(); curses.use_default_colors()
            curses.init_pair(1, curses.COLOR_CYAN, -1); curses.init_pair(2, curses.COLOR_GREEN, -1)
            curses.init_pair(3, curses.COLOR_YELLOW, -1); curses.init_pair(4, curses.COLOR_RED, -1); colors = True
    except curses.error: pass

    def attr(pair): return curses.color_pair(pair) if colors else 0
    def put(y, x, text, style=0, limit=None):
        h, w = stdscr.getmaxyx()
        if not (0 <= y < h) or x >= w - 1: return
        amount = w - x - 1
        if limit is not None: amount = min(amount, limit)
        if amount <= 0: return
        try: stdscr.addnstr(y, x, str(text).replace('\n', ' ').replace('\r', ' '), amount, style)
        except curses.error: pass
    def rule(y):
        h, w = stdscr.getmaxyx()
        if 0 <= y < h:
            try: stdscr.addnstr(y, 0, '─' * max(1, w - 1), w - 1, attr(1))
            except curses.error:
                try: stdscr.addnstr(y, 0, '-' * max(1, w - 1), w - 1)
                except curses.error: pass
    def input_line(prompt, maxlen=32):
        h, w = stdscr.getmaxyx(); y = h - 1; prompt = prompt[:max(0, w - 2)]
        stdscr.move(y, 0); stdscr.clrtoeol(); put(y, 0, prompt, curses.A_BOLD); stdscr.refresh()
        # TUI refreshes time out after two seconds, but input prompts must wait
        # until the user finishes typing rather than silently returning blank.
        stdscr.timeout(-1)
        try:
            curses.echo(); curses.curs_set(1)
            return stdscr.getstr(y, min(len(prompt), max(0, w - 2)), min(maxlen, max(1, w - len(prompt) - 1))).decode('utf-8', 'replace').strip()
        except curses.error: return ''
        finally:
            curses.noecho(); stdscr.timeout(2000)
            try: curses.curs_set(0)
            except curses.error: pass
    def show_results(title, lines):
        offset = 0
        while True:
            stdscr.erase(); h, w = stdscr.getmaxyx(); wrapped = []
            for item in lines: wrapped.extend(textwrap.wrap(str(item), max(20, w - 4), subsequent_indent='  ') or [''])
            put(0, 0, title, curses.A_BOLD | attr(1)); rule(1); view = max(1, h - 5)
            for i, text in enumerate(wrapped[offset:offset + view]): put(2 + i, 1, text)
            rule(h - 2)
            put(h - 1, 0, f'Up/Down scroll, q close  |  {offset + 1}-{min(offset + view, len(wrapped))} of {len(wrapped)}')
            stdscr.refresh(); key = stdscr.getch()
            if key in (ord('q'), 10, 13, 27): return
            if key in (curses.KEY_DOWN, ord('j')): offset = min(max(0, len(wrapped) - view), offset + 1)
            elif key in (curses.KEY_UP, ord('k')): offset = max(0, offset - 1)
            elif key == curses.KEY_NPAGE: offset = min(max(0, len(wrapped) - view), offset + view)
            elif key == curses.KEY_PPAGE: offset = max(0, offset - view)

    while True:
        stdscr.erase(); h, w = stdscr.getmaxyx()
        if h < 22 or w < 76:
            put(0, 0, 'RAPL + iGPU CLOCK CONTROL', curses.A_BOLD | attr(1))
            put(2, 0, 'Terminal too small. Resize to at least 76 columns by 22 rows.')
            put(4, 0, 'Press q to quit.')
            stdscr.refresh()
            if stdscr.getch() in (ord('q'), ord('Q')): return
            continue
        verify = rapl_verification(); state = verify['state']; target = battery_watts(); interval = reapply_interval_seconds(); auto_state = watcher_status()
        put(0, 0, 'RAPL + iGPU CLOCK CONTROL', curses.A_BOLD | attr(1)); put(0, w - 13, 'q  Quit', attr(1))
        put(1, 0, 'CPU package power and Intel iGPU frequency cap | Status refreshes every 2 seconds'); rule(2)
        put(3, 0, 'POWER', curses.A_BOLD); put(4, 2, f'Source: {state.upper() if state else "UNKNOWN"}', curses.A_BOLD | (attr(2) if state == 'AC' else attr(3) if state == 'BATTERY' else attr(4)))
        put(4, 32, f'Battery limit: {target:g} W'); put(4, 55, f'Reapply: {interval}s', curses.A_BOLD)
        verify_label = (f'LIMITED {verify["matched"]}/{verify["total"]}' if verify['ok'] is True and verify.get('notices') else f'VERIFIED {verify["matched"]}/{verify["total"]}' if verify['ok'] is True else f'MISMATCH {verify["matched"]}/{verify["total"]}' if verify['ok'] is False else 'UNKNOWN')
        verify_attr = attr(2) if verify['ok'] is True and not verify.get('notices') else attr(3) if verify['ok'] is True else attr(4) if verify['ok'] is False else attr(3)
        put(5, 2, f'RAPL: {verify_label}', curses.A_BOLD | verify_attr)
        put(5, 27, f'AUTO-SWITCH: {auto_state}', curses.A_BOLD | (attr(2) if auto_state == 'ACTIVE' else attr(4)))
        if verify['ok'] is False:
            mismatches = verify.get('mismatches', [])
            if mismatches:
                first = mismatches[0]
                if first['actual'] is None:
                    summary = f'{first["label"]} / {first["name"]}: unreadable'
                else:
                    summary = (f'{first["label"]} / {first["name"]}: expected '
                               f'{first["expected"] / 1e6:.2f} W, got {first["actual"] / 1e6:.2f} W')
                if len(mismatches) > 1:
                    summary += f' (+{len(mismatches) - 1} more)'
            else:
                summary = verify['detail']
            put(6, 0, 'ISSUE: ' + summary, attr(4))
        elif verify.get('notices'):
            put(6, 0, 'LIMITED: ' + verify['notices'][0], attr(3))
        else:
            rule(6)
        put(7, 0, 'RAPL LIMITS', curses.A_BOLD)
        igpu_info = igpu_clock_status()
        if igpu_info.get('ok'):
            igpu = igpu_info['gpu']
            cap_text = 'OFF' if igpu_info['target_mhz'] == 0 else f"{igpu_info['target_mhz']} MHz"
            igpu_summary = (f"DRM card{igpu['card_number']}/{igpu['driver']} max={igpu_info['current_max']} MHz; "
                            f"range={igpu_info['minimum_mhz']:.0f}-{igpu_info['maximum_mhz']:.0f}; cap={cap_text}")
        else:
            igpu_summary = 'iGPU clock cap unavailable: ' + igpu_info['detail']
        put(7, 13, igpu_summary, attr(1 if igpu_info.get('ok') else 3), max(1, w - 14))
        max_col = w - 15; current_col = max(35, max_col - 19); label_width = current_col - 2
        put(8, 1, 'DOMAIN / CONSTRAINT', curses.A_BOLD | attr(1), label_width); put(8, current_col, 'CURRENT', curses.A_BOLD | attr(1), 15); put(8, max_col, 'DRIVER MAX', curses.A_BOLD | attr(1), 15); rule(9)
        rows = []
        for domain in package_domains():
            label = read_text(domain / 'name') or domain.name
            for item in constraints_for(domain):
                if item['maximum'] > 0 and item['minimum'] <= item['maximum']:
                    rows.append((f'{label} / {item["name"].replace("_", " ")}', item['current'], item['maximum']))
        list_top = 10; footer_top = h - 10; avail = max(0, footer_top - list_top - 1)
        if not rows: put(list_top, 2, 'No active RAPL constraints with a valid positive maximum.', attr(3))
        for i, (label, current, maximum) in enumerate(rows[:avail]):
            put(list_top + i, 1, label, 0, label_width); put(list_top + i, current_col, f'{current/1e6:.2f} W', 0, 15); put(list_top + i, max_col, f'{maximum/1e6:.2f} W', 0, 15)
        if len(rows) > avail: put(footer_top - 1, 1, f'{len(rows)-avail} constraints hidden; enlarge terminal.', attr(3))
        rule(footer_top)
        put(footer_top + 1, 0, 'iGPU clock cap is separate from the CPU package power limit.', attr(3))
        put(footer_top + 2, 0, 'Actual iGPU frequency still varies with load, temperature, and power limits.', attr(3))
        put(h - 6, 0, message, attr(4) if message_error else attr(2)); rule(h - 5)
        put(h - 4, 0, '[1] Battery watts  [2] Apply RAPL  [3] Uninstall  [5] Reapply interval', curses.A_BOLD)
        put(h - 3, 0, '[4] iGPU max MHz (0 restores)', curses.A_BOLD)
        put(h - 2, 0, 'Set 0 MHz to restore the saved iGPU maximum; cap is disabled by default.')
        put(h - 1, 0, 'Select: ', curses.A_BOLD); stdscr.refresh(); key = stdscr.getch()
        if key in (ord('q'), ord('Q')): return
        if key == -1: continue  # timed refresh; keep the last action message visible
        if key == curses.KEY_RESIZE: continue
        message = ''; message_error = False
        if key == ord('1'):
            raw = input_line('New battery limit in watts (0.5-1000): ')
            try:
                value = float(raw); save_battery_watts(value); result = apply_policy(quiet=True)
                if result['warnings']:
                    message = f'Saved {value:g} W, but {len(result["warnings"])} limit(s) failed readback; see RAPL status.'; message_error = True
                elif result['notices']:
                    message = f'Saved {value:g} W; hardware minimum constrains {len(result["notices"])} limit(s).'; message_error = True
                else:
                    message = f'Saved {value:g} W and applied current policy.'
            except (ValueError, OSError, RuntimeError) as exc: message = f'Could not apply setting: {exc}'; message_error = True
        elif key == ord('2'):
            try:
                result = apply_policy(quiet=True)
                if result['warnings']:
                    message = f'Policy partly applied: {len(result["warnings"])} write/readback issue(s).'; message_error = True
                elif result['notices']:
                    message = f'Policy applied; hardware minimum constrains {len(result["notices"])} limit(s).'; message_error = True
                else:
                    message = f'Applied {result["state"]} power policy; all writes read back correctly.'
            except (OSError, RuntimeError) as exc:
                message = f'Could not apply policy: {exc}'; message_error = True
        elif key == ord('5'):
            raw = input_line('Reapply interval in whole seconds (1-3600; default 7): ', 8)
            try:
                seconds = int(raw)
                save_reapply_interval(seconds)
                message = f'Saved {seconds}-second interval. The watcher will use it on its next timer cycle.'
                message_error = False
            except (ValueError, OSError) as exc:
                message = f'Could not save interval: {exc}'
                message_error = True
        elif key == ord('4'):
            info = igpu_clock_status()
            if not info.get('ok'):
                message = f"Cannot set iGPU cap: {info.get('detail', 'iGPU clock controls unavailable')}"
                message_error = True
            else:
                raw = input_line(
                    f"DRM card{info['gpu']['card_number']} cap MHz ({info['minimum_mhz']:.0f}-{info['maximum_mhz']:.0f}; 0=restore): ",
                    8,
                )
                try:
                    value = int(raw)
                    if value == 0:
                        message = disable_igpu_cap()
                    else:
                        result = set_igpu_cap(value)
                        readbacks = ', '.join(f"{c['id']}={c['current_max_mhz']:.0f} MHz" for c in result['controls'])
                        message = f"Saved iGPU cap {value} MHz on DRM card{result['gpu_number']} ({readbacks})."
                    message_error = False
                except (ValueError, OSError, RuntimeError) as exc:
                    message = f'Could not set iGPU cap: {exc}'
                    message_error = True
        elif key == ord('3'):
            stdscr.erase(); put(0, 0, 'UNINSTALL RAPL + iGPU CLOCK CAP', curses.A_BOLD | attr(1)); rule(1)
            put(3, 0, 'Stops the RAPL services and restores saved CPU power and iGPU clock limits.')
            put(4, 0, 'Restores pre-existing managed files and configuration.')
            put(5, 0, 'Legacy installs may not have true pre-install backups.')
            put(7, 0, 'Type YES to confirm. Anything else cancels:', curses.A_BOLD); stdscr.refresh()
            if input_line('Confirmation (YES): ', 16) == 'YES': show_results('UNINSTALL RESULT', uninstall_installation()); return
            message = 'Uninstall cancelled.'


def watch():
    """Reapply policy at the configured interval and immediately on supply events."""
    last_state = None

    def sync_state(force=False):
        nonlocal last_state
        # The iGPU clock cap is independent of AC/battery state. Reapply it
        # even if power-source detection temporarily fails.
        gpu_target = igpu_cap_mhz()
        if gpu_target > 0:
            try:
                gpu_result = apply_igpu_cap(gpu_target, force=False)
                if gpu_result['changed']:
                    print(
                        f"raplctl: iGPU cap re-applied: DRM card{gpu_result['gpu_number']} {gpu_target} MHz; driver={gpu_result['driver']}",
                        flush=True,
                    )
            except (OSError, RuntimeError, ValueError) as exc:
                print(f'raplctl: iGPU cap warning: {exc}', file=sys.stderr, flush=True)
        state = power_state()
        if state not in ('AC', 'BATTERY'):
            print('raplctl: power source unknown; will retry at the configured interval', file=sys.stderr, flush=True)
            return
        verification = rapl_verification()
        if not force and state == last_state and verification.get('ok') is True:
            return
        try:
            result = apply_policy(state, quiet=True)
            failures = len(result['warnings'])
            print(
                f'raplctl: source={state}; verified={result["verified"]}/{result["attempted"]}; '
                f'issues={failures}; reapply_interval={reapply_interval_seconds()}s; target=' +
                (f'{battery_watts():g} W battery' if state == 'BATTERY' else 'driver-reported maximum'),
                flush=True,
            )
            for label, name, desired, actual, maximum in result['changes']:
                status = 'OK' if actual == desired else 'MISMATCH'
                print(
                    f'raplctl: {status}: {label} / {name}: target={desired / 1e6:.2f} W, '
                    f'readback={actual / 1e6:.2f} W, driver_max={maximum / 1e6:.2f} W',
                    flush=True,
                )
            for warning in result['warnings']:
                print(f'raplctl: WARNING: {warning}', file=sys.stderr, flush=True)
            for notice in result['notices']:
                print(f'raplctl: NOTICE: {notice}', file=sys.stderr, flush=True)
            last_state = state if not result['warnings'] else None
        except (OSError, RuntimeError, ValueError) as exc:
            last_state = None
            print(f'raplctl: {exc}', file=sys.stderr, flush=True)

    sync_state(force=True)
    udevadm = shutil.which('udevadm')
    if not udevadm:
        while True:
            time.sleep(reapply_interval_seconds())
            sync_state(force=True)

    while True:
        proc = None
        try:
            proc = subprocess.Popen(
                [udevadm, 'monitor', '--kernel', '--subsystem-match=power_supply'],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
            )
            if proc.stdout is None:
                raise RuntimeError('udevadm monitor has no readable output stream')
            while proc.poll() is None:
                timeout = reapply_interval_seconds()
                ready, _, _ = select.select([proc.stdout], [], [], timeout)
                if not ready:
                    # Re-write limits on every interval even if they already match.
                    sync_state(force=True)
                    continue
                chunk = os.read(proc.stdout.fileno(), 4096).decode('utf-8', 'replace')
                if not chunk:
                    break
                if any(line.startswith('KERNEL[') for line in chunk.splitlines()):
                    time.sleep(0.35)  # let sysfs attributes settle after the event
                    sync_state(force=True)
        except (OSError, ValueError, RuntimeError) as exc:
            print(f'raplctl: udev monitor failed: {exc}; retrying', file=sys.stderr, flush=True)
        finally:
            if proc is not None:
                try:
                    if proc.poll() is None: proc.terminate()
                    proc.wait(timeout=2)
                except (OSError, subprocess.TimeoutExpired):
                    try: proc.kill()
                    except OSError: pass
        time.sleep(min(5, reapply_interval_seconds()))


def main():
    if os.geteuid() != 0: print('Run the TUI with the rapl command.', file=sys.stderr); return 1
    command = sys.argv[1] if len(sys.argv) > 1 else 'tui'
    if command == 'apply': apply_policy()
    elif command == 'snapshot':
        snap = capture_original_limits(); print(f'Saved {len(snap.get("limits", {}))} RAPL constraint value(s).')
    elif command == 'watch': watch()
    elif command == 'tui': curses.wrapper(tui)
    else: print('Usage: raplctl {tui|apply|watch|snapshot}', file=sys.stderr); return 2
    return 0

if __name__ == '__main__':
    try: raise SystemExit(main())
    except (OSError, RuntimeError, ValueError) as exc: print(f'raplctl: {exc}', file=sys.stderr); raise SystemExit(1)
PYTHON
chmod 0755 /usr/local/sbin/raplctl

if [[ ! -e /etc/rapl-battery-watts ]]; then printf '7.0\n' > /etc/rapl-battery-watts; fi
chmod 0644 /etc/rapl-battery-watts
if [[ ! -e /etc/rapl-reapply-seconds ]]; then printf '7\n' > /etc/rapl-reapply-seconds; fi
chmod 0644 /etc/rapl-reapply-seconds
if [[ ! -e /etc/rapl-igpu-max-mhz ]]; then printf '0\n' > /etc/rapl-igpu-max-mhz; fi
chmod 0644 /etc/rapl-igpu-max-mhz
cat > /usr/local/bin/rapl <<'WRAPPER'
#!/usr/bin/env bash
exec sudo /usr/local/sbin/raplctl tui
WRAPPER
chmod 0755 /usr/local/bin/rapl

cat > /etc/systemd/system/rapl-apply.service <<'UNIT'
[Unit]
Description=Apply RAPL limits for current power source
After=local-fs.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/raplctl apply
UNIT
cat > /etc/systemd/system/rapl-watch.service <<'UNIT'
[Unit]
Description=Watch power-supply events and apply RAPL limits
After=local-fs.target
[Service]
Type=simple
ExecStart=/usr/local/sbin/raplctl watch
Restart=on-failure
RestartSec=2
[Install]
WantedBy=multi-user.target
UNIT
cat > /etc/acpi/events/rapl-ac-adapter <<'ACPI'
event=ac_adapter.*
action=/usr/bin/systemctl start --no-block rapl-apply.service
ACPI

systemctl daemon-reload
/usr/local/sbin/raplctl snapshot
systemctl enable --now rapl-watch.service
if systemctl list-unit-files acpid.service --no-legend 2>/dev/null | grep -q '^acpid\.service'; then systemctl enable --now acpid.service; systemctl restart acpid.service; fi
systemctl start rapl-apply.service || true

echo
echo 'Installed. Run: rapl'
echo 'Battery limit default: 7 W. AC uses the maximum reported by RAPL.'
echo 'RAPL limits are reapplied every 7 seconds by default; change this with TUI option 5.'
echo 'iGPU clock cap: disabled by default; use rapl option 4 to set a detected MHz limit.'
echo 'Uninstall from the TUI attempts to restore saved RAPL/iGPU clock state and prior files.'
