#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include "ASICamera2.h"

/* =========================================================
   Packet framing — 4-байтовый big-endian заголовок длины
   Это стандарт для Erlang Port с опцией {:packet, 4}
   ========================================================= */

static int read_exact(uint8_t *buf, int len) {
    int got = 0;
    while (got < len) {
        int n = read(STDIN_FILENO, buf + got, len - got);
        if (n <= 0) return -1;
        got += n;
    }
    return got;
}

static int write_exact(const uint8_t *buf, int len) {
    int sent = 0;
    while (sent < len) {
        int n = write(STDOUT_FILENO, buf + sent, len - sent);
        if (n <= 0) return -1;
        sent += n;
    }
    return sent;
}

static int read_packet(uint8_t **buf) {
    uint8_t hdr[4];
    if (read_exact(hdr, 4) < 0) return -1;
    uint32_t len = ((uint32_t)hdr[0] << 24) |
                   ((uint32_t)hdr[1] << 16) |
                   ((uint32_t)hdr[2] <<  8) |
                    (uint32_t)hdr[3];
    *buf = malloc(len);
    if (!*buf) return -1;
    if (read_exact(*buf, len) < 0) { free(*buf); return -1; }
    return (int)len;
}

static void write_packet(const uint8_t *data, uint32_t len) {
    uint8_t hdr[4] = {
        (len >> 24) & 0xFF,
        (len >> 16) & 0xFF,
        (len >>  8) & 0xFF,
         len        & 0xFF
    };
    write_exact(hdr, 4);
    write_exact(data, len);
}

/* =========================================================
   Вспомогательные функции ответов
   ========================================================= */

static void reply_ok(void) {
    uint8_t r = 0x00;
    write_packet(&r, 1);
}

static void reply_ok_byte(uint8_t val) {
    uint8_t r[2] = {0x00, val};
    write_packet(r, 2);
}

static void reply_ok_int(int32_t val) {
    uint8_t r[5];
    r[0] = 0x00;
    r[1] = (val >> 24) & 0xFF;
    r[2] = (val >> 16) & 0xFF;
    r[3] = (val >>  8) & 0xFF;
    r[4] =  val        & 0xFF;
    write_packet(r, 5);
}

static void reply_error(const char *msg) {
    uint32_t mlen = strlen(msg);
    uint8_t *r = malloc(1 + mlen);
    r[0] = 0xFF;
    memcpy(r + 1, msg, mlen);
    write_packet(r, 1 + mlen);
    free(r);
}

/* =========================================================
   Опкоды команд — должны совпадать с CameraWorker
   ========================================================= */

#define CMD_OPEN_CAMERA     0x01
#define CMD_SET_ROI         0x02
#define CMD_SET_CONTROL     0x03
#define CMD_START_EXPOSURE  0x04
#define CMD_GET_EXP_STATUS  0x05
#define CMD_GET_FRAME       0x06
#define CMD_CLOSE_CAMERA    0x07
#define CMD_GET_TEMP        0x08
#define CMD_SET_COOLER      0x09

/* =========================================================
   Глобальное состояние — один процесс = одна камера
   ========================================================= */

static int      g_cam_id  = -1;
static int      g_width   = 9576;
static int      g_height  = 6388;
static uint8_t *g_frame_buf = NULL;
static long     g_frame_buf_size = 0;

/* =========================================================
   Обработчики команд
   ========================================================= */

static void cmd_open_camera(void) {
    int n = ASIGetNumOfConnectedCameras();
    if (n <= 0) { reply_error("no_cameras"); return; }

    ASI_CAMERA_INFO info;
    if (ASIGetCameraProperty(&info, 0) != ASI_SUCCESS) {
        reply_error("get_property_failed"); return;
    }
    if (ASIOpenCamera(info.CameraID) != ASI_SUCCESS) {
        reply_error("open_failed"); return;
    }
    if (ASIInitCamera(info.CameraID) != ASI_SUCCESS) {
        reply_error("init_failed"); return;
    }
    g_cam_id = info.CameraID;
    reply_ok_byte((uint8_t)g_cam_id);
}

/* payload: width(4) height(4) bin(1) img_type(1) */
static void cmd_set_roi(const uint8_t *buf, int len) {
    if (len < 10) { reply_error("bad_args"); return; }
    int width    = (buf[0]<<24)|(buf[1]<<16)|(buf[2]<<8)|buf[3];
    int height   = (buf[4]<<24)|(buf[5]<<16)|(buf[6]<<8)|buf[7];
    int bin      = buf[8];
    int img_type = buf[9];

    if (ASISetROIFormat(g_cam_id, width, height, bin,
                        (ASI_IMG_TYPE)img_type) != ASI_SUCCESS) {
        reply_error("set_roi_failed"); return;
    }
    g_width  = width;
    g_height = height;

    /* Пересоздаём буфер под новый размер (RAW16 = 2 байта/пиксель) */
    free(g_frame_buf);
    g_frame_buf_size = (long)width * height * 2;
    g_frame_buf = malloc(g_frame_buf_size);
    if (!g_frame_buf) { reply_error("malloc_failed"); return; }

    reply_ok();
}

/* payload: ctrl_type(4) value(4) */
static void cmd_set_control(const uint8_t *buf, int len) {
    if (len < 8) { reply_error("bad_args"); return; }
    int  ctrl  = (buf[0]<<24)|(buf[1]<<16)|(buf[2]<<8)|buf[3];
    long value = (long)((buf[4]<<24)|(buf[5]<<16)|(buf[6]<<8)|buf[7]);

    if (ASISetControlValue(g_cam_id, (ASI_CONTROL_TYPE)ctrl,
                           value, ASI_FALSE) != ASI_SUCCESS) {
        reply_error("set_control_failed"); return;
    }
    reply_ok();
}

static void cmd_start_exposure(void) {
    if (ASIStartExposure(g_cam_id, ASI_FALSE) != ASI_SUCCESS) {
        reply_error("start_exposure_failed"); return;
    }
    reply_ok();
}

static void cmd_get_exp_status(void) {
    ASI_EXPOSURE_STATUS status;
    ASIGetExpStatus(g_cam_id, &status);
    reply_ok_byte((uint8_t)status);
    /* 0 = working, 1 = success, 2 = failed */
}

static void cmd_get_frame(void) {
    if (!g_frame_buf) { reply_error("no_buffer"); return; }

    if (ASIGetDataAfterExp(g_cam_id, g_frame_buf,
                           g_frame_buf_size) != ASI_SUCCESS) {
        reply_error("get_data_failed"); return;
    }

    /* Ответ: [0x00, ...frame bytes...] */
    uint8_t *resp = malloc(1 + g_frame_buf_size);
    if (!resp) { reply_error("malloc_failed"); return; }
    resp[0] = 0x00;
    memcpy(resp + 1, g_frame_buf, g_frame_buf_size);
    write_packet(resp, 1 + g_frame_buf_size);
    free(resp);
}

static void cmd_get_temp(void) {
    long temp = 0;
    ASI_BOOL is_auto;
    /* ASI_TEMPERATURE = 14 */
    ASIGetControlValue(g_cam_id, ASI_TEMPERATURE, &temp, &is_auto);
    reply_ok_int((int32_t)temp);
}

/* payload: target_temp_tenths(4) */
static void cmd_set_cooler(const uint8_t *buf, int len) {
    if (len < 4) { reply_error("bad_args"); return; }
    long target = (long)((buf[0]<<24)|(buf[1]<<16)|(buf[2]<<8)|buf[3]);
    ASISetControlValue(g_cam_id, ASI_TARGET_TEMP, target, ASI_FALSE);
    ASISetControlValue(g_cam_id, ASI_COOLER_ON,   1,      ASI_FALSE);
    reply_ok();
}

static void cmd_close_camera(void) {
    if (g_cam_id >= 0) {
        ASISetControlValue(g_cam_id, ASI_COOLER_ON, 0, ASI_FALSE);
        ASICloseCamera(g_cam_id);
        g_cam_id = -1;
    }
    free(g_frame_buf);
    g_frame_buf = NULL;
    reply_ok();
}

/* =========================================================
   Main loop
   ========================================================= */

int main(void) {
    /* Отключаем буферизацию — иначе BEAM не получит ответы */
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stdin,  NULL, _IONBF, 0);

    uint8_t *buf;
    int      len;

    while ((len = read_packet(&buf)) > 0) {
        uint8_t cmd = buf[0];

        switch (cmd) {
            case CMD_OPEN_CAMERA:    cmd_open_camera();                   break;
            case CMD_SET_ROI:        cmd_set_roi(buf+1, len-1);           break;
            case CMD_SET_CONTROL:    cmd_set_control(buf+1, len-1);       break;
            case CMD_START_EXPOSURE: cmd_start_exposure();                break;
            case CMD_GET_EXP_STATUS: cmd_get_exp_status();                break;
            case CMD_GET_FRAME:      cmd_get_frame();                     break;
            case CMD_GET_TEMP:       cmd_get_temp();                      break;
            case CMD_SET_COOLER:     cmd_set_cooler(buf+1, len-1);        break;
            case CMD_CLOSE_CAMERA:   cmd_close_camera();                  break;
            default:                 reply_error("unknown_command");      break;
        }

        free(buf);
    }

    /* stdin закрылся — BEAM завершил процесс, чистимся */
    cmd_close_camera();
    return 0;
}