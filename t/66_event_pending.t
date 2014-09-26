#
# https://github.com/vlet/iec104/issues/2
#
# SIGSEGV on pending() of not initialized timer

use Event::Lib;
use Test::More;

BEGIN { plan tests => 1; }

my $pid = fork;
if (! $pid ) {
    my $timer;
    $timer = timer_new( sub { 
        $timer->remove;
        my $f = timer_new( sub {} );
        $f->pending;
        $f->remove;
    });
    $timer->add(0.1);
    event_mainloop;
    exit;
} else {
    waitpid $pid,0;
    is $?&127, 0, "no segfault";
}
