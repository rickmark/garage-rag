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

Rick publishes most of his work on [GitHub](https://github.com/rickmark). Beyond the T2 work, it falls into a few areas.

**Firmware and boot security.**
- [mojo_thor](https://github.com/rickmark/mojo_thor) (2017) is research into malware that infects the EFI and SMC firmware of MacBooks.
- [peiutil](https://github.com/rickmark/peiutil) (2017) converts UEFI PEI images (TE and VZ files) to PE, so they can be disassembled.
- [apple_ssv](https://github.com/rickmark/apple_ssv) (2020) explores macOS Signed System Volumes.
- [windows-bluepill](https://github.com/rickmark/windows-bluepill) (2022) looks at breaking a system's security without breaking Secure Boot.

**Ports, cables and radios.**
- [badusb](https://github.com/rickmark/badusb) (2019) detects and exploits time-of-check/time-of-use gaps in USB mass storage.
- [lightning_strike](https://github.com/rickmark/lightning_strike) (2019) and [lightning_dfu](https://github.com/rickmark/lightning_dfu) (2021) study the security of the Lightning connector.
- [apple_utdm](https://github.com/rickmark/apple_utdm) (2020) is a Linux kernel driver for Apple's USB Target Disk Mode.
- [apple-malicious-baseband](https://github.com/rickmark/apple-malicious-baseband) (2022) documents a malicious cellular baseband image that carried Apple's signature.

**Libraries for Apple formats and services.** [libapfs](https://github.com/rickmark/libapfs) for the Apple File System, [pyxar](https://github.com/rickmark/pyxar) for XAR archives, [libiupdate](https://github.com/rickmark/libiupdate) for Apple software updates, [libicloud](https://github.com/rickmark/libicloud) for iCloud, [apple_net_recovery](https://github.com/rickmark/apple_net_recovery) for Internet Recovery, and Rust reimaginings of libimobiledevice ([libidevice](https://github.com/rickmark/libidevice)) and XPC ([libxpc](https://github.com/rickmark/libxpc)).

**Tools that protect people.**
- [isafety](https://github.com/rickmark/isafety) (2020) examines iPhones and iPads for security and safety threats.
- [chainfix](https://github.com/rickmark/chainfix) (2024) checks and repairs Keychain and iCloud Keychain.

**In the organizations he runs.** Rick also owns the [Hack Different](https://github.com/hack-different) and [Team t8012](https://github.com/t8012) organizations on GitHub. Besides apple-knowledge, their projects include:
- [webmuxd](https://github.com/hack-different/webmuxd) and [go-webmuxd](https://github.com/hack-different/go-webmuxd), which talk to iPhones and iPads from a web browser over WebUSB, and [demuxusb](https://github.com/hack-different/demuxusb), which analyzes their USB sessions;
- [smcutil](https://github.com/hack-different/smcutil) for Apple's SMC payloads, [efivalidate](https://github.com/hack-different/efivalidate) for validating the firmware of Macs up to the T1, and [libapplefw](https://github.com/hack-different/libapplefw) for Apple firmware images;
- [go-aapl-integrity](https://github.com/hack-different/go-aapl-integrity) and [cnklverify](https://github.com/t8012/cnklverify) for Apple's integrity formats (img4, chunklists, trust caches), and [secure_emu](https://github.com/hack-different/secure_emu), which runs SecureROM under the Unicorn emulator;
- [mootool](https://github.com/hack-different/mootool) for Mach-O files, [yolo_dsc](https://github.com/hack-different/yolo_dsc) for extracting the dyld shared cache, [symbol-server](https://github.com/hack-different/symbol-server) for Apple symbols, [xnudex](https://github.com/hack-different/xnudex) for indexing XNU OS images, and [kext-kmem](https://github.com/hack-different/kext-kmem), a kernel extension for reading and writing kernel memory;
- [homebrew-jailbreak](https://github.com/hack-different/homebrew-jailbreak), a Homebrew tap of research tools;
- [libibackup](https://github.com/hack-different/libibackup) for iOS backups, [apple-diagnostics-format](https://github.com/hack-different/apple-diagnostics-format) for Apple's wireless diagnostics files, [apple-baseband](https://github.com/hack-different/apple-baseband) for the modem baseband, and [uarp](https://github.com/hack-different/uarp) for Apple's accessory firmware update protocol;
- from the T2 work, [pongo-flash](https://github.com/t8012/pongo-flash), a flash storage driver for checkra1n's pongoOS, and [RemoteServiceDiscovery](https://github.com/t8012/RemoteServiceDiscovery), a reverse-engineered rewrite of Apple's framework of that name.

He also runs [AudienceKit](https://github.com/audience-kit), a platform with its own API, admin interface, and Swift and Ruby SDKs. He also built [hedonism_bot](https://github.com/lwm-luminx/hedonism_bot), where photographers upload event photos. It uses the same Postgres, pgvector and embedding approach as Garage to find and group faces without naming anyone, so people can find and download the photos they appear in.

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
