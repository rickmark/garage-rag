import argparse
import os
import shutil
import subprocess
import sys

from pex.common import safe_mkdtemp, safe_rmtree
from pex.scie.science import ensure_science


def parse_args():
    parser = argparse.ArgumentParser(fromfile_prefix_chars="@")
    parser.add_argument("-o", "--output", dest="output", required=True, help="Output file path")
    parser.add_argument("--pex-file", dest="pex_file", required=True, help="Input PEX file")
    
    # Scie options
    parser.add_argument("--scie", dest="scie", default="none", choices=["none", "eager", "lazy"])
    parser.add_argument("--scie-python-version", dest="scie_python_version", default="3.13")
    parser.add_argument("--scie-pbs-release", dest="scie_pbs_release", default="")
    parser.add_argument("--scie-platform", dest="scie_platforms", action="append", default=[])
    parser.add_argument("--scie-env", dest="scie_env", action="append", default=[])
    parser.add_argument("--inject-env", dest="inject_env", action="append", default=[])
    parser.add_argument("--scie-science-binary", dest="scie_science_binary", default="")

    return parser.parse_args(args=sys.argv[1:])


UNIVERSAL_LAUNCHER_C = r"""#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <limits.h>
#include <errno.h>

#if defined(__arm64__) || defined(__aarch64__)
__asm__(
    ".section __DATA,__payload\n"
    ".globl _payload_start\n"
    "_payload_start:\n"
    ".incbin \"" ARM64_SCIE_PATH "\"\n"
    ".globl _payload_end\n"
    "_payload_end:\n"
);
#elif defined(__x86_64__)
__asm__(
    ".section __DATA,__payload\n"
    ".globl _payload_start\n"
    "_payload_start:\n"
    ".incbin \"" X86_64_SCIE_PATH "\"\n"
    ".globl _payload_end\n"
    "_payload_end:\n"
);
#else
#error "Unsupported architecture"
#endif

extern char payload_start[];
extern char payload_end[];

static void ensure_dir(const char *dir) {
    char tmp[PATH_MAX];
    char *p = NULL;
    size_t len;

    snprintf(tmp, sizeof(tmp), "%s", dir);
    len = strlen(tmp);
    if (tmp[len - 1] == '/')
        tmp[len - 1] = 0;
    for (p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    mkdir(tmp, 0755);
}

int main(int argc, char *argv[]) {
    size_t payload_size = (size_t)(payload_end - payload_start);
    const char *home = getenv("HOME");
    char cache_dir[PATH_MAX];
    if (home) {
        snprintf(cache_dir, sizeof(cache_dir), "%s/Library/Caches/garage/bin", home);
    } else {
        snprintf(cache_dir, sizeof(cache_dir), "/tmp/garage/bin");
    }
    ensure_dir(cache_dir);

    char target_path[PATH_MAX];
#if defined(__arm64__) || defined(__aarch64__)
    snprintf(target_path, sizeof(target_path), "%s/%s.arm64", cache_dir, APP_NAME);
#elif defined(__x86_64__)
    snprintf(target_path, sizeof(target_path), "%s/%s.x86_64", cache_dir, APP_NAME);
#endif

    struct stat st;
    int needs_extract = 1;
    if (stat(target_path, &st) == 0) {
        if ((size_t)st.st_size == payload_size) {
            needs_extract = 0;
        }
    }

    if (needs_extract) {
        char tmp_path[PATH_MAX];
        snprintf(tmp_path, sizeof(tmp_path), "%s.tmp.%d", target_path, getpid());
        FILE *fp = fopen(tmp_path, "wb");
        if (!fp) {
            perror("fopen tmp");
            return 1;
        }
        if (fwrite(payload_start, 1, payload_size, fp) != payload_size) {
            perror("fwrite payload");
            fclose(fp);
            unlink(tmp_path);
            return 1;
        }
        fclose(fp);
        chmod(tmp_path, 0755);
        if (rename(tmp_path, target_path) != 0) {
            if (errno != EEXIST) {
                snprintf(target_path, sizeof(target_path), "%s", tmp_path);
            }
        }
    }

    argv[0] = target_path;
    execv(target_path, argv);
    perror("execv target");
    return 1;
}
"""


def build_scie_from_pex(pex_path, output_path, options):
    science_binary = options.scie_science_binary if options.scie_science_binary else None
    science = ensure_science(science_binary=science_binary)

    work_dir = safe_mkdtemp()
    try:
        app_name = os.path.splitext(os.path.basename(output_path))[0]
        dest_pex_name = "app.pex"
        dest_pex_path = os.path.join(work_dir, dest_pex_name)
        shutil.copyfile(pex_path, dest_pex_path)
        os.chmod(dest_pex_path, 0o755)

        is_lazy = options.scie == "lazy"
        py_ver = options.scie_python_version or "3.13"

        platforms = list(options.scie_platforms)
        if not platforms and sys.platform == "darwin":
            platforms = ["macos-aarch64", "macos-x86_64"]

        is_multi_platform = len(platforms) > 1

        lines = [
            "[lift]",
            f'name = "{app_name}"',
        ]

        if platforms:
            platforms_str = ", ".join(f'"{p}"' for p in platforms)
            lines.append(f"platforms = [{platforms_str}]")

        lines.extend([
            "",
            "[[lift.interpreters]]",
            'id = "cpython"',
            'provider = "PythonBuildStandalone"',
            f'version = "{py_ver}"',
            f'lazy = {"true" if is_lazy else "false"}',
        ])

        if options.scie_pbs_release:
            lines.append(f'release = "{options.scie_pbs_release}"')

        lines.extend([
            "",
            "[[lift.files]]",
            f'name = "{dest_pex_name}"',
            "",
            "[[lift.commands]]",
            'exe = "#{cpython:python}"',
            f'args = ["{{{dest_pex_name}}}"]',
        ])

        env_items = {}
        for env_item in (options.inject_env or []) + (options.scie_env or []):
            if "=" in env_item:
                k, v = env_item.split("=", 1)
                env_items[k] = v

        if env_items:
            lines.append("")
            lines.append("[lift.commands.env.replace]")
            for k, v in env_items.items():
                lines.append(f'{k} = "{v}"')

        manifest_path = os.path.join(work_dir, "lift.toml")
        with open(manifest_path, "w") as f:
            f.write("\n".join(lines) + "\n")

        dest_dir = os.path.join(work_dir, "dist")
        os.makedirs(dest_dir, exist_ok=True)

        cmd = [
            science,
            "lift",
            "build",
            "--dest-dir",
            dest_dir,
        ]
        if not is_multi_platform:
            cmd.append("--no-use-platform-suffix")
        cmd.append(manifest_path)

        res = subprocess.run(cmd, cwd=work_dir, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        if res.returncode != 0:
            print(f"Error executing science: {res.stderr}\n{res.stdout}", file=sys.stderr)
            sys.exit(res.returncode)

        os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)

        is_macos_fat = (
            "macos-aarch64" in platforms
            and "macos-x86_64" in platforms
            and sys.platform == "darwin"
        )

        if is_macos_fat:
            arm64_bin = os.path.join(dest_dir, f"{app_name}-macos-aarch64")
            x86_64_bin = os.path.join(dest_dir, f"{app_name}-macos-x86_64")

            launcher_src = os.path.join(work_dir, "universal_launcher.c")
            with open(launcher_src, "w") as f:
                f.write(UNIVERSAL_LAUNCHER_C)

            clang_cmd = [
                "clang",
                "-arch", "arm64",
                "-arch", "x86_64",
                f"-DAPP_NAME=\"{app_name}\"",
                f"-DARM64_SCIE_PATH=\"{arm64_bin}\"",
                f"-DX86_64_SCIE_PATH=\"{x86_64_bin}\"",
                "-O2",
                launcher_src,
                "-o", output_path,
            ]
            compile_res = subprocess.run(clang_cmd, capture_output=True, text=True)
            if compile_res.returncode != 0:
                print(f"Error compiling universal launcher: {compile_res.stderr}", file=sys.stderr)
                sys.exit(compile_res.returncode)
            os.chmod(output_path, 0o755)
        else:
            built_binary = os.path.join(dest_dir, app_name)
            if not os.path.exists(built_binary):
                candidates = os.listdir(dest_dir)
                if candidates:
                    built_binary = os.path.join(dest_dir, candidates[0])
                else:
                    print(f"Error: science did not produce an executable in {dest_dir}", file=sys.stderr)
                    sys.exit(1)

            if os.path.exists(output_path):
                os.remove(output_path)
            shutil.copyfile(built_binary, output_path)
            os.chmod(output_path, 0o755)
    finally:
        safe_rmtree(work_dir)


def main():
    options = parse_args()

    if options.scie in ("eager", "lazy"):
        build_scie_from_pex(options.pex_file, options.output, options)
    else:
        if os.path.exists(options.output):
            os.remove(options.output)
        shutil.copyfile(options.pex_file, options.output)
        os.chmod(options.output, 0o755)


if __name__ == "__main__":
    main()
