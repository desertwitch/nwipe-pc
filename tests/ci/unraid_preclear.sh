#!/usr/bin/env bash
set -eo pipefail

NWIPE_BIN="${1:-./src/nwipe}"
ARTIFACT_DIR="${NWIPE_CI_ARTIFACT_DIR:-}"

if [[ "$(id -u)" -ne 0 ]]; then
	echo "Error: must run as root (loop devices + dmsetup)."
	exit 1
fi

if [[ ! -x "${NWIPE_BIN}" ]]; then
	echo "Error: nwipe binary not executable: ${NWIPE_BIN}"
	exit 2
fi

for cmd in losetup truncate dmsetup dd blockdev hexdump awk grep mktemp tee tail; do
	if ! command -v "${cmd}" >/dev/null 2>&1; then
		echo "Error: required command not found: ${cmd}"
		exit 1
	fi
done

WORKDIR="$(mktemp -d /tmp/unraid-preclear-ci.XXXXXX)"
LOG_DIR="${WORKDIR}/logs"
mkdir -p "${LOG_DIR}"

SMALL_IMG="${WORKDIR}/small.img" # 10MB backing file
LARGE_IMG="${WORKDIR}/large.img" # 10MB backing file for first 10MB of 3TB device
SMALL_LOOP=""
LARGE_LOOP=""

LARGE_DM_NAME="unraid_ci_large_$$"
LARGE_DM_DEV="/dev/mapper/${LARGE_DM_NAME}"

# ------------------------------------------------------------------------------
# HELPERS
# ------------------------------------------------------------------------------

cleanup() {
	echo "==> Cleaning up..."
	if dmsetup info "${LARGE_DM_NAME}" >/dev/null 2>&1; then
		dmsetup remove "${LARGE_DM_NAME}" >/dev/null 2>&1 || true
	fi

	if [[ -n "${LARGE_LOOP}" ]]; then
		losetup -d "${LARGE_LOOP}" >/dev/null 2>&1 || true
	fi

	if [[ -n "${SMALL_LOOP}" ]]; then
		losetup -d "${SMALL_LOOP}" >/dev/null 2>&1 || true
	fi

	if [[ -n "${ARTIFACT_DIR}" ]]; then
		mkdir -p "${ARTIFACT_DIR}"
		cp -a "${LOG_DIR}/." "${ARTIFACT_DIR}/" >/dev/null 2>&1 || true
		cp -f "${SMALL_IMG}" "${ARTIFACT_DIR}/small.img" >/dev/null 2>&1 || true
		cp -f "${LARGE_IMG}" "${ARTIFACT_DIR}/large.img" >/dev/null 2>&1 || true
	fi

	rm -rf "${WORKDIR}"
}
trap cleanup EXIT

verify_mbr() {
	#
	# called verify_mbr "/dev/disX"
	#
	local cleared
	local disk=$1
	local disk_blocks=${disk_properties[blocks_512]}
	local i
	local max_mbr_blocks
	local mbr_blocks
	local over_mbr_size
	local partition_size
	local patterns
	local -a sectors
	local start_sector 
	local patterns=("00000" "00000" "00000" "00170" "00085")
	local max_mbr_blocks=$(printf "%d" 0xFFFFFFFF)

	if [ $disk_blocks -ge $max_mbr_blocks ]; then
		over_mbr_size="y"
		patterns+=("00000" "00000" "00002" "00000" "00000" "00255" "00255" "00255")
		partition_size=$(printf "%d" 0xFFFFFFFF)
		echo "    Checking large MBR layout (> 2TB)..." 
	else
		patterns+=("00000" "00000" "00000" "00000" "00000" "00000" "00000" "00000")
		partition_size=$disk_blocks
		echo "    Checking small MBR layout (< 2TB)..." 
	fi

	#
	# verify MBR boot area is clear
	#
	sectors+=(`dd bs=446 count=1 if=$disk 2>/dev/null | sum | awk '{print $1}'`)

	#
	# verify partitions 2,3, & 4 are cleared
	#
	sectors+=(`dd bs=1 skip=462 count=48 if=$disk 2>/dev/null | sum | awk '{print $1}'`)

	#
	# verify partition type byte is clear
	#
	sectors+=(`dd bs=1 skip=450 count=1 if=$disk 2>/dev/null | sum | awk '{print $1}'`)

	#
	# verify MBR signature bytes are set as expected
	#
	sectors+=(`dd bs=1 count=1 skip=511 if=$disk 2>/dev/null | sum | awk '{print $1}'`)
	sectors+=(`dd bs=1 count=1 skip=510 if=$disk 2>/dev/null | sum | awk '{print $1}'`)

	for i in $(seq 446 461); do
		sectors+=(`dd bs=1 count=1 skip=$i if=$disk 2>/dev/null | sum | awk '{print $1}'`)
	done

	for i in $(seq 0 $((${#patterns[@]}-1)) ); do
		if [ "${sectors[$i]}" != "${patterns[$i]}" ]; then
			echo "Failed test 1: MBR signature is not valid, byte $i [${sectors[$i]}] != [${patterns[$i]}]"
			return 1
		fi
	done

	for i in $(seq ${#patterns[@]} $((${#sectors[@]}-1)) ); do
		if [ $i -le 16 ]; then
			start_sector="$(echo ${sectors[$i]} | awk '{printf("%02x", $1)}')${start_sector}"
		else
			mbr_blocks="$(echo ${sectors[$i]} | awk '{printf("%02x", $1)}')${mbr_blocks}"
		fi
	done

	start_sector=$(printf "%d" "0x${start_sector}")
	mbr_blocks=$(printf "%d" "0x${mbr_blocks}")

	case "$start_sector" in
		63|64)
			if [ $disk_blocks -ge $max_mbr_blocks ]; then
				partition_size=$(printf "%d" 0xFFFFFFFF)
			else
				let partition_size=($disk_blocks - $start_sector)
			fi
			;;
		1)
			if [ "$over_mbr_size" != "y" ]; then
				echo "Failed test 2: GPT start sector [$start_sector] is wrong, should be [1]."
				return 1
			fi
			;;
		*)
			echo "Failed test 3: start sector is different from those accepted by Unraid."
			;;
	esac

	if [ $partition_size -ne $mbr_blocks ]; then
		echo "Failed test 4: physical size didn't match MBR declared size. [$partition_size] != [$mbr_blocks]"
		return 1
	fi

	return 0
}

run_nwipe() {
	local case_name="$1"
	local device="$2"
	local log_file="${LOG_DIR}/${case_name}.log"
	local stdout_file="${LOG_DIR}/${case_name}.stdout"
	local stderr_file="${LOG_DIR}/${case_name}.stderr"

	echo "==> nwipe: case=${case_name} device=${device}"

	set +e
	"${NWIPE_BIN}" \
		--autonuke \
		--nogui \
		--nowait \
		--nosignals \
		--noblank \
		--rounds=1 \
		--directio \
		--sync=0 \
		--verify=off \
		--method=unraid \
		--PDFreportpath=noPDF \
		--logfile="${log_file}" \
		"${device}" \
		> >(tee "${stdout_file}") \
		2> >(tee "${stderr_file}" >&2)
	local rc=$?
	set -e

	if [[ "${rc}" -ne 0 ]]; then
		echo "Error: nwipe returned ${rc} for case '${case_name}'"
		echo "--- stdout ---"
		tail -n 40 "${stdout_file}" || true
		echo "--- stderr ---"
		tail -n 40 "${stderr_file}" || true
		return 1
	fi

	if ! grep -Fq "Nwipe successfully completed." "${log_file}"; then
		echo "Error: 'Nwipe successfully completed.' not found in ${log_file}"
		tail -n 40 "${log_file}" || true
		return 1
	fi

	echo "    nwipe completed successfully."
}

assert_mbr() {
	local case_name="$1"
	local device="$2"

	echo "==> verify_mbr: case=${case_name} device=${device}"

	declare -A disk_properties
	disk_properties[blocks_512]=$(blockdev --getsz "${device}")
	echo "    blocks_512: ${disk_properties[blocks_512]}"

	if verify_mbr "${device}"; then
		echo "    PASS: Unraid preclear signature valid."
	else
		echo "    FAIL: Unraid preclear invalid for case '${case_name}'"
		return 1
	fi
}

assert_large_head_size() {
	local expected_bytes=$(( 10 * 1024 * 1024 ))
	local actual_bytes
	local dm_sectors

	dm_sectors=$(blockdev --getsz "${LARGE_DM_DEV}")
	echo "==> Writing to end of large device to verify dm-zero discards"
	echo "    dm device blocks_512: ${dm_sectors}"

	dd if=/dev/urandom bs=512 count=1 \
		seek=$(( LARGE_TOTAL_SECTORS - 1 )) \
		of="${LARGE_DM_DEV}" 2>/dev/null

	actual_bytes=$(stat -c%s "${LARGE_IMG}")
	echo "    Expected backing file: ${expected_bytes} bytes"
	echo "    Actual backing file:   ${actual_bytes} bytes"

	if [[ "${actual_bytes}" -gt "${expected_bytes}" ]]; then
		echo "    FAIL: backing file grew beyond 10MB - dm-zero tail is not discarding writes"
		return 1
	fi
	echo "    PASS: Backing file size unchanged after tail write."
}

# ------------------------------------------------------------------------------
# DEVICES
# ------------------------------------------------------------------------------

echo "==> Creating SMALL device (10MB loopback, < 2TB)"
truncate -s 10M "${SMALL_IMG}"
SMALL_LOOP="$(losetup --find --show "${SMALL_IMG}")"
echo "    Loop device: ${SMALL_LOOP}"

echo "==> Creating LARGE fake device (3TB, first 10MB real + rest dm-zero)"
LARGE_TOTAL_SECTORS=$(( 3 * 1024 * 1024 * 1024 * 1024 / 512 ))
HEAD_SECTORS=$(( 10 * 1024 * 1024 / 512 ))
TAIL_SECTORS=$(( LARGE_TOTAL_SECTORS - HEAD_SECTORS ))

truncate -s 10M "${LARGE_IMG}"
LARGE_LOOP="$(losetup --find --show "${LARGE_IMG}")"

echo "    Head loop device: ${LARGE_LOOP}"
echo "    Total sectors: ${LARGE_TOTAL_SECTORS}"
echo "    Head sectors: ${HEAD_SECTORS}, Tail sectors (dm-zero): ${TAIL_SECTORS}"

# First 10MB - linear to real loop, remainder - zero (discards writes)
dmsetup create "${LARGE_DM_NAME}" <<EOF
0 ${HEAD_SECTORS} linear ${LARGE_LOOP} 0
${HEAD_SECTORS} ${TAIL_SECTORS} zero
EOF

echo "    DM device: ${LARGE_DM_DEV}"

# ------------------------------------------------------------------------------
# TESTS
# ------------------------------------------------------------------------------

echo ""
echo "========================================"
echo " TEST 1: SMALL device (< 2TB)"
echo "========================================"
run_nwipe  "small_wipe" "${SMALL_LOOP}"
assert_mbr "small_wipe" "${SMALL_LOOP}"

echo ""
echo "========================================"
echo " TEST 2: LARGE device (> 2TB)"
echo "========================================"
assert_large_head_size
run_nwipe  "large_wipe" "${LARGE_DM_DEV}"
assert_mbr "large_wipe" "${LARGE_DM_DEV}"

echo ""
echo "========================================"
echo " ALL TESTS PASSED"
echo "========================================"
