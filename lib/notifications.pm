package notifications;
use strict;
use warnings;
use utf8;

use v5.16;

use Dancer2 appname => 'linkgarden';
use Dancer2::Plugin::Database;
use Dancer2::Plugin::Auth::Extensible;

use Encode;
use Parse::BBCode;

use util;

get '/notifications/?' => require_login sub {
    my $stmt = database('viewer')->prepare(
        "SELECT notifs.*, from_user.name from_username FROM linkgarden_notifications notifs
            INNER JOIN linkgarden_users from_user ON notifs.from_user = from_user.id
            WHERE to_user = ?"
    );
    $stmt->execute(logged_in_user->{id});

    my $notifs = $stmt->fetchall_arrayref({});

    template 'notifications', {
        linkgarden::common_template_params(),
        nav => [
            { name => 'notifications', link => undef },
        ],
        notifications => $notifs,
    };
};

get '/notifications/:id/?' => require_login sub {
    my $notif_id = route_parameters->get('id');
    my $notif = database('viewer')->quick_select('linkgarden_notifications', { id => $notif_id });

    say join ";", keys %$notif;

    redirect "/notifications" unless $notif;

    say "$notif->{to_user} ", logged_in_user->{id};

    redirect "/notifications" unless $notif->{to_user} == logged_in_user->{id};

    # Mark notification as read
    my $stmt = database('link_creator')->prepare(
        "UPDATE linkgarden_notifications SET unread = 0 WHERE id = ?"
    );
    $stmt->execute($notif_id);

    redirect $notif->{link};
};

1;
