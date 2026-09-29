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
# Setiap program dijalankan dengan kombinasi:
#   Jumlah thread : 1, 2, 4, 8
#   Himpunan core : LITTLE saja, BIG saja, BIG+LITTLE (gabungan)
# Core di-pin dengan taskset; thread OpenMP mewarisi mask CPU tersebut.
# Pada himpunan 4 core, 8 thread berarti oversubscription (2 thread/core).
#
# Usage:
#   bash comparison_ratna.sh              # build lalu jalankan benchmark penuh
#   bash comparison_ratna.sh --build-only # hanya build executable
#
# Env opsional (contoh: NUM_RUNS=3 THREAD_LIST="1 4" bash comparison_ratna.sh):
#   TOTAL_FRAMES=150              jumlah frame yang diproses
#   NUM_RUNS=5                    run per skenario (run 1 = cold-start, tidak dirata-rata)
#   THREAD_LIST="1 2 4 8"         jumlah thread yang diuji
#   CORESET_LIST="little big all" himpunan core yang diuji
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

read -r -a THREAD_LIST <<< "${THREAD_LIST:-1 2 4 8}"
read -r -a CORESET_LIST <<< "${CORESET_LIST:-little big all}"
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

# Hitung jumlah CPU dari format taskset (mis. "0-3,6" -> 5)
count_cpus() {
    local list="$1" n=0 part a b
    IFS=, read -r -a parts <<< "$list"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            a="${part%-*}"; b="${part#*-}"
            n=$((n + b - a + 1))
        else
            n=$((n + 1))
        fi
    done
    echo "$n"
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
    DETECTED_ALL=$(join_cpus "${all[@]}")
}

detect_cores
BIG_CPUS="${BIG_CPUS:-$DETECTED_BIG}"
LITTLE_CPUS="${LITTLE_CPUS:-$DETECTED_LITTLE}"
ALL_CPUS="${ALL_CPUS:-$DETECTED_ALL}"

coreset_cpus() {
    case "$1" in
        little) echo "$LITTLE_CPUS" ;;
        big)    echo "$BIG_CPUS" ;;
        all)    echo "$ALL_CPUS" ;;
        *)      echo "" ;;
    esac
}

coreset_label() {
    case "$1" in
        little) echo "LITTLE" ;;
        big)    echo "BIG" ;;
        all)    echo "BIG+LITTLE" ;;
        *)      echo "$1" ;;
    esac
}

program_label() {
    case "$1" in
        NAIVE) echo "Naif CHW (sebelum)" ;;
        HWC)   echo "Usulan HWC" ;;
        *)     echo "$1" ;;
    esac
}

# run_program <program> <threads> <cpus> <output.yuv> <layer_csv> <perf_file> <stdout_file>
run_program() {
    local prog="$1" threads="$2" cpus="$3" out="$4" layer_csv="$5" perf_file="$6" stdout_file="$7"
    local -a cmd

    case "$prog" in
        NAIVE) cmd=("${SCRIPT_DIR}/fsrcnn_naive_openmp_old" "$INPUT_PATH" "$out" "$TOTAL_FRAMES") ;;
        HWC)   cmd=("${SCRIPT_DIR}/fsrcnn_naive_openmp" "$INPUT_PATH" "$out" "$TOTAL_FRAMES" "$threads" "$layer_csv" "$WIDTH" "$HEIGHT") ;;
        *)     echo "Program tidak dikenal: $prog" >&2; return 1 ;;
    esac

    if [ "$PERF" = "1" ]; then
        cmd=(perf stat -x, -o "$perf_file" -e "$PERF_EVENTS" -- "${cmd[@]}")
    fi

    OMP_NUM_THREADS="$threads" OMP_DYNAMIC=false taskset -c "$cpus" "${cmd[@]}" > "$stdout_file" 2>&1
}

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
echo "  LITTLE core   : ${LITTLE_CPUS}"
echo "  BIG core      : ${BIG_CPUS}"
echo "  BIG+LITTLE    : ${ALL_CPUS}"
echo "  Program       : ${PROGRAM_LIST[*]}"
echo "  Thread        : ${THREAD_LIST[*]}"
echo "  Himpunan core : ${CORESET_LIST[*]}"
echo "  Frame         : ${TOTAL_FRAMES}, run/skenario: ${NUM_RUNS} (run 1 = cold-start)"
echo "  perf          : $([ "$PERF" = "1" ] && echo "ON (${PERF_EVENTS})" || echo "OFF")"
echo "  Folder hasil  : ${RESULT_DIR}"
{
    echo "date=$(date -Iseconds)"
    echo "host=$(uname -a)"
    echo "compiler=$($CC --version | head -1)"
    echo "little_cpus=${LITTLE_CPUS}"
    echo "big_cpus=${BIG_CPUS}"
    echo "all_cpus=${ALL_CPUS}"
    echo "programs=${PROGRAM_LIST[*]}"
    echo "threads=${THREAD_LIST[*]}"
    echo "coresets=${CORESET_LIST[*]}"
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
echo "scenario,program,coreset,cpus,threads,run,inference_ms,process_wall_ms,excluded_from_avg,exit_ok" > "$RAW_CSV"
echo "scenario,program,coreset,cpus,run,layout,threads,frames,width,height,layer,name,time_ms_per_frame,time_pct,gflops,ai_flop_per_byte,bw_min_gbs" > "$LAYER_CSV"
[ "$PERF" = "1" ] && echo "scenario,program,coreset,threads,run,event,value,unit" > "$PERF_CSV"

declare -a SCEN_KEYS=()
declare -A T_AVG T_MIN T_MAX T_STD T_COLD T_CONS

total_scen=$(( ${#PROGRAM_LIST[@]} * ${#CORESET_LIST[@]} * ${#THREAD_LIST[@]} ))
scen_no=0

for coreset in "${CORESET_LIST[@]}"; do
    cpus=$(coreset_cpus "$coreset")
    if [ -z "$cpus" ]; then
        echo "[!] Himpunan core '${coreset}' kosong/tidak dikenal, dilewati."
        continue
    fi
    n_cpus=$(count_cpus "$cpus")

    for threads in "${THREAD_LIST[@]}"; do
        for prog in "${PROGRAM_LIST[@]}"; do
            scen_no=$((scen_no + 1))
            key="${prog}|${coreset}|${threads}"
            scen="${prog}_$(coreset_label "$coreset" | tr '+' '_')_${threads}T"
            SCEN_KEYS+=("$key")
            output_file="${RESULT_DIR}/output_${scen}.yuv"

            echo "---------------------------------------------------------------------"
            echo "[${scen_no}/${total_scen}] $(program_label "$prog") | $(coreset_label "$coreset") (cpu ${cpus}) | ${threads} thread"
            if [ "$threads" -gt "$n_cpus" ]; then
                echo "     Catatan: oversubscription (${threads} thread pada ${n_cpus} core)"
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
                run_program "$prog" "$threads" "$cpus" "$output_file" "$layer_tmp" "$perf_tmp" "$stdout_tmp" || exit_ok=0
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
                    awk -F, -v p="${scen},${prog},${coreset},\"${cpus}\",${run}" 'NR > 1 {print p "," $0}' "$layer_tmp" >> "$LAYER_CSV"
                fi

                # Hardware counter perf (format -x,: value,unit,event,...)
                if [ "$PERF" = "1" ] && [ -f "$perf_tmp" ]; then
                    awk -F, -v p="${scen},${prog},${coreset},${threads},${run}" \
                        '!/^#/ && NF >= 3 && $3 != "" {print p "," $3 "," $1 "," $2}' "$perf_tmp" >> "$PERF_CSV"
                fi

                if [ "$run" -eq 1 ]; then
                    first_run_time=$elapsed
                    echo "${scen},${prog},${coreset},\"${cpus}\",${threads},${run},${elapsed},${wall_ms},yes,${exit_ok}" >> "$RAW_CSV"
                    printf "     Run %d/%d (Cold-Start, DIKECUALIKAN dari rata-rata): inferensi %d ms (proses total %d ms)\n" "$run" "$NUM_RUNS" "$elapsed" "$wall_ms"
                else
                    total_time=$((total_time + elapsed))
                    steady_runs+=("$elapsed")
                    [ "$elapsed" -lt "$min_time" ] && min_time=$elapsed
                    [ "$elapsed" -gt "$max_time" ] && max_time=$elapsed
                    echo "${scen},${prog},${coreset},\"${cpus}\",${threads},${run},${elapsed},${wall_ms},no,${exit_ok}" >> "$RAW_CSV"
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
echo "scenario_key,program,coreset,threads,avg_ms,min_ms,max_ms,stddev_ms,cold_start_ms,fps,output_check" > "$SUMMARY_CSV"

printf "%-22s | %-10s | %3s | %9s | %9s | %9s | %8s | %8s | %s\n" \
    "Program" "Core" "Thr" "Inf Avg" "Inf Min" "Inf Max" "StdDev" "FPS" "Output"
printf -- "%.0s-" {1..110}; echo ""
for key in "${SCEN_KEYS[@]}"; do
    IFS='|' read -r prog coreset threads <<< "$key"
    fps=$(fps_of "${T_AVG[$key]}")
    printf "%-22s | %-10s | %3s | %9d | %9d | %9d | %8s | %8s | %s\n" \
        "$(program_label "$prog")" "$(coreset_label "$coreset")" "$threads" \
        "${T_AVG[$key]}" "${T_MIN[$key]}" "${T_MAX[$key]}" "${T_STD[$key]}" "$fps" "${T_CONS[$key]}"
    echo "${prog}_${coreset}_${threads},${prog},${coreset},${threads},${T_AVG[$key]},${T_MIN[$key]},${T_MAX[$key]},${T_STD[$key]},${T_COLD[$key]},${fps},${T_CONS[$key]}" >> "$SUMMARY_CSV"
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
    echo "  SPEEDUP USULAN HWC vs NAIF CHW (thread & himpunan core sama; >1 = usulan lebih cepat)"
    echo "============================================================================="
    printf "%-10s | %3s | %14s | %14s | %s\n" "Core" "Thr" "Naif CHW (ms)" "Usulan HWC (ms)" "Speedup"
    printf -- "%.0s-" {1..66}; echo ""
    for coreset in "${CORESET_LIST[@]}"; do
        for threads in "${THREAD_LIST[@]}"; do
            n="${T_AVG[NAIVE|$coreset|$threads]:-0}"
            h="${T_AVG[HWC|$coreset|$threads]:-0}"
            printf "%-10s | %3s | %14s | %15s | %sx\n" "$(coreset_label "$coreset")" "$threads" \
                "$n" "$h" "$(ratio_of "$n" "$h")"
        done
    done
    echo ""
fi

# ===================== SKALABILITAS =====================
echo "============================================================================="
echo "     SKALABILITAS (speedup terhadap 1 thread pada program & himpunan core sama)"
echo "============================================================================="
printf "%-22s | %-10s" "Program" "Core"
for threads in "${THREAD_LIST[@]}"; do printf " | %7sT" "$threads"; done
echo ""
printf -- "%.0s-" {1..80}; echo ""
for prog in "${PROGRAM_LIST[@]}"; do
    for coreset in "${CORESET_LIST[@]}"; do
        base="${T_AVG[$prog|$coreset|1]:-0}"
        printf "%-22s | %-10s" "$(program_label "$prog")" "$(coreset_label "$coreset")"
        for threads in "${THREAD_LIST[@]}"; do
            printf " | %7sx" "$(ratio_of "$base" "${T_AVG[$prog|$coreset|$threads]:-0}")"
        done
        echo ""
    done
done
[ -z "${T_AVG[${PROGRAM_LIST[0]}|${CORESET_LIST[0]}|1]:-}" ] && echo "(N/A: THREAD_LIST tidak memuat 1 thread)"
echo ""

# ===================== GRAFIK (GNUPLOT) =====================
echo "============================================================================="
echo "                  MENULIS DATA & MEMBUAT GRAFIK (GNUPLOT)"
echo "============================================================================="
for coreset in "${CORESET_LIST[@]}"; do
    dat="${RESULT_DIR}/fps_${coreset}.dat"
    {
        printf "# threads"
        for prog in "${PROGRAM_LIST[@]}"; do printf " %s" "$prog"; done
        echo ""
        for threads in "${THREAD_LIST[@]}"; do
            printf "%s" "$threads"
            for prog in "${PROGRAM_LIST[@]}"; do
                v=$(fps_of "${T_AVG[$prog|$coreset|$threads]:-0}")
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
            [ -n "$plot_cmd" ] && plot_cmd="${plot_cmd}, "
            plot_cmd="${plot_cmd}'${dat}' using 1:${col} with linespoints lw 2 pt 7 title '$(program_label "$prog")'"
            col=$((col + 1))
        done
        gnuplot <<EOF
set terminal pngcairo size 800,600 enhanced font 'Helvetica,11'
set output '${RESULT_DIR}/fps_${coreset}.png'
set title "FSRCNN Throughput - $(coreset_label "$coreset") core\n(Lebih tinggi lebih baik)" font 'Helvetica-Bold,14'
set xlabel "Jumlah thread" font 'Helvetica-Bold,12'
set ylabel "Throughput (FPS)" font 'Helvetica-Bold,12'
set grid lc rgb "#dddddd"
set logscale x 2
set xtics ($(join_cpus "${THREAD_LIST[@]}"))
set yrange [0:*]
set key top left
plot ${plot_cmd}
EOF
        echo "  [✓] Grafik: ${RESULT_DIR}/fps_${coreset}.png"
    fi
done
command -v gnuplot &> /dev/null || echo "  [!] gnuplot tidak ditemukan, grafik dilewati (data .dat tetap ditulis)."
echo ""

echo "  Ringkasan            : ${SUMMARY_CSV}"
echo "  Timing mentah        : ${RAW_CSV}"
echo "  Waktu per lapisan    : ${LAYER_CSV} (hanya program usulan)"
[ "$PERF" = "1" ] && echo "  Hardware counter     : ${PERF_CSV}"
echo ""
echo "============================================================================="
echo "                       BENCHMARK SELESAI"
echo "============================================================================="
