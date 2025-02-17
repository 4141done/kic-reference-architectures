#!/usr/bin/env bash

set -o errexit  # abort on nonzero exit status
set -o pipefail # don't hide errors within pipes

# Function below is based upon code in this StackOverflow post:
# https://stackoverflow.com/a/31939275/33611
# CC BY-SA 3.0 License: https://creativecommons.org/licenses/by-sa/3.0/
function askYesNo() {
  QUESTION=$1
  DEFAULT=$2
  if [ "$DEFAULT" = true ]; then
    OPTIONS="[Y/n]"
    DEFAULT="y"
  else
    OPTIONS="[y/N]"
    DEFAULT="n"
  fi
  if [ "${DEBIAN_FRONTEND}" != "noninteractive" ]; then
    read -p "$QUESTION $OPTIONS " -n 1 -s -r INPUT
    INPUT=${INPUT:-${DEFAULT}}
    echo "${INPUT}"
  fi

  if [ "${DEBIAN_FRONTEND}" == "noninteractive" ]; then
    ANSWER=$DEFAULT
  elif [[ "$INPUT" =~ ^[yY]$ ]]; then
    ANSWER=true
  else
    ANSWER=false
  fi
}

# Does basic OS distribution detection for "class" of distribution, such
# as debian, rhel, etc
function distro_like() {
  local like
  if [ "$(uname -s)" == "Darwin" ]; then
    like="darwin"
  elif [ -f /etc/os-release ]; then
    if grep --quiet '^ID_LIKE=' /etc/os-release; then
      like="$(grep '^ID_LIKE=' /etc/os-release | cut -d'=' -f2 | tr -d \")"
    else
      like="$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d \")"
    fi
  else
    like="unknown"
  fi

  echo "${like}"
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Unset if defined
unset VIRTUAL_ENV

if ! command -v git >/dev/null; then
  echo >&2 "git must be installed to continue"
  exit 1
fi

if ! command -v python3 >/dev/null; then
  if ! command -v make >/dev/null; then
    echo >&2 "make must be installed in order to install python with pyenv"
    echo >&2 "Either install make or install Python 3 with the venv module"
    exit 1
  fi
  if ! command -v gcc >/dev/null; then
    echo >&2 "gcc must be installed in order to install python with pyenv"
    echo >&2 "Either install gcc or install Python 3 with the venv module"
    exit 1
  fi

  echo "Python 3 is not installed. Adding pyenv to allow for Python installation"
  echo "If development library dependencies are not installed, Python build may fail."

  # Give relevant hint for the distro
  if distro_like | grep --quiet 'debian'; then
    echo "You may need to install additional packages using a command like the following:"
    echo "   apt-get install libbz2-dev libffi-dev libreadline-dev libsqlite3-dev libssl-dev"
  elif distro_like | grep --quiet 'rhel'; then
    echo "You may need to install additional packages using a command like the following:"
    echo "   yum install bzip2-devel libffi-devel readline-devel sqlite-devel openssl-devel zlib-devel"
  else
    echo "required libraries: libbz2 libffi libreadline libsqlite3 libssl zlib1g"
  fi

  export PYENV_ROOT="${script_dir}/../pulumi/python/.pyenv"

  mkdir -p "${PYENV_ROOT}"
  git_clone_log="$(mktemp -t pyenv_git_clone-XXXXXXX.log)"
  if git clone --depth 1 --branch v2.0.3 https://github.com/pyenv/pyenv.git "${PYENV_ROOT}" 2>"${git_clone_log}"; then
    rm "${git_clone_log}"
  else
    echo >&2 "Error cloning pyenv repository:"
    cat >&2 "${git_clone_log}"
  fi

  export PATH="$PYENV_ROOT/bin:$PATH"
fi

# If pyenv is available we use a hardcoded python version
if command -v pyenv >/dev/null; then
  eval "$(pyenv init --path)"
  eval "$(pyenv init -)"
  pyenv install --skip-existing <"${script_dir}/../.python-version"

  # If the pyenv-virtualenv tools are installed, prompt the user if they want to
  # use them.
  if [ -d "${PYENV_ROOT}/plugins/pyenv-virtualenv" ]; then
    askYesNo "Use pyenv-virtualenv to manage virtual environment?" true
    if [ $ANSWER = true ]; then
      has_pyenv_venv_plugin=1
    else
      has_pyenv_venv_plugin=0
    fi
  else
    has_pyenv_venv_plugin=0
  fi
else
  has_pyenv_venv_plugin=0
fi

# if pyenv with virtual-env plugin is installed, use that
if [ ${has_pyenv_venv_plugin} -eq 1 ]; then
  eval "$(pyenv virtualenv-init -)"

  if ! pyenv virtualenvs --bare | grep --quiet '^ref-arch-pulumi-aws'; then
    pyenv virtualenv ref-arch-pulumi-aws
  fi

  if [ -z "${VIRTUAL_ENV}" ]; then
    pyenv activate ref-arch-pulumi-aws
  fi

  if [ -h "${script_dir}/../pulumi/python/venv" ]; then
    echo "Link already exists [${script_dir}/../pulumi/python/venv] - removing and relinking"
    rm "${script_dir}/../pulumi/python/venv"
  elif [ -d "${script_dir}/../pulumi/python/venv" ]; then
    echo "Virtual environment directory already exists"
    askYesNo "Delete and replace with pyenv-virtualenv managed link?" false
    if [ $ANSWER = true ]; then
      echo "Deleting ${script_dir}/../pulumi/python/venv"
      rm -rf "${script_dir}/../pulumi/python/venv"
    else
      echo >&2 "The path ${script_dir}/../pulumi/python/venv must not be a virtual environment directory when using pyenv-virtualenv"
      echo >&2 "Exiting. Please manually remove the directory"
      exit 1
    fi
  fi

  echo "Linking virtual environment [${VIRTUAL_ENV}] to local directory [venv]"
  ln -s "${VIRTUAL_ENV}" "${script_dir}/../pulumi/python/venv"
fi

# If pyenv isn't present do everything with default python tooling
if [ ${has_pyenv_venv_plugin} -eq 0 ]; then
  if [ -z "${VIRTUAL_ENV}" ]; then
    VIRTUAL_ENV="${script_dir}/../pulumi/python/venv"
    echo "No virtual environment already specified, defaulting to: ${VIRTUAL_ENV}"
  fi

  if [ ! -d "${VIRTUAL_ENV}" ]; then
    echo "Creating new virtual environment: ${VIRTUAL_ENV}"
    if ! python3 -m venv "${VIRTUAL_ENV}"; then
      echo "Deleting partially created virtual environment: ${VIRTUAL_ENV}"
      rm -rf "${VIRTUAL_ENV}" || true
    fi
  fi

  source "${VIRTUAL_ENV}/bin/activate"
fi

source "${VIRTUAL_ENV}/bin/activate"

set -o nounset # abort on unbound variable

# Use the latest version of pip
pip3 install --upgrade pip

# Installs wheel package management, so that pulumi requirements install quickly
pip3 install wheel

# Get nodeenv version so that node can be installed before we install Python
# dependencies because pulumi_eks depends on the presence of node.
pip3 install "$(grep nodeenv "${script_dir}/../pulumi/python/requirements.txt")"

# Install node.js into virtual environment so that it can be used by Python
# modules that make call outs to it.
if [ ! -x "${VIRTUAL_ENV}/bin/node" ]; then
  nodeenv -p --node=lts
else
  echo "Node.js version $("${VIRTUAL_ENV}/bin/node" --version) is already installed"
fi

# Install general package requirements
pip3 install --requirement "${script_dir}/../pulumi/python/requirements.txt"
# Install local common utilities module
pip3 install "${script_dir}/../pulumi/python/utility/kic-pulumi-utils" &&
  rm -rf "${script_dir}/../pulumi/python/utility/kic-pulumi-utils/.eggs" \
    "${script_dir}/../pulumi/python/utility/kic-pulumi-utils/build" \
    "${script_dir}/../pulumi/python/utility/kic-pulumi-utils/kic_pulumi_utils.egg-info"

ARCH=""
case $(uname -m) in
i386) ARCH="386" ;;
i686) ARCH="386" ;;
x86_64) ARCH="amd64" ;;
aarch64) ARCH="arm64" ;;
arm64) ARCH="arm64" ;;
arm) dpkg --print-architecture | grep -q "arm64" && ARCH="arm64" || ARCH="arm" ;;
*)
  echo >&2 "Unable to determine system architecture."
  exit 1
  ;;
esac
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

if command -v wget >/dev/null; then
  download_cmd="wget --quiet --max-redirect=12 --output-document -"
elif command -v curl >/dev/null; then
  download_cmd="curl --fail --silent --location"
else
  echo >&2 "either wget or curl must be installed"
  exit 1
fi

if command -v sha256sum >/dev/null; then
  sha256sum_cmd="sha256sum --check"
elif command -v shasum >/dev/null; then
  sha256sum_cmd="shasum --algorithm 256 --check"
else
  echo >&2 "either sha256sum or shasum must be installed"
  exit 1
fi

#
# This section originally pulled the most recent version of Kubectl down; however it turned out that
# was causing isues with our AWS deploy (see the issues in the repo). Addtionally, this was only
# downloading the kubectl if it did not exist; this could result in versions not being updated if the
# MARA project was run in the same environment w/o a refresh.
#
# The two fixes here are to hardcode (For now) to a known good version (1.23.6) and force the script to
# always download this version.
#
# TODO: Figure out a way to not hardocde the kubectl version
# TODO: Should not always download if the versions match; need a version check
#
#
if [ ! -x "${VIRTUAL_ENV}/bin/kubectl" ]; then
  echo "Downloading kubectl into virtual environment"
  KUBECTL_VERSION="v1.23.6"
  ${download_cmd} "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl" >"${VIRTUAL_ENV}/bin/kubectl"
  KUBECTL_CHECKSUM="$(${download_cmd} "https://dl.k8s.io/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl.sha256")"
  echo "${KUBECTL_CHECKSUM}  ${VIRTUAL_ENV}/bin/kubectl" | ${sha256sum_cmd}
  chmod +x "${VIRTUAL_ENV}/bin/kubectl"
else
  echo "kubectl is already installed, but will overwrite to ensure correct version"
  echo "Downloading kubectl into virtual environment"
  KUBECTL_VERSION="v1.23.6"
  ${download_cmd} "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl" >"${VIRTUAL_ENV}/bin/kubectl"
  KUBECTL_CHECKSUM="$(${download_cmd} "https://dl.k8s.io/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl.sha256")"
  echo "${KUBECTL_CHECKSUM}  ${VIRTUAL_ENV}/bin/kubectl" | ${sha256sum_cmd}
  chmod +x "${VIRTUAL_ENV}/bin/kubectl"
fi

#
# Download Pulumi CLI tooling
#
# Added some error checking to handle a failure here since it can be a bit confusing to the user (or at least to me)
# when this bombs out and you can't figure out why. Note that the logic is specifically looking for "~=" in the
# requirements file. Other comparisons that are legal in terms of the requirements file WILL fail with this logic.
#
echo "Downloading Pulumi CLI into virtual environment"
PULUMI_VERSION="$(grep '^pulumi~=.*$' "${script_dir}/../pulumi/python/requirements.txt" | cut -d '=' -f2 || true)"
    if  [ -z $PULUMI_VERSION ] ; then
      echo "Failed to find Pulumi version - EXITING"
      exit 5
    else
      echo "Pulumi version found"
    fi

if [[ -x "${VIRTUAL_ENV}/bin/pulumi" ]] && [[ "$(PULUMI_SKIP_UPDATE_CHECK=true "${VIRTUAL_ENV}/bin/pulumi" version)" == "v${PULUMI_VERSION}" ]]; then
  echo "Pulumi version ${PULUMI_VERSION} is already installed"
else
  PULUMI_TARBALL_URL="https://get.pulumi.com/releases/sdk/pulumi-v${PULUMI_VERSION}-${OS}-${ARCH/amd64/x64}.tar.gz"
  PULUMI_TARBALL_DESTTARBALL_DEST=$(mktemp -t pulumi.tar.gz.XXXXXXXXXX)
  ${download_cmd} "${PULUMI_TARBALL_URL}" >"${PULUMI_TARBALL_DESTTARBALL_DEST}"
      [ $? -eq 0 ] && echo "Pulumi downloaded successfully" || echo "Failed to download Pulumi"
  tar --extract --gunzip --directory "${VIRTUAL_ENV}/bin" --strip-components 1 --file "${PULUMI_TARBALL_DESTTARBALL_DEST}"
      [ $? -eq 0 ] && echo "Pulumi installed successfully" || echo "Failed to install Pulumi"
  rm "${PULUMI_TARBALL_DESTTARBALL_DEST}"
fi
