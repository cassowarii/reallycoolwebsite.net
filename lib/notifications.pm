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

use List::Util qw( min );

use util;

use constant NOTIF_PAGE_SIZE => 25;

sub notif_page {
    my ($page) = @_;

    my $offset = ($page - 1) * NOTIF_PAGE_SIZE;
    my $query_page_size = NOTIF_PAGE_SIZE + 1;

    my $stmt = database('viewer')->prepare(
        "SELECT notifs.*, from_user.name from_username FROM linkgarden_notifications notifs
            INNER JOIN linkgarden_users from_user ON notifs.from_user = from_user.id
            WHERE to_user = ?
            ORDER BY created DESC
            LIMIT ?,?"
    );
    $stmt->execute(logged_in_user->{id}, $offset, $query_page_size);

    my $notifs = $stmt->fetchall_arrayref({});

    my $first_page = 0;
    my $last_page = 1;
    if ($page == 1) {
        $first_page = 1;
    }
    if (@$notifs > NOTIF_PAGE_SIZE) {
        $last_page = 0;
    }

    # If we aren't on the last page, we picked up one extra notification to check whether
    # we *were* on the last page -- so cut it off.
    pop @$notifs if scalar @$notifs > NOTIF_PAGE_SIZE;

    return template 'notifications', {
        linkgarden::common_template_params(),
        nav => [
            { name => 'notifications', link => undef },
        ],
        title => 'notifications &mdash; reallycoolwebsite.net',
        page_num => $page,
        first_page => $first_page,
        last_page => $last_page,
        notifications => $notifs,
    };
}

get '/notifications/?' => require_login sub {
    return notif_page(1);
};

get '/notifications/page/:pagenum/?' => require_login sub {
    return notif_page(route_parameters->get('pagenum'));
};

get '/notifications/:id[Int]/?' => require_login sub {
    my $notif_id = route_parameters->get('id');
    my $notif = database('viewer')->quick_select('linkgarden_notifications', { id => $notif_id });

    redirect "/notifications" unless $notif;

    redirect "/notifications" unless $notif->{to_user} == logged_in_user->{id};

    # Mark notification as read
    my $stmt = database('link_creator')->prepare(
        "UPDATE linkgarden_notifications SET unread = 0 WHERE id = ?"
    );
    $stmt->execute($notif_id);

    redirect $notif->{link};
};

get '/notifications/mark-all-read' => require_login sub {
    my $stmt = database('link_creator')->prepare(
        "UPDATE linkgarden_notifications SET unread = 0 WHERE to_user = ?"
    );
    $stmt->execute(logged_in_user->{id});

    redirect "/notifications";
};

1;
