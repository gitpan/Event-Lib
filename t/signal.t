use Test;
BEGIN { plan tests => 2 }

use Event::Lib;
ok(1); 

use POSIX;

my $pid = fork;
skip($!, 1) if not defined $pid;

if ($pid) {
    kill SIGHUP => $pid;
    ok(1);
    wait;
} else {
    my $event = signal_new(SIGHUP, sub { ok(1) });
    $event->add;
    # we give it ten seconds to receive the signal
    $event->dispatch(EVLOOP_ONCE, 10);
    ok(0);
    exit;
}


