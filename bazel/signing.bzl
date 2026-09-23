"""The code-signing identities this repository knows about.

One place to name them, because each one is referenced three times over: by the
platform that selects it, by the config_setting that detects it, and by the
codesign rule that decides what options make sense for it.
"""

# Self-signed, generated per developer by //tools/signing:local_identity. It
# exists so that local builds have a code identity that survives a rebuild:
# an ad-hoc signature's designated requirement pins the cdhash, so every build
# is a different app as far as Keychain ACLs are concerned, while a certificate
# pins the certificate's own hash instead. See that script's header.
LOCAL_SIGNING_IDENTITY = "Garage Local Signing"

DEVELOPER_ID_IDENTITY = "Developer ID Application: Richard Penwell (DWVXMLB45Y)"

# The App Store configuration signs with Apple Development and the development profile
# (macapp/GarageRAGDevelopmentApp.provisionprofile), so a store build runs on registered Macs.
# Uploading re-signs the archive with Apple Distribution and GarageMacAppConnect in Xcode.
STORE_IDENTITY = "Apple Development: Rick Penwell (23E5F7Z5L7)"

# Identities with no Apple-issued chain: usable to establish a stable identity,
# but not to notarize, and — because hardened runtime turns on library
# validation, which these cannot satisfy — not to run with hardened runtime.
UNCHAINED_IDENTITIES = ["-", LOCAL_SIGNING_IDENTITY]
