import platform
import sys


def main() -> None:
    print("Python is ready.")
    print(f"  version: {sys.version.split()[0]}")
    print(f"  executable: {sys.executable}")
    print(f"  platform: {platform.platform()}")


if __name__ == "__main__":
    main()
