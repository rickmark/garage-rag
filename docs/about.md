---
layout: default
title: About the creator
description: Rick Mark-Penwell, the creator of Garage, is a security engineer and Apple platform reverse engineer known for his research into Apple's T2 chip.
---

# About the creator

Garage is written and maintained by **Rick Mark-Penwell**.

Rick is a security engineer and reverse engineer who has worked on Apple platforms since 2007. His Apple developer account dates from then and still carries his prior name, Richard Penwell, so that's the name on Garage's Developer ID signature. Rick Mark and Richard Penwell are the same person, and Garage's copyright uses the hyphenated name to make that clear.

## Background

Rick has worked as an internal security engineer at tech companies, assessing workstations, phones and other systems, with a focus on macOS integrity, EFI and device restore.

He is best known for his research into Apple's **T2 security chip** as part of Team t8012:
- He built an early T2 integrity verification tool in 2017.
- In October 2019 he proposed that the checkm8 bootrom exploit reached the T2, and extended ipwndfu for it.
- In 2020 he performed the team's first successful SecureROM dump.
- He helped bring the exploit into the checkra1n jailbreak.
- He adapted libimobiledevice to talk to the T2, and reverse engineered the USB Target Disk Mode protocol.

When the research went public in October 2020, Rick explained to the press why the flaw can't be patched in shipping Macs. He also corrected how the work had been credited. The team's own account is [On bridgeOS / T2 Research](https://blog.t8012.dev/on-bridgeos-t2-research/).

Rick is part of [Hack Different](https://github.com/hack-different), an open-source community around Apple platforms. There he maintains [apple-knowledge](https://github.com/hack-different/apple-knowledge), a machine-readable collection of reverse-engineered Apple hardware and software facts. He also contributes to The Apple Wiki.

## Research and open source

Rick publishes most of his work on [GitHub](https://github.com/rickmark). Beyond the T2 work, it includes:

**Firmware and devices.**
- [peiutil](https://github.com/rickmark/peiutil) (2017) converts UEFI PEI images (TE and VZ files) to PE, so they can be disassembled.
- [apple_ssv](https://github.com/rickmark/apple_ssv) (2020) explores macOS Signed System Volumes.
- [apple_utdm](https://github.com/rickmark/apple_utdm) (2020) is a Linux kernel driver for Apple's USB Target Disk Mode.

**Libraries for Apple formats and services.** [libapfs](https://github.com/rickmark/libapfs) for the Apple File System, [pyxar](https://github.com/rickmark/pyxar) for XAR archives, [libiupdate](https://github.com/rickmark/libiupdate) for Apple software updates, [libicloud](https://github.com/rickmark/libicloud) for iCloud, [apple_net_recovery](https://github.com/rickmark/apple_net_recovery) for Internet Recovery, and Rust reimaginings of libimobiledevice ([libidevice](https://github.com/rickmark/libidevice)) and XPC ([libxpc](https://github.com/rickmark/libxpc)).

**Tools that protect people.**
- [isafety](https://github.com/rickmark/isafety) (2020) examines iPhones and iPads for security and safety threats.
- [chainfix](https://github.com/rickmark/chainfix) (2024) checks and repairs Keychain and iCloud Keychain.

His most widely used project is [apple-knowledge](https://github.com/hack-different/apple-knowledge), mentioned above, with over 1,400 stars on GitHub.

## Outside of work

Away from the keyboard, Rick makes documentary film and photography centered on the LGBT community.

## Why Garage

Garage brings that security background to AI. It makes your own documents, code and messages searchable by your AI assistant without them leaving your Mac. The database, the models and the index all run on your machine, and communications never leave it. Garage is open source, so you can check that for yourself.

## Work with Rick

Rick is available for hire. If you or your team could use help with software like this, get in touch on [LinkedIn](https://linkedin.com/in/penwellr).

## Support the project

Garage is free. If it's useful to you, you can support Rick's work on [Patreon](https://www.patreon.com/rickmark), and you can report bugs, suggest features or send pull requests on [GitHub](https://github.com/rickmark/garage-rag).

## Elsewhere

[GitHub](https://github.com/rickmark) · [LinkedIn](https://linkedin.com/in/penwellr)
