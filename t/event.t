use Test;
BEGIN { plan tests => 2 }
use Event::Lib;
use Socket;
use warnings;
ok(1); 

my $pid = open KID, "|-";
skip($!, 1), exit if not defined $pid;

if ($pid) {
    $| = 1;
    print KID "ok";
    close KID;
} else {
    event_init;
    my $event = event_new(\*STDIN, EV_READ, 
	sub {  
	    my $ev = shift;
	    my $fh = $ev->fh;
	    read ($fh, my $buf, 2);
	    if ($buf eq 'ok') {
		ok(1);
		exit;
	    }
	    exit;
	}
    );
    $event->add;
    $event->dispatch(EVLOOP_ONCE, 10);
    ok(0);
    exit;
}


