#!/usr/bin/env python3
"""
Installs Lambda dependencies into lambda/package/ so that Terraform's
archive_file data source can zip them up.

Usage: python build.py <module_dir>
"""
import os
import sys
import shutil
import subprocess


REQUIRED_PYTHON = (3, 12)


def build(module_dir: str) -> None:
    if sys.version_info[:2] != REQUIRED_PYTHON:
        print(
            f"ERROR: Lambda runtime is Python {REQUIRED_PYTHON[0]}.{REQUIRED_PYTHON[1]},"
            f" but this script is running on Python {sys.version_info[0]}.{sys.version_info[1]}."
            " Install Python 3.12 or create a virtualenv with it before running terraform apply.",
            file=sys.stderr,
        )
        sys.exit(1)

    lambda_dir   = os.path.join(module_dir, "lambda")
    package_dir  = os.path.join(lambda_dir, "package")
    requirements = os.path.join(lambda_dir, "requirements.txt")
    seed_py      = os.path.join(lambda_dir, "seed.py")

    # Check whether pip packages are already installed. If present, skip the
    # install step so repeated applies in the same directory complete in seconds.
    # This matters when null_resource.build_package uses always_run = timestamp()
    # to guarantee the build runs in every Terragrunt cache directory.
    pg8000_present  = os.path.isdir(os.path.join(package_dir, "pg8000"))
    pymysql_present = os.path.isdir(os.path.join(package_dir, "pymysql"))

    if pg8000_present and pymysql_present:
        print("Dependencies already present, skipping pip install.")
    else:
        # Clear stale package contents before a fresh install, keeping .gitkeep.
        for item in os.listdir(package_dir):
            if item == ".gitkeep":
                continue
            item_path = os.path.join(package_dir, item)
            if os.path.isfile(item_path) or os.path.islink(item_path):
                os.remove(item_path)
            elif os.path.isdir(item_path):
                shutil.rmtree(item_path)

        print("Installing Lambda dependencies...")
        try:
            subprocess.check_call(
                [
                    sys.executable, "-m", "pip", "install",
                    "-r", requirements,
                    "-t", package_dir,
                    "--quiet",
                    "--no-cache-dir",
                ]
            )
        except subprocess.CalledProcessError as e:
            print(
                f"ERROR: pip install failed (exit code {e.returncode}).\n"
                f"Check that pip is available and that all packages in {requirements} "
                f"can be installed on this platform.",
                file=sys.stderr,
            )
            sys.exit(1)

    shutil.copy(seed_py, package_dir)
    print(f"Lambda package ready: {package_dir}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: build.py <module_dir>", file=sys.stderr)
        sys.exit(1)
    build(sys.argv[1])
