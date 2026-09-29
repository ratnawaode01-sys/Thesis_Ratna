#!/bin/bash
###############################################################################
# comparison_ratna.sh - Perbandingan FSRCNN: Naif (sebelum diubah) vs Usulan
#
# Program yang dibandingkan:
#   NAIVE : fsrcnn_naive_openmp_old.c  - naif sebelum diubah: layout feature map CHW,
#           paralel per kanal/filter, race condition pada layer 8 dekonvolusi
#   HWC   : fsrcnn_naive_openmp.c      - usulan: layout feature map HWC,
#           paralelisasi spasial (baris keluaran)
#
# Waktu yang dibandingkan adalah waktu inferensi FSRCNN() saja (INFERENCE_MS yang dicetak
# program), tidak termasuk start/tutup proses, baca bobot, dan buka/tutup/baca/tulis file.
# Waktu proses total tetap dicatat di raw_timings.csv (kolom process_wall_ms).
#
# Skenario percobaan (jumlah thread pada LITTLE core dan BIG core):
#   Satu jenis core : 1 LITTLE, 1 BIG, 5 LITTLE, 5 BIG, 10 LITTLE, 10 BIG
#   Gabungan        : 5 LITTLE + 5 BIG, 10 LITTLE + 10 BIG
# Skenario ditulis sebagai token "<n>L", "<n>B", atau "<n>L+<n>B".
#
# Pinning:
#   Proses di-pin dengan taskset ke himpunan core skenario, lalu tiap thread OpenMP
#   di-pin ke satu CPU tetap dengan GOMP_CPU_AFFINITY (thread dibagi bergiliran ke core
#   pada jenisnya). Jadi 2 thread memakai tepat 2 CPU, dan pada skenario gabungan tepat
#   <n> thread berjalan di LITTLE dan <n> thread di BIG.
#   Jika jumlah thread melebihi jumlah core pada jenis tersebut, terjadi oversubscription
#   (mis. 5 thread pada 4 core LITTLE).
#
# Usage:
#   bash comparison_ratna.sh              # build lalu jalankan benchmark penuh
#   bash comparison_ratna.sh --build-only # hanya build executable
#
# Env opsional (contoh: NUM_RUNS=3 SCENARIO_LIST="1L 1B 5L+5B" bash comparison_ratna.sh):
#   TOTAL_FRAMES=150              jumlah frame yang diproses
#   NUM_RUNS=5                    run per skenario (run 1 = cold-start, tidak dirata-rata)
#   SCENARIO_LIST="1L 1B 5L 5B 10L 10B 5L+5B 10L+10B"   skenario yang diuji
#   PROGRAM_LIST="NAIVE HWC"      program yang diuji
#   BIG_CPUS=4-7 LITTLE_CPUS=0-3  override deteksi otomatis big/little core
#   COOLDOWN=10                   jeda (detik) antar skenario
#   PERF=1                        rekam hardware counter dengan perf stat
#   PERF_EVENTS="..."             daftar event perf (default di bawah)
#   KEEP_OUTPUT=1                 simpan file YUV keluaran tiap skenario
#   NO_PAUSE=1                    jangan menunggu Enter sebelum jendela terminal ditutup
###############################################################################

set -e

BUILD_ONLY=0
if [ "${1:-}" = "--build-only" ] || [ "${1:-}" = "build-only" ]; then
    BUILD_ONLY=1
fi

# ===================== KONFIGURASI =====================
INPUT_FILE="suzie_qcif.yuv"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT_PATH="${SCRIPT_DIR}/${INPUT_FILE}"

# Resolusi QCIF
WIDTH=176
HEIGHT=144

# Upscale factor (2x)
OUT_WIDTH=$((WIDTH * 2))
OUT_HEIGHT=$((HEIGHT * 2))

TOTAL_FRAMES="${TOTAL_FRAMES:-150}"
NUM_RUNS="${NUM_RUNS:-5}"
COOLDOWN="${COOLDOWN:-10}"
KEEP_OUTPUT="${KEEP_OUTPUT:-0}"
PERF="${PERF:-0}"
PERF_EVENTS="${PERF_EVENTS:-task-clock,cycles,instructions,cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses,LLC-loads,LLC-load-misses}"

read -r -a SCENARIO_LIST <<< "${SCENARIO_LIST:-1L 1B 5L 5B 10L 10B 5L+5B 10L+10B}"
read -r -a PROGRAM_LIST <<< "${PROGRAM_LIST:-NAIVE HWC}"

EXPECTED_OUTPUT_SIZE=$((OUT_WIDTH * OUT_HEIGHT * 3 / 2 * TOTAL_FRAMES))

RESULT_DIR="${SCRIPT_DIR}/results_ratna/$(date +%Y%m%d_%H%M%S)"

# ===================== JENDELA TERMINAL TETAP TERBUKA =====================
# Jika script dijalankan dengan double-click, jendela terminal langsung tertutup saat
# script selesai/gagal. Tahan jendela sampai Enter ditekan (baik sukses maupun error).
# Set NO_PAUSE=1 untuk menonaktifkan (mis. saat dijalankan otomatis/lewat SSH).
pause_before_exit() {
    local code=$?
    if [ -t 0 ] && [ "${NO_PAUSE:-0}" != "1" ]; then
        echo ""
        if [ "$code" -ne 0 ]; then
            echo "Script berhenti dengan error (kode ${code}). Lihat pesan di atas atau log: ${LOG_FILE}"
        fi
        read -r -p "Tekan Enter untuk menutup jendela..." _
    fi
}
trap pause_before_exit EXIT

# Seluruh keluaran terminal juga disimpan ke file log, supaya tetap bisa dibaca
# walaupun jendela sudah ditutup.
mkdir -p "${SCRIPT_DIR}/results_ratna"
LOG_FILE="${SCRIPT_DIR}/results_ratna/comparison_ratna_last.log"
exec > >(tee "$LOG_FILE") 2>&1

if [ "$NUM_RUNS" -lt 2 ]; then
    echo "ERROR: NUM_RUNS minimal 2 (run 1 adalah cold-start dan tidak dirata-rata)."
    exit 1
fi

# ===================== KOMPILASI =====================
echo "============================================================================="
echo "                          KOMPILASI EXECUTABLE"
echo "============================================================================="
CC="gcc-15"
if ! command -v gcc-15 &> /dev/null; then
    CC="gcc"
fi
echo "Using compiler: $CC"
$CC -O3 -fopenmp -o "${SCRIPT_DIR}/fsrcnn_naive_openmp_old" "${SCRIPT_DIR}/fsrcnn_naive_openmp_old.c" -lm
$CC -O3 -fopenmp -o "${SCRIPT_DIR}/fsrcnn_naive_openmp" "${SCRIPT_DIR}/fsrcnn_naive_openmp.c" -lm
$CC -O3 -o "${SCRIPT_DIR}/fsrcnn_serial" "${SCRIPT_DIR}/fsrcnn_serial.c" -lm
echo "Kompilasi selesai."
echo ""

if [ "$BUILD_ONLY" -eq 1 ]; then
    echo "Mode --build-only: benchmark tidak dijalankan."
    exit 0
fi

# Setelah kompilasi, kegagalan satu run dicatat (kolom exit_ok) dan benchmark tetap lanjut
set +e

# ===================== VALIDASI =====================
if [ ! -f "$INPUT_PATH" ]; then
    echo "ERROR: Input file '${INPUT_FILE}' tidak ditemukan di ${SCRIPT_DIR}"
    exit 1
fi
if ! command -v taskset &> /dev/null; then
    echo "ERROR: taskset tidak ditemukan (paket util-linux). Dibutuhkan untuk pinning core."
    exit 1
fi
if [ "$PERF" = "1" ] && ! command -v perf &> /dev/null; then
    echo "ERROR: PERF=1 tetapi perf tidak ditemukan (paket linux-tools)."
    exit 1
fi

# Program dijalankan dari SCRIPT_DIR karena membaca weights_layer*.txt secara relatif
cd "$SCRIPT_DIR"
mkdir -p "$RESULT_DIR"

# ===================== FUNGSI UTILITAS =====================

get_time_ms() {
    echo $(($(date +%s%N) / 1000000))
}

get_file_size() {
    stat -c%s "$1" 2>/dev/null || echo "0"
}

# Ubah daftar CPU (mis. "0 1 2 3") menjadi format taskset "0,1,2,3"
join_cpus() {
    local IFS=,
    echo "$*"
}

# Uraikan format taskset menjadi daftar CPU satu per satu (mis. "0-2,6" -> "0 1 2 6")
expand_cpus() {
    local list="$1" part a b out=()
    IFS=, read -r -a parts <<< "$list"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            a="${part%-*}"; b="${part#*-}"
            out+=($(seq "$a" "$b"))
        else
            out+=("$part")
        fi
    done
    echo "${out[*]}"
}

# Hitung jumlah CPU dari format taskset (mis. "0-3,6" -> 5)
count_cpus() {
    local -a c
    read -r -a c <<< "$(expand_cpus "$1")"
    echo "${#c[@]}"
}

# Deteksi big/little core dari cpuinfo_max_freq (RK3588S: A55 = little, A76 = big)
detect_cores() {
    local big=() little=() all=() cpu freq max_f=0 min_f=0
    for cpu_dir in /sys/devices/system/cpu/cpu[0-9]*; do
        cpu="${cpu_dir##*cpu}"
        all+=("$cpu")
        freq=$(cat "${cpu_dir}/cpufreq/cpuinfo_max_freq" 2>/dev/null || echo 0)
        [ "$freq" -gt "$max_f" ] && max_f=$freq
        if [ "$min_f" -eq 0 ] || { [ "$freq" -gt 0 ] && [ "$freq" -lt "$min_f" ]; }; then
            min_f=$freq
        fi
    done
    if [ "${#all[@]}" -eq 0 ]; then
        mapfile -t all < <(seq 0 $(($(nproc) - 1)))
    fi
    mapfile -t all < <(printf '%s\n' "${all[@]}" | sort -n)

    if [ "$max_f" -gt 0 ] && [ "$max_f" -ne "$min_f" ]; then
        for cpu in "${all[@]}"; do
            freq=$(cat "/sys/devices/system/cpu/cpu${cpu}/cpufreq/cpuinfo_max_freq" 2>/dev/null || echo 0)
            if [ "$freq" -eq "$max_f" ]; then big+=("$cpu"); else little+=("$cpu"); fi
        done
    else
        # Bukan arsitektur asimetris (atau cpufreq tidak tersedia): bagi dua
        echo "[!] WARNING: big/little tidak terdeteksi dari cpufreq, core dibagi dua (setengah bawah = little)." >&2
        local half=$((${#all[@]} / 2))
        little=("${all[@]:0:$half}")
        big=("${all[@]:$half}")
    fi

    DETECTED_BIG=$(join_cpus "${big[@]}")
    DETECTED_LITTLE=$(join_cpus "${little[@]}")
}

detect_cores
BIG_CPUS="${BIG_CPUS:-$DETECTED_BIG}"
LITTLE_CPUS="${LITTLE_CPUS:-$DETECTED_LITTLE}"
N_LITTLE=$(count_cpus "$LITTLE_CPUS")
N_BIG=$(count_cpus "$BIG_CPUS")

# Uraikan token skenario ("5L", "10B", "5L+5B") menjadi SC_L (thread LITTLE) dan
# SC_B (thread BIG). Mengembalikan status 1 jika token tidak valid.
parse_scenario() {
    local tok="$1" part
    SC_L=0; SC_B=0
    IFS=+ read -r -a parts <<< "$tok"
    for part in "${parts[@]}"; do
        case "$part" in
            *[0-9]L) SC_L=$((SC_L + ${part%L})) ;;
            *[0-9]B) SC_B=$((SC_B + ${part%B})) ;;
            *)       return 1 ;;
        esac
    done
    [ $((SC_L + SC_B)) -gt 0 ]
}

scenario_label() {
    parse_scenario "$1" || { echo "$1"; return; }
    if [ "$SC_L" -gt 0 ] && [ "$SC_B" -gt 0 ]; then
        echo "${SC_L} LITTLE + ${SC_B} BIG"
    elif [ "$SC_L" -gt 0 ]; then
        echo "${SC_L} LITTLE"
    else
        echo "${SC_B} BIG"
    fi
}

# Mask taskset untuk skenario
scenario_cpus() {
    parse_scenario "$1" || { echo ""; return; }
    if [ "$SC_L" -gt 0 ] && [ "$SC_B" -gt 0 ]; then
        echo "${LITTLE_CPUS},${BIG_CPUS}"
    elif [ "$SC_L" -gt 0 ]; then
        echo "$LITTLE_CPUS"
    else
        echo "$BIG_CPUS"
    fi
}

# GOMP_CPU_AFFINITY: thread 0..L-1 bergiliran di core LITTLE, thread L..L+B-1 bergiliran
# di core BIG. Dipakai di semua skenario supaya tiap thread menempel di satu CPU tetap
# (tanpa ini, mis. 2 thread pada mask 4 CPU berpindah-pindah dan terlihat memakai 4 CPU).
scenario_affinity() {
    parse_scenario "$1" || { echo ""; return; }
    local -a lc bc out=()
    local i
    read -r -a lc <<< "$(expand_cpus "$LITTLE_CPUS")"
    read -r -a bc <<< "$(expand_cpus "$BIG_CPUS")"
    for ((i=0; i<SC_L; i++)); do out+=("${lc[$((i % ${#lc[@]}))]}"); done
    for ((i=0; i<SC_B; i++)); do out+=("${bc[$((i % ${#bc[@]}))]}"); done
    echo "${out[*]}"
}

program_label() {
    case "$1" in
        NAIVE) echo "Naif CHW (sebelum)" ;;
        HWC)   echo "Usulan HWC" ;;
        *)     echo "$1" ;;
    esac
}

# run_program <program> <threads> <cpus> <affinity> <output.yuv> <layer_csv> <perf_file> <stdout_file>
run_program() {
    local prog="$1" threads="$2" cpus="$3" affinity="$4" out="$5" layer_csv="$6" perf_file="$7" stdout_file="$8"
    local -a cmd

    case "$prog" in
        NAIVE) cmd=("${SCRIPT_DIR}/fsrcnn_naive_openmp_old" "$INPUT_PATH" "$out" "$TOTAL_FRAMES") ;;
        HWC)   cmd=("${SCRIPT_DIR}/fsrcnn_naive_openmp" "$INPUT_PATH" "$out" "$TOTAL_FRAMES" "$threads" "$layer_csv" "$WIDTH" "$HEIGHT") ;;
        *)     echo "Program tidak dikenal: $prog" >&2; return 1 ;;
    esac

    if [ "$PERF" = "1" ]; then
        cmd=(perf stat -x, -o "$perf_file" -e "$PERF_EVENTS" -- "${cmd[@]}")
    fi

    GOMP_CPU_AFFINITY="$affinity" OMP_NUM_THREADS="$threads" OMP_DYNAMIC=false \
        taskset -c "$cpus" "${cmd[@]}" > "$stdout_file" 2>&1
}

# Validasi token skenario lebih awal supaya salah ketik tidak baru ketahuan di tengah benchmark
for sc in "${SCENARIO_LIST[@]}"; do
    if ! parse_scenario "$sc"; then
        echo "ERROR: skenario '${sc}' tidak valid (format: <n>L, <n>B, atau <n>L+<n>B)."
        exit 1
    fi
done

# ===================== GROUND TRUTH =====================
# Ground truth dari fsrcnn_serial (single-thread, deterministik).
if [ "$TOTAL_FRAMES" -eq 150 ]; then
    GROUND_TRUTH="${SCRIPT_DIR}/output_serial_ground_truth.yuv"
else
    GROUND_TRUTH="${SCRIPT_DIR}/output_serial_ground_truth_${TOTAL_FRAMES}f.yuv"
fi

if [ "$(get_file_size "$GROUND_TRUTH")" -eq "$EXPECTED_OUTPUT_SIZE" ]; then
    echo ">> Ground truth sudah ada, pakai cache: ${GROUND_TRUTH}"
else
    echo ">> Membuat ground truth dari fsrcnn_serial (${TOTAL_FRAMES} frame)..."
    "${SCRIPT_DIR}/fsrcnn_serial" "$INPUT_PATH" "$GROUND_TRUTH" "$TOTAL_FRAMES" > /dev/null 2>&1
fi
echo ""

# ===================== INFORMASI SISTEM =====================
echo "============================================================================="
echo "                         KONFIGURASI PENGUJIAN"
echo "============================================================================="
echo "  LITTLE core   : ${LITTLE_CPUS} (${N_LITTLE} core)"
echo "  BIG core      : ${BIG_CPUS} (${N_BIG} core)"
echo "  Program       : ${PROGRAM_LIST[*]}"
echo "  Skenario      : ${SCENARIO_LIST[*]}"
echo "  Frame         : ${TOTAL_FRAMES}, run/skenario: ${NUM_RUNS} (run 1 = cold-start)"
echo "  perf          : $([ "$PERF" = "1" ] && echo "ON (${PERF_EVENTS})" || echo "OFF")"
echo "  Folder hasil  : ${RESULT_DIR}"
{
    echo "date=$(date -Iseconds)"
    echo "host=$(uname -a)"
    echo "compiler=$($CC --version | head -1)"
    echo "little_cpus=${LITTLE_CPUS}"
    echo "big_cpus=${BIG_CPUS}"
    echo "programs=${PROGRAM_LIST[*]}"
    echo "scenarios=${SCENARIO_LIST[*]}"
    echo "frames=${TOTAL_FRAMES}"
    echo "runs=${NUM_RUNS}"
    echo "perf=${PERF} events=${PERF_EVENTS}"
} > "${RESULT_DIR}/config.txt"
echo ""

# ===================== EKSEKUSI SKENARIO =====================
echo "============================================================================="
echo "                         MENJALANKAN BENCHMARK"
echo "============================================================================="
echo ""

RAW_CSV="${RESULT_DIR}/raw_timings.csv"
LAYER_CSV="${RESULT_DIR}/layer_timings.csv"
PERF_CSV="${RESULT_DIR}/perf_counters.csv"
SUMMARY_CSV="${RESULT_DIR}/summary.csv"
echo "scenario,program,skenario,little_threads,big_threads,cpus,threads,run,inference_ms,process_wall_ms,excluded_from_avg,exit_ok" > "$RAW_CSV"
echo "scenario,program,skenario,cpus,run,layout,threads,frames,width,height,layer,name,time_ms_per_frame,time_pct,gflops,ai_flop_per_byte,bw_min_gbs" > "$LAYER_CSV"
[ "$PERF" = "1" ] && echo "scenario,program,skenario,threads,run,event,value,unit" > "$PERF_CSV"

declare -a SCEN_KEYS=()
declare -A T_AVG T_MIN T_MAX T_STD T_COLD T_CONS

total_scen=$(( ${#PROGRAM_LIST[@]} * ${#SCENARIO_LIST[@]} ))
scen_no=0

for sc in "${SCENARIO_LIST[@]}"; do
    parse_scenario "$sc"
    n_l=$SC_L
    n_b=$SC_B
    threads=$((n_l + n_b))
    cpus=$(scenario_cpus "$sc")
    affinity=$(scenario_affinity "$sc")
    sc_id="${sc//+/_}"

    for prog in "${PROGRAM_LIST[@]}"; do
        scen_no=$((scen_no + 1))
        key="${prog}|${sc}"
        scen="${prog}_${sc_id}"
        SCEN_KEYS+=("$key")
        output_file="${RESULT_DIR}/output_${scen}.yuv"

        echo "---------------------------------------------------------------------"
        echo "[${scen_no}/${total_scen}] $(program_label "$prog") | $(scenario_label "$sc") (cpu ${cpus}) | ${threads} thread"
        echo "     GOMP_CPU_AFFINITY: ${affinity}"
        if [ "$n_l" -gt "$N_LITTLE" ]; then
            echo "     Catatan: oversubscription LITTLE (${n_l} thread pada ${N_LITTLE} core)"
        fi
        if [ "$n_b" -gt "$N_BIG" ]; then
            echo "     Catatan: oversubscription BIG (${n_b} thread pada ${N_BIG} core)"
        fi
        echo "---------------------------------------------------------------------"

        total_time=0
        min_time=999999999
        max_time=0
        first_run_time=0
        steady_runs=()

        for ((run=1; run<=NUM_RUNS; run++)); do
            rm -f "$output_file"
            layer_tmp="${RESULT_DIR}/.layer_tmp.csv"
            perf_tmp="${RESULT_DIR}/.perf_tmp.txt"
            stdout_tmp="${RESULT_DIR}/.stdout_tmp.txt"
            rm -f "$layer_tmp" "$perf_tmp" "$stdout_tmp"

            start_time=$(get_time_ms)
            exit_ok=1
            run_program "$prog" "$threads" "$cpus" "$affinity" "$output_file" "$layer_tmp" "$perf_tmp" "$stdout_tmp" || exit_ok=0
            end_time=$(get_time_ms)
            wall_ms=$((end_time - start_time))

            # Waktu utama = waktu inferensi FSRCNN() yang dicetak program (INFERENCE_MS),
            # tanpa start/tutup proses, baca bobot, dan buka/tutup/baca/tulis file YUV.
            elapsed=$(awk -F= '/^INFERENCE_MS=/ {printf "%d", $2 + 0.5; found=1} END {if (!found) print -1}' "$stdout_tmp" 2>/dev/null)
            if [ -z "$elapsed" ] || [ "$elapsed" -lt 0 ]; then
                echo "     [ERROR] INFERENCE_MS tidak ditemukan di keluaran program, memakai waktu proses total." >&2
                elapsed=$wall_ms
                exit_ok=0
            fi

            if [ "$exit_ok" -eq 0 ]; then
                echo "     [ERROR] Program keluar dengan error pada run ${run}." >&2
            fi

            # Data per lapisan (hanya program usulan yang menulisnya)
            if [ -f "$layer_tmp" ]; then
                awk -F, -v p="${scen},${prog},${sc},\"${cpus}\",${run}" 'NR > 1 {print p "," $0}' "$layer_tmp" >> "$LAYER_CSV"
            fi

            # Hardware counter perf (format -x,: value,unit,event,...)
            if [ "$PERF" = "1" ] && [ -f "$perf_tmp" ]; then
                awk -F, -v p="${scen},${prog},${sc},${threads},${run}" \
                    '!/^#/ && NF >= 3 && $3 != "" {print p "," $3 "," $1 "," $2}' "$perf_tmp" >> "$PERF_CSV"
            fi

            raw_prefix="${scen},${prog},${sc},${n_l},${n_b},\"${cpus}\",${threads},${run},${elapsed},${wall_ms}"
            if [ "$run" -eq 1 ]; then
                first_run_time=$elapsed
                echo "${raw_prefix},yes,${exit_ok}" >> "$RAW_CSV"
                printf "     Run %d/%d (Cold-Start, DIKECUALIKAN dari rata-rata): inferensi %d ms (proses total %d ms)\n" "$run" "$NUM_RUNS" "$elapsed" "$wall_ms"
            else
                total_time=$((total_time + elapsed))
                steady_runs+=("$elapsed")
                [ "$elapsed" -lt "$min_time" ] && min_time=$elapsed
                [ "$elapsed" -gt "$max_time" ] && max_time=$elapsed
                echo "${raw_prefix},no,${exit_ok}" >> "$RAW_CSV"
                printf "     Run %d/%d (Steady-State): inferensi %d ms (proses total %d ms)\n" "$run" "$NUM_RUNS" "$elapsed" "$wall_ms"
            fi
        done
        rm -f "${RESULT_DIR}/.layer_tmp.csv" "${RESULT_DIR}/.perf_tmp.txt" "${RESULT_DIR}/.stdout_tmp.txt"

        steady_count=$((NUM_RUNS - 1))
        avg_time=$((total_time / steady_count))
        T_AVG[$key]=$avg_time
        T_MIN[$key]=$min_time
        T_MAX[$key]=$max_time
        T_COLD[$key]=$first_run_time
        T_STD[$key]=$(printf '%s\n' "${steady_runs[@]}" | awk -v avg="$avg_time" '{s+=($1-avg)^2; n++} END {if(n>0) printf "%.1f", sqrt(s/n); else print "0.0"}')

        # Cek konsistensi output run terakhir terhadap ground truth
        if [ -f "$output_file" ] && [ -f "$GROUND_TRUTH" ]; then
            if cmp -s "$GROUND_TRUTH" "$output_file"; then
                T_CONS[$key]="IDENTIK"
            else
                diff_bytes=$(cmp -l "$GROUND_TRUTH" "$output_file" 2>/dev/null | wc -l | tr -d ' ')
                T_CONS[$key]="BERBEDA(${diff_bytes}B)"
            fi
        else
            T_CONS[$key]="TIDAK_ADA"
        fi
        [ "$KEEP_OUTPUT" = "1" ] || rm -f "$output_file"

        echo ""
        printf "     Rata-rata (steady-state, n=%d): %d ms (StdDev: %s ms) | Output: %s\n" \
            "$steady_count" "$avg_time" "${T_STD[$key]}" "${T_CONS[$key]}"
        echo ""

        if [ "$scen_no" -lt "$total_scen" ] && [ "$COOLDOWN" -gt 0 ]; then
            echo "     [...] Cooldown ${COOLDOWN} detik..."
            sleep "$COOLDOWN"
        fi
    done
done

# ===================== TABEL RINGKASAN =====================
fps_of() {
    awk -v f="$TOTAL_FRAMES" -v t="$1" 'BEGIN { if (t > 0) printf "%.2f", f * 1000 / t; else print "N/A" }'
}

ratio_of() {
    awk -v a="$1" -v b="$2" 'BEGIN { if (a > 0 && b > 0) printf "%.2f", a / b; else print "N/A" }'
}

echo "============================================================================="
echo "        RINGKASAN HASIL (waktu inferensi FSRCNN, ms; tanpa buka/tutup program)"
echo "============================================================================="
echo ""
echo "scenario_key,program,skenario,little_threads,big_threads,threads,avg_ms,min_ms,max_ms,stddev_ms,cold_start_ms,fps,output_check" > "$SUMMARY_CSV"

printf "%-20s | %-18s | %3s | %9s | %9s | %9s | %8s | %8s | %s\n" \
    "Program" "Skenario" "Thr" "Inf Avg" "Inf Min" "Inf Max" "StdDev" "FPS" "Output"
printf -- "%.0s-" {1..118}; echo ""
for key in "${SCEN_KEYS[@]}"; do
    IFS='|' read -r prog sc <<< "$key"
    parse_scenario "$sc"
    threads=$((SC_L + SC_B))
    fps=$(fps_of "${T_AVG[$key]}")
    printf "%-20s | %-18s | %3s | %9d | %9d | %9d | %8s | %8s | %s\n" \
        "$(program_label "$prog")" "$(scenario_label "$sc")" "$threads" \
        "${T_AVG[$key]}" "${T_MIN[$key]}" "${T_MAX[$key]}" "${T_STD[$key]}" "$fps" "${T_CONS[$key]}"
    echo "${prog}_${sc//+/_},${prog},${sc},${SC_L},${SC_B},${threads},${T_AVG[$key]},${T_MIN[$key]},${T_MAX[$key]},${T_STD[$key]},${T_COLD[$key]},${fps},${T_CONS[$key]}" >> "$SUMMARY_CSV"
done
echo ""

# ===================== SPEEDUP USULAN vs NAIF =====================
has_prog() {
    local p
    for p in "${PROGRAM_LIST[@]}"; do [ "$p" = "$1" ] && return 0; done
    return 1
}

if has_prog NAIVE && has_prog HWC; then
    echo "============================================================================="
    echo "  SPEEDUP USULAN HWC vs NAIF CHW (skenario sama; >1 = usulan lebih cepat)"
    echo "============================================================================="
    printf "%-18s | %14s | %15s | %s\n" "Skenario" "Naif CHW (ms)" "Usulan HWC (ms)" "Speedup"
    printf -- "%.0s-" {1..66}; echo ""
    for sc in "${SCENARIO_LIST[@]}"; do
        n="${T_AVG[NAIVE|$sc]:-0}"
        h="${T_AVG[HWC|$sc]:-0}"
        printf "%-18s | %14s | %15s | %sx\n" "$(scenario_label "$sc")" "$n" "$h" "$(ratio_of "$n" "$h")"
    done
    echo ""
fi

# ===================== SKALABILITAS =====================
# Speedup tiap skenario terhadap 1 thread LITTLE (1L) dan 1 thread BIG (1B) pada program sama.
echo "============================================================================="
echo "  SKALABILITAS (speedup terhadap 1 LITTLE dan 1 BIG pada program yang sama)"
echo "============================================================================="
printf "%-20s | %-18s | %9s | %10s | %10s\n" "Program" "Skenario" "Avg (ms)" "vs 1 LIT" "vs 1 BIG"
printf -- "%.0s-" {1..80}; echo ""
for prog in "${PROGRAM_LIST[@]}"; do
    base_l="${T_AVG[$prog|1L]:-0}"
    base_b="${T_AVG[$prog|1B]:-0}"
    for sc in "${SCENARIO_LIST[@]}"; do
        t="${T_AVG[$prog|$sc]:-0}"
        printf "%-20s | %-18s | %9s | %9sx | %9sx\n" "$(program_label "$prog")" "$(scenario_label "$sc")" \
            "$t" "$(ratio_of "$base_l" "$t")" "$(ratio_of "$base_b" "$t")"
    done
done
echo "(N/A: skenario 1L / 1B tidak ada di SCENARIO_LIST)"
echo ""

# ===================== GRAFIK (GNUPLOT) =====================
echo "============================================================================="
echo "                  MENULIS DATA & MEMBUAT GRAFIK (GNUPLOT)"
echo "============================================================================="
dat="${RESULT_DIR}/fps_scenarios.dat"
{
    printf "# skenario"
    for prog in "${PROGRAM_LIST[@]}"; do printf " %s" "$prog"; done
    echo ""
    for sc in "${SCENARIO_LIST[@]}"; do
        printf "\"%s\"" "$(scenario_label "$sc")"
        for prog in "${PROGRAM_LIST[@]}"; do
            v=$(fps_of "${T_AVG[$prog|$sc]:-0}")
            [ "$v" = "N/A" ] && v="NaN"
            printf " %s" "$v"
        done
        echo ""
    done
} > "$dat"

if command -v gnuplot &> /dev/null; then
    plot_cmd=""
    col=2
    for prog in "${PROGRAM_LIST[@]}"; do
        if [ -z "$plot_cmd" ]; then
            plot_cmd="'${dat}' using ${col}:xtic(1) title '$(program_label "$prog")'"
        else
            plot_cmd="${plot_cmd}, '' using ${col} title '$(program_label "$prog")'"
        fi
        col=$((col + 1))
    done
    gnuplot <<EOF
set terminal pngcairo size 1000,600 enhanced font 'Helvetica,11'
set output '${RESULT_DIR}/fps_scenarios.png'
set title "FSRCNN Throughput per Skenario\n(Lebih tinggi lebih baik)" font 'Helvetica-Bold,14'
set xlabel "Skenario (jumlah thread per jenis core)" font 'Helvetica-Bold,12'
set ylabel "Throughput (FPS)" font 'Helvetica-Bold,12'
set grid ytics lc rgb "#dddddd"
set style data histogram
set style histogram clustered gap 1
set style fill solid 0.8 border -1
set boxwidth 0.9
set xtics rotate by -30
set yrange [0:*]
set key top left
plot ${plot_cmd}
EOF
    echo "  [✓] Grafik: ${RESULT_DIR}/fps_scenarios.png"
else
    echo "  [!] gnuplot tidak ditemukan, grafik dilewati (data .dat tetap ditulis)."
fi
echo ""

echo "  Ringkasan            : ${SUMMARY_CSV}"
echo "  Timing mentah        : ${RAW_CSV}"
echo "  Waktu per lapisan    : ${LAYER_CSV} (hanya program usulan)"
[ "$PERF" = "1" ] && echo "  Hardware counter     : ${PERF_CSV}"
echo ""
echo "============================================================================="
echo "                       BENCHMARK SELESAI"
echo "============================================================================="
