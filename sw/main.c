

#include <stdio.h>
#include <string.h>
#include "xparameters.h"
#include "xaxidma.h"
#include "xscugic.h"
#include "xtmrctr.h"
#include "xil_cache.h"
#include "xil_exception.h"
#include "xil_printf.h"
#include "xstatus.h"

/* IZBOR FILTRA*/
#define FILT_BOX      0
#define FILT_GAUSS    1
#define FILT_LOG      2
#define FILT_SHARPEN  3
#define FILT_SOBEL    4
#define FILT_CUSTOM   5

#define FILTER     FILT_SOBEL
#define RADIUS_SEL  3     /* radijus  1..4  */

/*SLIKA */
#define IMG_W        128
#define IMG_H        128
/* baferi se dimenzionisu za najveci izlaz (radijus 1) i 16-bit */
#define OUT_MAX_PIX  ((IMG_W-2)*(IMG_H-2))

#define USE_INTERRUPT 1
#define USE_TIMER     1
#define TIMER_FREQ_HZ 100000000UL   /* FCLK_CLK0 = 100 MHz */

#define MARKER       0xA5
#define WAIT_TIMEOUT 800000000U

/*BAZNE ADRESE*/
#ifdef XPAR_XAXIDMA_0_BASEADDR
  #define DMA_BASE   XPAR_XAXIDMA_0_BASEADDR
#elif defined(XPAR_AXI_DMA_0_BASEADDR)
  #define DMA_BASE   XPAR_AXI_DMA_0_BASEADDR
#else
  #define DMA_BASE   0x40400000U
#endif
#define ACC_BASE     0x40000000U

#ifdef XPAR_SCUGIC_0_DEVICE_ID
  #define INTC_ID    XPAR_SCUGIC_0_DEVICE_ID
#elif defined(XPAR_XSCUGIC_0_BASEADDR)
  #define INTC_ID    XPAR_XSCUGIC_0_BASEADDR
#else
  #define INTC_ID    0xF8F01000U
#endif
#ifdef XPAR_FABRIC_AXI_DMA_0_MM2S_INTROUT_INTR
  #define MM2S_INTR_ID XPAR_FABRIC_AXI_DMA_0_MM2S_INTROUT_INTR
#else
  #define MM2S_INTR_ID 61U
#endif
#ifdef XPAR_FABRIC_AXI_DMA_0_S2MM_INTROUT_INTR
  #define S2MM_INTR_ID XPAR_FABRIC_AXI_DMA_0_S2MM_INTROUT_INTR
#else
  #define S2MM_INTR_ID 62U
#endif
#ifndef XPAR_AXI_TIMER_0_BASEADDR
  #ifdef XPAR_XTMRCTR_0_BASEADDR
    #define XPAR_AXI_TIMER_0_BASEADDR XPAR_XTMRCTR_0_BASEADDR
  #endif
#endif

/* REGISTRI (4-bajtna mapa) */
#define R_CTRL   0x00
#define R_RADIUS 0x04
#define R_IMG_W  0x08
#define R_IMG_H  0x0C
#define R_SCALE  0x10
#define R_COEFF0 0x14
#define ACC_WR(o,v) Xil_Out32(ACC_BASE + (o), (u32)(v))
#define ACC_RD(o)   Xil_In32 (ACC_BASE + (o))

/* ProcessingParams  */
typedef struct {
    u16   ImgW;
    u16   ImgH;
    u16   FilterRadius;                 /* maska je (2R+1)x(2R+1) */
    float FilterCoeffs[81];             /* originalni koef, layout (2R+1)x(2R+1), red-po-red */
    float FilterCoeffsScale;            /* faktor skaliranja (forward); scale < 8 */
    u8    Border;                        /* samo za BONUS 1 (ovde 0) */
    u8    Mode;                          /* 0 = 8-bit U izlaz, 1 = 16-bit S izlaz (reg_ctrl bit0) */
} ProcessingParams;

/* GLOBALI */
static u8 DataBuffer    [IMG_W*IMG_H]  __attribute__((aligned(64)));
static u8 ResultBuffer  [OUT_MAX_PIX*2] __attribute__((aligned(64)));
static u8 ReferentBuffer[OUT_MAX_PIX*2] __attribute__((aligned(64)));

static ProcessingParams Params;         

static XAxiDma  AxiDma;
#if USE_INTERRUPT
static XScuGic  Intc;
static volatile int TxDone=0, RxDone=0, DmaErr=0;
#endif
#if USE_TIMER
static XTmrCtr  Timer;
#endif
volatile u32 img_ready = 0;
volatile int filter_sel = FILTER;   

/* KVANTIZACIJA KOEFICIJENATA */
/* Isti izracun za SW i HW -> bit-tacno poklapanje. Vraca CoeffFixed[81] (9x9
 * mapa, kako HW cita) i ScaleFixed (U4.12). */
static void QuantizeCoeffs(const ProcessingParams *p, s16 CoeffFixed[81], u32 *ScaleFixed)
{
    int R = p->FilterRadius, S = 2*R+1, fr, fc, i;
    float invS = 1.0f / p->FilterCoeffsScale;
    for (i = 0; i < 81; i++) CoeffFixed[i] = 0;
    for (fr = 0; fr < S; fr++)
        for (fc = 0; fc < S; fc++) {
            float v = p->FilterCoeffs[fr*S + fc] * invS;      /* svesti u [-1,1) */
            int   q = (int)(v * 32768.0f + (v >= 0 ? 0.5f : -0.5f));
            int ki = fr - R, kj = fc - R;
            int idx = (4 + ki)*9 + (4 + kj);                  /* centar 9x9, vazi za sve R */
            CoeffFixed[idx] = (s16)q;
        }
    *ScaleFixed = (u32)(p->FilterCoeffsScale * 4096.0f + 0.5f);
}

/* ImageFilterSW */
/* Racuna referencu istom fixed-point aritmetikom kao HW  */
static void ImageFilterSW(const u8 *DataIn, void *DataOut, const ProcessingParams *p)
{
    s16 CoeffFixed[81]; u32 ScaleFixed;
    int R = p->FilterRadius, W = p->ImgW, H = p->ImgH;
    int NewW = W - 2*R, i, j, ki, kj;
    QuantizeCoeffs(p, CoeffFixed, &ScaleFixed);

    for (i = R; i < H - R; i++)
        for (j = R; j < W - R; j++) {
            long long acc = 0;
            for (ki = -R; ki <= R; ki++)
                for (kj = -R; kj <= R; kj++) {
                    int idx = (4 + ki)*9 + (4 + kj);
                    acc += (long long)DataIn[(i+ki)*W + (j+kj)] * (long long)CoeffFixed[idx];
                }
            long long full = acc * (long long)(s16)ScaleFixed;   /* HW cita scale kao signed */
            int outIdx = (i - R)*NewW + (j - R);
            if (p->Mode == 1) {
                long long val = full >> 20;                       /* Q7 (S9.7) */
                if (val >  32767) val =  32767;
                if (val < -32768) val = -32768;
                ((s16*)DataOut)[outIdx] = (s16)val;
            } else {
                long long val = full >> 27;
                if (val > 255) val = 255;
                if (val < 0)   val = 0;
                ((u8*)DataOut)[outIdx] = (u8)val;
            }
        }
}

/* DMA / INTERRUPT */
#if USE_INTERRUPT
static void TxIntrHandler(void *cb){ XAxiDma *d=(XAxiDma*)cb; u32 s=XAxiDma_IntrGetIrq(d,XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrAckIrq(d,s,XAXIDMA_DMA_TO_DEVICE); if(!(s&XAXIDMA_IRQ_ALL_MASK))return;
    if(s&XAXIDMA_IRQ_ERROR_MASK){DmaErr=1;return;} if(s&XAXIDMA_IRQ_IOC_MASK)TxDone=1; }
static void RxIntrHandler(void *cb){ XAxiDma *d=(XAxiDma*)cb; u32 s=XAxiDma_IntrGetIrq(d,XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_IntrAckIrq(d,s,XAXIDMA_DEVICE_TO_DMA); if(!(s&XAXIDMA_IRQ_ALL_MASK))return;
    if(s&XAXIDMA_IRQ_ERROR_MASK){DmaErr=1;return;} if(s&XAXIDMA_IRQ_IOC_MASK)RxDone=1; }
static int SetupIntr(void){
    XScuGic_Config *cfg=XScuGic_LookupConfig(INTC_ID);
    if(!cfg||XScuGic_CfgInitialize(&Intc,cfg,cfg->CpuBaseAddress)!=XST_SUCCESS){xil_printf("  ERR GIC\r\n");return XST_FAILURE;}
    XScuGic_SetPriorityTriggerType(&Intc,MM2S_INTR_ID,0xA0,0x3);
    XScuGic_SetPriorityTriggerType(&Intc,S2MM_INTR_ID,0xA0,0x3);
    XScuGic_Connect(&Intc,MM2S_INTR_ID,(Xil_InterruptHandler)TxIntrHandler,&AxiDma);
    XScuGic_Connect(&Intc,S2MM_INTR_ID,(Xil_InterruptHandler)RxIntrHandler,&AxiDma);
    XScuGic_Enable(&Intc,MM2S_INTR_ID); XScuGic_Enable(&Intc,S2MM_INTR_ID);
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT,(Xil_ExceptionHandler)XScuGic_InterruptHandler,&Intc);
    Xil_ExceptionEnable();
    xil_printf("  Interrupt OK (MM2S=%d S2MM=%d)\r\n",(int)MM2S_INTR_ID,(int)S2MM_INTR_ID);
    return XST_SUCCESS;
}
#endif
static int DmaInit(void){
    XAxiDma_Config *cfg=XAxiDma_LookupConfig(DMA_BASE);
    if(!cfg||XAxiDma_CfgInitialize(&AxiDma,cfg)!=XST_SUCCESS){xil_printf("  ERR DMA\r\n");return XST_FAILURE;}
    if(XAxiDma_HasSg(&AxiDma)){xil_printf("  ERR DMA SG\r\n");return XST_FAILURE;}
    return XST_SUCCESS;
}

/* TIMER */
#if USE_TIMER
static int  TimerInit(void){ if(XTmrCtr_Initialize(&Timer,XPAR_AXI_TIMER_0_BASEADDR)!=XST_SUCCESS){xil_printf("  ERR timer\r\n");return XST_FAILURE;}
    XTmrCtr_SetOptions(&Timer,0,XTC_AUTO_RELOAD_OPTION); xil_printf("  Timer OK (%d Hz)\r\n",(int)TIMER_FREQ_HZ); return XST_SUCCESS; }
static void TimerStart(void){ XTmrCtr_Reset(&Timer,0); XTmrCtr_Start(&Timer,0); }
static u32  TimerStopUs(void){ XTmrCtr_Stop(&Timer,0);
    return (u32)((unsigned long long)XTmrCtr_GetValue(&Timer,0)/(TIMER_FREQ_HZ/1000000UL)); }
#else
static int  TimerInit(void){ return XST_SUCCESS; }
static void TimerStart(void){ }
static u32  TimerStopUs(void){ return 0; }
#endif

/* ImageFilterHW */
static int ImageFilterHW(const u8 *DataIn, void *DataOut, const ProcessingParams *p)
{
    s16 CoeffFixed[81]; u32 ScaleFixed; int i;
    int R = p->FilterRadius;
    int InSize  = p->ImgW * p->ImgH;
    int OutPix  = (p->ImgW - 2*R)*(p->ImgH - 2*R);
    int OutSize = OutPix * (p->Mode ? 2 : 1);
    volatile u32 t;

    /*  konfiguracija akceleratora  */
    QuantizeCoeffs(p, CoeffFixed, &ScaleFixed);
    ACC_WR(R_CTRL,  (p->Mode & 0x1));           
    ACC_WR(R_RADIUS, p->FilterRadius);
    ACC_WR(R_IMG_W,  p->ImgW);
    ACC_WR(R_IMG_H,  p->ImgH);
    ACC_WR(R_SCALE,  ScaleFixed);
    for (i = 0; i < 81; i++) ACC_WR(R_COEFF0 + 4*i, (u32)(u16)CoeffFixed[i]);
    if (ACC_RD(R_IMG_W)!=p->ImgW || ACC_RD(R_IMG_H)!=p->ImgH || ACC_RD(R_RADIUS)!=p->FilterRadius) {
        xil_printf("  ERR: readback registara\r\n"); return XST_FAILURE;
    }

    /*  DMA prenos  */
    memset(DataOut, MARKER, OutSize);
    Xil_DCacheFlushRange((UINTPTR)DataIn,  InSize);
    Xil_DCacheFlushRange((UINTPTR)DataOut, OutSize);
#if USE_INTERRUPT
    TxDone=RxDone=DmaErr=0;
    XAxiDma_IntrEnable(&AxiDma,XAXIDMA_IRQ_ALL_MASK,XAXIDMA_DEVICE_TO_DMA);
    XAxiDma_IntrEnable(&AxiDma,XAXIDMA_IRQ_ALL_MASK,XAXIDMA_DMA_TO_DEVICE);
#endif
    if(XAxiDma_SimpleTransfer(&AxiDma,(UINTPTR)DataOut,OutSize,XAXIDMA_DEVICE_TO_DMA)!=XST_SUCCESS)
        {xil_printf("  ERR RX (Buffer Length reg DMA-a premali za %d B?)\r\n",OutSize);return XST_FAILURE;}
    if(XAxiDma_SimpleTransfer(&AxiDma,(UINTPTR)DataIn,InSize,XAXIDMA_DMA_TO_DEVICE)!=XST_SUCCESS)
        {xil_printf("  ERR TX (Buffer Length reg DMA-a premali za %d B?)\r\n",InSize);return XST_FAILURE;}
#if USE_INTERRUPT
    t=WAIT_TIMEOUT; while(!(TxDone&&RxDone)&&!DmaErr){if(--t==0)break;}
    if(DmaErr){xil_printf("  ERR DMA irq\r\n");return XST_FAILURE;}
    if(!TxDone){xil_printf("  TX TIMEOUT\r\n");return XST_FAILURE;}
    if(!RxDone){xil_printf("  RX TIMEOUT\r\n");return XST_FAILURE;}
#else
    t=WAIT_TIMEOUT; while(XAxiDma_Busy(&AxiDma,XAXIDMA_DMA_TO_DEVICE)){if(--t==0){xil_printf("  TX TIMEOUT\r\n");return XST_FAILURE;}}
    t=WAIT_TIMEOUT; while(XAxiDma_Busy(&AxiDma,XAXIDMA_DEVICE_TO_DMA)){if(--t==0){xil_printf("  RX TIMEOUT\r\n");return XST_FAILURE;}}
#endif
    Xil_DCacheInvalidateRange((UINTPTR)DataOut, OutSize);
    return XST_SUCCESS;
}

/* CheckData */
static int CheckData(const void *sw, const void *hw, int nPix, u8 mode)
{
    int i, err=0, shown=0;
    if (mode==1) {
        const s16 *a=(const s16*)sw, *b=(const s16*)hw;
        for(i=0;i<nPix;i++) if(a[i]!=b[i]){ err++; if(shown<10){xil_printf("  MISMATCH %d: SW=%d HW=%d\r\n",i,a[i],b[i]);shown++;} }
    } else {
        const u8 *a=(const u8*)sw, *b=(const u8*)hw;
        for(i=0;i<nPix;i++) if(a[i]!=b[i]){ err++; if(shown<10){xil_printf("  MISMATCH %d: SW=%d HW=%d\r\n",i,a[i],b[i]);shown++;} }
    }
    if(err==0){ xil_printf("  Data check OK - BIT-TACNO svih %d piksela\r\n",nPix); return XST_SUCCESS; }
    xil_printf("  Data check FAIL: %d/%d odstupa\r\n",err,nPix); return XST_FAILURE;
}

/* FILTRI (pregledne matrice - lako se menjaju) *
 *  Za svaki filtar: matrica m[] (red po red), delilac za normalizaciju
 *  (norm; koristi se za filtre za usrednjavanje da im suma bude 1; za
 *  edge/sharpen stavi 1), faktor skaliranja (scale, mora < 8) i mod
 *  (0 = 8-bit neoznacen, 1 = 16-bit oznacen).
 **/
static void BuildParams(ProcessingParams *p, int filt)
{
    int R, i, n;
    float norm = 1.0f;
    for (i = 0; i < 81; i++) p->FilterCoeffs[i] = 0.0f;
    p->ImgW = IMG_W; p->ImgH = IMG_H; p->Border = 0;
    R = 1; p->FilterCoeffsScale = 1.0f; p->Mode = 0;

    switch (filt) {
    case FILT_BOX: {
        R=RADIUS_SEL; p->FilterCoeffsScale=1.0f; p->Mode=0;
        norm=(float)((2*R+1)*(2*R+1));
        n=(2*R+1)*(2*R+1); for(i=0;i<n;i++) p->FilterCoeffs[i]=1.0f/norm;
        xil_printf("  Filtar: BOX R=%d (%dx%d)\r\n", R, 2*R+1, 2*R+1); break; }

    case FILT_GAUSS: {
        static const float m[49] = {
        +0.0000f, +0.0002f, +0.0011f, +0.0018f, +0.0011f, +0.0002f, +0.0000f,
        +0.0002f, +0.0029f, +0.0131f, +0.0216f, +0.0131f, +0.0029f, +0.0002f,
        +0.0011f, +0.0131f, +0.0586f, +0.0966f, +0.0586f, +0.0131f, +0.0011f,
        +0.0018f, +0.0216f, +0.0966f, +0.1592f, +0.0966f, +0.0216f, +0.0018f,
        +0.0011f, +0.0131f, +0.0586f, +0.0966f, +0.0586f, +0.0131f, +0.0011f,
        +0.0002f, +0.0029f, +0.0131f, +0.0216f, +0.0131f, +0.0029f, +0.0002f,
        +0.0000f, +0.0002f, +0.0011f, +0.0018f, +0.0011f, +0.0002f, +0.0000f};
        R=3; p->FilterCoeffsScale=1.0f; p->Mode=0; norm=1.0f;
        n=(2*R+1)*(2*R+1); for(i=0;i<n;i++) p->FilterCoeffs[i]=m[i]/norm;
        xil_printf("  Filtar: GAUSS 7x7\r\n"); break; }

    case FILT_LOG: {   /* LoG R=3, sigma=1 (9x9) */
        static const float m[49] = {
        +0.0003f, +0.0026f, +0.0086f, +0.0124f, +0.0086f, +0.0026f, +0.0003f,
        +0.0026f, +0.0175f, +0.0392f, +0.0431f, +0.0392f, +0.0175f, +0.0026f,
        +0.0086f, +0.0392f, -0.0000f, -0.0965f, -0.0000f, +0.0392f, +0.0086f,
        +0.0124f, +0.0431f, -0.0965f, -0.3183f, -0.0965f, +0.0431f, +0.0124f,
        +0.0086f, +0.0392f, -0.0000f, -0.0965f, -0.0000f, +0.0392f, +0.0086f,
        +0.0026f, +0.0175f, +0.0392f, +0.0431f, +0.0392f, +0.0175f, +0.0026f,
        +0.0003f, +0.0026f, +0.0086f, +0.0124f, +0.0086f, +0.0026f, +0.0003f};
        R=3; p->FilterCoeffsScale=1.0f; p->Mode=1; norm=1.0f;
        n=(2*R+1)*(2*R+1); for(i=0;i<n;i++) p->FilterCoeffs[i]=m[i]/norm;
        xil_printf("  Filtar: LoG 7x7 R=3 sigma=1\r\n"); break; }

    case FILT_SHARPEN: {
        R=RADIUS_SEL; p->FilterCoeffsScale=3.0f; p->Mode=0;
        { float nb=(float)((2*R+1)*(2*R+1)); int c=R*(2*R+1)+R;
          n=(2*R+1)*(2*R+1);
          for(i=0;i<n;i++) p->FilterCoeffs[i] = -1.0f/nb;   /* -box */
          p->FilterCoeffs[c] += 2.0f;                        /* +2*delta u centru */
        }
        xil_printf("  Filtar: SHARPEN R=%d\r\n", R); break; }

    case FILT_SOBEL: {
        static const float m[9] = { -1,0,1, -2,0,2, -1,0,1 };
        R=1; p->FilterCoeffsScale=4.0f; p->Mode=1; norm=1.0f;
        n=(2*R+1)*(2*R+1); for(i=0;i<n;i++) p->FilterCoeffs[i]=m[i]/norm;
        xil_printf("  Filtar: SOBEL-X 3x3\r\n"); break; }
        
    default: { /* FILT_CUSTOM - upisi svoju masku */
        static const float m[9] = { 0,0,0, 0,1,0, 0,0,0 };
        R=1; p->FilterCoeffsScale=1.0f; p->Mode=0; norm=1.0f;
        n=(2*R+1)*(2*R+1); for(i=0;i<n;i++) p->FilterCoeffs[i]=m[i]/norm;
        xil_printf("  Filtar: CUSTOM\r\n"); break; }
    }
    p->FilterRadius = R;
}

/* MAIN */
int main(void)
{
    u32 t_sw, t_hw;
    int R, OutW, OutH, OutPix, OutSize;

    xil_printf("\r\n--- acc_image_filter : ProcessingParams ---\r\n");

    if (DmaInit()  != XST_SUCCESS) return -1;
#if USE_INTERRUPT
    if (SetupIntr()!= XST_SUCCESS) return -1;
#endif
    if (TimerInit()!= XST_SUCCESS) return -1;

    /*  petlja: svaka nova obrada bez restarta */
    for (;;) {
        xil_printf("\r\n>>> NOVA OBRADA (Suspend, ukucaj u XSCT, pa Resume):\r\n");
        xil_printf("    1) izaberi filtar:  mwr 0x%08x <N>\r\n", (unsigned)(UINTPTR)&filter_sel);
        xil_printf("       0=BOX 1=GAUSS 2=LOG 3=SHARPEN 4=SOBEL 5=CUSTOM\r\n");
        xil_printf("    2) ucitaj sliku:    mwr -size b -bin -file C:/pokusaj_proj/slika_raw.bin 0x%08x %d\r\n",
                   (unsigned)(UINTPTR)DataBuffer, IMG_W*IMG_H);
        xil_printf("    3) pokreni:         mwr 0x%08x 1\r\n", (unsigned)(UINTPTR)&img_ready);

        /* cekaj trigger; filtar i sliku postavljas u toku ove pauze */
        img_ready = 0;
        while (img_ready == 0) Xil_DCacheInvalidateRange((UINTPTR)&img_ready, sizeof(img_ready));

        /* tek sada procitaj izabrani filtar (osvezi kes zbog mwr iz XSCT) */
        Xil_DCacheInvalidateRange((UINTPTR)&filter_sel, sizeof(filter_sel));
        BuildParams(&Params, filter_sel);
        R      = Params.FilterRadius;
        OutW   = Params.ImgW - 2*R;
        OutH   = Params.ImgH - 2*R;
        OutPix = OutW * OutH;
        OutSize= OutPix * (Params.Mode ? 2 : 1);
        Xil_DCacheInvalidateRange((UINTPTR)DataBuffer, IMG_W*IMG_H);
        xil_printf("  Ulaz %dx%d, izlaz %dx%d, MODE=%d, izlaz %d B\r\n",
                   Params.ImgW, Params.ImgH, OutW, OutH, Params.Mode, OutSize);

        TimerStart(); ImageFilterSW(DataBuffer, ReferentBuffer, &Params); t_sw = TimerStopUs();
        xil_printf("  SW: %d us\r\n", (int)t_sw);

        TimerStart();
        if (ImageFilterHW(DataBuffer, ResultBuffer, &Params) != XST_SUCCESS) { xil_printf("  HW greska\r\n"); continue; }
        t_hw = TimerStopUs();
        xil_printf("  HW: %d us\r\n", (int)t_hw);
        if (t_hw > 0) xil_printf("  Ubrzanje SW/HW = %d.%02d x\r\n",
                                 (int)(t_sw/t_hw), (int)(((t_sw%t_hw)*100)/t_hw));

        CheckData(ReferentBuffer, ResultBuffer, OutPix, Params.Mode);

        xil_printf(">>> DUMP:  mrd -size b -bin -file C:/pokusaj_proj/result.bin 0x%08x %d\r\n",
                   (unsigned)(UINTPTR)ResultBuffer, OutSize);
    }
    return 0;
}