use Test;
BEGIN { plan tests => 4 }

use Event::Lib;
ok(1);

sub time1 {
    my $ev = shift;
    ok(1);
    timer_new(\&time2)->add(0.5);
}

sub time2 {
    my $ev = shift;
    ok(1);
    timer_new(\&time3)->add(0.5);
}

sub time3 {
    my $ev = shift;
    ok(1);
    exit;
}

timer_new(\&time1)->add(0.5);
event_dispatch(0, 5);
ok(0);
