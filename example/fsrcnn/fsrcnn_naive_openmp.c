// FSRCNN (56,12,4) untuk interpolasi video YUV 4:2:0 (x2) pada CPU multi-core
// Basis implementasi: Milad Abdollahzadeh, 09/02/2017
//
// Dimodifikasi untuk penelitian tesis:
//   "Analisis Pengaruh Pola Akses Feature Map dan Paralelisasi Spasial terhadap
//    Tekanan Bandwidth Memori dan Efisiensi Inferensi Layer FSRCNN Berkanal Kecil
//    pada CPU Multi-Core" - Wa Ode Ratna Adiningsih (D082252009)
//
// USULAN: layout feature map HWC + paralelisasi spasial.
//   - Layout HWC  : seluruh kanal pada satu posisi spasial tersimpan kontigu,
//                   out[y][x][c], dipakai di seluruh 8 lapisan.
//   - Paralelisasi: OpenMP pada dimensi spasial, yaitu baris (tinggi) feature map
//                   keluaran dibagi rata antar-thread (1, 2, 4, 8 thread).
// Pembanding (baseline) adalah fsrcnn_naive_openmp_old.c: layout CHW dengan
// paralelisasi per kanal/filter.
//
// Keluaran pengukuran (per lapisan, dengan resolusi nanodetik via clock_gettime):
//   - waktu eksekusi (efisiensi inferensi) dan throughput (GFLOP/s, FPS)
//   - arithmetic intensity teoretis (FLOP/byte) dan estimasi bandwidth minimum
//     (compulsory traffic / waktu) sebagai proksi tekanan bandwidth memori
// Cache miss dan bandwidth DRAM aktual diukur dari luar (non-intrusif) dengan perf, mis.:
//   perf stat -e cycles,instructions,L1-dcache-load-misses,LLC-load-misses,LLC-loads
//     ./fsrcnn_naive_openmp in.yuv out.yuv 150 4
//
// Kompilasi : gcc -O3 -fopenmp -o fsrcnn_naive_openmp fsrcnn_naive_openmp.c -lm
// Pemakaian : ./fsrcnn_naive_openmp <in.yuv> <out.yuv> [frames] [threads] [csv] [width] [height]
//   frames  : default 150
//   threads : default OMP_NUM_THREADS / omp_get_max_threads()
//   csv     : file CSV untuk ditambahkan hasil per lapisan (opsional, "-" = tidak ada)
//   width, height : resolusi input, default 176x144 (QCIF)

#define _POSIX_C_SOURCE 199309L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <omp.h>

#define SCALE      2
#define NUM_LAYERS 8

// Konfigurasi lapisan FSRCNN (56,12,4): feature extraction, shrinking, mapping x4, expanding, deconvolution
typedef struct
{
	const char *name;
	int cin;           // jumlah kanal masukan
	int cout;          // jumlah kanal keluaran (filter)
	int ksize;         // ukuran kernel (ksize x ksize)
	double prelu;      // koefisien PReLU
	const char *wfile;
	const char *bfile;
	double *w;         // bobot tersusun untuk HWC: [cout][ky][kx][cin] (deconv: [ky][kx][cin])
	double *b;
} layer_t;

static layer_t layers[NUM_LAYERS] = {
	{ "L1 feature_extraction", 1,  56, 5, -0.8986, "weights_layer1.txt", "biasess_layer1.txt" },
	{ "L2 shrinking",          56, 12, 1,  0.3236, "weights_layer2.txt", "biasess_layer2.txt" },
	{ "L3 mapping1",           12, 12, 3,  0.2288, "weights_layer3.txt", "biasess_layer3.txt" },
	{ "L4 mapping2",           12, 12, 3,  0.2476, "weights_layer4.txt", "biasess_layer4.txt" },
	{ "L5 mapping3",           12, 12, 3,  0.3495, "weights_layer5.txt", "biasess_layer5.txt" },
	{ "L6 mapping4",           12, 12, 3,  0.7806, "weights_layer6.txt", "biasess_layer6.txt" },
	{ "L7 expanding",          12, 56, 1,  0.0087, "weights_layer7.txt", "biasess_layer7.txt" },
	{ "L8 deconvolution",      56, 1,  9,  0.0,    "weights_layer8.txt", "biasess_layer8.txt" },
};

// Statistik per lapisan (akumulasi seluruh frame)
static double layer_time_ns[NUM_LAYERS];
static double layer_flops[NUM_LAYERS];   // FLOP per frame
static double layer_bytes[NUM_LAYERS];   // byte compulsory per frame (input + output + bobot)

static void load_txt(const char *fname, double *dst, int n);
static void init_layers(void);
static void free_layers(void);
static void compute_layer_cost(int rows, int cols);
static double now_ns(void);

static void FSRCNN(double *img_hr, const double *img_lr, double **fmap, int rows, int cols);
static void conv_hwc(const double *in, double *out, const layer_t *L, int rows, int cols);
static void deconv_hwc(const double *in, double *out, const layer_t *L, int rows, int cols);
static void double_2_uint8(const double *double_img, unsigned char *uint8_img, int n);
static void upsample_chroma(const unsigned char *in, unsigned char *out, int inCols, int inRows);
static void report(FILE *csv, int threads, int frames, int rows, int cols, double total_ns, double wall_ns);

static inline int clampi(int v, int lo, int hi)
{
	return v < lo ? lo : (v > hi ? hi : v);
}

static inline double prelu(double v, double coeff)
{
	return v > 0 ? v : coeff * v;
}

int main(int argc, char *argv[])
{
	if (argc < 3)
	{
		fprintf(stderr, "Pemakaian: %s <in.yuv> <out.yuv> [frames] [threads] [csv] [width] [height]\n", argv[0]);
		return 1;
	}

	char *inFile = argv[1];
	char *outFile = argv[2];
	int num = (argc > 3) ? atoi(argv[3]) : 150;                    // Jumlah frame
	int threads = (argc > 4) ? atoi(argv[4]) : omp_get_max_threads();
	const char *csvFile = (argc > 5 && strcmp(argv[5], "-") != 0) ? argv[5] : NULL;
	int inCols = (argc > 6) ? atoi(argv[6]) : 176;                // Lebar video input
	int inRows = (argc > 7) ? atoi(argv[7]) : 144;                // Tinggi video input

	if (num <= 0 || threads <= 0 || inCols <= 0 || inRows <= 0)
	{
		fprintf(stderr, "Parameter tidak valid\n");
		return 1;
	}
	omp_set_num_threads(threads);

	int outCols = inCols * SCALE;
	int outRows = inRows * SCALE;

	FILE *inFp = fopen(inFile, "rb");
	if (inFp == NULL) { fprintf(stderr, "Gagal membuka input %s\n", inFile); return 1; }
	FILE *outFp = fopen(outFile, "wb");
	if (outFp == NULL) { fprintf(stderr, "Gagal membuka output %s\n", outFile); return 1; }

	init_layers();
	compute_layer_cost(inRows, inCols);

	// Seluruh buffer dialokasikan sekali di luar loop frame agar malloc/free
	// tidak ikut terukur sebagai waktu inferensi.
	unsigned char *inBuf = (unsigned char *)malloc(inCols * inRows);
	unsigned char *outBuf = (unsigned char *)malloc(outCols * outRows);
	double *inBuf_tmp = (double *)malloc(inCols * inRows * sizeof(double));
	double *outBuf_tmp = (double *)malloc(outCols * outRows * sizeof(double));
	double *fmap[NUM_LAYERS - 1];
	for (int l = 0; l < NUM_LAYERS - 1; l++)
		fmap[l] = (double *)malloc((size_t)inRows * inCols * layers[l].cout * sizeof(double));

	double total_ns = 0;
	double wall_start = now_ns();

	for (int fcnt = 0; fcnt < num; fcnt++)
	{
		//Y Component: FSRCNN
		if (fread(inBuf, 1, inCols * inRows, inFp) != (size_t)(inCols * inRows))
		{
			fprintf(stderr, "Input habis pada frame %d\n", fcnt);
			num = fcnt;
			break;
		}

		for (int i = 0; i < inCols * inRows; i++)
			inBuf_tmp[i] = inBuf[i] / 255.0;

		double t0 = now_ns();
		FSRCNN(outBuf_tmp, inBuf_tmp, fmap, inRows, inCols);
		total_ns += now_ns() - t0;

		for (int i = 0; i < outCols * outRows; i++)
			outBuf_tmp[i] = outBuf_tmp[i] * 255;

		double_2_uint8(outBuf_tmp, outBuf, outCols * outRows);
		fwrite(outBuf, 1, outCols * outRows, outFp);

		//U Component: simple repetition
		fread(inBuf, 1, inCols * inRows / 4, inFp);
		upsample_chroma(inBuf, outBuf, inCols, inRows);
		fwrite(outBuf, 1, outCols * outRows / 4, outFp);

		// V Component: simple repetition
		fread(inBuf, 1, inCols * inRows / 4, inFp);
		upsample_chroma(inBuf, outBuf, inCols, inRows);
		fwrite(outBuf, 1, outCols * outRows / 4, outFp);
	}
	double wall_ns = now_ns() - wall_start;

	FILE *csv = NULL;
	if (csvFile != NULL)
	{
		csv = fopen(csvFile, "a+");
		if (csv == NULL)
			fprintf(stderr, "Gagal membuka CSV %s\n", csvFile);
	}
	report(csv, threads, num, inRows, inCols, total_ns, wall_ns);
	if (csv != NULL)
		fclose(csv);
	// Format sama dengan fsrcnn_naive_openmp_old.c, dibaca oleh comparison_ratna.sh
	printf("INFERENCE_MS=%.3f\n", total_ns * 1e-6);

	fclose(inFp);
	fclose(outFp);
	for (int l = 0; l < NUM_LAYERS - 1; l++)
		free(fmap[l]);
	free(inBuf);
	free(inBuf_tmp);
	free(outBuf);
	free(outBuf_tmp);
	free_layers();
	return 0;
}

static void FSRCNN(double *img_hr, const double *img_lr, double **fmap, int rows, int cols)
{
	// Lapisan 1-7: konvolusi + PReLU. Input lapisan 1 hanya satu kanal (citra Y).
	const double *in = img_lr;
	for (int l = 0; l < NUM_LAYERS - 1; l++)
	{
		double t0 = now_ns();
		conv_hwc(in, fmap[l], &layers[l], rows, cols);
		layer_time_ns[l] += now_ns() - t0;
		in = fmap[l];
	}

	// Lapisan 8: dekonvolusi (stride = SCALE)
	double t0 = now_ns();
	deconv_hwc(in, img_hr, &layers[NUM_LAYERS - 1], rows, cols);
	layer_time_ns[NUM_LAYERS - 1] += now_ns() - t0;
}

// Konvolusi layout HWC: out[y][x][co]
// Paralelisasi spasial: baris keluaran (y) dibagi rata antar-thread (schedule static).
// Kanal masukan pada satu posisi spasial tersimpan kontigu, sehingga loop terdalam
// berjalan pada dimensi kanal (bobot disusun [co][ky][kx][ci]).
// Padding replikasi diimplementasikan dengan clamp indeks (setara pad_image pada versi asli).
static void conv_hwc(const double *in, double *out, const layer_t *L, int rows, int cols)
{
	const int cin = L->cin, cout = L->cout, k = L->ksize, pad = (k - 1) / 2;

	#pragma omp parallel for schedule(static)
	for (int y = 0; y < rows; y++)
	{
		for (int x = 0; x < cols; x++)
		{
			double *out_px = out + ((size_t)y * cols + x) * cout;
			for (int co = 0; co < cout; co++)
			{
				const double *w = L->w + (size_t)co * k * k * cin;
				double acc = 0;
				for (int ky = 0; ky < k; ky++)
				{
					const int iy = clampi(y + ky - pad, 0, rows - 1);
					for (int kx = 0; kx < k; kx++)
					{
						const double *in_px = in + ((size_t)iy * cols + clampi(x + kx - pad, 0, cols - 1)) * cin;
						const double *w_px = w + (ky * k + kx) * cin;
						for (int ci = 0; ci < cin; ci++)
							acc += in_px[ci] * w_px[ci];
					}
				}
				out_px[co] = prelu(acc + L->b[co], L->prelu);
			}
		}
	}
}

// Dekonvolusi (transposed convolution) dalam bentuk gather, setara dengan fungsi
// deconv() asli (scatter input yang di-pad replikasi 1 piksel, lalu crop).
// Setiap piksel keluaran dihitung oleh tepat satu thread, sehingga tidak ada race
// condition saat akumulasi antar-kanal (berbeda dengan versi naif sebelumnya).
//
// Relasi scatter asli: tmp[i*s + ky][j*s + kx] += in_pad[i][j] * w[ky][kx]
// out[y][x] = tmp[y + off][x + off], off = (k+1)/2 + s*border - 1
#define DECONV_BORDER 1

static inline void deconv_range(int Y, int s, int k, int n_pad, int *lo, int *hi)
{
	// indeks i pada input ter-pad yang berkontribusi ke baris tmp Y: 0 <= Y - i*s < k
	int l = (Y - k + 1 + s - 1) / s;
	if (Y - k + 1 < 0) l = 0;
	int h = Y / s;
	*lo = l < 0 ? 0 : l;
	*hi = h > n_pad - 1 ? n_pad - 1 : h;
}

static void deconv_hwc(const double *in, double *out, const layer_t *L, int rows, int cols)
{
	const int cin = L->cin, k = L->ksize, s = SCALE;
	const int off = (k + 1) / 2 + s * DECONV_BORDER - 1;
	const int rows_pad = rows + 2 * DECONV_BORDER, cols_pad = cols + 2 * DECONV_BORDER;
	const int rows_out = rows * s, cols_out = cols * s;

	#pragma omp parallel for schedule(static)
	for (int y = 0; y < rows_out; y++)
	{
		int i_lo, i_hi;
		deconv_range(y + off, s, k, rows_pad, &i_lo, &i_hi);
		for (int x = 0; x < cols_out; x++)
		{
			int j_lo, j_hi;
			deconv_range(x + off, s, k, cols_pad, &j_lo, &j_hi);
			double acc = 0;
			for (int i = i_lo; i <= i_hi; i++)
			{
				const int iy = clampi(i - DECONV_BORDER, 0, rows - 1);
				const int ky = y + off - i * s;
				for (int j = j_lo; j <= j_hi; j++)
				{
					const double *in_px = in + ((size_t)iy * cols + clampi(j - DECONV_BORDER, 0, cols - 1)) * cin;
					const double *w_px = L->w + (ky * k + (x + off - j * s)) * cin;
					for (int c = 0; c < cin; c++)
						acc += in_px[c] * w_px[c];
				}
			}
			out[(size_t)y * cols_out + x] = acc + L->b[0];
		}
	}
}

static void load_txt(const char *fname, double *dst, int n)
{
	FILE *fp = fopen(fname, "r");
	if (fp == NULL)
	{
		fprintf(stderr, "Gagal membaca %s\n", fname);
		exit(1);
	}
	for (int i = 0; i < n; i++)
	{
		if (fscanf(fp, "%lf", &dst[i]) != 1)
		{
			fprintf(stderr, "Isi %s kurang dari %d nilai\n", fname, n);
			exit(1);
		}
	}
	fclose(fp);
}

static void init_layers(void)
{
	for (int l = 0; l < NUM_LAYERS; l++)
	{
		layer_t *L = &layers[l];
		const int kk = L->ksize * L->ksize;
		const int nw = L->cout * L->cin * kk;

		// File bobot tersimpan [co][ci][ky][kx]; disusun ulang menjadi [co][ky][kx][ci]
		double *w_file = (double *)malloc(nw * sizeof(double));
		L->w = (double *)malloc(nw * sizeof(double));
		L->b = (double *)malloc(L->cout * sizeof(double));
		load_txt(L->wfile, w_file, nw);
		load_txt(L->bfile, L->b, L->cout);

		for (int co = 0; co < L->cout; co++)
		for (int ci = 0; ci < L->cin; ci++)
		for (int p = 0; p < kk; p++)
			L->w[((size_t)co * kk + p) * L->cin + ci] = w_file[((size_t)co * L->cin + ci) * kk + p];
		free(w_file);
	}
}

static void free_layers(void)
{
	for (int l = 0; l < NUM_LAYERS; l++)
	{
		free(layers[l].w);
		free(layers[l].b);
	}
}

// Menghitung FLOP dan compulsory traffic (byte) per frame untuk tiap lapisan.
// Arithmetic intensity = FLOP / byte; dipakai untuk memetakan lapisan pada roofline model.
static void compute_layer_cost(int rows, int cols)
{
	const double px = (double)rows * cols;
	for (int l = 0; l < NUM_LAYERS - 1; l++)
	{
		const layer_t *L = &layers[l];
		const double kk = L->ksize * L->ksize;
		layer_flops[l] = 2.0 * px * L->cout * L->cin * kk + 2.0 * px * L->cout; // MAC + bias/PReLU
		layer_bytes[l] = sizeof(double) * (px * L->cin + px * L->cout + L->cout * L->cin * kk + L->cout);
	}

	// Dekonvolusi: hitung jumlah tap aktual dari bentuk gather
	const layer_t *L = &layers[NUM_LAYERS - 1];
	const int k = L->ksize, s = SCALE;
	const int off = (k + 1) / 2 + s * DECONV_BORDER - 1;
	double taps_y = 0, taps_x = 0;
	int lo, hi;
	for (int y = 0; y < rows * s; y++) { deconv_range(y + off, s, k, rows + 2 * DECONV_BORDER, &lo, &hi); taps_y += hi - lo + 1; }
	for (int x = 0; x < cols * s; x++) { deconv_range(x + off, s, k, cols + 2 * DECONV_BORDER, &lo, &hi); taps_x += hi - lo + 1; }
	layer_flops[NUM_LAYERS - 1] = 2.0 * taps_y * taps_x * L->cin + px * s * s;
	layer_bytes[NUM_LAYERS - 1] = sizeof(double) * (px * L->cin + px * s * s + L->cin * k * k + 1);
}

static void report(FILE *csv, int threads, int frames, int rows, int cols, double total_ns, double wall_ns)
{
	if (frames <= 0)
		return;

	printf("\n=== FSRCNN usulan | layout=HWC | threads=%d | frames=%d | input=%dx%d ===\n",
		threads, frames, cols, rows);
	printf("%-22s %12s %8s %10s %10s %12s\n",
		"Lapisan", "ms/frame", "%waktu", "GFLOP/s", "AI(F/B)", "BWmin(GB/s)");

	if (csv != NULL)
	{
		fseek(csv, 0, SEEK_END);
		if (ftell(csv) == 0)
			fprintf(csv, "layout,threads,frames,width,height,layer,name,time_ms_per_frame,time_pct,gflops,ai_flop_per_byte,bw_min_gbs\n");
	}

	double sum_layers_ns = 0;
	for (int l = 0; l < NUM_LAYERS; l++)
		sum_layers_ns += layer_time_ns[l];

	for (int l = 0; l < NUM_LAYERS; l++)
	{
		double t_frame_s = layer_time_ns[l] / frames * 1e-9;
		double gflops = layer_flops[l] / t_frame_s * 1e-9;
		double ai = layer_flops[l] / layer_bytes[l];
		double bw = layer_bytes[l] / t_frame_s * 1e-9;
		double pct = 100.0 * layer_time_ns[l] / sum_layers_ns;

		printf("%-22s %12.3f %7.2f%% %10.3f %10.3f %12.3f\n",
			layers[l].name, t_frame_s * 1e3, pct, gflops, ai, bw);
		if (csv != NULL)
			fprintf(csv, "HWC,%d,%d,%d,%d,%d,%s,%.6f,%.3f,%.6f,%.6f,%.6f\n",
				threads, frames, cols, rows, l + 1, layers[l].name,
				t_frame_s * 1e3, pct, gflops, ai, bw);
	}

	double flops_total = 0;
	for (int l = 0; l < NUM_LAYERS; l++)
		flops_total += layer_flops[l];
	double t_frame_s = total_ns / frames * 1e-9;

	printf("%-22s %12.3f %8s %10.3f\n", "TOTAL inferensi", t_frame_s * 1e3, "", flops_total / t_frame_s * 1e-9);
	printf("FPS inferensi (Y)  : %.3f\n", frames / (total_ns * 1e-9));
	printf("FPS end-to-end     : %.3f (termasuk I/O dan konversi)\n", frames / (wall_ns * 1e-9));

	if (csv != NULL)
		fprintf(csv, "HWC,%d,%d,%d,%d,0,TOTAL,%.6f,100.000,%.6f,,\n",
			threads, frames, cols, rows,
			t_frame_s * 1e3, flops_total / t_frame_s * 1e-9);
}

static double now_ns(void)
{
#ifdef CLOCK_MONOTONIC
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec * 1e9 + (double)ts.tv_nsec;
#else
	return omp_get_wtime() * 1e9; // fallback untuk platform tanpa clock_gettime (mis. MinGW)
#endif
}

static void upsample_chroma(const unsigned char *in, unsigned char *out, int inCols, int inRows)
{
	const int outColsC = inCols; // lebar plane chroma keluaran = (inCols*SCALE)/2
	for (int i = 0; i < inRows / 2; i++)
	for (int j = 0; j < inCols / 2; j++)
	{
		unsigned char x = in[i * (inCols / 2) + j];
		int cnt = 2 * i * outColsC + 2 * j;
		out[cnt] = x;
		out[cnt + 1] = x;
		out[cnt + outColsC] = x;
		out[cnt + outColsC + 1] = x;
	}
}

static void double_2_uint8(const double *double_img, unsigned char *uint8_img, int n)
{
	for (int i = 0; i < n; i++)
	{
		double v = double_img[i];
		if (v < 0)
			uint8_img[i] = 0;
		else if (v >= 255)
			uint8_img[i] = 255;
		else
			uint8_img[i] = (unsigned char)(v + 0.5);
	}
}
