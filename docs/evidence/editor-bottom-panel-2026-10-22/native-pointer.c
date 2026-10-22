#include <wayland-client.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "bookie-panel-pointer.h"
static struct zwlr_virtual_pointer_manager_v1 *manager;
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
 if (!strcmp(interface,"zwlr_virtual_pointer_manager_v1")) manager=wl_registry_bind(registry,name,&zwlr_virtual_pointer_manager_v1_interface,1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {}
static const struct wl_registry_listener listener={global,removed};
static uint32_t now(void) { struct timespec ts;clock_gettime(CLOCK_MONOTONIC,&ts);return ts.tv_sec*1000+ts.tv_nsec/1000000; }
static void move(struct zwlr_virtual_pointer_v1 *pointer,int x,int y) {
 zwlr_virtual_pointer_v1_motion_absolute(pointer,now(),x,y,1920,1200);zwlr_virtual_pointer_v1_frame(pointer);
}
int main(int argc,char **argv) {
 if(argc!=3 && argc!=5) return 2;
 struct wl_display *display=wl_display_connect(NULL);if(!display)return 3;
 struct wl_registry *registry=wl_display_get_registry(display);wl_registry_add_listener(registry,&listener,NULL);wl_display_roundtrip(display);
 if(!manager)return 4;
 struct zwlr_virtual_pointer_v1 *pointer=zwlr_virtual_pointer_manager_v1_create_virtual_pointer(manager,NULL);
 int x=atoi(argv[1]),y=atoi(argv[2]);move(pointer,x,y);wl_display_roundtrip(display);usleep(50000);
 zwlr_virtual_pointer_v1_button(pointer,now(),272,WL_POINTER_BUTTON_STATE_PRESSED);zwlr_virtual_pointer_v1_frame(pointer);wl_display_roundtrip(display);usleep(50000);
 if(argc==5) { int endx=atoi(argv[3]),endy=atoi(argv[4]);for(int i=1;i<=12;i++) {move(pointer,x+(endx-x)*i/12,y+(endy-y)*i/12);wl_display_roundtrip(display);usleep(16000);} }
 zwlr_virtual_pointer_v1_button(pointer,now(),272,WL_POINTER_BUTTON_STATE_RELEASED);zwlr_virtual_pointer_v1_frame(pointer);wl_display_roundtrip(display);usleep(50000);
 zwlr_virtual_pointer_v1_destroy(pointer);zwlr_virtual_pointer_manager_v1_destroy(manager);wl_registry_destroy(registry);wl_display_disconnect(display);return 0;
}
