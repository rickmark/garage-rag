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

        lines = [
            "[lift]",
            f'name = "{app_name}"',
            "",
            "[[lift.interpreters]]",
            'id = "cpython"',
            'provider = "PythonBuildStandalone"',
            f'version = "{py_ver}"',
            f'lazy = {"true" if is_lazy else "false"}',
        ]

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
            "--no-use-platform-suffix",
            manifest_path,
        ]

        res = subprocess.run(cmd, cwd=work_dir, capture_output=True, text=True)
        if res.returncode != 0:
            print(f"Error executing science: {res.stderr}\n{res.stdout}", file=sys.stderr)
            sys.exit(res.returncode)

        built_binary = os.path.join(dest_dir, app_name)
        if not os.path.exists(built_binary):
            candidates = os.listdir(dest_dir)
            if candidates:
                built_binary = os.path.join(dest_dir, candidates[0])
            else:
                print(f"Error: science did not produce an executable in {dest_dir}", file=sys.stderr)
                sys.exit(1)

        os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
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
