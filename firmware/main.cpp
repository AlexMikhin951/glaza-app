#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/queue.h"
#include "freertos/event_groups.h"
#include "freertos/semphr.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "esp_camera.h"
#include "lwip/sockets.h"
#include "lwip/inet.h"
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "esp_rom_sys.h"
#include "esp_system.h"
#include "cJSON.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "FPV_CORE";

char target_ip[16] = "";
uint16_t target_port = 0;
char wifi_ssid[32] = "";
char wifi_pass[64] = "";

#define WIFI_CONNECTED_BIT BIT0
#define WIFI_FAIL_BIT      BIT1
static EventGroupHandle_t s_wifi_event_group;
static int s_retry_num = 0;
#define WIFI_MAXIMUM_RETRY 30

#define CMD_PORT 12346
#define FRAME_TYPE_VIDEO 0
#define FRAME_TYPE_PHOTO 1

#define PWDN_GPIO_NUM 32
#define RESET_GPIO_NUM -1
#define XCLK_GPIO_NUM 0
#define SIOD_GPIO_NUM 26
#define SIOC_GPIO_NUM 27
#define Y9_GPIO_NUM 35
#define Y8_GPIO_NUM 34
#define Y7_GPIO_NUM 39
#define Y6_GPIO_NUM 36
#define Y5_GPIO_NUM 21
#define Y4_GPIO_NUM 19
#define Y3_GPIO_NUM 18
#define Y2_GPIO_NUM 5
#define VSYNC_GPIO_NUM 25
#define HREF_GPIO_NUM 23
#define PCLK_GPIO_NUM 22

QueueHandle_t frameQueue;
QueueHandle_t returnQueue;
SemaphoreHandle_t camMutex;

volatile bool streaming_enabled = true;
volatile bool capture_requested = false;

volatile uint32_t stat_cam_frames = 0;
volatile uint32_t stat_udp_frames = 0;
volatile uint32_t stat_photo_frames = 0;
volatile uint32_t stat_dropped_frames = 0;
volatile uint32_t stat_total_bytes = 0;

static int udp_sock = -1;
static struct sockaddr_in dest_addr;
static struct sockaddr_in dest_addr_alt;
static bool dest_alt_enabled = false;
static uint32_t video_frame_count = 0;
static uint32_t photo_frame_count = 0;

bool load_settings_from_nvs() {
    nvs_handle_t my_handle;
    if (nvs_open("storage", NVS_READONLY, &my_handle) != ESP_OK) return false;
    size_t size = sizeof(wifi_ssid);
    if (nvs_get_str(my_handle, "ssid", wifi_ssid, &size) != ESP_OK) return false;
    size = sizeof(wifi_pass);
    nvs_get_str(my_handle, "pass", wifi_pass, &size);
    size = sizeof(target_ip);
    if (nvs_get_str(my_handle, "ip", target_ip, &size) != ESP_OK) return false;
    nvs_get_u16(my_handle, "port", &target_port);
    nvs_close(my_handle);
    return true;
}

void save_settings_to_nvs(const char* ssid, const char* pass, const char* ip, uint16_t port) {
    nvs_handle_t my_handle;
    nvs_open("storage", NVS_READWRITE, &my_handle);
    nvs_set_str(my_handle, "ssid", ssid);
    nvs_set_str(my_handle, "pass", pass);
    nvs_set_str(my_handle, "ip", ip);
    nvs_set_u16(my_handle, "port", port);
    nvs_commit(my_handle);
    nvs_close(my_handle);
}

static uint8_t ble_addr_type;
void ble_advertise();

void delayed_restart_task(void *pvParameter) {
    vTaskDelay(pdMS_TO_TICKS(1500));
    esp_restart();
}

static int gatt_svr_chr_access(uint16_t conn_handle, uint16_t attr_handle, struct ble_gatt_access_ctxt *ctxt, void *arg) {
    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        char data[256];
        int len = OS_MBUF_PKTLEN(ctxt->om);
        if (len > 255) len = 255;
        os_mbuf_copydata(ctxt->om, 0, len, data);
        data[len] = '\0';

        cJSON *root = cJSON_Parse(data);
        if (root) {
            cJSON *s = cJSON_GetObjectItem(root, "s");
            cJSON *p = cJSON_GetObjectItem(root, "p");
            cJSON *i = cJSON_GetObjectItem(root, "i");
            cJSON *o = cJSON_GetObjectItem(root, "o");

            if (s && i && o) {
                save_settings_to_nvs(s->valuestring, p ? p->valuestring : "", i->valuestring, (uint16_t)o->valueint);
                xTaskCreate(delayed_restart_task, "restart_task", 2048, NULL, 5, NULL);
            }
            cJSON_Delete(root);
        }
    }
    return 0;
}

static const ble_uuid16_t my_svc_uuid = BLE_UUID16_INIT(0xFFFF);
static const ble_uuid16_t my_chr_uuid = BLE_UUID16_INIT(0xFF01);

static const struct ble_gatt_svc_def gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &my_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]){
            { .uuid = &my_chr_uuid.u, .access_cb = gatt_svr_chr_access, .flags = BLE_GATT_CHR_F_WRITE }, {0}
        }
    }, {0}
};

void ble_advertise() {
    struct ble_gap_adv_params adv_params;
    struct ble_hs_adv_fields fields;
    memset(&adv_params, 0, sizeof(adv_params));
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    memset(&fields, 0, sizeof(fields));
    fields.name = (uint8_t *)"SmartGlasses";
    fields.name_len = strlen("SmartGlasses");
    fields.name_is_complete = 1;
    ble_gap_adv_set_fields(&fields);
    ble_gap_adv_start(ble_addr_type, NULL, BLE_HS_FOREVER, &adv_params, NULL, NULL);
}

void ble_on_sync() {
    ble_hs_id_infer_auto(0, &ble_addr_type);
    ble_advertise();
}

void ble_host_task(void *param) { nimble_port_run(); }

void statsTask(void *pvParameters) {
    uint32_t last_udp_frames = 0;
    while (true) {
        vTaskDelay(pdMS_TO_TICKS(5000));
        uint32_t current_udp = stat_udp_frames;
        uint32_t current_cam = stat_cam_frames;
        uint32_t dropped = stat_dropped_frames;
        uint32_t total_kb = stat_total_bytes / 1024;
        uint32_t fps = (current_udp - last_udp_frames) / 5;
        last_udp_frames = current_udp;

        ESP_LOGI(TAG, "==== CAMERA STATS ====");
        ESP_LOGI(TAG, "FPS (Network): %lu frames/sec", fps);
        ESP_LOGI(TAG, "Captured: %lu | Sent: %lu | Photos: %lu | Dropped: %lu",
                 current_cam, current_udp, stat_photo_frames, dropped);
        ESP_LOGI(TAG, "Stream: %s", streaming_enabled ? "ON" : "PAUSED");
        ESP_LOGI(TAG, "Total Data Sent: %lu KB", total_kb);
        ESP_LOGI(TAG, "======================");
    }
}

static void wifi_event_handler(void* arg, esp_event_base_t event_base, int32_t event_id, void* event_data) {
    if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (event_base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        EventBits_t bits = xEventGroupGetBits(s_wifi_event_group);
        const bool ever_connected = (bits & WIFI_CONNECTED_BIT) != 0;
        if (ever_connected || s_retry_num < WIFI_MAXIMUM_RETRY) {
            esp_wifi_connect();
            s_retry_num++;
            ESP_LOGW(TAG, "WiFi disconnected, reconnect #%d", s_retry_num);
        } else {
            xEventGroupSetBits(s_wifi_event_group, WIFI_FAIL_BIT);
        }
    } else if (event_base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        s_retry_num = 0;
        xEventGroupClearBits(s_wifi_event_group, WIFI_FAIL_BIT);
        xEventGroupSetBits(s_wifi_event_group, WIFI_CONNECTED_BIT);
        ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
        ESP_LOGI(TAG, "Got IP: " IPSTR, IP2STR(&event->ip_info.ip));
    }
}

static framesize_t getMaxPhotoSize(sensor_t *s) {
    if (s && s->id.PID == OV5640_PID) {
#ifdef FRAMESIZE_5MP
        return FRAMESIZE_5MP;
#else
        return FRAMESIZE_QSXGA;
#endif
    }
    return FRAMESIZE_UXGA;
}

static void sendFrameOverUdp(camera_fb_t *fb, uint8_t frameType, uint32_t *frameCounter) {
    if (udp_sock < 0 || fb == NULL) return;

    (*frameCounter)++;
    uint16_t total_chunks = (fb->len + 1428) / 1429;

    for (uint16_t i = 0; i < total_chunks; i++) {
        size_t offset = i * 1429;
        size_t size = (fb->len - offset < 1429) ? (fb->len - offset) : 1429;

        uint8_t packet[1440];
        memcpy(packet, frameCounter, 4);
        memcpy(packet + 4, &i, 2);
        memcpy(packet + 6, &total_chunks, 2);
        packet[8] = frameType;
        memcpy(packet + 9, fb->buf + offset, size);

        sendto(udp_sock, packet, size + 9, 0, (struct sockaddr *)&dest_addr, sizeof(dest_addr));
        if (dest_alt_enabled) {
            sendto(udp_sock, packet, size + 9, 0,
                   (struct sockaddr *)&dest_addr_alt, sizeof(dest_addr_alt));
        }

        if (i % 4 == 0) {
            vTaskDelay(1);
        } else {
            esp_rom_delay_us(500);
        }
    }

    stat_total_bytes += fb->len;
    if (frameType == FRAME_TYPE_PHOTO) {
        stat_photo_frames++;
    } else {
        stat_udp_frames++;
    }
}

static void captureHighResPhoto() {
    sensor_t *s = esp_camera_sensor_get();
    if (!s) {
        ESP_LOGE(TAG, "Sensor unavailable for photo");
        return;
    }

    framesize_t prevSize = s->status.framesize;
    framesize_t photoSize = getMaxPhotoSize(s);
    int prevQuality = 10;

    ESP_LOGI(TAG, "Capturing photo at framesize %d", photoSize);
    s->set_framesize(s, photoSize);
    s->set_quality(s, 4);

    for (int i = 0; i < 2; i++) {
        camera_fb_t *junk = esp_camera_fb_get();
        if (junk) esp_camera_fb_return(junk);
        vTaskDelay(pdMS_TO_TICKS(100));
    }

    camera_fb_t *fb = esp_camera_fb_get();
    if (fb) {
        ESP_LOGI(TAG, "Photo captured: %u bytes", fb->len);
        sendFrameOverUdp(fb, FRAME_TYPE_PHOTO, &photo_frame_count);
        esp_camera_fb_return(fb);
    } else {
        ESP_LOGE(TAG, "Photo capture failed");
    }

    s->set_framesize(s, prevSize);
    s->set_quality(s, prevQuality);
}

static void setVideoDest(struct in_addr addr, const char *reason) {
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_port = htons(target_port);
    dest_addr.sin_addr = addr;
    if (dest_addr_alt.sin_addr.s_addr != 0 &&
        dest_addr_alt.sin_addr.s_addr != dest_addr.sin_addr.s_addr) {
        dest_alt_enabled = true;
    } else {
        dest_alt_enabled = false;
    }
    ESP_LOGI(TAG, "Video DEST → " IPSTR ":%u (%s)%s",
             IP2STR(&dest_addr.sin_addr), (unsigned)target_port, reason,
             dest_alt_enabled ? " +alt .1" : "");
}

void commandTask(void *pvParameters) {
    int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_port = htons(CMD_PORT);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        ESP_LOGE(TAG, "Command socket bind failed");
        vTaskDelete(NULL);
        return;
    }

    char buf[32];
    ESP_LOGI(TAG, "Command listener on port %d", CMD_PORT);

    while (true) {
        struct sockaddr_in source;
        socklen_t slen = sizeof(source);
        int len = recvfrom(sock, buf, sizeof(buf) - 1, 0, (struct sockaddr *)&source, &slen);
        if (len <= 0) continue;
        buf[len] = '\0';

        const bool isDestCmd = strncmp(buf, "DEST:", 5) == 0;
        const bool isWakeCmd =
            strncmp(buf, "STREAM", 6) == 0 || strncmp(buf, "PING", 4) == 0;
        if (source.sin_addr.s_addr != 0 && (isDestCmd || isWakeCmd)) {
            if (source.sin_addr.s_addr != dest_addr.sin_addr.s_addr) {
                setVideoDest(source.sin_addr, isDestCmd ? "DEST source" : "cmd source");
            }
        }

        if (strncmp(buf, "READ_START", 10) == 0) {
            streaming_enabled = false;
            ESP_LOGI(TAG, "Video stream paused (reading mode)");
        } else if (strncmp(buf, "STREAM", 6) == 0) {
            streaming_enabled = true;
            ESP_LOGI(TAG, "Video stream resumed");
        } else if (strncmp(buf, "CAPTURE", 7) == 0) {
            capture_requested = true;
            ESP_LOGI(TAG, "Photo capture requested");
        } else if (isDestCmd) {
            if (source.sin_addr.s_addr == 0) {
                const char *ip = buf + 5;
                struct in_addr parsed;
                if (inet_pton(AF_INET, ip, &parsed) == 1) {
                    setVideoDest(parsed, "DEST cmd");
                } else {
                    ESP_LOGW(TAG, "Bad DEST IP: %s", ip);
                }
            }
        } else if (strncmp(buf, "PING", 4) == 0) {
            streaming_enabled = true;
        }
    }
}

void udpTask(void *pvParameters) {
    udp_sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP);
    memset(&dest_addr, 0, sizeof(dest_addr));
    memset(&dest_addr_alt, 0, sizeof(dest_addr_alt));
    dest_alt_enabled = false;
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_port = htons(target_port);

    esp_netif_ip_info_t self_info = {};
    esp_netif_t *netif = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
    bool have_self = netif && esp_netif_get_ip_info(netif, &self_info) == ESP_OK;

    if (strcmp(target_ip, "0.0.0.0") == 0) {
        if (have_self && self_info.gw.addr != 0) {
            dest_addr.sin_addr.s_addr = self_info.gw.addr;
            ESP_LOGW(TAG, "HOTSPOT: primary → gateway " IPSTR ":%u",
                     IP2STR(&self_info.gw), (unsigned)target_port);
        } else if (have_self && self_info.ip.addr != 0) {
            uint32_t ip_h = ntohl(self_info.ip.addr);
            dest_addr.sin_addr.s_addr = htonl((ip_h & 0xFFFFFF00u) | 1u);
            ESP_LOGW(TAG, "HOTSPOT: primary → subnet .1");
        } else {
            dest_addr.sin_addr.s_addr = inet_addr("192.168.43.1");
            ESP_LOGW(TAG, "HOTSPOT: primary → 192.168.43.1");
        }
    } else {
        inet_pton(AF_INET, target_ip, &dest_addr.sin_addr);
        ESP_LOGI(TAG, "Video primary → %s:%u", target_ip, (unsigned)target_port);
    }

    if (have_self) {
        ESP_LOGI(TAG, "ESP own IP: " IPSTR "  GW: " IPSTR,
                 IP2STR(&self_info.ip), IP2STR(&self_info.gw));
        if (self_info.ip.addr != 0) {
            uint32_t ip_h = ntohl(self_info.ip.addr);
            dest_addr_alt.sin_family = AF_INET;
            dest_addr_alt.sin_port = htons(target_port);
            dest_addr_alt.sin_addr.s_addr = htonl((ip_h & 0xFFFFFF00u) | 1u);
            if (dest_addr_alt.sin_addr.s_addr != dest_addr.sin_addr.s_addr) {
                dest_alt_enabled = true;
                ESP_LOGI(TAG, "Video also → " IPSTR ":%u (subnet .1)",
                         IP2STR(&dest_addr_alt.sin_addr), (unsigned)target_port);
            }
        }
    }

    int snd_buf = 128 * 1024;
    setsockopt(udp_sock, SOL_SOCKET, SO_SNDBUF, &snd_buf, sizeof(snd_buf));

    while (true) {
        camera_fb_t *fb;
        if (xQueueReceive(frameQueue, &fb, portMAX_DELAY) == pdTRUE) {
            sendFrameOverUdp(fb, FRAME_TYPE_VIDEO, &video_frame_count);
            xQueueSend(returnQueue, &fb, portMAX_DELAY);
        }
    }
}

void cameraTask(void *pvParameters) {
    TickType_t xLastWakeTime = xTaskGetTickCount();
    while (true) {
        if (capture_requested) {
            capture_requested = false;
            if (xSemaphoreTake(camMutex, pdMS_TO_TICKS(10000)) == pdTRUE) {
                captureHighResPhoto();
                xSemaphoreGive(camMutex);
            }
            continue;
        }

        if (!streaming_enabled) {
            vTaskDelay(pdMS_TO_TICKS(50));
            continue;
        }

        vTaskDelayUntil(&xLastWakeTime, pdMS_TO_TICKS(33));
        if (xSemaphoreTake(camMutex, pdMS_TO_TICKS(100)) != pdTRUE) continue;

        camera_fb_t *fb_ret;
        while (xQueueReceive(returnQueue, &fb_ret, 0) == pdTRUE) esp_camera_fb_return(fb_ret);

        camera_fb_t *fb = esp_camera_fb_get();
        if (!fb) {
            xSemaphoreGive(camMutex);
            continue;
        }

        stat_cam_frames++;
        if (xQueueSend(frameQueue, &fb, 0) != pdPASS) {
            stat_dropped_frames++;
            esp_camera_fb_return(fb);
        }
        xSemaphoreGive(camMutex);
    }
}

extern "C" void app_main(void) {
    WRITE_PERI_REG(RTC_CNTL_BROWN_OUT_REG, 0);
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        nvs_flash_init();
    }

    if (!load_settings_from_nvs()) {
        ESP_LOGI(TAG, "No settings found. Starting BLE Provisioning...");
        nimble_port_init();
        ble_svc_gap_device_name_set("SmartGlasses");
        ble_svc_gap_init();
        ble_svc_gatt_init();
        ble_gatts_count_cfg(gatt_svcs);
        ble_gatts_add_svcs(gatt_svcs);
        ble_hs_cfg.sync_cb = ble_on_sync;
        nimble_port_freertos_init(ble_host_task);
        return;
    }

    ESP_LOGI(TAG, "NVS: ssid=%s target_ip=%s port=%u",
             wifi_ssid, target_ip, (unsigned)target_port);
    if (strcmp(target_ip, "0.0.0.0") == 0) {
        ESP_LOGW(TAG, "NVS target_ip is 0.0.0.0 → HOTSPOT/gateway mode.");
    }

    s_wifi_event_group = xEventGroupCreate();
    esp_netif_init();
    esp_event_loop_create_default();
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_wifi_init(&cfg);
    esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID, &wifi_event_handler, NULL, NULL);
    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP, &wifi_event_handler, NULL, NULL);
    wifi_config_t wifi_config = {};
    strcpy((char*)wifi_config.sta.ssid, wifi_ssid);
    strcpy((char*)wifi_config.sta.password, wifi_pass);
    esp_wifi_set_mode(WIFI_MODE_STA);
    esp_wifi_set_config(WIFI_IF_STA, &wifi_config);
    esp_wifi_start();
    esp_wifi_set_ps(WIFI_PS_NONE);

    EventBits_t bits = xEventGroupWaitBits(s_wifi_event_group, WIFI_CONNECTED_BIT | WIFI_FAIL_BIT, pdFALSE, pdFALSE, pdMS_TO_TICKS(60000));

    if (!(bits & WIFI_CONNECTED_BIT)) {
        ESP_LOGE(TAG, "WiFi Failed for 60s. Restarting (NVS kept)...");
        vTaskDelay(pdMS_TO_TICKS(2000));
        esp_restart();
    }

    camera_config_t cam_cfg = {};
    cam_cfg.ledc_channel = LEDC_CHANNEL_0;
    cam_cfg.ledc_timer = LEDC_TIMER_0;
    cam_cfg.pin_d0 = Y2_GPIO_NUM;
    cam_cfg.pin_d1 = Y3_GPIO_NUM;
    cam_cfg.pin_d2 = Y4_GPIO_NUM;
    cam_cfg.pin_d3 = Y5_GPIO_NUM;
    cam_cfg.pin_d4 = Y6_GPIO_NUM;
    cam_cfg.pin_d5 = Y7_GPIO_NUM;
    cam_cfg.pin_d6 = Y8_GPIO_NUM;
    cam_cfg.pin_d7 = Y9_GPIO_NUM;
    cam_cfg.pin_xclk = XCLK_GPIO_NUM;
    cam_cfg.pin_pclk = PCLK_GPIO_NUM;
    cam_cfg.pin_vsync = VSYNC_GPIO_NUM;
    cam_cfg.pin_href = HREF_GPIO_NUM;
    cam_cfg.pin_sccb_sda = SIOD_GPIO_NUM;
    cam_cfg.pin_sccb_scl = SIOC_GPIO_NUM;
    cam_cfg.pin_pwdn = PWDN_GPIO_NUM;
    cam_cfg.pin_reset = RESET_GPIO_NUM;
    cam_cfg.xclk_freq_hz = 20000000;
    cam_cfg.pixel_format = PIXFORMAT_JPEG;
    cam_cfg.frame_size = FRAMESIZE_VGA;
    cam_cfg.jpeg_quality = 10;
    cam_cfg.fb_count = 2;
    cam_cfg.grab_mode = CAMERA_GRAB_LATEST;
    cam_cfg.fb_location = CAMERA_FB_IN_PSRAM;
    esp_camera_init(&cam_cfg);

    sensor_t * s = esp_camera_sensor_get();
    if (s && s->id.PID == OV5640_PID) {
        s->set_vflip(s, 0);
        s->set_hmirror(s, 1);
        ESP_LOGI(TAG, "OV5640 detected, max photo: 2592x1944");
    }

    camMutex = xSemaphoreCreateMutex();
    frameQueue = xQueueCreate(2, sizeof(camera_fb_t *));
    returnQueue = xQueueCreate(2, sizeof(camera_fb_t *));

    xTaskCreatePinnedToCore(commandTask, "Cmd", 4096, NULL, 8, NULL, 0);
    xTaskCreatePinnedToCore(udpTask, "UDP", 8192, NULL, 10, NULL, 0);
    xTaskCreatePinnedToCore(cameraTask, "Cam", 8192, NULL, 10, NULL, 1);
    xTaskCreatePinnedToCore(statsTask, "Stats", 2048, NULL, 5, NULL, 0);
}
