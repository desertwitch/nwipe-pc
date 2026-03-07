#!/usr/bin/env bash
set -eo pipefail

NWIPE_BIN="${1:-./src/nwipe}"
ARTIFACT_DIR="${NWIPE_CI_ARTIFACT_DIR:-}"

if [[ "$(id -u)" -ne 0 ]]; then
	echo "[ERROR] Must run as root (loop devices + dmsetup)."
	exit 1
fi

if [[ ! -x "${NWIPE_BIN}" ]]; then
	echo "[ERROR] nwipe binary not executable: ${NWIPE_BIN}"
	exit 2
fi

for cmd in losetup truncate dmsetup dd blockdev hexdump awk grep mktemp tee tail; do
	if ! command -v "${cmd}" >/dev/null 2>&1; then
		echo "[ERROR] Required command not found: ${cmd}"
		exit 1
	fi
done

WORKDIR="$(mktemp -d /tmp/unraid-preclear-ci.XXXXXX)"
LOG_DIR="${WORKDIR}/logs"
mkdir -p "${LOG_DIR}"

SMALL_IMG="${WORKDIR}/small.img"
LARGE_IMG="${WORKDIR}/large.img"
SMALL_LOOP=""
LARGE_LOOP=""

SMALL_DM_NAME="unraid_ci_small_$$"
SMALL_DM_DEV="/dev/mapper/${SMALL_DM_NAME}"

LARGE_DM_NAME="unraid_ci_large_$$"
LARGE_DM_DEV="/dev/mapper/${LARGE_DM_NAME}"

# ------------------------------------------------------------------------------
# HELPERS
# ------------------------------------------------------------------------------

cleanup() {
	echo "==> [CLEANUP] Removing devices and temporary files..."
	if dmsetup info "${SMALL_DM_NAME}" >/dev/null 2>&1; then
		dmsetup remove "${SMALL_DM_NAME}" >/dev/null 2>&1 || true
	fi

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
		echo "    [INFO] MBR layout: large (>= 2TB)"
	else
		patterns+=("00000" "00000" "00000" "00000" "00000" "00000" "00000" "00000")
		partition_size=$disk_blocks
		echo "    [INFO] MBR layout: small (< 2TB)"
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
			echo "    [FAIL] MBR signature byte ${i}: got [${sectors[$i]}], expected [${patterns[$i]}]"
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
				echo "    [FAIL] GPT start sector [${start_sector}] invalid; expected [1] for large disk"
				return 1
			fi
			;;
		*)
			echo "    [FAIL] Start sector [${start_sector}] not accepted by Unraid (expected 1, 63, or 64)"
			return 1
			;;
	esac

	if [ $partition_size -ne $mbr_blocks ]; then
		echo "    [FAIL] Partition size mismatch: physical [${partition_size}] != MBR declared [${mbr_blocks}]"
		return 1
	fi

	return 0
}

run_nwipe() {
	local case_name="$1"
	local io="$2"
	local device="$3"

	local log_file="${LOG_DIR}/${case_name}.log"
	local stdout_file="${LOG_DIR}/${case_name}.stdout"
	local stderr_file="${LOG_DIR}/${case_name}.stderr"

	echo "==> [NWIPE] case=${case_name} device=${device} io=${io}"

	set +e
	"${NWIPE_BIN}" \
		--autonuke \
		--nogui \
		--nowait \
		--nosignals \
		--noblank \
		--rounds=1 \
		--${io} \
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
		echo "    [FAIL] nwipe exited with code ${rc}"
		echo "    [INFO] Last 40 lines of stdout:"
		tail -n 40 "${stdout_file}" || true
		echo "    [INFO] Last 40 lines of stderr:"
		tail -n 40 "${stderr_file}" || true
		return 1
	fi

	if ! grep -Fq "Nwipe successfully completed." "${log_file}"; then
		echo "    [FAIL] 'Nwipe successfully completed.' not found in ${log_file}"
		echo "    [INFO] Last 40 lines of log:"
		tail -n 40 "${log_file}" || true
		return 1
	fi

	echo "    [PASS] nwipe completed successfully"
}

assert_mbr() {
	local case_name="$1"
	local device="$2"

	echo "==> [ASSERT_MBR] case=${case_name} device=${device}"

	declare -A disk_properties
	disk_properties[blocks_512]=$(blockdev --getsz "${device}")
	echo "    [INFO] blocks_512=${disk_properties[blocks_512]}"

	if verify_mbr "${device}"; then
		echo "    [PASS] Unraid preclear signature valid"
	else
		echo "    [FAIL] Unraid preclear signature invalid"
		return 1
	fi
}

assert_head_size() {
	local case_name="$1"
	local dm_dev="$2"
	local total_sectors="$3"
	local backing_img="$4"

	local expected_bytes=$(( 10 * 1024 * 1024 ))
	local actual_bytes
	local dm_sectors

	dm_sectors=$(blockdev --getsz "${dm_dev}")

	echo "==> [ASSERT_HEAD_SIZE] case=${case_name} device=${dm_dev}"
	echo "    [INFO] dm_sectors=${dm_sectors}"

	dd if=/dev/urandom bs=512 count=1 \
		seek=$(( total_sectors - 1 )) \
		of="${dm_dev}" 2>/dev/null

	actual_bytes=$(stat -c%s "${backing_img}")
	echo "    [INFO] Expected backing file size: ${expected_bytes} bytes"
	echo "    [INFO] Actual backing file size:   ${actual_bytes} bytes"

	if [[ "${actual_bytes}" -gt "${expected_bytes}" ]]; then
		echo "    [FAIL] Backing file grew beyond 10MB; dm-zero tail is not discarding writes"
		return 1
	fi
	echo "    [PASS] Backing file size unchanged after tail write"
}

assert_image_equal() {
	local case_name="${1:-image_compare}"
	local expected="$2"
	local actual="$3"

	local size
	size=$(stat -c%s "${expected}")

	echo "==> [ASSERT_IMAGE_EQUAL] case=${case_name} size=${size}"

	if cmp -s -n "${size}" "${expected}" "${actual}"; then
		echo "    [PASS] First ${size} bytes match reference image"
	else
		echo "    [FAIL] Mismatch in first ${size} bytes against reference image"
		diff <(hexdump -C "${expected}") <(dd if="${actual}" bs=1 count="${size}" 2>/dev/null | hexdump -C) | head -60
		return 1
	fi
}

# ------------------------------------------------------------------------------
# DEVICES
# ------------------------------------------------------------------------------

HEAD_SECTORS=$(( 10 * 1024 * 1024 / 512 ))

echo "==> [SETUP] Creating SMALL fake device (500GB, first 10MB real + rest dm-zero)"
SMALL_TOTAL_SECTORS=976773168
SMALL_TAIL_SECTORS=$(( SMALL_TOTAL_SECTORS - HEAD_SECTORS ))

truncate -s 10M "${SMALL_IMG}"
SMALL_LOOP="$(losetup --find --show "${SMALL_IMG}")"

dmsetup create "${SMALL_DM_NAME}" <<EOF
0 ${HEAD_SECTORS} linear ${SMALL_LOOP} 0
${HEAD_SECTORS} ${SMALL_TAIL_SECTORS} zero
EOF

echo "    [INFO] dm_device=${SMALL_DM_DEV}"
echo "    [INFO] total_sectors=${SMALL_TOTAL_SECTORS}"

echo "==> [SETUP] Creating LARGE fake device (3TB, first 10MB real + rest dm-zero)"
LARGE_TOTAL_SECTORS=$(( 3 * 1024 * 1024 * 1024 * 1024 / 512 ))
LARGE_TAIL_SECTORS=$(( LARGE_TOTAL_SECTORS - HEAD_SECTORS ))

truncate -s 10M "${LARGE_IMG}"
LARGE_LOOP="$(losetup --find --show "${LARGE_IMG}")"

dmsetup create "${LARGE_DM_NAME}" <<EOF
0 ${HEAD_SECTORS} linear ${LARGE_LOOP} 0
${HEAD_SECTORS} ${LARGE_TAIL_SECTORS} zero
EOF

echo "    [INFO] dm_device=${LARGE_DM_DEV}"
echo "    [INFO] total_sectors=${LARGE_TOTAL_SECTORS}"

# ------------------------------------------------------------------------------
# TESTS
# ------------------------------------------------------------------------------

echo ""
echo "========================================"
echo " TEST 1: SMALL device (< 2TB)"
echo "========================================"
assert_head_size   "small" "${SMALL_DM_DEV}" "${SMALL_TOTAL_SECTORS}" "${SMALL_IMG}"

run_nwipe          "small_wipe_direct" "directio" "${SMALL_DM_DEV}"
assert_mbr         "small_wipe_direct" "${SMALL_DM_DEV}"
assert_image_equal "small_wipe_direct" "tests/ci/unraid_ref_small.img" "${SMALL_IMG}"

# Do not test in cached I/O as it takes extremely long.

echo ""
echo "========================================"
echo " TEST 2: LARGE device (> 2TB)"
echo "========================================"
assert_head_size   "large" "${LARGE_DM_DEV}" "${LARGE_TOTAL_SECTORS}" "${LARGE_IMG}"

run_nwipe          "large_wipe_direct" "directio" "${LARGE_DM_DEV}"
assert_mbr         "large_wipe_direct" "${LARGE_DM_DEV}"

# Do not test in cached I/O as it takes extremely long.

echo ""
echo "========================================"
echo " ALL TESTS PASSED"
echo "========================================"
