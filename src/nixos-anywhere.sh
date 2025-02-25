#!/usr/bin/env bash
set -euo pipefail

here=$(dirname "${BASH_SOURCE[0]}")
kexecUrl=""
kexecExtraFlags=""
enableDebug=""
nixOptions=(
  --extra-experimental-features 'nix-command flakes'
  "--no-write-lock-file"
)
SSH_PRIVATE_KEY=${SSH_PRIVATE_KEY-}

declare -A phases
phases[kexec]=1
phases[disko]=1
phases[install]=1
phases[reboot]=1

substituteOnDestination=y
sshPrivateKeyFile=
if [ -t 0 ]; then # stdin is a tty, we allow interactive input to ssh i.e. passwords
  sshTtyParam="-t"
else
  sshTtyParam="-T"
fi
postKexecSshPort=22
buildOnRemote=n
envPassword=

declare -A diskEncryptionKeys
declare -a nixCopyOptions
declare -a sshArgs

showUsage() {
  cat <<USAGE
Usage: nixos-anywhere [options] <ssh-host>

Options:

* -f, --flake <flake_uri>
  set the flake to install the system from.
* -i <identity_file>
  selects which SSH private key file to use.
* -p, --ssh-port <ssh_port>
  set the ssh port to connect with
* --ssh-option <ssh_option>
  set an ssh option
* -L, --print-build-logs
  print full build logs
* --env-password
  set a password used by ssh-copy-id, the password should be set by
  the environment variable SSHPASS
* -s, --store-paths <disko-script> <nixos-system>
  set the store paths to the disko-script and nixos-system directly
  if this is given, flake is not needed
* --kexec <path>
  use another kexec tarball to bootstrap NixOS
* --kexec-extra-flags
  extra flags to add into the call to kexec, e.g. "--no-sync"
* --post-kexec-ssh-port <ssh_port>
  after kexec is executed, use a custom ssh port to connect. Defaults to 22
* --copy-host-keys
  copy over existing /etc/ssh/ssh_host_* host keys to the installation
* --extra-files <path>
  path to a directory to copy into the root of the new nixos installation.
  Copied files will be owned by root.
* --disk-encryption-keys <remote_path> <local_path>
  copy the contents of the file or pipe in local_path to remote_path in the installer environment,
  after kexec but before installation. Can be repeated.
* --no-substitute-on-destination
  disable passing --substitute-on-destination to nix-copy
* --debug
  enable debug output
* --option <key> <value>
  nix option to pass to every nix related command
* --from <store-uri>
  URL of the source Nix store to copy the nixos and disko closure from
* --build-on-remote
  build the closure on the remote machine instead of locally and copy-closuring it
* --vm-test
  build the system and test the disk configuration inside a VM without installing it to the target.
* --phases
  comma separated list of phases to run. Default is: kexec,disko,install,reboot
  kexec: kexec into the nixos installer
  disko: first unmount and destroy all filesystems on the disks we want to format, then run the create and mount mode
  install: install the system
  reboot: reboot the machine
USAGE
}

abort() {
  echo "aborted: $*" >&2
  exit 1
}

step() {
  echo "### $* ###"
}

parseArgs() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -f | --flake)
      flake=$2
      shift
      ;;
    -i)
      sshPrivateKeyFile=$2
      shift
      ;;
    -p | --ssh-port)
      sshArgs+=("-p" "$2")
      shift
      ;;
    --ssh-option)
      sshArgs+=("-o" "$2")
      shift
      ;;
    -L | --print-build-logs)
      printBuildLogs=y
      ;;
    -s | --store-paths)
      diskoScript=$(readlink -f "$2")
      nixosSystem=$(readlink -f "$3")
      shift
      shift
      ;;
    -t | --tty)
      echo "the '$1' flag is deprecated, a tty is now detected automatically" >&2
      ;;
    --help)
      showUsage
      exit 0
      ;;
    --kexec)
      kexecUrl=$2
      shift
      ;;
    --kexec-extra-flags)
      kexecExtraFlags=$2
      shift
      ;;
    --post-kexec-ssh-port)
      postKexecSshPort=$2
      shift
      ;;
    --copy-host-keys)
      copyHostKeys=y
      ;;
    --debug)
      enableDebug="-x"
      printBuildLogs=y
      set -x
      ;;
    --extra-files)
      extraFiles=$2
      shift
      ;;
    --disk-encryption-keys)
      diskEncryptionKeys["$2"]="$3"
      shift
      shift
      ;;
    --phases)
      phases[kexec]=0
      phases[disko]=0
      phases[install]=0
      phases[reboot]=0
      IFS=, read -r -a phaseList <<<"$2"
      for phase in "${phaseList[@]}"; do
        if [[ ${phases[$phase]:-unset} == unset ]]; then
          abort "Unknown phase: $phase"
        fi
        phases[$phase]=1
      done
      shift
      ;;
    --stop-after-disko)
      echo "WARNING: --stop-after-disko is deprecated, use --phases=kexec,disko instead" 2>&1
      phases[kexec]=1
      phases[disko]=1
      phases[install]=0
      phases[reboot]=0
      ;;
    --no-reboot)
      echo "WARNING: --no-reboot is deprecated, use --phases=kexec,disko,install instead" 2>&1
      phases[kexec]=1
      phases[disko]=1
      phases[install]=1
      phases[reboot]=0
      ;;
    --from)
      nixCopyOptions+=("--from" "$2")
      shift
      ;;
    --option)
      key=$2
      shift
      value=$2
      shift
      nixOptions+=("--option" "$key" "$value")
      ;;
    --no-substitute-on-destination)
      substituteOnDestination=n
      ;;
    --build-on-remote)
      buildOnRemote=y
      ;;
    --env-password)
      envPassword=y
      ;;
    --vm-test)
      vmTest=y
      ;;
    *)
      if [[ -z ${sshConnection-} ]]; then
        sshConnection="$1"
      else
        showUsage
        exit 1
      fi
      ;;
    esac
    shift
  done

  if [[ ${printBuildLogs-n} == "y" ]]; then
    nixOptions+=("-L")
  fi

  if [[ ${substituteOnDestination-n} == "y" ]]; then
    nixCopyOptions+=("--substitute-on-destination")
  fi

  if [[ -z ${sshConnection-} ]]; then
    abort "ssh-host must be set"
  fi

  if [[ -n ${flake-} ]]; then
    if [[ $flake =~ ^(.*)\#([^\#\"]*)$ ]]; then
      flake="${BASH_REMATCH[1]}"
      flakeAttr="${BASH_REMATCH[2]}"
    fi
    if [[ -z ${flakeAttr-} ]]; then
      echo "Please specify the name of the NixOS configuration to be installed, as a URI fragment in the flake-uri." >&2
      echo 'For example, to use the output nixosConfigurations.foo from the flake.nix, append "#foo" to the flake-uri.' >&2
      exit 1
    fi
  fi

}

# ssh wrapper
runSshTimeout() {
  timeout 10 ssh -i "$sshKeyDir"/nixos-anywhere -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "${sshArgs[@]}" "$sshConnection" "$@"
}
runSsh() {
  ssh "$sshTtyParam" -i "$sshKeyDir"/nixos-anywhere -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "${sshArgs[@]}" "$sshConnection" "$@"
}

nixCopy() {
  NIX_SSHOPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i $sshKeyDir/nixos-anywhere ${sshArgs[*]}" nix copy \
    "${nixOptions[@]}" \
    "${nixCopyOptions[@]}" \
    "$@"
}
nixBuild() {
  NIX_SSHOPTS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i $sshKeyDir/nixos-anywhere ${sshArgs[*]}" nix build \
    --print-out-paths \
    --no-link \
    "${nixOptions[@]}" \
    "$@"
}

runVmTest() {
  if [[ -z ${flakeAttr-} ]]; then
    echo "--vm-test is not supported with --store-paths" >&2
    echo "Please use --flake instead or build config.system.build.installTest of your nixos configuration manually" >&2
    exit 1
  fi

  if [[ ${buildOnRemote} == "y" ]]; then
    echo "--vm-test is not supported with --build-on-remote" >&2
    exit 1
  fi
  if [[ -n ${extraFiles-} ]]; then
    echo "--vm-test is not supported with --extra-files" >&2
    exit 1
  fi
  if [[ -n ${diskEncryptionKeys-} ]]; then
    echo "--vm-test is not supported with --disk-encryption-keys" >&2
    exit 1
  fi
  exec nix build \
    --print-out-paths \
    --no-link \
    -L \
    "${nixOptions[@]}" \
    "${flake}#nixosConfigurations.\"${flakeAttr}\".config.system.build.installTest"
}

uploadSshKey() {
  # we generate a temporary ssh keypair that we can use during nixos-anywhere
  sshKeyDir=$(mktemp -d)
  trap 'rm -rf "$sshKeyDir"' EXIT
  mkdir -p "$sshKeyDir"
  # ssh-copy-id requires this directory
  mkdir -p "$HOME/.ssh/"
  ssh-keygen -t ed25519 -f "$sshKeyDir"/nixos-anywhere -P "" -C "nixos-anywhere" >/dev/null

  declare -a sshCopyIdArgs
  if [[ -n ${sshPrivateKeyFile} ]]; then
    unset SSH_AUTH_SOCK # don't use system agent if key was supplied
    sshCopyIdArgs+=(-o "IdentityFile=${sshPrivateKeyFile}" -f)
  fi

  step Uploading install SSH keys
  until
    if [[ -n ${envPassword} ]]; then
      sshpass -e \
        ssh-copy-id \
        -i "$sshKeyDir"/nixos-anywhere.pub \
        -o ConnectTimeout=10 \
        -o UserKnownHostsFile=/dev/null \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no \
        "${sshCopyIdArgs[@]}" \
        "${sshArgs[@]}" \
        "$sshConnection"
    else
      ssh-copy-id \
        -i "$sshKeyDir"/nixos-anywhere.pub \
        -o ConnectTimeout=10 \
        -o UserKnownHostsFile=/dev/null \
        -o StrictHostKeyChecking=no \
        "${sshCopyIdArgs[@]}" \
        "${sshArgs[@]}" \
        "$sshConnection"
    fi
  do
    sleep 3
  done
}

importFacts() {
  step Gathering machine facts
  local facts filteredFacts
  if ! facts=$(runSsh -o ConnectTimeout=10 enableDebug=$enableDebug sh -- <"$here"/get-facts.sh); then
    exit 1
  fi
  filteredFacts=$(echo "$facts" | grep -E '^(has|is)[A-Za-z0-9_]+=\S+')
  if [[ -z $filteredFacts ]]; then
    abort "Retrieving host facts via ssh failed. Check with --debug for the root cause, unless you have done so already"
  fi
  # make facts available in script
  # shellcheck disable=SC2046
  export $(echo "$filteredFacts" | xargs)
}

runKexec() {
  if [[ ${isKexec-n} == "y" ]] || [[ ${isInstaller-n} == "y" ]]; then
    return
  fi

  if [[ ${isContainer-none} != "none" ]]; then
    echo "WARNING: This script does not support running from a '${isContainer}' container. kexec will likely not work" >&2
  fi

  if [[ $kexecUrl == "" ]]; then
    case "${isArch-unknown}" in
    x86_64 | aarch64)
      kexecUrl="https://github.com/nix-community/nixos-images/releases/download/nixos-24.05/nixos-kexec-installer-noninteractive-${isArch}-linux.tar.gz"
      ;;
    *)
      abort "Unsupported architecture: ${isArch}. Our default kexec images only support x86_64 and aarch64 cpus. Checkout https://github.com/nix-community/nixos-anywhere/#using-your-own-kexec-image for more information."
      ;;
    esac
  fi

  step Switching system into kexec
  runSsh sh <<SSH
set -efu ${enableDebug}
$maybeSudo rm -rf /root/kexec
$maybeSudo mkdir -p /root/kexec
SSH

  # no way to reach global ipv4 destinations, use gh-v6.com automatically if github url
  if [[ ${hasIpv6Only-n} == "y" ]] && [[ $kexecUrl == "https://github.com/"* ]]; then
    kexecUrl=${kexecUrl/"github.com"/"gh-v6.com"}
  fi

  if [[ -f $kexecUrl ]]; then
    runSsh "${maybeSudo} tar -C /root/kexec -xvzf-" <"$kexecUrl"
  elif [[ ${hasCurl-n} == "y" ]]; then
    runSsh "curl --fail -Ss -L '${kexecUrl}' | ${maybeSudo} tar -C /root/kexec -xvzf-"
  elif [[ ${hasWget-n} == "y" ]]; then
    runSsh "wget '${kexecUrl}' -O- | ${maybeSudo} tar -C /root/kexec -xvzf-"
  else
    curl --fail -Ss -L "${kexecUrl}" | runSsh "${maybeSudo} tar -C /root/kexec -xvzf-"
  fi

  runSsh <<SSH
TMPDIR=/root/kexec setsid ${maybeSudo} /root/kexec/kexec/run --kexec-extra-flags "${kexecExtraFlags}"
SSH

  # use the default SSH port to connect at this point
  for i in "${!sshArgs[@]}"; do
    if [[ ${sshArgs[i]} == "-p" ]]; then
      sshArgs[i + 1]=$postKexecSshPort
      break
    fi
  done

  # wait for machine to become unreachable.
  while runSshTimeout -- exit 0; do sleep 1; done

  # After kexec we explicitly set the user to root@
  sshConnection="root@${sshHost}"

  # waiting for machine to become available again
  until runSsh -o ConnectTimeout=10 -- exit 0; do sleep 5; done
}

runDisko() {
  local diskoScript=$1
  for path in "${!diskEncryptionKeys[@]}"; do
    step "Uploading ${diskEncryptionKeys[$path]} to $path"
    runSsh "umask 077; cat > $path" <"${diskEncryptionKeys[$path]}"
  done
  if [[ -n ${diskoScript-} ]]; then
    nixCopy --to "ssh://$sshConnection" "$diskoScript"
  elif [[ ${buildOnRemote} == "y" ]]; then
    step Building disko script
    # We need to do a nix copy first because nix build doesn't have --no-check-sigs
    nixCopy --to "ssh-ng://$sshConnection" "${flake}#nixosConfigurations.\"${flakeAttr}\".config.system.build.diskoScript" \
      --derivation --no-check-sigs
    diskoScript=$(
      nixBuild "${flake}#nixosConfigurations.\"${flakeAttr}\".config.system.build.diskoScript" \
        --eval-store auto --store "ssh-ng://$sshConnection?ssh-key=$sshKeyDir/nixos-anywhere"
    )
  fi

  step Formatting hard drive with disko
  runSsh "$diskoScript"
}

nixosInstall() {
  if [[ -n ${nixosSystem-} ]]; then
    step Uploading the system closure
    nixCopy --to "ssh://$sshConnection?remote-store=local?root=/mnt" "$nixosSystem"
  elif [[ ${buildOnRemote} == "y" ]]; then
    step Building the system closure
    # We need to do a nix copy first because nix build doesn't have --no-check-sigs
    nixCopy --to "ssh-ng://$sshConnection?remote-store=local?root=/mnt" "${flake}#nixosConfigurations.\"${flakeAttr}\".config.system.build.toplevel" \
      --derivation --no-check-sigs
    nixosSystem=$(
      nixBuild "${flake}#nixosConfigurations.\"${flakeAttr}\".config.system.build.toplevel" \
        --eval-store auto --store "ssh-ng://$sshConnection?ssh-key=$sshKeyDir/nixos-anywhere&remote-store=local?root=/mnt"
    )
  fi

  if [[ -n ${extraFiles-} ]]; then
    step Copying extra files
    tar -C "$extraFiles" -cpf- . | runSsh "${maybeSudo} tar -C /mnt -xf- --no-same-owner"
    runSsh "chmod 755 /mnt" # tar also changes permissions of /mnt
  fi

  step Installing NixOS
  maybeReboot=""
  if [[ ${phases[reboot]-} == 1 ]]; then
    maybeReboot="nohup sh -c 'sleep 6 && reboot' >/dev/null &"
  fi
  runSsh sh <<SSH
set -eu ${enableDebug}
# when running not in nixos we might miss this directory, but it's needed in the nixos chroot during installation
export PATH="\$PATH:/run/current-system/sw/bin"

# needed for installation if initrd-secrets are used
mkdir -p /mnt/tmp
chmod 777 /mnt/tmp
if [ ${copyHostKeys-n} = "y" ]; then
  # NB we copy host keys that are in turn copied by kexec installer.
  mkdir -m 755 -p /mnt/etc/ssh
  for p in /etc/ssh/ssh_host_*; do
    # Skip if the source file does not exist (i.e. glob did not match any files)
    # or the destination already exists (e.g. copied with --extra-files).
    if [ ! -e "\$p" ] || [ -e "/mnt/\$p" ]; then
      continue
    fi
    cp -a "\$p" "/mnt/\$p"
  done
fi
nixos-install --no-root-passwd --no-channel-copy --system "$nixosSystem"
if command -v zpool >/dev/null && [ "\$(zpool list)" != "no pools available" ]; then
  # we always want to export the zfs pools so people can boot from it without force import
  umount -Rv /mnt/
  zpool export -a || true
fi
${maybeReboot}
SSH

}

main() {
  parseArgs "$@"

  if [[ -n ${vmTest-} ]]; then
    runVmTest
  fi

  # parse flake nixos-install style syntax, get the system attr
  if [[ -n ${flake-} ]]; then
    if [[ ${buildOnRemote} == "n" ]]; then
      diskoScript=$(nixBuild "${flake}#nixosConfigurations.\"${flakeAttr}\".config.system.build.diskoScript")
      nixosSystem=$(nixBuild "${flake}#nixosConfigurations.\"${flakeAttr}\".config.system.build.toplevel")
    fi
  elif [[ -n ${diskoScript-} ]] && [[ -n ${nixosSystem-} ]]; then
    if [[ ! -e ${diskoScript} ]] || [[ ! -e ${nixosSystem} ]]; then
      abort "${diskoScript} and ${nixosSystem} must be existing store-paths"
    fi
  else
    abort "--flake or --store-paths must be set"
  fi

  if [[ -n ${SSH_PRIVATE_KEY} ]] && [[ -z ${sshPrivateKeyFile-} ]]; then
    # $sshKeyDir is getting deleted on trap EXIT
    sshPrivateKeyFile="$sshKeyDir/from-env"
    (
      umask 077
      printf '%s\n' "$SSH_PRIVATE_KEY" >"$sshPrivateKeyFile"
    )
  fi

  sshSettings=$(ssh "${sshArgs[@]}" -G "${sshConnection}")
  sshUser=$(echo "$sshSettings" | awk '/^user / { print $2 }')
  sshHost=$(echo "$sshSettings" | awk '/^hostname / { print $2 }')

  uploadSshKey

  importFacts

  if [[ ${hasTar-n} == "n" ]]; then
    abort "no tar command found, but required to unpack kexec tarball"
  fi

  if [[ ${hasSetsid-n} == "n" ]]; then
    abort "no setsid command found, but required to run the kexec script under a new session"
  fi

  maybeSudo=""
  if [[ ${hasSudo-n} == "y" ]]; then
    maybeSudo="sudo"
  elif [[ ${hasDoas-n} == "y" ]]; then
    maybeSudo="doas"
  fi

  if [[ ${isOs-n} != "Linux" ]]; then
    abort "This script requires Linux as the operating system, but got $isOs"
  fi

  if [[ ${phases[kexec]-} == 1 ]]; then
    runKexec
  fi

  # Installation will fail if non-root user is used for installer.
  # Switch to root user by copying authorized_keys.
  if [[ ${isInstaller-n} == "y" ]] && [[ ${sshUser} != "root" ]]; then
    # Allow copy to fail if authorized_keys does not exist, like if using /etc/ssh/authorized_keys.d/
    runSsh "${maybeSudo} mkdir -p /root/.ssh; ${maybeSudo} cp ~/.ssh/authorized_keys /root/.ssh || true"
    sshConnection="root@${sshHost}"
  fi

  if [[ ${phases[disko]-} == 1 ]]; then
    runDisko "$diskoScript"
  fi

  if [[ ${phases[install]-} == 1 ]]; then
    nixosInstall
  fi

  if [[ ${phases[reboot]-} == 1 ]]; then
    step Waiting for the machine to become unreachable due to reboot
    while runSshTimeout -- exit 0; do sleep 1; done
  fi

  step "Done!"
}

main "$@"
