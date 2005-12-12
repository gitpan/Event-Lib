#include <sys/time.h>
#include <sys/types.h>
#include <event.h>



int main (int argc, char **argv) {
    event_init();
    event_priority_init(10);
    return 0;
}
