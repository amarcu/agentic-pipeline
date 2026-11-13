# One-time setup

Each item is done once, by the human, at the machine. Until it is done, `bin/machine` refuses the
step that needs it and says which. Nothing here is automated: every item changes a machine's
security boundary.

## Desktop — Ubuntu side (`desktop-ubuntu`)

1. **SSH from M2.** Add M2's public key to `~/.ssh/authorized_keys` for the user in
   `machines.conf` (`get_machine_user`). Then, once, from M2 in an interactive shell, accept the
   desktop's host key: `ssh dev@gpu-box true`. Without that, every batch SSH fails with
   "Host key verification failed". Check: `ssh -o BatchMode=yes dev@gpu-box true`.
2. **A narrow sudoers rule** — `sudo visudo -f /etc/sudoers.d/pipeline-machine`:

   ```
   dev ALL=(root) NOPASSWD: /usr/bin/efibootmgr --bootnext *, /usr/bin/systemctl reboot, /usr/bin/systemctl poweroff
   ```

   Nothing broader. `bin/machine` calls exactly these with `sudo -n`, so a missing rule fails
   rather than prompting.
3. **Record the Windows boot entry.** Run `sudo efibootmgr` and find `Windows Boot Manager`. Put
   its number (for example `0003`) in `machines.conf` as `DESKTOP_WINDOWS_BOOT_ENTRY`. Leave
   `BootOrder` alone: Ubuntu stays the default.

## Desktop — Windows side (`desktop-windows`)

4. **Tailscale.** Install it and sign in, then put its MagicDNS name in `get_machine_host`.
5. **OpenSSH Server.** Settings → Optional features → OpenSSH Server; start the `sshd` service and
   set it to Automatic. Add M2's key to `C:\ProgramData\ssh\administrators_authorized_keys` (for an
   admin account) and set the user in `get_machine_user`.
6. **Fast Startup off.** Control Panel → Power Options → "Choose what the power buttons do" →
   untick "Turn on fast startup". With it on, "shut down" is a hibernate, the NIC often ignores the
   wake packet, and the firmware's BootNext can be skipped.
7. **BitLocker.** If the Windows drive is encrypted, confirm one BootNext boot reaches the desktop
   without asking for the recovery key before relying on it unattended.

## Wake-on-LAN (both sides)

8. **Firmware:** enable "Wake on LAN" / "Power on by PCI-E" in the BIOS.
9. **Windows:** Device Manager → the network adapter → Power Management → allow it to wake the
   computer; Advanced → "Wake on Magic Packet" enabled.
10. **Ubuntu:** `sudo ethtool <iface>` shows `Wake-on: g`; if not, persist it with a NetworkManager
    setting: `nmcli connection modify <conn> 802-3-ethernet.wake-on-lan magic`.

## The Pi

If the Pi's SSH uses Tailscale SSH in `check` mode, it asks for a browser sign-in periodically, so
no unattended job can use it. The pipeline host sends the wake packet itself instead.
