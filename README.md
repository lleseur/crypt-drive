# Crypt-Drive

## Introduction

This script unlock and mount multiple LUKS encrypted drives to a specific directory.

To encrypt a RAID there is several solutions: LUKS on RAID or RAID on LUKS. The second solution requires to unlock all drives before accessing the RAID. This script wants to automate this process.

Use case example: You want to use LUKS and BTRFS, you have 2 solutions:
- MDADM + LUKS + BTRFS: You don't use BTRFS native RAID support so you won't benefit from BTRFS bit corruption protection
- LUKS + BTRFS RAID: You need to encrypt each drives separately

In this example, this script would allow you to mount all drives at once.
You would have one file or USB key encrypted with a password, it would contain all the keys to unlock the drives.
This script will unlock the file/USB key by asking you the password, it would then unlock all the drives with the keyfiles.

## Usage
To unlock and mount the drives: `crypt-drive.sh --config=./crypt-drive.config unlock`

To dismount and lock the drives: `crypt-drive.sh --config=./crypt-drive.config lock`

## Todo

- [x] Unlock with keyfiles encrypted and stored in a separate filesystem (USB device or regular file)
- [x] Unlock when the header is stored in a separate file (with cryptsetup --header)
- [ ] Allow to unlock all drives with password
- [ ] Unlock hidden volumes (with cryptsetup --align-payload)
