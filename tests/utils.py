import os
import shutil


def init_env():
    xdg_config_home = "Xtest/xdg/config"
    xdg_data_home = "Xtest/xdg/share"
    tmpdir = "Xtest/tmp"
    os.environ["XDG_CONFIG_HOME"] = xdg_config_home
    os.environ["XDG_DATA_HOME"] = xdg_data_home
    os.environ["TMPDIR"] = tmpdir

    # Unset $NVIM so that when you run tests inside Nvim terminal, it doesn't
    # make parent Nvim open a new tab
    if "NVIM" in os.environ:
        del os.environ["NVIM"]

    # Unset $SHELL to make tests use POSIX shell (sh) on POSIX
    # systems. This doesn't affect Windows though.
    if "SHELL" in os.environ:
        del os.environ["SHELL"]

    os.makedirs(tmpdir, exist_ok=True)
    os.makedirs(xdg_config_home + "/nvim", exist_ok=True)

    config_file = os.path.join(xdg_config_home, "nvim", "init.lua")
    if not os.path.exists(config_file):
        shutil.copy("scripts/init.lua", config_file)


def clean():
    shutil.rmtree("Xtest", ignore_errors=True)
