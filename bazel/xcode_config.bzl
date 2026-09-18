"""Custom Xcode configuration for Garage project."""

load("@rules_xcodeproj//xcode/private:xcode_config.bzl", "get_default_xcode_path")

def _xcode_config_impl(ctx):
    """Xcode config that uses the default Xcode installation."""
    xcode_path = get_default_xcode_path(ctx)
    
    return [
        platform_common.XcodeConfiguration(
            xcode_version = "27.0",
            developer_dir = xcode_path,
            sdk_versions = {
                "iphoneos": "15.0",
                "iphonesimulator": "15.0",
                "macos": "12.0",
                "tvos": "15.0",
                "tvossimulator": "15.0",
                "watchos": "8.0",
                "watchsimulator": "8.0",
            },
        ),
    ]

xcode_config = rule(
    implementation = _xcode_config_impl,
    local = True,
)
